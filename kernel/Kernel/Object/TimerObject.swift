import CKernel
import Synchronization

/// Timer objects (K7c, requirement 10; Zircon's TimerDispatcher): an
/// absolute deadline plus slack, SIGNALED when it fires. A set arms a
/// per-CPU kernel timer on the calling CPU, holding a reference to the
/// object; a generation number makes a callback from an older set
/// harmless, and a cancel reaches the arming CPU by IPI. Threads on a
/// deadline profile always get zero slack ("RT profiles get zero slack").
///
/// Not yet: an armed timer whose last handle closes stays until it fires
/// (Zircon cancels on zero handles), and the per-CPU kernel timer queue is
/// a fixed 32 entries (NO_RESOURCES when full) until K3's intrusive queue.
struct TimerObject: ~Copyable {
    var header = ObjectHeader(type: .timer)
    /// Zircon's ZX_TIMER_SLACK_CENTER (0), EARLY (1), LATE (2).
    let slackPolicy: UInt32
    var generation: UInt64 = 0
    var armedId: UInt32 = 0
    var armedCpu = -1
    /// The kernel timer a cancel IPI is for.
    var cancelId: UInt32 = 0
    /// One set or cancel at a time.
    let configuring = Atomic<Bool>(false)

    static var defaultRights: Rights { [.basic, .write, .signal] }
}

@safe struct TimerObjectPointer {
    let object: ObjectPointer

    var pointee: TimerObject {
        unsafeAddress { unsafe UnsafePointer<TimerObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<TimerObject>(bitPattern: UInt(object.address))! }
    }
}

enum TimerObjects {
    static func create(slackPolicy: UInt32) throws(Status) -> ObjectPointer {
        guard slackPolicy <= 2 else { throw .invalidArgs }
        guard let object = Objects.allocate(TimerObject(slackPolicy: slackPolicy)) else { throw .noMemory }
        return object
    }

    /// timer_set: fires at `deadline`, within `slack` as the timer's policy
    /// places it. Replaces any earlier set.
    static func set(_ object: ObjectPointer, deadline: UInt64, slack: UInt64) throws(Status) {
        let timer = TimerObjectPointer(object: object)
        configure(timer) {
            cancelArmed(timer)
        }
        object.updateSignals(clear: Signals.signaled, set: 0)
        let width = Scheduler.effectiveProfile(of: Scheduler.current).discipline == .deadline ? 0 : slack
        let start: UInt64, window: UInt64
        switch timer.pointee.slackPolicy {
        case 1: (start, window) = (deadline > width ? deadline - width : 0, width)  // early
        case 2: (start, window) = (deadline, width)                                 // late
        default:                                                                     // center
            (start, window) = (deadline > width ? deadline - width : 0, width.multipliedReportingOverflow(by: 2).overflow
                               ? .max : 2 * width)
        }
        object.retain()  // the armed kernel timer's
        let armed = configure(timer) { () -> Bool in
            object.header.lock.withLock { () -> Bool in
                timer.pointee.generation += 1
                guard let id = Timers.arm(deadline: start, slack: window, fired, object.address,
                                          context: timer.pointee.generation) else { return false }
                timer.pointee.armedId = id
                timer.pointee.armedCpu = Int(Cpu.current)
                return true
            }
        }
        guard armed else {
            object.release()
            throw .noResources
        }
    }

    /// timer_cancel.
    static func cancel(_ object: ObjectPointer) {
        let timer = TimerObjectPointer(object: object)
        configure(timer) { cancelArmed(timer) }
    }

    private static func configure<R>(_ timer: TimerObjectPointer, _ body: () -> R) -> R {
        while timer.pointee.configuring.exchange(true, ordering: .acquiring) { Scheduler.yield() }
        let result = body()
        timer.pointee.configuring.store(false, ordering: .releasing)
        return result
    }

    /// Disarms the current set, if any (configuring held).
    private static func cancelArmed(_ timer: TimerObjectPointer) {
        let object = timer.object
        let (id, cpu) = object.header.lock.withLock { () -> (UInt32, Int) in
            let armed = (timer.pointee.armedId, timer.pointee.armedCpu)
            timer.pointee.armedId = 0
            timer.pointee.armedCpu = -1
            timer.pointee.generation += 1  // a callback already in flight does nothing
            return armed
        }
        guard id != 0 else { return }
        timer.pointee.cancelId = id
        _ = Ipi.call(onCpu: cpu, cancelHere, object.address)
    }

    /// On the arming CPU: if the kernel timer hadn't fired, its reference
    /// is ours to drop (otherwise the callback drops it).
    private static let cancelHere: Ipi.Function = { address in
        let object = ObjectPointer(address: address)
        if Timers.cancel(TimerObjectPointer(object: object).pointee.cancelId) { object.release() }
    }

    private static let fired: Timers.Callback = { address, generation in
        let object = ObjectPointer(address: address)
        let timer = TimerObjectPointer(object: object)
        let current = object.header.lock.withLock { () -> Bool in
            guard timer.pointee.generation == generation else { return false }
            timer.pointee.armedId = 0
            timer.pointee.armedCpu = -1
            return true
        }
        if current { object.updateSignals(clear: 0, set: Signals.signaled) }
        object.release()
    }
}
