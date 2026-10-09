import CKernel
import PageTables

enum VmError: Error, Equatable {
    case unaligned(UInt64)
    case alreadyMapped(UInt64)
    case outOfMemory
    /// The range isn't in this address space (or crosses halves).
    case outOfRange(UInt64)
    /// No free virtual range big enough.
    case noSpace
    /// No region starts at this address.
    case notFound(UInt64)
    /// Bad size, offset or rights for the object.
    case invalidArgument
    /// The physical range is RAM or firmware memory (the deny list).
    case denied(UInt64)
}

/// What a virtual address translates to.
struct Translation: Equatable {
    var physical: UInt64
    var attributes: MapAttributes
    /// Size of the page or block that maps it.
    var pageSize: UInt64
}

/// One address space's page tables and the operations of Zircon's
/// ArchVmAspace: map, unmap, protect, query.
///
/// Tables come from the PMM (state `.mmu`) and are reached through the
/// physmap; tables emptied by unmap go back to the PMM (never the roots).
/// Every entry change is followed by TLB invalidation for its address
/// (broadcast on arm64); on amd64/rv64 each operation ends with a
/// TlbShootdown of its range on the other CPUs.
/// Not locked: the owning address space serializes calls.
///
/// Splitting a large page is break-before-make on arm64, so a split must
/// not cover memory in use while it happens (e.g. the page tables
/// themselves): don't split the physmap.
struct ArchAspace {
    let rootLow: UInt64
    let rootHigh: UInt64
    /// Never free the tables the root points at (the kernel's on amd64/
    /// rv64: user roots copy those entries, so they must never change).
    var pinsTopLevel = false

    init(rootLow: UInt64, rootHigh: UInt64) {
        self.rootLow = rootLow
        self.rootHigh = rootHigh
    }

    private typealias Format = PageTableFormat
    private static var entriesPerTable: Int { 512 }
    private static var lastLevel: Int { Format.levels - 1 }
    private static var smallPage: UInt64 { Format.pageSize(level: Format.levels - 1) }

    // MARK: Map

    /// Maps [virt, virt+size) to [phys, phys+size) with the largest pages
    /// that fit. Anything already mapped in the range is an error (nothing
    /// is changed for the overlapping page; earlier pages stay mapped).
    func map(virt: UInt64, phys: UInt64, size: UInt64, _ attributes: MapAttributes) throws(VmError) {
        try checkRange(virt, size)
        guard phys % Self.smallPage == 0 else { throw .unaligned(phys) }
        var virt = virt, phys = phys, left = size
        while left > 0 {
            var level = Self.lastLevel
            for candidate in 0..<Format.levels where Format.leafAllowed(level: candidate) {
                let page = Format.pageSize(level: candidate)
                if virt % page == 0, phys % page == 0, left >= page {
                    level = candidate
                    break
                }
            }
            try mapOne(virt: virt, phys: phys, level: level, attributes)
            let page = Format.pageSize(level: level)
            virt &+= page
            phys += page
            left -= page
        }
        TlbShootdown.flushOthers(virt &- size, size)
    }

    private func mapOne(virt: UInt64, phys: UInt64, level: Int, _ attributes: MapAttributes) throws(VmError) {
        var table = root(virt)
        for walk in 0..<level {
            let slot = unsafe entries(table) + Format.index(virt, level: walk)
            let entry = unsafe slot.pointee
            if Format.isPresent(entry) {
                guard Format.isTable(entry, level: walk) else { throw .alreadyMapped(virt) }
                table = Format.address(entry)
            } else {
                let next = try allocateTable()
                unsafe slot.pointee = Format.table(next)
                table = next
            }
        }
        let slot = unsafe entries(table) + Format.index(virt, level: level)
        guard unsafe !Format.isPresent(slot.pointee) else { throw .alreadyMapped(virt) }
        unsafe slot.pointee = Format.leaf(phys, level: level, attributes)
        // Not strictly needed for not-present -> present everywhere, but RISC-V
        // without Svvptc may otherwise see the new entry late.
        arch_tlb_invalidate_page(virt)
    }

    // MARK: Unmap / protect

    /// Unmaps everything in [virt, virt+size), splitting large pages that
    /// are only partly covered. Holes are fine.
    func unmap(virt: UInt64, size: UInt64) throws(VmError) {
        try checkRange(virt, size)
        defer { TlbShootdown.flushOthers(virt, size) }
        try update(table: root(virt), level: 0, start: virt, end: virt + size, .unmap)
    }

    /// Changes the attributes of everything mapped in [virt, virt+size),
    /// splitting large pages that are only partly covered. Holes are skipped.
    func protect(virt: UInt64, size: UInt64, _ attributes: MapAttributes) throws(VmError) {
        try checkRange(virt, size)
        defer { TlbShootdown.flushOthers(virt, size) }
        try update(table: root(virt), level: 0, start: virt, end: virt + size, .protect(attributes))
    }

    private enum Operation {
        case unmap
        case protect(MapAttributes)
    }

    /// Applies `operation` to [start, end) within `table` (a table at `level`).
    private func update(table: UInt64, level: Int, start: UInt64, end: UInt64, _ operation: Operation) throws(VmError) {
        let size = Format.pageSize(level: level)
        var virt = start
        while virt < end {
            let entryBase = virt & ~(size - 1)
            let entryEnd = entryBase &+ size  // 0 at the very top of the address space
            let chunkEnd = (entryEnd == 0 || entryEnd > end) ? end : entryEnd
            let slot = unsafe entries(table) + Format.index(virt, level: level)
            let entry = unsafe slot.pointee

            if Format.isTable(entry, level: level) {
                let child = Format.address(entry)
                try update(table: child, level: level + 1, start: virt, end: chunkEnd, operation)
                if case .unmap = operation, !(level == 0 && pinsTopLevel), unsafe isEmpty(child) {
                    unsafe slot.pointee = 0
                    arch_tlb_invalidate_page(entryBase)  // drops walk-cache entries too
                    pmm.free(child)
                }
            } else if Format.isPresent(entry) {
                if virt == entryBase, chunkEnd &- entryBase == size {
                    switch operation {
                    case .unmap:
                        unsafe slot.pointee = 0
                        arch_tlb_invalidate_page(entryBase)
                    case .protect(let attributes):
                        let old = Format.attributes(entry, level: level)
                        let new = Format.leaf(Format.leafAddress(entry, level: level), level: level, attributes)
                        unsafe replace(slot, with: new, at: entryBase, breakFirst: old.cache != attributes.cache)
                    }
                } else {
                    let child = unsafe try split(slot, level: level, at: entryBase)
                    try update(table: child, level: level + 1, start: virt, end: chunkEnd, operation)
                }
            }
            virt = chunkEnd
        }
    }

    /// Replaces the large leaf in `slot` with a table of next-level leaves
    /// mapping the same memory with the same attributes. Returns the table.
    @unsafe private func split(_ slot: UnsafeMutablePointer<UInt64>, level: Int, at base: UInt64) throws(VmError) -> UInt64 {
        let entry = unsafe slot.pointee
        let attributes = Format.attributes(entry, level: level)
        let physical = Format.leafAddress(entry, level: level)
        let childSize = Format.pageSize(level: level + 1)
        let child = try allocateTable()
        let childEntries = unsafe entries(child)
        for i in 0..<Self.entriesPerTable {
            unsafe childEntries[i] = Format.leaf(physical + UInt64(i) * childSize, level: level + 1, attributes)
        }
        // A change of block size: break-before-make on arm64.
        unsafe replace(slot, with: Format.table(child), at: base, breakFirst: true)
        return child
    }

    /// Writes a new value over a valid entry. Arm requires break-before-make
    /// (invalid, TLBI, new) when output address, memory type or block size
    /// change; permission-only changes may be made in place.
    @unsafe private func replace(_ slot: UnsafeMutablePointer<UInt64>, with entry: UInt64, at virt: UInt64, breakFirst: Bool) {
        #if arch(arm64)
        if breakFirst {
            unsafe slot.pointee = 0
            arch_tlb_invalidate_page(virt)
        }
        #endif
        unsafe slot.pointee = entry
        arch_tlb_invalidate_page(virt)
    }

    // MARK: Query

    /// What `virt` translates to, if it is mapped.
    func query(_ virt: UInt64) -> Translation? {
        var table = root(virt)
        for level in 0..<Format.levels {
            let entry = unsafe entries(table)[Format.index(virt, level: level)]
            guard Format.isPresent(entry) else { return nil }
            if Format.isTable(entry, level: level) {
                table = Format.address(entry)
                continue
            }
            let size = Format.pageSize(level: level)
            return Translation(physical: Format.leafAddress(entry, level: level) + (virt & (size - 1)),
                               attributes: Format.attributes(entry, level: level), pageSize: size)
        }
        return nil
    }

    // MARK: User address spaces

    /// Top-level slots of the kernel half, in the root that holds it.
    static var kernelHalf: Range<Int> { 256..<512 }

    /// Gives every kernel-half top-level slot a table, once, so that user
    /// roots can copy the kernel half and stay current (amd64, rv64; on
    /// arm64 the kernel half is TTBR1's and nothing is copied).
    mutating func populateKernelHalf() throws(VmError) {
        #if arch(x86_64) || arch(riscv64)
        let slots = unsafe entries(rootHigh)
        for i in Self.kernelHalf where unsafe slots[i] == 0 {
            unsafe slots[i] = Format.table(try allocateTable())
        }
        #endif
        pinsTopLevel = true
    }

    /// A new user address space's tables: an empty user half, sharing the
    /// kernel half of `kernel` (amd64/rv64: a root of its own whose kernel
    /// slots copy the kernel's; arm64: a TTBR0 root).
    static func makeUser(sharing kernel: borrowing ArchAspace) throws(VmError) -> ArchAspace {
        guard let root = pmm.allocatePage(.mmu) else { throw .outOfMemory }
        let slots = unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(root)))!
        unsafe UnsafeMutableRawPointer(slots).initializeMemory(as: UInt8.self, repeating: 0, count: Int(KernelLayout.pageSize))
        #if arch(x86_64) || arch(riscv64)
        let kernelSlots = unsafe UnsafePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(kernel.rootHigh)))!
        for i in kernelHalf { unsafe slots[i] = kernelSlots[i] }
        return ArchAspace(rootLow: root, rootHigh: root)
        #else
        return ArchAspace(rootLow: root, rootHigh: kernel.rootHigh)
        #endif
    }

    /// Frees a user address space's tables: everything below the user half
    /// of the root, then the root (the pages they map are their owners').
    /// Nothing may be using it.
    func destroyUser() {
        let slots = unsafe entries(rootLow)
        for i in 0..<Self.kernelHalf.lowerBound where Format.isTable(unsafe slots[i], level: 0) {
            freeTables(Format.address(unsafe slots[i]), level: 1)
        }
        pmm.free(rootLow)
    }

    private func freeTables(_ table: UInt64, level: Int) {
        let slots = unsafe entries(table)
        for i in 0..<Self.entriesPerTable where Format.isTable(unsafe slots[i], level: level) {
            freeTables(Format.address(unsafe slots[i]), level: level + 1)
        }
        pmm.free(table)
    }

    // MARK: Helpers

    private func root(_ virt: UInt64) -> UInt64 { virt >> 63 != 0 ? rootHigh : rootLow }

    /// Page aligned, non-empty, no wrap, within one half (one root on arm64).
    private func checkRange(_ virt: UInt64, _ size: UInt64) throws(VmError) {
        guard virt % Self.smallPage == 0, size % Self.smallPage == 0, size > 0 else { throw .unaligned(virt) }
        let (last, overflow) = virt.addingReportingOverflow(size - 1)
        guard !overflow, virt >> 63 == last >> 63 else { throw .outOfRange(virt) }
    }

    private func allocateTable() throws(VmError) -> UInt64 {
        guard let phys = pmm.allocatePage(.mmu) else { throw .outOfMemory }
        unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(phys)))!
            .initializeMemory(as: UInt8.self, repeating: 0, count: Int(KernelLayout.pageSize))
        return phys
    }

    private func entries(_ table: UInt64) -> UnsafeMutablePointer<UInt64> {
        unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(table)))!
    }

    @unsafe private func isEmpty(_ table: UInt64) -> Bool {
        let e = unsafe entries(table)
        for i in 0..<Self.entriesPerTable where unsafe e[i] != 0 {
            return false
        }
        return true
    }
}
