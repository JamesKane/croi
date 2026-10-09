import CKernel
import Fmt
import Synchronization

/// Boot self-test for K3c: fair shares, EDF reservations (meeting
/// deadlines, budget enforcement, overruns), admission with reasons,
/// capacity scaling, power hints and CPU reservation. Each part panics on
/// failure.
enum DeadlineSelfTest {
    static var ms: UInt64 { 1_000_000 }
    static let stop = Atomic<Bool>(false)
    static let go = Atomic<Bool>(false)
    static let counts = Atomic<UInt64>(0)  // two 32-bit counters
    static let fairWork = Atomic<Int>(0)
    static let misses = Atomic<Int>(0)
    static let worstWake = Atomic<UInt64>(0)
    static let hookCalls = Atomic<Int>(0)
    static let cpusUsed = Atomic<UInt64>(0)
    static let reservedCpu = Atomic<Int>(-1)

    static func run(_ console: Uart) {
        let cpu = Smp.count - 1
        let ratio = fairShares(cpu)
        let wake = edf(cpu)
        let overruns = budget(cpu)
        admission(cpu)
        powerHints(cpu)
        reservation(cpu)
        console.write("  edf:    fair shares by weight (")
        console.write(decimal: ratio / 10)
        console.write(".")
        console.write(decimal: ratio % 10)
        console.write("x for 1.95x), 20 periods no misses (worst wake ")
        console.write(decimal: wake / 1000)
        console.write(" us), budget enforced (")
        console.write(decimal: overruns)
        console.write(" overruns), admission reasons, capacity, power hints, reserved CPU ok\n")
    }

    // MARK: Fair shares

    /// Weights 1024 and 525 on one CPU for 200 ms: work splits about 1.95:1.
    /// Returns the ratio x10.
    private static func fairShares(_ cpu: Int) -> UInt64 {
        stop.store(false, ordering: .relaxed)
        counts.store(0, ordering: .relaxed)
        let heavy = spawn("heavy", cpu, 31, nil, countWork, 0)
        let light = spawn("light", cpu, 24, nil, countWork, 32)
        Scheduler.sleep(until: Clock.now() + 200 * ms)
        stop.store(true, ordering: .releasing)
        _ = heavy.join()
        _ = light.join()
        let both = counts.load(ordering: .relaxed)
        let h = both & 0xFFFF_FFFF, l = both >> 32
        guard l > 0 else { panic("edf self-test: a fair thread starved") }
        let ratio = h * 10 / l
        guard ratio >= 14, ratio <= 28 else { panic("edf self-test: fair shares not by weight") }
        return ratio
    }

    /// Counts work into half of `counts` (shift in the argument) until stop.
    private static let countWork: Thread.Entry = { shift in
        while !stop.load(ordering: .acquiring) {
            for _ in 0..<64 { arch_spin_pause() }
            counts.add(1 << shift, ordering: .relaxed)
        }
        return 0
    }

    // MARK: EDF

    /// A job of 1 ms every 10 ms (reserved 3 ms) against two heavy fair
    /// spinners on its CPU: every job finishes by its deadline, and the
    /// spinners still run. Returns the worst wake latency (period start to
    /// running).
    private static func edf(_ cpu: Int) -> UInt64 {
        stop.store(false, ordering: .relaxed)
        misses.store(0, ordering: .relaxed)
        worstWake.store(0, ordering: .relaxed)
        fairWork.store(0, ordering: .relaxed)
        let context = admit(DeadlineParams(capacity: 3 * ms, period: 10 * ms), 1 << UInt64(cpu))
        let a = spawn("spin", cpu, 31, nil, spinFair, 0)
        let b = spawn("spin", cpu, 31, nil, spinFair, 0)
        let job = spawn("job", nil, 16, context.record, periodicJob, 20)
        guard job.join() == 0 else { panic("edf self-test: job thread failed") }
        stop.store(true, ordering: .releasing)
        _ = a.join()
        _ = b.join()
        guard misses.load(ordering: .relaxed) == 0 else { panic("edf self-test: deadline missed") }
        guard fairWork.load(ordering: .relaxed) > 0 else { panic("edf self-test: fair threads starved") }
        return worstWake.load(ordering: .relaxed)
    }

    private static let spinFair: Thread.Entry = { _ in
        while !stop.load(ordering: .acquiring) {
            for _ in 0..<64 { arch_spin_pause() }
            fairWork.add(1, ordering: .relaxed)
        }
        return 0
    }

    /// `argument` periods: wait for the period, work 1 ms, finish (yield).
    private static let periodicJob: Thread.Entry = { periods in
        Scheduler.yield()  // start on a period boundary
        for _ in 0..<periods {
            let (start, deadline) = Scheduler.currentPeriod()
            guard deadline != 0 else { return 1 }
            let now = Clock.now()
            let wake = now > start ? now - start : 0
            if wake > worstWake.load(ordering: .relaxed) { worstWake.store(wake, ordering: .relaxed) }
            while Clock.now() < now + ms { arch_spin_pause() }
            if Clock.now() > deadline { misses.add(1, ordering: .relaxed) }
            Scheduler.yield()
        }
        return 0
    }

    // MARK: Budget

    /// A reservation of 2 ms every 10 ms that never yields, spinning for
    /// 45 ms: it is throttled each period (overruns, the hook runs) and a
    /// fair thread on its CPU gets the rest.
    private static func budget(_ cpu: Int) -> UInt64 {
        stop.store(false, ordering: .relaxed)
        fairWork.store(0, ordering: .relaxed)
        hookCalls.store(0, ordering: .relaxed)
        let context = admit(DeadlineParams(capacity: 2 * ms, period: 10 * ms), 1 << UInt64(cpu))
        context.setOverrunHook(countOverrun, 0)
        let fair = spawn("fair", cpu, 16, nil, spinFair, 0)
        let hog = spawn("hog", nil, 16, context.record, hogFor, 45)
        _ = hog.join()
        stop.store(true, ordering: .releasing)
        _ = fair.join()
        let overruns = context.overruns
        guard overruns >= 3, hookCalls.load(ordering: .relaxed) == Int(overruns) else {
            panic("edf self-test: budget not enforced")
        }
        guard fairWork.load(ordering: .relaxed) > 0 else { panic("edf self-test: fair thread starved by a hog") }
        return overruns
    }

    private static let hogFor: Thread.Entry = { wall in
        let until = Clock.now() + wall * ms
        while Clock.now() < until { arch_spin_pause() }
        return 0
    }

    private static let countOverrun: Timers.Callback = { _, _ in
        hookCalls.add(1, ordering: .relaxed)
    }

    // MARK: Admission

    private static func admission(_ cpu: Int) {
        let only = UInt64(1) << UInt64(cpu)
        func refusal(_ params: DeadlineParams, _ affinity: UInt64, _ account: AccountPointer? = nil) -> AdmissionRefusal? {
            do throws(AdmissionRefusal) {
                _ = try SchedContext(deadline: params, affinity: affinity, account: account)
                return nil
            } catch {
                return error
            }
        }
        let p40 = DeadlineParams(capacity: 4 * ms, period: 10 * ms)
        guard refusal(DeadlineParams(capacity: 11 * ms, deadline: 10 * ms, period: 10 * ms), only) == .invalidParameters,
              refusal(p40, 0) == .noEligibleCpu else { panic("edf self-test: bad reservations admitted") }

        // 0.4 + 0.4 fit under 0.85; another 0.1 doesn't.
        let first = admit(p40, only)
        let second = admit(p40, only)
        guard refusal(DeadlineParams(capacity: 1 * ms, period: 10 * ms), only) == .cpuOverloaded(cpu: cpu) else {
            panic("edf self-test: overload admitted")
        }
        _ = consume first
        _ = consume second

        // A per-user budget of 0.5.
        let account = SchedAccount(limit: SchedScale.one / 2)
        let p30 = DeadlineParams(capacity: 3 * ms, period: 10 * ms)
        do throws(AdmissionRefusal) {
            let charged = try SchedContext(deadline: p30, affinity: only, account: account.record)
            guard account.used == p30.utilization,
                  refusal(p30, only, account.record) == .accountExhausted else { panic("edf self-test: account") }
            _ = consume charged
        } catch {
            panic("edf self-test: account refused its first reservation")
        }
        guard account.used == 0 else { panic("edf self-test: account not credited back") }

        // Capacity: 0.5 of the reference core is all of a half-speed one.
        Scheduler.setCapacity(cpu: cpu, 512)
        guard refusal(DeadlineParams(capacity: 5 * ms, period: 10 * ms), only) == .cpuOverloaded(cpu: cpu) else {
            panic("edf self-test: admission ignored capacity")
        }
        // Biggest core first: with this one at half speed, another is chosen.
        if Smp.count > 1 {
            let both = only | 1 << UInt64(cpu - 1)
            let placed = admit(DeadlineParams(capacity: 1 * ms, period: 10 * ms), both)
            guard placed.cpu == cpu - 1 else { panic("edf self-test: not admitted on the biggest core") }
        }
        Scheduler.setCapacity(cpu: cpu, 1024)
    }

    // MARK: Power hints

    private static func powerHints(_ cpu: Int) {
        let context = admit(DeadlineParams(capacity: 2 * ms, period: 10 * ms), 1 << UInt64(cpu))
        let hints = Scheduler.powerHints(cpu: cpu)
        guard hints.wakeLatency == 8 * ms, hints.frequencyFloor == SchedScale.one / 5 else {
            panic("edf self-test: power hints")
        }
        _ = consume context
        let after = Scheduler.powerHints(cpu: cpu)
        guard after.wakeLatency == .max, after.frequencyFloor == 0 else { panic("edf self-test: power hints kept") }
    }

    // MARK: Reservation

    /// The last CPU reserved for tag 7: ordinary threads stay off it, and a
    /// thread whose context carries the tag runs only there.
    private static func reservation(_ cpu: Int) {
        guard Smp.count > 1 else { return }
        guard Scheduler.reserve(cpu: cpu, tag: 7) else { panic("edf self-test: reservation refused") }
        go.store(false, ordering: .relaxed)
        cpusUsed.store(0, ordering: .relaxed)
        var handles = UniqueArray<ThreadHandle>(capacity: 2 * Smp.count)
        for _ in 0..<(2 * Smp.count) { handles.append(spawn("ordinary", nil, 16, nil, noteCpu, 0)) }
        let tagged = SchedContext(weight: Profile.weight(priority: 16), reservation: 7)
        let inside = spawn("tagged", nil, 16, tagged.record, reportCpu, 0)
        go.store(true, ordering: .releasing)
        while let handle = handles.popLast() { _ = handle.join() }
        _ = inside.join()
        _ = consume tagged
        Scheduler.reserve(cpu: cpu, tag: 0)
        guard cpusUsed.load(ordering: .relaxed) & (1 << UInt64(cpu)) == 0 else {
            panic("edf self-test: an ordinary thread ran on a reserved CPU")
        }
        guard reservedCpu.load(ordering: .relaxed) == cpu else { panic("edf self-test: tagged thread ran elsewhere") }
    }

    private static let noteCpu: Thread.Entry = { _ in
        while !go.load(ordering: .acquiring) { arch_spin_pause() }
        for _ in 0..<2000 {
            _ = cpusUsed.bitwiseOr(1 << UInt64(Cpu.current), ordering: .relaxed)
            arch_spin_pause()
        }
        return 0
    }

    private static let reportCpu: Thread.Entry = { _ in
        while !go.load(ordering: .acquiring) { arch_spin_pause() }
        var seen = -1
        for _ in 0..<2000 {
            let here = Int(Cpu.current)
            if seen >= 0, here != seen { seen = -2 }
            if seen != -2 { seen = here }
        }
        reservedCpu.store(seen, ordering: .relaxed)
        return 0
    }

    // MARK: Helpers

    private static func admit(_ params: DeadlineParams, _ affinity: UInt64) -> SchedContext {
        do throws(AdmissionRefusal) {
            return try SchedContext(deadline: params, affinity: affinity)
        } catch {
            panic("edf self-test: reservation refused")
        }
    }

    private static func spawn(_ name: StaticString, _ cpu: Int?, _ priority: Int, _ context: SchedContextPointer?,
                              _ entry: Thread.Entry, _ argument: UInt64) -> ThreadHandle {
        do throws(VmError) {
            return try Scheduler.spawn(name, cpu: cpu, priority: priority, context: context, entry, argument)
        } catch {
            panic("edf self-test: spawn failed")
        }
    }
}
