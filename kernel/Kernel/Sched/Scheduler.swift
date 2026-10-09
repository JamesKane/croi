import CKernel
import Fmt
import Synchronization

/// One CPU's scheduling state (scheduler lock).
struct CpuScheduler {
    var current: ThreadPointer?
    var idle: ThreadPointer?
    /// The thread just switched away from, for `finishSwitch`.
    var previous: ThreadPointer?
    var queue = QueueHead()
    /// Takes threads (its idle thread exists).
    var ready = false
    /// The running thread's timeslice timer, 0 when none is armed.
    var sliceTimer: UInt32 = 0
    var switches: UInt64 = 0
}

/// Kernel threads on per-CPU run queues (roadmap K3a). This first version
/// is round-robin with a timeslice. Fair and deadline (EDF) scheduling on
/// separate scheduling contexts replace the policy in K3c; what stays is
/// the mechanism here: one scheduler lock, switching, blocking with
/// timeouts, wakeup placement and preemption.
///
/// Locking: one global lock (Zircon's thread_lock) protects every thread
/// record, run queue and wait queue. It is taken with interrupts masked
/// and handed across a context switch: the thread that resumes releases
/// it (`finishSwitch`). Never hold another spinlock while taking it, and
/// never send a waiting IPI (`Ipi.call`) while holding it, since the target
/// may be spinning on it with interrupts masked.
///
/// Preemption: a request sets this CPU's bit in `preemptPending` (slice
/// expiry, a wakeup onto an idle CPU, a reschedule IPI). It is acted on
/// when an interrupt returns, or at the next voluntary switch.
enum Scheduler {
    static let lock = SpinLock()
    static var timeslice: UInt64 { 10_000_000 }  // ns

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

    // MARK: Bring-up

    /// The boot CPU: the code running now becomes the "bootstrap" thread
    /// (it may block, unlike an idle thread), and CPU 0 gets an idle thread.
    static func initializeBootCpu(stack: StackRange) {
        exitWaiters = QueuePointer.allocate()
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
                              isIdle: true, priority: -1, affinity: 1, cpu: 0)
        idle.pointee.savedSp = arch_thread_prepare(idleStack.top, idle.address)
        let saved = arch_interrupts_save()
        lock.lockMasked()
        cpus[0].current = bootstrap
        cpus[0].idle = idle
        cpus[0].ready = true
        lock.unlockMasked()
        arch_interrupts_restore(saved)
        started.store(true, ordering: .releasing)
    }

    /// A secondary CPU: the code running now becomes its idle thread.
    static func becomeIdle(stack: StackRange) -> Never {
        let me = Int(Cpu.current)
        let idle = makeRecord(name: "idle", stack: stack, ownsStack: false, entry: nil, argument: 0,
                              isIdle: true, priority: -1, affinity: 1 << UInt64(me), cpu: me)
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

    /// Runs whatever is queued here, frees dead threads, and otherwise
    /// waits for an interrupt. Interrupts stay masked except while waiting.
    private static func idleLoop() -> Never {
        let me = Int(Cpu.current)
        while true {
            reapZombies()
            lock.lockMasked()
            // Loop: coming back here, `finishSwitch` may have just made a
            // thread ready on this CPU (a joiner woken by an exit), with
            // only a local request and no IPI to end the wait below.
            while !cpus[me].queue.isEmpty {
                switchAway()
            }
            lock.unlockMasked()
            // A wakeup aimed here after the check above sends an IPI, which
            // ends the wait at once.
            arch_wait_for_interrupt()
        }
    }

    private static var allCpus: UInt64 { Smp.count >= 64 ? .max : (1 << UInt64(Smp.count)) - 1 }

    // MARK: Threads

    /// Starts a kernel thread running `entry(argument)` on a new stack. With
    /// `cpu`, it only ever runs there.
    static func spawn(_ name: StaticString, cpu: Int? = nil, priority: Int = Thread.defaultPriority,
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
        locked { makeReady(thread) }
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
        thread.pointee.exitCode = code
        thread.pointee.state = .dead
        switchAway()
        panic("sched: a dead thread was resumed")
    }

    /// Lets other threads queued on this CPU run first.
    static func yield() {
        locked {
            let me = Int(Cpu.current)
            let thread = cpus[me].current!
            guard cpus[me].queue.topPriority >= thread.pointee.effectivePriority else { return }
            thread.pointee.state = .ready
            cpus[me].queue.push(thread)
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
    /// a wakeup or priority change in `body` may have made another thread
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
    static func block(on queue: QueuePointer?, deadline: UInt64) -> Thread.WaitResult {
        let me = Int(Cpu.current)
        let thread = cpus[me].current!
        guard !thread.pointee.isIdle else { panic("sched: the idle thread blocked") }
        thread.pointee.state = .blocked
        thread.pointee.waitResult = .woken
        thread.pointee.waitQueue = queue
        queue?.pointee.push(thread)
        if let owner = queue?.pointee.owner { updateEffectivePriority(owner) }  // lend it our priority
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

    /// Wakes the first thread on `queue`. Lock held.
    @discardableResult
    static func wakeOne(_ queue: QueuePointer) -> Bool {
        guard let thread = queue.pointee.pop() else { return false }
        thread.pointee.waitQueue = nil
        makeReady(thread)
        if let owner = queue.pointee.owner { updateEffectivePriority(owner) }
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
        if thread.pointee.state == .blocked, thread.pointee.waitGeneration == generation {
            if let queue = thread.pointee.waitQueue {
                queue.pointee.remove(thread)
                thread.pointee.waitQueue = nil
                if let owner = queue.pointee.owner { updateEffectivePriority(owner) }
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

    // MARK: Priority inheritance (lock held)

    /// A thread's effective priority: its base, or the best waiter on any
    /// owned wait queue it holds.
    private static func inheritedPriority(_ thread: ThreadPointer) -> Int {
        var priority = thread.pointee.basePriority
        var owned = thread.pointee.ownedQueues
        while let queue = owned {
            priority = max(priority, queue.pointee.topPriority)
            owned = queue.pointee.nextOwned
        }
        return priority
    }

    /// Recomputes `thread`'s effective priority and carries a change along
    /// the chain: its position in the queue it is on, and the owner of the
    /// owned queue it waits on, and so on.
    static func updateEffectivePriority(_ start: ThreadPointer) {
        var thread = start
        for _ in 0..<1024 {
            let priority = inheritedPriority(thread)
            let old = thread.pointee.effectivePriority
            guard priority != old else { return }
            thread.pointee.effectivePriority = priority
            switch thread.pointee.state {
            case .ready:
                let cpu = thread.pointee.cpu
                cpus[cpu].queue.remove(thread)
                cpus[cpu].queue.push(thread)
                if priority > cpus[cpu].current!.pointee.effectivePriority { requestPreemption(on: cpu) }
                return
            case .running:
                let cpu = thread.pointee.cpu
                if priority < old, cpus[cpu].queue.topPriority > priority { requestPreemption(on: cpu) }
                return
            case .blocked:
                guard let queue = thread.pointee.waitQueue else { return }
                queue.pointee.remove(thread)
                queue.pointee.push(thread)
                guard let owner = queue.pointee.owner else { return }
                thread = owner
            case .dead:
                return
            }
        }
        panic("sched: priority inheritance chain too long")
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
                updateEffectivePriority(next)  // it inherits the remaining waiters
                makeReady(next)
            }
            updateEffectivePriority(me)  // drop what we inherited through it
        }
    }

    static func effectivePriority(of thread: ThreadPointer) -> Int {
        locked { thread.pointee.effectivePriority }
    }

    // MARK: Switching (lock held, interrupts masked)

    /// Queues a ready thread on the CPU chosen for it, and makes that CPU
    /// reschedule if it is idle or past its timeslice.
    private static func makeReady(_ thread: ThreadPointer) {
        let cpu = place(thread)
        thread.pointee.state = .ready
        thread.pointee.cpu = cpu
        cpus[cpu].queue.push(thread)
        let me = Int(Cpu.current)
        let running = cpus[cpu].current!.pointee.effectivePriority
        if cpus[cpu].current == cpus[cpu].idle || thread.pointee.effectivePriority > running {
            if cpu == me { requestPreemption() } else { Ipi.requestReschedule(cpu) }
        } else if thread.pointee.effectivePriority == running, cpus[cpu].sliceTimer == 0 {
            // Its thread has used up a slice already: preempt it. Here, in
            // thread context nothing would act on a request, so start a
            // fresh slice instead.
            if cpu == me { armSlice(for: cpus[me].current!, on: me) } else { Ipi.requestReschedule(cpu) }
        }
    }

    /// Where a ready thread should run: its last CPU if that is idle, else
    /// an idle CPU it may use, else one running something of lower
    /// priority (the lowest), else the least loaded one.
    private static func place(_ thread: ThreadPointer) -> Int {
        let affinity = thread.pointee.affinity
        let last = thread.pointee.cpu
        let priority = thread.pointee.effectivePriority
        var best = -1
        var bestLoad = Int.max
        var preemptible = -1
        var preemptiblePriority = priority
        for step in 0..<Smp.count {
            let cpu = (last + step) % Smp.count
            guard cpus[cpu].ready, affinity & (1 << UInt64(cpu)) != 0 else { continue }
            let busy = cpus[cpu].current != cpus[cpu].idle ? 1 : 0
            let load = cpus[cpu].queue.count + busy
            if load == 0 { return cpu }
            let running = cpus[cpu].current!.pointee.effectivePriority
            if running < preemptiblePriority, cpus[cpu].queue.topPriority < priority {
                preemptible = cpu
                preemptiblePriority = running
            }
            if load < bestLoad {
                best = cpu
                bestLoad = load
            }
        }
        if preemptible >= 0 { return preemptible }
        guard best >= 0 else { panic("sched: no CPU a thread may run on") }
        return best
    }

    /// Switches this CPU to its next thread. The caller has already set
    /// the running thread's new state (and queued it, if ready); a thread
    /// left `.running` keeps the CPU when nothing else is queued. Returns
    /// when this thread next runs, with the lock held.
    private static func switchAway() {
        let me = Int(Cpu.current)
        _ = preemptPending.bitwiseAnd(~(1 << UInt64(me)), ordering: .relaxed)
        let current = cpus[me].current!
        let next = cpus[me].queue.pop() ?? (current.pointee.state == .running ? current : cpus[me].idle!)
        next.pointee.state = .running
        armSlice(for: next, on: me)
        guard next != current else { return }

        next.pointee.cpu = me
        next.pointee.cpusSeen |= 1 << UInt64(me)
        next.pointee.switchesIn += 1
        if current.pointee.isIdle { current.pointee.state = .ready }
        cpus[me].switches += 1
        cpus[me].previous = current
        cpus[me].current = next
        unsafe arch_context_switch(UnsafeMutablePointer<UInt64>(bitPattern: UInt(current.address))!,
                                   next.pointee.savedSp)
        finishSwitch()
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

    /// A timeslice for a thread that is about to run, unless it is idle.
    private static func armSlice(for thread: ThreadPointer, on me: Int) {
        if cpus[me].sliceTimer != 0 {
            Timers.cancel(cpus[me].sliceTimer)
            cpus[me].sliceTimer = 0
        }
        guard !thread.pointee.isIdle else { return }
        cpus[me].sliceTimer = Timers.arm(deadline: Clock.now() + timeslice, sliceExpired, 0) ?? 0
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
    /// threads if asked to and a thread that should preempt is waiting.
    static func preemptIfRequested() {
        guard started.load(ordering: .acquiring) else { return }
        let me = Int(Cpu.current)
        guard preemptPending.load(ordering: .relaxed) & (1 << UInt64(me)) != 0 else { return }
        lock.lockMasked()
        // Loop: the thread switched to may raise a new request in
        // `finishSwitch` (a wakeup onto this CPU).
        while preemptPending.load(ordering: .relaxed) & (1 << UInt64(me)) != 0 {
            let running = cpus[me].current?.pointee.effectivePriority ?? -1
            let waiting = cpus[me].queue.topPriority
            // A higher priority waiting, or an equal one once the slice is used up.
            guard cpus[me].ready, !cpus[me].queue.isEmpty,
                  cpus[me].current == cpus[me].idle || waiting > running
                    || (waiting == running && cpus[me].sliceTimer == 0) else {
                _ = preemptPending.bitwiseAnd(~(1 << UInt64(me)), ordering: .relaxed)
                break
            }
            let current = cpus[me].current!
            if !current.pointee.isIdle {
                current.pointee.state = .ready
                cpus[me].queue.push(current)
            }
            switchAway()
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
            out.write(", queued ")
            out.write(decimal: UInt64(cpus[cpu].queue.count))
            out.write(", slice ")
            out.write(decimal: UInt64(cpus[cpu].sliceTimer))
            out.write(pending & (1 << UInt64(cpu)) != 0 ? ", preempt pending" : "")
            out.write(", switches ")
            out.write(decimal: cpus[cpu].switches)
            out.write(", ipi mailbox ")
            out.write(hex: UInt64(unsafe UnsafePointer<PerCpu>(bitPattern: UInt(Smp.records[cpu]))!.pointee.ipiPending.load(ordering: .relaxed)))
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
            out.write(" prio ")
            out.write(decimal: UInt64(thread.pointee.effectivePriority + 1))
            out.write("-1 queue ")
            out.write(hex: thread.pointee.waitQueue?.address ?? 0)
            out.write(" timer ")
            out.write(decimal: UInt64(thread.pointee.timeoutTimer))
            out.write("@")
            out.write(decimal: UInt64(thread.pointee.timeoutCpu))
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
