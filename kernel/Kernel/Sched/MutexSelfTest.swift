import CKernel
import Fmt
import Synchronization

/// Boot self-test for K3b: priority inheritance through owned wait queues,
/// and the kernel Mutex. Each part panics on failure.
enum MutexSelfTest {
    // Globals, as kernel mutexes usually are (initialized on first use).
    static let a = Mutex()
    static let b = Mutex()
    static let flag = Atomic<Bool>(false)
    static let stop = Atomic<Bool>(false)
    static let midCount = Atomic<Int>(0)
    static let observed = Atomic<Int>(0)
    static let midDuringHold = Atomic<Int>(-1)
    static let midWhenHighLocked = Atomic<Int>(-1)
    static let counter = Atomic<Int>(0)
    static let order = Atomic<UInt64>(0)
    static var ms: UInt64 { 1_000_000 }

    static func run(_ console: Uart) {
        inversion()
        transitive()
        handoffOrder()
        let threads = contention()
        console.write("  mutex:  priority inheritance (inversion, transitive), handoff by priority, ")
        console.write(decimal: UInt64(threads))
        console.write(" threads contending ok\n")
    }

    // MARK: Inversion

    /// Low (4) holds A; High (24) blocks on it; Mid (16) is then made ready
    /// on the same CPU. With inheritance Low runs at 24, so Mid must not
    /// run until High has had the lock.
    private static func inversion() {
        let cpu = Smp.count - 1
        flag.store(false, ordering: .relaxed)
        stop.store(false, ordering: .relaxed)
        midCount.store(0, ordering: .relaxed)
        let low = spawn("low", cpu, 4, lowHolder, 0)
        waitFor { a.owner != nil }
        let high = spawn("high", cpu, 24, highWaiter, 0)
        waitFor { a.waiters == 1 }
        let mid = spawn("mid", cpu, 16, midSpinner, 0)
        flag.store(true, ordering: .releasing)
        guard high.join() == 0, mid.join() == 0, low.join() == 0 else { panic("mutex self-test: inversion threads failed") }
        guard observed.load(ordering: .relaxed) == 24 else { panic("mutex self-test: no priority inherited") }
        guard midDuringHold.load(ordering: .relaxed) == 0, midWhenHighLocked.load(ordering: .relaxed) == 0 else {
            panic("mutex self-test: priority inversion")
        }
    }

    private static let lowHolder: Thread.Entry = { _ in
        a.lock()
        let giveUp = Clock.now() + 2000 * ms
        while !flag.load(ordering: .acquiring) {  // High waiting and Mid spawned
            if Clock.now() > giveUp { break }
            arch_spin_pause()
        }
        observed.store(Scheduler.effectivePriority(of: Scheduler.current), ordering: .relaxed)
        let before = midCount.load(ordering: .relaxed)
        let until = Clock.now() + 30 * ms  // longer than a timeslice
        while Clock.now() < until { arch_spin_pause() }
        midDuringHold.store(midCount.load(ordering: .relaxed) - before, ordering: .relaxed)
        a.unlock()
        return Scheduler.effectivePriority(of: Scheduler.current) == 4 ? 0 : 1
    }

    private static let highWaiter: Thread.Entry = { _ in
        a.lock()
        midWhenHighLocked.store(midCount.load(ordering: .relaxed), ordering: .relaxed)
        a.unlock()
        stop.store(true, ordering: .releasing)
        return 0
    }

    private static let midSpinner: Thread.Entry = { _ in
        let giveUp = Clock.now() + 500 * ms
        while !stop.load(ordering: .acquiring) {
            if Clock.now() > giveUp { return 1 }
            midCount.add(1, ordering: .relaxed)
        }
        return 0
    }

    // MARK: Transitive

    /// T1 (2) holds A; T2 (3) holds B and waits for A; T3 (28) waits for B.
    /// T1 and T2 must both run at 28, and T1 drop back to 2 after.
    private static func transitive() {
        flag.store(false, ordering: .relaxed)
        let t1 = spawn("t1", nil, 2, chainHolder, 0)
        waitFor { a.owner != nil }
        let t2 = spawn("t2", nil, 3, chainMiddle, 0)
        waitFor { a.waiters == 1 }
        let t3 = spawn("t3", nil, 28, chainTop, 0)
        waitFor { b.waiters == 1 }
        guard Scheduler.effectivePriority(of: t1.thread) == 28, Scheduler.effectivePriority(of: t2.thread) == 28 else {
            panic("mutex self-test: priority not inherited transitively")
        }
        flag.store(true, ordering: .releasing)
        guard t3.join() == 0, t2.join() == 0, t1.join() == 0 else { panic("mutex self-test: chain threads failed") }
    }

    private static let chainHolder: Thread.Entry = { _ in
        a.lock()
        while !flag.load(ordering: .acquiring) { Scheduler.sleep(until: Clock.now() + ms) }
        a.unlock()
        return Scheduler.effectivePriority(of: Scheduler.current) == 2 ? 0 : 1
    }

    private static let chainMiddle: Thread.Entry = { _ in
        b.lock()
        a.lock()
        a.unlock()
        b.unlock()
        return Scheduler.effectivePriority(of: Scheduler.current) == 3 ? 0 : 1
    }

    private static let chainTop: Thread.Entry = { _ in
        b.withLock {}
        return 0
    }

    // MARK: Handoff order

    /// Waiters of priority 5, 20 and 10 queue behind the bootstrap thread;
    /// unlocking hands A to them in priority order.
    private static func handoffOrder() {
        order.store(0, ordering: .relaxed)
        a.lock()
        var handles = UniqueArray<ThreadHandle>(capacity: 3)
        for (i, priority) in [5, 20, 10].enumerated() {
            handles.append(spawn("waiter", nil, priority, recordOrder, UInt64(priority)))
            waitFor { a.waiters == i + 1 }
        }
        a.unlock()
        while let handle = handles.popLast() { _ = handle.join() }
        guard order.load(ordering: .relaxed) == 20 << 16 | 10 << 8 | 5 else { panic("mutex self-test: handoff order") }
    }

    private static let recordOrder: Thread.Entry = { priority in
        a.withLock {
            order.store(order.load(ordering: .relaxed) << 8 | priority, ordering: .relaxed)
        }
        return 0
    }

    // MARK: Contention

    private static func contention() -> Int {
        counter.store(0, ordering: .relaxed)
        let count = 2 * Smp.count
        var handles = UniqueArray<ThreadHandle>(capacity: count)
        for _ in 0..<count { handles.append(spawn("contender", nil, Thread.defaultPriority, contend, 0)) }
        while let handle = handles.popLast() { _ = handle.join() }
        guard counter.load(ordering: .relaxed) == count * 500 else { panic("mutex self-test: lost increments") }
        return count
    }

    private static let contend: Thread.Entry = { _ in
        for i in 0..<500 {
            a.withLock {
                let value = counter.load(ordering: .relaxed)
                if i % 50 == 0 { Scheduler.yield() }  // hold it across a switch
                counter.store(value + 1, ordering: .relaxed)
            }
        }
        return 0
    }

    // MARK: Helpers

    private static func waitFor(_ condition: () -> Bool) {
        let giveUp = Clock.now() + 2000 * ms
        while !condition() {
            guard Clock.now() < giveUp else { panic("mutex self-test: timed out waiting") }
            Scheduler.sleep(until: Clock.now() + ms / 4)
        }
    }

    private static func spawn(_ name: StaticString, _ cpu: Int?, _ priority: Int, _ entry: Thread.Entry,
                              _ argument: UInt64) -> ThreadHandle {
        do throws(VmError) {
            return try Scheduler.spawn(name, cpu: cpu, priority: priority, entry, argument)
        } catch {
            panic("mutex self-test: spawn failed")
        }
    }
}
