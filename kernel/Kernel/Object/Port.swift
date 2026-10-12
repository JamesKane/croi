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
    /// An interrupt object's (payload[0]: timestamp).
    static var interrupt: UInt32 { 7 }
    /// Ext 3: a deadline reservation overran its budget (count in payload[2]).
    static var budgetOverrun: UInt32 { 0x80 }
    /// Ext 6: a memory account crossed its pressure level (bytes charged in
    /// payload[1], count in payload[2]).
    static var memoryPressure: UInt32 { 0x81 }
    /// K13d: a pager VMO's request (payload: command, offset, length).
    static var pageRequest: UInt32 { 9 }

    // Signal payload: trigger (low 32 of [0]), observed (high 32 of [0]), count, timestamp.
    var trigger: UInt32 { UInt32(truncatingIfNeeded: payload[0]) }
    var observed: UInt32 { UInt32(truncatingIfNeeded: payload[0] >> 32) }
    var count: UInt64 { payload[2] }
}

/// A queued packet. Owned by the queue (from wait_async or port_queue: freed
/// when dequeued), by a kernel packet source, or by an interrupt object
/// (both reused: never freed here).
struct QueuedPacket {
    var next: UInt64 = 0
    var packet: PortPacket
    /// 0, the PacketSource that owns this record, or `Ports.interruptOwned`.
    let source: UInt64
    /// An interrupt packet is on its port's interrupt list (packets lock).
    var interruptQueued = false
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
/// scheduler. Lock order: object -> scheduler -> packets. A port created
/// with BIND_TO_INTERRUPT also has interrupt objects' packets, on a list
/// of their own that is read first (Zircon's).
struct PortObject: ~Copyable {
    var header = ObjectHeader(type: .port)
    let packetsLock = SpinLock()
    var head: UInt64 = 0
    var tail: UInt64 = 0
    var queued = 0
    /// port_queue's packets among them (review fix: they had no bound;
    /// Zircon's limit is `Ports.maxUserPackets`).
    var userQueued = 0
    let waiters = QueuePointer.allocate()
    let bindToInterrupt: Bool
    var interruptHead: UInt64 = 0
    var interruptTail: UInt64 = 0
    /// K13e: the objects with async waits to this port, once per observer
    /// (port_cancel_key finds them here). Under `packetsLock`; an entry
    /// means an observer is registered, so the object is alive (objects
    /// lose their observers before their last reference: handle close).
    var watched = UniqueArray<UInt64>()

    /// ZX_DEFAULT_PORT_RIGHTS: no WAIT (ports are waited on with port_wait).
    static var defaultRights: Rights { Rights.basic.subtracting(.wait).union(.read | .write) }
}

extension QueuedPacketPointer {
    /// A port_queue packet: no source, no origin handle, not an interrupt's.
    var isUserPacket: Bool {
        pointee.source == 0 && pointee.originTable == 0 && pointee.packet.type == PortPacket.user
    }
}

@safe struct PortPointer {
    let object: ObjectPointer

    var pointee: PortObject {
        unsafeAddress { unsafe UnsafePointer<PortObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<PortObject>(bitPattern: UInt(object.address))! }
    }
}

enum Ports {
    /// `QueuedPacket.source` of an interrupt object's packet.
    static var interruptOwned: UInt64 { ~0 }

    static func create(options: UInt64 = 0) throws(Status) -> ObjectPointer {
        guard options & ~UInt64(CROI_PORT_BIND_TO_INTERRUPT) == 0 else { throw .invalidArgs }
        guard let object = Objects.allocate(PortObject(bindToInterrupt: options != 0)) else { throw .noMemory }
        return object
    }

    static func destroy(_ object: ObjectPointer) {
        let port = PortPointer(object: object)
        while let (_, record) = pop(port) {
            if let record { release(record) }
        }
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

    /// Takes a queued kernel-source packet back out (its source is retiring);
    /// false if a reader already took it (and will hand it back).
    static func unqueue(_ port: PortPointer, _ record: QueuedPacketPointer) -> Bool {
        port.pointee.packetsLock.withLock { () -> Bool in
            var previous: UInt64 = 0
            var cursor = port.pointee.head
            while cursor != 0 {
                let next = QueuedPacketPointer(address: cursor).pointee.next
                if cursor == record.address {
                    if previous != 0 {
                        QueuedPacketPointer(address: previous).pointee.next = next
                    } else {
                        port.pointee.head = next
                    }
                    if port.pointee.tail == cursor { port.pointee.tail = previous }
                    port.pointee.queued -= 1
                    return true
                }
                previous = cursor
                cursor = next
            }
            return false
        }
    }

    /// The next packet (interrupts first), copied under the lock, and its
    /// record if it needs `release` (an interrupt's stays its object's).
    private static func pop(_ port: PortPointer) -> (PortPacket, QueuedPacketPointer?)? {
        port.pointee.packetsLock.withLock { () -> (PortPacket, QueuedPacketPointer?)? in
            if port.pointee.interruptHead != 0 {
                let record = QueuedPacketPointer(address: port.pointee.interruptHead)
                port.pointee.interruptHead = record.pointee.next
                if port.pointee.interruptHead == 0 { port.pointee.interruptTail = 0 }
                record.pointee.interruptQueued = false
                port.pointee.queued -= 1
                return (record.pointee.packet, nil)
            }
            guard port.pointee.head != 0 else { return nil }
            let record = QueuedPacketPointer(address: port.pointee.head)
            port.pointee.head = record.pointee.next
            if port.pointee.head == 0 { port.pointee.tail = 0 }
            port.pointee.queued -= 1
            if record.isUserPacket { port.pointee.userQueued -= 1 }
            return (record.pointee.packet, record)
        }
    }

    /// Queues an interrupt object's packet with `timestamp` and wakes a
    /// waiter; false if it is still queued. Any context (interrupts too).
    static func queueInterrupt(_ port: PortPointer, _ record: QueuedPacketPointer, timestamp: UInt64) -> Bool {
        let queued = port.pointee.packetsLock.withLock { () -> Bool in
            guard !record.pointee.interruptQueued else { return false }
            record.pointee.interruptQueued = true
            record.pointee.packet.type = PortPacket.interrupt
            record.pointee.packet.status = 0
            record.pointee.packet.payload[0] = timestamp
            record.pointee.next = 0
            if port.pointee.interruptTail != 0 {
                QueuedPacketPointer(address: port.pointee.interruptTail).pointee.next = record.address
            } else {
                port.pointee.interruptHead = record.address
            }
            port.pointee.interruptTail = record.address
            port.pointee.queued += 1
            return true
        }
        if queued { Scheduler.locked { _ = Scheduler.wakeOne(port.pointee.waiters) } }
        return queued
    }

    /// Takes an interrupt object's packet off its port; false if it wasn't
    /// queued (already read).
    static func removeInterrupt(_ port: PortPointer, _ record: QueuedPacketPointer) -> Bool {
        port.pointee.packetsLock.withLock { () -> Bool in
            guard record.pointee.interruptQueued else { return false }
            var previous: UInt64 = 0
            var cursor = port.pointee.interruptHead
            while cursor != 0, cursor != record.address {
                previous = cursor
                cursor = QueuedPacketPointer(address: cursor).pointee.next
            }
            guard cursor != 0 else { return false }
            if previous != 0 {
                QueuedPacketPointer(address: previous).pointee.next = record.pointee.next
            } else {
                port.pointee.interruptHead = record.pointee.next
            }
            if port.pointee.interruptTail == record.address { port.pointee.interruptTail = previous }
            record.pointee.interruptQueued = false
            port.pointee.queued -= 1
            return true
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
    /// Zircon's per-port limits (kMaxAllocatedPacketCountPerPort, the
    /// kernel.port.max-observers default).
    static let maxUserPackets = 4096
    static let maxObservers = 50_000

    static func queue(_ table: borrowing HandleTable, _ handle: UInt32, _ packet: PortPacket) throws(Status) {
        let ref = try table.get(handle, type: .port, rights: .write)
        let port = PortPointer(object: ref.object)
        var user = packet
        user.type = PortPacket.user
        let record = try QueuedPacketPointer.allocate(user)
        let full = port.pointee.packetsLock.withLock { () -> Bool in
            guard port.pointee.userQueued <= maxUserPackets else { return true }
            port.pointee.userQueued += 1
            return false
        }
        guard !full else {
            record.free()
            // The caller sees the exception; unhandled, it is killed.
            Policy.limitException(UInt32(CROI_EXCP_POLICY_CODE_PORT_TOO_MANY_PACKETS))
            throw .shouldWait
        }
        enqueue(port, record)
    }

    /// A wait_async to `port` would be its `maxObservers`th or more.
    static func overObserverLimit(_ port: ObjectPointer) -> Bool {
        let p = PortPointer(object: port)
        return p.pointee.packetsLock.withLock { p.pointee.watched.count >= maxObservers }
    }

    /// port_wait: the next packet, waiting until `deadline` (timedOut).
    static func wait(_ table: borrowing HandleTable, _ handle: UInt32, deadline: UInt64) throws(Status) -> PortPacket {
        let ref = try table.get(handle, type: .port, rights: .read)
        let port = PortPointer(object: ref.object)
        var popped: (PortPacket, QueuedPacketPointer?)? = nil
        Scheduler.locked {
            while true {
                if let next = pop(port) {
                    popped = next
                    return
                }
                let result = Scheduler.block(on: port.pointee.waiters, deadline: deadline, interruptible: true)
                if result == .interrupted || (result == .timedOut && port.pointee.queued == 0) { return }
            }
        }
        guard let (packet, record) = popped else { throw .timedOut }
        if let record { release(record) }
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
                    untrack(p, source.object)
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

    /// An async wait on `object` to `port` was added / went. Object lock held.
    static func track(_ port: UInt64, _ object: ObjectPointer) {
        let p = PortPointer(object: ObjectPointer(address: port))
        p.pointee.packetsLock.withLock { p.pointee.watched.append(object.address) }
    }

    static func untrack(_ port: UInt64, _ object: ObjectPointer) {
        let p = PortPointer(object: ObjectPointer(address: port))
        p.pointee.packetsLock.withLock {
            for i in 0..<p.pointee.watched.count where p.pointee.watched[i] == object.address {
                _ = p.pointee.watched.remove(at: i)
                return
            }
        }
    }

    /// port_cancel_key (K13e): every async wait to this port with `key`,
    /// whatever its source, and every queued packet with it (user packets
    /// too; not kernel sources' or interrupts'). NOT_FOUND if none.
    static func cancelKey(_ table: borrowing HandleTable, port portHandle: UInt32, options: UInt64,
                          key: UInt64) throws(Status) {
        guard options == 0 else { throw .invalidArgs }
        let portRef = try table.get(portHandle, type: .port, rights: .write)
        let port = PortPointer(object: portRef.object)
        var objects = UniqueArray<UInt64>()
        port.pointee.packetsLock.withLock {
            for i in 0..<port.pointee.watched.count {
                let address = port.pointee.watched[i]
                var seen = false
                for j in 0..<objects.count where objects[j] == address { seen = true }
                if !seen, ObjectPointer(address: address).tryRetain() { objects.append(address) }
            }
        }
        var found = false
        for i in 0..<objects.count {
            let source = ObjectPointer(address: objects[i])
            source.header.lock.withLock {
                var previous: ObserverPointer? = nil
                var cursor = source.header.observers
                while let observer = cursor {
                    cursor = observer.pointee.next
                    if case .port(let p, let k, let packet, _) = observer.pointee.kind, p == port.object.address, k == key {
                        if let previous { previous.pointee.next = observer.pointee.next } else { source.header.observers = observer.pointee.next }
                        untrack(p, source)
                        QueuedPacketPointer(address: packet).free()
                        port.object.release()  // the observer's reference
                        unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(observer.address))!)
                        found = true
                    } else {
                        previous = observer
                    }
                }
            }
            source.release()
        }
        var removed = UniqueArray<QueuedPacketPointer>()
        port.pointee.packetsLock.withLock {
            var previous: UInt64 = 0
            var cursor = port.pointee.head
            while cursor != 0 {
                let record = QueuedPacketPointer(address: cursor)
                cursor = record.pointee.next
                if record.pointee.packet.key == key, record.pointee.source == 0 {
                    if previous != 0 { QueuedPacketPointer(address: previous).pointee.next = record.pointee.next } else { port.pointee.head = record.pointee.next }
                    if port.pointee.tail == record.address { port.pointee.tail = previous }
                    port.pointee.queued -= 1
                    if record.isUserPacket { port.pointee.userQueued -= 1 }
                    removed.append(record)
                } else {
                    previous = record.address
                }
            }
        }
        if removed.count > 0 { found = true }
        while let record = removed.popLast() { release(record) }
        guard found else { throw .notFound }
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

    /// Reports an event (value in payload[1]; `word0` and `word3`, if
    /// given, in payload[0] and [3]). Any context.
    func fire(value: UInt64, word0: UInt64? = nil, word3: UInt64? = nil, schedulerLocked: Bool = false) {
        let queue = pointee.lock.withLock { () -> Bool in
            if let word0 { pointee.record.pointee.packet.payload[0] = word0 }
            if let word3 { pointee.record.pointee.packet.payload[3] = word3 }
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
    /// Its owner is going. A packet still queued is taken back (nobody may
    /// ever read it, and it holds the port); one a reader has already
    /// taken is freed when handed back (`dequeued`).
    func retire() {
        let now = pointee.lock.withLock { () -> Bool in
            pointee.retired = true
            if pointee.queued,
               Ports.unqueue(PortPointer(object: ObjectPointer(address: pointee.port)), pointee.record) {
                pointee.queued = false
            }
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
