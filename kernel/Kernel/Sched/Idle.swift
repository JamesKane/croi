import CKernel

/// Deadline-aware idle (K15c; Todhchai ext 11; include/power.h): each CPU's
/// idle-state table, installed by the power service from what devmgr
/// evaluated (_CST, _LPI), and the governor that picks a state at every
/// idle. Deterministic, as Todhchai asked: the deepest state whose target
/// residency fits before the CPU's next timer and whose exit latency fits
/// its wake-latency bound (`Scheduler`'s, from admitted deadlines and
/// interrupts routed here with a deadline profile). States that stop the
/// local timer or lose context are kept but not entered: croi has no wake
/// timer or resume path for them yet.
struct IdleTable: ~Copyable {
    var count = 0
    var states = InlineArray<8, croi_idle_state_t>(repeating: croi_idle_state_t())
    var entries = InlineArray<8, UInt64>(repeating: 0)
    var residency = InlineArray<8, UInt64>(repeating: 0)
    var demoted = InlineArray<8, UInt64>(repeating: 0)
    var skipped = InlineArray<8, UInt64>(repeating: 0)
    /// The plain halt (no table, or nothing fitted).
    var halts: UInt64 = 0
    var haltTime: UInt64 = 0
}

enum Idle {
    /// Guards every CPU's table pointer and counters (a leaf; the idle path
    /// takes it masked, briefly, before and after a wait).
    static let lock = SpinLock()

    private static func percpu(_ cpu: Int) -> UnsafeMutablePointer<PerCpu> {
        unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(Smp.records[cpu]))!
    }

    private static func table(_ cpu: Int) -> UnsafeMutablePointer<IdleTable>? {
        unsafe UnsafeMutablePointer<IdleTable>(bitPattern: UInt(percpu(cpu).pointee.idleTable))
    }

    /// Whether this machine can enter states of `method`.
    static func supports(_ method: UInt32) -> Bool {
        switch method {
        case UInt32(CROI_IDLE_METHOD_HALT): return true
        case UInt32(CROI_IDLE_METHOD_MWAIT):
            #if arch(x86_64)
            // MONITOR/MWAIT (CPUID.1:ECX[3]; KVM hides it unless the host
            // passes MWAIT through, -overcommit cpu-pm=on).
            var regs = InlineArray<4, UInt32>(repeating: 0)
            var span = regs.mutableSpan
            unsafe span.withUnsafeMutableBufferPointer { unsafe arch_cpuid(1, 0, $0.baseAddress!) }
            return regs[2] & (1 << 3) != 0
            #else
            return false
            #endif
        case UInt32(CROI_IDLE_METHOD_PSCI):
            #if arch(arm64)
            return Power.psci.available
            #else
            return false
            #endif
        default: return false
        }
    }

    /// cpu_set_idle_states: `states` (already copied in) for `cpu`.
    static func install(cpu: Int, _ states: InlineArray<8, croi_idle_state_t>, count: Int) throws(Status) {
        guard cpu < Smp.count, count <= 8 else { throw .invalidArgs }
        for i in 0..<count {
            let s = states[i]
            guard s.flags & ~UInt32(CROI_IDLE_FLAG_TIMER_STOPS | CROI_IDLE_FLAG_CONTEXT_LOST) == 0 else { throw .invalidArgs }
            if i > 0 { guard s.exit_latency_ns >= states[i - 1].exit_latency_ns else { throw .invalidArgs } }
            guard s.method <= UInt32(CROI_IDLE_METHOD_PSCI) else { throw .invalidArgs }
            guard supports(s.method) else { throw .notSupported }
        }
        var fresh: UInt64 = 0
        if count > 0 {
            guard let raw = unsafe heap.allocate(size: MemoryLayout<IdleTable>.size,
                                                 alignment: MemoryLayout<IdleTable>.alignment) else { throw .noMemory }
            let made = unsafe raw.bindMemory(to: IdleTable.self, capacity: 1)
            unsafe made.initialize(to: IdleTable())
            unsafe made.pointee.count = count
            for i in 0..<count { unsafe made.pointee.states[i] = states[i] }
            fresh = unsafe UInt64(UInt(bitPattern: made))
        }
        let old = lock.withLock { () -> UInt64 in
            let record = unsafe percpu(cpu)
            let old = unsafe record.pointee.idleTable
            unsafe record.pointee.idleTable = fresh
            return old
        }
        if let gone = unsafe UnsafeMutablePointer<IdleTable>(bitPattern: UInt(old)) {
            unsafe gone.deinitialize(count: 1)
            unsafe heap.free(UnsafeMutableRawPointer(gone))
        }
        Scheduler.reevaluateIdle(cpu: cpu)  // in effect at once, not at its next wakeup
    }

    /// The idle wait on this CPU (interrupts masked; returns masked, an
    /// interrupt pending or taken): the chosen state, counted.
    static func enter(_ me: Int) {
        let now = Clock.now()
        let next = Timers.nextLatest()
        let horizon = next > now ? next - now : 0
        let bound = Scheduler.wakeLatencyBound(cpu: me)
        // The choice, under the lock (the table may be replaced meanwhile).
        let choice = lock.withLock { () -> (index: Int, state: croi_idle_state_t, table: UInt64)? in
            guard let t = unsafe table(me) else { return nil }
            var chosen: Int? = nil
            var i = unsafe t.pointee.count - 1
            while i >= 0 {
                let s = unsafe t.pointee.states[i]
                if s.target_residency_ns <= horizon {
                    if s.flags != 0 {
                        unsafe t.pointee.skipped[i] += 1
                    } else if s.exit_latency_ns > bound {
                        unsafe t.pointee.demoted[i] += 1
                    } else {
                        chosen = i
                        break
                    }
                }
                i -= 1
            }
            // Counted as entered now (an idle CPU may sleep a long while
            // before it wakes to count anything else).
            guard let index = chosen else {
                unsafe t.pointee.halts += 1
                return nil
            }
            unsafe t.pointee.entries[index] += 1
            let current = unsafe percpu(me).pointee.idleTable
            return (index, unsafe t.pointee.states[index], current)
        }
        let start = Clock.now()
        if let choice {
            switch choice.state.method {
            case UInt32(CROI_IDLE_METHOD_MWAIT):
                #if arch(x86_64)
                arch_idle_mwait(UInt32(truncatingIfNeeded: choice.state.param))
                #endif
            case UInt32(CROI_IDLE_METHOD_PSCI):
                #if arch(arm64)
                // CPU_SUSPEND (64-bit) for a standby state: back here when an
                // interrupt is pending, as WFI (masked at EL1 all along).
                _ = arch_psci_call(0xC400_0001, choice.state.param, 0, 0, Power.psci.useHvc ? 1 : 0)
                #endif
            default:
                arch_wait_for_interrupt()
            }
        } else {
            arch_wait_for_interrupt()
        }
        let spent = Clock.now() - start
        lock.withLock {
            guard let t = unsafe table(me) else { return }
            let current = unsafe percpu(me).pointee.idleTable
            if let choice, choice.table == current {
                unsafe t.pointee.residency[choice.index] += spent
            } else if choice == nil {
                unsafe t.pointee.haltTime += spent
            }
        }
    }

    /// CROI_INFO_CPU_IDLE_STATES: every CPU's states, then its plain halt.
    static func stats(into out: (croi_idle_state_stats_t) -> Bool) {
        lock.withLock {
            for cpu in 0..<Smp.count {
                guard let t = unsafe table(cpu) else {
                    _ = out(croi_idle_state_stats_t(cpu: UInt32(cpu), state: UInt32(CROI_IDLE_STATE_DEFAULT), entries: 0,
                                                    residency_ns: 0, demoted: 0, skipped: 0))
                    continue
                }
                let count = unsafe t.pointee.count
                for i in 0..<count {
                    _ = unsafe out(croi_idle_state_stats_t(cpu: UInt32(cpu), state: UInt32(i), entries: t.pointee.entries[i],
                                                           residency_ns: t.pointee.residency[i],
                                                           demoted: t.pointee.demoted[i], skipped: t.pointee.skipped[i]))
                }
                _ = unsafe out(croi_idle_state_stats_t(cpu: UInt32(cpu), state: UInt32(CROI_IDLE_STATE_DEFAULT),
                                                       entries: t.pointee.halts, residency_ns: t.pointee.haltTime,
                                                       demoted: 0, skipped: 0))
            }
        }
    }
}

extension Syscalls {
    /// cpu_set_idle_states(resource, cpu, const croi_idle_state_t *, count),
    /// syscall 245 (K15c): the POWER system resource (base 5) or root.
    static func idleCall(_ a: InlineArray<6, UInt64>, _ table: borrowing HandleTable) throws(Status) {
        try Resources.check(table, UInt32(truncatingIfNeeded: a[0]), system: UInt64(CROI_RSRC_SYSTEM_POWER_BASE))
        guard a[1] < UInt64(Smp.count), a[3] <= UInt64(CROI_IDLE_STATES_MAX) else { throw .invalidArgs }
        var states = InlineArray<8, croi_idle_state_t>(repeating: croi_idle_state_t())
        let size = MemoryLayout<croi_idle_state_t>.size
        for i in 0..<Int(a[3]) {
            var state = croi_idle_state_t()
            let failed = withUnsafeMutableBytes(of: &state) { unsafe UserCopy.from($0.baseAddress!, a[2] + UInt64(i * size), UInt64(size)) }
            guard failed == 0 else { throw .invalidArgs }
            states[i] = state
        }
        try Idle.install(cpu: Int(a[1]), states, count: Int(a[3]))
    }

    /// object_get_info(INFO resource or root, CROI_INFO_CPU_IDLE_STATES,
    /// buffer, size, actual, avail): every CPU's state counters (K15c).
    static func idleInfo(_ a: InlineArray<6, UInt64>, _ table: borrowing HandleTable) throws(Status) {
        try Resources.check(table, UInt32(truncatingIfNeeded: a[0]), system: UInt64(CROI_RSRC_SYSTEM_INFO_BASE))
        var records = UniqueArray<croi_idle_state_stats_t>()
        Idle.stats { record in
            records.append(record)
            return true
        }
        let size = MemoryLayout<croi_idle_state_stats_t>.size
        let fits = min(records.count, Int(a[3]) / size)
        if fits > 0 { try check(a[2], fits * size) }
        for i in 0..<fits {
            var record = records[i]
            let failed = withUnsafeBytes(of: &record) { unsafe UserCopy.to(a[2] + UInt64(i * size), $0.baseAddress!, UInt64(size)) }
            guard failed == 0 else { throw .invalidArgs }
        }
        if a[4] != 0 { try put(UInt64(fits), a[4]) }
        if a[5] != 0 { try put(UInt64(records.count), a[5]) }
    }
}
