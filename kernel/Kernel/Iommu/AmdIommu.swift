import _Volatile
import CKernel
import Fmt
import PageTables
import Synchronization

#if arch(x86_64)
/// AMD-Vi DMA remapping (K12b; the AMD I/O Virtualization Technology
/// specification, 48882, rev. 3.x). Zircon has no AMD driver, so the ABI
/// is croi's: iommu_create(CROI_IOMMU_TYPE_AMD, croi_iommu_desc_amd_t),
/// whose register base must be an IVRS IVHD's; BTIs as VT-d's.
///
/// One `AmdviUnit` per IOMMU. Creation gives it a device table covering
/// every device id (2 MiB, entries invalid: untranslated, as before the
/// IOMMU was on), a command buffer for invalidations (each batch ends with
/// a COMPLETION_WAIT that stores to a semaphore word the CPU polls) and an
/// event log, whose interrupt is an MSI the kernel programs into the
/// IOMMU's own PCI function (ECAM from the MCFG). A claimed device's entry
/// points at an `IoDomain` of 4-level host page tables; a released one's
/// is valid with translation off and no permissions: blocked.
///
/// Not yet: interrupt remapping, device-specific IVHD scopes (a unit covers
/// its whole segment but itself), ATS, 5- and 6-level tables.
enum Amdvi {
    nonisolated(unsafe) static var units = InlineArray<8, UInt64>(repeating: 0)
    nonisolated(unsafe) static var unitCount = 0
    static let unitsLock = Mutex()

    // MARK: Registers (offsets)

    static var deviceTableBase: UInt64 { 0x00 }
    static var commandBufferBase: UInt64 { 0x08 }
    static var eventLogBase: UInt64 { 0x10 }
    static var control: UInt64 { 0x18 }
    static var extendedFeatures: UInt64 { 0x30 }
    static var commandHead: UInt64 { 0x2000 }
    static var commandTail: UInt64 { 0x2008 }
    static var eventHead: UInt64 { 0x2010 }
    static var eventTail: UInt64 { 0x2018 }
    static var status: UInt64 { 0x2020 }

    // Control bits.
    static var iommuEnable: UInt64 { 1 << 0 }
    static var eventLogEnable: UInt64 { 1 << 2 }
    static var eventInterruptEnable: UInt64 { 1 << 3 }
    static var coherent: UInt64 { 1 << 10 }
    static var commandBufferEnable: UInt64 { 1 << 12 }

    /// Buffers of 256 16-byte entries (one page each).
    static var ringBytes: UInt64 { 4096 }

    /// Creates or re-binds the unit `descriptor` describes and turns it on.
    static func create(_ descriptor: RawSpan) throws(Status) -> UInt64 {
        let headerSize = MemoryLayout<croi_iommu_desc_amd_t>.size
        let unitySize = MemoryLayout<croi_iommu_desc_amd_unity_t>.size
        guard descriptor.byteCount >= headerSize else { throw .invalidArgs }
        let header = unsafe descriptor.unsafeLoadUnaligned(as: croi_iommu_desc_amd_t.self)
        guard Int(header.unity_bytes) % unitySize == 0, headerSize + Int(header.unity_bytes) == descriptor.byteCount,
              header.register_base % KernelLayout.pageSize == 0 else { throw .invalidArgs }
        var at = headerSize
        while at < descriptor.byteCount {
            let unity = unsafe descriptor.unsafeLoadUnaligned(fromByteOffset: at, as: croi_iommu_desc_amd_unity_t.self)
            guard unity.base_addr % KernelLayout.pageSize == 0, unity.len % KernelLayout.pageSize == 0,
                  unity.first_device <= unity.last_device else { throw .invalidArgs }
            at += unitySize
        }
        guard Ivrs.find(header.register_base, segment: header.pci_segment) != nil else { throw .notFound }
        unitsLock.lock()
        defer { unitsLock.unlock() }
        for i in 0..<unitCount where AmdviUnitPointer(address: units[i]).pointee.registerBase == header.register_base {
            let unit = AmdviUnitPointer(address: units[i])
            guard !unit.pointee.bound else { throw .alreadyBound }
            try unit.setDescriptor(descriptor)
            unit.pointee.bound = true
            return unit.address
        }
        throw .notSupported  // in the IVRS, but boot couldn't bring it up
    }

    /// Brings up every IVRS unit (devices untranslated until claimed), then
    /// interrupt remapping (K12g) where every unit and the IVRS allow it.
    static func boot(_ acpi: AcpiTables, _ console: Uart) {
        for i in 0..<Ivrs.count where unitCount < units.count {
            if let unit = try? AmdviUnitPointer.make(Ivrs.units[i]) {
                units[unitCount] = unit.address
                unitCount += 1
            }
        }
        guard unitCount > 0 else { return }
        console.write("  iommu:  AMD-Vi, ")
        console.write(decimal: UInt64(unitCount))
        console.write(unitCount == 1 ? " unit; interrupt remapping " : " units; interrupt remapping ")
        if BootOptions.has("croi.intremap=off") {
            console.write("off (croi.intremap=off)\n")
            return
        }
        // As Linux: only where the IVRS describes every IOAPIC (firmware
        // that doesn't can't have its IOAPICs' interrupts remapped).
        guard unitCount == Ivrs.count, IoApic.allIds({ Ivrs.describesIoApic($0) }) else {
            console.write("not offered by the platform\n")
            return
        }
        var invalidateAll = true, extended = true
        for i in 0..<unitCount {
            let features = AmdviUnitPointer(address: units[i]).read64(Amdvi.extendedFeatures)
            invalidateAll = invalidateAll && features & (1 << 6) != 0             // IASup
            extended = extended && features & (1 << 2) != 0 && features & (1 << 7) != 0  // XTSup, GASup
        }
        guard invalidateAll else {
            console.write("not supported by every unit\n")
            return
        }
        var highest: UInt64 = 0
        Madt.forEachCpu(acpi) { cpu in highest = max(highest, cpu.hardwareId) }
        guard extended || highest <= 0xFF else {
            console.write("off (x2APIC ids above 255 without XT)\n")
            return
        }
        guard InterruptRemapping.startAmd(extended: extended) else {
            console.write("off (no memory)\n")
            return
        }
        // Every device's entry gets the table: remapped (IntCtl 10b), 2048
        // entries; then the units drop what they cached.
        let word2 = InterruptRemapping.table | 11 << 1 | 1 | 2 << 60
        for i in 0..<unitCount {
            let unit = AmdviUnitPointer(address: units[i])
            unit.pointee.lock.withLock {
                for device in 0..<65536 { unsafe (unit.entry(UInt16(device)) + 2).pointee = word2 }
                if extended {
                    unit.write64(Amdvi.control, unit.read64(Amdvi.control) | 1 << 17 | 1 << 50)  // GAEn, XTEn
                }
                unit.submitLocked(0, 8 << 28, 0, 0)  // INVALIDATE_IOMMU_ALL
                try? unit.waitLocked()
            }
        }
        InterruptRemapping.enabled = true
        console.write(extended ? "on, x2APIC destinations\n" : "on\n")
    }

    /// After an interrupt table entry changed: every unit drops its caches.
    static func invalidateInterrupts() {
        for i in 0..<unitCount {
            let unit = AmdviUnitPointer(address: units[i])
            unit.pointee.lock.withLock {
                unit.submitLocked(0, 8 << 28, 0, 0)  // INVALIDATE_IOMMU_ALL (IASup is required)
                try? unit.waitLocked()
            }
        }
    }

    static func unbind(_ address: UInt64) {
        unitsLock.lock()
        AmdviUnitPointer(address: address).pointee.bound = false
        unitsLock.unlock()
    }

    static func faultsCounted() -> UInt64 {
        var total: UInt64 = 0
        for i in 0..<unitCount {
            let unit = AmdviUnitPointer(address: units[i])
            unit.drainEvents()  // a fault whose interrupt hasn't come yet
            total += unit.pointee.faults
        }
        return total
    }

    static let eventInterrupt: DeviceIrqs.KernelMsiHandler = { address in AmdviUnitPointer(address: address).drainEvents() }

    // MARK: Devices

    /// Claims `deviceId`: a domain of its own (unity ranges naming it
    /// identity mapped) and its device table entry pointed at it.
    static func attach(_ unit: AmdviUnitPointer, deviceId: UInt16) throws(Status) -> IoDomainPointer {
        guard deviceId != unit.pointee.iommuDeviceId else { throw .outOfRange }
        let id = try unit.pointee.lock.withLock { () throws(Status) -> UInt16 in
            let low = unsafe unit.entry(deviceId).pointee
            // Claimed: valid, translation valid, a paging mode.
            if low & 3 == 3, (low >> 9) & 7 != 0 { throw .alreadyBound }
            for id in 1..<1024 where unit.pointee.domains[id / 64] & (1 << UInt64(id % 64)) == 0 {
                unit.pointee.domains[id / 64] |= 1 << UInt64(id % 64)
                return UInt16(id)
            }
            throw .noResources
        }
        guard let domain = IoDomains.make(.amd, unit: unit.address, id: id, deviceId: deviceId, levels: 4) else {
            freeId(unit, id)
            throw .noMemory
        }
        do throws(Status) {
            try mapUnityRanges(domain, unit)
            try unit.pointee.lock.withLock { () throws(Status) in
                let entry = unsafe unit.entry(deviceId)
                // Domain first, then valid + translation valid + mode 4 +
                // IR + IW with the root.
                unsafe (entry + 1).pointee = UInt64(id)
                unsafe entry.pointee = domain.pointee.root | 4 << 9 | 1 << 61 | 1 << 62 | 3
                try unit.invalidateDeviceLocked(deviceId, domain: id)
            }
        } catch {
            IoDomains.free(domain)
            freeId(unit, id)
            throw error
        }
        return domain
    }

    /// Blocks the device (valid, translation on in mode 0: no paging, no
    /// permissions) and frees its domain.
    static func detach(_ domain: IoDomainPointer) {
        let unit = AmdviUnitPointer(address: domain.pointee.unit)
        let deviceId = domain.pointee.deviceId, id = domain.pointee.domainId
        unit.pointee.lock.withLock {
            let entry = unsafe unit.entry(deviceId)
            unsafe entry.pointee = 3
            unsafe (entry + 1).pointee = 0
            try? unit.invalidateDeviceLocked(deviceId, domain: id)
        }
        IoDomains.free(domain)
        freeId(unit, id)
    }

    private static func freeId(_ unit: AmdviUnitPointer, _ id: UInt16) {
        unit.pointee.lock.withLock { unit.pointee.domains[Int(id) / 64] &= ~(1 << UInt64(id % 64)) }
    }

    private static func mapUnityRanges(_ domain: IoDomainPointer, _ unit: AmdviUnitPointer) throws(Status) {
        let base = unit.pointee.descriptor
        var at = MemoryLayout<croi_iommu_desc_amd_t>.size
        while at < unit.pointee.descriptorSize {
            let unity = unsafe UnsafeRawPointer(bitPattern: UInt(base) + UInt(at))!
                .loadUnaligned(as: croi_iommu_desc_amd_unity_t.self)
            if unity.first_device <= domain.pointee.deviceId, domain.pointee.deviceId <= unity.last_device {
                try IoDomains.identityMap(domain, unity.base_addr, unity.len)
            }
            at += MemoryLayout<croi_iommu_desc_amd_unity_t>.size
        }
    }
}

/// ACPI's IVRS: the AMD IOMMUs (IVHD blocks; the kernel needs each one's
/// registers, segment, PCI function and capability offset).
enum Ivrs {
    struct Unit {
        var registerBase: UInt64 = 0
        var segment: UInt16 = 0
        var deviceId: UInt16 = 0
        var capabilityOffset: UInt16 = 0
    }

    nonisolated(unsafe) static var units = InlineArray<8, Unit>(repeating: Unit())
    nonisolated(unsafe) static var count = 0
    /// IOAPICs the IVHDs' special device entries describe (their ids).
    nonisolated(unsafe) static var ioApics = InlineArray<8, UInt8>(repeating: 0)
    nonisolated(unsafe) static var ioApicCount = 0

    static func describesIoApic(_ id: UInt8) -> Bool {
        for i in 0..<ioApicCount where ioApics[i] == id { return true }
        return false
    }

    static func initialize(_ acpi: AcpiTables) {
        guard let ivrs = acpi.table("IVRS") else { return }
        acpi.withTable(ivrs) { (table: RawSpan) in
            var at = 48
            while at + 24 <= table.byteCount {
                let type = table.load(fromByteOffset: at, as: UInt8.self)
                let length = Int(unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 2, as: UInt16.self))
                guard length >= 4, at + length <= table.byteCount else { return }
                // One IOMMU may have several IVHD types (0x10, 0x11, 0x40):
                // keep the first block for each register base.
                if type == 0x10 || type == 0x11 || type == 0x40, count < units.count {
                    let unit = Unit(registerBase: unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 8, as: UInt64.self),
                                    segment: unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 16, as: UInt16.self),
                                    deviceId: unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 4, as: UInt16.self),
                                    capabilityOffset: unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 6, as: UInt16.self))
                    if find(unit.registerBase, segment: unit.segment) == nil {
                        units[count] = unit
                        count += 1
                    }
                    // Device entries: 4 bytes below type 64, 8 below 128;
                    // special devices (type 0x48) name IOAPICs (variety 1).
                    var entry = at + (type == 0x10 ? 24 : 40)
                    while entry + 4 <= at + length {
                        let kind = table.load(fromByteOffset: entry, as: UInt8.self)
                        let size = kind < 64 ? 4 : kind < 128 ? 8 : Int(table.load(fromByteOffset: entry + 21, as: UInt8.self)) + 22
                        guard entry + size <= at + length else { break }
                        if kind == 0x48, table.load(fromByteOffset: entry + 7, as: UInt8.self) == 1, ioApicCount < ioApics.count {
                            ioApics[ioApicCount] = table.load(fromByteOffset: entry + 4, as: UInt8.self)
                            ioApicCount += 1
                        }
                        entry += size
                    }
                }
                at += length
            }
        }
    }

    static func find(_ base: UInt64, segment: UInt16) -> Unit? {
        for i in 0..<count where units[i].registerBase == base && units[i].segment == segment { return units[i] }
        return nil
    }
}

/// One IOMMU's state (heap, never freed: the hardware keeps its tables).
struct AmdviUnit: ~Copyable {
    let registers: UInt64     // virtual
    let registerBase: UInt64  // physical
    let segment: UInt16
    let iommuDeviceId: UInt16
    let lock = SpinLock()
    var deviceTable: UInt64 = 0    // physical, 2 MiB
    var commandBuffer: UInt64 = 0  // physical
    var commandTailValue: UInt64 = 0
    var eventLog: UInt64 = 0       // physical
    var semaphore: UInt64 = 0      // physical: COMPLETION_WAIT stores here
    var sequence: UInt64 = 0
    var domains = InlineArray<16, UInt64>(repeating: 1)  // id 0 reserved
    var bound = false
    var descriptor: UInt64 = 0
    var descriptorSize = 0
    var faults: UInt64 = 0
}

@safe struct AmdviUnitPointer {
    let address: UInt64

    var pointee: AmdviUnit {
        unsafeAddress { unsafe UnsafePointer<AmdviUnit>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<AmdviUnit>(bitPattern: UInt(address))! }
    }

    func read64(_ offset: UInt64) -> UInt64 {
        unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: UInt(pointee.registers + offset)).load()
    }
    func write64(_ offset: UInt64, _ value: UInt64) {
        unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: UInt(pointee.registers + offset)).store(value)
    }

    /// A device's 32-byte table entry (four words), through the physmap.
    func entry(_ deviceId: UInt16) -> UnsafeMutablePointer<UInt64> {
        unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(pointee.deviceTable) + UInt64(deviceId) * 32))!
    }

    // MARK: Creation

    static func make(_ ivhd: Ivrs.Unit) throws(Status) -> AmdviUnitPointer {
        let registers: UInt64
        do throws(VmError) {
            registers = try kernelAspace.mapPhysical(ivhd.registerBase, size: 4 * KernelLayout.pageSize,
                                                     MapAttributes(writable: true, cache: .device, global: true))
        } catch {
            throw .noMemory
        }
        guard let raw = unsafe heap.allocate(size: MemoryLayout<AmdviUnit>.size, alignment: 64) else { throw .noMemory }
        unsafe raw.bindMemory(to: AmdviUnit.self, capacity: 1).initialize(to: AmdviUnit(
            registers: registers, registerBase: ivhd.registerBase, segment: ivhd.segment, iommuDeviceId: ivhd.deviceId))
        let unit = AmdviUnitPointer(address: UInt64(UInt(bitPattern: raw)))

        // Off while the tables change (firmware may have left it on).
        unit.write64(Amdvi.control, 0)
        guard let table = pmm.allocateContiguous(512, alignLog2: 12, .mmu),
              let commands = IoDomains.zeroedPage(), let events = IoDomains.zeroedPage(),
              let semaphore = IoDomains.zeroedPage() else { throw .noMemory }
        unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(table)))!
            .initializeMemory(as: UInt8.self, repeating: 0, count: 512 * Int(KernelLayout.pageSize))
        unit.pointee.deviceTable = table
        unit.pointee.commandBuffer = commands
        unit.pointee.eventLog = events
        unit.pointee.semaphore = semaphore
        unit.write64(Amdvi.deviceTableBase, table | 0x1FF)            // 512 pages: every device id
        unit.write64(Amdvi.commandBufferBase, commands | 8 << 56)     // 2^8 entries
        unit.write64(Amdvi.eventLogBase, events | 8 << 56)
        unit.write64(Amdvi.commandHead, 0)
        unit.write64(Amdvi.commandTail, 0)
        unit.write64(Amdvi.eventHead, 0)
        unit.write64(Amdvi.eventTail, 0)
        var control = Amdvi.iommuEnable | Amdvi.eventLogEnable | Amdvi.coherent | Amdvi.commandBufferEnable
        if unit.setUpEventInterrupt(ivhd) { control |= Amdvi.eventInterruptEnable }
        unit.write64(Amdvi.control, control)
        // Whatever it cached from firmware's tables goes.
        try unit.pointee.lock.withLock { () throws(Status) in
            if unit.read64(Amdvi.extendedFeatures) & (1 << 6) != 0 {  // IASup
                unit.submitLocked(0, 8 << 28, 0, 0)                   // INVALIDATE_IOMMU_ALL
            }
            try unit.waitLocked()
        }
        return unit
    }

    func setDescriptor(_ descriptor: RawSpan) throws(Status) {
        guard let copy = unsafe heap.allocate(size: descriptor.byteCount) else { throw .noMemory }
        descriptor.withUnsafeBytes { unsafe copy.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        if pointee.descriptor != 0 { unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(pointee.descriptor))!) }
        pointee.descriptor = UInt64(UInt(bitPattern: copy))
        pointee.descriptorSize = descriptor.byteCount
    }

    /// The event log interrupt: an MSI to the boot CPU, programmed in the
    /// IOMMU function's MSI capability (bus mastering on, so the IOMMU can
    /// send it). False if the function or its capability can't be found.
    private func setUpEventInterrupt(_ ivhd: Ivrs.Unit) -> Bool {
        guard let config = Mcfg.configSpace(segment: ivhd.segment, deviceId: ivhd.deviceId),
              let cfg = try? kernelAspace.mapPhysical(config, size: KernelLayout.pageSize,
                                                      MapAttributes(writable: true, cache: .device, global: true),
                                                      shared: true) else { return false }
        func read8(_ offset: UInt64) -> UInt8 { unsafe VolatileMappedRegister<UInt8>(unsafeBitPattern: UInt(cfg + offset)).load() }
        func read16(_ offset: UInt64) -> UInt16 { unsafe VolatileMappedRegister<UInt16>(unsafeBitPattern: UInt(cfg + offset)).load() }
        func write16(_ offset: UInt64, _ v: UInt16) { unsafe VolatileMappedRegister<UInt16>(unsafeBitPattern: UInt(cfg + offset)).store(v) }
        func write32(_ offset: UInt64, _ v: UInt32) { unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(cfg + offset)).store(v) }
        guard read16(6) & 0x10 != 0 else { return false }  // a capability list
        var cap = UInt64(read8(0x34) & 0xFC)
        var hops = 0
        while cap != 0, read8(cap) != 5, hops < 48 {
            cap = UInt64(read8(cap + 1) & 0xFC)
            hops += 1
        }
        // The IOMMU's own interrupt isn't remapped: compatibility format.
        let apicId = DeviceIrqs.apicId(cpu: 0)
        guard cap != 0, read8(cap) == 5, apicId <= 0xFF,
              let vector = DeviceIrqs.allocateMsi(cpu: 0, count: 1) else { return false }
        let message = (address: 0xFEE0_0000 | apicId << 12, data: vector)
        DeviceIrqs.setKernelMsiHandler(cpu: 0, vector: vector, Amdvi.eventInterrupt, address)
        let control = read16(cap + 2)
        write32(cap + 4, UInt32(truncatingIfNeeded: message.address))
        if control & (1 << 7) != 0 {  // 64-bit
            write32(cap + 8, 0)
            write16(cap + 0xC, UInt16(truncatingIfNeeded: message.data))
        } else {
            write16(cap + 8, UInt16(truncatingIfNeeded: message.data))
        }
        write16(cap + 2, (control & ~(7 << 4)) | 1)  // one message, enabled
        write16(4, read16(4) | 1 << 2)               // bus master
        return true
    }

    // MARK: Commands (unit lock held)

    /// Queues one command; waits for room if the ring is full.
    func submitLocked(_ d0: UInt32, _ d1: UInt32, _ d2: UInt32, _ d3: UInt32) {
        let tail = pointee.commandTailValue
        let next = (tail + 16) % Amdvi.ringBytes
        while read64(Amdvi.commandHead) & (Amdvi.ringBytes - 1) == next { arch_spin_pause() }
        let at = unsafe UnsafeMutablePointer<UInt32>(bitPattern: UInt(KernelLayout.physmap(pointee.commandBuffer) + tail))!
        unsafe at[0] = d0
        unsafe at[1] = d1
        unsafe at[2] = d2
        unsafe at[3] = d3
        pointee.commandTailValue = next
        write64(Amdvi.commandTail, next)
    }

    /// COMPLETION_WAIT storing a new sequence number, polled (one second
    /// at most): every command before it has finished.
    func waitLocked() throws(Status) {
        pointee.sequence += 1
        let value = pointee.sequence
        let semaphore = pointee.semaphore
        submitLocked(UInt32(truncatingIfNeeded: semaphore) | 1,                           // S: store
                     UInt32(truncatingIfNeeded: semaphore >> 32) & 0xF_FFFF | 1 << 28,  // opcode 1
                     UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32))
        let word = unsafe UnsafePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(semaphore)))!
        let giveUp = Clock.now() + 1_000_000_000
        while unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: UInt(bitPattern: word)).load() != value {
            guard Clock.now() < giveUp else { throw .timedOut }
            arch_spin_pause()
        }
    }

    /// After a device table entry changed: the entry and its domain's
    /// translations.
    func invalidateDeviceLocked(_ deviceId: UInt16, domain: UInt16) throws(Status) {
        submitLocked(UInt32(deviceId), 2 << 28, 0, 0)  // INVALIDATE_DEVTAB_ENTRY
        submitPagesLocked(domain)
        try waitLocked()
    }

    /// INVALIDATE_IOMMU_PAGES for the whole domain (S, all address bits,
    /// with the directory caches).
    private func submitPagesLocked(_ domain: UInt16) {
        submitLocked(0, UInt32(domain) | 3 << 28, 0xFFFF_F000 | 3, 0x7FFF_FFFF)
    }

    func invalidatePages(domain: UInt16) {
        pointee.lock.withLock {
            submitPagesLocked(domain)
            try? waitLocked()
        }
    }

    // MARK: Events

    /// Reads every event, counting page faults; logs the first few of a
    /// batch (a device retrying a refused access can fill the log) and how
    /// many more there were.
    func drainEvents() {
        pointee.lock.withLock {
            var head = read64(Amdvi.eventHead) & (Amdvi.ringBytes - 1)
            let tail = read64(Amdvi.eventTail) & (Amdvi.ringBytes - 1)
            var logged = 0
            while head != tail {
                let at = unsafe UnsafePointer<UInt32>(bitPattern: UInt(KernelLayout.physmap(pointee.eventLog) + head))!
                let (d0, d1) = unsafe (at[0], at[1])
                let address = unsafe UInt64(at[2]) | UInt64(at[3]) << 32
                let code = d1 >> 28
                if code == 2 { pointee.faults += 1 }  // IO_PAGE_FAULT
                logged += 1
                if logged <= 4, let console = panicConsole {
                    let device = UInt64(d0 & 0xFFFF)
                    console.write(code == 2 ? "iommu: DMA fault from " : "iommu: event ")
                    if code != 2 {
                        console.write(decimal: UInt64(code))
                        console.write(" from ")
                    }
                    console.write(hex: device >> 8)
                    console.write(":")
                    console.write(hex: (device >> 3) & 0x1F)
                    console.write(".")
                    console.write(decimal: device & 7)
                    if code == 2 { console.write(d1 & (1 << 21) != 0 ? " writing " : " reading ") } else { console.write(" at ") }
                    console.write(hex: address)
                    console.write("\n")
                }
                head = (head + 16) % Amdvi.ringBytes
            }
            if logged > 4, let console = panicConsole {
                console.write("iommu: ")
                console.write(decimal: UInt64(logged - 4))
                console.write(" more events\n")
            }
            write64(Amdvi.eventHead, head)
            write64(Amdvi.status, 3)  // clear EventOverflow and EventLogInt (write 1 to clear)
        }
    }
}
#endif
