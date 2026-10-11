import _Volatile
import CKernel
import Synchronization
import PageTables

/// The monotonic clock: nanoseconds since kernel entry (K9f: so boot
/// budgets, such as entry to the first console frame, read straight off
/// it), from each arch's free-running counter (amd64 TSC, arm64
/// CNTVCT_EL0, rv64 `time`).
///
/// The conversion lives in a croi_time_page_t (time.h) so user space can
/// read the clock without a syscall once K6 maps the page; the kernel uses
/// the same fields.
enum Clock {
    nonisolated(unsafe) private(set) static var frequency: UInt64 = 0
    nonisolated(unsafe) private(set) static var source: StaticString = "none"
    nonisolated(unsafe) private static var base: UInt64 = 0
    /// The counter at kernel entry, the clock's zero.
    nonisolated(unsafe) private static var entry: UInt64 = 0
    nonisolated(unsafe) private static var mult: UInt64 = 0
    /// ns = (counter delta * multiplier) >> 32.
    static var multiplier: UInt64 { mult }
    /// Physical address of the time page (for mapping into user space).
    nonisolated(unsafe) private(set) static var timePage: UInt64 = 0

    /// Notes the counter at kernel entry (the first thing kernel_main does).
    static func markEntry() { entry = arch_counter_read() }

    /// Finds the counter frequency; the clock reads 0 at kernel entry. Interrupts
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
        base = entry != 0 ? entry : arch_counter_read()

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

    /// The first counter value at or after monotonic time `ns`
    /// (saturating): rounded up, so a timer armed for it never finds its
    /// deadline still ahead (K10f: rv64's 10 MHz timebase fired up to a
    /// tick early, and the interrupt that ran nothing was a wakeup).
    static func counter(atNanoseconds ns: UInt64) -> UInt64 {
        let product = ns.multipliedFullWidth(by: frequency)
        guard product.high < 1_000_000_000 else { return .max }
        let division = UInt64(1_000_000_000).dividingFullWidth(product)
        let (ticks, overflow) = base.addingReportingOverflow(division.quotient + (division.remainder != 0 ? 1 : 0))
        guard !overflow else { return .max }
        // `now` rounds through `mult`: step past any shortfall that leaves.
        var counter = ticks
        while nanoseconds(counter: counter) < ns, counter < .max { counter += 1 }
        return counter
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
        // A hypervisor's timing leaf (KVM/QEMU, VMware: EAX = TSC kHz): the
        // frequency it converts our TSC deadlines with. Ours from the HPET
        // was ~24 ppm off under KVM, so a 60 s deadline came 1.4 ms early.
        cpuid(1, &regs)
        if regs[2] & (1 << 31) != 0 {
            cpuid(0x4000_0000, &regs)
            if regs[0] >= 0x4000_0010 {
                cpuid(0x4000_0010, &regs)
                if regs[0] != 0 {
                    calibratedBy = "hypervisor leaf 0x40000010"
                    let tsc = UInt64(regs[0]) * 1000
                    calibrateApicTimer(tscFrequency: tsc)
                    return tsc
                }
            }
        }
        let hpetMapped = mapHpet(acpi)
        if let tsc = kvmTscFrequency() {
            calibratedBy = "kvmclock"
            calibrateApicTimer(tscFrequency: tsc)
            startSkew(hpetMapped)
            return tsc
        }
        guard let (mmio, period) = hpetMapped else { return 0 }

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
        startSkew(hpetMapped)
        return tsc
    }

    /// The HPET, mapped and counting, with its period (fs), if there is one.
    private static func mapHpet(_ acpi: AcpiTables) -> (mmio: UInt64, period: UInt64)? {
        guard let hpet = acpi.table("HPET") else { return nil }
        let address = acpi.withTable(hpet) { (table: RawSpan) -> UInt64 in
            table.byteCount >= 52 ? table.load(fromByteOffset: 44, as: UInt64.self) : 0
        }
        guard address != 0 else { return nil }
        let mmio: UInt64
        do throws(VmError) {
            mmio = try kernelAspace.mapPhysical(address & ~(KernelLayout.pageSize - 1), size: KernelLayout.pageSize,
                                                MapAttributes(writable: true, cache: .device, global: true))
                + (address & (KernelLayout.pageSize - 1))
        } catch {
            return nil
        }
        let period = read64(mmio) >> 32  // femtoseconds per HPET tick
        guard period > 0, period <= 100_000_000 else { return nil }
        write64(mmio + 0x10, read64(mmio + 0x10) | 1)  // ENABLE_CNF
        return (mmio, period)
    }

    // MARK: Skew (K10f)

    /// Under a hypervisor, the TSC deadline is turned into a host timer on
    /// the host's clock (NTP-disciplined), while our clock is the TSC at
    /// its nominal rate: KVM's 60 s deadline came ~1.7 ms early (~28 ppm).
    /// The HPET runs on the host's clock, so TSC time against HPET time
    /// over a second or more gives the skew, which `Timers` arms long
    /// deadlines later by.
    nonisolated(unsafe) private static var skewHpet: (mmio: UInt64, period: UInt64)? = nil
    nonisolated(unsafe) private static var skewBase: (tsc: UInt64, hpet: UInt64) = (0, 0)

    private static func startSkew(_ hpet: (mmio: UInt64, period: UInt64)?) {
        var regs = InlineArray<4, UInt32>(repeating: 0)
        cpuid(1, &regs)
        guard regs[2] & (1 << 31) != 0, let hpet else { return }  // hypervisors only
        skewHpet = hpet
        skewBase = (arch_counter_read(), read64(hpet.mmio + 0xF0))
    }

    /// How much slower our clock runs than the HPET's, in ppm (positive:
    /// hardware deadlines come early), over everything since boot (at
    /// least 100 ms); nil without a measurement.
    static func skewPpm() -> Int64? {
        guard let hpet = skewHpet else { return nil }
        let tsc = arch_counter_read() &- skewBase.tsc
        let hpetNs = (read64(hpet.mmio + 0xF0) &- skewBase.hpet).multipliedFullWidth(by: hpet.period)
        let ours = tsc.multipliedFullWidth(by: Clock.multiplier)
        let oursNs = Int64(ours.high << 32 | ours.low >> 32)
        let theirsNs = Int64(UInt64(1_000_000).dividingFullWidth(hpetNs).quotient)
        guard theirsNs >= 100_000_000 else { return nil }
        return (theirsNs - oursNs) * 1_000_000 / theirsNs
    }

    /// KVM's own TSC frequency, from one kvmclock reading: its
    /// tsc_to_system_mul and tsc_shift come from the same guest TSC kHz
    /// KVM converts TSC deadlines with (an HPET calibration was ~24 ppm
    /// off, and long deadlines fired early). The page is registered, read
    /// and unregistered; kvmclock isn't the kernel's clock.
    private static func kvmTscFrequency() -> UInt64? {
        var regs = InlineArray<4, UInt32>(repeating: 0)
        cpuid(1, &regs)
        guard regs[2] & (1 << 31) != 0 else { return nil }
        cpuid(0x4000_0000, &regs)
        // "KVMKVMKVM\0\0\0" in EBX ECX EDX.
        guard regs[1] == 0x4B4D_564B, regs[2] == 0x564B_4D56, regs[3] == 0x0000_004D, regs[0] >= 0x4000_0001 else {
            return nil
        }
        cpuid(0x4000_0001, &regs)
        guard regs[0] & (1 << 3) != 0 else { return nil }  // KVM_FEATURE_CLOCKSOURCE2
        guard let page = pmm.allocatePage(.wired) else { return nil }
        defer { pmm.free(page) }
        let record = unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(page)))!
        unsafe record.initializeMemory(as: UInt8.self, repeating: 0, count: 32)
        arch_wrmsr(0x4B56_4D01, page | 1)  // MSR_KVM_SYSTEM_TIME_NEW, enabled
        var mul: UInt32 = 0
        var shift: Int8 = 0
        for _ in 0..<1000 {  // pvclock_vcpu_time_info under its version seqlock
            let version = unsafe record.load(fromByteOffset: 0, as: UInt32.self)
            atomicMemoryFence(ordering: .acquiring)
            mul = unsafe record.load(fromByteOffset: 24, as: UInt32.self)
            shift = unsafe record.load(fromByteOffset: 28, as: Int8.self)
            atomicMemoryFence(ordering: .acquiring)
            if version & 1 == 0, version != 0, unsafe record.load(fromByteOffset: 0, as: UInt32.self) == version { break }
            mul = 0
        }
        arch_wrmsr(0x4B56_4D01, 0)  // off before the page goes back
        guard mul != 0, shift > -32, shift < 32 else { return nil }
        // ns = ((tsc << shift) * mul) >> 32: Hz = 1e9 * 2^32 / mul / 2^shift.
        let scaled = UInt64(1_000_000_000) << 32
        let hz = shift >= 0 ? scaled / UInt64(mul) >> UInt64(shift) : (scaled / UInt64(mul)) << UInt64(-shift)
        // KVM's mul comes from whole kHz: round to one.
        return (hz + 500) / 1000 * 1000
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
