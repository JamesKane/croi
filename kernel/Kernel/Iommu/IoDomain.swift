import CKernel
import PageTables

#if arch(x86_64)
/// What the IOMMU drivers share (K12): a claimed device's translation
/// domain, its I/O virtual address allocator and its page tables, whose
/// formats differ only in their bits (VT-d second-level tables, AMD-Vi
/// host page tables; both 512 entries of 64 bits, 4 KiB pages, addresses
/// in bits 51:12). The unit-specific parts (making a table write visible,
/// invalidating the IOTLB) dispatch on `kind`.
enum IommuKind: UInt8 {
    case vtd
    case amd
}

struct IoDomain: ~Copyable {
    let kind: IommuKind
    /// The unit's record (VtdUnit or AmdviUnit).
    let unit: UInt64
    let domainId: UInt16
    /// The device: bus << 8 | device << 3 | function.
    let deviceId: UInt16
    let root: UInt64  // physical
    let levels: Int
    let lock = SpinLock()
    /// Allocated IOVA ranges, sorted by base.
    var used = UniqueArray<IovaRange>()
    /// Table pages (freed with the domain).
    var tables = UniqueArray<UInt64>()

    var inputBits: UInt64 { UInt64(12 + 9 * levels) }
}

struct IovaRange {
    var base: UInt64
    var size: UInt64
}

@safe struct IoDomainPointer {
    let address: UInt64

    var pointee: IoDomain {
        unsafeAddress { unsafe UnsafePointer<IoDomain>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<IoDomain>(bitPattern: UInt(address))! }
    }
}

enum IoDomains {
    /// A domain record with an empty root table, or nil.
    static func make(_ kind: IommuKind, unit: UInt64, id: UInt16, deviceId: UInt16, levels: Int) -> IoDomainPointer? {
        guard let root = zeroedPage() else { return nil }
        guard let raw = unsafe heap.allocate(size: MemoryLayout<IoDomain>.size, alignment: 64) else {
            pmm.free(root)
            return nil
        }
        unsafe raw.bindMemory(to: IoDomain.self, capacity: 1).initialize(to: IoDomain(
            kind: kind, unit: unit, domainId: id, deviceId: deviceId, root: root, levels: levels))
        let domain = IoDomainPointer(address: UInt64(UInt(bitPattern: raw)))
        domain.pointee.tables.append(root)
        wrote(domain, root, KernelLayout.pageSize)
        return domain
    }

    /// Frees the tables and the record (no device points at them; the
    /// driver frees the id).
    static func free(_ domain: IoDomainPointer) {
        for i in 0..<domain.pointee.tables.count { pmm.free(domain.pointee.tables[i]) }
        let raw = unsafe UnsafeMutablePointer<IoDomain>(bitPattern: UInt(domain.address))!
        unsafe raw.deinitialize(count: 1)
        unsafe heap.free(UnsafeMutableRawPointer(raw))
    }

    /// A zeroed page for tables (PMM, state mmu), or nil.
    static func zeroedPage() -> UInt64? {
        guard let phys = pmm.allocatePage(.mmu) else { return nil }
        unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(phys)))!
            .initializeMemory(as: UInt8.self, repeating: 0, count: Int(KernelLayout.pageSize))
        return phys
    }

    // MARK: IOVAs

    /// `size` bytes of I/O virtual addresses inside [low, high), first fit
    /// from 1 MiB (address 0 stays unmapped), or at `fixed`.
    static func reserve(_ domain: IoDomainPointer, at fixed: UInt64? = nil, size: UInt64,
                        low: UInt64 = 0, high: UInt64 = .max) throws(Status) -> UInt64 {
        let limit = min(high, 1 << domain.pointee.inputBits)
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

    static func release(_ domain: IoDomainPointer, iova: UInt64) {
        domain.pointee.lock.withLock {
            for i in 0..<domain.pointee.used.count where domain.pointee.used[i].base == iova {
                _ = domain.pointee.used.remove(at: i)
                return
            }
        }
    }

    /// Firmware's ranges the device may still be using (VT-d RMRRs, AMD-Vi
    /// unity maps): reserved and mapped at their own addresses.
    static func identityMap(_ domain: IoDomainPointer, _ base: UInt64, _ size: UInt64) throws(Status) {
        _ = try reserve(domain, at: base, size: size)
        var offset: UInt64 = 0
        while offset < size {
            try map(domain, iova: base + offset, phys: base + offset, write: true)
            offset += KernelLayout.pageSize
        }
    }

    // MARK: Page tables

    private static var addressMask: UInt64 { 0x000F_FFFF_FFFF_F000 }

    private static func present(_ kind: IommuKind, _ entry: UInt64) -> Bool {
        kind == .vtd ? entry & 3 != 0 : entry & 1 != 0
    }

    /// A table entry pointing at the next level's table (`level` is the
    /// level of the table holding it); permissions are the leaves'.
    private static func directory(_ kind: IommuKind, _ next: UInt64, level: Int) -> UInt64 {
        switch kind {
        case .vtd: return next | 3                                            // read, write
        case .amd: return next | 1 | UInt64(level - 1) << 9 | 1 << 61 | 1 << 62  // PR, next level, IR, IW
        }
    }

    private static func leaf(_ kind: IommuKind, _ phys: UInt64, write: Bool) -> UInt64 {
        switch kind {
        case .vtd: return phys | 1 | (write ? 2 : 0)
        case .amd: return phys | 1 | 1 << 61 | (write ? 1 << 62 : 0)  // next level 0: a page
        }
    }

    /// Maps one page (read, and write if asked).
    static func map(_ domain: IoDomainPointer, iova: UInt64, phys: UInt64, write: Bool) throws(Status) {
        let kind = domain.pointee.kind
        try domain.pointee.lock.withLock { () throws(Status) in
            var table = domain.pointee.root
            for level in stride(from: domain.pointee.levels, to: 1, by: -1) {
                let index = Int((iova >> UInt64(12 + 9 * (level - 1))) & 0x1FF)
                let slot = unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(table)))! + index
                if unsafe !present(kind, slot.pointee) {
                    guard let next = zeroedPage() else { throw .noMemory }
                    domain.pointee.tables.append(next)
                    wrote(domain, next, KernelLayout.pageSize)
                    unsafe slot.pointee = directory(kind, next, level: level)
                    wrote(domain, table + UInt64(index) * 8, 8)
                }
                table = unsafe slot.pointee & addressMask
            }
            let index = Int((iova >> 12) & 0x1FF)
            let slot = unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(table)))! + index
            unsafe slot.pointee = leaf(kind, phys, write: write)
            wrote(domain, table + UInt64(index) * 8, 8)
        }
        if kind == .vtd, VtdUnitPointer(address: domain.pointee.unit).pointee.cachingMode {
            invalidate(domain)  // caching mode caches not-present entries too
        }
    }

    /// Unmaps [iova, iova+size) and invalidates the domain's IOTLB: when it
    /// returns, the device can't reach those pages.
    static func unmap(_ domain: IoDomainPointer, iova: UInt64, size: UInt64) {
        let kind = domain.pointee.kind
        domain.pointee.lock.withLock {
            var at = iova
            while at < iova + size {
                var table = domain.pointee.root
                var found = true
                for level in stride(from: domain.pointee.levels, to: 1, by: -1) {
                    let index = Int((at >> UInt64(12 + 9 * (level - 1))) & 0x1FF)
                    let entry = unsafe UnsafePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(table)))![index]
                    guard present(kind, entry) else { found = false; break }
                    table = entry & addressMask
                }
                if found {
                    let index = Int((at >> 12) & 0x1FF)
                    unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(table)))![index] = 0
                    wrote(domain, table + UInt64(index) * 8, 8)
                }
                at += KernelLayout.pageSize
            }
        }
        invalidate(domain)
    }

    // MARK: Unit-specific

    /// The CPU wrote [phys, phys+size) of a table.
    private static func wrote(_ domain: IoDomainPointer, _ phys: UInt64, _ size: UInt64) {
        if domain.pointee.kind == .vtd { VtdUnitPointer(address: domain.pointee.unit).flushTables(phys, size) }
        // AMD-Vi page walks snoop the CPU's caches.
    }

    /// The domain's cached translations go.
    static func invalidate(_ domain: IoDomainPointer) {
        switch domain.pointee.kind {
        case .vtd:
            let unit = VtdUnitPointer(address: domain.pointee.unit)
            unit.pointee.lock.withLock { try? unit.invalidateIotlbLocked(domain: domain.pointee.domainId) }
        case .amd:
            AmdviUnitPointer(address: domain.pointee.unit).invalidatePages(domain: domain.pointee.domainId)
        }
    }
}

/// What Dma.swift calls: claiming and releasing devices, whatever the unit.
enum Iommus {
    static func attach(_ kind: IommuKind, unit: UInt64, deviceId: UInt16) throws(Status) -> IoDomainPointer {
        switch kind {
        case .vtd: return try Vtd.attach(VtdUnitPointer(address: unit), bdf: deviceId)
        case .amd: return try Amdvi.attach(AmdviUnitPointer(address: unit), deviceId: deviceId)
        }
    }

    /// Blocks the device and frees its domain.
    static func detach(_ domain: IoDomainPointer) {
        switch domain.pointee.kind {
        case .vtd: Vtd.detach(domain)
        case .amd: Amdvi.detach(domain)
        }
    }

    static func unbind(_ kind: IommuKind, unit: UInt64) {
        switch kind {
        case .vtd: Vtd.unbind(unit)
        case .amd: Amdvi.unbind(unit)
        }
    }

    /// Faults every unit has recorded (self-test).
    static func faultsCounted() -> UInt64 { Vtd.faultsCounted() + Amdvi.faultsCounted() }

    /// The first unit the firmware describes, for the self-test's user
    /// side (a driver reads the ACPI tables itself): its type and registers.
    static func firstUnit() -> (type: UInt32, base: UInt64)? {
        if Dmar.count > 0 { return (UInt32(CROI_IOMMU_TYPE_INTEL), Dmar.units[0].registerBase) }
        if Ivrs.count > 0 { return (UInt32(CROI_IOMMU_TYPE_AMD), Ivrs.units[0].registerBase) }
        return nil
    }
}
#endif
