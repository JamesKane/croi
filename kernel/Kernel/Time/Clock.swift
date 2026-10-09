import _Volatile
import CKernel
import PageTables

/// The monotonic clock: nanoseconds since `initialize`, from each arch's
/// free-running counter (amd64 TSC, arm64 CNTVCT_EL0, rv64 `time`).
///
/// The conversion lives in a croi_time_page_t (time.h) so user space can
/// read the clock without a syscall once K6 maps the page; the kernel uses
/// the same fields.
enum Clock {
    nonisolated(unsafe) private(set) static var frequency: UInt64 = 0
    nonisolated(unsafe) private(set) static var source: StaticString = "none"
    nonisolated(unsafe) private static var base: UInt64 = 0
    nonisolated(unsafe) private static var mult: UInt64 = 0
    /// Physical address of the time page (for mapping into user space).
    nonisolated(unsafe) private(set) static var timePage: UInt64 = 0

    /// Finds the counter frequency and starts the clock at 0. Interrupts
    /// should be masked (calibration on amd64 times a short interval).
    static func initialize(_ acpi: AcpiTables) -> Bool {
        let kind: UInt32
        #if arch(x86_64)
        frequency = X86TimeSources.tscFrequency(acpi)
        source = X86TimeSources.calibratedBy
        kind = CROI_COUNTER_TSC
        #elseif arch(arm64)
        frequency = arch_counter_frequency()
        source = "CNTFRQ_EL0"
        kind = CROI_COUNTER_ARM_VIRTUAL
        #elseif arch(riscv64)
        frequency = rhctTimebase(acpi)
        source = "RHCT timebase"
        kind = CROI_COUNTER_RISCV_TIME
        #endif
        guard frequency > 0, frequency < 1 << 40 else { return false }
        mult = (1_000_000_000 << 32) / frequency
        base = arch_counter_read()

        guard let page = pmm.allocatePage(.wired) else { return false }
        timePage = page
        let time = unsafe UnsafeMutablePointer<croi_time_page_t>(bitPattern: UInt(KernelLayout.physmap(page)))!
        unsafe time.initialize(to: croi_time_page_t())
        unsafe time.pointee.sequence = 1  // odd: being written
        unsafe time.pointee.version = CROI_TIME_PAGE_VERSION
        unsafe time.pointee.counter_kind = kind
        unsafe time.pointee.counter_frequency = frequency
        unsafe time.pointee.counter_base = base
        unsafe time.pointee.ns_mult = mult
        unsafe time.pointee.sequence = 2
        return true
    }

    /// Monotonic nanoseconds.
    static func now() -> UInt64 { nanoseconds(counter: arch_counter_read()) }

    static func nanoseconds(counter: UInt64) -> UInt64 {
        let product = (counter &- base).multipliedFullWidth(by: mult)
        return product.high << 32 | product.low >> 32
    }

    /// The counter value at monotonic time `ns` (saturating).
    static func counter(atNanoseconds ns: UInt64) -> UInt64 {
        let product = ns.multipliedFullWidth(by: frequency)
        guard product.high < 1_000_000_000 else { return .max }
        let (ticks, overflow) = base.addingReportingOverflow(UInt64(1_000_000_000).dividingFullWidth(product).quotient)
        return overflow ? .max : ticks
    }

    /// Busy-waits at least `ns` nanoseconds.
    static func delay(nanoseconds ns: UInt64) {
        let end = now() + ns
        while now() < end {
            arch_spin_pause()
        }
    }

    #if arch(riscv64)
    /// RHCT time base frequency (offset 40).
    private static func rhctTimebase(_ acpi: AcpiTables) -> UInt64 {
        guard let rhct = acpi.table("RHCT") else { return 0 }
        return acpi.withTable(rhct) { (table: RawSpan) -> UInt64 in
            table.byteCount >= 48 ? table.load(fromByteOffset: 40, as: UInt64.self) : 0
        }
    }
    #endif
}

#if arch(x86_64)
/// TSC frequency: CPUID leaf 0x15 when it gives one, else timed against
/// the HPET. Also calibrates the local APIC timer (the fallback when
/// TSC-deadline mode is missing).
enum X86TimeSources {
    nonisolated(unsafe) private(set) static var calibratedBy: StaticString = "none"
    /// Local APIC timer ticks per second at divide-by-16.
    nonisolated(unsafe) private(set) static var apicTimerFrequency: UInt64 = 0

    static func tscFrequency(_ acpi: AcpiTables) -> UInt64 {
        var regs = InlineArray<4, UInt32>(repeating: 0)
        cpuid(0, &regs)
        if regs[0] >= 0x15 {
            cpuid(0x15, &regs)  // eax: denominator, ebx: numerator, ecx: crystal Hz
            if regs[0] != 0, regs[1] != 0, regs[2] != 0 {
                calibratedBy = "CPUID 0x15"
                let tsc = UInt64(regs[2]) * UInt64(regs[1]) / UInt64(regs[0])
                calibrateApicTimer(tscFrequency: tsc)
                return tsc
            }
        }
        guard let hpet = acpi.table("HPET") else { return 0 }
        let address = acpi.withTable(hpet) { (table: RawSpan) -> UInt64 in
            table.byteCount >= 52 ? table.load(fromByteOffset: 44, as: UInt64.self) : 0
        }
        guard address != 0 else { return 0 }
        let mmio: UInt64
        do throws(VmError) {
            mmio = try kernelAspace.mapPhysical(address & ~(KernelLayout.pageSize - 1), size: KernelLayout.pageSize,
                                                MapAttributes(writable: true, cache: .device, global: true))
                + (address & (KernelLayout.pageSize - 1))
        } catch {
            return 0
        }
        let period = read64(mmio) >> 32  // femtoseconds per HPET tick
        guard period > 0, period <= 100_000_000 else { return 0 }
        write64(mmio + 0x10, read64(mmio + 0x10) | 1)  // ENABLE_CNF

        // 10 ms of HPET ticks, timed by the TSC.
        let ticks = 10_000_000_000_000 / period
        let h0 = read64(mmio + 0xF0)
        let t0 = arch_counter_read()
        var h1 = h0
        while h1 &- h0 < ticks {
            h1 = read64(mmio + 0xF0)
        }
        let t1 = arch_counter_read()
        let femtoseconds = (h1 &- h0) * period
        let scaled = (t1 &- t0).multipliedFullWidth(by: 1_000_000_000_000_000)
        guard femtoseconds > scaled.high else { return 0 }
        calibratedBy = "HPET"
        let tsc = femtoseconds.dividingFullWidth(scaled).quotient
        calibrateApicTimer(tscFrequency: tsc)
        return tsc
    }

    /// Counts local APIC timer ticks over 10 ms of TSC.
    private static func calibrateApicTimer(tscFrequency: UInt64) {
        LocalApic.write(LocalApic.timerDivide, 0x3)          // divide by 16
        LocalApic.write(LocalApic.lvtTimer, 1 << 16)         // masked, one-shot
        LocalApic.write(LocalApic.timerInitial, 0xFFFF_FFFF)
        let end = arch_counter_read() + tscFrequency / 100
        while arch_counter_read() < end {}
        let elapsed = 0xFFFF_FFFF - UInt64(LocalApic.read(LocalApic.timerCurrent))
        LocalApic.write(LocalApic.timerInitial, 0)
        apicTimerFrequency = elapsed * 100
    }

    private static func cpuid(_ leaf: UInt32, _ regs: inout InlineArray<4, UInt32>) {
        var span = regs.mutableSpan
        span.withUnsafeMutableBufferPointer { unsafe arch_cpuid(leaf, 0, $0.baseAddress!) }
    }
    private static func read64(_ address: UInt64) -> UInt64 {
        unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: UInt(address)).load()
    }
    private static func write64(_ address: UInt64, _ value: UInt64) {
        unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: UInt(address)).store(value)
    }
}
#endif
