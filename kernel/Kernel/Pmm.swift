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
    /// K14f: lent by its lender (a contiguous VMO or the contiguous pool)
    /// and free: on the PMM's loaned list, which only `allocateLoaned`
    /// hands out (Zircon's FREE_LOANED).
    case freeLoaned
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
    /// K14a, a VMO page of a reclaimable VMO (Vm/Reclaim.swift): aging
    /// passes since its last access (saturating), and the ALWAYS_NEED /
    /// DONT_NEED hints. Reset when the page is allocated.
    var reclaimAge: UInt8 = 0
    var reclaimFlags: UInt8 = 0

    fileprivate init(physical: UInt64) {
        self.physical = physical
    }

    /// K14f, in `reclaimFlags`: lent (free or borrowed), and its lender
    /// wants it back. While borrowed, `next` is the borrower's VmoRecord
    /// and `prev` the page's index there (VMO pages use no links), 0 while
    /// in transit.
    static var loaned: UInt8 { 0x80 }
    static var loanCancelled: UInt8 { 0x40 }
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

/// Lookups on the global `pmm` are `mutating` although they change nothing:
/// a non-mutating method got a copy of the whole struct (850 bytes, `rep
/// movsb`, ~150 ns per `page(for:)`, most of a heap free and so of each
/// channel call), and indexing `arenas` there copied the array again per
/// arena; a mutating one gets the global's address (K14l).
@safe struct Pmm: ~Copyable {
    private var arenas = InlineArray<32, Arena>(repeating: Arena())
    private(set) var arenaCount = 0
    /// Physmap address of the first free `Page`, 0 if none.
    private var freeHead: UInt64 = 0
    private(set) var freePages: UInt64 = 0
    /// K14f: the free lent pages, and every lent page (free or borrowed).
    private var loanedHead: UInt64 = 0
    private(set) var freeLoanedPages: UInt64 = 0
    private(set) var loanedPages: UInt64 = 0
    private(set) var totalPages: UInt64 = 0
    /// A page of free RAM below 1 MiB kept out of the free list, for the
    /// amd64 SMP trampoline (0 if there is none).
    private(set) var lowTrampolinePage: UInt64 = 0
    /// K14a: the free-page band the memory watchdog last evaluated; the
    /// first allocation or free leaving it tells the watchdog
    /// (`Reclaim.freeMemoryChanged`) and opens the band until it is set
    /// again. A single page allocation failing does too (Zircon's
    /// trigger-on-alloc-failure).
    private var signalLow: UInt64 = 0
    private var signalHigh = UInt64.max
    private var watching = false
    private(set) var singleAllocationFailed = false

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
        PhysicalMap.record(boot)

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
    /// never the kernel's to allocate, so they get no arena; nor do the
    /// ACPI tables (reclaim), which user space reads for good (K9b).
    private static func isManaged(_ type: UInt32) -> Bool {
        type == CROI_MEM_FREE || type == CROI_MEM_KERNEL || type == CROI_MEM_HANDOFF || type == CROI_MEM_BOOTFS
    }

    // MARK: Allocation

    /// One page, not zeroed. Returns its physical address.
    mutating func allocatePage(_ state: PageState = .alloc) -> UInt64? {
        var crossed = false
        let phys = pmmLock.withLock { () -> UInt64? in
            let phys = allocatePageLocked(state)
            if phys == nil, watching { singleAllocationFailed = true }
            crossed = leftBandLocked(failed: phys == nil)
            return phys
        }
        if crossed { Reclaim.freeMemoryChanged() }
        return phys
    }

    private mutating func allocatePageLocked(_ state: PageState) -> UInt64? {
        guard freeHead != 0 else { return nil }
        let page = unsafe pointer(freeHead)
        unsafe unlinkFree(page)
        unsafe page.pointee.state = state
        unsafe page.pointee.reclaimAge = 0
        unsafe page.pointee.reclaimFlags = 0
        return unsafe page.pointee.physical
    }

    /// Whether the free count just left the watchdog's band (closing it).
    private mutating func leftBandLocked(failed: Bool = false) -> Bool {
        // An open band: the watchdog has been told and hasn't looked yet.
        guard watching, signalLow != 0 || signalHigh != .max else { return false }
        guard failed || freePages < signalLow || freePages > signalHigh else { return false }
        signalLow = 0
        signalHigh = .max
        return true
    }

    /// K14a: asks to hear when the free page count leaves [low, high].
    /// False, setting nothing, if it is outside already (or a single page
    /// allocation failed since `clearAllocationFailure`).
    mutating func setFreeMemorySignal(low: UInt64, high: UInt64) -> Bool {
        pmmLock.withLock { () -> Bool in
            watching = true
            guard !singleAllocationFailed, freePages >= low, freePages <= high else { return false }
            signalLow = low
            signalHigh = high
            return true
        }
    }

    mutating func clearAllocationFailure() {
        pmmLock.withLock { singleAllocationFailed = false }
    }

    /// `count` physically contiguous pages whose base is aligned to
    /// 2^`alignLog2` bytes (at least page aligned), ending at or below
    /// `limit` (e.g. 4 GiB for a 32-bit DMA engine). Not zeroed.
    mutating func allocateContiguous(_ count: UInt64, alignLog2: Int = 12, _ state: PageState = .alloc,
                                     floor: UInt64 = 0, limit: UInt64 = .max) -> UInt64? {
        var crossed = false
        let phys = pmmLock.withLock { () -> UInt64? in
            let phys = allocateContiguousLocked(count, alignLog2: alignLog2, state, floor: floor, limit: limit)
            crossed = leftBandLocked()
            return phys
        }
        if crossed { Reclaim.freeMemoryChanged() }
        return phys
    }

    private mutating func allocateContiguousLocked(_ count: UInt64, alignLog2: Int, _ state: PageState,
                                                   floor: UInt64, limit: UInt64) -> UInt64? {
        guard count > 0, alignLog2 < 64 else { return nil }
        let pageSize = KernelLayout.pageSize
        let alignment = max(UInt64(1) << alignLog2, pageSize)
        for a in 0..<arenaCount {
            let arena = arenas[a]
            var phys = (max(arena.base, floor) + alignment - 1) & ~(alignment - 1)
            while arena.contains(phys), arena.pageCount - (phys - arena.base) / pageSize >= count,
                  count <= limit / pageSize, phys <= limit - count * pageSize {
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
                        unsafe page.pointee.reclaimAge = 0
                        unsafe page.pointee.reclaimFlags = 0
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

    /// Pages in each PageState (indexed by raw value), by a scan of every
    /// arena (ZX_INFO_KMEM_STATS; not a hot path).
    func pageCounts() -> InlineArray<7, UInt64> {
        pmmLock.withLock { () -> InlineArray<7, UInt64> in
            var counts = InlineArray<7, UInt64>(repeating: 0)
            for a in 0..<arenaCount {
                for i in 0..<arenas[a].pageCount {
                    let state = Int(unsafe page(arenas[a], i).pointee.state.rawValue)
                    if state < 7 { counts[state] += 1 }
                }
            }
            return counts
        }
    }

    /// Returns a page to the free list. Freeing a page that isn't allocated
    /// (double free, or not RAM the PMM manages) panics.
    mutating func free(_ phys: UInt64) {
        let crossed = pmmLock.withLock { () -> Bool in
            freeLocked(phys)
            return leftBandLocked()
        }
        if crossed { Reclaim.freeMemoryChanged() }
    }

    mutating func free(_ phys: UInt64, count: UInt64) {
        let crossed = pmmLock.withLock { () -> Bool in
            for i in 0..<count {
                freeLocked(phys + i * KernelLayout.pageSize)
            }
            return leftBandLocked()
        }
        if crossed { Reclaim.freeMemoryChanged() }
    }

    private mutating func freeLocked(_ phys: UInt64) {
        guard let page = unsafe page(for: phys) else { panic("pmm: freeing a page outside every arena") }
        guard unsafe page.pointee.state != .free, unsafe page.pointee.state != .freeLoaned else {
            panic("pmm: double free")
        }
        // A borrowed page goes back to the loaned list, or to its lender if
        // it asked for it meanwhile (K14f).
        if unsafe page.pointee.reclaimFlags & Page.loaned != 0 {
            unsafe page.pointee.next = 0
            unsafe page.pointee.prev = 0
            if unsafe page.pointee.reclaimFlags & Page.loanCancelled != 0 {
                unsafe returnToLender(page)
            } else {
                unsafe pushLoaned(page)
            }
            return
        }
        unsafe pushFree(page)
    }

    // MARK: Loaning (K14f)

    /// Lends `count` pages at `phys`, its lender's (state .vmo: a
    /// contiguous VMO's or the pool's), to the rest of the system: free on
    /// the loaned list until `unloan` takes each back.
    mutating func lend(_ phys: UInt64, count: UInt64) {
        pmmLock.withLock {
            for i in 0..<count {
                guard let page = unsafe page(for: phys + i * KernelLayout.pageSize),
                      unsafe page.pointee.state == .vmo, unsafe page.pointee.reclaimFlags & Page.loaned == 0 else {
                    panic("pmm: lending a page its lender doesn't hold")
                }
                unsafe page.pointee.reclaimFlags = Page.loaned
                unsafe page.pointee.next = 0
                unsafe page.pointee.prev = 0
                unsafe pushLoaned(page)
                loanedPages += 1
            }
        }
    }

    /// One step of taking a lent page back for its lender: `.back` (it is
    /// the lender's again, state .vmo), `.evict` (borrowed: the borrower,
    /// retained here by `retain` while its backlink is still good, must
    /// let go of it, whose free then returns it), or `.wait` (in transit
    /// between a borrower and the PMM, or the borrower is going: ask again
    /// shortly).
    enum Unloan: Equatable {
        case back
        case evict(vmo: UInt64, index: UInt64)
        case wait
    }

    mutating func unloan(_ phys: UInt64, retaining retain: (UInt64) -> Bool) -> Unloan {
        pmmLock.withLock { () -> Unloan in
            guard let page = unsafe page(for: phys) else { panic("pmm: unloaning a page outside every arena") }
            guard unsafe page.pointee.reclaimFlags & Page.loaned != 0 else { return .back }
            if unsafe page.pointee.state == .freeLoaned {
                unsafe unlinkLoaned(page)
                unsafe returnToLender(page)
                return .back
            }
            unsafe page.pointee.reclaimFlags |= Page.loanCancelled
            // A backlink means the page is still in that VMO, whose release
            // frees its pages (taking this lock) before its record goes.
            let vmo = unsafe page.pointee.next
            guard vmo != 0, retain(vmo) else { return .wait }
            return .evict(vmo: vmo, index: unsafe page.pointee.prev)
        }
    }

    /// A free lent page for page `index` of the VmoRecord at `vmo` (a
    /// borrower: its page must stay replaceable), which it must install
    /// before dropping its lock; nil if none is free.
    mutating func allocateLoaned(for vmo: UInt64, index: UInt64) -> UInt64? {
        pmmLock.withLock { () -> UInt64? in
            guard loanedHead != 0 else { return nil }
            let page = unsafe pointer(loanedHead)
            unsafe unlinkLoaned(page)
            unsafe page.pointee.state = .vmo
            unsafe page.pointee.reclaimAge = 0
            unsafe page.pointee.next = vmo
            unsafe page.pointee.prev = index
            return unsafe page.pointee.physical
        }
    }

    /// A page swapped for another keeps its place in reclamation: the old
    /// one's age and hints (K14a), the new one's loan bits.
    mutating func copyReclaimState(from old: UInt64, to new: UInt64) {
        guard let from = unsafe page(for: old), let to = unsafe page(for: new) else { return }
        let loan = Page.loaned | Page.loanCancelled
        unsafe to.pointee.reclaimAge = from.pointee.reclaimAge
        unsafe to.pointee.reclaimFlags = (to.pointee.reclaimFlags & loan) | (from.pointee.reclaimFlags & ~loan)
    }

    /// Whether `phys` is a lent page (a borrower asks about its own pages,
    /// under its lock: the bit doesn't change while it holds the page).
    mutating func isLoaned(_ phys: UInt64) -> Bool {
        guard let page = unsafe page(for: phys) else { return false }
        return unsafe page.pointee.reclaimFlags & Page.loaned != 0
    }

    @unsafe private mutating func returnToLender(_ page: UnsafeMutablePointer<Page>) {
        unsafe page.pointee.state = .vmo
        unsafe page.pointee.reclaimFlags = 0
        unsafe page.pointee.reclaimAge = 0
        loanedPages -= 1
    }

    @unsafe private mutating func pushLoaned(_ page: UnsafeMutablePointer<Page>) {
        unsafe page.pointee.state = .freeLoaned
        unsafe page.pointee.prev = 0
        unsafe page.pointee.next = loanedHead
        if loanedHead != 0 { unsafe pointer(loanedHead).pointee.prev = address(page) }
        loanedHead = unsafe address(page)
        freeLoanedPages += 1
    }

    @unsafe private mutating func unlinkLoaned(_ page: UnsafeMutablePointer<Page>) {
        let next = unsafe page.pointee.next, prev = unsafe page.pointee.prev
        if prev != 0 { unsafe pointer(prev).pointee.next = next } else { loanedHead = next }
        if next != 0 { unsafe pointer(next).pointee.prev = prev }
        unsafe page.pointee.next = 0
        unsafe page.pointee.prev = 0
        freeLoanedPages -= 1
    }

    /// Hands `count` wired pages at `phys` (memory the loader filled, e.g.
    /// bootfs) to a VMO: false, changing nothing, unless every one is a
    /// wired page in an arena. The VMO frees them like its own.
    mutating func adopt(_ phys: UInt64, count: UInt64) -> Bool {
        pmmLock.withLock { () -> Bool in
            for i in 0..<count {
                guard let page = unsafe page(for: phys + i * KernelLayout.pageSize),
                      unsafe page.pointee.state == .wired else { return false }
            }
            for i in 0..<count {
                unsafe page(for: phys + i * KernelLayout.pageSize)!.pointee.state = .vmo
            }
            return true
        }
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
    mutating func page(for phys: UInt64) -> UnsafeMutablePointer<Page>? {
        for a in 0..<arenaCount where arenas[a].contains(phys) {
            return unsafe page(arenas[a], (phys - arenas[a].base) / KernelLayout.pageSize)
        }
        return nil
    }

    mutating func state(of phys: UInt64) -> PageState? {
        pmmLock.withLock { unsafe page(for: phys)?.pointee.state }
    }

    mutating func arena(_ i: Int) -> Arena { arenas[i] }

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

/// Physical ranges physical VMOs may never cover (Todhchai's RAM deny
/// list; Zircon's root filter): RAM the kernel owns or may reuse, and
/// persistent or unusable memory, kept after the handoff is gone.
/// Firmware's memory the physmap maps cached (ACPI tables and NVS, UEFI
/// runtime: K9b) is allowed but only cached, so no mapping disagrees with
/// the physmap's. MMIO, the framebuffer, RESERVED ranges (firmware's
/// "never touch": PCIe ECAM, flash; the kernel doesn't) and holes are
/// allowed with any memory type.
enum PhysicalMap {
    nonisolated(unsafe) private static var denied = InlineArray<64, (UInt64, UInt64)>(repeating: (0, 0))
    nonisolated(unsafe) private(set) static var deniedCount = 0
    nonisolated(unsafe) private static var firmware = InlineArray<64, (UInt64, UInt64)>(repeating: (0, 0))
    nonisolated(unsafe) private(set) static var firmwareCount = 0
    /// The end of the highest range of any type.
    nonisolated(unsafe) private(set) static var highestEnd: UInt64 = 0

    static func record(_ boot: borrowing BootAllocator) {
        for i in 0..<boot.rangeCount {
            let r = boot.range(i)
            highestEnd = max(highestEnd, r.base + r.size)
            guard r.size > 0 else { continue }
            switch r.type {
            case CROI_MEM_MMIO, CROI_MEM_FRAMEBUFFER, CROI_MEM_RESERVED:
                continue
            case CROI_MEM_ACPI_RECLAIM, CROI_MEM_ACPI_NVS, CROI_MEM_FIRMWARE_RUNTIME:
                // Too many to list: deny the rest rather than allow it uncached.
                if !add(&firmware, &firmwareCount, r.base, r.base + r.size, grow: false) {
                    _ = add(&denied, &deniedCount, r.base, r.base + r.size, grow: true)
                }
            default:
                _ = add(&denied, &deniedCount, r.base, r.base + r.size, grow: true)
            }
        }
    }

    /// Appends [start, end), merged with the previous range if they touch.
    /// With the list full, `grow` widens the last entry to cover it (for
    /// the deny list: conservative, never permissive); else false.
    private static func add(_ list: inout InlineArray<64, (UInt64, UInt64)>, _ count: inout Int,
                            _ start: UInt64, _ end: UInt64, grow: Bool) -> Bool {
        if count > 0, list[count - 1].1 == start {
            list[count - 1].1 = end
        } else if count < 64 {
            list[count] = (start, end)
            count += 1
        } else if grow {
            list[63].1 = max(list[63].1, end)
        } else {
            return false
        }
        return true
    }

    /// Whether [base, base+size) touches RAM or memory that is never mapped.
    static func overlapsDenied(_ base: UInt64, _ size: UInt64) -> Bool {
        for i in 0..<deniedCount where base < denied[i].1 && denied[i].0 < base &+ size { return true }
        return false
    }

    /// Whether [base, base+size) lies inside firmware memory the physmap
    /// maps cached.
    static func firmwareCovers(_ base: UInt64, _ size: UInt64) -> Bool {
        for i in 0..<firmwareCount where firmware[i].0 <= base && base &+ size <= firmware[i].1 { return true }
        return false
    }

    /// Whether [base, base+size) touches firmware memory the physmap maps
    /// cached.
    static func overlapsFirmware(_ base: UInt64, _ size: UInt64) -> Bool {
        for i in 0..<firmwareCount where base < firmware[i].1 && firmware[i].0 < base &+ size { return true }
        return false
    }
}
