import CKernel
import Fmt
import Synchronization

/// One CPU's scheduling state (scheduler lock).
struct CpuScheduler {
    var current: ThreadPointer?
    var idle: ThreadPointer?
    /// The thread just switched away from, for `finishSwitch`.
    var previous: ThreadPointer?
    /// Runnable threads: fair by virtual runtime, deadline by absolute
    /// deadline, and deadline threads waiting for their next period.
    var fair = QueueHead()
    var deadline = QueueHead()
    var throttled = QueueHead()
    /// Takes threads (its idle thread exists).
    var ready = false
    /// The running thread's slice or budget timer, 0 when none is armed.
    var sliceTimer: UInt32 = 0
    /// The user address space whose tables are loaded here, if any.
    var activeAspace: UserAspacePointer?
    /// The PKRU loaded here (amd64 with PKU).
    var pkru: UInt32 = 0
    /// Wakes the CPU when the first throttled thread's period starts.
    var eligibilityTimer: UInt32 = 0
    var eligibilityAt: UInt64 = 0
    /// Never decreases; woken fair threads start near it.
    var minVruntime: UInt64 = 0
    /// Processing rate, 1024 = the reference (biggest) core.
    var capacity: UInt64 = 1024
    /// Reservation tag (ext 8): 0, or the only tag whose threads run here.
    var reservation: UInt32 = 0
    /// Admitted deadline utilization in this CPU's own time.
    var admitted: UInt64 = 0
    /// Published for the power service (KP): how long this CPU may take
    /// to wake without breaking an admitted deadline, and the fraction of
    /// its capacity admitted work needs (SchedScale.one = all of it).
    var wakeLatencyBound: UInt64 = .max
    var frequencyFloor: UInt64 = 0
    var switches: UInt64 = 0

    var hasRunnable: Bool { !fair.isEmpty || !deadline.isEmpty }
    var queuedCount: Int { fair.count + deadline.count + throttled.count }
}

/// Kernel threads on per-CPU run queues: fair (weighted virtual runtime)
/// plus deadline (EDF over CBS reservations), Zircon's two disciplines.
///
/// Mechanism (K3a): one scheduler lock, switching, blocking with timeouts,
/// wakeup placement and preemption. Policy (K3c):
/// - An eligible deadline thread runs before any fair one, earliest
///   absolute deadline first. Its budget is charged in capacity-scaled
///   time; when it runs out the thread waits for its next period
///   (throttled), and the context counts an overrun (ext 3).
/// - Fair threads run in order of virtual runtime (ns used x 1024 /
///   weight), each for a slice of the target latency in proportion to its
///   weight, at least the minimum granularity.
/// - Deadline reservations are admitted on one CPU, with a reason when
///   refused (ext 4), and never migrate. CPUs can be reserved for a tag
///   (ext 8).
/// - Priority inheritance carries profiles (Zircon's rules).
///
/// Locking: one global lock (Zircon's thread_lock) protects every thread
/// record, run queue, wait queue and context. It is taken with interrupts
/// masked and handed across a context switch: the thread that resumes
/// releases it (`finishSwitch`). Never hold another spinlock while taking
/// it, and never send a waiting IPI (`Ipi.call`) while holding it, since
/// the target may be spinning on it with interrupts masked.
///
/// Preemption: a request sets this CPU's bit in `preemptPending` (slice or
/// budget expiry, a period starting, a wakeup that should run first, a
/// reschedule IPI). It is acted on when an interrupt returns, or when a
/// `locked` section ends with interrupts on.
enum Scheduler {
    static let lock = SpinLock()
    static var targetLatency: UInt64 { 16_000_000 }      // ns (Zircon's default)
    static var minimumGranularity: UInt64 { 750_000 }    // ns
    /// Admitted deadline utilization per CPU stays below this, leaving
    /// room for fair threads and interrupts.
    static var admissionBound: UInt64 { SchedScale.one * 85 / 100 }

    nonisolated(unsafe) private static var cpus = InlineArray<64, CpuScheduler>(repeating: CpuScheduler())
    private static let preemptPending = Atomic<UInt64>(0)
    /// Dead detached threads awaiting `reapZombies`.
    nonisolated(unsafe) private static var zombies = QueueHead()
    /// Threads waiting in `join` (woken whenever a joinable thread dies).
    nonisolated(unsafe) private static var exitWaiters = QueuePointer(address: 0)
    private static let started = Atomic<Bool>(false)
    /// Thread records allocated and not yet freed (idle threads included).
    static let threadCount = Atomic<Int>(0)
    /// Every thread record, linked through `allNext` (scheduler lock).
    nonisolated(unsafe) private static var allThreads: ThreadPointer?
    nonisolated(unsafe) private static var nextTraceId: UInt32 = 0
    /// CPUs whose capacity or power hints changed and aren't in the shared
    /// pages yet (published once the scheduler lock is dropped).
    nonisolated(unsafe) private static var publishPending: UInt64 = 0
    /// Every scheduling context, linked through `next`.
    nonisolated(unsafe) private static var contexts: SchedContextPointer?

    // MARK: Bring-up

    /// The boot CPU: the code running now becomes the "bootstrap" thread
    /// (it may block, unlike an idle thread), and CPU 0 gets an idle thread.
    /// Every CPU's capacity starts from its core type.
    static func initializeBootCpu(stack: StackRange) {
        exitWaiters = QueuePointer.allocate()
        var estimates = InlineArray<64, UInt64>(repeating: 1024)
        var biggest: UInt64 = 1
        for cpu in 0..<Smp.count {
            estimates[cpu] = CoreCapacity.estimate(coreType: CpuTopologies.topology(cpu).coreType)
            biggest = max(biggest, estimates[cpu])
        }
        let bootstrap = makeRecord(name: "bootstrap", stack: stack, ownsStack: false, entry: nil, argument: 0,
                                   isIdle: false, priority: Thread.defaultPriority, affinity: allCpus, cpu: 0)
        bootstrap.pointee.state = .running
        bootstrap.pointee.detached = true
        bootstrap.pointee.cpusSeen = 1
        let idleStack: StackRange
        do throws(VmError) {
            idleStack = try KernelStack().keepForever()
        } catch {
            panic("sched: no memory for an idle stack")
        }
        let idle = makeRecord(name: "idle", stack: idleStack, ownsStack: false, entry: idleEntry, argument: 0,
                              isIdle: true, priority: 0, affinity: 1, cpu: 0)
        idle.pointee.savedSp = arch_thread_prepare(idleStack.top, idle.address)
        let saved = arch_interrupts_save()
        lock.lockMasked()
        for cpu in 0..<Smp.count {
            cpus[cpu].capacity = max(1, estimates[cpu] * SchedScale.capacityOne / biggest)
        }
        cpus[0].current = bootstrap
        unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!.pointee.traceThread = bootstrap.pointee.traceId
        cpus[0].idle = idle
        cpus[0].ready = true
        bootstrap.pointee.runStart = Clock.now()
        lock.unlockMasked()
        arch_interrupts_restore(saved)
        started.store(true, ordering: .releasing)
    }

    /// A secondary CPU: the code running now becomes its idle thread.
    static func becomeIdle(stack: StackRange) -> Never {
        let me = Int(Cpu.current)
        let idle = makeRecord(name: "idle", stack: stack, ownsStack: false, entry: nil, argument: 0,
                              isIdle: true, priority: 0, affinity: 1 << UInt64(me), cpu: me)
        idle.pointee.state = .running
        _ = arch_interrupts_save()
        lock.lockMasked()
        cpus[me].current = idle
        cpus[me].idle = idle
        cpus[me].ready = true
        lock.unlockMasked()
        idleLoop()
    }

    private static let idleEntry: Thread.Entry = { _ in
        _ = arch_interrupts_save()
        idleLoop()
    }

    /// Runs whatever is runnable here, frees dead threads, and otherwise
    /// waits for an interrupt. Interrupts stay masked except while waiting.
    private static func idleLoop() -> Never {
        let me = Int(Cpu.current)
        while true {
            reapZombies()
            lock.lockMasked()
            refreshEligibility(me, Clock.now())
            // Loop: coming back here, `finishSwitch` may have just made a
            // thread ready on this CPU (a joiner woken by an exit), with
            // only a local request and no IPI to end the wait below.
            while cpus[me].hasRunnable {
                switchAway()
                refreshEligibility(me, Clock.now())
            }
            lock.unlockMasked()
            // A wakeup aimed here after the check above sends an IPI, and a
            // throttled thread's period start has a timer: either ends the
            // wait.
            arch_wait_for_interrupt()
        }
    }

    private static var allCpus: UInt64 { Smp.count >= 64 ? .max : (1 << UInt64(Smp.count)) - 1 }

    // MARK: Threads

    /// Starts a kernel thread running `entry(argument)` on a new stack. With
    /// `cpu`, it only ever runs there. With `context`, it runs on that
    /// scheduling context; otherwise fair at `priority`'s weight.
    /// `extendedState` gives it an FP/SIMD/vector save area (for user
    /// threads from K6; kernel threads don't need one).
    static func spawn(_ name: StaticString, cpu: Int? = nil, priority: Int = Thread.defaultPriority,
                      context: SchedContextPointer? = nil, extendedState: Bool = false,
                      _ entry: Thread.Entry, _ argument: UInt64) throws(VmError) -> ThreadHandle {
        guard (0...Thread.maxPriority).contains(priority) else { panic("sched: priority out of range") }
        reapZombies()
        let stack = try KernelStack().keepForever()
        var affinity = allCpus
        if let cpu {
            guard cpu < Smp.count else { panic("sched: spawn on a CPU that doesn't exist") }
            affinity = 1 << UInt64(cpu)
        }
        let thread = makeRecord(name: name, stack: stack, ownsStack: true, entry: entry, argument: argument,
                                isIdle: false, priority: priority, affinity: affinity, cpu: Int(Cpu.current))
        thread.pointee.savedSp = arch_thread_prepare(stack.top, thread.address)
        if extendedState { thread.pointee.extendedState = ExtendedState.allocate() }
        locked {
            if let context { attach(thread, context) }
            makeReady(thread)
        }
        return ThreadHandle(thread: thread)
    }

    /// The running thread.
    static var current: ThreadPointer {
        let saved = arch_interrupts_save()
        defer { arch_interrupts_restore(saved) }
        return cpus[Int(Cpu.current)].current!
    }

    /// Ends the running thread.
    static func exit(_ code: Int) -> Never {
        _ = arch_interrupts_save()
        lock.lockMasked()
        let me = Int(Cpu.current)
        let thread = cpus[me].current!
        guard !thread.pointee.isIdle else { panic("sched: the idle thread exited") }
        guard thread.pointee.ownedQueues == nil else { panic("sched: a thread exited holding a mutex") }
        detachContext(thread)
        thread.pointee.aspace?.pointee.threads -= 1
        thread.pointee.aspace = nil  // the switch away loads whatever runs next
        thread.pointee.exitCode = code
        thread.pointee.state = .dead
        switchAway()
        panic("sched: a dead thread was resumed")
    }

    /// Fair threads: lets others on this CPU run first. Deadline threads:
    /// ends this period's work, giving up the rest of its budget.
    static func yield() {
        locked {
            let me = Int(Cpu.current)
            let thread = cpus[me].current!
            let now = Clock.now()
            charge(thread, me, now)
            if thread.pointee.effective.discipline == .deadline {
                thread.pointee.remaining = 0
                thread.pointee.budgetYielded = true
            } else {
                guard cpus[me].hasRunnable else { return }
                if let first = cpus[me].fair.head {
                    thread.pointee.vruntime = max(thread.pointee.vruntime, first.pointee.vruntime)
                }
            }
            thread.pointee.state = .ready
            switchAway()
        }
    }

    /// Blocks the running thread until `deadline` (monotonic ns).
    static func sleep(until deadline: UInt64) {
        locked {
            while Clock.now() < deadline {
                _ = block(on: nil, deadline: deadline)
            }
        }
    }

    static func join(_ thread: ThreadPointer) -> Int {
        let code = locked { () -> Int in
            while !thread.pointee.switchedOut {
                _ = block(on: exitWaiters, deadline: .max)
            }
            return thread.pointee.exitCode
        }
        free(thread)
        return code
    }

    static func detach(_ thread: ThreadPointer) {
        let freeNow = locked { () -> Bool in
            if thread.pointee.switchedOut { return true }
            thread.pointee.detached = true
            return false
        }
        if freeNow { free(thread) }
    }

    // MARK: Waiting (scheduler lock held, through `locked`)

    /// Runs `body` with the scheduler lock held and interrupts masked.
    /// `body` may block (`block`); the lock is held again when it resumes.
    ///
    /// Leaving it is a preemption point when the caller had interrupts on:
    /// a wakeup or profile change in `body` may have made another thread
    /// on this CPU more deserving.
    static func locked<R>(_ body: () -> R) -> R {
        let preemptible = arch_interrupts_enabled()
        let saved = arch_interrupts_save()
        lock.lockMasked()
        let result = body()
        lock.unlockMasked()
        cancelTimeout()
        if preemptible { preemptIfRequested() }
        arch_interrupts_restore(saved)
        return result
    }

    /// Blocks the running thread on `queue` (nil: no queue, only the
    /// deadline wakes it) until woken or until `deadline`. Lock held.
    static func block(on queue: QueuePointer?, deadline: UInt64, interruptible: Bool = false) -> Thread.WaitResult {
        let me = Int(Cpu.current)
        let thread = cpus[me].current!
        guard !thread.pointee.isIdle else { panic("sched: the idle thread blocked") }
        // A user-facing wait (syscalls) ends when its thread is killed.
        if interruptible, thread.pointee.killPending { return .interrupted }
        thread.pointee.interruptible = interruptible
        Trace.event(CROI_TRACE_SCHED, UInt16(CROI_TK_BLOCK), deadline)
        thread.pointee.state = .blocked
        thread.pointee.waitResult = .woken
        thread.pointee.waitQueue = queue
        if let queue {
            thread.pointee.queueKey = thread.pointee.effective.waitKey
            queue.pointee.push(thread)
            if let owner = queue.pointee.owner { updateEffectiveProfile(owner) }  // lend it our profile
        }
        // Waiting again for the same deadline (a condition loop) keeps the
        // timer already armed, and with it the generation it checks.
        if deadline == .max || thread.pointee.timeoutTimer == 0 || thread.pointee.timeoutDeadline != deadline {
            dropTimeout(thread, me)
            thread.pointee.waitGeneration &+= 1
            if deadline != .max {
                guard let id = Timers.arm(deadline: deadline, timeoutFired, thread.address,
                                          context: thread.pointee.waitGeneration) else {
                    panic("sched: no timer slot for a timeout")
                }
                thread.pointee.timeoutTimer = id
                thread.pointee.timeoutCpu = me
                thread.pointee.timeoutDeadline = deadline
            }
        }
        switchAway()
        if thread.pointee.waitResult == .timedOut {
            thread.pointee.timeoutTimer = 0  // it fired: nothing to cancel
        }
        return thread.pointee.waitResult
    }

    /// Marks `thread` killed: an interruptible wait it is in ends now
    /// (.interrupted), and if it is running elsewhere its CPU enters the
    /// kernel, where the way back to user mode sees the mark. Lock held.
    static func interrupt(_ thread: ThreadPointer) {
        thread.pointee.killPending = true
        switch thread.pointee.state {
        case .blocked where thread.pointee.interruptible:
            if let queue = thread.pointee.waitQueue {
                queue.pointee.remove(thread)
                thread.pointee.waitQueue = nil
                if let owner = queue.pointee.owner { updateEffectiveProfile(owner) }
            }
            thread.pointee.waitResult = .interrupted
            makeReady(thread)
        case .running where thread.pointee.cpu != Int(Cpu.current):
            requestPreemption(on: thread.pointee.cpu)
        default:
            break
        }
    }

    /// Sleeps until `deadline` unless the thread is killed (nanosleep).
    static func sleepInterruptible(until deadline: UInt64) {
        locked {
            while Clock.now() < deadline {
                if block(on: nil, deadline: deadline, interruptible: true) == .interrupted { return }
            }
        }
    }

    /// Wakes the first thread on `queue`. Lock held.
    @discardableResult
    static func wakeOne(_ queue: QueuePointer) -> Bool {
        guard let thread = queue.pointee.pop() else { return false }
        thread.pointee.waitQueue = nil
        makeReady(thread)
        if let owner = queue.pointee.owner { updateEffectiveProfile(owner) }
        return true
    }

    /// Wakes every thread on `queue`. Lock held.
    @discardableResult
    static func wakeAll(_ queue: QueuePointer) -> Int {
        var woken = 0
        while wakeOne(queue) { woken += 1 }
        return woken
    }

    private static let timeoutFired: Timers.Callback = { address, generation in
        let thread = ThreadPointer(address: address)
        lock.lockMasked()  // a timer callback: interrupts are masked
        // This wait's timer is gone now, whatever the thread is doing: if
        // it was woken first and blocks again for the same deadline, it
        // must arm a new one (keeping this id lost the timeout for good).
        if thread.pointee.waitGeneration == generation { thread.pointee.timeoutTimer = 0 }
        if thread.pointee.state == .blocked, thread.pointee.waitGeneration == generation {
            if let queue = thread.pointee.waitQueue {
                queue.pointee.remove(thread)
                thread.pointee.waitQueue = nil
                if let owner = queue.pointee.owner { updateEffectiveProfile(owner) }
            }
            thread.pointee.waitResult = .timedOut
            makeReady(thread)
        }
        lock.unlockMasked()
    }

    /// Forgets a thread's armed timeout: cancelled now if it is on this
    /// CPU, else queued for `cancelTimeout`. Lock held.
    private static func dropTimeout(_ thread: ThreadPointer, _ me: Int) {
        let id = thread.pointee.timeoutTimer
        guard id != 0 else { return }
        thread.pointee.timeoutTimer = 0
        if thread.pointee.timeoutCpu == me {
            Timers.cancel(id)
            return
        }
        let count = thread.pointee.staleTimerCount
        guard count < 4 else { panic("sched: too many timeouts left on other CPUs") }
        thread.pointee.staleTimers[count] = UInt64(thread.pointee.timeoutCpu) << 32 | UInt64(id)
        thread.pointee.staleTimerCount = count + 1
    }

    /// Cancels the running thread's leftover timeouts, now that the lock is
    /// dropped: a timer firing after its thread is freed would touch freed
    /// memory. Interrupts masked.
    private static func cancelTimeout() {
        let me = Int(Cpu.current)
        guard let thread = cpus[me].current else { return }
        lock.lockMasked()
        dropTimeout(thread, me)
        var stale = thread.pointee.staleTimers
        let count = thread.pointee.staleTimerCount
        thread.pointee.staleTimerCount = 0
        lock.unlockMasked()
        for i in 0..<count {
            Ipi.call(onCpu: Int(stale[i] >> 32), cancelTimer, stale[i] & 0xFFFF_FFFF)
            stale[i] = 0
        }
    }

    private static let cancelTimer: Ipi.Function = { id in
        Timers.cancel(UInt32(id))
    }

    // MARK: Profiles and inheritance (lock held)

    private static func baseProfile(_ thread: ThreadPointer) -> Profile {
        thread.pointee.context?.pointee.profile ?? .fair(weight: thread.pointee.baseWeight)
    }

    /// Base profile plus what the waiters on its owned queues lend it.
    private static func computeEffective(_ thread: ThreadPointer) -> Profile {
        var inherited = InheritedProfile()
        var owned = thread.pointee.ownedQueues
        while let queue = owned {
            var waiter = queue.pointee.head
            while let current = waiter {
                inherited.add(current.pointee.effective)
                waiter = current.pointee.next
            }
            owned = queue.pointee.nextOwned
        }
        return inherited.applied(to: baseProfile(thread))
    }

    /// Recomputes `thread`'s effective profile and carries a change along
    /// the chain: its place in the queue it is on, and the owner of the
    /// owned queue it waits on, and so on.
    static func updateEffectiveProfile(_ start: ThreadPointer) {
        var thread = start
        let now = Clock.now()
        for _ in 0..<1024 {
            let profile = computeEffective(thread)
            let old = thread.pointee.effective
            guard profile != old else { return }
            switch thread.pointee.state {
            case .ready:
                let cpu = thread.pointee.cpu
                dequeue(thread, cpu)
                setProfile(thread, profile, now)
                enqueue(thread, on: cpu, now)
                requestPreemption(on: cpu)
                return
            case .running:
                if thread.pointee.isIdle { return }
                charge(thread, thread.pointee.cpu, now)
                setProfile(thread, profile, now)
                requestPreemption(on: thread.pointee.cpu)  // re-evaluate, re-arm its slice
                return
            case .blocked:
                setProfile(thread, profile, now)
                guard let queue = thread.pointee.waitQueue else { return }
                queue.pointee.remove(thread)
                thread.pointee.queueKey = profile.waitKey
                queue.pointee.push(thread)
                guard let owner = queue.pointee.owner else { return }
                thread = owner
            case .dead:
                return
            }
        }
        panic("sched: priority inheritance chain too long")
    }

    /// Switches a thread to a new effective profile, starting the runtime
    /// state of a discipline it wasn't using.
    private static func setProfile(_ thread: ThreadPointer, _ profile: Profile, _ now: UInt64) {
        let old = thread.pointee.effective
        thread.pointee.effective = profile
        if profile.discipline == .deadline, old.discipline != .deadline || old.params != profile.params {
            startPeriod(thread, now)
        } else if profile.discipline == .fair, old.discipline != .fair {
            thread.pointee.vruntime = cpus[thread.pointee.cpu].minVruntime
        }
    }

    private static func addOwned(_ queue: QueuePointer, to owner: ThreadPointer) {
        queue.pointee.owner = owner
        queue.pointee.nextOwned = owner.pointee.ownedQueues
        owner.pointee.ownedQueues = queue
    }

    private static func removeOwned(_ queue: QueuePointer, from owner: ThreadPointer) {
        var previous: QueuePointer? = nil
        var cursor = owner.pointee.ownedQueues
        while let current = cursor {
            if current == queue {
                if let previous {
                    previous.pointee.nextOwned = current.pointee.nextOwned
                } else {
                    owner.pointee.ownedQueues = current.pointee.nextOwned
                }
                break
            }
            previous = current
            cursor = current.pointee.nextOwned
        }
        queue.pointee.owner = nil
        queue.pointee.nextOwned = nil
    }

    /// Whether `queue`'s owner chain (owner, what it waits on, its owner,
    /// ...) reaches `thread`: blocking there would be a deadlock.
    static func ownerChainReaches(_ queue: QueuePointer, _ thread: ThreadPointer) -> Bool {
        var cursor = queue.pointee.owner
        for _ in 0..<1024 {
            guard let owner = cursor else { return false }
            if owner == thread { return true }
            guard owner.pointee.state == .blocked, let next = owner.pointee.waitQueue else { return false }
            cursor = next.pointee.owner
        }
        return true
    }

    /// The running deadline thread's current period: when it started and
    /// its absolute deadline (both 0 for a fair thread).
    static func currentPeriod() -> (start: UInt64, deadline: UInt64) {
        locked {
            let thread = cpus[Int(Cpu.current)].current!
            guard thread.pointee.effective.discipline == .deadline else { return (0, 0) }
            return (thread.pointee.periodStart, thread.pointee.absoluteDeadline)
        }
    }

    static func effectiveProfile(of thread: ThreadPointer) -> Profile {
        locked { thread.pointee.effective }
    }

    // MARK: Mutex

    static func lockMutex(_ queue: QueuePointer) {
        locked {
            let me = cpus[Int(Cpu.current)].current!
            guard let owner = queue.pointee.owner else {
                addOwned(queue, to: me)
                return
            }
            if owner == me { panic("mutex: recursive lock") }
            if ownerChainReaches(queue, me) { panic("mutex: deadlock") }
            // Unlock hands the mutex over, so one wakeup means we own it.
            _ = block(on: queue, deadline: .max)
            guard queue.pointee.owner == me else { panic("mutex: woken without ownership") }
        }
    }

    static func unlockMutex(_ queue: QueuePointer) {
        locked {
            let me = cpus[Int(Cpu.current)].current!
            guard queue.pointee.owner == me else { panic("mutex: unlocked by a thread that doesn't hold it") }
            removeOwned(queue, from: me)
            if let next = queue.pointee.pop() {
                next.pointee.waitQueue = nil
                addOwned(queue, to: next)
                updateEffectiveProfile(next)  // it inherits the remaining waiters
                makeReady(next)
            }
            updateEffectiveProfile(me)  // drop what we inherited through it
        }
    }

    // MARK: Scheduling contexts (ext 2, 3, 4, 8, 10)

    static func makeContext(_ profile: Profile, cpu: Int, account: AccountPointer?, wallUtilization: UInt64,
                            reservation: UInt32) -> SchedContextPointer {
        guard let raw = unsafe heap.allocate(size: MemoryLayout<SchedContextRecord>.size) else {
            panic("sched: out of memory for a scheduling context")
        }
        unsafe raw.bindMemory(to: SchedContextRecord.self, capacity: 1).initialize(
            to: SchedContextRecord(profile: profile, cpu: cpu, account: account, wallUtilization: wallUtilization,
                                   reservation: reservation))
        let context = SchedContextPointer(address: UInt64(UInt(bitPattern: raw)))
        locked {
            context.pointee.next = contexts
            contexts = context
            if cpu >= 0 { recomputePowerHints(cpu) }
        }
        return context
    }

    /// Admission control: the CPU the reservation fits on, biggest first
    /// (so deadline work lands on fast cores and stays there), or why none
    /// will take it.
    static func admit(_ params: DeadlineParams, affinity: UInt64, account: AccountPointer?,
                      reservation: UInt32) throws(AdmissionRefusal) -> SchedContextPointer {
        guard params.isValid else { throw .invalidParameters }
        let utilization = params.utilization
        let decision = locked { () -> (cpu: Int, wall: UInt64, refusal: AdmissionRefusal?) in
            if let account, account.pointee.used + utilization > account.pointee.limit {
                return (-1, 0, .accountExhausted)
            }
            var best = -1, bestWall: UInt64 = 0
            var closest = -1, closestLoad = UInt64.max
            for cpu in 0..<Smp.count {
                guard cpus[cpu].ready, affinity & (1 << UInt64(cpu)) != 0,
                      cpus[cpu].reservation == reservation else { continue }
                let wall = utilization * SchedScale.capacityOne / cpus[cpu].capacity
                let load = cpus[cpu].admitted + wall
                if load < closestLoad {
                    closest = cpu
                    closestLoad = load
                }
                guard load <= admissionBound else { continue }
                if best < 0 || cpus[cpu].capacity > cpus[best].capacity
                    || (cpus[cpu].capacity == cpus[best].capacity && cpus[cpu].admitted < cpus[best].admitted) {
                    best = cpu
                    bestWall = wall
                }
            }
            if best < 0 { return (-1, 0, closest < 0 ? .noEligibleCpu : .cpuOverloaded(cpu: closest)) }
            cpus[best].admitted += bestWall
            if let account { account.pointee.used += utilization }
            return (best, bestWall, nil)
        }
        if let refusal = decision.refusal { throw refusal }
        return makeContext(.deadline(params), cpu: decision.cpu, account: account,
                           wallUtilization: decision.wall, reservation: reservation)
    }

    static func destroyContext(_ context: SchedContextPointer) {
        locked {
            guard context.pointee.boundThreads == 0 else { panic("sched: context destroyed while threads use it") }
            let cpu = context.pointee.cpu
            if cpu >= 0 {
                cpus[cpu].admitted -= context.pointee.wallUtilization
                if let account = context.pointee.account {
                    account.pointee.used -= context.pointee.profile.params.utilization
                }
            }
            if contexts == context {
                contexts = context.pointee.next
            } else {
                var cursor = contexts
                while let current = cursor {
                    if current.pointee.next == context {
                        current.pointee.next = context.pointee.next
                        break
                    }
                    cursor = current.pointee.next
                }
            }
            if cpu >= 0 { recomputePowerHints(cpu) }
        }
        unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(context.address))!)
    }

    /// Runs `thread` on `context` from now on (nil: back to its own
    /// weight). A deadline context moves it to the admitted CPU.
    static func bind(_ thread: ThreadPointer, _ context: SchedContextPointer?) {
        locked {
            detachContext(thread)
            if let context { attach(thread, context) }
            reposition(thread)
        }
    }

    private static func attach(_ thread: ThreadPointer, _ context: SchedContextPointer) {
        context.pointee.boundThreads += 1
        thread.pointee.context = context
        setProfile(thread, computeEffective(thread), Clock.now())
    }

    private static func detachContext(_ thread: ThreadPointer) {
        guard let context = thread.pointee.context else { return }
        context.pointee.boundThreads -= 1
        thread.pointee.context = nil
        if thread.pointee.state != .dead {
            setProfile(thread, computeEffective(thread), Clock.now())
        }
    }

    /// After a profile or placement rule changed: queue it again where it
    /// now belongs, or make its CPU re-evaluate it.
    private static func reposition(_ thread: ThreadPointer) {
        switch thread.pointee.state {
        case .ready:
            dequeue(thread, thread.pointee.cpu)
            makeReady(thread)
        case .running:
            requestPreemption(on: thread.pointee.cpu)
        case .blocked:
            if let queue = thread.pointee.waitQueue {
                queue.pointee.remove(thread)
                thread.pointee.queueKey = thread.pointee.effective.waitKey
                queue.pointee.push(thread)
                if let owner = queue.pointee.owner { updateEffectiveProfile(owner) }
            }
        case .dead:
            break
        }
    }

    /// Reserves `cpu` for threads whose context carries `tag` (ext 8);
    /// everything else leaves it. Refused while reservations of another
    /// tag are admitted there.
    @discardableResult
    static func reserve(cpu: Int, tag: UInt32) -> Bool {
        locked { () -> Bool in
            var cursor = contexts
            while let context = cursor {
                if context.pointee.cpu == cpu, context.pointee.reservation != tag { return false }
                cursor = context.pointee.next
            }
            cpus[cpu].reservation = tag
            // Move whatever no longer belongs here.
            var movers = QueueHead()
            for queueIndex in 0..<3 {
                while true {
                    let candidate: ThreadPointer?
                    switch queueIndex {
                    case 0: candidate = cpus[cpu].fair.head
                    case 1: candidate = cpus[cpu].deadline.head
                    default: candidate = cpus[cpu].throttled.head
                    }
                    guard let thread = candidate else { break }
                    dequeue(thread, cpu)
                    movers.push(thread)
                }
            }
            while let thread = movers.pop() { makeReady(thread) }
            requestPreemption(on: cpu)
            return true
        }
    }

    /// The tag a thread's context reserves CPUs for, or 0.
    private static func tag(_ thread: ThreadPointer) -> UInt32 {
        thread.pointee.context?.pointee.reservation ?? 0
    }

    private static func allowed(_ thread: ThreadPointer, on cpu: Int) -> Bool {
        cpus[cpu].ready && thread.pointee.affinity & (1 << UInt64(cpu)) != 0 && cpus[cpu].reservation == tag(thread)
    }

    /// Sets a CPU's capacity (the user-space power service's privileged
    /// call, from `_CPC`). Returns whether its admitted reservations still
    /// fit under the bound; they are not revoked if not.
    @discardableResult
    static func setCapacity(cpu: Int, _ capacity: UInt64) -> Bool {
        locked { () -> Bool in
            cpus[cpu].capacity = max(1, min(capacity, SchedScale.capacityOne))
            var admitted: UInt64 = 0
            var cursor = contexts
            while let context = cursor {
                if context.pointee.cpu == cpu {
                    admitted += context.pointee.profile.params.utilization * SchedScale.capacityOne
                        / cpus[cpu].capacity
                }
                cursor = context.pointee.next
            }
            cpus[cpu].admitted = admitted
            recomputePowerHints(cpu)
            return admitted <= admissionBound
        }
    }

    /// Writes the shared pages for CPUs whose hints changed (outside the
    /// scheduler lock: SharedPages reads through it).
    static func publishPowerHints() {
        let pending = locked { () -> UInt64 in
            let pending = publishPending
            publishPending = 0
            return pending
        }
        for cpu in 0..<Smp.count where pending & (1 << UInt64(cpu)) != 0 { SharedPages.publish(cpu: cpu) }
    }

    static func capacity(cpu: Int) -> UInt64 { locked { cpus[cpu].capacity } }

    /// The wake-latency bound and frequency floor `cpu` publishes for the
    /// power service (KP enforces them; these are the hooks).
    static func powerHints(cpu: Int) -> (wakeLatency: UInt64, frequencyFloor: UInt64) {
        locked { (cpus[cpu].wakeLatencyBound, cpus[cpu].frequencyFloor) }
    }

    /// Wake latency: the least slack (deadline minus the wall time its
    /// budget needs here) among the reservations admitted on `cpu`.
    private static func recomputePowerHints(_ cpu: Int) {
        var latency = UInt64.max
        var cursor = contexts
        while let context = cursor {
            if context.pointee.cpu == cpu {
                let params = context.pointee.profile.params
                let wall = params.capacity * SchedScale.capacityOne / cpus[cpu].capacity
                latency = min(latency, params.deadline > wall ? params.deadline - wall : 0)
            }
            cursor = context.pointee.next
        }
        cpus[cpu].wakeLatencyBound = latency
        cpus[cpu].frequencyFloor = cpus[cpu].admitted
        publishPending |= 1 << UInt64(cpu)
    }

    // MARK: Run queues (lock held)

    /// Charges the running thread for the time since `runStart`: virtual
    /// runtime for fair threads, capacity-scaled budget for deadline ones.
    private static func charge(_ thread: ThreadPointer, _ cpu: Int, _ now: UInt64) {
        guard !thread.pointee.isIdle, now > thread.pointee.runStart else { return }
        let elapsed = now - thread.pointee.runStart
        thread.pointee.runStart = now
        switch thread.pointee.effective.discipline {
        case .fair:
            thread.pointee.vruntime &+= elapsed * SchedScale.capacityOne / max(1, thread.pointee.effective.weight)
        case .deadline:
            thread.pointee.remaining -= Int64(elapsed * cpus[cpu].capacity / SchedScale.capacityOne)
        }
    }

    /// A fresh period starting now.
    private static func startPeriod(_ thread: ThreadPointer, _ now: UInt64) {
        let params = thread.pointee.effective.params
        thread.pointee.periodStart = now
        thread.pointee.absoluteDeadline = now + params.deadline
        thread.pointee.remaining = Int64(params.capacity)
    }

    /// The period after the current one (or now, if that has passed too).
    private static func nextPeriod(_ thread: ThreadPointer, _ now: UInt64) {
        let params = thread.pointee.effective.params
        var start = thread.pointee.periodStart + params.period
        if start + params.deadline <= now { start = now }
        thread.pointee.periodStart = start
        thread.pointee.absoluteDeadline = start + params.deadline
        thread.pointee.remaining = Int64(params.capacity)
    }

    /// The CBS wakeup rule: keep the current period's budget only if using
    /// it before the deadline wouldn't exceed the reserved utilization.
    private static func replenishOnWake(_ thread: ThreadPointer, _ now: UInt64) {
        let params = thread.pointee.effective.params
        let deadline = thread.pointee.absoluteDeadline
        if thread.pointee.remaining <= 0 {
            if now >= thread.pointee.periodStart + params.period { startPeriod(thread, now) } else { nextPeriod(thread, now) }
        } else if now >= deadline
                    || UInt64(thread.pointee.remaining) * params.period > (deadline - now) * params.capacity {
            startPeriod(thread, now)
        }
    }

    /// Puts a ready thread on `cpu`'s run queues.
    private static func enqueue(_ thread: ThreadPointer, on cpu: Int, _ now: UInt64) {
        thread.pointee.state = .ready
        thread.pointee.cpu = cpu
        switch thread.pointee.effective.discipline {
        case .fair:
            thread.pointee.queueKey = thread.pointee.vruntime
            thread.pointee.runQueue = .fair
            cpus[cpu].fair.push(thread)
        case .deadline:
            if thread.pointee.periodStart > now {
                thread.pointee.queueKey = thread.pointee.periodStart
                thread.pointee.runQueue = .throttled
                cpus[cpu].throttled.push(thread)
            } else {
                thread.pointee.queueKey = thread.pointee.absoluteDeadline
                thread.pointee.runQueue = .deadline
                cpus[cpu].deadline.push(thread)
            }
        }
    }

    private static func dequeue(_ thread: ThreadPointer, _ cpu: Int) {
        switch thread.pointee.runQueue {
        case .fair: cpus[cpu].fair.remove(thread)
        case .deadline: cpus[cpu].deadline.remove(thread)
        case .throttled: cpus[cpu].throttled.remove(thread)
        case .none: break
        }
        thread.pointee.runQueue = .none
    }

    private static func pop(_ cpu: Int) -> ThreadPointer? {
        let thread = cpus[cpu].deadline.pop() ?? cpus[cpu].fair.pop()
        thread?.pointee.runQueue = .none
        return thread
    }

    /// Moves throttled threads whose period has started to the deadline
    /// queue, and arms a timer for the next one. On `cpu` itself.
    private static func refreshEligibility(_ cpu: Int, _ now: UInt64) {
        while let first = cpus[cpu].throttled.head, first.pointee.periodStart <= now {
            _ = cpus[cpu].throttled.pop()
            first.pointee.queueKey = first.pointee.absoluteDeadline
            first.pointee.runQueue = .deadline
            cpus[cpu].deadline.push(first)
        }
        let want = cpus[cpu].throttled.head?.pointee.periodStart ?? 0
        guard want != cpus[cpu].eligibilityAt else { return }
        if cpus[cpu].eligibilityTimer != 0 {
            Timers.cancel(cpus[cpu].eligibilityTimer)
            cpus[cpu].eligibilityTimer = 0
        }
        cpus[cpu].eligibilityAt = want
        if want != 0 {
            cpus[cpu].eligibilityTimer = Timers.arm(deadline: want, eligibilityReached, 0) ?? 0
        }
    }

    private static let eligibilityReached: Timers.Callback = { _, _ in
        lock.lockMasked()
        let me = Int(Cpu.current)
        cpus[me].eligibilityTimer = 0
        cpus[me].eligibilityAt = 0
        lock.unlockMasked()
        requestPreemption()
    }

    /// Whether `candidate` (ready on this CPU) should replace `current`.
    private static func preempts(_ candidate: ThreadPointer, _ current: ThreadPointer) -> Bool {
        if current.pointee.isIdle { return true }
        guard candidate.pointee.runQueue == .deadline else { return false }  // fair waits for the slice
        return current.pointee.effective.discipline == .fair
            || candidate.pointee.absoluteDeadline < current.pointee.absoluteDeadline
    }

    // MARK: Switching (lock held, interrupts masked)

    /// Queues a thread that has just become runnable (spawned, woken) on
    /// the CPU chosen for it, and makes that CPU reschedule if it should
    /// run before what is running there.
    private static func makeReady(_ thread: ThreadPointer) {
        let now = Clock.now()
        if thread.pointee.effective.discipline == .deadline {
            replenishOnWake(thread, now)
        }
        let from = thread.pointee.cpu
        let cpu = place(thread)
        Trace.event(CROI_TRACE_SCHED, UInt16(CROI_TK_WAKE), UInt64(thread.pointee.traceId), UInt64(cpu))
        if cpu != from {
            Trace.event(CROI_TRACE_SCHED, UInt16(CROI_TK_MIGRATE), UInt64(thread.pointee.traceId),
                        UInt64(from) << 32 | UInt64(cpu))
        }
        if thread.pointee.effective.discipline == .fair {
            // Its lag, carried to this CPU; a sleeper gets at most half the
            // target latency of credit.
            let floor = cpus[cpu].minVruntime
            let lag = max(thread.pointee.lag, -Int64(targetLatency / 2))
            thread.pointee.vruntime = lag < 0 ? floor &- UInt64(-lag) : floor &+ UInt64(lag)
        }
        enqueue(thread, on: cpu, now)
        let me = Int(Cpu.current)
        let current = cpus[cpu].current!
        if thread.pointee.runQueue == .throttled {
            if cpu == me { refreshEligibility(me, now) } else { Ipi.requestReschedule(cpu) }
        } else if preempts(thread, current)
                    || (current.pointee.effective.discipline == .fair && cpus[cpu].sliceTimer == 0) {
            requestPreemption(on: cpu)
        }
    }

    /// Where a runnable thread should go. Deadline threads: the CPU their
    /// reservation was admitted on (inherited deadline work stays put).
    /// Fair: the last CPU if idle, else an idle one, else the least loaded.
    private static func place(_ thread: ThreadPointer) -> Int {
        if let context = thread.pointee.context, context.pointee.cpu >= 0 { return context.pointee.cpu }
        let last = thread.pointee.cpu
        if thread.pointee.effective.discipline == .deadline, allowed(thread, on: last) { return last }
        var best = -1
        var bestLoad = Int.max
        for step in 0..<Smp.count {
            let cpu = (last + step) % Smp.count
            guard allowed(thread, on: cpu) else { continue }
            let busy = cpus[cpu].current != cpus[cpu].idle ? 1 : 0
            let load = cpus[cpu].queuedCount + busy
            if load == 0 { return cpu }
            if load < bestLoad {
                best = cpu
                bestLoad = load
            }
        }
        guard best >= 0 else { panic("sched: no CPU a thread may run on") }
        return best
    }

    /// Switches this CPU to its best runnable thread. The caller has set
    /// the running thread's new state: `.ready` (preempted or yielding: it
    /// is charged and competes again), `.blocked`, `.dead`, or `.running`
    /// (keeps the CPU if nothing is runnable). Returns when this thread
    /// next runs, with the lock held.
    private static func switchAway() {
        let me = Int(Cpu.current)
        _ = preemptPending.bitwiseAnd(~(1 << UInt64(me)), ordering: .relaxed)
        let now = Clock.now()
        let current = cpus[me].current!
        charge(current, me, now)
        if !current.pointee.isIdle {
            switch current.pointee.state {
            case .ready:
                requeue(current, me, now)
            case .blocked, .dead:
                if current.pointee.effective.discipline == .fair {
                    current.pointee.lag = Int64(bitPattern: current.pointee.vruntime &- cpus[me].minVruntime)
                }
            case .running:
                break
            }
        }
        refreshEligibility(me, now)
        let next = pop(me) ?? (current.pointee.state == .running ? current : cpus[me].idle!)
        next.pointee.state = .running
        next.pointee.runStart = now
        advanceMinVruntime(me, next)
        armSlice(for: next, on: me, now)
        guard next != current else { return }

        Trace.event(CROI_TRACE_SCHED, UInt16(CROI_TK_SWITCH), UInt64(next.pointee.traceId),
                    UInt64(stateCode(current.pointee.state)))
        unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!.pointee.traceThread = next.pointee.traceId
        next.pointee.cpu = me
        next.pointee.cpusSeen |= 1 << UInt64(me)
        next.pointee.switchesIn += 1
        if current.pointee.isIdle { current.pointee.state = .ready }
        cpus[me].switches += 1
        cpus[me].previous = current
        cpus[me].current = next
        // Kernel threads run on the kernel's tables alone, so a user
        // address space is loaded only where its threads run.
        if next.pointee.aspace != cpus[me].activeAspace {
            UserAspaces.activate(next.pointee.aspace, replacing: cpus[me].activeAspace)
            cpus[me].activeAspace = next.pointee.aspace
        }
        loadPkru(next.pointee.pkru, me)
        setKernelStack(next.pointee.stack.top)
        Sampler.switched(to: next)
        Pmu.switched(from: current, to: next)
        // User FP/SIMD state (K6d): out of the registers for the thread
        // leaving, in for the one arriving. Nothing in between uses FP.
        if current.pointee.extendedState != 0 {
            unsafe arch_xstate_save(UnsafeMutableRawPointer(bitPattern: UInt(current.pointee.extendedState))!)
        }
        if next.pointee.extendedState != 0 {
            unsafe arch_xstate_restore(UnsafeRawPointer(bitPattern: UInt(next.pointee.extendedState))!)
        }
        unsafe arch_context_switch(UnsafeMutablePointer<UInt64>(bitPattern: UInt(current.address))!,
                                   next.pointee.savedSp)
        finishSwitch()
    }

    /// A preempted or yielding thread competes again: on this CPU, or
    /// wherever it may run now if this CPU no longer takes it. A deadline
    /// thread out of budget waits for its next period.
    private static func requeue(_ thread: ThreadPointer, _ me: Int, _ now: UInt64) {
        if thread.pointee.effective.discipline == .deadline, thread.pointee.remaining <= 0 {
            if !thread.pointee.budgetYielded { overrun(thread) }
            thread.pointee.budgetYielded = false
            nextPeriod(thread, now)
        }
        if allowed(thread, on: me), thread.pointee.context.map({ $0.pointee.cpu < 0 || $0.pointee.cpu == me }) ?? true {
            enqueue(thread, on: me, now)
        } else {
            thread.pointee.lag = Int64(bitPattern: thread.pointee.vruntime &- cpus[me].minVruntime)
            let cpu = place(thread)
            enqueue(thread, on: cpu, now)
            requestPreemption(on: cpu)
        }
    }

    /// The budget ran out before the work was done (ext 3).
    private static func overrun(_ thread: ThreadPointer) {
        guard let context = thread.pointee.context else { return }
        context.pointee.overruns += 1
        Trace.event(CROI_TRACE_SCHED, UInt16(CROI_TK_OVERRUN), context.pointee.overruns)
        if let hook = context.pointee.overrunHook {
            hook(context.pointee.overrunArgument, context.pointee.overruns)
        }
        if context.pointee.overrunSource != 0 {
            PacketSourcePointer(address: context.pointee.overrunSource)
                .fire(value: context.pointee.overruns, schedulerLocked: true)
        }
    }

    private static func advanceMinVruntime(_ cpu: Int, _ running: ThreadPointer) {
        var floor = UInt64.max
        if !running.pointee.isIdle, running.pointee.effective.discipline == .fair {
            floor = running.pointee.vruntime
        }
        if let first = cpus[cpu].fair.head { floor = min(floor, first.pointee.vruntime) }
        if floor != .max, floor > cpus[cpu].minVruntime { cpus[cpu].minVruntime = floor }
    }

    /// The first thing a thread does after being switched to, on the CPU
    /// that switched to it: deal with the thread that was switched away
    /// from, now that its stack is no longer in use.
    static func finishSwitch() {
        let me = Int(Cpu.current)
        guard let previous = cpus[me].previous else { return }
        cpus[me].previous = nil
        if previous.pointee.state == .dead {
            previous.pointee.switchedOut = true
            if previous.pointee.detached {
                zombies.push(previous)
            } else {
                wakeAll(exitWaiters)
            }
        }
    }

    /// The running thread's timer: a deadline thread's remaining budget
    /// (enforcement), or a fair thread's share of the target latency when
    /// others are waiting (none when it is alone: tickless).
    private static func armSlice(for thread: ThreadPointer, on me: Int, _ now: UInt64) {
        if cpus[me].sliceTimer != 0 {
            Timers.cancel(cpus[me].sliceTimer)
            cpus[me].sliceTimer = 0
        }
        guard !thread.pointee.isIdle else { return }
        var length: UInt64
        switch thread.pointee.effective.discipline {
        case .deadline:
            let remaining = UInt64(max(0, thread.pointee.remaining))
            length = remaining * SchedScale.capacityOne / cpus[me].capacity
        case .fair:
            guard cpus[me].hasRunnable else { return }
            var total = thread.pointee.effective.weight
            var cursor = cpus[me].fair.head
            while let waiting = cursor {
                total += waiting.pointee.effective.weight
                cursor = waiting.pointee.next
            }
            length = max(minimumGranularity, targetLatency * thread.pointee.effective.weight / max(1, total))
        }
        cpus[me].sliceTimer = Timers.arm(deadline: now + max(1, length), sliceExpired, 0) ?? 0
    }

    private static let sliceExpired: Timers.Callback = { _, _ in
        lock.lockMasked()
        cpus[Int(Cpu.current)].sliceTimer = 0
        lock.unlockMasked()
        requestPreemption()
    }

    // MARK: Preemption

    /// Asks `cpu` to reschedule: this one at its next preemption point,
    /// another by IPI.
    private static func requestPreemption(on cpu: Int) {
        if cpu == Int(Cpu.current) { requestPreemption() } else { Ipi.requestReschedule(cpu) }
    }

    /// Asks this CPU to reschedule when the current interrupt returns.
    /// Interrupts masked (IPI and timer handlers).
    static func requestPreemption() {
        _ = preemptPending.bitwiseOr(1 << UInt64(Cpu.current), ordering: .relaxed)
    }

    /// Called as an interrupt returns (and at `locked`'s exit): switches
    /// threads if asked to and the running one should give way: its budget
    /// or slice is used up, or an eligible deadline thread comes first.
    static func preemptIfRequested() {
        guard started.load(ordering: .acquiring),
              preemptPending.load(ordering: .relaxed) & (1 << UInt64(Cpu.current)) != 0 else { return }
        lock.lockMasked()
        // Loop: the thread switched to may raise a new request in
        // `finishSwitch` (a wakeup onto this CPU). `me` is read afresh each
        // time round: after switchAway this thread may be running on
        // another CPU, and a stale `me` would cancel that CPU's timers by
        // ids from another CPU's numbering (it cancelled a sleeper's
        // timeout).
        while true {
            let me = Int(Cpu.current)
            guard preemptPending.load(ordering: .relaxed) & (1 << UInt64(me)) != 0 else { break }
            _ = preemptPending.bitwiseAnd(~(1 << UInt64(me)), ordering: .relaxed)
            guard cpus[me].ready else { break }
            let now = Clock.now()
            refreshEligibility(me, now)
            let current = cpus[me].current!
            charge(current, me, now)
            var give = false
            var reason: UInt64 = 0
            if current.pointee.isIdle {
                give = cpus[me].hasRunnable
            } else if current.pointee.effective.discipline == .deadline, current.pointee.remaining <= 0 {
                give = true
                reason = CROI_TRACE_PREEMPT_BUDGET
            } else if let first = cpus[me].deadline.head, preempts(first, current) {
                give = true
                reason = CROI_TRACE_PREEMPT_DEADLINE
            } else if current.pointee.effective.discipline == .fair, cpus[me].sliceTimer == 0 {
                give = !cpus[me].fair.isEmpty
                reason = CROI_TRACE_PREEMPT_SLICE
            } else if !allowed(current, on: me) {
                give = true  // reserved away from it
                reason = CROI_TRACE_PREEMPT_RESERVED
            }
            if give, reason != 0 {
                Trace.event(CROI_TRACE_SCHED, UInt16(CROI_TK_PREEMPT), reason)
            }
            if give {
                if !current.pointee.isIdle { current.pointee.state = .ready }
                switchAway()
            } else if !current.pointee.isIdle, cpus[me].sliceTimer == 0 {
                // Competition or its profile changed; an armed slice is left
                // alone, or requests could keep extending it.
                armSlice(for: current, on: me, now)
            }
        }
        lock.unlockMasked()
    }

    // MARK: Records

    private static func makeRecord(name: StaticString, stack: StackRange, ownsStack: Bool, entry: Thread.Entry?,
                                   argument: UInt64, isIdle: Bool, priority: Int, affinity: UInt64,
                                   cpu: Int) -> ThreadPointer {
        guard let raw = unsafe heap.allocate(size: MemoryLayout<Thread>.size,
                                             alignment: max(16, MemoryLayout<Thread>.alignment)) else {
            panic("sched: out of memory for a thread")
        }
        unsafe raw.bindMemory(to: Thread.self, capacity: 1).initialize(
            to: Thread(name: name, stack: stack, ownsStack: ownsStack, entry: entry, argument: argument,
                       isIdle: isIdle, priority: priority, affinity: affinity, cpu: cpu))
        threadCount.add(1, ordering: .relaxed)
        let thread = ThreadPointer(address: UInt64(UInt(bitPattern: raw)))
        locked {
            if !isIdle {
                nextTraceId = nextTraceId % 0xFFF + 1  // 1...4095, task 0
                thread.pointee.traceId = nextTraceId
            }
            thread.pointee.allNext = allThreads
            allThreads = thread
        }
        return thread
    }

    /// Frees a thread that is dead and off its stack.
    private static func free(_ thread: ThreadPointer) {
        locked {
            if allThreads == thread {
                allThreads = thread.pointee.allNext
            } else {
                var cursor = allThreads
                while let current = cursor {
                    if current.pointee.allNext == thread {
                        current.pointee.allNext = thread.pointee.allNext
                        break
                    }
                    cursor = current.pointee.allNext
                }
            }
        }
        if thread.pointee.ownsStack {
            do throws(VmError) {
                try kernelAspace.free(thread.pointee.stack.base)
            } catch {
                panic("sched: freeing an unknown thread stack")
            }
        }
        ExtendedState.free(thread.pointee.extendedState)
        Pmu.release(thread)
        let raw = unsafe UnsafeMutablePointer<Thread>(bitPattern: UInt(thread.address))!
        unsafe raw.deinitialize(count: 1)
        unsafe heap.free(UnsafeMutableRawPointer(raw))
        threadCount.subtract(1, ordering: .relaxed)
    }

    /// Frees dead detached threads. Not with the lock held.
    static func reapZombies() {
        while true {
            let saved = arch_interrupts_save()
            lock.lockMasked()
            let zombie = zombies.pop()
            lock.unlockMasked()
            arch_interrupts_restore(saved)
            guard let zombie else { return }
            free(zombie)
        }
    }

    private static func stateCode(_ state: Thread.State) -> Int {
        switch state {
        case .ready: 0
        case .running: 1
        case .blocked: 2
        case .dead: 3
        }
    }

    // MARK: Statistics and debugging

    /// Prints every CPU's and thread's scheduling state. For lockups: it
    /// takes the lock without waiting forever, and reads other CPUs' state
    /// as it finds it.
    static func dump(to out: some TextOutput) {
        var tries = 0
        while !lock.tryLockMasked() {
            tries += 1
            if tries > 10_000_000 {
                out.write("sched dump: lock held by cpu+1 = ")
                out.write(decimal: UInt64(lock.holderForDebugging))
                out.write(", reading anyway\n")
                break
            }
        }
        let pending = preemptPending.load(ordering: .relaxed)
        for cpu in 0..<Smp.count {
            out.write("cpu ")
            out.write(decimal: UInt64(cpu))
            out.write(": current ")
            out.write(hex: cpus[cpu].current?.address ?? 0)
            out.write(cpus[cpu].current == cpus[cpu].idle ? " (idle)" : "")
            out.write(", fair ")
            out.write(decimal: UInt64(cpus[cpu].fair.count))
            out.write(" deadline ")
            out.write(decimal: UInt64(cpus[cpu].deadline.count))
            out.write(" throttled ")
            out.write(decimal: UInt64(cpus[cpu].throttled.count))
            out.write(", slice ")
            out.write(decimal: UInt64(cpus[cpu].sliceTimer))
            out.write(pending & (1 << UInt64(cpu)) != 0 ? ", preempt pending" : "")
            out.write(", switches ")
            out.write(decimal: cpus[cpu].switches)
            out.write(", ipi mailbox ")
            out.write(hex: UInt64(unsafe UnsafePointer<PerCpu>(bitPattern: UInt(Smp.records[cpu]))!.pointee.ipiPending.load(ordering: .relaxed)))
            let timers = Timers.inspect(cpu: cpu, id: 0)
            out.write(", timers ")
            out.write(decimal: UInt64(timers.pending))
            out.write(" pending, hardware ")
            if timers.programmed == .max {
                out.write("disarmed")
            } else {
                out.write("due in ")
                out.write(decimal: UInt64(bitPattern: Int64(bitPattern: timers.programmed &- Clock.now()) / 1000))
                out.write(" us")
            }
            out.write(", timer irqs ")
            out.write(decimal: timers.interrupts)
            let percpu = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(Smp.records[cpu]))!
            out.write(", all irqs ")
            out.write(decimal: unsafe percpu.pointee.interruptCount)
            #if arch(x86_64)
            if cpu == Int(Cpu.current), LocalApic.x2apic {
                out.write(", ISR ")
                for i in (0..<8).reversed() { out.write(hex: arch_rdmsr(0x810 + UInt32(i))) }
                out.write(" IRR ")
                for i in (0..<8).reversed() { out.write(hex: arch_rdmsr(0x820 + UInt32(i))) }
                out.write(" TPR ")
                out.write(hex: arch_rdmsr(0x808))
                out.write(" LVTT ")
                out.write(hex: arch_rdmsr(0x832))
                out.write(" TSCDL-now ")
                out.write(hex: arch_rdmsr(0x6E0) &- arch_counter_read())
            }
            #endif
            out.write("\n")
        }
        var cursor = allThreads
        while let thread = cursor {
            out.write("thread ")
            out.write(hex: thread.address)
            out.write(" ")
            out.write(thread.pointee.name)
            switch thread.pointee.state {
            case .ready: out.write(" ready")
            case .running: out.write(" running")
            case .blocked: out.write(" blocked")
            case .dead: out.write(" dead")
            }
            out.write(" cpu ")
            out.write(decimal: UInt64(thread.pointee.cpu))
            switch thread.pointee.effective.discipline {
            case .fair:
                out.write(" fair w ")
                out.write(decimal: thread.pointee.effective.weight)
            case .deadline:
                out.write(" deadline ")
                out.write(decimal: thread.pointee.effective.params.capacity / 1000)
                out.write("/")
                out.write(decimal: thread.pointee.effective.params.period / 1000)
                out.write(" us left ")
                out.write(decimal: UInt64(max(0, thread.pointee.remaining)) / 1000)
            }
            out.write(" queue ")
            out.write(hex: thread.pointee.waitQueue?.address ?? 0)
            out.write(" timer ")
            out.write(decimal: UInt64(thread.pointee.timeoutTimer))
            out.write("@")
            out.write(decimal: UInt64(thread.pointee.timeoutCpu))
            if thread.pointee.timeoutTimer != 0 {
                let state = Timers.inspect(cpu: thread.pointee.timeoutCpu, id: thread.pointee.timeoutTimer)
                out.write(state.deadline != nil ? " (pending)" : " (not in its queue)")
            }
            out.write(" deadline ")
            out.write(decimal: thread.pointee.timeoutDeadline)
            out.write(" gen ")
            out.write(decimal: thread.pointee.waitGeneration)
            out.write(" switchedOut ")
            out.write(thread.pointee.switchedOut ? "y" : "n")
            out.write("\n")
            cursor = thread.pointee.allNext
        }
        out.write("now ")
        out.write(decimal: Clock.now())
        out.write("\n")
        if lock.isHeldByCurrentCpu { lock.unlockMasked() }
    }

    /// Runs the calling thread in `aspace` from now on (nil: kernel only).
    /// A user address space starts it with JIT writes closed.
    static func setAspace(_ aspace: UserAspacePointer?) {
        locked {
            let me = Int(Cpu.current)
            let thread = cpus[me].current!
            thread.pointee.aspace?.pointee.threads -= 1
            thread.pointee.aspace = aspace
            aspace?.pointee.threads += 1
            if aspace != cpus[me].activeAspace {
                UserAspaces.activate(aspace, replacing: cpus[me].activeAspace)
                cpus[me].activeAspace = aspace
            }
            thread.pointee.pkru = aspace == nil ? 0 : Jit.defaultUserPkru
            loadPkru(thread.pointee.pkru, me)
        }
    }

    /// Opens or closes writes to JIT key `key` for the running thread only
    /// (PKU; what user space will do with WRPKRU).
    static func setJitWritable(_ key: UInt8, _ writable: Bool) {
        locked {
            let me = Int(Cpu.current)
            let thread = cpus[me].current!
            let bit: UInt32 = 1 << UInt32(2 * Int(key) + 1)  // WD
            if writable { thread.pointee.pkru &= ~bit } else { thread.pointee.pkru |= bit }
            loadPkru(thread.pointee.pkru, me)
        }
    }

    /// Where this CPU enters the kernel from user mode: the running
    /// thread's kernel stack top (per-CPU; amd64 also the TSS's RSP0).
    static func setKernelStack(_ top: UInt64) {
        let percpu = unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!
        unsafe percpu.pointee.arch.kernel_sp = top
        #if arch(x86_64)
        if unsafe percpu.pointee.arch.tss != 0 {
            unsafe UnsafeMutableRawPointer(bitPattern: UInt(percpu.pointee.arch.tss + 4))!.storeBytes(of: top, as: UInt64.self)
        }
        #endif
    }

    private static func loadPkru(_ value: UInt32, _ me: Int) {
        #if arch(x86_64)
        guard Jit.mechanism == .protectionKeys, cpus[me].pkru != value else { return }
        arch_write_pkru(value)
        cpus[me].pkru = value
        #endif
    }

    /// CPUs that have an idle thread and take threads.
    static var readyCpuCount: Int {
        locked {
            var count = 0
            for i in 0..<Smp.count where cpus[i].ready { count += 1 }
            return count
        }
    }

    static func switches(onCpu cpu: Int) -> UInt64 {
        locked { cpus[cpu].switches }
    }
}
