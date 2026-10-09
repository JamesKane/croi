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

    static let lowWork = Atomic<Int>(0)

    static func run(_ console: Uart) {
        let share = fairInheritance()
        deadlineInheritance()
        transitive()
        handoffOrder()
        let threads = contention()
        console.write("  mutex:  inheritance: weights add (holder ran ")
        console.write(decimal: UInt64(share))
        console.write("x the competitor), deadline lent, transitive; handoff by profile, ")
        console.write(decimal: UInt64(threads))
        console.write(" threads contending ok\n")
    }

    // MARK: Fair inheritance

    /// Low (priority 4, weight 78) holds A; High (24, weight 525) waits for
    /// it; Mid (16, weight 245) spins on the same CPU. Low inherits High's
    /// weight (603 in all), so it must out-run Mid while it holds A
    /// (without inheritance, Mid would get three times Low's share).
    private static func fairInheritance() -> Int {
        let cpu = Smp.count - 1
        flag.store(false, ordering: .relaxed)
        stop.store(false, ordering: .relaxed)
        midCount.store(0, ordering: .relaxed)
        let low = spawn("low", cpu, 4, nil, lowHolder, 4 << 16 | 60)
        waitFor { a.owner != nil }
        let high = spawn("high", cpu, 24, nil, highWaiter, 0)
        waitFor { a.waiters == 1 }
        let mid = spawn("mid", cpu, 16, nil, midSpinner, 0)
        flag.store(true, ordering: .releasing)
        guard high.join() == 0, mid.join() == 0, low.join() == 0 else { panic("mutex self-test: inheriting threads failed") }
        guard observed.load(ordering: .relaxed) == Int(Profile.weight(priority: 4) + Profile.weight(priority: 24)) else {
            panic("mutex self-test: weight not inherited")
        }
        let work = lowWork.load(ordering: .relaxed), competitor = midDuringHold.load(ordering: .relaxed)
        guard work > competitor else { panic("mutex self-test: inherited weight gave no share") }
        return work / max(1, competitor)
    }

    /// Holds A until told, then works for a window (`argument` bits 0-15,
    /// ms) while counting what Mid manages meanwhile; checks it ends back
    /// at its own priority (bits 16+).
    private static let lowHolder: Thread.Entry = { argument in
        let window = argument & 0xFFFF, priority = Int(argument >> 16)
        a.lock()
        let giveUp = Clock.now() + 2000 * ms
        // Wait for High to be waiting and Mid spawned by sleeping, not
        // spinning: once High waits we run on its inherited budget, and
        // spinning would spend it before the measured window.
        while !flag.load(ordering: .acquiring) {
            if Clock.now() > giveUp { break }
            Scheduler.sleep(until: Clock.now() + ms / 4)
        }
        let profile = Scheduler.effectiveProfile(of: Scheduler.current)
        observed.store(profile.discipline == .fair ? Int(profile.weight) : -1, ordering: .relaxed)
        let before = midCount.load(ordering: .relaxed)
        let until = Clock.now() + window * ms
        var work = 0
        while Clock.now() < until { work += 1 }
        lowWork.store(work, ordering: .relaxed)
        midDuringHold.store(midCount.load(ordering: .relaxed) - before, ordering: .relaxed)
        a.unlock()
        return Scheduler.effectiveProfile(of: Scheduler.current) == .fair(weight: Profile.weight(priority: priority)) ? 0 : 1
    }

    private static let highWaiter: Thread.Entry = { _ in
        a.lock()
        midWhenHighLocked.store(midCount.load(ordering: .relaxed), ordering: .relaxed)
        a.unlock()
        stop.store(true, ordering: .releasing)
        return 0
    }

    private static let midSpinner: Thread.Entry = { _ in
        let giveUp = Clock.now() + 2000 * ms
        while !stop.load(ordering: .acquiring) {
            if Clock.now() > giveUp { return 1 }
            midCount.add(1, ordering: .relaxed)
        }
        return 0
    }

    // MARK: Deadline inheritance

    /// A fair holder of A inherits a deadline waiter's reservation (8 ms
    /// every 10 ms): during a 3 ms critical section a fair spinner on the
    /// same CPU gets nothing.
    private static func deadlineInheritance() {
        let cpu = Smp.count - 1
        flag.store(false, ordering: .relaxed)
        stop.store(false, ordering: .relaxed)
        midCount.store(0, ordering: .relaxed)
        let context: SchedContext
        do throws(AdmissionRefusal) {
            context = try SchedContext(deadline: DeadlineParams(capacity: 8 * ms, period: 10 * ms),
                                       affinity: 1 << UInt64(cpu))
        } catch {
            panic("mutex self-test: deadline waiter not admitted")
        }
        // Traced, so a failure shows what the CPU did (see dumpTrace).
        do throws(VmError) {
            try Trace.start(categories: CROI_TRACE_SCHED, pages: 64, mode: CROI_TRACE_ONESHOT)
        } catch {
            panic("mutex self-test: no memory for trace rings")
        }
        let low = spawn("low", cpu, 16, nil, lowHolder, 16 << 16 | 3)
        waitFor { a.owner != nil }
        let high = spawn("high", cpu, 16, context.record, highWaiter, 0)
        waitFor { a.waiters == 1 }
        let mid = spawn("mid", cpu, 16, nil, midSpinner, 0)
        flag.store(true, ordering: .releasing)
        let ids = (high.thread.pointee.traceId, mid.thread.pointee.traceId, low.thread.pointee.traceId)
        let (h, m, l) = (high.join(), mid.join(), low.join())
        Trace.stop()
        guard h == 0, m == 0, l == 0 else {
            if let console = panicConsole {
                console.write("  mutex:  deadline inheritance: high ")
                console.write(decimal: UInt64(h))
                console.write(", mid ")
                console.write(decimal: UInt64(m))
                console.write(", low ")
                console.write(decimal: UInt64(l))
                console.write("; trace ids high ")
                console.write(decimal: UInt64(ids.0))
                console.write(" mid ")
                console.write(decimal: UInt64(ids.1))
                console.write(" low ")
                console.write(decimal: UInt64(ids.2))
                console.write("\n")
                dumpTrace(cpu, to: console)
            }
            panic("mutex self-test: deadline threads failed")
        }
        Trace.release()
        guard observed.load(ordering: .relaxed) == -1 else { panic("mutex self-test: deadline not inherited") }
        // Mid may run while Low sleeps waiting to start; while Low runs on
        // the inherited reservation, it must not.
        guard midDuringHold.load(ordering: .relaxed) == 0 else {
            panic("mutex self-test: fair thread ran during inherited deadline work")
        }
    }

    /// The last 120 sched records of `cpu`: µs since the first, kind,
    /// thread, a, b.
    private static func dumpTrace(_ cpu: Int, to console: Uart) {
        guard let header = Trace.header(cpu) else { return }
        let total = Int(min(header.head, header.capacity))
        var index = 0
        var first: UInt64 = 0
        Trace.forEachRecord(cpu) { record in
            if index == 0 { first = record.time }
            if index >= total - 120 {
                console.write("    ")
                console.write(decimal: (record.time - first) * 1_000_000 / max(1, header.frequency))
                console.write(" us kind ")
                console.write(decimal: UInt64(record.kind))
                console.write(" thread ")
                console.write(decimal: UInt64(record.thread))
                console.write(" a ")
                console.write(decimal: record.a)
                console.write(" b ")
                console.write(decimal: record.b)
                console.write("\n")
            }
            index += 1
        }
    }

    // MARK: Transitive

    /// T1 (priority 2) holds A; T2 (3) holds B and waits for A; T3 (28)
    /// waits for B. Weights add along the chain: T2 = w3 + w28, T1 = w2 +
    /// T2's; T1 drops back to its own after.
    private static func transitive() {
        flag.store(false, ordering: .relaxed)
        let t1 = spawn("t1", nil, 2, nil, chainHolder, 0)
        waitFor { a.owner != nil }
        let t2 = spawn("t2", nil, 3, nil, chainMiddle, 0)
        waitFor { a.waiters == 1 }
        let t3 = spawn("t3", nil, 28, nil, chainTop, 0)
        waitFor { b.waiters == 1 }
        let w2 = Profile.weight(priority: 2), w3 = Profile.weight(priority: 3), w28 = Profile.weight(priority: 28)
        guard Scheduler.effectiveProfile(of: t2.thread) == .fair(weight: w3 + w28),
              Scheduler.effectiveProfile(of: t1.thread) == .fair(weight: w2 + w3 + w28) else {
            panic("mutex self-test: weight not inherited transitively")
        }
        flag.store(true, ordering: .releasing)
        guard t3.join() == 0, t2.join() == 0, t1.join() == 0 else { panic("mutex self-test: chain threads failed") }
    }

    private static let chainHolder: Thread.Entry = { _ in
        a.lock()
        while !flag.load(ordering: .acquiring) { Scheduler.sleep(until: Clock.now() + ms) }
        a.unlock()
        return Scheduler.effectiveProfile(of: Scheduler.current) == .fair(weight: Profile.weight(priority: 2)) ? 0 : 1
    }

    private static let chainMiddle: Thread.Entry = { _ in
        b.lock()
        a.lock()
        a.unlock()
        b.unlock()
        return Scheduler.effectiveProfile(of: Scheduler.current) == .fair(weight: Profile.weight(priority: 3)) ? 0 : 1
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
            handles.append(spawn("waiter", nil, priority, nil, recordOrder, UInt64(priority)))
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
        for _ in 0..<count { handles.append(spawn("contender", nil, Thread.defaultPriority, nil, contend, 0)) }
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

    private static func spawn(_ name: StaticString, _ cpu: Int?, _ priority: Int, _ context: SchedContextPointer?,
                              _ entry: Thread.Entry, _ argument: UInt64) -> ThreadHandle {
        do throws(VmError) {
            return try Scheduler.spawn(name, cpu: cpu, priority: priority, context: context, entry, argument)
        } catch {
            panic("mutex self-test: spawn failed")
        }
    }
}
