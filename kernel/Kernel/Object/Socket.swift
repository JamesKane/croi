import CKernel
import PageTables
import Synchronization

/// Sockets (K13c; Zircon's SocketDispatcher, type 14): two endpoints, each
/// with a receive buffer its holder reads; a write fills the peer's.
/// Stream sockets move bytes (short writes allowed), datagram sockets whole
/// messages (all or nothing; a short read drops the rest of one).
/// set_disposition turns writing off and on per direction; read and write
/// thresholds raise READ_THRESHOLD / WRITE_THRESHOLD. Zircon's error order
/// and signal rules (the pinned tree's, including its quirks: re-enabling
/// writing sets WRITABLE unconditionally, as does a read that drains a full
/// buffer, whatever the writer's disposition).
///
/// A receive buffer is a ring of up to 64 PMM pages (256 KiB, Zircon's
/// 264160 rounded to pages), each allocated when first written and freed
/// once drained, so an idle socket holds no memory. A datagram carries a
/// 4-byte length before its bytes in the ring (counted against capacity;
/// not in rx_buf_size). User bytes are copied straight into and out of the
/// ring under the pair's Mutex (copies may fault and page in, which a spin
/// lock mustn't), and objects' signals under their own spin locks. Lock
/// order: the pair's mutex -> object.
struct SocketShared: ~Copyable {
    let mutex = Mutex()
    let references = Atomic<Int>(2)
}

@safe struct SocketSharedPointer {
    let address: UInt64

    var pointee: SocketShared {
        unsafeAddress { unsafe UnsafePointer<SocketShared>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<SocketShared>(bitPattern: UInt(address))! }
    }

    static func allocate() -> SocketSharedPointer? {
        guard let raw = unsafe heap.allocate(size: MemoryLayout<SocketShared>.size, alignment: 16) else { return nil }
        unsafe raw.bindMemory(to: SocketShared.self, capacity: 1).initialize(to: SocketShared())
        return SocketSharedPointer(address: UInt64(UInt(bitPattern: raw)))
    }

    func release() {
        guard pointee.references.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 else { return }
        let raw = unsafe UnsafeMutablePointer<SocketShared>(bitPattern: UInt(address))!
        unsafe raw.deinitialize(count: 1)
        unsafe heap.free(UnsafeMutableRawPointer(raw))
    }
}

struct SocketObject: ~Copyable {
    var header = ObjectHeader(type: .socket)
    let shared: SocketSharedPointer
    let datagram: Bool
    var peer: UInt64 = 0
    var peerKoid: UInt64 = 0
    /// The receive ring: byte counters (positions mod `capacity`) and its
    /// pages (physical, 0 until written).
    var head: UInt64 = 0
    var tail: UInt64 = 0
    var pages = InlineArray<64, UInt64>(repeating: 0)
    /// Payload bytes queued (datagrams' headers excluded), datagrams queued.
    var payload: UInt64 = 0
    var readThreshold: UInt64 = 0
    var writeThreshold: UInt64 = 0
    /// The peer turned its writing off: reads of an empty buffer are BAD_STATE.
    var readDisabled = false

    static var capacity: UInt64 { 64 * 4096 }

    /// ZX_DEFAULT_SOCKET_RIGHTS: basic, read, write, properties, signal,
    /// signal peer, manage socket.
    static var defaultRights: Rights {
        .basic | .read | .write | .getProperty | .setProperty | .signal | .signalPeer | .manageSocket
    }
}

@safe struct SocketPointer {
    let object: ObjectPointer

    var pointee: SocketObject {
        unsafeAddress { unsafe UnsafePointer<SocketObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<SocketObject>(bitPattern: UInt(object.address))! }
    }

    var peerPointer: SocketPointer? {
        pointee.peer == 0 ? nil : SocketPointer(object: ObjectPointer(address: pointee.peer))
    }

    var used: UInt64 { pointee.head - pointee.tail }
    var free: UInt64 { SocketObject.capacity - used }

    // MARK: The ring (pair mutex held)

    /// Copies `length` bytes between the ring at position `at` and a kernel
    /// or user address, page piece by page piece; allocates pages for
    /// writes. Returns the bytes moved before any fault.
    private func copy(at: UInt64, length: UInt64, user: UInt64, intoRing: Bool) -> UInt64 {
        var done: UInt64 = 0
        while done < length {
            let position = (at + done) % SocketObject.capacity
            let index = Int(position / 4096), offset = position % 4096
            let piece = min(length - done, 4096 - offset)
            if pointee.pages[index] == 0 {
                guard intoRing, let page = pmm.allocatePage() else { return done }
                pointee.pages[index] = page
            }
            let ring = KernelLayout.physmap(pointee.pages[index]) + offset
            let failed = intoRing
                ? unsafe UserCopy.from(UnsafeMutableRawPointer(bitPattern: UInt(ring))!, user + done, piece)
                : unsafe UserCopy.to(user + done, UnsafeRawPointer(bitPattern: UInt(ring))!, piece)
            guard failed == 0 else { return done }
            done += piece
        }
        return done
    }

    /// A 4-byte datagram length at ring position `at`, read or written.
    private func header(at: UInt64) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<UInt64(4) {
            let position = (at + i) % SocketObject.capacity
            let page = pointee.pages[Int(position / 4096)]
            let byte = page == 0 ? 0 : unsafe UnsafePointer<UInt8>(bitPattern: UInt(KernelLayout.physmap(page) + position % 4096))!.pointee
            value |= UInt32(byte) << UInt32(8 * i)
        }
        return value
    }

    private func setHeader(at: UInt64, _ value: UInt32) -> Bool {
        for i in 0..<UInt64(4) {
            let position = (at + i) % SocketObject.capacity
            let index = Int(position / 4096)
            if pointee.pages[index] == 0 {
                guard let page = pmm.allocatePage() else { return false }
                pointee.pages[index] = page
            }
            unsafe UnsafeMutablePointer<UInt8>(bitPattern: UInt(KernelLayout.physmap(pointee.pages[index]) + position % 4096))!
                .pointee = UInt8(truncatingIfNeeded: value >> UInt32(8 * i))
        }
        return true
    }

    /// Pages wholly behind the tail and not in use go back.
    private func trim() {
        if used == 0 {
            for i in 0..<64 where pointee.pages[i] != 0 {
                pmm.free(pointee.pages[i])
                pointee.pages[i] = 0
            }
            pointee.head = 0
            pointee.tail = 0
            return
        }
        // Pages wholly inside the free region, which runs from the head
        // (the next byte written) for `capacity - used` bytes. (Review fix:
        // this walked the pages strictly between the head's and the tail's,
        // which, both in one page of a nearly full ring, were all the others,
        // full of unread data: they were freed and the socket wedged.)
        let capacity = SocketObject.capacity
        var at = pointee.head % capacity
        var left = capacity - used
        let into = at % 4096
        if into != 0 {  // the rest of the head's page isn't all free
            guard left > 4096 - into else { return }
            left -= 4096 - into
            at = (at + 4096 - into) % capacity
        }
        while left >= 4096 {
            let page = Int(at / 4096)
            if pointee.pages[page] != 0 {
                pmm.free(pointee.pages[page])
                pointee.pages[page] = 0
            }
            at = (at + 4096) % capacity
            left -= 4096
        }
    }

    /// Appends from user memory: a stream's bytes (up to the room there is)
    /// or one datagram. Returns the payload bytes queued, or an error.
    func enqueue(_ source: UInt64, _ size: UInt64) throws(Status) -> UInt64 {
        if pointee.datagram {
            guard size <= SocketObject.capacity - 4 else { throw .outOfRange }
            guard free >= size + 4 else { throw .shouldWait }
            guard setHeader(at: pointee.head, UInt32(size)) else { throw .shouldWait }
            let moved = copy(at: pointee.head + 4, length: size, user: source, intoRing: true)
            guard moved == size else {
                trim()
                throw moved == 0 && size > 0 && free < size + 4 ? .shouldWait : .invalidArgs
            }
            pointee.head += 4 + size
            pointee.payload += size
            return size
        }
        guard free > 0 else { throw .shouldWait }
        let wanted = min(size, free)
        let moved = copy(at: pointee.head, length: wanted, user: source, intoRing: true)
        pointee.head += moved
        pointee.payload += moved
        if moved < wanted, moved == 0 { throw .invalidArgs }
        return moved
    }

    /// Copies (and unless `peek`, consumes) into user memory: stream bytes
    /// up to `size`, or the head datagram's first `size` bytes (the rest of
    /// it dropped). Returns the bytes copied; the buffer is non-empty.
    func dequeue(_ destination: UInt64, _ size: UInt64, peek: Bool) throws(Status) -> UInt64 {
        if pointee.datagram {
            let length = UInt64(header(at: pointee.tail))
            let n = min(size, length)
            let moved = copy(at: pointee.tail + 4, length: n, user: destination, intoRing: false)
            if !peek {
                pointee.tail += 4 + length
                pointee.payload -= length
                trim()
            }
            guard moved == n else { throw .invalidArgs }
            return n
        }
        let n = min(size, used)
        let moved = copy(at: pointee.tail, length: n, user: destination, intoRing: false)
        if !peek {
            pointee.tail += moved
            pointee.payload -= moved
            trim()
        }
        guard moved == n else { throw .invalidArgs }
        return n
    }

    /// Readable bytes as ZX_INFO_SOCKET's rx_buf_available reports them.
    var available: UInt64 {
        pointee.datagram ? (used == 0 ? 0 : UInt64(header(at: pointee.tail))) : pointee.payload
    }

    func freeRing() {
        for i in 0..<64 where pointee.pages[i] != 0 { pmm.free(pointee.pages[i]) }
    }
}

enum Sockets {
    static var readable: UInt32 { CROI_SIGNAL_READABLE }
    static var writable: UInt32 { CROI_SIGNAL_WRITABLE }
    static var peerClosed: UInt32 { CROI_SIGNAL_PEER_CLOSED }
    static var peerWriteDisabled: UInt32 { 1 << 4 }
    static var writeDisabled: UInt32 { 1 << 5 }
    static var readThreshold: UInt32 { 1 << 10 }
    static var writeThreshold: UInt32 { 1 << 11 }

    static func create(options: UInt32) throws(Status) -> (ObjectPointer, ObjectPointer) {
        guard options & ~UInt32(CROI_SOCKET_DATAGRAM) == 0 else { throw .invalidArgs }
        let datagram = options & UInt32(CROI_SOCKET_DATAGRAM) != 0
        guard let shared = SocketSharedPointer.allocate() else { throw .noMemory }
        guard let a = Objects.allocate(SocketObject(shared: shared, datagram: datagram)) else {
            shared.release(); shared.release()
            throw .noMemory
        }
        guard let b = Objects.allocate(SocketObject(shared: shared, datagram: datagram)) else {
            a.release()
            shared.release()
            throw .noMemory
        }
        SocketPointer(object: a).pointee.peer = b.address
        SocketPointer(object: b).pointee.peer = a.address
        SocketPointer(object: a).pointee.peerKoid = b.header.koid
        SocketPointer(object: b).pointee.peerKoid = a.header.koid
        a.header.signals = writable
        b.header.signals = writable
        return (a, b)
    }

    /// Its last reference: the peer loses WRITABLE and gains PEER_CLOSED.
    static func destroy(_ object: ObjectPointer) {
        let me = SocketPointer(object: object)
        let shared = me.pointee.shared
        var peer: ObjectPointer? = nil
        shared.pointee.mutex.withLock {
            if let other = me.peerPointer {
                other.pointee.peer = 0
                if other.object.tryRetain() { peer = other.object }
            }
            me.pointee.peer = 0
        }
        if let peer {
            peer.updateSignals(clear: writable, set: peerClosed)
            peer.release()
        }
        me.freeRing()
        shared.release()
        Objects.free(object, as: SocketObject.self)
    }

    private static func locked<R>(_ me: SocketPointer, _ body: () throws(Status) -> R) throws(Status) -> R {
        me.pointee.shared.pointee.mutex.lock()
        defer { me.pointee.shared.pointee.mutex.unlock() }
        return try body()
    }

    /// socket_write (the handle checked): bytes into the peer's buffer.
    static func write(_ object: ObjectPointer, _ source: UInt64, _ size: UInt64) throws(Status) -> UInt64 {
        let me = SocketPointer(object: object)
        return try locked(me) { () throws(Status) -> UInt64 in
            guard let peer = me.peerPointer else { throw .peerClosed }
            guard object.signals & writeDisabled == 0 else { throw .badState }
            guard size > 0 else { return 0 }
            guard size <= UInt64(UInt32.max) else { throw .invalidArgs }
            let wasEmpty = peer.used == 0
            let written: UInt64
            do throws(Status) {
                written = try peer.enqueue(source, size)
            } catch {
                if peer.free == 0 { object.updateSignals(clear: writable, set: 0) }
                throw error
            }
            var set: UInt32 = 0
            if wasEmpty, written > 0 { set |= readable }
            if peer.pointee.readThreshold > 0, peer.pointee.payload >= peer.pointee.readThreshold { set |= readThreshold }
            if set != 0 { peer.object.updateSignals(clear: 0, set: set) }
            var clear: UInt32 = 0
            if me.pointee.writeThreshold > 0, SocketObject.capacity - peer.used < me.pointee.writeThreshold { clear |= writeThreshold }
            if peer.free == 0 || (peer.pointee.datagram && peer.free <= 4) { clear |= writable }
            if clear != 0 { object.updateSignals(clear: clear, set: 0) }
            return written
        }
    }

    /// socket_read (the handle checked).
    static func read(_ object: ObjectPointer, _ destination: UInt64, _ size: UInt64, peek: Bool) throws(Status) -> UInt64 {
        let me = SocketPointer(object: object)
        return try locked(me) { () throws(Status) -> UInt64 in
            guard size <= UInt64(UInt32.max) else { throw .invalidArgs }
            guard me.used > 0 else {
                if me.peerPointer == nil { throw .peerClosed }
                throw me.pointee.readDisabled ? .badState : .shouldWait
            }
            guard size > 0 else { return 0 }
            let wasFull = me.free == 0 || (me.pointee.datagram && me.free <= 4)
            var result: Status? = nil
            var moved: UInt64 = 0
            do throws(Status) {
                moved = try me.dequeue(destination, size, peek: peek)
            } catch {
                result = error
            }
            if !peek {
                var clear: UInt32 = 0
                if me.pointee.readThreshold > 0, me.pointee.payload < me.pointee.readThreshold { clear |= readThreshold }
                if me.used == 0 { clear |= readable }
                if clear != 0 { object.updateSignals(clear: clear, set: 0) }
                if let peer = me.peerPointer {
                    var set: UInt32 = 0
                    if peer.pointee.writeThreshold > 0, me.free >= peer.pointee.writeThreshold { set |= writeThreshold }
                    if wasFull, moved > 0 { set |= writable }  // Zircon's (review fix: also when nothing moved)
                    if set != 0 { peer.object.updateSignals(clear: 0, set: set) }
                }
            }
            if let result { throw result }
            return moved
        }
    }

    /// socket_set_disposition (the arguments checked, MANAGE_SOCKET held).
    static func setDisposition(_ object: ObjectPointer, _ mine: UInt32, _ peers: UInt32) throws(Status) {
        let me = SocketPointer(object: object)
        let disabled = UInt32(CROI_SOCKET_DISPOSITION_WRITE_DISABLED), enabled = UInt32(CROI_SOCKET_DISPOSITION_WRITE_ENABLED)
        try locked(me) { () throws(Status) in
            let peer = me.peerPointer
            // Re-enabling waits until what was written before the disable is read.
            if peers == enabled, me.used > 0, object.signals & peerWriteDisabled != 0 { throw .badState }
            if mine == enabled, let peer, peer.used > 0, peer.object.signals & peerWriteDisabled != 0 { throw .badState }
            func apply(_ end: SocketPointer, _ other: SocketPointer?, _ disposition: UInt32) {
                if disposition == disabled {
                    end.object.updateSignals(clear: writable, set: writeDisabled)
                    if let other {
                        other.object.updateSignals(clear: 0, set: peerWriteDisabled)
                        other.pointee.readDisabled = true
                    }
                } else if disposition == enabled {
                    end.object.updateSignals(clear: writeDisabled, set: writable)
                    if let other {
                        other.object.updateSignals(clear: peerWriteDisabled, set: 0)
                        other.pointee.readDisabled = false
                    }
                }
            }
            apply(me, peer, mine)
            if let peer { apply(peer, me, peers) }
        }
    }

    /// ZX_PROP_SOCKET_RX_THRESHOLD / TX_THRESHOLD.
    static func threshold(_ object: ObjectPointer, transmit: Bool) throws(Status) -> UInt64 {
        let me = SocketPointer(object: object)
        return try locked(me) { () throws(Status) -> UInt64 in
            transmit ? me.pointee.writeThreshold : me.pointee.readThreshold
        }
    }

    static func setThreshold(_ object: ObjectPointer, transmit: Bool, _ value: UInt64) throws(Status) {
        let me = SocketPointer(object: object)
        guard value <= SocketObject.capacity else { throw .invalidArgs }
        try locked(me) { () throws(Status) in
            if transmit {
                guard let peer = me.peerPointer else { throw .peerClosed }
                me.pointee.writeThreshold = value
                let on = value > 0 && SocketObject.capacity - peer.used >= value
                object.updateSignals(clear: on ? 0 : writeThreshold, set: on ? writeThreshold : 0)
            } else {
                me.pointee.readThreshold = value
                let on = value > 0 && me.pointee.payload >= value
                object.updateSignals(clear: on ? 0 : readThreshold, set: on ? readThreshold : 0)
            }
        }
    }

    /// ZX_INFO_SOCKET.
    static func info(_ object: ObjectPointer) -> croi_info_socket_t {
        let me = SocketPointer(object: object)
        me.pointee.shared.pointee.mutex.lock()
        defer { me.pointee.shared.pointee.mutex.unlock() }
        var info = croi_info_socket_t()
        info.options = me.pointee.datagram ? UInt32(CROI_SOCKET_DATAGRAM) : 0
        info.rx_buf_max = SocketObject.capacity
        info.rx_buf_size = me.pointee.payload
        info.rx_buf_available = me.available
        if let peer = me.peerPointer {
            info.tx_buf_max = SocketObject.capacity
            info.tx_buf_size = peer.pointee.payload
        }
        return info
    }

    static func relatedKoid(_ object: ObjectPointer) -> UInt64 { SocketPointer(object: object).pointee.peerKoid }

    /// object_signal_peer on a socket (user signals, checked by the caller).
    static func signalPeer(_ object: ObjectPointer, clear: UInt32, set: UInt32) throws(Status) {
        let me = SocketPointer(object: object)
        let peer = try locked(me) { () throws(Status) -> ObjectPointer in
            guard let other = me.peerPointer, other.object.tryRetain() else { throw .peerClosed }
            return other.object
        }
        peer.updateSignals(clear: clear, set: set)
        peer.release()
    }
}
