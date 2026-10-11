import _Volatile
import CKernel
import Fmt
import PageTables
import Synchronization

#if arch(riscv64)
/// The RISC-V IOMMU (K12e; the RISC-V IOMMU Architecture Specification
/// 1.0). croi's ABI, as AMD-Vi's (Zircon has none):
/// iommu_create(CROI_IOMMU_TYPE_RISCV, { register_base }), the base an
/// ACPI RIMT IOMMU node gives (a PCIe-based IOMMU: its BAR 0); bti_create's
/// id is the PCI requester id, which the RIMT maps to a device id.
///
/// One `RiscvIommuUnit` per IOMMU, brought up at boot (`boot`; skipped if
/// firmware left it translating), bound by iommu_create. Bring-up builds a device directory (2 levels of base
/// 32-byte device contexts, or 3 of extended 64-byte ones where MSI_FLAT
/// makes them extended) with a pass-through context (valid, both stages
/// Bare) for every device id the RIMT routes there, so devices keep
/// working; a command queue (each batch ends with IOFENCE.C writing a
/// sequence number the CPU polls) and a fault queue. A claimed device's
/// context gets first-stage translation (Sv48, else Sv39) through an
/// `IoDomain` (PSCID = domain id); a released one is invalid, so its
/// DMA faults.
///
/// Faults are read from the queue when counted and before each unmap's
/// invalidation returns, not by interrupt: the IOMMU's interrupts are MSIs
/// to an IMSIC (not supported yet) or wired lines the RIMT may list.
/// Not yet: interrupt remapping (MSI page tables), PCIe ATS/PRI, process
/// directories, the second stage.
enum RiscvIommus {
    nonisolated(unsafe) static var units = InlineArray<4, UInt64>(repeating: 0)
    nonisolated(unsafe) static var unitCount = 0
    static let unitsLock = Mutex()
    // Registers.
    static var capabilities: UInt64 { 0x00 }
    static var featureControl: UInt64 { 0x08 }
    static var ddtp: UInt64 { 0x10 }
    static var cqb: UInt64 { 0x18 }
    static var cqh: UInt64 { 0x20 }
    static var cqt: UInt64 { 0x24 }
    static var fqb: UInt64 { 0x28 }
    static var fqh: UInt64 { 0x30 }
    static var fqt: UInt64 { 0x34 }
    static var cqcsr: UInt64 { 0x48 }
    static var fqcsr: UInt64 { 0x4C }
    static var ipsr: UInt64 { 0x54 }

    /// Queues: 256 commands of 16 bytes, 128 fault records of 32.
    static var commandLog2: UInt64 { 8 }
    static var faultLog2: UInt64 { 7 }

    static func create(_ descriptor: RawSpan) throws(Status) -> UInt64 {
        guard descriptor.byteCount == MemoryLayout<UInt64>.size else { throw .invalidArgs }
        let base = unsafe descriptor.unsafeLoadUnaligned(as: UInt64.self)
        guard base != 0, base % KernelLayout.pageSize == 0 else { throw .invalidArgs }
        var index = -1
        for i in 0..<Rimt.count where Rimt.registerBase(i) == base { index = i }
        guard index >= 0 else { throw .notFound }
        unitsLock.lock()
        defer { unitsLock.unlock() }
        for i in 0..<unitCount where RiscvIommuUnitPointer(address: units[i]).pointee.registerBase == base {
            let unit = RiscvIommuUnitPointer(address: units[i])
            guard !unit.pointee.bound else { throw .alreadyBound }
            unit.pointee.bound = true
            return unit.address
        }
        throw .notSupported  // in the RIMT, but boot couldn't bring it up
    }

    /// Brings up every RIMT IOMMU at boot, every device it covers in pass-
    /// through: firmware may leave one off, which blocks its devices
    /// (QEMU's resets that way), MSIs included. iommu_create binds them.
    static func boot(_ console: Uart) {
        for i in 0..<Rimt.count where unitCount < units.count {
            guard let base = Rimt.registerBase(i), let unit = try? RiscvIommuUnitPointer.make(i, base: base) else { continue }
            units[unitCount] = unit.address
            unitCount += 1
        }
        guard unitCount > 0 else { return }
        console.write("  iommu:  RISC-V IOMMU, ")
        console.write(decimal: UInt64(unitCount))
        console.write(unitCount == 1 ? " unit, devices passed through\n" : " units, devices passed through\n")
    }

    static func unbind(_ address: UInt64) {
        unitsLock.lock()
        RiscvIommuUnitPointer(address: address).pointee.bound = false
        unitsLock.unlock()
    }

    static func faultsCounted() -> UInt64 {
        var total: UInt64 = 0
        for i in 0..<unitCount {
            let unit = RiscvIommuUnitPointer(address: units[i])
            unit.pointee.lock.withLock { unit.drainFaultsLocked() }
            total += unit.pointee.faults
        }
        return total
    }

    // MARK: Devices

    /// Claims the device with requester id `rid`: its context translated
    /// through a domain of its own.
    static func attach(_ unit: RiscvIommuUnitPointer, requesterId rid: UInt16) throws(Status) -> IoDomainPointer {
        guard let did = Rimt.deviceId(rid, iommu: unit.pointee.rimtIndex), did <= unit.pointee.maxDevice else {
            throw .outOfRange
        }
        let id = try unit.pointee.lock.withLock { () throws(Status) -> UInt16 in
            let context = unsafe unit.context(did)
            if unsafe context[0] & 1 != 0, unsafe context[3] >> 60 != 0 { throw .alreadyBound }  // first stage on: claimed
            for id in 1..<1024 where unit.pointee.domains[id / 64] & (1 << UInt64(id % 64)) == 0 {
                unit.pointee.domains[id / 64] |= 1 << UInt64(id % 64)
                return UInt16(id)
            }
            throw .noResources
        }
        let levels = unit.pointee.sv48 ? 4 : 3
        guard let domain = IoDomains.make(.riscv, unit: unit.address, id: id, deviceId: rid, levels: levels) else {
            unit.pointee.lock.withLock { unit.pointee.domains[Int(id) / 64] &= ~(1 << UInt64(id % 64)) }
            throw .noMemory
        }
        domain.pointee.extra = UInt64(did)
        do throws(Status) {
            try mapInterruptFiles(domain, unit)
            try unit.pointee.lock.withLock { () throws(Status) in
                let context = unsafe unit.context(did)
                // Invalid while it changes, then first stage on.
                unsafe context[0] = 0
                try unit.invalidateDeviceLocked(did, domain: nil)
                unsafe context[1] = 0                                                   // second stage Bare
                unsafe context[2] = UInt64(id) << 12                                    // PSCID
                unsafe context[3] = (unit.pointee.sv48 ? 9 : 8) << 60 | domain.pointee.root >> 12  // Sv48/Sv39, PPN
                if unit.pointee.extendedContexts, unit.pointee.msiTable != 0 {
                    // MSIs: writes to the supervisor files, through the MSI page table.
                    unsafe context[4] = 1 << 60 | unit.pointee.msiTable >> 12  // msiptp: Flat
                    unsafe context[5] = unit.pointee.msiMask
                    unsafe context[6] = unit.pointee.msiPattern
                }
                arch_device_write_barrier()
                unsafe context[0] = 1                                                   // valid
                try unit.invalidateDeviceLocked(did, domain: id)
            }
        } catch {
            IoDomains.free(domain)
            unit.pointee.lock.withLock { unit.pointee.domains[Int(id) / 64] &= ~(1 << UInt64(id % 64)) }
            throw error
        }
        return domain
    }

    /// The device's context goes invalid (its DMA faults), then the domain.
    static func detach(_ domain: IoDomainPointer) {
        let unit = RiscvIommuUnitPointer(address: domain.pointee.unit)
        let did = UInt32(domain.pointee.extra), id = domain.pointee.domainId
        unit.pointee.lock.withLock {
            let context = unsafe unit.context(did)
            unsafe context[0] = 0
            unsafe context[3] = 0
            if unit.pointee.extendedContexts { unsafe context[4] = 0 }
            try? unit.invalidateDeviceLocked(did, domain: id)
            unit.pointee.domains[Int(id) / 64] &= ~(1 << UInt64(id % 64))
        }
        IoDomains.free(domain)
    }
}

extension RiscvIommus {
    /// K12j: a claimed device's MSIs. Its writes to the harts' supervisor
    /// interrupt files pass the first stage at their own addresses (they
    /// are identity mapped, as SMMUv3 domains map the ITS doorbell), and
    /// with MSI_FLAT the context's MSI page table (one per unit, built
    /// here once) then routes them, write-through, to those files only:
    /// the address pattern covers the files, one entry per hart index.
    /// The data (the identity) isn't restricted: that would take MRIF mode
    /// or guest files of its own.
    static func mapInterruptFiles(_ domain: IoDomainPointer, _ unit: RiscvIommuUnitPointer) throws(Status) {
        guard Aia.active, Aia.fileCount > 0 else { return }
        for i in 0..<Aia.fileCount {
            try IoDomains.identityMap(domain, Aia.file(i).address, KernelLayout.pageSize)
        }
        guard unit.pointee.extendedContexts else { return }
        try unit.pointee.lock.withLock { () throws(Status) in
            guard unit.pointee.msiTable == 0 else { return }
            var lowest = UInt64.max, highest: UInt32 = 0
            for i in 0..<Aia.fileCount {
                lowest = min(lowest, Aia.file(i).address)
                highest = max(highest, Aia.file(i).index)
            }
            var bits: UInt64 = 0
            while 1 << bits <= UInt64(highest) { bits += 1 }
            var strideShift: UInt64 = 0
            while (KernelLayout.pageSize << strideShift) < Aia.fileStride { strideShift += 1 }
            guard bits <= 8, let table = IoDomains.zeroedPage() else { throw .noMemory }
            for i in 0..<Aia.fileCount {
                let (address, index) = Aia.file(i)
                let entry = unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(table)) + UInt(index) * 16)!
                unsafe entry[1] = 0
                unsafe entry[0] = (address >> 12) << 10 | 3 << 1 | 1  // PPN, M basic (write-through), V
            }
            arch_device_write_barrier()
            unit.pointee.msiMask = ((1 << bits) - 1) << strideShift
            unit.pointee.msiPattern = (lowest >> 12) & ~unit.pointee.msiMask
            unit.pointee.msiTable = table
        }
    }
}

/// ACPI's RIMT (RISC-V IO Mapping Table): IOMMUs and how PCI requester ids
/// reach them as device ids.
enum Rimt {
    struct Iommu {
        var base: UInt64 = 0      // 0: PCIe-based (its BAR 0)
        var pci = false
        var segment: UInt16 = 0
        var bdf: UInt16 = 0
        var offset: UInt32 = 0    // the node's offset in the RIMT
    }

    struct Mapping {
        var sourceBase: UInt32 = 0
        var count: UInt32 = 0
        var destinationBase: UInt32 = 0
        var iommu = 0
    }

    nonisolated(unsafe) static var iommus = InlineArray<4, Iommu>(repeating: Iommu())
    nonisolated(unsafe) static var count = 0
    nonisolated(unsafe) static var mappings = InlineArray<16, Mapping>(repeating: Mapping())
    nonisolated(unsafe) static var mappingCount = 0

    static func initialize(_ acpi: AcpiTables) {
        guard let rimt = acpi.table("RIMT") else { return }
        acpi.withTable(rimt) { (table: RawSpan) in
            guard table.byteCount >= 48 else { return }
            let nodes = Int(unsafe table.unsafeLoadUnaligned(fromByteOffset: 36, as: UInt32.self))
            let first = Int(unsafe table.unsafeLoadUnaligned(fromByteOffset: 40, as: UInt32.self))
            // IOMMU nodes (type 0) first, so root complexes can name them.
            for pass in 0..<2 {
                var at = first
                for _ in 0..<nodes {
                    guard at + 8 <= table.byteCount else { return }
                    let type = table.load(fromByteOffset: at, as: UInt8.self)
                    let length = Int(unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 2, as: UInt16.self))
                    guard length >= 8, at + length <= table.byteCount else { return }
                    if pass == 0, type == 0, length >= 40, count < iommus.count {
                        iommus[count] = Iommu(
                            base: unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 16, as: UInt64.self),
                            pci: unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 24, as: UInt32.self) & 1 != 0,
                            segment: unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 32, as: UInt16.self),
                            bdf: unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 34, as: UInt16.self),
                            offset: UInt32(at))
                        count += 1
                    } else if pass == 1, type == 1, length >= 20 {
                        let array = Int(unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 16, as: UInt16.self))
                        let entries = Int(unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 18, as: UInt16.self))
                        for m in 0..<entries {
                            let entry = at + array + 20 * m
                            guard entry + 20 <= at + length, mappingCount < mappings.count else { break }
                            let target = unsafe table.unsafeLoadUnaligned(fromByteOffset: entry + 12, as: UInt32.self)
                            for i in 0..<count where iommus[i].offset == target {
                                mappings[mappingCount] = Mapping(
                                    sourceBase: unsafe table.unsafeLoadUnaligned(fromByteOffset: entry, as: UInt32.self),
                                    count: unsafe table.unsafeLoadUnaligned(fromByteOffset: entry + 4, as: UInt32.self),
                                    destinationBase: unsafe table.unsafeLoadUnaligned(fromByteOffset: entry + 8, as: UInt32.self),
                                    iommu: i)
                                mappingCount += 1
                            }
                        }
                    }
                    at += length
                }
            }
        }
    }

    /// IOMMU `i`'s register base: the node's, or a PCIe-based IOMMU's BAR 0
    /// (64-bit memory BAR) through its configuration space.
    static func registerBase(_ i: Int) -> UInt64? {
        let node = iommus[i]
        guard node.pci else { return node.base }
        guard let config = Mcfg.configSpace(segment: node.segment, deviceId: node.bdf),
              let cfg = try? kernelAspace.mapPhysical(config, size: KernelLayout.pageSize,
                                                      MapAttributes(writable: true, cache: .device, global: true),
                                                      shared: true) else { return nil }
        let low = unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(cfg + 0x10)).load()
        let high = unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(cfg + 0x14)).load()
        try? kernelAspace.free(cfg)
        let base = UInt64(low & ~0xF) | ((low >> 1) & 3 == 2 ? UInt64(high) << 32 : 0)
        return base == 0 ? nil : base
    }

    /// The device id requester id `rid` reaches IOMMU `iommu` with.
    static func deviceId(_ rid: UInt16, iommu: Int) -> UInt32? {
        for i in 0..<mappingCount where mappings[i].iommu == iommu {
            let m = mappings[i]
            if UInt32(rid) >= m.sourceBase, UInt32(rid) - m.sourceBase < m.count {
                return m.destinationBase + (UInt32(rid) - m.sourceBase)
            }
        }
        return nil
    }

    static func maxDeviceId(iommu: Int) -> UInt32 {
        var top: UInt32 = 0
        for i in 0..<mappingCount where mappings[i].iommu == iommu && mappings[i].count > 0 {
            top = max(top, mappings[i].destinationBase &+ mappings[i].count - 1)
        }
        return min(top, 0xFFFF)
    }
}

/// One IOMMU's state (heap, never freed).
struct RiscvIommuUnit: ~Copyable {
    let registers: UInt64     // virtual
    let registerBase: UInt64  // physical
    let rimtIndex: Int
    let extendedContexts: Bool  // MSI_FLAT: 64-byte contexts, 64 per page
    let sv48: Bool
    let lock = SpinLock()
    var root: UInt64 = 0         // the directory's root (physical)
    var maxDevice: UInt32 = 0
    var commandQueue: UInt64 = 0
    var commandTail: UInt32 = 0
    var faultQueue: UInt64 = 0
    var semaphore: UInt64 = 0
    var sequence: UInt32 = 0
    var domains = InlineArray<16, UInt64>(repeating: 1)  // PSCID 0 reserved
    /// K12j: the MSI page table claimed devices' contexts share (physical,
    /// 0 until needed), and the context's msi_addr_mask and pattern.
    var msiTable: UInt64 = 0
    var msiMask: UInt64 = 0
    var msiPattern: UInt64 = 0
    var bound = false
    var faults: UInt64 = 0
}

@safe struct RiscvIommuUnitPointer {
    let address: UInt64

    var pointee: RiscvIommuUnit {
        unsafeAddress { unsafe UnsafePointer<RiscvIommuUnit>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<RiscvIommuUnit>(bitPattern: UInt(address))! }
    }

    func read32(_ offset: UInt64) -> UInt32 {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(pointee.registers + offset)).load()
    }
    func write32(_ offset: UInt64, _ value: UInt32) {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(pointee.registers + offset)).store(value)
    }
    func read64(_ offset: UInt64) -> UInt64 {
        unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: UInt(pointee.registers + offset)).load()
    }
    func write64(_ offset: UInt64, _ value: UInt64) {
        unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: UInt(pointee.registers + offset)).store(value)
    }

    private func waitUntil(_ done: () -> Bool) throws(Status) {
        let giveUp = Clock.now() + 1_000_000_000
        while !done() {
            guard Clock.now() < giveUp else { throw .timedOut }
            arch_spin_pause()
        }
    }

    // MARK: The device directory

    /// Device contexts per leaf page, and the device id bits that index one.
    var perLeaf: UInt32 { pointee.extendedContexts ? 64 : 128 }
    var leafBits: UInt32 { pointee.extendedContexts ? 6 : 7 }
    var directoryLevels: Int { pointee.extendedContexts ? 3 : 2 }

    /// Device `did`'s context words (4 or 8), through the physmap.
    func context(_ did: UInt32) -> UnsafeMutablePointer<UInt64> {
        var table = pointee.root
        for level in stride(from: directoryLevels - 1, to: 0, by: -1) {  // directory levels above the leaf
            let shift = leafBits + 9 * UInt32(level - 1)
            let entry = unsafe UnsafePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(table)))![Int((did >> shift) & 0x1FF)]
            table = ((entry >> 10) & ((1 << 44) - 1)) << 12
        }
        let words = pointee.extendedContexts ? 8 : 4
        return unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(table)))!
            + Int(did & (perLeaf - 1)) * words
    }

    // MARK: Creation

    static func make(_ index: Int, base: UInt64) throws(Status) -> RiscvIommuUnitPointer {
        let node = Rimt.iommus[index]
        // A PCIe-based IOMMU decodes its registers only with memory space on.
        if node.pci { enablePciFunction(node) }
        let registers: UInt64
        do throws(VmError) {
            registers = try kernelAspace.mapPhysical(base, size: KernelLayout.pageSize,
                                                     MapAttributes(writable: true, cache: .device, global: true))
        } catch {
            throw .noMemory
        }
        func read64(_ offset: UInt64) -> UInt64 {
            unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: UInt(registers + offset)).load()
        }
        let caps = read64(RiscvIommus.capabilities)
        guard (caps >> 4) & 0xF == 1 else { throw .notSupported }        // version 1.x
        guard caps & (1 << 9 | 1 << 10) != 0 else { throw .notSupported } // Sv39 or Sv48
        // A directory firmware set up is firmware's.
        guard read64(RiscvIommus.ddtp) & 0xF <= 1 else { throw .badState }
        guard let raw = unsafe heap.allocate(size: MemoryLayout<RiscvIommuUnit>.size, alignment: 64) else { throw .noMemory }
        unsafe raw.bindMemory(to: RiscvIommuUnit.self, capacity: 1).initialize(to: RiscvIommuUnit(
            registers: registers, registerBase: base, rimtIndex: index,
            extendedContexts: caps & (1 << 22) != 0, sv48: caps & (1 << 10) != 0))
        let unit = RiscvIommuUnitPointer(address: UInt64(UInt(bitPattern: raw)))
        IoDomains.riscvPageBasedMemoryTypes = (RiscvIommus.unitCount == 0 || IoDomains.riscvPageBasedMemoryTypes)
            && caps & (1 << 15) != 0

        // Queues first: the directory's switch is followed by invalidations.
        guard let commands = IoDomains.zeroedPage(), let faults = IoDomains.zeroedPage(),
              let semaphore = IoDomains.zeroedPage() else { throw .noMemory }
        unit.pointee.commandQueue = commands
        unit.pointee.faultQueue = faults
        unit.pointee.semaphore = semaphore
        unit.write64(RiscvIommus.cqb, (RiscvIommus.commandLog2 - 1) | (commands >> 12) << 10)
        unit.write32(RiscvIommus.cqt, 0)
        unit.write32(RiscvIommus.cqcsr, 1)  // cqen
        try unit.waitUntil { unit.read32(RiscvIommus.cqcsr) & (1 << 16) != 0 }
        unit.write64(RiscvIommus.fqb, (RiscvIommus.faultLog2 - 1) | (faults >> 12) << 10)
        unit.write32(RiscvIommus.fqh, 0)
        unit.write32(RiscvIommus.fqcsr, 1)  // fqen, no interrupt
        try unit.waitUntil { unit.read32(RiscvIommus.fqcsr) & (1 << 16) != 0 }

        // Pass-through contexts for every device id the RIMT routes here.
        unit.pointee.maxDevice = Rimt.maxDeviceId(iommu: index)
        guard let root = IoDomains.zeroedPage() else { throw .noMemory }
        unit.pointee.root = root
        let leaves = (unit.pointee.maxDevice / unit.perLeaf) + 1
        var middle: UInt64 = 0  // 3 levels: the current middle table
        for leaf in 0..<leaves {
            guard let page = IoDomains.zeroedPage() else { throw .noMemory }
            let words = unit.pointee.extendedContexts ? 8 : 4
            let contexts = unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(page)))!
            for i in 0..<Int(unit.perLeaf) { unsafe contexts[i * words] = 1 }  // valid, both stages Bare
            if unit.directoryLevels == 2 {
                unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(root)))![Int(leaf)] = (page >> 12) << 10 | 1
            } else {
                if leaf % 512 == 0 {
                    guard let table = IoDomains.zeroedPage() else { throw .noMemory }
                    middle = table
                    unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(root)))![Int(leaf / 512)] = (table >> 12) << 10 | 1
                }
                unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(middle)))![Int(leaf % 512)] = (page >> 12) << 10 | 1
            }
        }
        arch_device_write_barrier()
        try unit.waitUntil { unit.read64(RiscvIommus.ddtp) & (1 << 4) == 0 }
        unit.write64(RiscvIommus.ddtp, UInt64(unit.directoryLevels + 1) | (root >> 12) << 10)  // 2LVL = 3, 3LVL = 4
        try unit.waitUntil { unit.read64(RiscvIommus.ddtp) & (1 << 4) == 0 }
        try unit.pointee.lock.withLock { () throws(Status) in
            unit.submitLocked(3, 0)  // IODIR.INVAL_DDT, every device
            unit.submitLocked(1, 0)  // IOTINVAL.VMA, everything
            try unit.waitLocked()
        }
        return unit
    }

    /// A PCIe-based IOMMU reaches memory as a bus master.
    private static func enablePciFunction(_ node: Rimt.Iommu) {
        guard let config = Mcfg.configSpace(segment: node.segment, deviceId: node.bdf),
              let cfg = try? kernelAspace.mapPhysical(config, size: KernelLayout.pageSize,
                                                      MapAttributes(writable: true, cache: .device, global: true),
                                                      shared: true) else { return }
        let command = unsafe VolatileMappedRegister<UInt16>(unsafeBitPattern: UInt(cfg + 4))
        command.store(command.load() | 1 << 1 | 1 << 2)  // memory space, bus master
        try? kernelAspace.free(cfg)
    }

    // MARK: Commands (unit lock held)

    func submitLocked(_ word0: UInt64, _ word1: UInt64) {
        let mask: UInt32 = (1 << UInt32(RiscvIommus.commandLog2)) - 1
        let tail = pointee.commandTail
        let next = (tail + 1) & mask
        while read32(RiscvIommus.cqh) & mask == next { arch_spin_pause() }
        let at = unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(pointee.commandQueue) + UInt64(tail) * 16))!
        unsafe at[0] = word0
        unsafe at[1] = word1
        arch_device_write_barrier()
        pointee.commandTail = next
        write32(RiscvIommus.cqt, next)
    }

    /// IOFENCE.C writing a new sequence number, polled (one second at
    /// most): every command before it has completed.
    func waitLocked() throws(Status) {
        pointee.sequence &+= 1
        let value = pointee.sequence
        let semaphore = pointee.semaphore
        submitLocked(2 | 1 << 10 | UInt64(value) << 32, semaphore >> 2)  // IOFENCE.C, AV
        let word = KernelLayout.physmap(semaphore)
        try waitUntil {
            if read32(RiscvIommus.cqcsr) & (7 << 8) != 0 { return true }  // cqmf, cmd_to, cmd_ill
            return unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(word)).load() == value
        }
        let errors = read32(RiscvIommus.cqcsr) & (7 << 8)
        if errors != 0 {
            panicConsole?.write("iommu: RISC-V IOMMU command queue error\n")
            write32(RiscvIommus.cqcsr, read32(RiscvIommus.cqcsr) | errors)  // write 1 to clear
            throw .internalError
        }
    }

    /// After device `did`'s context changed: its cached context and, with a
    /// domain, that PSCID's translations.
    func invalidateDeviceLocked(_ did: UInt32, domain: UInt16?) throws(Status) {
        submitLocked(3 | 1 << 33 | UInt64(did) << 40, 0)  // IODIR.INVAL_DDT, DV
        if let domain { submitLocked(1 | 1 << 32 | UInt64(domain) << 12, 0) }  // IOTINVAL.VMA, PSCV
        try waitLocked()
    }

    func invalidateDomain(_ domain: UInt16) {
        pointee.lock.withLock {
            submitLocked(1 | 1 << 32 | UInt64(domain) << 12, 0)
            try? waitLocked()
            drainFaultsLocked()
        }
    }

    // MARK: Faults

    /// Reads the fault queue, counting access and page faults; logs the
    /// first four of a batch and how many more there were.
    func drainFaultsLocked() {
        let mask: UInt32 = (1 << UInt32(RiscvIommus.faultLog2)) - 1
        var head = read32(RiscvIommus.fqh) & mask
        let tail = read32(RiscvIommus.fqt) & mask
        var logged = 0
        while head != tail {
            let record = unsafe UnsafePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(pointee.faultQueue) + UInt64(head) * 32))!
            let (word0, iotval) = unsafe (record[0], record[2])
            let cause = word0 & 0xFFF
            if cause == 1 || cause == 5 || cause == 7 || cause == 12 || cause == 13 || cause == 15 { pointee.faults += 1 }
            logged += 1
            if logged <= 4, let console = panicConsole {
                console.write("iommu: fault ")
                console.write(decimal: cause)
                console.write(" from device ")
                console.write(hex: word0 >> 40)
                console.write(" at ")
                console.write(hex: iotval)
                console.write("\n")
            }
            head = (head + 1) & mask
        }
        if logged > 4, let console = panicConsole {
            console.write("iommu: ")
            console.write(decimal: UInt64(logged - 4))
            console.write(" more faults\n")
        }
        write32(RiscvIommus.fqh, head)
        let csr = read32(RiscvIommus.fqcsr)
        if csr & (3 << 8) != 0 { write32(RiscvIommus.fqcsr, csr) }  // fqmf, fqof: write 1 to clear
    }
}
#endif
