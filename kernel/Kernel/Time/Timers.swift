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
    /// What the hardware is armed for (monotonic ns), or .max.
    var programmed: UInt64 = .max
    var interrupts: UInt64 = 0
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
            program()
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
            unsafe queue.pointee.entries[i] = TimerEntry()
            program()
            return true
        }
        return false
    }

    /// The timer interrupt (interrupts masked).
    static func handleInterrupt() {
        let queue = unsafe self.queue
        unsafe queue.pointee.interrupts += 1
        unsafe queue.pointee.programmed = .max
        let now = Clock.now()
        for i in 0..<32 {
            let entry = unsafe queue.pointee.entries[i]
            guard entry.id != 0, entry.deadline <= now, let callback = entry.callback else { continue }
            unsafe queue.pointee.entries[i] = TimerEntry()  // free first: the callback may re-arm
            callback(entry.argument, entry.context)
        }
        program()
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

    /// Timer interrupts this CPU has taken.
    static var interruptCount: UInt64 { unsafe queue.pointee.interrupts }

    // MARK: Hardware

    private static var queue: UnsafeMutablePointer<TimerQueue> {
        let record = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!
        return unsafe UnsafeMutablePointer<TimerQueue>(bitPattern: UInt(record.pointee.timerQueue))!
    }

    /// Arms the hardware for the earliest `latest`, or disarms it.
    private static func program() {
        let queue = unsafe self.queue
        var earliest = UInt64.max
        for i in 0..<32 where unsafe queue.pointee.entries[i].id != 0 {
            earliest = min(earliest, unsafe queue.pointee.entries[i].latest)
        }
        unsafe queue.pointee.programmed = earliest
        if earliest == .max {
            disarmHardware()
        } else {
            armHardware(atNanoseconds: earliest)
        }
    }

    private static func armHardware(atNanoseconds ns: UInt64) {
        let now = arch_counter_read()
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
