import CHandoff
import PageTables

/// Hands out zeroed physical pages from free RAM, front to back, until the
/// PMM exists. Pages are never freed: within each free range, everything
/// below the allocator's cursor stays in use.
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

    #if arch(x86_64)
    /// Keep the first MiB for real-mode trampolines (SMP bring-up).
    private static var lowestUsable: UInt64 { 0x10_0000 }
    #else
    private static var lowestUsable: UInt64 { KernelLayout.pageSize }
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

    mutating func allocatePage() -> UInt64? {
        let pageSize = KernelLayout.pageSize
        while index < count {
            let r = range(index)
            if r.type == CROI_MEM_FREE {
                let start = max(r.base, Self.lowestUsable)
                let page = (max(cursor, start) + pageSize - 1) & ~(pageSize - 1)
                if page < r.base + r.size, r.base + r.size - page >= pageSize {
                    cursor = page + pageSize
                    pagesAllocated += 1
                    unsafe UnsafeMutableRawPointer(bitPattern: UInt(page + accessOffset))!
                        .initializeMemory(as: UInt8.self, repeating: 0, count: Int(pageSize))
                    return page
                }
            }
            index += 1
            cursor = 0
        }
        return nil
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
