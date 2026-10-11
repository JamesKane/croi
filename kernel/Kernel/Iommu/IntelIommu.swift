import _Volatile
import CKernel
import Fmt
import PageTables
import Synchronization

#if arch(x86_64)
/// Intel VT-d DMA remapping (K12a; Todhchai requirement 14; the Intel VT-d
/// specification, rev. 3.x, chapters 9-11). Zircon's ABI (iommu_create
/// with zx_iommu_desc_intel_t, dma.h); Zircon itself no longer carries an
/// Intel driver, so this one follows the specification.
///
/// One `VtdUnit` per remapping unit (a DMAR DRHD). Creating it points every
/// bus's root entry at one shared context table whose 256 entries are all
/// pass-through, then turns translation on: devices behind the unit keep
/// working untranslated until a BTI claims one. The claimed device's bus
/// gets a private copy of that table, and its entry points at a `VtdDomain`:
/// legacy-mode second-level page tables (4-level 48-bit, else 3-level
/// 39-bit, as SAGAW allows) mapping only what its BTI pins. Invalidation is
/// register based (CCMD, IOTLB): global for the context cache, domain
/// selective for the IOTLB. Faults raise the unit's fault event, an MSI to
/// the boot CPU, and are logged and counted.
///
/// Not yet: queued invalidation, interrupt remapping (x2APIC IDs above
/// 255), device-TLB (ATS), scopes behind bridges, large pages in domains.
enum Vtd {
    /// Units created so far (VtdUnit records), never freed: the hardware
    /// keeps translating through their tables. A unit whose IOMMU object
    /// went can be bound again (`bound`).
    nonisolated(unsafe) static var units = InlineArray<8, UInt64>(repeating: 0)
    nonisolated(unsafe) static var unitCount = 0
    /// Held across creation, which maps registers and waits on hardware.
    static let unitsLock = Mutex()

    // MARK: Registers (offsets)

    static var capabilityRegister: UInt64 { 0x08 }
    static var extendedRegister: UInt64 { 0x10 }
    static var globalCommand: UInt64 { 0x18 }
    static var globalStatus: UInt64 { 0x1C }
    static var rootTableAddress: UInt64 { 0x20 }
    static var contextCommand: UInt64 { 0x28 }
    static var faultStatus: UInt64 { 0x34 }
    static var faultControl: UInt64 { 0x38 }
    static var faultData: UInt64 { 0x3C }
    static var faultAddress: UInt64 { 0x40 }
    static var faultUpperAddress: UInt64 { 0x44 }

    // Global command / status bits.
    static var translationEnable: UInt32 { 1 << 31 }
    static var setRootTablePointer: UInt32 { 1 << 30 }
    static var writeBufferFlush: UInt32 { 1 << 27 }
    /// Status bits that stay set (the others report one-shot commands).
    static var persistentStatus: UInt32 { 1 << 31 | 1 << 26 | 1 << 25 | 1 << 23 }

    /// Creates the unit `descriptor` describes (zx_iommu_desc_intel_t,
    /// already copied in) and turns translation on. Returns the record.
    static func create(_ descriptor: RawSpan) throws(Status) -> UInt64 {
        let headerSize = MemoryLayout<croi_iommu_desc_intel_t>.size
        guard descriptor.byteCount >= headerSize else { throw .invalidArgs }
        let header = unsafe descriptor.unsafeLoadUnaligned(as: croi_iommu_desc_intel_t.self)
        let scopeBytes = Int(header.scope_bytes), reservedBytes = Int(header.reserved_memory_bytes)
        guard scopeBytes % MemoryLayout<croi_iommu_desc_intel_scope_t>.size == 0,
              headerSize + scopeBytes + reservedBytes == descriptor.byteCount,
              header.register_base % KernelLayout.pageSize == 0 else { throw .invalidArgs }
        guard Dmar.contains(header.register_base, segment: header.pci_segment) else { throw .notFound }
        // The reserved-memory list must parse: each entry's scopes inside it.
        var at = headerSize + scopeBytes
        while at < descriptor.byteCount {
            guard at + 24 <= descriptor.byteCount else { throw .invalidArgs }
            let entry = unsafe descriptor.unsafeLoadUnaligned(fromByteOffset: at, as: croi_iommu_desc_intel_reserved_memory_t.self)
            guard entry.scope_bytes % 8 == 0, at + 24 + Int(entry.scope_bytes) <= descriptor.byteCount,
                  entry.base_addr % KernelLayout.pageSize == 0, entry.len % KernelLayout.pageSize == 0 else {
                throw .invalidArgs
            }
            at += 24 + Int(entry.scope_bytes)
        }
        unitsLock.lock()
        defer { unitsLock.unlock() }
        for i in 0..<unitCount where VtdUnitPointer(address: units[i]).pointee.registerBase == header.register_base {
            let unit = VtdUnitPointer(address: units[i])
            guard !unit.pointee.bound else { throw .alreadyBound }
            try unit.setDescriptor(descriptor)
            unit.pointee.bound = true
            return unit.address
        }
        guard unitCount < units.count else { throw .noResources }
        let unit = try VtdUnitPointer.make(header.register_base, segment: header.pci_segment, descriptor)
        unit.pointee.bound = true
        units[unitCount] = unit.address
        unitCount += 1
        return unit.address
    }

    /// Faults every unit has recorded (self-test).
    static func faultsCounted() -> UInt64 {
        var total: UInt64 = 0
        for i in 0..<unitCount { total += VtdUnitPointer(address: units[i]).pointee.faults }
        return total
    }

    /// The unit's IOMMU object went (its BTIs, which hold it, went first):
    /// the unit stays translating, every device it covers pass-through or
    /// blocked, until it is bound again.
    static func unbind(_ address: UInt64) {
        unitsLock.lock()
        VtdUnitPointer(address: address).pointee.bound = false
        unitsLock.unlock()
    }
}

/// ACPI's DMAR: the remapping units the firmware describes (the kernel
/// only checks iommu_create's register_base against them; user space
/// reads the scopes and reserved memory itself, as Zircon's ACPI driver).
enum Dmar {
    struct Unit {
        var registerBase: UInt64 = 0
        var segment: UInt16 = 0
        var includesAll = false
    }

    nonisolated(unsafe) static var units = InlineArray<8, Unit>(repeating: Unit())
    nonisolated(unsafe) static var count = 0
    /// Host address width (DMAR's HAW + 1), 0 without a DMAR.
    nonisolated(unsafe) static var hostAddressBits = 0

    static func initialize(_ acpi: AcpiTables) {
        guard let dmar = acpi.table("DMAR") else { return }
        acpi.withTable(dmar) { (table: RawSpan) in
            guard table.byteCount >= 48 else { return }
            hostAddressBits = Int(table.load(fromByteOffset: 36, as: UInt8.self)) + 1
            var at = 48
            while at + 4 <= table.byteCount {
                let type = unsafe table.unsafeLoadUnaligned(fromByteOffset: at, as: UInt16.self)
                let length = Int(unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 2, as: UInt16.self))
                guard length >= 4, at + length <= table.byteCount else { return }
                if type == 0, length >= 16, count < units.count {  // DRHD
                    units[count] = Unit(registerBase: unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 8, as: UInt64.self),
                                        segment: unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 6, as: UInt16.self),
                                        includesAll: table.load(fromByteOffset: at + 4, as: UInt8.self) & 1 != 0)
                    count += 1
                }
                at += length
            }
        }
    }

    static func contains(_ base: UInt64, segment: UInt16) -> Bool {
        for i in 0..<count where units[i].registerBase == base && units[i].segment == segment { return true }
        return false
    }
}

/// One remapping unit's state (heap, never freed: the hardware keeps
/// pointing at its tables).
struct VtdUnit: ~Copyable {
    let registers: UInt64      // virtual
    let registerBase: UInt64   // physical
    let segment: UInt16
    let capability: UInt64
    let extended: UInt64
    let lock = SpinLock()
    /// Root table and the shared all-pass-through context table (physical).
    var rootTable: UInt64 = 0
    var passThroughTable: UInt64 = 0
    /// Each bus's context table: 0 while it is the shared one.
    var busTables = InlineArray<256, UInt64>(repeating: 0)
    /// Translation levels (3 or 4) and the context entries' AW value.
    var levels = 4
    var addressWidth: UInt64 = 2
    /// Domain ids in use, a bit each (0 is reserved by caching mode, 1 is
    /// the pass-through domain); ids above 1023 aren't used.
    var domains = InlineArray<16, UInt64>(repeating: 0)
    var bound = false
    /// The descriptor (heap copy): scopes and reserved memory.
    var descriptor: UInt64 = 0
    var descriptorSize = 0
    /// Faults recorded, and the last one (tests, logs).
    var faults: UInt64 = 0
    var lastFaultAddress: UInt64 = 0
    var lastFaultSource: UInt16 = 0
    var lastFaultReason: UInt8 = 0

    /// Bits of I/O virtual address the domains translate.
    var inputBits: UInt64 { UInt64(12 + 9 * levels) }
    var coherent: Bool { extended & 1 != 0 }       // ECAP.C: page walks snoop
    var needsWriteBufferFlush: Bool { capability & (1 << 4) != 0 }  // CAP.RWBF
    var cachingMode: Bool { capability & (1 << 7) != 0 }            // CAP.CM
    var domainCount: Int { min(1 << (4 + 2 * Int(capability & 7)), 1024) }
    var iotlbRegister: UInt64 { ((extended >> 8) & 0x3FF) * 16 + 8 }
    var faultRecords: UInt64 { ((capability >> 24) & 0x3FF) * 16 }
    var faultRecordCount: Int { Int((capability >> 40) & 0xFF) + 1 }
}

@safe struct VtdUnitPointer {
    let address: UInt64

    var pointee: VtdUnit {
        unsafeAddress { unsafe UnsafePointer<VtdUnit>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<VtdUnit>(bitPattern: UInt(address))! }
    }

    // MARK: Register access

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

    /// Issues a global command (keeping the persistent bits) and waits for
    /// its status bit to read `on` (one second at most).
    func command(_ bit: UInt32, on: Bool = true) throws(Status) {
        let status = read32(Vtd.globalStatus) & Vtd.persistentStatus
        write32(Vtd.globalCommand, on ? status | bit : status & ~bit)
        try waitUntil { (read32(Vtd.globalStatus) & bit != 0) == on }
    }

    private func waitUntil(_ done: () -> Bool) throws(Status) {
        let giveUp = Clock.now() + 1_000_000_000
        while !done() {
            guard Clock.now() < giveUp else { throw .timedOut }
            arch_spin_pause()
        }
    }

    // MARK: Creation

    /// Maps the registers, builds the tables and turns translation on.
    static func make(_ registerBase: UInt64, segment: UInt16, _ descriptor: RawSpan) throws(Status) -> VtdUnitPointer {
        let device = MapAttributes(writable: true, cache: .device, global: true)
        let size = 4 * KernelLayout.pageSize  // IOTLB and fault registers sit past the first page
        let registers: UInt64
        do throws(VmError) {
            registers = try kernelAspace.mapPhysical(registerBase, size: size, device)
        } catch {
            throw .noMemory
        }
        let capability = unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: UInt(registers + Vtd.capabilityRegister)).load()
        let extended = unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: UInt(registers + Vtd.extendedRegister)).load()
        guard extended & (1 << 6) != 0 else { throw .notSupported }  // ECAP.PT: needed to leave devices alone
        let sagaw = (capability >> 8) & 0x1F
        let levels: Int, addressWidth: UInt64
        if sagaw & 4 != 0 {
            (levels, addressWidth) = (4, 2)
        } else if sagaw & 2 != 0 {
            (levels, addressWidth) = (3, 1)
        } else {
            throw .notSupported
        }
        guard let raw = unsafe heap.allocate(size: MemoryLayout<VtdUnit>.size, alignment: 64) else { throw .noMemory }
        unsafe raw.bindMemory(to: VtdUnit.self, capacity: 1).initialize(to: VtdUnit(
            registers: registers, registerBase: registerBase, segment: segment, capability: capability, extended: extended))
        let unit = VtdUnitPointer(address: UInt64(UInt(bitPattern: raw)))
        unit.pointee.levels = levels
        unit.pointee.addressWidth = addressWidth
        unit.pointee.domains[0] = 3
        try unit.setDescriptor(descriptor)

        // Every device pass-through (TT = 10, DID 1), every bus pointing at it.
        guard let root = Vtd.zeroedPage(), let shared = Vtd.zeroedPage() else { throw .noMemory }
        for i in 0..<256 {
            Vtd.store(shared, entry: i, low: 2 << 2 | 1, high: addressWidth | 1 << 8)
            Vtd.store(root, entry: i, low: shared | 1, high: 0)
        }
        unit.pointee.rootTable = root
        unit.pointee.passThroughTable = shared
        unit.flushTables(root, KernelLayout.pageSize)
        unit.flushTables(shared, KernelLayout.pageSize)

        try unit.pointee.lock.withLock { () throws(Status) in
            unit.write64(Vtd.rootTableAddress, root)  // legacy translation mode (TTM 00)
            try unit.command(Vtd.setRootTablePointer)
            try unit.invalidateContextsLocked()
            try unit.invalidateIotlbLocked(domain: nil)
            unit.setUpFaultEvents()
            try unit.command(Vtd.translationEnable)
        }
        return unit
    }

    /// Keeps a heap copy of the descriptor (scopes, reserved memory).
    func setDescriptor(_ descriptor: RawSpan) throws(Status) {
        guard let copy = unsafe heap.allocate(size: descriptor.byteCount) else { throw .noMemory }
        unsafe descriptor.withUnsafeBytes { unsafe copy.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        if pointee.descriptor != 0 { unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(pointee.descriptor))!) }
        pointee.descriptor = UInt64(UInt(bitPattern: copy))
        pointee.descriptorSize = descriptor.byteCount
    }

    // MARK: Table helpers

    /// After the CPU wrote [phys, phys+size) of a table: visible to a page
    /// walk that doesn't snoop, and past the write buffer if it has one.
    func flushTables(_ phys: UInt64, _ size: UInt64) {
        if !pointee.coherent {
            arch_cache_op(KernelLayout.physmap(phys), size, CROI_CACHE_CLEAN, VmoCache.line)
        }
        if pointee.needsWriteBufferFlush {
            // WBF is written as 1 and reads 1 until the flush is done.
            write32(Vtd.globalCommand, read32(Vtd.globalStatus) & Vtd.persistentStatus | Vtd.writeBufferFlush)
            try? waitUntil { read32(Vtd.globalStatus) & Vtd.writeBufferFlush == 0 }
        }
    }

    // MARK: Invalidation (unit lock held)

    func invalidateContextsLocked() throws(Status) {
        write64(Vtd.contextCommand, 1 << 63 | 1 << 61)  // ICC, global
        try waitUntil { read64(Vtd.contextCommand) & (1 << 63) == 0 }
    }

    /// The IOTLB for `domain` (nil: all), draining reads and writes.
    func invalidateIotlbLocked(domain: UInt16?) throws(Status) {
        var value: UInt64 = 1 << 63 | 1 << 49 | 1 << 48  // IVT, DR, DW
        if let domain {
            value |= 2 << 60 | UInt64(domain) << 32         // domain selective
        } else {
            value |= 1 << 60                                // global
        }
        let register = pointee.iotlbRegister
        write64(register, value)
        try waitUntil { read64(register) & (1 << 63) == 0 }
    }

    // MARK: Faults

    /// The fault event: an MSI to the boot CPU, a kernel handler.
    private func setUpFaultEvents() {
        guard let vector = DeviceIrqs.allocateMsi(cpu: 0, count: 1),
              let message = DeviceIrqs.msiMessage(cpu: 0, vector: vector) else { return }
        DeviceIrqs.setKernelMsiHandler(cpu: 0, vector: vector, Vtd.faultEvent, address)
        write32(Vtd.faultData, message.data)
        write32(Vtd.faultAddress, UInt32(truncatingIfNeeded: message.address))
        write32(Vtd.faultUpperAddress, 0)
        write32(Vtd.faultControl, 0)  // unmasked
    }

    /// Reads and clears every recorded fault, logging each.
    func drainFaults() {
        pointee.lock.withLock {
            for i in 0..<pointee.faultRecordCount {
                let record = pointee.faultRecords + UInt64(i) * 16
                let high = read64(record + 8)
                guard high & (1 << 63) != 0 else { continue }
                let low = read64(record)
                pointee.faults += 1
                pointee.lastFaultAddress = low & ~0xFFF
                pointee.lastFaultSource = UInt16(truncatingIfNeeded: high)
                pointee.lastFaultReason = UInt8(truncatingIfNeeded: high >> 32)
                write64(record + 8, 1 << 63)  // clear F
                if let console = panicConsole {
                    let sid = pointee.lastFaultSource
                    console.write("iommu: DMA fault from ")
                    console.write(hex: UInt64(sid >> 8))
                    console.write(":")
                    console.write(hex: UInt64((sid >> 3) & 0x1F))
                    console.write(".")
                    console.write(decimal: UInt64(sid & 7))
                    console.write(high & (1 << 62) != 0 ? " reading " : " writing ")
                    console.write(hex: pointee.lastFaultAddress)
                    console.write(", reason ")
                    console.write(hex: UInt64(pointee.lastFaultReason))
                    console.write("\n")
                }
            }
            write32(Vtd.faultStatus, 0x7F)  // clear overflow and pending (write 1 to clear)
        }
    }
}

extension Vtd {
    static let faultEvent: DeviceIrqs.KernelMsiHandler = { address in VtdUnitPointer(address: address).drainFaults() }

    /// A zeroed page for tables (PMM, state mmu), or nil.
    static func zeroedPage() -> UInt64? {
        guard let phys = pmm.allocatePage(.mmu) else { return nil }
        unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(phys)))!
            .initializeMemory(as: UInt8.self, repeating: 0, count: Int(KernelLayout.pageSize))
        return phys
    }

    /// A 128-bit root or context entry, high half first so a walk never
    /// sees a present entry with a stale high half.
    static func store(_ table: UInt64, entry: Int, low: UInt64, high: UInt64) {
        let at = unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(table) + UInt64(entry) * 16))!
        unsafe at[1] = high
        unsafe at[0] = low
    }

    static func load(_ table: UInt64, entry: Int) -> (low: UInt64, high: UInt64) {
        let at = unsafe UnsafePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(table) + UInt64(entry) * 16))!
        return unsafe (at[0], at[1])
    }
}

// MARK: Domains

/// A claimed device's translation (one per VT-d BTI): its second-level
/// page tables and the I/O virtual addresses in use.
struct VtdDomain: ~Copyable {
    let unit: VtdUnitPointer
    let domainId: UInt16
    let bdf: UInt16
    let root: UInt64  // physical
    let lock = SpinLock()
    /// Allocated IOVA ranges, sorted by base.
    var used = UniqueArray<IovaRange>()
    /// Table pages (freed with the domain).
    var tables = UniqueArray<UInt64>()
}

struct IovaRange {
    var base: UInt64
    var size: UInt64
}

@safe struct VtdDomainPointer {
    let address: UInt64

    var pointee: VtdDomain {
        unsafeAddress { unsafe UnsafePointer<VtdDomain>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<VtdDomain>(bitPattern: UInt(address))! }
    }
}

extension Vtd {
    /// Claims device `bdf` behind `unit`: a domain of its own, the reserved
    /// memory its scopes name identity mapped, its context entry pointed
    /// at it. OUT_OF_RANGE if the unit's scopes don't cover it,
    /// ALREADY_BOUND if it is claimed.
    static func attach(_ unit: VtdUnitPointer, bdf: UInt16) throws(Status) -> VtdDomainPointer {
        guard covers(unit, bdf: bdf) else { throw .outOfRange }
        guard let root = zeroedPage() else { throw .noMemory }
        guard let raw = unsafe heap.allocate(size: MemoryLayout<VtdDomain>.size, alignment: 64) else {
            pmm.free(root)
            throw .noMemory
        }
        let bus = Int(bdf >> 8), entry = Int(bdf & 0xFF)
        let id = try unit.pointee.lock.withLock { () throws(Status) -> UInt16 in
            // Claimed: present and translated (TT 00). Blocked devices (a
            // BTI that went) can be claimed again.
            if unit.pointee.busTables[bus] != 0 {
                let low = load(unit.pointee.busTables[bus], entry: entry).low
                if low & 1 != 0, (low >> 2) & 3 == 0 { throw .alreadyBound }
            }
            for id in 2..<unit.pointee.domainCount where unit.pointee.domains[id / 64] & (1 << UInt64(id % 64)) == 0 {
                unit.pointee.domains[id / 64] |= 1 << UInt64(id % 64)
                return UInt16(id)
            }
            throw .noResources
        }
        unsafe raw.bindMemory(to: VtdDomain.self, capacity: 1).initialize(to: VtdDomain(
            unit: unit, domainId: id, bdf: bdf, root: root))
        let domain = VtdDomainPointer(address: UInt64(UInt(bitPattern: raw)))
        domain.pointee.tables.append(root)
        unit.flushTables(root, KernelLayout.pageSize)
        do throws(Status) {
            try mapReservedMemory(domain)
        } catch {
            free(domain)
            throw error
        }
        let copy = unit.pointee.lock.withLock { unit.pointee.busTables[bus] } == 0 ? zeroedPage() : nil
        do throws(Status) { try unit.pointee.lock.withLock { () throws(Status) in
            var table = unit.pointee.busTables[bus]
            if table != 0, let copy { pmm.free(copy) }  // another claim on the bus made it
            if table == 0 {
                guard let copy else { throw .noMemory }
                unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(copy)))!.copyMemory(
                    from: UnsafeRawPointer(bitPattern: UInt(KernelLayout.physmap(unit.pointee.passThroughTable)))!,
                    byteCount: Int(KernelLayout.pageSize))
                unit.flushTables(copy, KernelLayout.pageSize)
                unit.pointee.busTables[bus] = copy
                store(unit.pointee.rootTable, entry: bus, low: copy | 1, high: 0)
                unit.flushTables(unit.pointee.rootTable + UInt64(bus) * 16, 16)
                table = copy
            }
            // Translated (TT = 00) through the domain's tables.
            store(table, entry: entry, low: root | 1, high: unit.pointee.addressWidth | UInt64(id) << 8)
            unit.flushTables(table + UInt64(entry) * 16, 16)
            try unit.invalidateContextsLocked()
            try unit.invalidateIotlbLocked(domain: nil)
        } } catch {
            free(domain)
            throw error
        }
        return domain
    }

    /// The device loses all DMA (a not-present entry), and the domain's
    /// tables go. Its pins must be gone (their PMTs unpinned) first.
    static func detach(_ domain: VtdDomainPointer) {
        let unit = domain.pointee.unit
        let bus = Int(domain.pointee.bdf >> 8), entry = Int(domain.pointee.bdf & 0xFF)
        unit.pointee.lock.withLock {
            let table = unit.pointee.busTables[bus]
            store(table, entry: entry, low: 0, high: 0)
            unit.flushTables(table + UInt64(entry) * 16, 16)
            try? unit.invalidateContextsLocked()
            try? unit.invalidateIotlbLocked(domain: domain.pointee.domainId)
        }
        free(domain)
    }

    /// The domain's tables, id and record (no device points at them).
    private static func free(_ domain: VtdDomainPointer) {
        let unit = domain.pointee.unit
        let id = Int(domain.pointee.domainId)
        unit.pointee.lock.withLock { unit.pointee.domains[id / 64] &= ~(1 << UInt64(id % 64)) }
        for i in 0..<domain.pointee.tables.count { pmm.free(domain.pointee.tables[i]) }
        let raw = unsafe UnsafeMutablePointer<VtdDomain>(bitPattern: UInt(domain.address))!
        unsafe raw.deinitialize(count: 1)
        unsafe heap.free(UnsafeMutableRawPointer(raw))
    }

    /// Whether the unit's descriptor puts `bdf` behind it: whole segment
    /// less the listed devices, or the listed devices (endpoints one hop
    /// from the host bridge).
    static func covers(_ unit: VtdUnitPointer, bdf: UInt16) -> Bool {
        let header = unsafe UnsafeRawPointer(bitPattern: UInt(unit.pointee.descriptor))!
            .loadUnaligned(as: croi_iommu_desc_intel_t.self)
        let listed = scopesInclude(unit.pointee.descriptor + 16, bytes: Int(header.scope_bytes), bdf: bdf)
        return header.whole_segment ? !listed : listed
    }

    private static func scopesInclude(_ address: UInt64, bytes: Int, bdf: UInt16) -> Bool {
        var at = 0
        while at + 8 <= bytes {
            let scope = unsafe UnsafeRawPointer(bitPattern: UInt(address) + UInt(at))!
                .loadUnaligned(as: croi_iommu_desc_intel_scope_t.self)
            at += 8
            guard scope.type == CROI_IOMMU_INTEL_SCOPE_ENDPOINT, scope.num_hops == 1 else { continue }
            if UInt16(scope.start_bus) << 8 | UInt16(scope.dev_func.0) == bdf { return true }
        }
        return false
    }

    /// Identity maps every reserved-memory region whose scopes name the
    /// domain's device (RMRRs: firmware's DMA the device may still do).
    private static func mapReservedMemory(_ domain: VtdDomainPointer) throws(Status) {
        let unit = domain.pointee.unit
        let base = unit.pointee.descriptor
        let header = unsafe UnsafeRawPointer(bitPattern: UInt(base))!.loadUnaligned(as: croi_iommu_desc_intel_t.self)
        var at = 16 + Int(header.scope_bytes)
        while at < unit.pointee.descriptorSize {
            let entry = unsafe UnsafeRawPointer(bitPattern: UInt(base) + UInt(at))!
                .loadUnaligned(as: croi_iommu_desc_intel_reserved_memory_t.self)
            if scopesInclude(base + UInt64(at) + 24, bytes: Int(entry.scope_bytes), bdf: domain.pointee.bdf) {
                _ = try reserve(domain, at: entry.base_addr, size: entry.len)
                var offset: UInt64 = 0
                while offset < entry.len {
                    try map(domain, iova: entry.base_addr + offset, phys: entry.base_addr + offset, write: true)
                    offset += KernelLayout.pageSize
                }
            }
            at += 24 + Int(entry.scope_bytes)
        }
    }

    // MARK: IOVAs

    /// `size` bytes of I/O virtual addresses inside [low, high), first fit
    /// from 1 MiB (address 0 stays unmapped), or at `fixed`.
    static func reserve(_ domain: VtdDomainPointer, at fixed: UInt64? = nil, size: UInt64,
                        low: UInt64 = 0, high: UInt64 = .max) throws(Status) -> UInt64 {
        let limit = min(high, 1 << domain.pointee.unit.pointee.inputBits)
        return try domain.pointee.lock.withLock { () throws(Status) -> UInt64 in
            var candidate = fixed ?? max(low, 0x10_0000)
            var index = 0
            while index < domain.pointee.used.count {
                let r = domain.pointee.used[index]
                if r.base + r.size <= candidate { index += 1; continue }
                if candidate + size <= r.base { break }
                guard fixed == nil else { throw .alreadyBound }
                candidate = r.base + r.size
                index += 1
            }
            guard candidate + size <= limit, candidate + size > candidate else { throw .noMemory }
            domain.pointee.used.insert(IovaRange(base: candidate, size: size), at: index)
            return candidate
        }
    }

    static func release(_ domain: VtdDomainPointer, iova: UInt64) {
        domain.pointee.lock.withLock {
            for i in 0..<domain.pointee.used.count where domain.pointee.used[i].base == iova {
                _ = domain.pointee.used.remove(at: i)
                return
            }
        }
    }

    // MARK: Second-level tables

    /// Maps one page (read, and write if asked). The caller invalidates
    /// where needed (caching mode: after every map).
    static func map(_ domain: VtdDomainPointer, iova: UInt64, phys: UInt64, write: Bool) throws(Status) {
        let unit = domain.pointee.unit
        try domain.pointee.lock.withLock { () throws(Status) in
            var table = domain.pointee.root
            for level in stride(from: unit.pointee.levels, to: 1, by: -1) {
                let index = Int((iova >> UInt64(12 + 9 * (level - 1))) & 0x1FF)
                let slot = unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(table)))! + index
                if unsafe slot.pointee & 3 == 0 {
                    guard let next = zeroedPage() else { throw .noMemory }
                    domain.pointee.tables.append(next)
                    unit.flushTables(next, KernelLayout.pageSize)
                    unsafe slot.pointee = next | 3  // read, write: leaves decide
                    unit.flushTables(table + UInt64(index) * 8, 8)
                }
                table = unsafe slot.pointee & 0x000F_FFFF_FFFF_F000
            }
            let index = Int((iova >> 12) & 0x1FF)
            let slot = unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(table)))! + index
            unsafe slot.pointee = phys | 1 | (write ? 2 : 0)
            unit.flushTables(table + UInt64(index) * 8, 8)
        }
        if unit.pointee.cachingMode {
            try unit.pointee.lock.withLock { () throws(Status) in try unit.invalidateIotlbLocked(domain: domain.pointee.domainId) }
        }
    }

    /// Unmaps [iova, iova+size) and invalidates the domain's IOTLB: when it
    /// returns, the device can't reach those pages.
    static func unmap(_ domain: VtdDomainPointer, iova: UInt64, size: UInt64) {
        let unit = domain.pointee.unit
        domain.pointee.lock.withLock {
            var at = iova
            while at < iova + size {
                var table = domain.pointee.root
                var present = true
                for level in stride(from: unit.pointee.levels, to: 1, by: -1) {
                    let index = Int((at >> UInt64(12 + 9 * (level - 1))) & 0x1FF)
                    let entry = unsafe UnsafePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(table)))![index]
                    guard entry & 3 != 0 else { present = false; break }
                    table = entry & 0x000F_FFFF_FFFF_F000
                }
                if present {
                    let index = Int((at >> 12) & 0x1FF)
                    unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(table)))![index] = 0
                    unit.flushTables(table + UInt64(index) * 8, 8)
                }
                at += KernelLayout.pageSize
            }
        }
        unit.pointee.lock.withLock { try? unit.invalidateIotlbLocked(domain: domain.pointee.domainId) }
    }
}
#endif
