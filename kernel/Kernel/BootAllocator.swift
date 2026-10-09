import CHandoff
import PageTables

/// Hands out zeroed physical pages from free RAM, front to back, until the
/// PMM exists. Nothing is ever freed; instead it records exactly which
/// spans it handed out, so the PMM can mark them in use when it takes over.
///
/// Reads the loader's range table in place. That is safe because the table
/// lives in CROI_MEM_HANDOFF memory, which this allocator never hands out.
struct BootAllocator {
    private let ranges: UInt64
    private let count: Int
    /// Virtual = physical + this. 0 while on the loader's identity map,
    /// the physmap base after switching to the kernel page tables.
    private(set) var accessOffset: UInt64 = 0
    private var index = 0
    private var cursor: UInt64 = 0
    private(set) var pagesAllocated: UInt64 = 0

    /// Allocated [start, end) spans, merged when contiguous.
    private var spans = InlineArray<16, (start: UInt64, end: UInt64)>(repeating: (0, 0))
    private var spanCount = 0

    #if arch(x86_64)
    /// Keep the first MiB for real-mode trampolines (SMP bring-up).
    static var lowestUsable: UInt64 { 0x10_0000 }
    #else
    static var lowestUsable: UInt64 { KernelLayout.pageSize }
    #endif

    init(_ handoff: croi_handoff_t) {
        ranges = handoff.memory_map
        count = Int(handoff.memory_map_count)
    }

    /// The range table entry `i`, through the current mapping.
    func range(_ i: Int) -> croi_mem_range_t {
        unsafe UnsafePointer<croi_mem_range_t>(bitPattern: UInt(ranges + accessOffset))![i]
    }

    var rangeCount: Int { count }

    mutating func allocatePage() -> UInt64? { allocate(pages: 1) }

    /// `pages` physically contiguous, zeroed pages, or nil.
    mutating func allocate(pages: UInt64) -> UInt64? {
        let pageSize = KernelLayout.pageSize
        let bytes = pages * pageSize
        while index < count {
            let r = range(index)
            if r.type == CROI_MEM_FREE {
                let start = (max(cursor, r.base, Self.lowestUsable) + pageSize - 1) & ~(pageSize - 1)
                let end = r.base + r.size
                if start < end, end - start >= bytes, record(start, start + bytes) {
                    cursor = start + bytes
                    pagesAllocated += pages
                    unsafe UnsafeMutableRawPointer(bitPattern: UInt(start + accessOffset))!
                        .initializeMemory(as: UInt8.self, repeating: 0, count: Int(bytes))
                    return start
                }
            }
            index += 1
            cursor = 0
        }
        return nil
    }

    /// Whether the page at `phys` was handed out.
    func isAllocated(_ phys: UInt64) -> Bool {
        for i in 0..<spanCount where phys >= spans[i].start && phys < spans[i].end {
            return true
        }
        return false
    }

    private mutating func record(_ start: UInt64, _ end: UInt64) -> Bool {
        if spanCount > 0, spans[spanCount - 1].end == start {
            spans[spanCount - 1].end = end
            return true
        }
        guard spanCount < spans.count else { return false }
        spans[spanCount] = (start, end)
        spanCount += 1
        return true
    }

    /// Call right after switching to the kernel page tables.
    mutating func useKernelMappings() {
        accessOffset = KernelLayout.physmapBase
    }
}

extension BootAllocator: PageTableMemory {
    mutating func allocateTable() -> UInt64? { allocatePage() }
    func tableAddress(_ phys: UInt64) -> UInt { UInt(phys + accessOffset) }
}
