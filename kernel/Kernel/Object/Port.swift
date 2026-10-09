import CKernel
import Synchronization

/// A port packet, laid out as zx_port_packet_t: key, type, status, and 32
/// bytes of payload (for signal packets: trigger, observed, count,
/// timestamp).
struct PortPacket: Equatable {
    var key: UInt64 = 0
    var type: UInt32 = 0
    var status: Int32 = 0
    var payload = InlineArray<4, UInt64>(repeating: 0)

    static func == (a: PortPacket, b: PortPacket) -> Bool {
        a.key == b.key && a.type == b.type && a.status == b.status && a.payload[0] == b.payload[0]
            && a.payload[1] == b.payload[1] && a.payload[2] == b.payload[2] && a.payload[3] == b.payload[3]
    }

    /// Packet types: Zircon's, then croi's own kernel sources.
    static var user: UInt32 { 0 }
    static var signalOne: UInt32 { 1 }
    /// Ext 3: a deadline reservation overran its budget (count in payload[2]).
    static var budgetOverrun: UInt32 { 0x80 }
    /// Ext 6: a memory account crossed its pressure level (bytes charged in
    /// payload[1], count in payload[2]).
    static var memoryPressure: UInt32 { 0x81 }

    // Signal payload: trigger (low 32 of [0]), observed (high 32 of [0]), count, timestamp.
    var trigger: UInt32 { UInt32(truncatingIfNeeded: payload[0]) }
    var observed: UInt32 { UInt32(truncatingIfNeeded: payload[0] >> 32) }
    var count: UInt64 { payload[2] }
}

/// A queued packet. Owned by the queue (from wait_async or port_queue: freed
/// when dequeued) or by a kernel packet source (reused: never freed here).
struct QueuedPacket {
    var next: UInt64 = 0
    var packet: PortPacket
    /// 0, or the PacketSource that owns this record.
    let source: UInt64
    /// For cancellation: the object and handle a signal packet came from.
    let originTable: UInt64
    let originHandle: UInt32
}

@safe struct QueuedPacketPointer: Equatable {
    let address: UInt64

    var pointee: QueuedPacket {
        unsafeAddress { unsafe UnsafePointer<QueuedPacket>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<QueuedPacket>(bitPattern: UInt(address))! }
    }

    static func allocate(_ packet: PortPacket, source: UInt64 = 0, table: UInt64 = 0,
                         handle: UInt32 = 0) throws(Status) -> QueuedPacketPointer {
        guard let raw = unsafe heap.allocate(size: MemoryLayout<QueuedPacket>.size) else { throw .noMemory }
        unsafe raw.bindMemory(to: QueuedPacket.self, capacity: 1).initialize(
            to: QueuedPacket(packet: packet, source: source, originTable: table, originHandle: handle))
        return QueuedPacketPointer(address: UInt64(UInt(bitPattern: raw)))
    }

    func free() {
        unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(address))!)
    }
}

/// A port (Zircon's PortDispatcher): a FIFO of packets and the threads
/// waiting for them. `packetsLock` guards the queue; waiters block on the
/// scheduler. Lock order: object -> scheduler -> packets.
struct PortObject: ~Copyable {
    var header = ObjectHeader(type: .port)
    let packetsLock = SpinLock()
    var head: UInt64 = 0
    var tail: UInt64 = 0
    var queued = 0
    let waiters = QueuePointer.allocate()

    static var defaultRights: Rights { [.basic, .read, .write] }
}

@safe struct PortPointer {
    let object: ObjectPointer

    var pointee: PortObject {
        unsafeAddress { unsafe UnsafePointer<PortObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<PortObject>(bitPattern: UInt(object.address))! }
    }
}

enum Ports {
    static func create() throws(Status) -> ObjectPointer {
        guard let object = Objects.allocate(PortObject()) else { throw .noMemory }
        return object
    }

    static func destroy(_ object: ObjectPointer) {
        let port = PortPointer(object: object)
        while let record = pop(port) { release(record) }
        port.pointee.waiters.deallocate()
        Objects.free(object, as: PortObject.self)
    }

    /// Queues `record` and wakes one waiter. Any context; the caller may
    /// hold an object lock, or (kernel sources) the scheduler lock.
    static func enqueue(_ port: PortPointer, _ record: QueuedPacketPointer, schedulerLocked: Bool = false) {
        port.pointee.packetsLock.withLock {
            record.pointee.next = 0
            if port.pointee.tail != 0 {
                QueuedPacketPointer(address: port.pointee.tail).pointee.next = record.address
            } else {
                port.pointee.head = record.address
            }
            port.pointee.tail = record.address
            port.pointee.queued += 1
        }
        if schedulerLocked {
            Scheduler.wakeOne(port.pointee.waiters)
        } else {
            Scheduler.locked { _ = Scheduler.wakeOne(port.pointee.waiters) }
        }
    }

    private static func pop(_ port: PortPointer) -> QueuedPacketPointer? {
        port.pointee.packetsLock.withLock { () -> QueuedPacketPointer? in
            guard port.pointee.head != 0 else { return nil }
            let record = QueuedPacketPointer(address: port.pointee.head)
            port.pointee.head = record.pointee.next
            if port.pointee.head == 0 { port.pointee.tail = 0 }
            port.pointee.queued -= 1
            return record
        }
    }

    /// Frees a dequeued record, or hands it back to its kernel source.
    private static func release(_ record: QueuedPacketPointer) {
        if record.pointee.source != 0 {
            PacketSourcePointer(address: record.pointee.source).dequeued()
        } else {
            record.free()
        }
    }

    // MARK: Syscall-shaped operations

    /// port_queue: a user packet (its type is forced to user).
    static func queue(_ table: borrowing HandleTable, _ handle: UInt32, _ packet: PortPacket) throws(Status) {
        let ref = try table.get(handle, type: .port, rights: .write)
        var user = packet
        user.type = PortPacket.user
        enqueue(PortPointer(object: ref.object), try QueuedPacketPointer.allocate(user))
    }

    /// port_wait: the next packet, waiting until `deadline` (timedOut).
    static func wait(_ table: borrowing HandleTable, _ handle: UInt32, deadline: UInt64) throws(Status) -> PortPacket {
        let ref = try table.get(handle, type: .port, rights: .read)
        let port = PortPointer(object: ref.object)
        var record: QueuedPacketPointer? = nil
        Scheduler.locked {
            while true {
                if let next = pop(port) {
                    record = next
                    return
                }
                if Scheduler.block(on: port.pointee.waiters, deadline: deadline) == .timedOut, port.pointee.queued == 0 {
                    return
                }
            }
        }
        guard let record else { throw .timedOut }
        let packet = record.pointee.packet
        release(record)
        return packet
    }

    /// port_cancel: drops the waits `handle` registered with this port under
    /// `key`, and their packets still queued.
    static func cancel(_ table: borrowing HandleTable, port portHandle: UInt32, source handle: UInt32,
                       key: UInt64) throws(Status) {
        let portRef = try table.get(portHandle, type: .port, rights: .write)
        let source = try table.get(handle, rights: .wait)
        let port = PortPointer(object: portRef.object)
        source.object.header.lock.withLock {
            var previous: ObserverPointer? = nil
            var cursor = source.object.header.observers
            while let observer = cursor {
                cursor = observer.pointee.next
                if case .port(let p, let k, let packet, _) = observer.pointee.kind, p == port.object.address, k == key,
                   observer.pointee.table == table.address, observer.pointee.handle == handle {
                    if let previous { previous.pointee.next = observer.pointee.next } else { source.object.header.observers = observer.pointee.next }
                    QueuedPacketPointer(address: packet).free()
                    port.object.release()  // the observer's reference
                    unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(observer.address))!)
                } else {
                    previous = observer
                }
            }
        }
        // Packets already queued from that handle with that key.
        var removed = UniqueArray<QueuedPacketPointer>()
        port.pointee.packetsLock.withLock {
            var previous: UInt64 = 0
            var cursor = port.pointee.head
            while cursor != 0 {
                let record = QueuedPacketPointer(address: cursor)
                cursor = record.pointee.next
                if record.pointee.packet.key == key, record.pointee.originTable == table.address,
                   record.pointee.originHandle == handle {
                    if previous != 0 { QueuedPacketPointer(address: previous).pointee.next = record.pointee.next } else { port.pointee.head = record.pointee.next }
                    if port.pointee.tail == record.address { port.pointee.tail = previous }
                    port.pointee.queued -= 1
                    removed.append(record)
                } else {
                    previous = record.address
                }
            }
        }
        while let record = removed.popLast() { release(record) }
    }

    static var queuedCount: (borrowing ObjectRef) -> Int {
        { ref in PortPointer(object: ref.object).pointee.packetsLock.withLock { PortPointer(object: ref.object).pointee.queued } }
    }
}

// MARK: Kernel packet sources (ext 3, ext 6)

/// A kernel event that reports to a port (budget overruns, memory
/// pressure): it owns one packet, so firing never allocates and may happen
/// with the scheduler lock held. While its packet is still queued, further
/// events only raise the packet's count.
struct PacketSource: ~Copyable {
    let port: UInt64
    let record: QueuedPacketPointer
    var queued = false
    /// Its owner is gone; it goes when its queued packet is read.
    var retired = false
    let lock = SpinLock()
}

@safe struct PacketSourcePointer {
    let address: UInt64

    var pointee: PacketSource {
        unsafeAddress { unsafe UnsafePointer<PacketSource>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<PacketSource>(bitPattern: UInt(address))! }
    }

    /// A source reporting to `port` with `key` and packet `type`; holds a
    /// reference to the port.
    static func make(port: borrowing ObjectRef, key: UInt64, type: UInt32) throws(Status) -> PacketSourcePointer {
        guard port.type == .port else { throw .wrongType }
        guard let raw = unsafe heap.allocate(size: MemoryLayout<PacketSource>.size) else { throw .noMemory }
        let address = UInt64(UInt(bitPattern: raw))
        let record = try QueuedPacketPointer.allocate(PortPacket(key: key, type: type), source: address)
        port.object.retain()
        unsafe raw.bindMemory(to: PacketSource.self, capacity: 1)
            .initialize(to: PacketSource(port: port.object.address, record: record))
        return PacketSourcePointer(address: address)
    }

    /// Reports an event (value in payload[1]). Any context.
    func fire(value: UInt64, schedulerLocked: Bool = false) {
        let queue = pointee.lock.withLock { () -> Bool in
            pointee.record.pointee.packet.payload[1] = value
            pointee.record.pointee.packet.payload[2] += 1
            if pointee.queued { return false }
            pointee.queued = true
            return true
        }
        if queue {
            Ports.enqueue(PortPointer(object: ObjectPointer(address: pointee.port)), pointee.record,
                          schedulerLocked: schedulerLocked)
        }
    }

    /// Its packet was read: the next event queues it again, from count 0
    /// (or, retired, it goes now).
    func dequeued() {
        let gone = pointee.lock.withLock { () -> Bool in
            pointee.queued = false
            pointee.record.pointee.packet.payload[2] = 0
            return pointee.retired
        }
        if gone { free() }
    }

    /// The owner (a context, an account) no longer reports: freed now, or
    /// once its queued packet is read.
    func retire() {
        let now = pointee.lock.withLock { () -> Bool in
            pointee.retired = true
            return !pointee.queued
        }
        if now { free() }
    }

    private func free() {
        let port = ObjectPointer(address: pointee.port)
        pointee.record.free()
        let raw = unsafe UnsafeMutablePointer<PacketSource>(bitPattern: UInt(address))!
        unsafe raw.deinitialize(count: 1)
        unsafe heap.free(UnsafeMutableRawPointer(raw))
        port.release()
    }
}
