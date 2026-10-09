import _Volatile
import CKernel
import PageTables

/// Interrupt handling (roadmap K2): one controller driver per arch behind
/// a common surface, and the dispatch every interrupt goes through.
///
/// Only IPIs are routed so far. Device interrupts (IOAPIC pins, GIC SPIs
/// and LPIs through the ITS, APLIC/IMSIC) are discovered and left masked
/// until drivers ask for them with an explicit CPU affinity (ext 8), and
/// MSI vectors come from the ranges reserved below (requirement 13).
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
        return true
        #elseif arch(arm64)
        guard GicV3.initializeBootCpu(acpi) else {
            summary = "GICv3 not found (GICv2 is not supported)"
            return false
        }
        summary = "GICv3, ITS at"
        detail = GicV3.itsBase
        return true
        #elseif arch(riscv64)
        RiscvInterrupts.initializeBootCpu(acpi)
        summary = "SBI IPIs; IMSIC/APLIC/PLIC count"
        detail = UInt64(RiscvInterrupts.controllers)
        return true
        #endif
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
        #if arch(x86_64)
        let vector = unsafe frame.pointee.vector
        switch vector {
        case UInt64(LocalApic.spuriousVector):
            return  // no EOI for spurious interrupts
        case UInt64(LocalApic.ipiVector):
            Ipi.handle()
        case UInt64(LocalApic.errorVector):
            LocalApic.clearErrors()
        default:
            unexpected(vector)
        }
        LocalApic.endOfInterrupt()
        #elseif arch(arm64)
        let intid = arch_gicv3_ack() & 0xFF_FFFF
        guard intid < 1020 else { return }  // spurious
        if intid == GicV3.ipiSgi {
            Ipi.handle()
        } else {
            unexpected(intid)
        }
        arch_gicv3_eoi(intid)
        #elseif arch(riscv64)
        let code = unsafe frame.pointee.scause & ~(1 << 63)
        if code == 1 {  // supervisor software interrupt
            arch_rv_sip_clear(1 << 1)
            Ipi.handle()
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
    /// Virtual address of the xAPIC registers (xAPIC mode only).
    nonisolated(unsafe) private static var mmio: UInt64 = 0

    private static var apicBaseMsr: UInt32 { 0x1B }

    // Register indices (xAPIC offset / 16; x2APIC MSR - 0x800).
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
        initializeThisCpu()
        return true
    }

    static func initializeThisCpu() {
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

    static func endOfInterrupt() { write(eoi, 0) }

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

    private static func write(_ register: UInt32, _ value: UInt32) {
        if x2apic {
            arch_wrmsr(0x800 + register, UInt64(value))
        } else {
            unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(mmio + UInt64(register) * 16)).store(value)
        }
    }
}

/// I/O APICs: every redirection entry masked until a driver routes it.
enum IoApic {
    /// Masks all pins of every IOAPIC in the MADT; returns how many pins.
    static func maskAll(_ acpi: AcpiTables) -> Int {
        var pins = 0
        Madt.forEachEntry(acpi) { type, entry in
            guard type == 1, entry.byteCount >= 12 else { return }  // I/O APIC
            let base = UInt64(entry.load(fromByteOffset: 4, as: UInt32.self))
            let window: UInt64
            do throws(VmError) {
                window = try kernelAspace.mapPhysical(base & ~(KernelLayout.pageSize - 1), size: KernelLayout.pageSize,
                                                      MapAttributes(writable: true, cache: .device, global: true))
            } catch {
                return
            }
            let mmio = window + (base & (KernelLayout.pageSize - 1))
            let count = Int((read(mmio, 1) >> 16) & 0xFF) + 1
            for pin in 0..<count {
                write(mmio, UInt32(0x10 + 2 * pin), 1 << 16)  // masked, vector 0
                write(mmio, UInt32(0x11 + 2 * pin), 0)
            }
            pins += count
        }
        return pins
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
    nonisolated(unsafe) private static var redistributorsSize: UInt64 = 0
    nonisolated(unsafe) private(set) static var itsBase: UInt64 = 0

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
        if version == 0 {  // "not specified": ask GICD_PIDR2
            version = UInt8((read32(distributor + 0xFFE8) >> 4) & 0xF)
        }
        guard version >= 3 else { return false }

        // Distributor: every SPI in Group 1, masked; affinity routing on.
        write32(distributor + 0x0, 0)
        waitForDistributor()
        let lines = Int((read32(distributor + 0x4) & 0x1F) + 1) * 32
        for n in 1..<(lines / 32) {
            write32(distributor + 0x80 + UInt64(n) * 4, ~0)    // IGROUPR: Group 1
            write32(distributor + 0x180 + UInt64(n) * 4, ~0)   // ICENABLER: masked
        }
        write32(distributor + 0x0, (1 << 4) | (1 << 1))  // ARE, EnableGrp1
        waitForDistributor()
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
        arch_gicv3_cpu_init()
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
/// RISC-V: IPIs through SBI (supervisor software interrupts). External
/// interrupt controllers (IMSIC, APLIC, PLIC) are only discovered so far.
enum RiscvInterrupts {
    nonisolated(unsafe) private(set) static var controllers = 0

    static func initializeBootCpu(_ acpi: AcpiTables) {
        Madt.forEachEntry(acpi) { type, _ in
            if type == 0x19 || type == 0x1A || type == 0x1B { controllers += 1 }  // IMSIC, APLIC, PLIC
        }
        initializeThisCpu()
    }

    static func initializeThisCpu() {
        arch_rv_sie_clear(~0)
        arch_rv_sip_clear(1 << 1)
        arch_rv_sie_set(1 << 1)  // SSIE: software interrupts (IPIs)
    }

    static func sendIpi(hart: UInt64) {
        let ipi: UInt64 = 0x73_5049  // "sPI"
        _ = arch_sbi_call(ipi, 0, 1, hart, 0)  // send_ipi(hart_mask = 1, hart_mask_base = hart)
    }
}
#endif
