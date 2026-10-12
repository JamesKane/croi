import CKernel

/// ZX_INFO_KMEM_STATS (Todhchai's M3 memory budget's cross-check): where
/// the RAM the PMM manages is, from a scan of its page records and the
/// heap's counters. Racy by nature: a snapshot, not a ledger.
enum KernelMemory {
    static func stats() -> croi_info_kmem_stats_t {
        let page = KernelLayout.pageSize
        let counts = pmm.pageCounts()  // by PageState raw value
        let heapBytes = UInt64(heap.slabPages + heap.largePages) * page
        var k = croi_info_kmem_stats_t()
        k.total_bytes = pmm.totalPages * page
        k.free_bytes = counts[Int(PageState.free.rawValue)] * page
        k.free_loaned_bytes = counts[Int(PageState.freeLoaned.rawValue)] * page  // K14f
        k.wired_bytes = counts[Int(PageState.wired.rawValue)] * page
        k.total_heap_bytes = heapBytes
        k.free_heap_bytes = heapBytes > UInt64(heap.bytesInUse) ? heapBytes - UInt64(heap.bytesInUse) : 0
        k.vmo_bytes = counts[Int(PageState.vmo.rawValue)] * page
        k.mmu_overhead_bytes = counts[Int(PageState.mmu.rawValue)] * page
        k.other_bytes = counts[Int(PageState.alloc.rawValue)] * page
        Reclaim.fill(&k)  // K14a: reclaimable and discardable bytes
        return k
    }
}
