import CKernel
import Synchronization

/// Timer objects (K7c, requirement 10; Zircon's TimerDispatcher): an
/// absolute deadline plus slack, SIGNALED when it fires. A set arms the
/// object's own kernel timer node on the calling CPU (so it never fails),
/// holding a reference to the object; a generation number makes a callback
/// from an older set harmless, and a cancel takes the node out of the
/// arming CPU's queue from wherever it runs. Threads on a deadline profile
/// always get zero slack ("RT profiles get zero slack"). The last handle's
/// close cancels it, as Zircon's on_zero_handles does.
struct TimerObject: ~Copyable {
    var header = ObjectHeader(type: .timer)
    /// Zircon's ZX_TIMER_SLACK_CENTER (0), EARLY (1), LATE (2).
    let slackPolicy: UInt32
    var generation: UInt64 = 0
    /// The CPU the node is armed on, or -1.
    var armedCpu = -1
    var node = TimerNode()
    /// One set or cancel at a time (a set is a cancel, then an arm): a
    /// blocking lock, so a deadline thread waits by lending its profile,
    /// not by yielding (a yield ends its period: a period's wait per try).
    let configuring = Mutex()

    static var defaultRights: Rights { .basic | .write | .signal }
}

@safe struct TimerObjectPointer {
    let object: ObjectPointer

    var pointee: TimerObject {
        unsafeAddress { unsafe UnsafePointer<TimerObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<TimerObject>(bitPattern: UInt(object.address))! }
    }

    var node: TimerNodePointer {
        withUnsafeMutablePointer(to: &pointee.node) { unsafe TimerNodePointer($0) }
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
    static func set(_ object: ObjectPointer, deadline: UInt64, slack: UInt64) {
        let timer = TimerObjectPointer(object: object)
        // One hold of `configuring` from the cancel to the arm (review fix:
        // two sets could both cancel, then both arm the node: a panic).
        configure(timer) {
            cancelArmed(timer)
            object.updateSignals(clear: Signals.signaled, set: 0)
            arm(timer, object, deadline: deadline, slack: slack)
        }
    }

    private static func arm(_ timer: TimerObjectPointer, _ object: ObjectPointer, deadline: UInt64, slack: UInt64) {
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
        object.header.lock.withLock {
            timer.pointee.generation += 1
            Timers.arm(timer.node, deadline: start, slack: window, fired, object.address,
                       context: timer.pointee.generation)
            timer.pointee.armedCpu = Int(Cpu.current)
        }
    }

    /// timer_cancel: disarms, and de-asserts SIGNALED, as Zircon's does (a
    /// timer that already fired is clear again). After `cancelArmed`, whose
    /// new generation stops a firing in flight from setting it again.
    static func cancel(_ object: ObjectPointer) {
        let timer = TimerObjectPointer(object: object)
        configure(timer) {
            cancelArmed(timer)
            object.updateSignals(clear: Signals.signaled, set: 0)
        }
    }

    private static func configure<R>(_ timer: TimerObjectPointer, _ body: () -> R) -> R {
        timer.pointee.configuring.withLock(body)
    }

    /// The last handle is gone: disarmed (Zircon's on_zero_handles), so
    /// the armed timer's reference doesn't keep it until it fires.
    static func lastHandleClosed(_ object: ObjectPointer) {
        cancelArmed(TimerObjectPointer(object: object))
    }

    /// Disarms the current set, if any (configuring held, or the last
    /// handle gone). A kernel timer that hadn't fired gives its reference
    /// to us to drop; one already firing finds a new generation and drops
    /// its own.
    private static func cancelArmed(_ timer: TimerObjectPointer) {
        let object = timer.object
        let cancelled = object.header.lock.withLock { () -> Bool in
            let cpu = timer.pointee.armedCpu
            timer.pointee.armedCpu = -1
            timer.pointee.generation += 1  // a callback already in flight does nothing
            return cpu >= 0 && Timers.cancel(timer.node, on: cpu)
        }
        if cancelled { object.release() }
    }

    private static let fired: Timers.Callback = { address, generation in
        let object = ObjectPointer(address: address)
        let timer = TimerObjectPointer(object: object)
        let current = object.header.lock.withLock { () -> Bool in
            guard timer.pointee.generation == generation else { return false }
            timer.pointee.armedCpu = -1
            return true
        }
        if current { object.updateSignals(clear: 0, set: Signals.signaled) }
        object.release()
    }
}
