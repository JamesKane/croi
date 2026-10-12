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
/// One `VtdUnit` per remapping unit (a DMAR DRHD), brought up by the kernel
/// at boot (`Vtd.boot`: registers, queued invalidation where there is
/// one, the fault event, and interrupt remapping, InterruptRemapping.swift).
/// iommu_create binds it; the first bind points every bus's root entry at
/// one shared context table whose 256 entries are all pass-through, then
/// turns translation on: devices behind the unit keep working untranslated
/// until a BTI claims one. The claimed device's bus
/// gets a private copy of that table, and its entry points at a `VtdDomain`:
/// legacy-mode second-level page tables (4-level 48-bit, else 3-level
/// 39-bit, as SAGAW allows) mapping only what its BTI pins. Invalidation
/// goes through the invalidation queue (descriptors, then a wait
/// descriptor writing a sequence number the CPU polls), or the registers
/// (CCMD, IOTLB) on a unit without one: global for the context cache,
/// domain selective for the IOTLB. Faults raise the unit's fault event, a
/// compatibility-format MSI to the boot CPU (the unit's own interrupts
/// aren't remapped), and are logged and counted.
///
/// Not yet: device-TLB (ATS), scopes behind bridges, large pages in
/// domains, posted interrupts.
enum Vtd {
    /// The DMAR's units, brought up at boot (VtdUnit records), never freed:
    /// the hardware keeps using their tables. A unit whose IOMMU object went
    /// can be bound again (`bound`).
    nonisolated(unsafe) static var units = InlineArray<8, UInt64>(repeating: 0)
    nonisolated(unsafe) static var unitCount = 0
    /// Held across binding, which builds tables and waits on hardware.
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
    static var queueHead: UInt64 { 0x80 }
    static var queueTail: UInt64 { 0x88 }
    static var queueAddress: UInt64 { 0x90 }
    static var interruptTableAddress: UInt64 { 0xB8 }

    // Global command / status bits.
    static var translationEnable: UInt32 { 1 << 31 }
    static var setRootTablePointer: UInt32 { 1 << 30 }
    static var writeBufferFlush: UInt32 { 1 << 27 }
    static var queuedInvalidationEnable: UInt32 { 1 << 26 }
    static var interruptRemappingEnable: UInt32 { 1 << 25 }
    static var setInterruptTablePointer: UInt32 { 1 << 24 }
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
            if !unit.pointee.translating { try unit.enableTranslation() }
            try unit.setDescriptor(descriptor)
            unit.pointee.bound = true
            return unit.address
        }
        throw .notSupported  // in the DMAR, but boot couldn't bring it up
    }

    /// Brings up every DMAR unit, then interrupt remapping where the
    /// platform and every unit support it (and `croi.intremap=off` isn't
    /// given). Interrupts not yet routed anywhere: every IOAPIC pin masked.
    static func boot(_ console: Uart) {
        for i in 0..<Dmar.count where unitCount < units.count {
            if let unit = try? VtdUnitPointer.bringUp(Dmar.units[i].registerBase, segment: Dmar.units[i].segment) {
                units[unitCount] = unit.address
                unitCount += 1
            }
        }
        guard unitCount > 0 else { return }
        console.write("  iommu:  VT-d, ")
        console.write(decimal: UInt64(unitCount))
        console.write(unitCount == 1 ? " unit; interrupt remapping " : " units; interrupt remapping ")
        if BootOptions.has("croi.intremap=off") {
            console.write("off (croi.intremap=off)\n")
            return
        }
        guard Dmar.interruptRemapping, unitCount == Dmar.count else {
            console.write("not offered by the platform\n")
            return
        }
        var eligible = true, extended = true
        for i in 0..<unitCount {
            let unit = VtdUnitPointer(address: units[i])
            eligible = eligible && unit.pointee.queued && unit.pointee.extended & (1 << 3) != 0  // QI, IR
            extended = extended && unit.pointee.extended & (1 << 4) != 0                         // EIM
        }
        guard eligible, extended || !LocalApic.x2apic else {
            console.write("not supported by every unit\n")
            return
        }
        guard InterruptRemapping.table == 0 else { return }
        let pages = UInt64(InterruptRemapping.entryCount * 16) / KernelLayout.pageSize
        guard let table = pmm.allocateContiguous(pages, alignLog2: 12, .mmu) else {
            console.write("off (no memory)\n")
            return
        }
        unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(table)))!
            .initializeMemory(as: UInt8.self, repeating: 0, count: Int(pages * KernelLayout.pageSize))
        InterruptRemapping.table = table
        InterruptRemapping.extended = extended
        for i in 0..<unitCount {
            let unit = VtdUnitPointer(address: units[i])
            unit.flushTables(table, pages * KernelLayout.pageSize)
            do throws(Status) {
                try unit.pointee.lock.withLock { () throws(Status) in
                    unit.write64(Vtd.interruptTableAddress, table | (extended ? 1 << 11 : 0) | 12)  // EIME, 2^13 entries
                    try unit.command(Vtd.setInterruptTablePointer)
                    try unit.invalidateInterruptsLocked(index: nil)
                    try unit.command(Vtd.interruptRemappingEnable)  // CFI stays clear: old-style MSIs blocked
                }
            } catch {
                panic("iommu: VT-d interrupt remapping didn't start")
            }
        }
        InterruptRemapping.enabled = true
        console.write(extended ? "on, x2APIC destinations\n" : "on\n")
    }

    /// After an interrupt table entry changed: every unit drops its copy.
    static func invalidateInterruptEntry(_ index: Int, flush: UInt64) {
        for i in 0..<unitCount {
            let unit = VtdUnitPointer(address: units[i])
            unit.flushTables(flush, 16)
            unit.pointee.lock.withLock { try? unit.invalidateInterruptsLocked(index: index) }
        }
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
    /// The DMAR's INTR_REMAP flag: the platform supports remapping.
    nonisolated(unsafe) static var interruptRemapping = false
    /// IOAPIC scopes: (IOAPIC id, its source id), for remapping entries.
    nonisolated(unsafe) static var ioApics = InlineArray<8, (id: UInt8, source: UInt16)>(repeating: (0, 0))
    nonisolated(unsafe) static var ioApicCount = 0

    static func initialize(_ acpi: AcpiTables) {
        guard let dmar = acpi.table("DMAR") else { return }
        acpi.withTable(dmar) { (table: RawSpan) in
            guard table.byteCount >= 48 else { return }
            hostAddressBits = Int(table.load(fromByteOffset: 36, as: UInt8.self)) + 1
            interruptRemapping = table.load(fromByteOffset: 37, as: UInt8.self) & 1 != 0
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
                    // Device scopes: IOAPICs (type 3) give their source id
                    // (start bus, then the last device/function of the path).
                    var scope = at + 16
                    while scope + 8 <= at + length {
                        let scopeLength = Int(table.load(fromByteOffset: scope + 1, as: UInt8.self))
                        guard scopeLength >= 8, scope + scopeLength <= at + length else { break }
                        if table.load(fromByteOffset: scope, as: UInt8.self) == 3, ioApicCount < ioApics.count {
                            let bus = UInt16(table.load(fromByteOffset: scope + 5, as: UInt8.self))
                            let device = UInt16(table.load(fromByteOffset: scope + scopeLength - 2, as: UInt8.self))
                            let function = UInt16(table.load(fromByteOffset: scope + scopeLength - 1, as: UInt8.self))
                            ioApics[ioApicCount] = (table.load(fromByteOffset: scope + 4, as: UInt8.self),
                                                    bus << 8 | device << 3 | function)
                            ioApicCount += 1
                        }
                        scope += scopeLength
                    }
                }
                at += length
            }
        }
    }

    /// IOAPIC `id`'s source id, if the DMAR names it.
    static func ioApicSource(_ id: UInt8) -> UInt16? {
        for i in 0..<ioApicCount where ioApics[i].id == id { return ioApics[i].source }
        return nil
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
    var translating = false
    /// The invalidation queue (physical), its tail, the page its wait
    /// descriptors write to and the last sequence number.
    var queued = false
    var queue: UInt64 = 0
    var queueTailIndex: UInt64 = 0
    var semaphore: UInt64 = 0
    var sequence: UInt32 = 0
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

    func waitUntil(_ done: () -> Bool) throws(Status) {
        let giveUp = Clock.now() + 1_000_000_000
        while !done() {
            guard Clock.now() < giveUp else { throw .timedOut }
            arch_spin_pause()
        }
    }

    // MARK: Creation

    /// Maps the registers and starts what the kernel needs at boot: the
    /// invalidation queue (if the unit has one) and the fault event.
    /// Translation stays off until the unit is bound.
    static func bringUp(_ registerBase: UInt64, segment: UInt16) throws(Status) -> VtdUnitPointer {
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
        guard let raw = unsafe heap.allocate(size: MemoryLayout<VtdUnit>.size, alignment: 64) else { throw .noMemory }
        unsafe raw.bindMemory(to: VtdUnit.self, capacity: 1).initialize(to: VtdUnit(
            registers: registers, registerBase: registerBase, segment: segment, capability: capability, extended: extended))
        let unit = VtdUnitPointer(address: UInt64(UInt(bitPattern: raw)))
        unit.pointee.domains[0] = 3
        // Whatever firmware left on goes off first (its tables are its own).
        let status = unit.read32(Vtd.globalStatus)
        if status & (Vtd.translationEnable | Vtd.interruptRemappingEnable | Vtd.queuedInvalidationEnable) != 0 {
            unit.write32(Vtd.globalCommand, 0)
            try unit.waitUntil { unit.read32(Vtd.globalStatus) & Vtd.persistentStatus == 0 }
        }
        if extended & (1 << 1) != 0 {  // QI
            guard let queue = Vtd.zeroedPage(), let semaphore = Vtd.zeroedPage() else { throw .noMemory }
            unit.pointee.queue = queue
            unit.pointee.semaphore = semaphore
            unit.write64(Vtd.queueTail, 0)
            unit.write64(Vtd.queueAddress, queue)  // 128-bit descriptors, one page: 256 of them
            try unit.command(Vtd.queuedInvalidationEnable)
            unit.pointee.queued = true
        }
        unit.setUpFaultEvents()
        return unit
    }

    /// The first bind: every device pass-through, then translation on.
    func enableTranslation() throws(Status) {
        guard pointee.extended & (1 << 6) != 0 else { throw .notSupported }  // ECAP.PT: needed to leave devices alone
        let sagaw = (pointee.capability >> 8) & 0x1F
        if sagaw & 4 != 0 {
            (pointee.levels, pointee.addressWidth) = (4, 2)
        } else if sagaw & 2 != 0 {
            (pointee.levels, pointee.addressWidth) = (3, 1)
        } else {
            throw .notSupported
        }
        // Every device pass-through (TT = 10, DID 1), every bus pointing at it.
        guard let root = Vtd.zeroedPage(), let shared = Vtd.zeroedPage() else { throw .noMemory }
        for i in 0..<256 {
            Vtd.store(shared, entry: i, low: 2 << 2 | 1, high: pointee.addressWidth | 1 << 8)
            Vtd.store(root, entry: i, low: shared | 1, high: 0)
        }
        pointee.rootTable = root
        pointee.passThroughTable = shared
        flushTables(root, KernelLayout.pageSize)
        flushTables(shared, KernelLayout.pageSize)
        try pointee.lock.withLock { () throws(Status) in
            write64(Vtd.rootTableAddress, root)  // legacy translation mode (TTM 00)
            try command(Vtd.setRootTablePointer)
            try invalidateContextsLocked()
            try invalidateIotlbLocked(domain: nil)
            try command(Vtd.translationEnable)
        }
        pointee.translating = true
    }

    /// Keeps a heap copy of the descriptor (scopes, reserved memory).
    func setDescriptor(_ descriptor: RawSpan) throws(Status) {
        guard let copy = unsafe heap.allocate(size: descriptor.byteCount) else { throw .noMemory }
        descriptor.withUnsafeBytes { unsafe copy.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
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
        if pointee.queued {
            submitLocked(0x1 | 1 << 4, 0)  // context-cache invalidate, global
            return try waitLocked()
        }
        write64(Vtd.contextCommand, 1 << 63 | 1 << 61)  // ICC, global
        try waitUntil { read64(Vtd.contextCommand) & (1 << 63) == 0 }
    }

    /// The interrupt entry cache: entry `index`, or all (nil). Queued only.
    func invalidateInterruptsLocked(index: Int?) throws(Status) {
        guard pointee.queued else { return }
        if let index {
            submitLocked(0x4 | 1 << 4 | UInt64(index) << 32, 0)  // index selective, IM 0
        } else {
            submitLocked(0x4, 0)                                 // global
        }
        try waitLocked()
    }

    /// Queues one 128-bit descriptor; waits while the queue is full.
    func submitLocked(_ low: UInt64, _ high: UInt64) {
        let tail = pointee.queueTailIndex
        let next = (tail + 1) % 256
        while (read64(Vtd.queueHead) >> 4) & 0xFF == next { arch_spin_pause() }
        let at = unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(pointee.queue) + tail * 16))!
        unsafe at[0] = low
        unsafe at[1] = high
        flushTables(pointee.queue + tail * 16, 16)
        pointee.queueTailIndex = next
        write64(Vtd.queueTail, next << 4)
    }

    /// An invalidation wait descriptor (fence, status write of a new
    /// sequence number), polled (one second at most): everything queued
    /// before it is done. A queue error (FSTS.IQE) is logged and cleared.
    func waitLocked() throws(Status) {
        pointee.sequence &+= 1
        let value = pointee.sequence
        submitLocked(0x5 | 1 << 5 | 1 << 6 | UInt64(value) << 32, pointee.semaphore)
        let word = KernelLayout.physmap(pointee.semaphore)
        try waitUntil {
            let written = unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(word)).load()
            return read32(Vtd.faultStatus) & (1 << 4) != 0 || written == value
        }
        if read32(Vtd.faultStatus) & (1 << 4) != 0 {
            panicConsole?.write("iommu: VT-d invalidation queue error\n")
            write32(Vtd.faultStatus, 1 << 4)
            throw .internalError
        }
    }

    /// The IOTLB for `domain` (nil: all), draining reads and writes.
    func invalidateIotlbLocked(domain: UInt16?) throws(Status) {
        if pointee.queued {
            // IOTLB invalidate, draining reads and writes: global or domain.
            let granularity: UInt64 = domain.map { 2 << 4 | UInt64($0) << 16 } ?? 1 << 4
            submitLocked(0x2 | granularity | 1 << 7 | 1 << 6, 0)
            return try waitLocked()
        }
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

    /// The fault event: an MSI to the boot CPU, a kernel handler. The
    /// unit's own interrupts aren't remapped: compatibility format, with
    /// the APIC id's upper bits in FEUADDR (extended interrupt mode).
    private func setUpFaultEvents() {
        guard let vector = DeviceIrqs.allocateMsi(cpu: 0, count: 1) else { return }
        let apicId = DeviceIrqs.apicId(cpu: 0)
        DeviceIrqs.setKernelMsiHandler(cpu: 0, vector: vector, Vtd.faultEvent, address)
        write32(Vtd.faultData, vector)
        write32(Vtd.faultAddress, 0xFEE0_0000 | UInt32(apicId & 0xFF) << 12)
        write32(Vtd.faultUpperAddress, UInt32(truncatingIfNeeded: apicId & ~0xFF))
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
                    let interrupt = pointee.lastFaultReason >= 0x20  // an interrupt remapping fault: the entry in bits 63:48
                    console.write(interrupt ? "iommu: interrupt fault from " : "iommu: DMA fault from ")
                    console.write(hex: UInt64(sid >> 8))
                    console.write(":")
                    console.write(hex: UInt64((sid >> 3) & 0x1F))
                    console.write(".")
                    console.write(decimal: UInt64(sid & 7))
                    if interrupt {
                        console.write(" entry ")
                        console.write(decimal: low >> 48)
                    } else {
                        console.write(high & (1 << 62) != 0 ? " reading " : " writing ")
                        console.write(hex: pointee.lastFaultAddress)
                    }
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

    static func zeroedPage() -> UInt64? { IoDomains.zeroedPage() }

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

extension Vtd {
    /// Claims device `bdf` behind `unit`: a domain of its own, the reserved
    /// memory its scopes name identity mapped, its context entry pointed
    /// at it. OUT_OF_RANGE if the unit's scopes don't cover it,
    /// ALREADY_BOUND if it is claimed.
    static func attach(_ unit: VtdUnitPointer, bdf: UInt16) throws(Status) -> IoDomainPointer {
        guard covers(unit, bdf: bdf) else { throw .outOfRange }
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
        guard let domain = IoDomains.make(.vtd, unit: unit.address, id: id, deviceId: bdf, levels: unit.pointee.levels) else {
            freeId(unit, id)
            throw .noMemory
        }
        do throws(Status) {
            try mapReservedMemory(domain)
        } catch {
            free(domain)
            throw error
        }
        let root = domain.pointee.root
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
            // Claimed meanwhile by another bti_create (review fix: the check
            // above and this store were separate holds of the lock).
            let current = load(table, entry: entry).low
            if current & 1 != 0, (current >> 2) & 3 == 0 { throw .alreadyBound }
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
    static func detach(_ domain: IoDomainPointer) {
        let unit = VtdUnitPointer(address: domain.pointee.unit)
        let bus = Int(domain.pointee.deviceId >> 8), entry = Int(domain.pointee.deviceId & 0xFF)
        unit.pointee.lock.withLock {
            let table = unit.pointee.busTables[bus]
            store(table, entry: entry, low: 0, high: 0)
            unit.flushTables(table + UInt64(entry) * 16, 16)
            try? unit.invalidateContextsLocked()
            try? unit.invalidateIotlbLocked(domain: domain.pointee.domainId)
        }
        free(domain)
    }

    private static func free(_ domain: IoDomainPointer) {
        let unit = VtdUnitPointer(address: domain.pointee.unit)
        let id = domain.pointee.domainId
        IoDomains.free(domain)
        freeId(unit, id)
    }

    private static func freeId(_ unit: VtdUnitPointer, _ id: UInt16) {
        unit.pointee.lock.withLock { unit.pointee.domains[Int(id) / 64] &= ~(1 << UInt64(id % 64)) }
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
    private static func mapReservedMemory(_ domain: IoDomainPointer) throws(Status) {
        let unit = VtdUnitPointer(address: domain.pointee.unit)
        let base = unit.pointee.descriptor
        let header = unsafe UnsafeRawPointer(bitPattern: UInt(base))!.loadUnaligned(as: croi_iommu_desc_intel_t.self)
        var at = 16 + Int(header.scope_bytes)
        while at < unit.pointee.descriptorSize {
            let entry = unsafe UnsafeRawPointer(bitPattern: UInt(base) + UInt(at))!
                .loadUnaligned(as: croi_iommu_desc_intel_reserved_memory_t.self)
            if scopesInclude(base + UInt64(at) + 24, bytes: Int(entry.scope_bytes), bdf: domain.pointee.deviceId) {
                try IoDomains.identityMap(domain, entry.base_addr, entry.len)
            }
            at += 24 + Int(entry.scope_bytes)
        }
    }
}
#endif
