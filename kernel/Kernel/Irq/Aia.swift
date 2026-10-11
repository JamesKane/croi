import _Volatile
import CKernel
import Fmt
import PageTables

#if arch(riscv64)
/// RISC-V AIA (K12i; the Advanced Interrupt Architecture 1.0): an IMSIC
/// interrupt file per hart, which MSIs (a device writing an identity to a
/// hart's file) and wired interrupts alike arrive at, the latter through
/// an APLIC in MSI delivery mode. Used where the MADT has an IMSIC and an
/// APLIC and every hart has Ssaia; the PLIC otherwise (Interrupts.swift).
///
/// Identities are global across harts: a wired source s is identity s on
/// whichever hart it is routed to (APLIC target: hart index, EIID s);
/// MSIs take consecutive, aligned identities from the first multiple of 64
/// above the APLIC's sources (`allocate`). Every hart enables every
/// identity at start (eidelivery on, threshold 0, all eie bits), so
/// masking is the device's (MSI) or the APLIC's (setie/clrie), and moving
/// an MSI to another hart rewrites only its address.
///
/// A level source in MSI mode pends again only on a new rising edge, so
/// unmasking one also writes setipnum, which the APLIC honours only while
/// the line is still asserted.
///
/// Not yet: the RISC-V IOMMU's MSI page tables (remapping), guest files,
/// APLIC direct mode (IDCs), several sockets' APLICs.
enum Aia {
    nonisolated(unsafe) static var active = false
    nonisolated(unsafe) private static var aplic: UInt64 = 0  // virtual
    nonisolated(unsafe) private(set) static var gsiBase: UInt32 = 0
    nonisolated(unsafe) private(set) static var sources: UInt32 = 0
    nonisolated(unsafe) private(set) static var identities: UInt32 = 0  // S-mode identities, 1..<identities
    /// Per hart: its id, IMSIC file (physical) and APLIC hart index.
    nonisolated(unsafe) private static var harts = InlineArray<64, (hart: UInt64, file: UInt64, index: UInt32)>(
        repeating: (0, 0, 0))
    nonisolated(unsafe) private static var hartCount = 0
    nonisolated(unsafe) private static var msisInUse = InlineArray<32, UInt64>(repeating: 0)
    /// Interrupt objects by identity (MSIs), heap.
    nonisolated(unsafe) private static var handlers: UInt64 = 0
    /// Level-sensitive wired sources, a bit each (for unmask's setipnum).
    nonisolated(unsafe) private static var levelSources = InlineArray<16, UInt64>(repeating: 0)
    static let lock = SpinLock()

    static var msiFirst: UInt32 { (sources / 64 + 1) * 64 }

    // APLIC registers.
    private static var domaincfg: UInt64 { 0x0000 }
    private static func sourcecfg(_ s: UInt32) -> UInt64 { 0x0004 + UInt64(s - 1) * 4 }
    private static var setipnum: UInt64 { 0x1CDC }
    private static var setienum: UInt64 { 0x1EDC }
    private static var clrienum: UInt64 { 0x1FDC }
    private static func target(_ s: UInt32) -> UInt64 { 0x3004 + UInt64(s - 1) * 4 }

    private static func read(_ offset: UInt64) -> UInt32 {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(aplic + offset)).load()
    }
    private static func write(_ offset: UInt64, _ value: UInt32) {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(aplic + offset)).store(value)
    }

    /// Finds the IMSIC files and the S-level APLIC; true if AIA is to be
    /// used (then the PLIC isn't).
    static func initialize(_ acpi: AcpiTables) -> Bool {
        var aplicBase: UInt64 = 0, aplicSize: UInt64 = 0, fileSize: UInt64 = 0
        Madt.forEachEntry(acpi) { type, e in
            switch type {
            case 0x18 where e.byteCount >= 36 && hartCount < 64:  // RINTC: its IMSIC file
                let file = e.load(fromByteOffset: 24, as: UInt64.self)
                if file != 0 {
                    harts[hartCount] = (e.load(fromByteOffset: 8, as: UInt64.self), file, 0)
                    hartCount += 1
                    fileSize = UInt64(e.load(fromByteOffset: 32, as: UInt32.self))
                }
            case 0x19 where e.byteCount >= 16:  // IMSIC
                identities = UInt32(e.load(fromByteOffset: 8, as: UInt16.self)) + 1
            case 0x1A where e.byteCount >= 36 && aplicBase == 0:  // APLIC (the first: socket 0)
                sources = UInt32(e.load(fromByteOffset: 18, as: UInt16.self))
                gsiBase = e.load(fromByteOffset: 20, as: UInt32.self)
                aplicBase = e.load(fromByteOffset: 24, as: UInt64.self)
                aplicSize = UInt64(e.load(fromByteOffset: 32, as: UInt32.self))
            default: ()
            }
        }
        guard hartCount > 0, identities > 1, aplicBase != 0, fileSize != 0, RiscvIsa.everyHartHas("ssaia", acpi),
              let mapped = try? kernelAspace.mapPhysical(aplicBase, size: aplicSize,
                                                         MapAttributes(writable: true, cache: .device, global: true)),
              let objects = unsafe heap.allocate(size: Int(identities) * 8) else { return false }
        aplic = mapped
        unsafe objects.initializeMemory(as: UInt8.self, repeating: 0, count: Int(identities) * 8)
        handlers = UInt64(UInt(bitPattern: objects))
        // Hart index: the file's place among the files (one group).
        var lowest = UInt64.max
        for i in 0..<hartCount { lowest = min(lowest, harts[i].file) }
        for i in 0..<hartCount { harts[i].index = UInt32((harts[i].file - lowest) / fileSize) }
        fileStride = fileSize
        // Every source inactive and disabled; then MSI delivery on.
        write(domaincfg, 0)
        for s in 1...sources {
            write(clrienum, s)
            write(sourcecfg(s), 0)
        }
        write(domaincfg, 1 << 8 | 1 << 2)  // IE, DM: MSI delivery
        active = true
        return true
    }

    /// This hart's interrupt file: delivery on, threshold 0, every
    /// identity enabled; then the external interrupt.
    static func initializeThisCpu() {
        guard active else { return }
        arch_rv_imsic_write(0x70, 1)  // eidelivery
        arch_rv_imsic_write(0x72, 0)  // eithreshold: every identity
        var word: UInt32 = 0
        while word * 64 < identities {
            arch_rv_imsic_write(0xC0 + UInt64(word) * 2, ~0)  // eie (RV64: even registers only)
            word += 1
        }
        arch_rv_sie_set(1 << 9)  // SEIE
    }

    /// The supervisor interrupt files (K12j: the RISC-V IOMMU's MSI page
    /// tables): how many, each one's address and hart index, and their
    /// spacing (a hart's guest files follow its supervisor file).
    static var fileCount: Int { hartCount }
    static func file(_ i: Int) -> (address: UInt64, index: UInt32) { (harts[i].file, harts[i].index) }
    nonisolated(unsafe) private(set) static var fileStride: UInt64 = 0

    private static func hart(_ id: UInt64) -> (file: UInt64, index: UInt32)? {
        for i in 0..<hartCount where harts[i].hart == id { return (harts[i].file, harts[i].index) }
        return nil
    }

    // MARK: Wired sources (through the APLIC)

    static func isValid(_ gsi: UInt32) -> Bool {
        active && gsi > gsiBase && gsi - gsiBase <= sources && gsi - gsiBase < identities
    }

    /// Routes `gsi` (masked) to `hart` as its own identity. Controller
    /// lock held.
    static func route(_ gsi: UInt32, level: Bool, hart id: UInt64) -> Bool {
        guard let hart = hart(id) else { return false }
        let s = gsi - gsiBase
        write(clrienum, s)
        write(sourcecfg(s), level ? 6 : 4)  // level high, or rising edge
        write(target(s), hart.index << 18 | s)
        let bit: UInt64 = 1 << UInt64(s % 64)
        levelSources[Int(s / 64)] = level ? levelSources[Int(s / 64)] | bit : levelSources[Int(s / 64)] & ~bit
        return true
    }

    static func setMasked(_ gsi: UInt32, _ masked: Bool) {
        let s = gsi - gsiBase
        if masked {
            write(clrienum, s)
        } else {
            write(setienum, s)
            if levelSources[Int(s / 64)] & (1 << UInt64(s % 64)) != 0 { write(setipnum, s) }  // still asserted: again
        }
    }

    /// Every identity pending on this hart, claimed: wired sources as GSIs
    /// to `wired`, MSIs to `msi`.
    static func claimAll(_ wired: (UInt32) -> Void, _ msi: (UInt32) -> Void) {
        while true {
            let identity = UInt32(truncatingIfNeeded: arch_rv_imsic_claim() >> 16)
            guard identity != 0 else { return }
            if identity <= sources { wired(gsiBase + identity) } else { msi(identity) }
        }
    }

    // MARK: MSIs

    /// `count` (a power of two) consecutive, aligned identities; the first.
    static func allocate(count: UInt32) -> UInt32? {
        guard active else { return nil }
        return lock.withLock { () -> UInt32? in
            var first = msiFirst
            while first + count <= identities {
                var free = true
                for i in first..<(first + count) where msisInUse[Int(i / 64)] & (1 << UInt64(i % 64)) != 0 { free = false }
                if free {
                    for i in first..<(first + count) { msisInUse[Int(i / 64)] |= 1 << UInt64(i % 64) }
                    return first
                }
                first += count
            }
            return nil
        }
    }

    static func free(_ identity: UInt32, count: UInt32) {
        lock.withLock {
            for i in identity..<(identity + count) { msisInUse[Int(i / 64)] &= ~(1 << UInt64(i % 64)) }
        }
    }

    /// The message for `identity` on CPU `cpu`: its hart's file and the
    /// identity as data.
    static func message(cpu: Int, identity: UInt32) -> (address: UInt64, data: UInt32)? {
        let id = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(Smp.records[cpu]))!.pointee.hardwareId
        guard let hart = hart(id) else { return nil }
        return (hart.file, identity)
    }

    // (DeviceIrqs's table lock held for these.)
    static func setHandler(_ identity: UInt32, _ object: UInt64) {
        guard handlers != 0, identity < identities else { return }
        unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(handlers))![Int(identity)] = object
    }

    static func handler(_ identity: UInt32) -> UInt64 {
        guard handlers != 0, identity < identities else { return 0 }
        return unsafe UnsafePointer<UInt64>(bitPattern: UInt(handlers))![Int(identity)]
    }
}
#endif
