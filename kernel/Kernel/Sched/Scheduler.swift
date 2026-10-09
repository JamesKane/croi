import CKernel
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

    // MARK: Bring-up

    /// The boot CPU: the code running now becomes the "bootstrap" thread
    /// (it may block, unlike an idle thread), and CPU 0 gets an idle thread.
    static func initializeBootCpu(stack: StackRange) {
        exitWaiters = QueuePointer.allocate()
        let bootstrap = makeRecord(name: "bootstrap", stack: stack, ownsStack: false, entry: nil, argument: 0,
                                   isIdle: false, affinity: allCpus, cpu: 0)
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
                              isIdle: true, affinity: 1, cpu: 0)
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
                              isIdle: true, affinity: 1 << UInt64(me), cpu: me)
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
            if !cpus[me].queue.isEmpty {
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
    static func spawn(_ name: StaticString, cpu: Int? = nil, _ entry: Thread.Entry,
                      _ argument: UInt64) throws(VmError) -> ThreadHandle {
        reapZombies()
        let stack = try KernelStack().keepForever()
        var affinity = allCpus
        if let cpu {
            guard cpu < Smp.count else { panic("sched: spawn on a CPU that doesn't exist") }
            affinity = 1 << UInt64(cpu)
        }
        let thread = makeRecord(name: name, stack: stack, ownsStack: true, entry: entry, argument: argument,
                                isIdle: false, affinity: affinity, cpu: Int(Cpu.current))
        thread.pointee.savedSp = arch_thread_prepare(stack.top, thread.address)
        let saved = arch_interrupts_save()
        lock.lockMasked()
        makeReady(thread)
        lock.unlockMasked()
        arch_interrupts_restore(saved)
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
        thread.pointee.exitCode = code
        thread.pointee.state = .dead
        switchAway()
        panic("sched: a dead thread was resumed")
    }

    /// Lets other threads queued on this CPU run first.
    static func yield() {
        locked {
            let me = Int(Cpu.current)
            guard !cpus[me].queue.isEmpty else { return }
            let thread = cpus[me].current!
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
    static func locked<R>(_ body: () -> R) -> R {
        let saved = arch_interrupts_save()
        lock.lockMasked()
        let result = body()
        lock.unlockMasked()
        cancelTimeout()
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

    // MARK: Switching (lock held, interrupts masked)

    /// Queues a ready thread on the CPU chosen for it, and makes that CPU
    /// reschedule if it is idle or past its timeslice.
    private static func makeReady(_ thread: ThreadPointer) {
        let cpu = place(thread)
        thread.pointee.state = .ready
        thread.pointee.cpu = cpu
        cpus[cpu].queue.push(thread)
        let me = Int(Cpu.current)
        if cpus[cpu].current == cpus[cpu].idle {
            if cpu == me { requestPreemption() } else { Ipi.requestReschedule(cpu) }
        } else if cpus[cpu].sliceTimer == 0 {
            // Its thread has used up a slice already: preempt it. Here, in
            // thread context nothing would act on a request, so start a
            // fresh slice instead.
            if cpu == me { armSlice(for: cpus[me].current!, on: me) } else { Ipi.requestReschedule(cpu) }
        }
    }

    /// Where a ready thread should run: its last CPU if that is idle, else
    /// an idle CPU it may use, else the least loaded one.
    private static func place(_ thread: ThreadPointer) -> Int {
        let affinity = thread.pointee.affinity
        let last = thread.pointee.cpu
        var best = -1
        var bestLoad = Int.max
        for step in 0..<Smp.count {
            let cpu = (last + step) % Smp.count
            guard cpus[cpu].ready, affinity & (1 << UInt64(cpu)) != 0 else { continue }
            let busy = cpus[cpu].current != cpus[cpu].idle ? 1 : 0
            let load = cpus[cpu].queue.count + busy
            if load == 0 { return cpu }
            if load < bestLoad {
                best = cpu
                bestLoad = load
            }
        }
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

    /// Asks this CPU to reschedule when the current interrupt returns.
    /// Interrupts masked (IPI and timer handlers).
    static func requestPreemption() {
        _ = preemptPending.bitwiseOr(1 << UInt64(Cpu.current), ordering: .relaxed)
    }

    /// Called as an interrupt returns: switches threads if asked to and
    /// another thread is waiting for this CPU.
    static func preemptIfRequested() {
        guard started.load(ordering: .acquiring) else { return }
        let me = Int(Cpu.current)
        guard preemptPending.load(ordering: .relaxed) & (1 << UInt64(me)) != 0 else { return }
        lock.lockMasked()
        if cpus[me].ready, !cpus[me].queue.isEmpty {
            let current = cpus[me].current!
            if !current.pointee.isIdle {
                current.pointee.state = .ready
                cpus[me].queue.push(current)
            }
            switchAway()
        } else {
            _ = preemptPending.bitwiseAnd(~(1 << UInt64(me)), ordering: .relaxed)
        }
        lock.unlockMasked()
    }

    // MARK: Records

    private static func makeRecord(name: StaticString, stack: StackRange, ownsStack: Bool, entry: Thread.Entry?,
                                   argument: UInt64, isIdle: Bool, affinity: UInt64, cpu: Int) -> ThreadPointer {
        guard let raw = unsafe heap.allocate(size: MemoryLayout<Thread>.size,
                                             alignment: max(16, MemoryLayout<Thread>.alignment)) else {
            panic("sched: out of memory for a thread")
        }
        unsafe raw.bindMemory(to: Thread.self, capacity: 1).initialize(
            to: Thread(name: name, stack: stack, ownsStack: ownsStack, entry: entry, argument: argument,
                       isIdle: isIdle, affinity: affinity, cpu: cpu))
        threadCount.add(1, ordering: .relaxed)
        return ThreadPointer(address: UInt64(UInt(bitPattern: raw)))
    }

    /// Frees a thread that is dead and off its stack.
    private static func free(_ thread: ThreadPointer) {
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

    // MARK: Statistics

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
