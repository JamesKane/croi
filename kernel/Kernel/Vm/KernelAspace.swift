import PageTables

/// The kernel's address space (Zircon's kernel VmAspace): the kernel page
/// tables plus a region allocator for the dynamic range (KernelLayout).
///
/// Regions are kept sorted by base, first fit, with at least one unmapped
/// guard page between neighbours and at the range ends, so running off a
/// region faults instead of corrupting the next one.
///
/// Every entry point takes `vmLock`. Lock order: vm -> heap -> pmm.
nonisolated(unsafe) var kernelAspace = KernelAspace()

let vmLock = SpinLock()

struct KernelAspace: ~Copyable {
    enum Kind {
        /// Address space only, nothing mapped by us.
        case reserved
        /// Fresh PMM pages, owned by the region and freed with it.
        case allocated
        /// Someone else's physical memory (e.g. device registers).
        case physical
    }

    struct Region {
        var base: UInt64
        var size: UInt64
        var kind: Kind
    }

    private var arch = ArchAspace(rootLow: 0, rootHigh: 0)
    private var regions = UniqueArray<Region>()

    static var guardSize: UInt64 { KernelLayout.pageSize }

    /// Takes over the page tables kernel_main switched to. Reserves room
    /// for the region list up front so typical use doesn't grow it.
    mutating func adopt(rootLow: UInt64, rootHigh: UInt64) {
        vmLock.withLock {
            arch = ArchAspace(rootLow: rootLow, rootHigh: rootHigh)
            regions.reserveCapacity(64)
        }
    }

    // MARK: Regions

    /// `pages` zeroed pages of fresh RAM, mapped read/write and never
    /// executable, between guard pages, at a base aligned to `alignment`.
    mutating func allocate(pages: Int, alignment: UInt64 = KernelLayout.pageSize) throws(VmError) -> UInt64 {
        try vmLock.withLock { () throws(VmError) -> UInt64 in
            let size = UInt64(pages) * KernelLayout.pageSize
            let (base, index) = try findGap(size: size, alignment: alignment)
            var mapped: UInt64 = 0
            do throws(VmError) {
                while mapped < size {
                    guard let phys = pmm.allocatePage() else { throw .outOfMemory }
                    unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(phys)))!
                        .initializeMemory(as: UInt8.self, repeating: 0, count: Int(KernelLayout.pageSize))
                    do throws(VmError) {
                        try arch.map(virt: base + mapped, phys: phys, size: KernelLayout.pageSize, Self.data)
                    } catch {
                        pmm.free(phys)
                        throw error
                    }
                    mapped += KernelLayout.pageSize
                }
            } catch {
                if mapped > 0 { releasePages(base, mapped) }
                throw error
            }
            regions.insert(Region(base: base, size: size, kind: .allocated), at: index)
            return base
        }
    }

    /// Maps `size` bytes of physical memory at `phys` (both page aligned)
    /// into the dynamic range. Returns the virtual base.
    mutating func mapPhysical(_ phys: UInt64, size: UInt64, _ attributes: MapAttributes) throws(VmError) -> UInt64 {
        try vmLock.withLock { () throws(VmError) -> UInt64 in
            let (base, index) = try findGap(size: size, alignment: KernelLayout.pageSize)
            do throws(VmError) {
                try arch.map(virt: base, phys: phys, size: size, attributes)
            } catch {
                try? arch.unmap(virt: base, size: size)
                throw error
            }
            regions.insert(Region(base: base, size: size, kind: .physical), at: index)
            return base
        }
    }

    /// Reserves `size` bytes of address space aligned to `alignment`,
    /// mapping nothing. The caller maps into it with `withArch`.
    mutating func reserve(size: UInt64, alignment: UInt64) throws(VmError) -> UInt64 {
        try vmLock.withLock { () throws(VmError) -> UInt64 in
            let (base, index) = try findGap(size: size, alignment: alignment)
            regions.insert(Region(base: base, size: size, kind: .reserved), at: index)
            return base
        }
    }

    /// Unmaps a region (freeing its pages if it owns them) and releases its
    /// address space. Reserved regions are unmapped too, in case the caller
    /// mapped into them.
    mutating func free(_ base: UInt64) throws(VmError) {
        try vmLock.withLock { () throws(VmError) in
            guard let index = indexOfRegion(at: base) else { throw .notFound(base) }
            let region = regions[index]
            switch region.kind {
            case .allocated:
                releasePages(region.base, region.size)
            case .physical, .reserved:
                try arch.unmap(virt: region.base, size: region.size)
            }
            _ = regions.remove(at: index)
        }
    }

    /// Runs `body` on the page tables with `vmLock` held.
    func withArch<R, E: Error>(_ body: (ArchAspace) throws(E) -> R) throws(E) -> R {
        try vmLock.withLock { () throws(E) -> R in try body(arch) }
    }

    func query(_ virt: UInt64) -> Translation? {
        vmLock.withLock { arch.query(virt) }
    }

    var regionCount: Int { vmLock.withLock { regions.count } }

    // MARK: Internals (vmLock held)

    private static var data: MapAttributes { MapAttributes(writable: true, global: true) }

    /// First fit: a base for `size` bytes with a guard page on both sides,
    /// and the index to insert its region at.
    private func findGap(size: UInt64, alignment: UInt64) throws(VmError) -> (UInt64, Int) {
        guard size > 0, size % KernelLayout.pageSize == 0,
              alignment >= KernelLayout.pageSize, alignment & (alignment - 1) == 0
        else { throw .unaligned(size) }
        let end = KernelLayout.dynamicBase + KernelLayout.dynamicSize
        var candidate = align(KernelLayout.dynamicBase + Self.guardSize, alignment)
        for i in 0..<regions.count {
            let region = regions[i]
            if candidate + size + Self.guardSize <= region.base {
                return (candidate, i)
            }
            candidate = align(region.base + region.size + Self.guardSize, alignment)
        }
        guard candidate + size + Self.guardSize <= end else { throw .noSpace }
        return (candidate, regions.count)
    }

    private func indexOfRegion(at base: UInt64) -> Int? {
        for i in 0..<regions.count where regions[i].base == base {
            return i
        }
        return nil
    }

    /// Unmaps [base, base+size) and returns the backing pages to the PMM.
    private func releasePages(_ base: UInt64, _ size: UInt64) {
        var offset: UInt64 = 0
        while offset < size {
            if let t = arch.query(base + offset) {
                try? arch.unmap(virt: base + offset, size: KernelLayout.pageSize)
                pmm.free(t.physical)
            }
            offset += KernelLayout.pageSize
        }
    }

    private func align(_ value: UInt64, _ alignment: UInt64) -> UInt64 {
        (value + alignment - 1) & ~(alignment - 1)
    }
}
