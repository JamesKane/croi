/// Where a `PageTableBuilder` gets its table pages from and how it reaches
/// them: firmware pages through the identity map in the loader, early boot
/// pages through the identity map or the physmap in the kernel.
public protocol PageTableMemory {
    /// A zeroed, page-aligned physical page for a new table, or nil.
    mutating func allocateTable() -> UInt64?
    /// The address the table at physical `phys` can be accessed at now.
    func tableAddress(_ phys: UInt64) -> UInt
}

public enum MapError: Error {
    case unaligned(UInt64)
    case overlap(UInt64)
    case outOfMemory
}

/// Builds page tables for this architecture's format (`PageTableFormat`).
public struct PageTableBuilder<Memory: PageTableMemory> {
    public var memory: Memory

    /// Root for the low half (and everything, except on arm64).
    public let rootLow: UInt64
    /// Root for the high half: TTBR1 on arm64, the same table elsewhere.
    public let rootHigh: UInt64

    @inlinable
    public init(memory: Memory) throws(MapError) {
        var memory = memory
        guard let low = memory.allocateTable() else { throw .outOfMemory }
        #if arch(arm64)
        guard let high = memory.allocateTable() else { throw .outOfMemory }
        #else
        let high = low
        #endif
        self.memory = memory
        rootLow = low
        rootHigh = high
    }

    /// Maps [virt, virt+size) to [phys, phys+size) using the largest pages
    /// that fit. All three must be page aligned; overlaps are an error.
    @inlinable
    public mutating func map(virt: UInt64, phys: UInt64, size: UInt64, _ attributes: MapAttributes) throws(MapError) {
        let pageSize = PageTableFormat.pageSize(level: PageTableFormat.levels - 1)
        guard virt % pageSize == 0, phys % pageSize == 0, size % pageSize == 0 else {
            throw .unaligned(virt)
        }
        var virt = virt, phys = phys, left = size
        while left > 0 {
            var level = PageTableFormat.levels - 1
            for candidate in 0..<PageTableFormat.levels where PageTableFormat.leafAllowed(level: candidate) {
                let page = PageTableFormat.pageSize(level: candidate)
                if virt % page == 0, phys % page == 0, left >= page {
                    level = candidate
                    break
                }
            }
            try mapOne(virt: virt, phys: phys, level: level, attributes)
            let page = PageTableFormat.pageSize(level: level)
            virt &+= page
            phys += page
            left -= page
        }
    }

    @inlinable
    mutating func mapOne(virt: UInt64, phys: UInt64, level: Int, _ attributes: MapAttributes) throws(MapError) {
        var table = virt >> 63 != 0 ? rootHigh : rootLow
        for walk in 0..<level {
            let slot = unsafe entries(table) + PageTableFormat.index(virt, level: walk)
            let entry = unsafe slot.pointee
            if PageTableFormat.isPresent(entry) {
                guard PageTableFormat.isTable(entry, level: walk) else { throw .overlap(virt) }
                table = PageTableFormat.address(entry)
            } else {
                guard let next = memory.allocateTable() else { throw .outOfMemory }
                unsafe slot.pointee = PageTableFormat.table(next)
                table = next
            }
        }
        let slot = unsafe entries(table) + PageTableFormat.index(virt, level: level)
        guard unsafe !PageTableFormat.isPresent(slot.pointee) else { throw .overlap(virt) }
        unsafe slot.pointee = PageTableFormat.leaf(phys, level: level, attributes)
    }

    @inlinable
    func entries(_ table: UInt64) -> UnsafeMutablePointer<UInt64> {
        unsafe UnsafeMutablePointer(bitPattern: memory.tableAddress(table))!
    }
}
