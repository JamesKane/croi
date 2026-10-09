import CKernel
import Synchronization

/// Performance counters (roadmap "Trace", K6e; NeoVectra ADR-0050's
/// pmu_configure): per-thread counters, saved and restored with the thread
/// at each switch, and overflow sampling, which writes the same SAMPLE and
/// FRAMES records as the tick (source 1 + generic event, 0xFF for raw).
///
/// Counters: threads use 0..<threadCounters, sampling the last one
/// (amd64/arm64); rv64's SBI hands out counters by event, so each use asks
/// for one. The sampling counter runs only while a CPU runs a thread, so
/// idle CPUs take no overflow interrupts. Backends: Intel architectural
/// PerfMon and AMD core counters (one LVTPC vector), arm64 PMUv3 (the
/// GICC's performance PPI), rv64 SBI PMU with Sscofpmf overflow.
enum Pmu {
    nonisolated(unsafe) private(set) static var kind = UInt32(CROI_PMU_KIND_NONE)
    nonisolated(unsafe) private(set) static var counters = 0
    nonisolated(unsafe) private(set) static var events: UInt32 = 0
    nonisolated(unsafe) private(set) static var canSample = false
    nonisolated(unsafe) private static var width: UInt64 = 32
    /// Threads with counters, or sampling on: the switch hook has work.
    nonisolated(unsafe) private static var users = 0
    private static let lock = SpinLock()

    // Overflow sampling (all CPUs).
    nonisolated(unsafe) private static var sampleConfig: UInt64 = 0
    nonisolated(unsafe) private static var samplePeriod: UInt64 = 0
    nonisolated(unsafe) private static var sampleSource: UInt64 = 0
    nonisolated(unsafe) private static var sampleEvent: UInt32 = 0
    static var threadCounters: Int { min(Int(CROI_PMU_THREAD_EVENTS), max(counters - 1, 0)) }
    private static var samplingCounter: Int { counters - 1 }

    struct ThreadCounters {
        var count = 0
        var configs = InlineArray<4, UInt64>(repeating: 0)
        var totals = InlineArray<4, UInt64>(repeating: 0)
        /// rv64: the SBI counter each event got at switch-in.
        var live = InlineArray<4, UInt64>(repeating: ~0)
    }

    #if arch(x86_64)
    static var vector: UInt32 { 0xF8 }
    nonisolated(unsafe) private static var fullWidthWrites = false
    nonisolated(unsafe) private static var amdExtended = false
    nonisolated(unsafe) private static var globalControl = false
    #elseif arch(arm64)
    nonisolated(unsafe) private(set) static var intid: UInt64 = 0
    #elseif arch(riscv64)
    private static var sbiPmu: UInt64 { 0x504D55 }
    /// Hardware counters the SBI offers (bit per index) and their CSRs.
    nonisolated(unsafe) private static var hardwareMask: UInt64 = 0
    nonisolated(unsafe) private static var csrs = InlineArray<64, UInt16>(repeating: 0)
    #endif

    // MARK: Setup

    static func initialize(_ acpi: AcpiTables) {
        probe(acpi)
        guard kind != UInt32(CROI_PMU_KIND_NONE) else { return }
        enableHere(0)
        Ipi.callOthers(enableHere, 0)
    }

    private static let enableHere: Ipi.Function = { _ in
        #if arch(x86_64)
        if globalControl {
            let mask: UInt64 = (1 << UInt64(counters)) - 1
            arch_wrmsr(kind == UInt32(CROI_PMU_KIND_AMD) ? 0xC000_0301 : 0x38F, mask)
        }
        LocalApic.write(0x34, vector)  // LVTPC: fixed delivery, unmasked
        #elseif arch(arm64)
        arch_pmu_sysreg_write(UInt32(CROI_PMU_PMCNTENCLR), ~0)
        arch_pmu_sysreg_write(UInt32(CROI_PMU_PMINTENCLR), ~0)
        arch_pmu_sysreg_write(UInt32(CROI_PMU_PMOVSCLR), ~0)
        arch_pmu_sysreg_write(UInt32(CROI_PMU_PMUSERENR), 0)
        arch_pmu_sysreg_write(UInt32(CROI_PMU_PMCR), arch_pmu_sysreg_read(UInt32(CROI_PMU_PMCR)) | 1)  // E
        if intid != 0 { GicV3.enablePrivate(intid) }
        #elseif arch(riscv64)
        if canSample { arch_rv_lcofi_enable() }
        #endif
    }

    private static func probe(_ acpi: AcpiTables) {
        #if arch(x86_64)
        let vendor = cpuid(0)
        let amd = vendor[1] == 0x6874_7541  // "Auth"
        if amd {
            let extended = cpuid(0x8000_0000)[0]
            guard extended >= 0x8000_0001 else { return }
            amdExtended = cpuid(0x8000_0001)[2] & (1 << 23) != 0  // PerfCtrExtCore
            counters = amdExtended ? 6 : 4
            if extended >= 0x8000_0022, cpuid(0x8000_0022)[0] & 1 != 0 {  // PerfMonV2
                globalControl = true
                counters = Int(cpuid(0x8000_0022)[1] & 0xF)
            }
            // Under a hypervisor the counters may be absent: check one sticks.
            arch_wrmsr(selectMsr(0), 0)
            arch_wrmsr(counterMsr(0), 0x1234)
            guard arch_rdmsr(counterMsr(0)) == 0x1234 else {
                counters = 0
                return
            }
            arch_wrmsr(counterMsr(0), 0)
            kind = UInt32(CROI_PMU_KIND_AMD)
            width = 48
            events = 0xF
        } else {
            guard cpuid(0)[0] >= 0xA else { return }
            let leaf = cpuid(0xA)
            let version = leaf[0] & 0xFF
            guard version >= 1, (leaf[0] >> 8) & 0xFF >= 2 else { return }
            counters = Int((leaf[0] >> 8) & 0xFF)
            width = UInt64((leaf[0] >> 16) & 0xFF)
            globalControl = version >= 2
            let length = (leaf[0] >> 24) & 0xFF
            let unavailable = leaf[1]
            for (event, bit) in [(0, 0), (1, 1), (2, 4), (3, 6)] as InlineArray<4, (UInt32, UInt32)>
            where bit < length && unavailable & (1 << bit) == 0 {
                events |= 1 << event
            }
            if cpuid(1)[2] & (1 << 15) != 0 {  // PDCM: IA32_PERF_CAPABILITIES
                fullWidthWrites = arch_rdmsr(0x345) & (1 << 13) != 0
            }
            kind = UInt32(CROI_PMU_KIND_INTEL)
        }
        canSample = counters >= 2
        #elseif arch(arm64)
        let version = (arch_pmu_sysreg_read(UInt32(CROI_PMU_DFR0)) >> 8) & 0xF
        guard version != 0, version != 0xF else { return }
        counters = Int((arch_pmu_sysreg_read(UInt32(CROI_PMU_PMCR)) >> 11) & 0x1F)
        guard counters >= 2 else { return }
        kind = UInt32(CROI_PMU_KIND_ARM)
        width = 32
        let supported = arch_pmu_sysreg_read(UInt32(CROI_PMU_PMCEID0))
        for (event, code) in [(0, 0x11), (1, 0x08), (2, 0x03), (3, 0x10)] as InlineArray<4, (UInt32, UInt64)>
        where supported & (1 << code) != 0 {
            events |= 1 << event
        }
        // The overflow PPI: every GICC names it; QEMU's virt uses 23.
        Madt.forEachEntry(acpi) { type, entry in
            if type == 0x0B, entry.byteCount >= 24, intid == 0 {  // Performance Interrupt GSIV
                intid = UInt64(entry.load(fromByteOffset: 20, as: UInt32.self))
            }
        }
        canSample = intid >= 16 && intid < 32
        #elseif arch(riscv64)
        var value: UInt64 = 0
        guard unsafe arch_sbi_call5(0x10, 3, sbiPmu, 0, 0, 0, 0, &value) == 0, value != 0 else { return }  // probe
        guard unsafe arch_sbi_call5(sbiPmu, 0, 0, 0, 0, 0, 0, &value) == 0 else { return }
        let total = min(Int(value), 64)
        for index in 0..<total {
            guard unsafe arch_sbi_call5(sbiPmu, 1, UInt64(index), 0, 0, 0, 0, &value) == 0 else { continue }
            guard value >> 63 == 0 else { continue }  // firmware counter
            hardwareMask |= 1 << UInt64(index)
            csrs[index] = UInt16(value & 0xFFF)
        }
        counters = hardwareMask.nonzeroBitCount
        guard counters >= 2 else { return }
        kind = UInt32(CROI_PMU_KIND_SBI)
        width = 64
        for event in 0..<UInt32(CROI_PMU_GENERIC_EVENTS) {
            if let index = sbiConfigure(config(for: event)!, start: false) {
                sbiStop(index)
                events |= 1 << event
            }
        }
        canSample = RiscvIsa.everyHartHas("sscofpmf", acpi)
        #endif
    }

    // MARK: Per-thread counters

    /// Starts counting `list` (generic or raw events) for the calling
    /// thread, from zero.
    static func enableThread(_ list: InlineArray<4, UInt32>, count: Int) throws(Status) {
        guard kind != UInt32(CROI_PMU_KIND_NONE) else { throw .notSupported }
        guard count >= 1, count <= threadCounters else { throw .invalidArgs }
        var state = ThreadCounters()
        state.count = count
        for i in 0..<count {
            guard let value = config(for: list[i]) else { throw .notSupported }
            state.configs[i] = value
        }
        let saved = arch_interrupts_save()
        defer { arch_interrupts_restore(saved) }
        let thread = Scheduler.current
        if thread.pointee.pmu != 0 { stopThread(thread) } else { lock.withLock { users += 1 } }
        let record = unsafe UnsafeMutablePointer<ThreadCounters>(bitPattern: UInt(thread.pointee.pmu))
            ?? allocate()
        unsafe record.pointee = state
        thread.pointee.pmu = UInt64(UInt(bitPattern: record))
        startThread(thread)
    }

    /// The calling thread's counts so far.
    static func readThread() -> InlineArray<4, UInt64>? {
        let saved = arch_interrupts_save()
        defer { arch_interrupts_restore(saved) }
        let thread = Scheduler.current
        guard let record = unsafe UnsafeMutablePointer<ThreadCounters>(bitPattern: UInt(thread.pointee.pmu)) else {
            return nil
        }
        var values = unsafe record.pointee.totals
        let count = unsafe record.pointee.count
        for i in 0..<count {
            values[i] &+= unsafe liveValue(record, i)
        }
        return values
    }

    static func disableThread() {
        let saved = arch_interrupts_save()
        defer { arch_interrupts_restore(saved) }
        let thread = Scheduler.current
        guard thread.pointee.pmu != 0 else { return }
        stopThread(thread)
        release(thread)
    }

    /// Frees a dead thread's counters (Scheduler, when the record goes).
    static func release(_ thread: ThreadPointer) {
        guard thread.pointee.pmu != 0 else { return }
        unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(thread.pointee.pmu))!)
        thread.pointee.pmu = 0
        lock.withLock { users -= 1 }
    }

    /// The scheduler is switching this CPU from `current` to `next`
    /// (interrupts masked).
    @inline(__always)
    static func switched(from current: ThreadPointer, to next: ThreadPointer) {
        if users != 0 { switchedSlow(from: current, to: next) }
    }

    @inline(never)
    private static func switchedSlow(from current: ThreadPointer, to next: ThreadPointer) {
        if current.pointee.pmu != 0 { stopThread(current) }
        if next.pointee.pmu != 0 { startThread(next) }
        if samplePeriod != 0 {
            if current.pointee.isIdle, !next.pointee.isIdle { startSamplingHere() }
            if next.pointee.isIdle, !current.pointee.isIdle { stopSamplingHere() }
        }
    }

    private static func allocate() -> UnsafeMutablePointer<ThreadCounters> {
        guard let raw = unsafe heap.allocate(size: MemoryLayout<ThreadCounters>.size,
                                             alignment: max(MemoryLayout<ThreadCounters>.alignment, 16)) else {
            panic("pmu: out of memory")
        }
        return unsafe raw.bindMemory(to: ThreadCounters.self, capacity: 1)
    }

    private static func startThread(_ thread: ThreadPointer) {
        let record = unsafe UnsafeMutablePointer<ThreadCounters>(bitPattern: UInt(thread.pointee.pmu))!
        let count = unsafe record.pointee.count
        for i in 0..<count {
            #if arch(riscv64)
            unsafe record.pointee.live[i] = sbiConfigure(record.pointee.configs[i], start: true) ?? ~0
            #else
            unsafe program(i, record.pointee.configs[i], from: 0, interrupt: false)
            #endif
        }
    }

    private static func stopThread(_ thread: ThreadPointer) {
        let record = unsafe UnsafeMutablePointer<ThreadCounters>(bitPattern: UInt(thread.pointee.pmu))!
        let count = unsafe record.pointee.count
        for i in 0..<count {
            unsafe record.pointee.totals[i] &+= liveValue(record, i)
            #if arch(riscv64)
            if unsafe record.pointee.live[i] != ~0 { unsafe sbiStop(record.pointee.live[i]) }
            unsafe record.pointee.live[i] = ~0
            #else
            disable(i)
            #endif
        }
    }

    private static func liveValue(_ record: UnsafeMutablePointer<ThreadCounters>, _ i: Int) -> UInt64 {
        #if arch(riscv64)
        let index = unsafe record.pointee.live[i]
        return index == ~0 ? 0 : arch_rv_counter_read(UInt32(csrs[Int(index)]))
        #else
        return read(i)
        #endif
    }

    // MARK: Overflow sampling

    /// Samples every CPU's running thread each `period` occurrences of
    /// `event`, into the trace's SAMPLE category.
    static func startSampling(event: UInt32, period: UInt64) throws(Status) {
        guard canSample else { throw .notSupported }
        guard period >= 1000, period < (1 << (width - 1)), let value = config(for: event) else { throw .invalidArgs }
        stopSampling()
        sampleConfig = value
        sampleEvent = event
        sampleSource = event & UInt32(CROI_PMU_RAW) != 0 ? 0xFF : 1 + UInt64(event)
        samplePeriod = period
        lock.withLock { users += 1 }
        startSamplingIfBusy(0)
        Ipi.callOthers(startSamplingIfBusy, 0)
    }

    static func stopSampling() {
        guard samplePeriod != 0 else { return }
        samplePeriod = 0
        stopEverywhere(0)
        Ipi.callOthers(stopEverywhere, 0)
        lock.withLock { users -= 1 }
    }

    static var samplingEvent: UInt32? { samplePeriod != 0 ? sampleEvent : nil }

    private static let startSamplingIfBusy: Ipi.Function = { _ in
        if !Scheduler.current.pointee.isIdle { startSamplingHere() }
    }

    private static let stopEverywhere: Ipi.Function = { _ in
        stopSamplingHere()
    }

    private static func startSamplingHere() {
        #if arch(riscv64)
        let percpu = unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!
        guard unsafe percpu.pointee.pmuSamplingCounter == ~0 else { return }
        unsafe percpu.pointee.pmuSamplingCounter = sbiConfigure(sampleConfig, start: true,
                                                                 initial: 0 &- samplePeriod) ?? ~0
        #else
        program(samplingCounter, sampleConfig, from: reload, interrupt: true)
        #endif
    }

    private static func stopSamplingHere() {
        #if arch(riscv64)
        let percpu = unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!
        guard unsafe percpu.pointee.pmuSamplingCounter != ~0 else { return }
        unsafe sbiStop(percpu.pointee.pmuSamplingCounter)
        unsafe percpu.pointee.pmuSamplingCounter = ~0
        #else
        disable(samplingCounter)
        #endif
    }

    /// The counter value that overflows after one period.
    private static var reload: UInt64 {
        let mask: UInt64 = width >= 64 ? ~0 : (1 << width) - 1
        return (0 &- samplePeriod) & mask
    }

    /// The overflow interrupt: sample the interrupted context, reload.
    static func handleOverflow(_ frame: UnsafeMutablePointer<arch_exception_frame_t>) {
        overflows.add(1, ordering: .relaxed)
        unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!.pointee.pmuOverflows += 1
        #if arch(x86_64)
        defer { LocalApic.write(0x34, vector) }  // Intel masks LVTPC on each PMI
        guard samplePeriod != 0 else { return }
        let overflowed: Bool
        if globalControl {
            let statusMsr: UInt32 = kind == UInt32(CROI_PMU_KIND_AMD) ? 0xC000_0300 : 0x38E
            let clearMsr: UInt32 = kind == UInt32(CROI_PMU_KIND_AMD) ? 0xC000_0302 : 0x390
            let status = arch_rdmsr(statusMsr)
            arch_wrmsr(clearMsr, status)
            overflowed = status & (1 << UInt64(samplingCounter)) != 0
        } else {
            overflowed = read(samplingCounter) & (1 << (width - 1)) == 0  // wrapped past zero
        }
        guard overflowed else { return }
        #elseif arch(arm64)
        let status = arch_pmu_sysreg_read(UInt32(CROI_PMU_PMOVSCLR))
        arch_pmu_sysreg_write(UInt32(CROI_PMU_PMOVSCLR), status)
        guard samplePeriod != 0, status & (1 << UInt64(samplingCounter)) != 0 else { return }
        #elseif arch(riscv64)
        arch_rv_sip_clear(1 << 13)
        let percpu = unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!
        let index = unsafe percpu.pointee.pmuSamplingCounter
        guard samplePeriod != 0, index != ~0, arch_rv_scountovf() & (1 << index) != 0 else { return }
        #endif
        let thread = Scheduler.current
        if !thread.pointee.isIdle, croi_trace_categories() & CROI_TRACE_SAMPLE != 0 {
            unsafe Sampler.sample(UnsafePointer(frame), thread, source: sampleSource)
        }
        #if arch(riscv64)
        sbiStop(index)
        unsafe percpu.pointee.pmuSamplingCounter = sbiConfigure(sampleConfig, start: true,
                                                                 initial: 0 &- samplePeriod) ?? ~0
        #else
        write(samplingCounter, reload)
        #endif
    }

    static let overflows = Atomic<UInt64>(0)

    // MARK: Events

    /// The arch's encoding of `event` (generic, or raw with CROI_PMU_RAW).
    private static func config(for event: UInt32) -> UInt64? {
        let raw = event & UInt32(CROI_PMU_RAW) != 0
        let code = UInt64(event & ~UInt32(CROI_PMU_RAW))
        guard raw || (code < UInt64(CROI_PMU_GENERIC_EVENTS) && (kind == UInt32(CROI_PMU_KIND_SBI) || events == 0 ||
                                                                   events & (1 << UInt32(code)) != 0)) else {
            return nil
        }
        #if arch(x86_64)
        if raw { return code }  // event | umask << 8 (AMD: event[11:8] at 35:32)
        let intel: InlineArray<4, UInt64> = [0x003C, 0x00C0, 0x412E, 0x00C5]
        let amd: InlineArray<4, UInt64> = [0x0076, 0x00C0, 0x0964, 0x00C3]
        return kind == UInt32(CROI_PMU_KIND_AMD) ? amd[Int(code)] : intel[Int(code)]
        #elseif arch(arm64)
        if raw { return code & 0xFFFF }
        let arm: InlineArray<4, UInt64> = [0x11, 0x08, 0x03, 0x10]
        return arm[Int(code)]
        #elseif arch(riscv64)
        if raw { return code }  // SBI event_idx
        let sbi: InlineArray<4, UInt64> = [1, 2, 4, 6]  // hardware general events
        return sbi[Int(code)]
        #endif
    }

    // MARK: Arch counters

    #if arch(x86_64)
    private static func cpuid(_ leaf: UInt32) -> InlineArray<4, UInt32> {
        var regs = InlineArray<4, UInt32>(repeating: 0)
        var span = regs.mutableSpan
        span.withUnsafeMutableBufferPointer { unsafe arch_cpuid(leaf, 0, $0.baseAddress!) }
        return regs
    }

    private static func selectMsr(_ i: Int) -> UInt32 {
        if kind == UInt32(CROI_PMU_KIND_INTEL) { return 0x186 + UInt32(i) }
        return amdExtended ? 0xC001_0200 + 2 * UInt32(i) : 0xC001_0000 + UInt32(i)
    }

    private static func counterMsr(_ i: Int) -> UInt32 {
        if kind == UInt32(CROI_PMU_KIND_INTEL) { return (fullWidthWrites ? 0x4C1 : 0xC1) + UInt32(i) }
        return amdExtended ? 0xC001_0201 + 2 * UInt32(i) : 0xC001_0004 + UInt32(i)
    }

    private static func program(_ i: Int, _ config: UInt64, from value: UInt64, interrupt: Bool) {
        arch_wrmsr(selectMsr(i), 0)
        arch_wrmsr(counterMsr(i), value)
        var select = (config & 0xFFFF) | 1 << 16 | 1 << 17 | 1 << 22  // USR, OS, EN
        if kind == UInt32(CROI_PMU_KIND_AMD) { select |= (config >> 16 & 0xF) << 32 }
        if interrupt { select |= 1 << 20 }  // INT
        arch_wrmsr(selectMsr(i), select)
    }

    private static func disable(_ i: Int) { arch_wrmsr(selectMsr(i), 0) }
    private static func read(_ i: Int) -> UInt64 { arch_rdmsr(counterMsr(i)) }
    private static func write(_ i: Int, _ value: UInt64) { arch_wrmsr(counterMsr(i), value) }
    #elseif arch(arm64)
    private static func program(_ i: Int, _ config: UInt64, from value: UInt64, interrupt: Bool) {
        arch_pmu_sysreg_write(UInt32(CROI_PMU_PMCNTENCLR), 1 << UInt64(i))
        arch_pmu_event_type(UInt32(i), config)  // EL0 and EL1 both counted
        arch_pmu_counter_write(UInt32(i), value)
        arch_pmu_sysreg_write(UInt32(CROI_PMU_PMOVSCLR), 1 << UInt64(i))
        if interrupt { arch_pmu_sysreg_write(UInt32(CROI_PMU_PMINTENSET), 1 << UInt64(i)) }
        arch_pmu_sysreg_write(UInt32(CROI_PMU_PMCNTENSET), 1 << UInt64(i))
    }

    private static func disable(_ i: Int) {
        arch_pmu_sysreg_write(UInt32(CROI_PMU_PMCNTENCLR), 1 << UInt64(i))
        arch_pmu_sysreg_write(UInt32(CROI_PMU_PMINTENCLR), 1 << UInt64(i))
    }

    private static func read(_ i: Int) -> UInt64 { arch_pmu_counter_read(UInt32(i)) }
    private static func write(_ i: Int, _ value: UInt64) { arch_pmu_counter_write(UInt32(i), value) }
    #elseif arch(riscv64)
    /// Asks the SBI for a hardware counter counting `event` (S and U mode),
    /// optionally starting it at `initial`. Returns its index.
    private static func sbiConfigure(_ event: UInt64, start: Bool, initial: UInt64 = 0) -> UInt64? {
        var index: UInt64 = 0
        let clearValue: UInt64 = 2, autoStart: UInt64 = 4
        let flags = clearValue | (start && initial == 0 ? autoStart : 0)
        guard unsafe arch_sbi_call5(sbiPmu, 2, 0, hardwareMask, flags, event, 0, &index) == 0 else { return nil }
        if start, initial != 0 {
            var ignored: UInt64 = 0
            guard unsafe arch_sbi_call5(sbiPmu, 3, index, 1, 1, initial, 0, &ignored) == 0 else {  // SET_INIT_VALUE
                sbiStop(index)
                return nil
            }
        }
        return index
    }

    private static func sbiStop(_ index: UInt64) {
        var ignored: UInt64 = 0
        _ = unsafe arch_sbi_call5(sbiPmu, 4, index, 1, 1, 0, 0, &ignored)  // RESET: release it
    }
    #endif
}
