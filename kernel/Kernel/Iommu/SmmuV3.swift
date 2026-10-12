import _Volatile
import CKernel
import Fmt
import PageTables
import Synchronization

#if arch(arm64)
/// Arm SMMUv3 DMA translation (K12c; the SMMU architecture specification
/// v3, IHI 0070). Zircon's ABI: iommu_create(ARM_SMMU,
/// zx_iommu_desc_arm_smmu_t), whose register base must be an IORT SMMUv3
/// node's (SMMUv1/v2 nodes go to SmmuV2.swift; Zircon's own ARM_SMMU
/// driver is v2, from a device tree). A unit firmware left enabled is
/// refused (BAD_STATE): it is firmware's. bti_create's id is the
/// PCI requester id; the IORT maps it to a stream id.
///
/// One `SmmuUnit` per SMMU. Creation gives it a linear stream table of
/// bypass entries (devices keep working untranslated, as before), a
/// command queue (each batch ends with CMD_SYNC; its consumption means the
/// batch is done) and an event queue, whose wired interrupt (the IORT's
/// event GSIV) the kernel takes. A claimed device's entry gets stage-1
/// translation through one context descriptor (ASID = domain id) over an
/// `IoDomain`'s 4-level VMSA tables; a released one aborts.
///
/// Not yet: SMMUv2, two-level stream tables, stage 2, MSIs for the queues,
/// ATS, PRI, named-component (non-PCI) stream ids.
enum SmmuV3 {
    nonisolated(unsafe) static var units = InlineArray<4, UInt64>(repeating: 0)
    nonisolated(unsafe) static var unitCount = 0
    static let unitsLock = Mutex()

    // MARK: Registers (offsets)

    static var idr0: UInt64 { 0x00 }
    static var idr1: UInt64 { 0x04 }
    static var idr5: UInt64 { 0x14 }
    static var cr0: UInt64 { 0x20 }
    static var cr0Ack: UInt64 { 0x24 }
    static var cr1: UInt64 { 0x28 }
    static var cr2: UInt64 { 0x2C }
    static var irqControl: UInt64 { 0x50 }
    static var irqControlAck: UInt64 { 0x54 }
    static var gerror: UInt64 { 0x60 }
    static var gerrorN: UInt64 { 0x64 }
    static var streamTableBase: UInt64 { 0x80 }
    static var streamTableConfig: UInt64 { 0x88 }
    static var commandQueueBase: UInt64 { 0x90 }
    static var commandProducer: UInt64 { 0x98 }
    static var commandConsumer: UInt64 { 0x9C }
    static var eventQueueBase: UInt64 { 0xA0 }
    static var eventProducer: UInt64 { 0x100A8 }  // page 1
    static var eventConsumer: UInt64 { 0x100AC }

    // CR0 bits.
    static var smmuEnable: UInt32 { 1 << 0 }
    static var eventQueueEnable: UInt32 { 1 << 2 }
    static var commandQueueEnable: UInt32 { 1 << 3 }

    /// Queue sizes (log2 of entries): 256 commands of 16 bytes, 128 events
    /// of 32 bytes, a page each.
    static var commandLog2: UInt32 { 8 }
    static var eventLog2: UInt32 { 7 }

    static func create(_ descriptor: RawSpan) throws(Status) -> UInt64 {
        guard descriptor.byteCount == MemoryLayout<UInt64>.size else { throw .invalidArgs }  // zx_iommu_desc_arm_smmu_t
        let base = unsafe descriptor.unsafeLoadUnaligned(as: UInt64.self)
        guard base % KernelLayout.pageSize == 0 else { throw .invalidArgs }
        guard let index = Iort.smmuIndex(base) else { throw .notFound }
        unitsLock.lock()
        defer { unitsLock.unlock() }
        for i in 0..<unitCount where SmmuUnitPointer(address: units[i]).pointee.registerBase == base {
            let unit = SmmuUnitPointer(address: units[i])
            guard !unit.pointee.bound else { throw .alreadyBound }
            unit.pointee.bound = true
            return unit.address
        }
        guard unitCount < units.count else { throw .noResources }
        let unit = try SmmuUnitPointer.make(index)
        unit.pointee.bound = true
        units[unitCount] = unit.address
        unitCount += 1
        return unit.address
    }

    static func unbind(_ address: UInt64) {
        unitsLock.lock()
        SmmuUnitPointer(address: address).pointee.bound = false
        unitsLock.unlock()
    }

    static func faultsCounted() -> UInt64 {
        var total: UInt64 = 0
        for i in 0..<unitCount {
            let unit = SmmuUnitPointer(address: units[i])
            unit.drainEvents()
            total += unit.pointee.faults
        }
        return total
    }

    static let eventInterrupt: DeviceIrqs.KernelHandler = { address in SmmuUnitPointer(address: address).drainEvents() }

    // MARK: Devices

    /// Claims the device with requester id `rid`: its stream's entry
    /// translated through a domain of its own.
    static func attach(_ unit: SmmuUnitPointer, requesterId rid: UInt16) throws(Status) -> IoDomainPointer {
        guard let sid = Iort.streamId(rid, smmu: unit.pointee.iortIndex), sid < unit.pointee.streams else {
            throw .outOfRange
        }
        let asidLimit = unit.pointee.asid16 ? 1024 : 256
        let id = try unit.pointee.lock.withLock { () throws(Status) -> UInt16 in
            let word0 = unsafe unit.entry(sid).pointee
            if (word0 >> 1) & 7 == 0b101 { throw .alreadyBound }  // stage-1 translated: claimed
            for id in 1..<asidLimit where unit.pointee.asids[id / 64] & (1 << UInt64(id % 64)) == 0 {
                unit.pointee.asids[id / 64] |= 1 << UInt64(id % 64)
                return UInt16(id)
            }
            throw .noResources
        }
        guard let domain = IoDomains.make(.smmu, unit: unit.address, id: id, deviceId: rid, levels: 4),
              let context = IoDomains.zeroedPage() else {
            freeAsid(unit, id)
            throw .noMemory
        }
        domain.pointee.extra = context
        // Its MSIs are writes to the ITS doorbell: that page stays reachable
        // at its own address (Linux's MSI window), as K12h needs.
        if Its.ready {
            do throws(Status) {
                try IoDomains.identityMap(domain, Its.translater & ~(KernelLayout.pageSize - 1), KernelLayout.pageSize)
            } catch {
                IoDomains.free(domain)
                pmm.free(context)
                freeAsid(unit, id)
                throw error
            }
        }
        unit.writeContext(context, root: domain.pointee.root, asid: id)
        do throws(Status) {
            try unit.pointee.lock.withLock { () throws(Status) in
                let entry = unsafe unit.entry(sid)
                // Break, then make: invalid while the other words change.
                unsafe entry.pointee = 0
                try unit.syncEntryLocked(sid)
                unsafe (entry + 1).pointee = unit.pointee.coherent ? (1 << 2 | 1 << 4 | 3 << 6) : 0  // CD fetch attributes
                unit.flushTables(unit.pointee.streamTable + UInt64(sid) * 64, 64)
                unsafe entry.pointee = (context & ~0x3F) | 0b101 << 1 | 1  // S1 translate, one CD, valid
                try unit.syncEntryLocked(sid)
            }
        } catch {
            IoDomains.free(domain)
            pmm.free(context)
            freeAsid(unit, id)
            throw error
        }
        return domain
    }

    /// The device's stream aborts; the domain's tables, CD and ASID go.
    static func detach(_ domain: IoDomainPointer) {
        let unit = SmmuUnitPointer(address: domain.pointee.unit)
        let id = domain.pointee.domainId, context = domain.pointee.extra
        if let sid = Iort.streamId(domain.pointee.deviceId, smmu: unit.pointee.iortIndex) {
            unit.pointee.lock.withLock {
                let entry = unsafe unit.entry(sid)
                unsafe entry.pointee = 1  // valid, config 000: abort
                try? unit.syncEntryLocked(sid)
                unit.submitLocked(0x11 | UInt64(id) << 48, 0)  // CMD_TLBI_NH_ASID
                try? unit.syncLocked()
            }
        }
        IoDomains.free(domain)
        pmm.free(context)
        freeAsid(unit, id)
    }

    private static func freeAsid(_ unit: SmmuUnitPointer, _ id: UInt16) {
        unit.pointee.lock.withLock { unit.pointee.asids[Int(id) / 64] &= ~(1 << UInt64(id % 64)) }
    }
}

/// ACPI's IORT: SMMUs and how PCI requester ids reach them as stream ids.
enum Iort {
    struct Smmu {
        var registerBase: UInt64 = 0
        var offset: UInt32 = 0          // the node's offset in the IORT
        var coherent = false            // COHACC override
        var eventInterrupt: UInt32 = 0  // GSIV, 0: none
    }

    struct Mapping {
        var inputBase: UInt32 = 0
        var count: UInt32 = 0  // ids in the range
        var outputBase: UInt32 = 0
        var smmu = 0           // index in `smmus`
    }

    nonisolated(unsafe) static var smmus = InlineArray<4, Smmu>(repeating: Smmu())
    nonisolated(unsafe) static var smmuCount = 0
    nonisolated(unsafe) static var mappings = InlineArray<16, Mapping>(repeating: Mapping())
    nonisolated(unsafe) static var mappingCount = 0
    /// Routes to the ITS (K12h): from a root complex (`smmu` -1) or from an
    /// SMMUv3's stream ids (`smmu` its index), to ITS DeviceIDs.
    nonisolated(unsafe) static var itsMappings = InlineArray<16, Mapping>(repeating: Mapping())
    nonisolated(unsafe) static var itsMappingCount = 0
    /// SMMUv1/v2 nodes (SmmuV2.swift).
    struct SmmuV2Node {
        var registerBase: UInt64 = 0
        var span: UInt64 = 0
        var model: UInt32 = 0
        var coherentWalks = false
        var contextInterrupts = 0
        /// Heap: per context bank, GSIV | edge << 32 (IORT order is bank
        /// order); 0 if none were listed.
        var interrupts: UInt64 = 0
    }

    nonisolated(unsafe) static var v2Nodes = InlineArray<4, SmmuV2Node>(repeating: SmmuV2Node())
    nonisolated(unsafe) static var v2Count = 0

    static func initialize(_ acpi: AcpiTables) {
        guard let iort = acpi.table("IORT") else { return }
        acpi.withTable(iort) { (table: RawSpan) in
            guard table.byteCount >= 48 else { return }
            let nodes = Int(unsafe table.unsafeLoadUnaligned(fromByteOffset: 36, as: UInt32.self))
            let first = Int(unsafe table.unsafeLoadUnaligned(fromByteOffset: 40, as: UInt32.self))
            // SMMUv3 nodes first, so root complexes can name them.
            var at = first
            for _ in 0..<nodes {
                guard at + 16 <= table.byteCount else { return }
                let type = table.load(fromByteOffset: at, as: UInt8.self)
                let length = Int(unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 1, as: UInt16.self))
                guard length >= 16, at + length <= table.byteCount else { return }
                if type == 4, length >= 48, smmuCount < smmus.count {
                    smmus[smmuCount] = Smmu(
                        registerBase: unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 16, as: UInt64.self),
                        offset: UInt32(at),
                        coherent: unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 24, as: UInt32.self) & 1 != 0,
                        eventInterrupt: unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 44, as: UInt32.self))
                    smmuCount += 1
                } else if type == 3, length >= 60, v2Count < v2Nodes.count {
                    var node = SmmuV2Node(
                        registerBase: unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 16, as: UInt64.self),
                        span: unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 24, as: UInt64.self),
                        model: unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 32, as: UInt32.self),
                        coherentWalks: unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 36, as: UInt32.self) & 2 != 0)
                    let count = Int(unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 44, as: UInt32.self))
                    let array = Int(unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 48, as: UInt32.self))
                    if count > 0, count <= 128, at + array + 8 * count <= table.byteCount,
                       let raw = unsafe heap.allocate(size: 8 * count) {
                        let words = unsafe raw.bindMemory(to: UInt64.self, capacity: count)
                        for i in 0..<count {
                            let gsiv = unsafe table.unsafeLoadUnaligned(fromByteOffset: at + array + 8 * i, as: UInt32.self)
                            let flags = unsafe table.unsafeLoadUnaligned(fromByteOffset: at + array + 8 * i + 4, as: UInt32.self)
                            unsafe words[i] = UInt64(gsiv) | UInt64(flags & 1) << 32
                        }
                        node.contextInterrupts = count
                        node.interrupts = UInt64(UInt(bitPattern: raw))
                    }
                    v2Nodes[v2Count] = node
                    v2Count += 1
                }
                at += length
            }
            // ITS groups (type 0): their offsets, so mappings can name them.
            var itsGroups = InlineArray<4, UInt32>(repeating: 0)
            var itsGroupCount = 0
            at = first
            for _ in 0..<nodes {
                let type = table.load(fromByteOffset: at, as: UInt8.self)
                let length = Int(unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 1, as: UInt16.self))
                if type == 0, itsGroupCount < itsGroups.count {
                    itsGroups[itsGroupCount] = UInt32(at)
                    itsGroupCount += 1
                }
                at += length
            }
            func isIts(_ offset: UInt32) -> Bool {
                for i in 0..<itsGroupCount where itsGroups[i] == offset { return true }
                return false
            }
            // Root complexes (type 2) and SMMUv3s (type 4): id mappings into
            // an SMMUv3 (root complexes) or an ITS group (both; an SMMUv3's
            // single mappings are its own interrupts, skipped).
            at = first
            for _ in 0..<nodes {
                let type = table.load(fromByteOffset: at, as: UInt8.self)
                let length = Int(unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 1, as: UInt16.self))
                if type == 2 || type == 4 {
                    var source = -1
                    for s in 0..<smmuCount where smmus[s].offset == UInt32(at) { source = s }
                    let count = Int(unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 8, as: UInt32.self))
                    let array = Int(unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 12, as: UInt32.self))
                    for m in 0..<count {
                        let entry = at + array + 20 * m
                        guard entry + 20 <= table.byteCount, itsMappingCount < itsMappings.count else { break }
                        let target = unsafe table.unsafeLoadUnaligned(fromByteOffset: entry + 12, as: UInt32.self)
                        let flags = unsafe table.unsafeLoadUnaligned(fromByteOffset: entry + 16, as: UInt32.self)
                        guard isIts(target), flags & 1 == 0 else { continue }
                        itsMappings[itsMappingCount] = Mapping(
                            inputBase: unsafe table.unsafeLoadUnaligned(fromByteOffset: entry, as: UInt32.self),
                            count: unsafe table.unsafeLoadUnaligned(fromByteOffset: entry + 4, as: UInt32.self) &+ 1,
                            outputBase: unsafe table.unsafeLoadUnaligned(fromByteOffset: entry + 8, as: UInt32.self),
                            smmu: type == 2 ? -1 : source)
                        itsMappingCount += 1
                    }
                }
                if type == 2 {
                    let count = Int(unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 8, as: UInt32.self))
                    let array = Int(unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 12, as: UInt32.self))
                    for m in 0..<count {
                        let entry = at + array + 20 * m
                        guard entry + 20 <= table.byteCount, mappingCount < mappings.count else { break }
                        let target = unsafe table.unsafeLoadUnaligned(fromByteOffset: entry + 12, as: UInt32.self)
                        for s in 0..<smmuCount where smmus[s].offset == target {
                            mappings[mappingCount] = Mapping(
                                inputBase: unsafe table.unsafeLoadUnaligned(fromByteOffset: entry, as: UInt32.self),
                                count: unsafe table.unsafeLoadUnaligned(fromByteOffset: entry + 4, as: UInt32.self) &+ 1,
                                outputBase: unsafe table.unsafeLoadUnaligned(fromByteOffset: entry + 8, as: UInt32.self),
                                smmu: s)
                            mappingCount += 1
                        }
                    }
                }
                at += length
            }
        }
        // The kernel's registers from boot (review fix: they joined the root
        // filter's list only at the first iommu_create, and a physical VMO
        // made before then kept working).
        let page = KernelLayout.pageSize
        for i in 0..<smmuCount where smmus[i].registerBase != 0 {
            RootFilter.recordKernelMmio(smmus[i].registerBase, 0x2_0000)  // SMMUv3: pages 0 and 1
        }
        for i in 0..<v2Count where v2Nodes[i].registerBase != 0 {
            RootFilter.recordKernelMmio(v2Nodes[i].registerBase, (v2Nodes[i].span + page - 1) & ~(page - 1))
        }
    }

    static func smmuIndex(_ base: UInt64) -> Int? {
        for i in 0..<smmuCount where smmus[i].registerBase == base { return i }
        return nil
    }

    static func smmuV2(_ base: UInt64) -> Int? {
        for i in 0..<v2Count where v2Nodes[i].registerBase == base { return i }
        return nil
    }

    /// The stream id requester id `rid` reaches SMMU `smmu` with, if any.
    static func streamId(_ rid: UInt16, smmu: Int) -> UInt32? {
        for i in 0..<mappingCount where mappings[i].smmu == smmu {
            let m = mappings[i]
            if UInt32(rid) >= m.inputBase, UInt32(rid) - m.inputBase < m.count { return m.outputBase + (UInt32(rid) - m.inputBase) }
        }
        return nil
    }

    /// The ITS DeviceID requester id `rid` reaches the ITS with: straight
    /// from the root complex, or through an SMMUv3's stream id.
    static func itsDeviceId(_ rid: UInt16) -> UInt32? {
        func through(_ source: Int, _ id: UInt32) -> UInt32? {
            for i in 0..<itsMappingCount where itsMappings[i].smmu == source {
                let m = itsMappings[i]
                if id >= m.inputBase, id - m.inputBase < m.count { return m.outputBase + (id - m.inputBase) }
            }
            return nil
        }
        if let direct = through(-1, UInt32(rid)) { return direct }
        for s in 0..<smmuCount {
            if let sid = streamId(rid, smmu: s), let device = through(s, sid) { return device }
        }
        return nil
    }

    /// The highest stream id any root complex reaches SMMU `smmu` with.
    static func maxStreamId(smmu: Int) -> UInt32 {
        var top: UInt32 = 0
        for i in 0..<mappingCount where mappings[i].smmu == smmu && mappings[i].count > 0 {
            top = max(top, mappings[i].outputBase &+ mappings[i].count - 1)
        }
        return top
    }
}

/// One SMMU's state (heap, never freed: the hardware keeps its tables).
struct SmmuUnit: ~Copyable {
    let registers: UInt64     // virtual
    let registerBase: UInt64  // physical
    let iortIndex: Int
    let coherent: Bool
    let asid16: Bool
    let outputSize: UInt64    // IDR5.OAS (the CD's IPS encoding)
    let lock = SpinLock()
    var streamTable: UInt64 = 0  // physical
    var streams: UInt32 = 0
    var commandQueue: UInt64 = 0
    var commandProducerValue: UInt32 = 0
    var eventQueue: UInt64 = 0
    var asids = InlineArray<16, UInt64>(repeating: 1)  // ASID 0 reserved
    var bound = false
    var faults: UInt64 = 0
}

@safe struct SmmuUnitPointer {
    let address: UInt64

    var pointee: SmmuUnit {
        unsafeAddress { unsafe UnsafePointer<SmmuUnit>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<SmmuUnit>(bitPattern: UInt(address))! }
    }

    func read32(_ offset: UInt64) -> UInt32 {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(pointee.registers + offset)).load()
    }
    func write32(_ offset: UInt64, _ value: UInt32) {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(pointee.registers + offset)).store(value)
    }
    func write64(_ offset: UInt64, _ value: UInt64) {
        unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: UInt(pointee.registers + offset)).store(value)
    }

    /// A stream's 64-byte table entry (eight words), through the physmap.
    func entry(_ sid: UInt32) -> UnsafeMutablePointer<UInt64> {
        unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(pointee.streamTable) + UInt64(sid) * 64))!
    }

    private func waitUntil(_ done: () -> Bool) throws(Status) {
        let giveUp = Clock.now() + 1_000_000_000
        while !done() {
            guard Clock.now() < giveUp else { throw .timedOut }
            arch_spin_pause()
        }
    }

    /// Writes CR0 and waits for CR0ACK to match.
    private func setControl(_ value: UInt32) throws(Status) {
        write32(SmmuV3.cr0, value)
        try waitUntil { read32(SmmuV3.cr0Ack) == value }
    }

    // MARK: Creation

    static func make(_ index: Int) throws(Status) -> SmmuUnitPointer {
        let node = Iort.smmus[index]
        let registers: UInt64
        do throws(VmError) {
            registers = try kernelAspace.mapPhysical(node.registerBase, size: 0x20000,
                                                     MapAttributes(writable: true, cache: .device, global: true))
        } catch {
            throw .noMemory
        }
        func read(_ offset: UInt64) -> UInt32 {
            unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(registers + offset)).load()
        }
        // A unit firmware left on is firmware's (the Q8B's PCIe SMMUv3 is
        // reserved, and its hypervisor resets the SoC on writes it doesn't
        // expect): leave it alone until a board rule hands it over.
        guard read(SmmuV3.cr0) & SmmuV3.smmuEnable == 0 else { throw .badState }
        let idr0 = read(SmmuV3.idr0), idr1 = read(SmmuV3.idr1), idr5 = read(SmmuV3.idr5)
        // Stage 1, AArch64 tables, 4 KiB granules.
        guard idr0 & (1 << 1) != 0, (idr0 >> 2) & 3 != 1, idr5 & (1 << 4) != 0 else { throw .notSupported }
        let sidBits = idr1 & 0x3F
        guard (idr1 >> 21) & 0x1F >= SmmuV3.commandLog2, (idr1 >> 16) & 0x1F >= SmmuV3.eventLog2 else {
            throw .notSupported
        }
        guard let raw = unsafe heap.allocate(size: MemoryLayout<SmmuUnit>.size, alignment: 64) else { throw .noMemory }
        unsafe raw.bindMemory(to: SmmuUnit.self, capacity: 1).initialize(to: SmmuUnit(
            registers: registers, registerBase: node.registerBase, iortIndex: index,
            coherent: idr0 & (1 << 4) != 0 || node.coherent, asid16: idr0 & (1 << 12) != 0,
            outputSize: UInt64(min(idr5 & 7, 5))))
        let unit = SmmuUnitPointer(address: UInt64(UInt(bitPattern: raw)))


        // A linear stream table of bypass entries reaching every stream id
        // the IORT routes here.
        let wanted = min(UInt64(Iort.maxStreamId(smmu: index)) + 1, 1 << UInt64(sidBits))
        var log2: UInt64 = 0
        while 1 << log2 < wanted { log2 += 1 }
        let bytes = max(64 << log2, KernelLayout.pageSize)
        let pages = bytes / KernelLayout.pageSize
        var align = 12
        while UInt64(1) << UInt64(align) < bytes { align += 1 }
        guard let table = pmm.allocateContiguous(pages, alignLog2: align, .mmu),
              let commands = IoDomains.zeroedPage(), let events = IoDomains.zeroedPage() else { throw .noMemory }
        unit.pointee.streamTable = table
        unit.pointee.streams = UInt32(1 << log2)
        unit.pointee.commandQueue = commands
        unit.pointee.eventQueue = events
        for sid in 0..<UInt32(1 << log2) {
            let entry = unsafe unit.entry(sid)
            for w in 1..<8 { unsafe (entry + w).pointee = 0 }
            unsafe (entry + 1).pointee = 1 << 44  // SHCFG: the incoming shareability
            unsafe entry.pointee = 0b100 << 1 | 1  // bypass, valid
        }
        unit.flushTables(table, bytes)

        // Walks and queues cacheable where the SMMU is coherent.
        let attributes: UInt32 = unit.pointee.coherent ? 1 | 1 << 2 | 3 << 4 : 2 << 4
        unit.write32(SmmuV3.cr1, attributes | attributes << 6)  // queues, tables
        unit.write32(SmmuV3.cr2, 1 << 1 | 1 << 2)               // RECINVSID, PTM
        let readAllocate: UInt64 = unit.pointee.coherent ? 1 << 62 : 0
        unit.write64(SmmuV3.streamTableBase, readAllocate | table)
        unit.write32(SmmuV3.streamTableConfig, UInt32(log2))  // linear
        unit.write64(SmmuV3.commandQueueBase, readAllocate | commands | UInt64(SmmuV3.commandLog2))
        unit.write32(SmmuV3.commandProducer, 0)
        unit.write32(SmmuV3.commandConsumer, 0)
        unit.write64(SmmuV3.eventQueueBase, readAllocate | events | UInt64(SmmuV3.eventLog2))
        unit.write32(SmmuV3.eventProducer, 0)
        unit.write32(SmmuV3.eventConsumer, 0)
        try unit.setControl(SmmuV3.commandQueueEnable | SmmuV3.eventQueueEnable)
        // Whatever it cached goes: configuration, then non-secure TLBs.
        try unit.pointee.lock.withLock { () throws(Status) in
            unit.submitLocked(0x04, 31)  // CMD_CFGI_ALL
            unit.submitLocked(0x10, 0)   // CMD_TLBI_NH_ALL
            unit.submitLocked(0x30, 0)   // CMD_TLBI_NSNH_ALL
            try unit.syncLocked()
        }
        if node.eventInterrupt != 0,
           DeviceIrqs.setKernelHandler(node.eventInterrupt, level: false, SmmuV3.eventInterrupt, unit.address) {
            unit.write32(SmmuV3.irqControl, 1 << 2 | 1 << 0)  // EVENTQ, GERROR
        }
        try unit.setControl(SmmuV3.commandQueueEnable | SmmuV3.eventQueueEnable | SmmuV3.smmuEnable)
        return unit
    }

    /// After the CPU wrote [phys, phys+size) of a table or queue: visible to
    /// an SMMU that doesn't snoop.
    func flushTables(_ phys: UInt64, _ size: UInt64) {
        if !pointee.coherent { arch_cache_op(KernelLayout.physmap(phys), size, CROI_CACHE_CLEAN, VmoCache.line) }
    }

    /// A domain's context descriptor: TTB0 = `root`, 48-bit input, 4 KiB
    /// granule, TTB1 walks off, AArch64, faults recorded and aborted,
    /// access-flag faults off, MAIR index 0 write-back, index 1 non-cacheable.
    func writeContext(_ context: UInt64, root: UInt64, asid: UInt16) {
        let walk: UInt64 = pointee.coherent ? 1 << 8 | 1 << 10 | 3 << 12 : 2 << 12
        let word0: UInt64 = 16 | walk | 1 << 30 | 1 << 31 | pointee.outputSize << 32 | 1 << 35 | 1 << 41
            | 1 << 45 | 1 << 46 | 1 << 47 | UInt64(asid) << 48
        let cd = unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(context)))!
        unsafe cd[1] = root
        unsafe cd[3] = 0x44FF
        unsafe cd[0] = word0
        flushTables(context, 64)
    }

    // MARK: Commands (unit lock held)

    /// Queues one 16-byte command; waits while the queue is full.
    func submitLocked(_ word0: UInt64, _ word1: UInt64) {
        let size: UInt32 = 1 << SmmuV3.commandLog2
        let producer = pointee.commandProducerValue
        let next = (producer + 1) & (2 * size - 1)  // index and wrap bit
        // Full: same index, different wrap.
        while (producer ^ (read32(SmmuV3.commandConsumer) & (2 * size - 1))) == size { arch_spin_pause() }
        let index = UInt64(producer & (size - 1))
        let at = unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(pointee.commandQueue) + index * 16))!
        unsafe at[0] = word0
        unsafe at[1] = word1
        flushTables(pointee.commandQueue + index * 16, 16)
        pointee.commandProducerValue = next
        write32(SmmuV3.commandProducer, next)
    }

    /// CMD_SYNC, then waits until the SMMU has consumed it: every earlier
    /// command has completed. A command error is logged and skipped.
    func syncLocked() throws(Status) {
        submitLocked(0x46, 0)  // CMD_SYNC, no completion signal
        let target = pointee.commandProducerValue
        let mask: UInt32 = (2 << SmmuV3.commandLog2) - 1
        try waitUntil {
            if (read32(SmmuV3.gerror) ^ read32(SmmuV3.gerrorN)) & 1 != 0 { return true }  // CMDQ_ERR
            return read32(SmmuV3.commandConsumer) & mask == target
        }
        if (read32(SmmuV3.gerror) ^ read32(SmmuV3.gerrorN)) & 1 != 0 {
            let consumer = read32(SmmuV3.commandConsumer)
            if let console = panicConsole {
                console.write("iommu: SMMU command error ")
                console.write(decimal: UInt64((consumer >> 24) & 0x7F))
                console.write("\n")
            }
            // Acknowledge; the failed command is skipped by moving on.
            write32(SmmuV3.gerrorN, read32(SmmuV3.gerror))
            throw .internalError
        }
    }

    /// After a stream table entry changed: the SMMU drops its copy.
    func syncEntryLocked(_ sid: UInt32) throws(Status) {
        flushTables(pointee.streamTable + UInt64(sid) * 64, 64)
        submitLocked(0x03 | UInt64(sid) << 32, 1)  // CMD_CFGI_STE, leaf
        try syncLocked()
    }

    /// A domain's cached translations go.
    func invalidateAsid(_ asid: UInt16) {
        pointee.lock.withLock {
            submitLocked(0x11 | UInt64(asid) << 48, 0)  // CMD_TLBI_NH_ASID
            try? syncLocked()
        }
    }

    // MARK: Events

    /// Reads every event, counting translation, permission and access
    /// faults; logs the first four of a batch and how many more there were.
    func drainEvents() {
        pointee.lock.withLock {
            let size: UInt32 = 1 << SmmuV3.eventLog2
            let mask = 2 * size - 1
            let producer = read32(SmmuV3.eventProducer)
            var consumer = read32(SmmuV3.eventConsumer) & mask
            var logged = 0
            while consumer != producer & mask {
                let index = UInt64(consumer & (size - 1))
                let at = unsafe UnsafePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(pointee.eventQueue) + index * 32))!
                if !pointee.coherent {
                    arch_cache_op(KernelLayout.physmap(pointee.eventQueue + index * 32), 32, CROI_CACHE_INVALIDATE, VmoCache.line)
                }
                let (word0, word1, word2) = unsafe (at[0], at[1], at[2])
                let type = word0 & 0xFF
                if type >= 0x10, type <= 0x13 { pointee.faults += 1 }  // F_TRANSLATION .. F_PERMISSION
                logged += 1
                if logged <= 4, let console = panicConsole {
                    let rid = word0 >> 32
                    console.write(type >= 0x10 && type <= 0x13 ? "iommu: DMA fault " : "iommu: event ")
                    console.write(hex: type)
                    console.write(" from stream ")
                    console.write(hex: rid)
                    console.write(word1 & (1 << 35) != 0 ? " reading " : " writing ")
                    console.write(hex: word2)
                    console.write("\n")
                }
                consumer = (consumer + 1) & mask
            }
            if logged > 4, let console = panicConsole {
                console.write("iommu: ")
                console.write(decimal: UInt64(logged - 4))
                console.write(" more events\n")
            }
            write32(SmmuV3.eventConsumer, consumer | producer & (1 << 31))  // acknowledge an overflow
            // Global errors: acknowledge (and report) whatever is active.
            let active = read32(SmmuV3.gerror) ^ read32(SmmuV3.gerrorN)
            if active & ~1 != 0 {
                if let console = panicConsole {
                    console.write("iommu: SMMU global error ")
                    console.write(hex: UInt64(active))
                    console.write("\n")
                }
                write32(SmmuV3.gerrorN, read32(SmmuV3.gerror) & ~1 | read32(SmmuV3.gerrorN) & 1)
            }
        }
    }
}
#endif
