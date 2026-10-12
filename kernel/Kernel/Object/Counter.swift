import CKernel

/// A counter (K10a; Zircon's CounterDispatcher, type 34): a signed 64-bit
/// value with POSITIVE / NON_POSITIVE signals, plus croi's waits at a value
/// (Todhchai's item 15: the desktop's fences, Vulkan's timeline semaphores
/// later). Value waits are observers with a threshold (Observer.byValue),
/// so they share the signal waits' registration, cancellation on handle
/// close, port_cancel and port delivery. The header lock guards the value.
struct CounterObject: ~Copyable {
    var header = ObjectHeader(type: .counter)
    var value: Int64 = 0
    /// K10c: a deadline profile lent to the threads its value waits wake.
    var lend: Profile? = nil

    /// ZX_DEFAULT_COUNTER_RIGHTS.
    static var defaultRights: Rights { Rights.basic.union(.read | .write | .signal) }
}

@safe struct CounterPointer {
    let object: ObjectPointer

    var pointee: CounterObject {
        unsafeAddress { unsafe UnsafePointer<CounterObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<CounterObject>(bitPattern: UInt(object.address))! }
    }
}

enum Counters {
    static var positive: UInt32 { UInt32(CROI_COUNTER_POSITIVE) }
    static var nonPositive: UInt32 { UInt32(CROI_COUNTER_NON_POSITIVE) }

    static func create() throws(Status) -> ObjectPointer {
        guard let object = Objects.allocate(CounterObject()) else { throw .noMemory }
        object.header.signals = nonPositive  // 0
        return object
    }

    /// The value (object lock held: Observers.notify's view). A display
    /// timeline's is its vblank count (K10b), waited on the same way.
    static func valueLocked(_ object: ObjectPointer) -> Int64 {
        object.header.type == .timeline ? Timelines.valueLocked(object) : CounterPointer(object: object).pointee.value
    }

    static func read(_ object: ObjectPointer) -> Int64 {
        object.header.lock.withLock { valueLocked(object) }
    }

    /// A handle that can be waited on at a value: a counter or a timeline.
    static func waitable(_ table: borrowing HandleTable, _ handle: UInt32, rights: Rights) throws(Status) -> ObjectRef {
        let ref = try table.get(handle, rights: rights)
        guard ref.type == .counter || ref.type == .timeline else { throw .wrongType }
        return ref
    }

    /// counter_add: OUT_OF_RANGE (and no change) on overflow.
    static func add(_ object: ObjectPointer, _ amount: Int64) throws(Status) {
        try object.header.lock.withLock { () throws(Status) in
            let (sum, overflow) = CounterPointer(object: object).pointee.value.addingReportingOverflow(amount)
            guard !overflow else { throw .outOfRange }
            setLocked(object, sum)
        }
    }

    /// counter_write.
    static func write(_ object: ObjectPointer, _ value: Int64) {
        object.header.lock.withLock { setLocked(object, value) }
    }

    /// Sets the value and the signals, and runs the observers either
    /// satisfies (signal waits and value waits alike). Object lock held.
    private static func setLocked(_ object: ObjectPointer, _ value: Int64) {
        CounterPointer(object: object).pointee.value = value
        let signals = object.header.signals & ~(positive | nonPositive)
        object.header.signals = signals | (value > 0 ? positive : nonPositive)
        Observers.notify(object)
    }

    /// counter_wait: until the value is at least `target`, or `deadline`
    /// (TIMED_OUT), or the handle is closed (CANCELED).
    static func wait(_ table: borrowing HandleTable, _ handle: UInt32, target: Int64,
                     deadline: UInt64) throws(Status) {
        let ref = try waitable(table, handle, rights: .wait | .read)
        let object = ref.object
        let state = try WaitStatePointer.forCurrentThread()
        let observer = try object.header.lock.withLock { () throws(Status) -> ObserverPointer? in
            if valueLocked(object) >= target { return nil }
            var waiter = Observer(kind: .wait(state: state.address, index: 0), trigger: 0, table: table.address,
                                  handle: handle)
            waiter.byValue = true
            waiter.atValue = target
            let added = try Observers.add(object, waiter)
            if object.header.type == .timeline { Timelines.watchLocked(object) }
            return added
        }
        guard let observer else { return }
        // One scheduler-lock pass: wait, and read how it ended.
        enum End { case reached, canceled, timedOut }
        let end = Scheduler.locked { () -> End in
            while !state.pointee.done {
                let result = Scheduler.block(on: state.pointee.queue, deadline: deadline, interruptible: true)
                if result == .interrupted { return .canceled }  // the thread was killed; it won't see this
                if result == .timedOut, !state.pointee.done { return .timedOut }
            }
            return state.pointee.canceled ? .canceled : .reached
        }
        object.header.lock.withLock { Observers.remove(object, observer) }
        switch end {
        case .reached: return
        case .canceled: throw .canceled
        case .timedOut: throw .timedOut
        }
    }

    /// counter_wait_async: one CROI_PKT_TYPE_COUNTER packet to `port` with
    /// `key` once the value is at least `target` (now, if it is).
    static func waitAsync(_ table: borrowing HandleTable, _ handle: UInt32, port portHandle: UInt32, key: UInt64,
                          target: Int64) throws(Status) {
        let object = try waitable(table, handle, rights: .wait | .read)
        let port = try table.get(portHandle, type: .port, rights: .write)
        // Zircon raises at its observer limit and still registers (review fix).
        if Ports.overObserverLimit(port.object) {
            Policy.limitException(UInt32(CROI_EXCP_POLICY_CODE_PORT_TOO_MANY_OBSERVERS))
        }
        let record = try QueuedPacketPointer.allocate(PortPacket(key: key, type: UInt32(CROI_PKT_TYPE_COUNTER)),
                                                      table: table.address, handle: handle)
        port.object.retain()  // the observer's
        do throws(Status) {
            try object.object.header.lock.withLock { () throws(Status) in
                let value = valueLocked(object.object)
                if value >= target {
                    Observers.fireValuePort(port.object.address, record, target, value)
                    return
                }
                var observer = Observer(kind: .port(port: port.object.address, key: key, packet: record.address,
                                                    options: 0),
                                        trigger: 0, table: table.address, handle: handle)
                observer.byValue = true
                observer.atValue = target
                _ = try Observers.add(object.object, observer)
                if object.object.header.type == .timeline { Timelines.watchLocked(object.object) }
            }
        } catch {
            record.free()
            port.object.release()
            throw error
        }
    }
}
