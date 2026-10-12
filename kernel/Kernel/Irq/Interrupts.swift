import _Volatile
import CKernel
import PageTables

/// Interrupt handling (roadmap K2): one controller driver per arch behind
/// a common surface, and the dispatch every interrupt goes through.
///
/// Device interrupts (IOAPIC pins, GIC SPIs, PLIC sources) stay masked
/// until an interrupt object takes them (K9c, `DeviceIrqs`), routed to an
/// explicit CPU (ext 8). LPIs through the ITS, APLIC/IMSIC and MSI vectors
/// (requirement 13) come with K9d.
enum Interrupts {
    /// One line describing the controllers found, for the boot log.
    nonisolated(unsafe) private(set) static var summary: StaticString = "none"
    nonisolated(unsafe) private(set) static var detail: UInt64 = 0

    /// Global controllers, then this (the boot) CPU's local one.
    static func initializeBootCpu(_ acpi: AcpiTables) -> Bool {
        #if arch(x86_64)
        guard LocalApic.initializeBootCpu(acpi) else { return false }
        detail = UInt64(IoApic.maskAll(acpi))
        summary = LocalApic.x2apic ? "x2APIC, IOAPIC pins" : "xAPIC, IOAPIC pins"
        #elseif arch(arm64)
        guard GicV3.initializeBootCpu(acpi) else {
            summary = "GICv3 not found (GICv2 is not supported)"
            return false
        }
        summary = "GICv3, ITS at"
        detail = GicV3.itsBase
        #elseif arch(riscv64)
        RiscvInterrupts.initializeBootCpu(acpi)
        summary = Aia.active ? "SBI IPIs, AIA: APLIC sources to IMSICs, identities" : "SBI IPIs, PLIC sources; IMSIC/APLIC/PLIC count"
        detail = Aia.active ? UInt64(Aia.identities) : UInt64(RiscvInterrupts.controllers)
        #endif
        DeviceIrqs.initialize()
        return true
    }

    /// This CPU's local controller (secondaries).
    static func initializeThisCpu() {
        #if arch(x86_64)
        LocalApic.initializeThisCpu()
        #elseif arch(arm64)
        GicV3.initializeThisCpu()
        #elseif arch(riscv64)
        RiscvInterrupts.initializeThisCpu()
        #endif
    }

    /// Sends the IPI interrupt to the CPU whose record is `target`.
    static func sendIpi(_ target: UnsafePointer<PerCpu>) {
        let hardwareId = unsafe target.pointee.hardwareId
        #if arch(x86_64)
        LocalApic.sendFixed(apicId: hardwareId, vector: LocalApic.ipiVector)
        #elseif arch(arm64)
        GicV3.sendSgi(GicV3.ipiSgi, to: hardwareId)
        #elseif arch(riscv64)
        RiscvInterrupts.sendIpi(hart: hardwareId)
        #endif
    }

    /// Handles the interrupt described by `frame` (from arch_exception).
    static func handle(_ frame: UnsafeMutablePointer<arch_exception_frame_t>) {
        let percpu = unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!
        unsafe percpu.pointee.interruptFrame = UInt64(UInt(bitPattern: frame))
        unsafe percpu.pointee.interruptCount += 1
        defer { unsafe percpu.pointee.interruptFrame = 0 }
        #if arch(x86_64)
        let vector = unsafe frame.pointee.vector
        Trace.event(CROI_TRACE_IRQ, UInt16(CROI_TK_IRQ_ENTER), vector)
        defer { Trace.event(CROI_TRACE_IRQ, UInt16(CROI_TK_IRQ_EXIT), vector) }
        switch vector {
        case UInt64(LocalApic.spuriousVector):
            return  // no EOI for spurious interrupts
        case UInt64(LocalApic.ipiVector):
            Ipi.handle()
        case UInt64(Timers.vector):
            Timers.handleInterrupt()
        case UInt64(LocalApic.errorVector):
            LocalApic.clearErrors()
        case UInt64(Pmu.vector):
            unsafe Pmu.handleOverflow(frame)
        case UInt64(IoApic.firstVector)..<UInt64(IoApic.firstVector + IoApic.gsiLimit):
            DeviceIrqs.dispatch(UInt32(vector) - IoApic.firstVector)
        case UInt64(DeviceIrqs.msiFirstVector)..<UInt64(DeviceIrqs.msiFirstVector + DeviceIrqs.msiVectorCount):
            DeviceIrqs.dispatchMsi(UInt32(vector))
        default:
            unexpected(vector)
        }
        LocalApic.endOfInterrupt()
        #elseif arch(arm64)
        let intid = arch_gicv3_ack() & 0xFF_FFFF
        guard intid < 1020 || intid >= UInt64(Its.firstLpi) else { return }  // spurious
        Trace.event(CROI_TRACE_IRQ, UInt16(CROI_TK_IRQ_ENTER), intid)
        defer { Trace.event(CROI_TRACE_IRQ, UInt16(CROI_TK_IRQ_EXIT), intid) }
        if intid == GicV3.ipiSgi {
            Ipi.handle()
        } else if intid == Timers.intid {
            Timers.handleInterrupt()
        } else if intid == Pmu.intid, intid != 0 {
            unsafe Pmu.handleOverflow(frame)
        } else if intid >= UInt64(Its.firstLpi) {
            DeviceIrqs.dispatchMsi(UInt32(intid))  // an LPI: an MSI through the ITS
        } else if intid >= 32 {
            DeviceIrqs.dispatch(UInt32(intid))
        } else {
            unexpected(intid)
        }
        arch_gicv3_eoi(intid)
        #elseif arch(riscv64)
        let code = unsafe frame.pointee.scause & ~(1 << 63)
        Trace.event(CROI_TRACE_IRQ, UInt16(CROI_TK_IRQ_ENTER), code)
        defer { Trace.event(CROI_TRACE_IRQ, UInt16(CROI_TK_IRQ_EXIT), code) }
        if code == 1 {  // supervisor software interrupt
            arch_rv_sip_clear(1 << 1)
            Ipi.handle()
        } else if code == 5 {  // supervisor timer interrupt (set_timer clears it)
            Timers.handleInterrupt()
        } else if code == 13 {  // local counter overflow (Sscofpmf)
            unsafe Pmu.handleOverflow(frame)
        } else if code == 9, Aia.active {  // supervisor external interrupt: this hart's IMSIC file
            Aia.claimAll({ gsi in DeviceIrqs.dispatch(gsi) }, { identity in DeviceIrqs.dispatchMsi(identity) })
        } else if code == 9 {  // supervisor external interrupt: the PLIC
            while let gsi = Plic.claim() {
                DeviceIrqs.dispatch(gsi)
                Plic.complete(gsi)
            }
        } else {
            unexpected(code)
        }
        #endif
    }

    /// Masked sources shouldn't fire; note it rather than crash.
    nonisolated(unsafe) private(set) static var unexpectedCount = 0
    private static func unexpected(_ id: UInt64) {
        unexpectedCount += 1
    }
}

#if arch(x86_64)
/// The local APIC, in x2APIC mode when the CPU supports it.
enum LocalApic {
    static var ipiVector: UInt32 { 0xF0 }
    static var errorVector: UInt32 { 0xFE }
    static var spuriousVector: UInt32 { 0xFF }

    nonisolated(unsafe) private(set) static var x2apic = false
    /// KVM's paravirtual EOI (K14n): a page of per-CPU words (64 bytes
    /// apart) KVM sets bit 0 of when the interrupt it injected needs no EOI
    /// write; clearing it instead saves a VM exit per interrupt (~5 us on
    /// this host). 0: not under KVM, or `croi.pv_eoi=off`.
    nonisolated(unsafe) private static var pvEoiPage: UInt64 = 0
    /// Virtual address of the xAPIC registers (xAPIC mode only).
    nonisolated(unsafe) private static var mmio: UInt64 = 0

    private static var apicBaseMsr: UInt32 { 0x1B }

    // Register indices (xAPIC offset / 16; x2APIC MSR - 0x800).
    static var lvtTimer: UInt32 { 0x32 }
    static var timerInitial: UInt32 { 0x38 }
    static var timerCurrent: UInt32 { 0x39 }
    static var timerDivide: UInt32 { 0x3E }
    private static var tpr: UInt32 { 0x08 }
    private static var eoi: UInt32 { 0x0B }
    private static var svr: UInt32 { 0x0F }
    private static var esr: UInt32 { 0x28 }
    private static var lvtLint0: UInt32 { 0x35 }
    private static var lvtLint1: UInt32 { 0x36 }
    private static var lvtError: UInt32 { 0x37 }

    static func initializeBootCpu(_ acpi: AcpiTables) -> Bool {
        // The legacy PICs would otherwise deliver on vectors 8-15.
        if let header = Madt.header(acpi), header.flags & 1 != 0 {
            arch_outb(0x21, 0xFF)
            arch_outb(0xA1, 0xFF)
        }
        var regs = InlineArray<4, UInt32>(repeating: 0)
        var span = regs.mutableSpan
        span.withUnsafeMutableBufferPointer { unsafe arch_cpuid(1, 0, $0.baseAddress!) }
        x2apic = regs[2] & (1 << 21) != 0
        if !x2apic {
            let base = arch_rdmsr(apicBaseMsr) & 0x000F_FFFF_FFFF_F000
            do throws(VmError) {
                mmio = try kernelAspace.mapPhysical(base, size: KernelLayout.pageSize,
                                                    MapAttributes(writable: true, cache: .device, global: true))
            } catch {
                return false
            }
        }
        if kvmPvEoi, !BootOptions.has("croi.pv_eoi=off"), let page = pmm.allocatePage(.wired) {
            unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(page)))!
                .initializeMemory(as: UInt8.self, repeating: 0, count: Int(KernelLayout.pageSize))
            pvEoiPage = page
        }
        initializeThisCpu()
        return true
    }

    /// Whether KVM offers PV EOI (KVMKVMKVM leaf, KVM_FEATURE_PV_EOI).
    private static var kvmPvEoi: Bool {
        var regs = InlineArray<4, UInt32>(repeating: 0)
        var span = regs.mutableSpan
        span.withUnsafeMutableBufferPointer { unsafe arch_cpuid(1, 0, $0.baseAddress!) }
        guard regs[2] & (1 << 31) != 0 else { return false }
        span = regs.mutableSpan
        span.withUnsafeMutableBufferPointer { unsafe arch_cpuid(0x4000_0000, 0, $0.baseAddress!) }
        guard regs[1] == 0x4B4D_564B, regs[2] == 0x564B_4D56, regs[3] == 0x0000_004D, regs[0] >= 0x4000_0001 else {
            return false
        }
        span = regs.mutableSpan
        span.withUnsafeMutableBufferPointer { unsafe arch_cpuid(0x4000_0001, 0, $0.baseAddress!) }
        return regs[0] & (1 << 6) != 0
    }

    /// This CPU's PV EOI word, if any.
    private static var pvEoiWord: UnsafeMutablePointer<UInt32>? {
        guard pvEoiPage != 0 else { return nil }
        return unsafe UnsafeMutablePointer<UInt32>(bitPattern: UInt(KernelLayout.physmap(pvEoiPage) + UInt64(Cpu.current) * 64))
    }

    static func initializeThisCpu() {
        if pvEoiPage != 0 {
            arch_wrmsr(0x4B56_4D04, pvEoiPage + UInt64(Cpu.current) * 64 | 1)  // MSR_KVM_PV_EOI_EN
        }
        if x2apic {
            arch_wrmsr(apicBaseMsr, arch_rdmsr(apicBaseMsr) | (1 << 11) | (1 << 10))  // EN | EXTD
        }
        write(tpr, 0)
        write(lvtLint0, 1 << 16)  // masked
        write(lvtLint1, 1 << 16)
        write(lvtError, errorVector)
        clearErrors()
        write(svr, (1 << 8) | spuriousVector)  // APIC software enable
    }

    static func endOfInterrupt() {
        // KVM said it needs none. Tested and cleared in one instruction:
        // KVM may clear the bit itself at any VM exit (another interrupt
        // pending: then the write is needed), and a separate test and clear
        // skipped that write, leaving the vector in service for good (half
        // the full KVM boots hung).
        if let word = unsafe pvEoiWord, unsafe arch_test_and_clear_bit0(word) != 0 { return }
        write(eoi, 0)
    }

    static func clearErrors() {
        write(esr, 0)  // xAPIC: a write latches the current errors
        if !x2apic { write(esr, 0) }
    }

    /// A fixed-delivery IPI with this vector.
    static func sendFixed(apicId: UInt64, vector: UInt32) {
        _ = sendCommand(apicId: apicId, UInt64(vector) | (1 << 14))  // level: assert
    }

    /// Writes the interrupt command register. Also used for INIT/SIPI.
    static func sendCommand(apicId: UInt64, _ command: UInt64) -> Bool {
        if x2apic {
            arch_wrmsr(0x830, apicId << 32 | command)
            return true
        }
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(mmio + 0x310)).store(UInt32(apicId) << 24)
        let low = unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(mmio + 0x300))
        low.store(UInt32(command))
        for _ in 0..<1_000_000 where low.load() & (1 << 12) == 0 {
            return true  // delivered
        }
        return false
    }

    static func write(_ register: UInt32, _ value: UInt32) {
        if x2apic {
            arch_wrmsr(0x800 + register, UInt64(value))
        } else {
            unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(mmio + UInt64(register) * 16)).store(value)
        }
    }

    static func read(_ register: UInt32) -> UInt32 {
        if x2apic {
            return UInt32(truncatingIfNeeded: arch_rdmsr(0x800 + register))
        }
        return unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(mmio + UInt64(register) * 16)).load()
    }
}

/// I/O APICs: every redirection entry masked until a driver routes it
/// (K9c: interrupt objects, by GSI; vector 0x30 + GSI).
enum IoApic {
    private struct Chip {
        var mmio: UInt64 = 0
        var gsiBase: UInt32 = 0
        var pins: UInt32 = 0
        var id: UInt8 = 0  // the MADT's IOAPIC id (the DMAR's scopes name it)
    }
    nonisolated(unsafe) private static var chips = InlineArray<8, Chip>(repeating: Chip())
    nonisolated(unsafe) private static var chipCount = 0
    /// MADT interrupt source overrides: ISA IRQ -> GSI and MPS INTI flags.
    nonisolated(unsafe) private static var overrides = InlineArray<16, (isa: UInt8, gsi: UInt32, flags: UInt16)>(
        repeating: (0, 0, 0))
    nonisolated(unsafe) private static var overrideCount = 0

    /// Device vectors: 0x30 + GSI, below the MSI range K9d takes (0xB0+).
    static var firstVector: UInt32 { 0x30 }
    static var gsiLimit: UInt32 { 0x80 }

    /// Masks all pins of every IOAPIC in the MADT and records them and the
    /// overrides; returns how many pins.
    static func maskAll(_ acpi: AcpiTables) -> Int {
        var pins = 0
        Madt.forEachEntry(acpi) { type, entry in
            if type == 2, entry.byteCount >= 10, overrideCount < 16 {  // interrupt source override
                overrides[overrideCount] = (entry.load(fromByteOffset: 3, as: UInt8.self),
                                            entry.load(fromByteOffset: 4, as: UInt32.self),
                                            entry.load(fromByteOffset: 8, as: UInt16.self))
                overrideCount += 1
            }
            guard type == 1, entry.byteCount >= 12, chipCount < 8 else { return }  // I/O APIC
            let base = UInt64(entry.load(fromByteOffset: 4, as: UInt32.self))
            let window: UInt64
            do throws(VmError) {
                window = try kernelAspace.mapPhysical(base & ~(KernelLayout.pageSize - 1), size: KernelLayout.pageSize,
                                                      MapAttributes(writable: true, cache: .device, global: true))
            } catch {
                return
            }
            let mmio = window + (base & (KernelLayout.pageSize - 1))
            let count = (read(mmio, 1) >> 16) & 0xFF + 1
            for pin in 0..<count {
                write(mmio, 0x10 + 2 * pin, 1 << 16)  // masked, vector 0
                write(mmio, 0x11 + 2 * pin, 0)
            }
            chips[chipCount] = Chip(mmio: mmio, gsiBase: entry.load(fromByteOffset: 8, as: UInt32.self), pins: count,
                                    id: entry.load(fromByteOffset: 2, as: UInt8.self))
            chipCount += 1
            pins += Int(count)
        }
        return pins
    }

    /// The chip and pin of `gsi`.
    private static func pin(_ gsi: UInt32) -> (mmio: UInt64, pin: UInt32)? {
        for i in 0..<chipCount where gsi >= chips[i].gsiBase && gsi - chips[i].gsiBase < chips[i].pins {
            return (chips[i].mmio, gsi - chips[i].gsiBase)
        }
        return nil
    }

    static func isValid(_ gsi: UInt32) -> Bool { gsi < gsiLimit && pin(gsi) != nil }

    /// The GSI an ISA IRQ arrives on (an override, else the same number).
    static func remapIsa(_ irq: UInt32) -> UInt32 {
        for i in 0..<overrideCount where UInt32(overrides[i].isa) == irq { return overrides[i].gsi }
        return irq
    }

    /// What firmware says about `gsi`: an override's flags, else ISA
    /// (edge, active high) below 16 and PCI (level, active low) above.
    static func defaultMode(_ gsi: UInt32) -> (level: Bool, activeLow: Bool) {
        var level = gsi >= 16, low = gsi >= 16
        for i in 0..<overrideCount where overrides[i].gsi == gsi {
            let polarity = overrides[i].flags & 3, trigger = (overrides[i].flags >> 2) & 3
            if polarity == 1 { low = false } else if polarity == 3 { low = true }
            if trigger == 1 { level = false } else if trigger == 3 { level = true }
        }
        return (level, low)
    }

    /// Programs `gsi`'s entry (masked) for `vector`, mode and destination.
    /// Controller lock held.
    static func program(_ gsi: UInt32, level: Bool, activeLow: Bool, apicId: UInt64) {
        guard let (mmio, pin) = pin(gsi) else { return }
        var low: UInt32 = (firstVector + gsi) | 1 << 16                 // fixed, physical, masked
        if activeLow { low |= 1 << 13 }
        if level { low |= 1 << 15 }
        write(mmio, 0x10 + 2 * pin, 1 << 16)
        write(mmio, 0x11 + 2 * pin, UInt32(apicId) << 24)
        write(mmio, 0x10 + 2 * pin, low)
    }

    /// Programs `gsi`'s entry (masked) in the remappable format, pointing
    /// at interrupt remapping table entry `index` (bit 48; the index in bits
    /// 63:49 and 11). Vector and trigger mode match the entry's (EOI uses
    /// them). Controller lock held.
    static func programRemapped(_ gsi: UInt32, level: Bool, activeLow: Bool, index: Int) {
        guard let (mmio, pin) = pin(gsi) else { return }
        var low: UInt32 = (firstVector + gsi) | 1 << 16 | UInt32((index >> 15) & 1) << 11
        if activeLow { low |= 1 << 13 }
        if level { low |= 1 << 15 }
        write(mmio, 0x10 + 2 * pin, 1 << 16)
        write(mmio, 0x11 + 2 * pin, 1 << 16 | UInt32(index & 0x7FFF) << 17)
        write(mmio, 0x10 + 2 * pin, low)
    }

    /// Whether `body` holds for every IOAPIC's MADT id.
    static func allIds(_ body: (UInt8) -> Bool) -> Bool {
        for i in 0..<chipCount where !body(chips[i].id) { return false }
        return true
    }

    /// The source id `gsi`'s IOAPIC sends interrupts with, if the DMAR says.
    static func sourceId(_ gsi: UInt32) -> UInt16? {
        for i in 0..<chipCount where gsi >= chips[i].gsiBase && gsi - chips[i].gsiBase < chips[i].pins {
            return Dmar.ioApicSource(chips[i].id)
        }
        return nil
    }

    /// Masks or unmasks `gsi`. Controller lock held.
    static func setMasked(_ gsi: UInt32, _ masked: Bool) {
        guard let (mmio, pin) = pin(gsi) else { return }
        let low = read(mmio, 0x10 + 2 * pin)
        write(mmio, 0x10 + 2 * pin, masked ? low | 1 << 16 : low & ~(1 << 16))
    }

    private static func read(_ mmio: UInt64, _ register: UInt32) -> UInt32 {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(mmio)).store(register)
        return unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(mmio + 0x10)).load()
    }

    private static func write(_ mmio: UInt64, _ register: UInt32, _ value: UInt32) {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(mmio)).store(register)
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(mmio + 0x10)).store(value)
    }
}
#endif

#if arch(arm64)
/// GICv3: distributor, one redistributor per CPU, system-register CPU
/// interface. Single security state (QEMU virt without EL3).
enum GicV3 {
    static var ipiSgi: UInt64 { 0 }

    nonisolated(unsafe) private static var distributor: UInt64 = 0
    nonisolated(unsafe) private static var redistributors: UInt64 = 0
    nonisolated(unsafe) private static var redistributorsPhysical: UInt64 = 0
    nonisolated(unsafe) private static var redistributorsSize: UInt64 = 0
    nonisolated(unsafe) private(set) static var itsBase: UInt64 = 0
    /// Interrupt lines the distributor has (SPIs end below this).
    nonisolated(unsafe) private static var lines: UInt32 = 0

    static func initializeBootCpu(_ acpi: AcpiTables) -> Bool {
        var gicd: UInt64 = 0
        var version: UInt8 = 0
        var gicr: UInt64 = 0
        var gicrLength: UInt64 = 0
        Madt.forEachEntry(acpi) { type, e in
            switch type {
            case 0x0C where e.byteCount >= 21:  // GIC distributor
                gicd = e.load(fromByteOffset: 8, as: UInt64.self)
                version = e.load(fromByteOffset: 20, as: UInt8.self)
            case 0x0E where e.byteCount >= 16:  // GIC redistributor range
                gicr = e.load(fromByteOffset: 4, as: UInt64.self)
                gicrLength = UInt64(e.load(fromByteOffset: 12, as: UInt32.self))
            case 0x0F where e.byteCount >= 16:  // GIC ITS
                itsBase = e.load(fromByteOffset: 8, as: UInt64.self)
                RootFilter.recordKernelMmio(itsBase, 0x2_0000)  // control and translation frames
            default: ()
            }
        }
        guard gicd != 0, gicr != 0, gicrLength != 0 else { return false }
        let device = MapAttributes(writable: true, cache: .device, global: true)
        do throws(VmError) {
            distributor = try kernelAspace.mapPhysical(gicd, size: 0x1_0000, device)
            redistributors = try kernelAspace.mapPhysical(gicr, size: gicrLength, device)
        } catch {
            return false
        }
        redistributorsSize = gicrLength
        redistributorsPhysical = gicr
        if version == 0 {  // "not specified": ask GICD_PIDR2
            version = UInt8((read32(distributor + 0xFFE8) >> 4) & 0xF)
        }
        guard version >= 3 else { return false }

        // Distributor: every SPI in Group 1, masked; affinity routing on.
        write32(distributor + 0x0, 0)
        waitForDistributor()
        lines = min((read32(distributor + 0x4) & 0x1F + 1) * 32, 1020)
        for n in 1..<Int((lines + 31) / 32) {
            write32(distributor + 0x80 + UInt64(n) * 4, ~0)    // IGROUPR: Group 1
            write32(distributor + 0x180 + UInt64(n) * 4, ~0)   // ICENABLER: masked
        }
        write32(distributor + 0x0, (1 << 4) | (1 << 1))  // ARE, EnableGrp1
        waitForDistributor()
        if itsBase != 0, !Its.initialize(itsBase) { itsBase = 0 }  // K12h: MSIs
        initializeThisCpu()
        return true
    }

    /// Wakes this CPU's redistributor, masks its SGIs/PPIs except the IPI
    /// SGI, and enables the CPU interface.
    static func initializeThisCpu() {
        guard let frame = redistributorFrame() else { return }
        write32(frame + 0x14, read32(frame + 0x14) & ~(1 << 1))  // WAKER: clear ProcessorSleep
        while read32(frame + 0x14) & (1 << 2) != 0 {             // until ChildrenAsleep clears
            arch_spin_pause()
        }
        let sgi = frame + 0x1_0000
        write32(sgi + 0x80, ~0)    // IGROUPR0: Group 1
        write32(sgi + 0x180, ~0)   // ICENABLER0: everything masked
        for i in 0..<8 {
            write32(sgi + 0x400 + UInt64(i) * 4, 0x8080_8080)  // priorities
        }
        write32(sgi + 0x100, 1 << UInt32(ipiSgi))  // ISENABLER0
        while read32(frame) & (1 << 3) != 0 {      // GICR_CTLR.RWP
            arch_spin_pause()
        }
        Its.enableThisCpu(frame: frame, physicalFrame: redistributorsPhysical + (frame - redistributors))
        arch_gicv3_cpu_init()
    }

    /// Unmasks private interrupt (SGI/PPI) `intid` on this CPU.
    static func enablePrivate(_ intid: UInt64) {
        guard intid < 32, let frame = redistributorFrame() else { return }
        write32(frame + 0x1_0000 + 0x100, 1 << UInt32(intid))  // ISENABLER0
    }

    // MARK: SPIs (K9c: interrupt objects)

    static func isValidSpi(_ intid: UInt32) -> Bool { intid >= 32 && intid < lines }

    /// Whether the distributor has `intid` configured level-sensitive (the
    /// reset state, or firmware's).
    static func spiIsLevel(_ intid: UInt32) -> Bool {
        read32(distributor + 0xC00 + UInt64(intid / 16) * 4) & (2 << ((intid % 16) * 2)) == 0
    }

    /// Programs a (masked) SPI: trigger mode, priority, the CPU it goes to
    /// (MPIDR affinity as in PerCpu.hardwareId, which IROUTER shares).
    /// Controller lock held.
    static func programSpi(_ intid: UInt32, level: Bool, affinity: UInt64) {
        setSpiMasked(intid, true)
        let config = distributor + 0xC00 + UInt64(intid / 16) * 4
        let bit: UInt32 = 2 << ((intid % 16) * 2)
        write32(config, level ? read32(config) & ~bit : read32(config) | bit)
        let priority = distributor + 0x400 + UInt64(intid & ~3)
        let shift = (intid % 4) * 8
        write32(priority, read32(priority) & ~(0xFF << shift) | 0x80 << shift)
        unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: UInt(distributor + 0x6000 + UInt64(intid) * 8))
            .store(affinity & 0xFF_00FF_FFFF)
    }

    /// Masks (ICENABLER, waiting for it to take) or unmasks an SPI.
    static func setSpiMasked(_ intid: UInt32, _ masked: Bool) {
        write32(distributor + (masked ? 0x180 : 0x100) + UInt64(intid / 32) * 4, 1 << (intid % 32))
        if masked { waitForDistributor() }
    }

    /// Sends SGI `intid` to the CPU with MPIDR affinity `target` (as in
    /// PerCpu.hardwareId: Aff3 << 32 | Aff2 << 16 | Aff1 << 8 | Aff0).
    static func sendSgi(_ intid: UInt64, to target: UInt64) {
        let aff0 = target & 0xFF
        let aff1 = (target >> 8) & 0xFF
        let aff2 = (target >> 16) & 0xFF
        let aff3 = (target >> 32) & 0xFF
        let value = (1 << (aff0 & 15)) | aff1 << 16 | intid << 24 | aff2 << 32 | (aff0 >> 4) << 44 | aff3 << 48
        arch_gicv3_send_sgi(value)
    }

    /// This CPU's redistributor frame, matched by affinity in GICR_TYPER.
    private static func redistributorFrame() -> UInt64? {
        let mpidr = arch_cpu_hardware_id()
        let affinity = (mpidr & 0xFF) | ((mpidr >> 8) & 0xFF) << 8 | ((mpidr >> 16) & 0xFF) << 16 | ((mpidr >> 32) & 0xFF) << 24
        var frame = redistributors
        while frame < redistributors + redistributorsSize {
            let typer = read64(frame + 0x8)
            if typer >> 32 == affinity { return frame }
            if typer & (1 << 4) != 0 { break }                        // Last
            frame += typer & (1 << 1) != 0 ? 0x4_0000 : 0x2_0000     // VLPIS: 4 frames, else 2
        }
        return nil
    }

    private static func waitForDistributor() {
        while read32(distributor) & (1 << 31) != 0 {  // GICD_CTLR.RWP
            arch_spin_pause()
        }
    }

    private static func read32(_ address: UInt64) -> UInt32 {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(address)).load()
    }
    private static func write32(_ address: UInt64, _ value: UInt32) {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(address)).store(value)
    }
    private static func read64(_ address: UInt64) -> UInt64 {
        unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: UInt(address)).load()
    }
}
#endif

#if arch(riscv64)
/// RISC-V: IPIs through SBI (supervisor software interrupts); device
/// interrupts through the PLIC (K9c; QEMU virt's default). IMSIC/APLIC
/// are only counted.
enum RiscvInterrupts {
    nonisolated(unsafe) private(set) static var controllers = 0

    static func initializeBootCpu(_ acpi: AcpiTables) {
        Madt.forEachEntry(acpi) { type, _ in
            if type == 0x19 || type == 0x1A || type == 0x1B { controllers += 1 }  // IMSIC, APLIC, PLIC
        }
        if !Aia.initialize(acpi) { Plic.initialize(acpi) }  // K12i: AIA where there is one
        initializeThisCpu()
    }

    static func initializeThisCpu() {
        arch_rv_sie_clear(~0)
        arch_rv_sip_clear(1 << 1)
        arch_rv_sie_set(1 << 1)  // SSIE: software interrupts (IPIs)
        if Aia.active {
            Aia.initializeThisCpu()
        } else if Plic.initializeThisCpu() {
            arch_rv_sie_set(1 << 9)  // SEIE: external interrupts
        }
    }

    static func sendIpi(hart: UInt64) {
        let ipi: UInt64 = 0x73_5049  // "sPI"
        _ = arch_sbi_call(ipi, 0, 1, hart, 0)  // send_ipi(hart_mask = 1, hart_mask_base = hart)
    }
}

/// The platform-level interrupt controller: sources 1..<count (GSI =
/// gsiBase + source), one context per hart's S mode (the RINTC's
/// external interrupt controller ID). A source is masked by priority 0
/// and routed by enabling it in one context.
enum Plic {
    nonisolated(unsafe) private static var mmio: UInt64 = 0
    nonisolated(unsafe) private(set) static var gsiBase: UInt32 = 0
    nonisolated(unsafe) private(set) static var count: UInt32 = 0
    /// Each hart's S-mode context.
    nonisolated(unsafe) private static var contexts = InlineArray<64, (hart: UInt64, context: UInt32)>(
        repeating: (0, 0))
    nonisolated(unsafe) private static var contextCount = 0

    static func initialize(_ acpi: AcpiTables) {
        var base: UInt64 = 0, size: UInt64 = 0
        Madt.forEachEntry(acpi) { type, e in
            switch type {
            case 0x1B where e.byteCount >= 36 && base == 0:  // PLIC (the first)
                count = UInt32(e.load(fromByteOffset: 12, as: UInt16.self)) + 1
                size = UInt64(e.load(fromByteOffset: 20, as: UInt32.self))
                base = e.load(fromByteOffset: 24, as: UInt64.self)
                gsiBase = e.load(fromByteOffset: 32, as: UInt32.self)
            case 0x18 where e.byteCount >= 24 && contextCount < 64:  // RINTC
                contexts[contextCount] = (e.load(fromByteOffset: 8, as: UInt64.self),
                                          e.load(fromByteOffset: 20, as: UInt32.self) & 0xFFFF)
                contextCount += 1
            default: ()
            }
        }
        guard base != 0, size != 0 else { return }
        do throws(VmError) {
            mmio = try kernelAspace.mapPhysical(base, size: size,
                                                MapAttributes(writable: true, cache: .device, global: true))
        } catch {
            return
        }
        for source in 1..<count { write(UInt64(source) * 4, 0) }  // priority 0: masked
        for i in 0..<contextCount {
            for word in 0..<(count + 31) / 32 { write(enable(contexts[i].context) + UInt64(word) * 4, 0) }
        }
    }

    /// Opens this hart's context (threshold 0). False with no PLIC.
    static func initializeThisCpu() -> Bool {
        guard mmio != 0, let context = context(of: thisHart) else { return false }
        write(0x20_0000 + UInt64(context) * 0x1000, 0)
        return true
    }

    static func context(of hart: UInt64) -> UInt32? {
        for i in 0..<contextCount where contexts[i].hart == hart { return contexts[i].context }
        return nil
    }

    static func isValid(_ gsi: UInt32) -> Bool { mmio != 0 && gsi > gsiBase && gsi - gsiBase < count }

    /// Routes `gsi`'s source to `hart` only (masked until unmasked).
    /// Controller lock held.
    static func route(_ gsi: UInt32, hart: UInt64) -> Bool {
        guard let target = context(of: hart) else { return false }
        let source = gsi - gsiBase
        setMasked(gsi, true)
        for i in 0..<contextCount {
            let word = enable(contexts[i].context) + UInt64(source / 32) * 4
            let bit: UInt32 = 1 << (source % 32)
            write(word, contexts[i].context == target ? read(word) | bit : read(word) & ~bit)
        }
        return true
    }

    static func setMasked(_ gsi: UInt32, _ masked: Bool) {
        write(UInt64(gsi - gsiBase) * 4, masked ? 0 : 1)
    }

    /// The next pending source for this hart's context (0: none), as a GSI.
    static func claim() -> UInt32? {
        guard let context = context(of: thisHart) else { return nil }
        let source = read(0x20_0004 + UInt64(context) * 0x1000)
        return source == 0 ? nil : gsiBase + source
    }

    static func complete(_ gsi: UInt32) {
        guard let context = context(of: thisHart) else { return }
        write(0x20_0004 + UInt64(context) * 0x1000, gsi - gsiBase)
    }

    private static func enable(_ context: UInt32) -> UInt64 { 0x2000 + UInt64(context) * 0x80 }

    /// S mode can't read its hart ID: the PerCpu record has it.
    private static var thisHart: UInt64 {
        unsafe UnsafePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!.pointee.hardwareId
    }

    private static func read(_ offset: UInt64) -> UInt32 {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(mmio + offset)).load()
    }
    private static func write(_ offset: UInt64, _ value: UInt32) {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(mmio + offset)).store(value)
    }
}
#endif
