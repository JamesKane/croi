import CKernel
import Fmt
import Synchronization

/// Boot self-test for K3a, run by the bootstrap thread once every CPU has
/// an idle thread. Each part panics on failure.
enum SchedulerSelfTest {
    static let counter = Atomic<Int>(0)
    static let cpusUsed = Atomic<UInt64>(0)
    static let started = Atomic<Bool>(false)
    static let flag = Atomic<Bool>(false)
    static var iterations: Int { 2000 }
    nonisolated(unsafe) static var queue = QueuePointer(address: 0)
    /// Whose turn it is in the ping-pong (scheduler lock).
    nonisolated(unsafe) static var turn = 0
    static var rounds: Int { 500 }

    static func run(_ console: Uart) {
        let ms: UInt64 = 1_000_000
        let deadline = Clock.now() + 1000 * ms
        while Scheduler.readyCpuCount < Smp.count {
            guard Clock.now() < deadline else { panic("sched self-test: a CPU has no idle thread") }
            arch_spin_pause()
        }
        let baseline = Scheduler.threadCount.load(ordering: .relaxed)
        queue = QueuePointer.allocate()

        // Many threads, spread over the CPUs, contending on a lock and
        // yielding; exit codes come back through join.
        let workers = 2 * Smp.count
        var handles = UniqueArray<ThreadHandle>(capacity: workers)
        for i in 0..<workers {
            handles.append(spawn("worker", nil, worker, UInt64(i)))
        }
        var index = workers - 1
        while let handle = handles.popLast() {
            guard handle.join() == index * 3 else { panic("sched self-test: wrong exit code") }
            index -= 1
        }
        guard counter.load(ordering: .relaxed) == workers * iterations else {
            panic("sched self-test: lost increments")
        }
        let used = cpusUsed.load(ordering: .relaxed).nonzeroBitCount
        guard used == Smp.count else { panic("sched self-test: workers didn't reach every CPU") }

        // Ping-pong through a wait queue: two threads on one CPU, then on
        // two CPUs (cross-CPU wakeups go by IPI to an idle CPU).
        let last = Smp.count - 1
        for (a, b) in [(last, last), (last, max(0, last - 1))] as InlineArray<2, (Int, Int)> {
            turn = 0
            let ping = spawn("ping", a, pingPong, 0)
            let pong = spawn("pong", b, pingPong, 1)
            guard ping.join() == 0, pong.join() == 0 else { panic("sched self-test: ping-pong") }
        }

        // Sleeping, and a wait that times out.
        var start = Clock.now()
        Scheduler.sleep(until: start + 5 * ms)
        let slept = Clock.now() - start
        guard slept >= 5 * ms, slept < 100 * ms else { panic("sched self-test: sleep") }
        start = Clock.now()
        let result = Scheduler.locked { Scheduler.block(on: queue, deadline: start + 3 * ms) }
        guard result == .timedOut, Clock.now() - start >= 3 * ms,
              Scheduler.locked({ queue.pointee.isEmpty }) else { panic("sched self-test: timeout") }

        // Preemption: a thread that never yields spins until a second thread
        // on the same CPU sets a flag, which only a timeslice lets happen.
        start = Clock.now()
        let spinner = spawn("spinner", last, spinUntilFlag, 0)
        while !started.load(ordering: .acquiring) { Scheduler.yield() }
        let setter = spawn("setter", last, setFlag, 0)
        guard spinner.join() == 0, setter.join() == 0 else { panic("sched self-test: no preemption") }
        let preemptedAfter = Clock.now() - start

        // A detached thread is freed after it exits.
        _ = spawn("detached", nil, worker, 1000)
        let reapDeadline = Clock.now() + 1000 * ms
        while Scheduler.threadCount.load(ordering: .relaxed) != baseline {
            guard Clock.now() < reapDeadline else { panic("sched self-test: detached thread not freed") }
            Scheduler.sleep(until: Clock.now() + ms)
        }
        queue.deallocate()

        console.write("  sched:  ")
        console.write(decimal: UInt64(workers))
        console.write(" threads on ")
        console.write(decimal: UInt64(used))
        console.write(" CPUs; ping-pong local and cross-CPU, sleep, timeout, preemption (")
        console.write(decimal: preemptedAfter / ms)
        console.write(" ms), reaping ok\n")
    }

    private static func spawn(_ name: StaticString, _ cpu: Int?, _ entry: Thread.Entry, _ argument: UInt64) -> ThreadHandle {
        do throws(VmError) {
            return try Scheduler.spawn(name, cpu: cpu, entry, argument)
        } catch {
            panic("sched self-test: spawn failed")
        }
    }

    private static let lock = SpinLock()

    private static let worker: Thread.Entry = { index in
        guard index < 1000 else { return 0 }
        for i in 0..<iterations {
            lock.withLock {
                counter.store(counter.load(ordering: .relaxed) + 1, ordering: .relaxed)
                _ = cpusUsed.bitwiseOr(1 << UInt64(Cpu.current), ordering: .relaxed)
            }
            if i % 100 == 0 { Scheduler.yield() }
        }
        return Int(index) * 3
    }

    private static let pingPong: Thread.Entry = { me in
        for _ in 0..<rounds {
            Scheduler.locked {
                while turn != Int(me) {
                    _ = Scheduler.block(on: queue, deadline: .max)
                }
                turn = 1 - Int(me)
                Scheduler.wakeAll(queue)
            }
        }
        return 0
    }

    private static let spinUntilFlag: Thread.Entry = { _ in
        let giveUp = Clock.now() + 2_000_000_000
        started.store(true, ordering: .releasing)
        while !flag.load(ordering: .acquiring) {
            if Clock.now() > giveUp { return 1 }
            arch_spin_pause()
        }
        return 0
    }

    private static let setFlag: Thread.Entry = { _ in
        flag.store(true, ordering: .releasing)
        return 0
    }
}
