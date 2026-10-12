import CKernel
import Synchronization

/// FIFOs (K13b; Zircon's FifoDispatcher, type 19): two endpoints, each
/// with a ring of `elementCount` records of `elementSize` bytes (at most
/// 4096 in all) that its holder reads; a write goes into the peer's ring.
/// Writes and reads move as many whole records as fit or are there (at
/// least one, else SHOULD_WAIT; PEER_CLOSED once the peer is gone and,
/// for reads, nothing is left). READABLE: records to read; WRITABLE: room
/// in the peer's ring; PEER_CLOSED when the peer's last handle went.
///
/// User bytes are copied through a kernel buffer outside the pair's lock:
/// a write copies all it was given in first; a read takes records under
/// the lock and copies them out after, the destination checked writable
/// beforehand (a racing unmap after that loses them: Zircon rolls back).
/// Lock order: the pair -> object, as channels.
struct FifoObject: ~Copyable {
    var header = ObjectHeader(type: .fifo)
    let shared: PeerSharedPointer
    let elementSize: Int
    let elementCount: Int
    /// Its ring (heap): records `tail..<head` (counts, wrapping by index).
    let ring: UInt64
    var head: UInt64 = 0
    var tail: UInt64 = 0
    var peer: UInt64 = 0
    var peerKoid: UInt64 = 0

    /// ZX_DEFAULT_FIFO_RIGHTS: basic, read and write, signal, signal peer.
    static var defaultRights: Rights { .basic | .read | .write | .signal | .signalPeer }
    static var maxBytes: Int { 4096 }
}

@safe struct FifoPointer {
    let object: ObjectPointer

    var pointee: FifoObject {
        unsafeAddress { unsafe UnsafePointer<FifoObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<FifoObject>(bitPattern: UInt(object.address))! }
    }

    var bytes: UnsafeMutableRawPointer { unsafe UnsafeMutableRawPointer(bitPattern: UInt(pointee.ring))! }
}

enum Fifos {
    static func create(count: UInt64, size: UInt64) throws(Status) -> (ObjectPointer, ObjectPointer) {
        guard count > 0, size > 0, count <= UInt64(FifoObject.maxBytes), size <= UInt64(FifoObject.maxBytes),
              count * size <= UInt64(FifoObject.maxBytes) else { throw .outOfRange }
        let bytes = Int(count * size)
        guard let shared = PeerSharedPointer.allocate() else { throw .noMemory }
        guard let ringA = unsafe heap.allocate(size: bytes) else {
            shared.release(); shared.release()
            throw .noMemory
        }
        guard let ringB = unsafe heap.allocate(size: bytes) else {
            unsafe heap.free(ringA)
            shared.release(); shared.release()
            throw .noMemory
        }
        func make(_ ring: UnsafeMutableRawPointer) -> ObjectPointer? {
            Objects.allocate(FifoObject(shared: shared, elementSize: Int(size), elementCount: Int(count),
                                        ring: UInt64(UInt(bitPattern: ring))))
        }
        guard let a = unsafe make(ringA) else {
            unsafe heap.free(ringA); unsafe heap.free(ringB)
            shared.release(); shared.release()
            throw .noMemory
        }
        guard let b = unsafe make(ringB) else {
            unsafe heap.free(ringB)
            a.release()  // frees ringA and one of shared's references
            shared.release()
            throw .noMemory
        }
        FifoPointer(object: a).pointee.peer = b.address
        FifoPointer(object: b).pointee.peer = a.address
        FifoPointer(object: a).pointee.peerKoid = b.header.koid
        FifoPointer(object: b).pointee.peerKoid = a.header.koid
        shared.pointee.id = min(a.header.koid, b.header.koid)
        a.header.signals = CROI_SIGNAL_WRITABLE
        b.header.signals = CROI_SIGNAL_WRITABLE
        return (a, b)
    }

    /// Its last reference: the peer loses WRITABLE and gains PEER_CLOSED.
    static func destroy(_ object: ObjectPointer) {
        let me = FifoPointer(object: object)
        let shared = me.pointee.shared
        var peer: ObjectPointer? = nil
        shared.pointee.lock.withLock {
            if me.pointee.peer != 0 {
                let other = ObjectPointer(address: me.pointee.peer)
                FifoPointer(object: other).pointee.peer = 0
                if other.tryRetain() { peer = other }
            }
            me.pointee.peer = 0
        }
        if let peer {
            peer.updateSignals(clear: CROI_SIGNAL_WRITABLE, set: CROI_SIGNAL_PEER_CLOSED)
            peer.release()
        }
        unsafe heap.free(me.bytes)
        shared.release()
        Objects.free(object, as: FifoObject.self)
    }

    /// fifo_write: up to `count` records from `source` into the peer's ring;
    /// how many went.
    static func write(_ object: ObjectPointer, size: UInt64, source: UInt64, count: UInt64) throws(Status) -> UInt64 {
        let me = FifoPointer(object: object)
        // Zircon's order: the peer, the size and count, room; then only the
        // records that fit are read from user memory (review fix: the
        // whole buffer was read first, so a full or peerless FIFO gave
        // INVALID_ARGS for a short buffer, and OUT_OF_RANGE before
        // PEER_CLOSED).
        let room = try me.pointee.shared.pointee.lock.withLock { () throws(Status) -> UInt64 in
            guard me.pointee.peer != 0 else { throw .peerClosed }
            guard size == UInt64(me.pointee.elementSize), count > 0 else { throw .outOfRange }
            let target = FifoPointer(object: ObjectPointer(address: me.pointee.peer))
            let used = target.pointee.head - target.pointee.tail
            guard used < UInt64(target.pointee.elementCount) else { throw .shouldWait }
            return UInt64(target.pointee.elementCount) - used
        }
        let wanted = min(count, room)
        let bytes = Int(wanted) * me.pointee.elementSize
        guard let staging = unsafe heap.allocate(size: bytes) else { throw .noMemory }
        defer { unsafe heap.free(staging) }
        guard unsafe UserCopy.from(staging, source, UInt64(bytes)) == 0 else { throw .invalidArgs }
        return try me.pointee.shared.pointee.lock.withLock { () throws(Status) -> UInt64 in
            guard me.pointee.peer != 0 else { throw .peerClosed }
            let target = FifoPointer(object: ObjectPointer(address: me.pointee.peer))
            let capacity = UInt64(target.pointee.elementCount)
            let used = target.pointee.head - target.pointee.tail
            guard used < capacity else { throw .shouldWait }
            let n = min(wanted, capacity - used)
            for i in 0..<n {
                let slot = Int((target.pointee.head + i) % capacity)
                unsafe target.bytes.advanced(by: slot * target.pointee.elementSize)
                    .copyMemory(from: staging.advanced(by: Int(i) * target.pointee.elementSize),
                                byteCount: target.pointee.elementSize)
            }
            target.pointee.head += n
            if used == 0 { target.object.updateSignals(clear: 0, set: CROI_SIGNAL_READABLE) }
            if used + n == capacity { object.updateSignals(clear: CROI_SIGNAL_WRITABLE, set: 0) }
            return n
        }
    }

    /// fifo_read: up to `count` records from its own ring into `destination`
    /// (checked writable first); how many came.
    static func read(_ object: ObjectPointer, size: UInt64, destination: UInt64, count: UInt64) throws(Status) -> UInt64 {
        let me = FifoPointer(object: object)
        guard size == UInt64(me.pointee.elementSize), count > 0 else { throw .outOfRange }
        // Empty first, then the destination only for the records there
        // (review fix, Zircon's order: an empty FIFO gave INVALID_ARGS for a
        // bad buffer, and a buffer for fewer records than asked was refused).
        let available = try me.pointee.shared.pointee.lock.withLock { () throws(Status) -> UInt64 in
            let used = me.pointee.head - me.pointee.tail
            guard used > 0 else { throw me.pointee.peer == 0 ? .peerClosed : .shouldWait }
            return used
        }
        let wanted = min(count, available)
        let bytes = Int(wanted) * me.pointee.elementSize
        try Syscalls.check(destination, bytes)
        guard let staging = unsafe heap.allocate(size: bytes) else { throw .noMemory }
        defer { unsafe heap.free(staging) }
        let n = try me.pointee.shared.pointee.lock.withLock { () throws(Status) -> UInt64 in
            let capacity = UInt64(me.pointee.elementCount)
            let used = me.pointee.head - me.pointee.tail
            guard used > 0 else { throw me.pointee.peer == 0 ? .peerClosed : .shouldWait }
            let n = min(wanted, used)
            for i in 0..<n {
                let slot = Int((me.pointee.tail + i) % capacity)
                unsafe staging.advanced(by: Int(i) * me.pointee.elementSize)
                    .copyMemory(from: me.bytes.advanced(by: slot * me.pointee.elementSize),
                                byteCount: me.pointee.elementSize)
            }
            me.pointee.tail += n
            if used == n { object.updateSignals(clear: CROI_SIGNAL_READABLE, set: 0) }
            if used == capacity, me.pointee.peer != 0 {  // was full: the writer has room again
                ObjectPointer(address: me.pointee.peer).updateSignals(clear: 0, set: CROI_SIGNAL_WRITABLE)
            }
            return n
        }
        guard unsafe UserCopy.to(destination, UnsafeRawPointer(staging), UInt64(n) * UInt64(me.pointee.elementSize)) == 0 else {
            throw .invalidArgs  // unmapped since the check: those records are lost
        }
        return n
    }
}
