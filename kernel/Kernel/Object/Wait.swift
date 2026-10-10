import CKernel
import Synchronization

/// One registered wait on an object (Zircon's SignalObserver): a thread in
/// `object_wait_one`/`wait_many` (K5b adds port packets). Heap records,
/// linked from the object's header, guarded by the object's lock.
struct Observer {
    enum Kind {
        /// A waiting thread: its WaitState, and its item index.
        case wait(state: UInt64, index: Int)
        /// object_wait_async: queue `packet` (allocated up front) to `port`
        /// with `key`, once. Holds a reference to the port.
        case port(port: UInt64, key: UInt64, packet: UInt64, options: UInt32)
    }

    var next: ObserverPointer?
    let kind: Kind
    /// Signals that satisfy it.
    let trigger: UInt32
    /// The handle it was registered through (cancelled when that closes).
    let table: UInt64
    let handle: UInt32
}

@safe struct ObserverPointer: Equatable {
    let address: UInt64

    var pointee: Observer {
        unsafeAddress { unsafe UnsafePointer<Observer>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<Observer>(bitPattern: UInt(address))! }
    }
}

/// A waiting thread's state: where it blocks, and what woke it. Heap, so
/// that it outlives every observer that may touch it (they are removed,
/// under their objects' locks, before it is freed). Scheduler lock.
struct WaitState {
    var queue: QueuePointer
    var done = false
    var canceled = false
    var firedIndex = -1
}

@safe struct WaitStatePointer {
    let address: UInt64

    var pointee: WaitState {
        unsafeAddress { unsafe UnsafePointer<WaitState>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<WaitState>(bitPattern: UInt(address))! }
    }

    static func allocate() throws(Status) -> WaitStatePointer {
        guard let raw = unsafe heap.allocate(size: MemoryLayout<WaitState>.size) else { throw .noMemory }
        unsafe raw.bindMemory(to: WaitState.self, capacity: 1).initialize(to: WaitState(queue: QueuePointer.allocate()))
        return WaitStatePointer(address: UInt64(UInt(bitPattern: raw)))
    }

    func free() {
        pointee.queue.deallocate()
        unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(address))!)
    }

    /// Marks the wait finished (by `index`, or canceled) and wakes the
    /// thread. Any context with the object lock held.
    func finish(index: Int, canceled: Bool) {
        Scheduler.locked {
            guard !pointee.done else { return }
            pointee.done = true
            pointee.canceled = canceled
            pointee.firedIndex = index
            Scheduler.wakeAll(pointee.queue)
        }
    }
}

enum Observers {
    static var edge: UInt32 { 1 << 1 }       // ZX_WAIT_ASYNC_EDGE
    static var timestamp: UInt32 { 1 << 0 }  // ZX_WAIT_ASYNC_TIMESTAMP

    /// Runs every observer `object`'s current signals satisfy; port
    /// observers fire once and go. Object lock held.
    static func notify(_ object: ObjectPointer) {
        let signals = object.header.signals
        var previous: ObserverPointer? = nil
        var cursor = object.header.observers
        while let observer = cursor {
            cursor = observer.pointee.next
            guard observer.pointee.trigger & signals != 0 else {
                previous = observer
                continue
            }
            switch observer.pointee.kind {
            case .wait(let state, let index):
                WaitStatePointer(address: state).finish(index: index, canceled: false)
                previous = observer
            case .port(let port, _, let packet, let options):
                if let previous { previous.pointee.next = observer.pointee.next } else { object.header.observers = observer.pointee.next }
                firePort(port, QueuedPacketPointer(address: packet), observer.pointee.trigger, signals, options)
                unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(observer.address))!)
            }
        }
    }

    private static func firePort(_ port: UInt64, _ record: QueuedPacketPointer, _ trigger: UInt32,
                                 _ observed: UInt32, _ options: UInt32) {
        record.pointee.packet.payload[0] = UInt64(observed) << 32 | UInt64(trigger)
        record.pointee.packet.payload[1] = 1  // count
        if options & timestamp != 0 { record.pointee.packet.payload[2] = Clock.now() }
        let pointer = ObjectPointer(address: port)
        Ports.enqueue(PortPointer(object: pointer), record)
        pointer.release()  // the observer's reference; the queue keeps the port alive
    }

    /// object_wait_async: a one-shot packet to `port` with `key` when
    /// `handle`'s object has any of `signals` (now, unless `edge`).
    static func waitAsync(_ table: borrowing HandleTable, _ handle: UInt32, port portHandle: UInt32, key: UInt64,
                          signals: UInt32, options: UInt32) throws(Status) {
        guard options & ~(edge | timestamp) == 0 else { throw .invalidArgs }
        let object = try table.get(handle, rights: .wait)
        let port = try table.get(portHandle, type: .port, rights: .write)
        let record = try QueuedPacketPointer.allocate(PortPacket(key: key, type: PortPacket.signalOne),
                                                      table: table.address, handle: handle)
        port.object.retain()  // the observer's
        do throws(Status) {
            try object.object.header.lock.withLock { () throws(Status) in
                if options & edge == 0, object.object.header.signals & signals != 0 {
                    firePort(port.object.address, record, signals, object.object.header.signals, options)
                    return
                }
                _ = try add(object.object, Observer(kind: .port(port: port.object.address, key: key,
                                                               packet: record.address, options: options),
                                                   trigger: signals, table: table.address, handle: handle))
            }
        } catch {
            record.free()
            port.object.release()
            throw error
        }
    }

    /// Adds an observer. Object lock held.
    static func add(_ object: ObjectPointer, _ observer: Observer) throws(Status) -> ObserverPointer {
        guard let raw = unsafe heap.allocate(size: MemoryLayout<Observer>.size) else { throw .noMemory }
        var record = observer
        record.next = object.header.observers
        unsafe raw.bindMemory(to: Observer.self, capacity: 1).initialize(to: record)
        let pointer = ObserverPointer(address: UInt64(UInt(bitPattern: raw)))
        object.header.observers = pointer
        return pointer
    }

    /// Unlinks and frees an observer if it is still there. Object lock held.
    static func remove(_ object: ObjectPointer, _ observer: ObserverPointer) {
        var previous: ObserverPointer? = nil
        var cursor = object.header.observers
        while let current = cursor {
            if current == observer {
                if let previous { previous.pointee.next = current.pointee.next } else { object.header.observers = current.pointee.next }
                unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(current.address))!)
                return
            }
            previous = current
            cursor = current.pointee.next
        }
    }

    /// The handle `handle` of `table` closed: its waits are canceled (the
    /// waiting threads remove their own observers; async waits just go).
    static func handleClosed(_ object: ObjectPointer, table: UInt64, handle: UInt32) {
        object.header.lock.withLock {
            var previous: ObserverPointer? = nil
            var cursor = object.header.observers
            while let observer = cursor {
                cursor = observer.pointee.next
                guard observer.pointee.table == table, observer.pointee.handle == handle else {
                    previous = observer
                    continue
                }
                switch observer.pointee.kind {
                case .wait(let state, let index):
                    WaitStatePointer(address: state).finish(index: index, canceled: true)
                    previous = observer
                case .port(let port, _, let packet, _):
                    if let previous { previous.pointee.next = observer.pointee.next } else { object.header.observers = observer.pointee.next }
                    QueuedPacketPointer(address: packet).free()
                    ObjectPointer(address: port).release()
                    unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(observer.address))!)
                }
            }
        }
    }
}

/// `object_wait_one` and `object_wait_many` (Zircon semantics: level
/// triggered; the observed signals are returned whatever the outcome).
enum ObjectWait {
    static var maxItems: Int { 64 }  // ZX_WAIT_MANY_MAX_ITEMS

    /// Waits until `handle`'s object has any of `signals`, or `deadline`.
    /// Returns the observed signals; throws timedOut (or canceled, if the
    /// handle is closed meanwhile) with them in `observed`.
    static func one(_ table: borrowing HandleTable, _ handle: UInt32, signals: UInt32, deadline: UInt64,
                    observed: inout UInt32) throws(Status) {
        var items = InlineArray<1, WaitItem>(repeating: WaitItem(handle: handle, waitFor: signals))
        var span = items.mutableSpan
        defer { observed = items[0].pending }
        try many(table, &span, deadline: deadline)
    }

    struct WaitItem {
        var handle: UInt32
        var waitFor: UInt32
        var pending: UInt32 = 0
    }

    /// Waits until any item's object has any of its signals, or `deadline`;
    /// every item's `pending` is filled in either way.
    static func many(_ table: borrowing HandleTable, _ items: inout MutableSpan<WaitItem>,
                     deadline: UInt64) throws(Status) {
        guard items.count > 0, items.count <= maxItems else { throw .invalidArgs }
        var objects = InlineArray<64, UInt64>(repeating: 0)
        var observers = InlineArray<64, UInt64>(repeating: 0)
        defer {
            for i in 0..<items.count where objects[i] != 0 { ObjectPointer(address: objects[i]).release() }
        }
        for i in 0..<items.count {
            let ref = try table.get(items[i].handle, rights: .wait)
            ref.object.retain()
            objects[i] = ref.object.address
        }
        let state = try WaitStatePointer.allocate()
        defer { state.free() }

        // Register on each object, unless one is already satisfied.
        var satisfied = false
        for i in 0..<items.count where !satisfied {
            let object = ObjectPointer(address: objects[i])
            try object.header.lock.withLock { () throws(Status) in
                if object.header.signals & items[i].waitFor != 0 {
                    satisfied = true
                    return
                }
                observers[i] = try Observers.add(object, Observer(
                    kind: .wait(state: state.address, index: i), trigger: items[i].waitFor,
                    table: table.address, handle: items[i].handle)).address
            }
        }
        var timedOut = false
        var interrupted = false
        if !satisfied {
            Scheduler.locked {
                while !state.pointee.done {
                    let result = Scheduler.block(on: state.pointee.queue, deadline: deadline, interruptible: true)
                    if result == .interrupted {
                        interrupted = true
                        return
                    }
                    if result == .timedOut, !state.pointee.done {
                        timedOut = true
                        return
                    }
                }
            }
        }
        // Unregister, and report each object's signals now.
        for i in 0..<items.count {
            let object = ObjectPointer(address: objects[i])
            object.header.lock.withLock {
                if observers[i] != 0 { Observers.remove(object, ObserverPointer(address: observers[i])) }
                items[i].pending = object.header.signals
            }
        }
        if Scheduler.locked({ state.pointee.canceled }) {
            for i in 0..<items.count { items[i].pending |= Signals.handleClosed }
            throw .canceled
        }
        if interrupted { throw .canceled }  // killed: it exits on the way out
        if timedOut { throw .timedOut }
    }
}
