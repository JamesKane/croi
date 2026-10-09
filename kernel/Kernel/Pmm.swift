import CHandoff

/// What a physical page is being used for (after Zircon's vm_page_state;
/// the subset croi uses so far).
enum PageState: UInt8 {
    case free
    /// Allocated; the owner is not tracked.
    case alloc
    /// In use outside the allocator's control: the kernel image, boot-time
    /// allocations, loader handoff data, reserved low memory.
    case wired
    /// Page tables.
    case mmu
    /// Kernel heap (see Heap.swift for the heap* fields).
    case heap
    /// Owned by a VMO (Vm/Vmo.swift).
    case vmo
}

/// Per-page metadata, one for every 4 KiB page in every arena (Zircon's
/// vm_page_t). Lives in the arena's page array, reached via the physmap.
struct Page {
    /// List links: physmap addresses of the neighbouring `Page`s, 0 for
    /// none. The PMM's free list while free; the owner's lists otherwise
    /// (e.g. the heap's partial-slab lists).
    var next: UInt64 = 0
    var prev: UInt64 = 0
    /// The page this describes.
    private(set) var physical: UInt64 = 0
    fileprivate(set) var state = PageState.wired

    // Owned by the heap while `state == .heap` (fits in the record's padding).
    /// Slab size class, or `Heap.largeHead` / `Heap.largeTail`.
    var heapClass: UInt8 = 0
    /// Slab: objects allocated. Large head: pages in the allocation.
    var heapInUse: UInt16 = 0
    /// Slab: offset of the first free object, or `Heap.endOfList`.
    var heapFree: UInt16 = 0

    fileprivate init(physical: UInt64) {
        self.physical = physical
    }
}

/// A run of physically contiguous RAM the PMM manages.
struct Arena {
    var base: UInt64 = 0
    var pageCount: UInt64 = 0
    /// Physmap address of `Page[pageCount]`.
    fileprivate var pages: UInt64 = 0

    func contains(_ phys: UInt64) -> Bool { phys >= base && phys - base < pageCount * KernelLayout.pageSize }
}

/// The kernel's physical memory manager (Zircon's PmmNode, single node).
/// Every entry point that touches allocation state takes `pmmLock`.
nonisolated(unsafe) var pmm = Pmm()

/// Guards `pmm`'s free list and page states. Innermost lock (see SpinLock).
let pmmLock = SpinLock()

@safe struct Pmm {
    private var arenas = InlineArray<32, Arena>(repeating: Arena())
    private(set) var arenaCount = 0
    /// Physmap address of the first free `Page`, 0 if none.
    private var freeHead: UInt64 = 0
    private(set) var freePages: UInt64 = 0
    private(set) var totalPages: UInt64 = 0
    /// A page of free RAM below 1 MiB kept out of the free list, for the
    /// amd64 SMP trampoline (0 if there is none).
    private(set) var lowTrampolinePage: UInt64 = 0

    enum InitError: Error {
        case tooManyArenas
        case noMemoryForPageArray
    }

    /// Takes over from the boot allocator. Every page in the arenas starts
    /// wired; free RAM the boot allocator never handed out goes on the free
    /// list. The boot allocator must not be used afterwards.
    mutating func initialize(from boot: inout BootAllocator) throws(InitError) {
        try pmmLock.withLock { () throws(InitError) in try initializeLocked(from: &boot) }
    }

    private mutating func initializeLocked(from boot: inout BootAllocator) throws(InitError) {
        let pageSize = KernelLayout.pageSize

        // Arenas: maximal runs of contiguous RAM the kernel owns.
        var runStart: UInt64 = 0
        var runEnd: UInt64 = 0
        for i in 0..<boot.rangeCount {
            let r = boot.range(i)
            guard Self.isManaged(r.type) else { continue }
            if r.base == runEnd {
                runEnd = r.base + r.size
                continue
            }
            try addArena(runStart, runEnd, boot: &boot)
            runStart = r.base
            runEnd = r.base + r.size
        }
        try addArena(runStart, runEnd, boot: &boot)

        // Free what is really free. Pushed highest first, so allocation
        // starts from low addresses.
        for i in (0..<boot.rangeCount).reversed() {
            let r = boot.range(i)
            guard r.type == CROI_MEM_FREE else { continue }
            var phys = (r.base + r.size) & ~(pageSize - 1)
            let floor = max(r.base, BootAllocator.lowestUsable)
            // Remember a free page below BootAllocator.lowestUsable (never page 0).
            let lowStart = (max(r.base, pageSize) + pageSize - 1) & ~(pageSize - 1)
            if lowTrampolinePage == 0, lowStart < BootAllocator.lowestUsable,
               lowStart + pageSize <= min(r.base + r.size, BootAllocator.lowestUsable) {
                lowTrampolinePage = lowStart
            }
            while phys >= floor + pageSize {
                phys -= pageSize
                if !boot.isAllocated(phys), let page = unsafe page(for: phys) {
                    unsafe pushFree(page)
                }
            }
        }
    }

    private mutating func addArena(_ start: UInt64, _ end: UInt64, boot: inout BootAllocator) throws(InitError) {
        let pageSize = KernelLayout.pageSize
        let base = (start + pageSize - 1) & ~(pageSize - 1)
        let limit = end & ~(pageSize - 1)
        guard limit > base else { return }
        guard arenaCount < arenas.count else { throw .tooManyArenas }

        let count = (limit - base) / pageSize
        let arrayBytes = count * UInt64(MemoryLayout<Page>.stride)
        guard let array = boot.allocate(pages: (arrayBytes + pageSize - 1) / pageSize) else {
            throw .noMemoryForPageArray
        }
        let arena = Arena(base: base, pageCount: count, pages: KernelLayout.physmap(array))
        let pages = unsafe UnsafeMutablePointer<Page>(bitPattern: UInt(arena.pages))!
        for i in 0..<Int(count) {
            unsafe (pages + i).initialize(to: Page(physical: base + UInt64(i) * pageSize))
        }
        arenas[arenaCount] = arena
        arenaCount += 1
        totalPages += count
    }

    /// RAM the PMM tracks. Firmware runtime/NVS and persistent memory are
    /// never the kernel's to allocate, so they get no arena.
    private static func isManaged(_ type: UInt32) -> Bool {
        type == CROI_MEM_FREE || type == CROI_MEM_KERNEL || type == CROI_MEM_HANDOFF
            || type == CROI_MEM_ACPI_RECLAIM || type == CROI_MEM_BOOTFS
    }

    // MARK: Allocation

    /// One page, not zeroed. Returns its physical address.
    mutating func allocatePage(_ state: PageState = .alloc) -> UInt64? {
        pmmLock.withLock { allocatePageLocked(state) }
    }

    private mutating func allocatePageLocked(_ state: PageState) -> UInt64? {
        guard freeHead != 0 else { return nil }
        let page = unsafe pointer(freeHead)
        unsafe unlinkFree(page)
        unsafe page.pointee.state = state
        return unsafe page.pointee.physical
    }

    /// `count` physically contiguous pages whose base is aligned to
    /// 2^`alignLog2` bytes (at least page aligned). Not zeroed.
    mutating func allocateContiguous(_ count: UInt64, alignLog2: Int = 12, _ state: PageState = .alloc) -> UInt64? {
        pmmLock.withLock { allocateContiguousLocked(count, alignLog2: alignLog2, state) }
    }

    private mutating func allocateContiguousLocked(_ count: UInt64, alignLog2: Int, _ state: PageState) -> UInt64? {
        guard count > 0, alignLog2 < 64 else { return nil }
        let pageSize = KernelLayout.pageSize
        let alignment = max(UInt64(1) << alignLog2, pageSize)
        for a in 0..<arenaCount {
            let arena = arenas[a]
            var phys = (arena.base + alignment - 1) & ~(alignment - 1)
            while arena.contains(phys), arena.pageCount - (phys - arena.base) / pageSize >= count {
                let first = (phys - arena.base) / pageSize
                var run: UInt64 = 0
                while run < count, unsafe page(arena, first + run).pointee.state == .free {
                    run += 1
                }
                if run == count {
                    for i in 0..<count {
                        let page = unsafe page(arena, first + i)
                        unsafe unlinkFree(page)
                        unsafe page.pointee.state = state
                    }
                    return phys
                }
                // Skip past the page that broke the run, to the next aligned base.
                let blocker = arena.base + (first + run) * pageSize
                phys = (blocker + pageSize + alignment - 1) & ~(alignment - 1)
            }
        }
        return nil
    }

    /// Returns a page to the free list. Freeing a page that isn't allocated
    /// (double free, or not RAM the PMM manages) panics.
    mutating func free(_ phys: UInt64) {
        pmmLock.withLock { freeLocked(phys) }
    }

    mutating func free(_ phys: UInt64, count: UInt64) {
        pmmLock.withLock {
            for i in 0..<count {
                freeLocked(phys + i * KernelLayout.pageSize)
            }
        }
    }

    private mutating func freeLocked(_ phys: UInt64) {
        guard let page = unsafe page(for: phys) else { panic("pmm: freeing a page outside every arena") }
        guard unsafe page.pointee.state != .free else { panic("pmm: double free") }
        unsafe pushFree(page)
    }

    /// Frees the loader's handoff memory (its range table and boot page
    /// tables), like Zircon's pmm_end_handoff. Reads the range table while
    /// freeing it, which is fine: freeing only touches Page records. After
    /// this, nothing may read the handoff.
    mutating func endHandoff(_ boot: BootAllocator) -> UInt64 {
        pmmLock.withLock { endHandoffLocked(boot) }
    }

    private mutating func endHandoffLocked(_ boot: BootAllocator) -> UInt64 {
        var freed: UInt64 = 0
        for i in 0..<boot.rangeCount {
            let r = boot.range(i)
            guard r.type == CROI_MEM_HANDOFF else { continue }
            var phys = r.base
            while phys < r.base + r.size {
                if let page = unsafe page(for: phys), unsafe page.pointee.state == .wired {
                    unsafe pushFree(page)
                    freed += 1
                }
                phys += KernelLayout.pageSize
            }
        }
        return freed
    }

    // MARK: Lookup

    /// The `Page` describing physical address `phys`, if the PMM manages it.
    func page(for phys: UInt64) -> UnsafeMutablePointer<Page>? {
        for a in 0..<arenaCount where arenas[a].contains(phys) {
            return unsafe page(arenas[a], (phys - arenas[a].base) / KernelLayout.pageSize)
        }
        return nil
    }

    func state(of phys: UInt64) -> PageState? {
        pmmLock.withLock { unsafe page(for: phys)?.pointee.state }
    }

    func arena(_ i: Int) -> Arena { arenas[i] }

    // MARK: Free list

    private func page(_ arena: Arena, _ index: UInt64) -> UnsafeMutablePointer<Page> {
        unsafe UnsafeMutablePointer<Page>(bitPattern: UInt(arena.pages))! + Int(index)
    }

    private func pointer(_ address: UInt64) -> UnsafeMutablePointer<Page> {
        unsafe UnsafeMutablePointer<Page>(bitPattern: UInt(address))!
    }

    private func address(_ page: UnsafeMutablePointer<Page>) -> UInt64 {
        UInt64(UInt(bitPattern: page))
    }

    @unsafe private mutating func pushFree(_ page: UnsafeMutablePointer<Page>) {
        unsafe page.pointee.state = .free
        unsafe page.pointee.prev = 0
        unsafe page.pointee.next = freeHead
        if freeHead != 0 {
            unsafe pointer(freeHead).pointee.prev = address(page)
        }
        freeHead = unsafe address(page)
        freePages += 1
    }

    @unsafe private mutating func unlinkFree(_ page: UnsafeMutablePointer<Page>) {
        let next = unsafe page.pointee.next
        let prev = unsafe page.pointee.prev
        if prev != 0 {
            unsafe pointer(prev).pointee.next = next
        } else {
            freeHead = next
        }
        if next != 0 {
            unsafe pointer(next).pointee.prev = prev
        }
        unsafe page.pointee.next = 0
        unsafe page.pointee.prev = 0
        freePages -= 1
    }
}
