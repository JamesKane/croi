import CKernel

/// One pending timer: fire `callback(argument)` somewhere in
/// [deadline, latest] (monotonic ns; latest = deadline + slack).
struct TimerEntry {
    var id: UInt32 = 0  // 0: free slot
    var deadline: UInt64 = 0
    var latest: UInt64 = 0
    var callback: Timers.Callback?
    var argument: UInt64 = 0
    var context: UInt64 = 0
}

/// A CPU's pending timers, in its PerCpu record. Touched only by its own
/// CPU with interrupts masked.
struct TimerQueue {
    var entries = InlineArray<32, TimerEntry>(repeating: TimerEntry())
    var nextId: UInt32 = 1
    /// What the hardware is armed for (monotonic ns), or .max; never later
    /// than the earliest pending `latest` (it may be earlier: see
    /// `Timers.program`).
    var programmed: UInt64 = .max
    var interrupts: UInt64 = 0
    /// The hardware's own target (monotonic ns, `programmed` plus the
    /// lead) and when it was set: what an early interrupt is measured by.
    var hardwareTarget: UInt64 = 0
    var hardwareArmedAt: UInt64 = 0
}

/// Tickless per-CPU one-shot timers (roadmap K2b). The hardware is armed
/// only for the earliest `latest` among pending timers; when it fires,
/// every timer whose deadline has passed runs. Timers whose windows
/// overlap therefore coalesce into one interrupt; zero slack is exact.
///
/// amd64: local APIC TSC-deadline mode (one-shot mode as the fallback).
/// arm64: the EL1 virtual timer (its PPI from the GTDT). rv64: SBI
/// set_timer. A timer runs on the CPU that armed it, in interrupt context.
enum Timers {
    /// Called with the two values given to `arm`.
    typealias Callback = @convention(c) (UInt64, UInt64) -> Void

    #if arch(x86_64)
    static var vector: UInt32 { 0xF1 }
    nonisolated(unsafe) private(set) static var deadlineMode = false
    /// CPUID 6 EAX[2]: the local APIC timer keeps running in deep C-states.
    /// Without it, deep idle will need an always-on wake timer (roadmap KP).
    nonisolated(unsafe) private(set) static var alwaysRunning = false
    #elseif arch(arm64)
    nonisolated(unsafe) private(set) static var intid: UInt64 = 27
    #endif

    /// Global setup (boot CPU, after Clock).
    static func initialize(_ acpi: AcpiTables) {
        #if arch(x86_64)
        deadlineMode = cpuid(1)[2] & (1 << 24) != 0  // ECX: TSC-deadline
        alwaysRunning = cpuid(6)[0] & (1 << 2) != 0  // EAX: ARAT
        #elseif arch(arm64)
        if let gtdt = acpi.table("GTDT") {
            let gsiv = acpi.withTable(gtdt) { (table: RawSpan) -> UInt32 in
                table.byteCount >= 68 ? table.load(fromByteOffset: 64, as: UInt32.self) : 0
            }
            if gsiv != 0 { intid = UInt64(gsiv) }  // virtual EL1 timer
        }
        #endif
        initializeThisCpu()
    }

    #if arch(x86_64)
    private static func cpuid(_ leaf: UInt32) -> InlineArray<4, UInt32> {
        var regs = InlineArray<4, UInt32>(repeating: 0)
        var span = regs.mutableSpan
        span.withUnsafeMutableBufferPointer { unsafe arch_cpuid(leaf, 0, $0.baseAddress!) }
        return regs
    }
    #endif

    /// This CPU's timer hardware: routed to its interrupt, disarmed.
    static func initializeThisCpu() {
        #if arch(x86_64)
        if deadlineMode {
            LocalApic.write(LocalApic.lvtTimer, vector | (2 << 17))  // TSC-deadline mode
            arch_wrmsr(0x6E0, 0)
        } else {
            LocalApic.write(LocalApic.timerDivide, 0x3)
            LocalApic.write(LocalApic.lvtTimer, vector)  // one-shot
            LocalApic.write(LocalApic.timerInitial, 0)
        }
        #elseif arch(arm64)
        arch_timer_disarm()
        GicV3.enablePrivate(intid)
        #elseif arch(riscv64)
        disarmHardware()
        arch_rv_sie_set(1 << 5)  // STIE
        #endif
    }

    /// Arms a timer on this CPU. Returns its id (for `cancel`), or nil if
    /// this CPU's queue is full.
    @discardableResult
    static func arm(
        deadline: UInt64, slack: UInt64 = 0, _ callback: Callback, _ argument: UInt64, context: UInt64 = 0
    ) -> UInt32? {
        let saved = arch_interrupts_save()
        defer { arch_interrupts_restore(saved) }
        let queue = unsafe self.queue
        for i in 0..<32 where unsafe queue.pointee.entries[i].id == 0 {
            let id = unsafe queue.pointee.nextId
            unsafe queue.pointee.nextId = id == .max ? 1 : id + 1
            let latest = deadline.addingReportingOverflow(slack).overflow ? .max : deadline + slack
            unsafe queue.pointee.entries[i] = TimerEntry(id: id, deadline: deadline, latest: latest,
                                                         callback: callback, argument: argument, context: context)
            // The hardware is never armed later than any other pending
            // timer's `latest`, so only this one can make it sooner: no
            // scan (the scheduler arms and cancels at every switch).
            if unsafe latest < queue.pointee.programmed {
                unsafe queue.pointee.programmed = latest
                armHardware(atNanoseconds: latest)
            }
            return id
        }
        return nil
    }

    /// Cancels a timer on this CPU. False if it already fired (or never was).
    @discardableResult
    static func cancel(_ id: UInt32) -> Bool {
        let saved = arch_interrupts_save()
        defer { arch_interrupts_restore(saved) }
        let queue = unsafe self.queue
        for i in 0..<32 where unsafe queue.pointee.entries[i].id == id {
            // The hardware stays armed: an early interrupt finds nothing
            // due and re-arms for what is left (`program`).
            unsafe queue.pointee.entries[i] = TimerEntry()
            return true
        }
        return false
    }

    /// Before this CPU idles (polls or halts; interrupts masked): the hardware
    /// armed for the earliest timer still pending, or not at all. `cancel`
    /// leaves it armed for speed, which on an idle CPU is a wakeup for
    /// nothing (K10f: an idle machine takes none).
    static func settle() {
        let queue = unsafe self.queue
        var earliest = UInt64.max
        for i in 0..<32 where unsafe queue.pointee.entries[i].id != 0 {
            earliest = min(earliest, unsafe queue.pointee.entries[i].latest)
        }
        guard unsafe earliest > queue.pointee.programmed else { return }
        unsafe queue.pointee.programmed = earliest
        if earliest == .max { disarmHardware() } else { armHardware(atNanoseconds: earliest) }
    }

    /// How early timer hardware fires, in parts per million of the
    /// distance it was armed for (KVM's TSC deadline: ~28, the host clock
    /// against our TSC); long deadlines are armed that much later. Seeded
    /// once from the measured skew (amd64 under a hypervisor), raised by
    /// any interrupt that still comes early. Shared: the skew is the
    /// host's. Racy updates are fine (a few ppm either way).
    nonisolated(unsafe) static var leadPpm: UInt64 = 0
    /// When the skew was last measured (ns since entry): it is measured
    /// again, over a longer baseline, once that has doubled.
    nonisolated(unsafe) private static var skewMeasuredAt: UInt64 = 0

    /// The farthest the hardware is ever armed (2^40 ns, ~18 minutes).
    static var maxDistance: UInt64 { 1 << 40 }

    /// The most a timer interrupt waits for a deadline it came before.
    static var earlyTolerance: UInt64 { 1_000_000 }

    /// The timer interrupt (interrupts masked).
    static func handleInterrupt() {
        let queue = unsafe self.queue
        unsafe queue.pointee.interrupts += 1
        unsafe queue.pointee.programmed = .max
        var now = Clock.now()
        // Early by a little (KVM's TSC deadline came ~240 us early for a
        // timer 10 s out, ~24 ppm): wait for the earliest instead of
        // re-arming for it, which was a second wakeup (K10f). Timers
        // never run early.
        var earliest = UInt64.max
        for i in 0..<32 where unsafe queue.pointee.entries[i].id != 0 {
            earliest = min(earliest, unsafe queue.pointee.entries[i].deadline)
        }
        // An interrupt before the hardware's own target teaches the lead:
        // in ppm of the distance it was armed for (ten ms or more, and
        // under 1%, so a stale or odd reading can't teach nonsense).
        let target = unsafe queue.pointee.hardwareTarget, armedAt = unsafe queue.pointee.hardwareArmedAt
        if target > now, target > armedAt, target - armedAt >= 10_000_000 {
            let early = target - now, distance = target - armedAt
            if early < distance / 100 {
                let ppm = early * 1_000_000 / distance + 1
                leadPpm = min(leadPpm + ppm, 2_000)
            }
        }
        if earliest > now, earliest - now <= earlyTolerance {
            while now < earliest {
                arch_spin_pause()
                now = Clock.now()
            }
        }
        for i in 0..<32 {
            let entry = unsafe queue.pointee.entries[i]
            guard entry.id != 0, entry.deadline <= now, let callback = entry.callback else { continue }
            unsafe queue.pointee.entries[i] = TimerEntry()  // free first: the callback may re-arm
            callback(entry.argument, entry.context)
            unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!.pointee.stats.timerCallbacks += 1
        }
        program()
        // Nothing left: the arm64 virtual timer and the SBI timer stay
        // pending until told otherwise.
        if unsafe queue.pointee.programmed == .max { disarmHardware() }
    }

    /// Diagnostics: another CPU's queue (read racily): the deadline of
    /// timer `id` if pending, what the hardware is armed for, pending
    /// count and interrupts taken.
    static func inspect(cpu: Int, id: UInt32) -> (deadline: UInt64?, programmed: UInt64, pending: Int, interrupts: UInt64) {
        let record = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(Smp.records[cpu]))!
        let queue = unsafe UnsafePointer<TimerQueue>(bitPattern: UInt(record.pointee.timerQueue))!
        var deadline: UInt64? = nil
        var pending = 0
        for i in 0..<32 where unsafe queue.pointee.entries[i].id != 0 {
            pending += 1
            if unsafe queue.pointee.entries[i].id == id { deadline = unsafe queue.pointee.entries[i].deadline }
        }
        return unsafe (deadline, queue.pointee.programmed, pending, queue.pointee.interrupts)
    }

    /// When this CPU's hardware was last armed to fire (ns; the time
    /// self-test's check of `maxDistance`).
    static var hardwareTarget: UInt64 { unsafe queue.pointee.hardwareTarget }

    /// Timer interrupts this CPU has taken.
    static var interruptCount: UInt64 { unsafe queue.pointee.interrupts }

    // MARK: Hardware

    private static var queue: UnsafeMutablePointer<TimerQueue> {
        let record = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!
        return unsafe UnsafeMutablePointer<TimerQueue>(bitPattern: UInt(record.pointee.timerQueue))!
    }

    /// After an interrupt: arms the hardware for the earliest `latest` left.
    /// `arm` and `cancel` don't come here: a cancel leaves the hardware
    /// armed (an early interrupt finds nothing due and re-arms for what is
    /// left), and `arm` writes it only for a sooner timer. Writing the
    /// hardware on every arm and cancel cost two VM exits per context
    /// switch under KVM (the scheduler re-arms its slice timer at each
    /// one); now it is at most one interrupt per slice.
    private static func program() {
        let queue = unsafe self.queue
        var earliest = UInt64.max
        for i in 0..<32 where unsafe queue.pointee.entries[i].id != 0 {
            earliest = min(earliest, unsafe queue.pointee.entries[i].latest)
        }
        guard unsafe earliest < queue.pointee.programmed else { return }
        unsafe queue.pointee.programmed = earliest
        armHardware(atNanoseconds: earliest)
    }

    private static func armHardware(atNanoseconds requested: UInt64) {
        let now = arch_counter_read()
        // Later by the learned lead (K10f: a 60 s sleep came ~1.4 ms early
        // under KVM, past what an interrupt waits out, and re-arming was a
        // second wakeup). At worst a long timer runs a few ppm late.
        let queue = unsafe self.queue
        let nowNs = Clock.nanoseconds(counter: now)
        let distance = requested > nowNs ? requested - nowNs : 0
        #if arch(x86_64)
        // A long deadline is when the skew matters: measure it (an HPET
        // read, a VM exit) when the baseline has doubled since last time.
        if distance >= 1_000_000_000, nowNs >= 200_000_000, nowNs >= 2 * skewMeasuredAt {
            skewMeasuredAt = nowNs
            if let ppm = X86TimeSources.skewPpm(), ppm > 0, ppm < 1_000 {
                leadPpm = max(leadPpm, UInt64(ppm) + 5)  // +5: a short baseline's error
            }
        }
        #endif
        let lead = leadPpm
        let extra = min(distance, 1 << 40) * lead / 1_000_000
        // Never further out than `maxDistance`: KVM converts a TSC deadline
        // to host ns as delta * 10^6 / tsc_khz in 64 bits, which wraps past
        // ~6000 s at 3 GHz and fired at once; the handler found nothing due
        // and re-armed the same far deadline, an interrupt storm (a futex
        // wait 146 years out took a contended lock from 0.3 ms to 5.6 s,
        // Todhchai's pthread test). Reaching the cap, the interrupt finds
        // nothing due and arms for what is left: one wakeup per cap.
        let ns = min(requested &+ extra < requested ? .max : requested + extra, nowNs + Self.maxDistance)
        unsafe queue.pointee.hardwareTarget = ns
        unsafe queue.pointee.hardwareArmedAt = nowNs
        let counter = max(Clock.counter(atNanoseconds: ns), now + 1)
        #if arch(x86_64)
        if deadlineMode {
            arch_wrmsr(0x6E0, counter)
        } else {
            // TSC ticks to APIC timer ticks, saturating at the 32-bit counter.
            // From the same `now`: a second counter read could already be
            // past `counter`, and the wrapped difference saturated the
            // count (QEMU TCG: a due timer fired 68.7 s late).
            let product = (counter - now).multipliedFullWidth(by: X86TimeSources.apicTimerFrequency)
            let apicTicks = product.high >= Clock.frequency
                ? UInt64(UInt32.max) : Clock.frequency.dividingFullWidth(product).quotient
            LocalApic.write(LocalApic.timerInitial, UInt32(max(1, min(apicTicks, UInt64(UInt32.max)))))
        }
        #elseif arch(arm64)
        arch_timer_arm(counter)
        #elseif arch(riscv64)
        _ = arch_sbi_call(0x5449_4D45, 0, counter, 0, 0)  // TIME: set_timer
        #endif
    }

    private static func disarmHardware() {
        #if arch(x86_64)
        if deadlineMode {
            arch_wrmsr(0x6E0, 0)
        } else {
            LocalApic.write(LocalApic.timerInitial, 0)
        }
        #elseif arch(arm64)
        arch_timer_disarm()
        #elseif arch(riscv64)
        _ = arch_sbi_call(0x5449_4D45, 0, .max, 0, 0)
        #endif
    }
}

