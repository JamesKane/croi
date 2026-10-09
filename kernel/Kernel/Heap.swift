import CKernel

/// The kernel heap. Backed by PMM pages (state `.heap`) reached through the
/// physmap, like Zircon's.
///
/// - Requests up to 2 KiB come from one-page slabs per size class, each
///   carved into equal objects with its own free list. A class keeps a list
///   of slabs that have free objects; a slab that empties goes back to the
///   PMM.
/// - Larger requests (or alignments above 2 KiB) get their own contiguous
///   PMM pages.
///
/// All bookkeeping lives in the PMM's `Page` records, so allocations carry
/// no headers. `free` validates the pointer, catches double frees and
/// poisons freed memory. Entry points take `heapLock`, and may take
/// `pmmLock` inside it.
nonisolated(unsafe) var heap = Heap()

/// Guards `heap`'s slab lists and counters (see SpinLock for lock order).
let heapLock = SpinLock()

@safe struct Heap {
    /// Size classes: multiples of 16, roughly 1.5x apart, all dividing a page
    /// evenly enough. Power-of-two classes also serve large alignments.
    static var classCount: Int { 13 }
    static func classSize(_ c: Int) -> Int {
        switch c {
        case 0: 16
        case 1: 32
        case 2: 48
        case 3: 64
        case 4: 96
        case 5: 128
        case 6: 192
        case 7: 256
        case 8: 384
        case 9: 512
        case 10: 768
        case 11: 1024
        default: 2048
        }
    }

    static var largeHead: UInt8 { 0xFF }
    static var largeTail: UInt8 { 0xFE }
    static var endOfList: UInt16 { 0xFFFF }
    private static var poison: UInt8 { 0xA5 }

    /// Per class: physmap address of the first slab `Page` with free objects.
    private var partial = InlineArray<13, UInt64>(repeating: 0)
    private(set) var bytesInUse = 0
    private(set) var slabPages = 0
    private(set) var largePages = 0

    // MARK: Allocation

    /// `size` bytes aligned to `alignment` (a power of two), or nil.
    mutating func allocate(size: Int, alignment: Int = 16) -> UnsafeMutableRawPointer? {
        unsafe heapLock.withLock { unsafe allocateLocked(size: size, alignment: alignment) }
    }

    private mutating func allocateLocked(size: Int, alignment: Int) -> UnsafeMutableRawPointer? {
        guard alignment > 0, alignment & (alignment - 1) == 0 else { return nil }
        let size = max(size, 1)
        for c in 0..<Self.classCount {
            let objectSize = Self.classSize(c)
            if objectSize >= size, objectSize % alignment == 0 {
                return unsafe allocateSmall(c)
            }
        }
        return unsafe allocateLarge(size: size, alignment: alignment)
    }

    private mutating func allocateSmall(_ c: Int) -> UnsafeMutableRawPointer? {
        if partial[c] == 0 {
            guard newSlab(c) else { return nil }
        }
        let slab = unsafe record(partial[c])
        let offset = unsafe slab.pointee.heapFree
        let object = unsafe objectAddress(slab, offset)
        unsafe slab.pointee.heapFree = object.load(as: UInt16.self)
        unsafe slab.pointee.heapInUse += 1
        if unsafe slab.pointee.heapFree == Self.endOfList {
            unsafe unlinkPartial(slab, c)
        }
        bytesInUse += Self.classSize(c)
        return unsafe object
    }

    /// Takes a page from the PMM and threads all its objects onto its free list.
    private mutating func newSlab(_ c: Int) -> Bool {
        guard let phys = pmm.allocatePage(.heap), let slab = unsafe pmm.page(for: phys) else { return false }
        let objectSize = Self.classSize(c)
        let count = Int(KernelLayout.pageSize) / objectSize
        let base = unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(phys)))!
        for i in 0..<count {
            let next = i + 1 < count ? UInt16((i + 1) * objectSize) : Self.endOfList
            unsafe (base + i * objectSize).storeBytes(of: next, as: UInt16.self)
        }
        unsafe slab.pointee.heapClass = UInt8(c)
        unsafe slab.pointee.heapInUse = 0
        unsafe slab.pointee.heapFree = 0
        unsafe pushPartial(slab, c)
        slabPages += 1
        return true
    }

    private mutating func allocateLarge(size: Int, alignment: Int) -> UnsafeMutableRawPointer? {
        let pageSize = Int(KernelLayout.pageSize)
        let pages = (size + pageSize - 1) / pageSize
        guard pages <= Int(UInt16.max) else { return nil }
        let alignLog2 = max(12, alignment.trailingZeroBitCount)
        guard let phys = pmm.allocateContiguous(UInt64(pages), alignLog2: alignLog2, .heap) else { return nil }
        for i in 0..<pages {
            let page = unsafe pmm.page(for: phys + UInt64(i * pageSize))!
            unsafe page.pointee.heapClass = i == 0 ? Self.largeHead : Self.largeTail
            unsafe page.pointee.heapInUse = i == 0 ? UInt16(pages) : 0
        }
        largePages += pages
        bytesInUse += pages * pageSize
        return unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(phys)))
    }

    // MARK: Free

    /// Frees an allocation. Anything that isn't the start of a live heap
    /// allocation panics.
    mutating func free(_ pointer: UnsafeMutableRawPointer) {
        heapLock.withLock { unsafe freeLocked(pointer) }
    }

    private mutating func freeLocked(_ pointer: UnsafeMutableRawPointer) {
        let virt = UInt64(UInt(bitPattern: pointer))
        guard virt >= KernelLayout.physmapBase else { panic("heap: free of a non-heap pointer") }
        let phys = virt - KernelLayout.physmapBase
        let pageBase = phys & ~(KernelLayout.pageSize - 1)
        guard let page = unsafe pmm.page(for: pageBase), unsafe page.pointee.state == .heap else {
            panic("heap: free of a non-heap pointer")
        }
        switch unsafe page.pointee.heapClass {
        case Self.largeHead:
            guard phys == pageBase else { panic("heap: free of an interior pointer") }
            let pages = unsafe Int(page.pointee.heapInUse)
            unsafe pointer.initializeMemory(as: UInt8.self, repeating: Self.poison, count: pages * Int(KernelLayout.pageSize))
            pmm.free(pageBase, count: UInt64(pages))
            largePages -= pages
            bytesInUse -= pages * Int(KernelLayout.pageSize)
        case Self.largeTail:
            panic("heap: free of an interior pointer")
        default:
            unsafe freeSmall(page, offset: UInt16(phys - pageBase), pointer)
        }
    }

    @unsafe private mutating func freeSmall(_ slab: UnsafeMutablePointer<Page>, offset: UInt16, _ object: UnsafeMutableRawPointer) {
        let c = unsafe Int(slab.pointee.heapClass)
        let objectSize = Self.classSize(c)
        guard Int(offset) % objectSize == 0 else { panic("heap: free of an interior pointer") }
        // Double free: the object is already on this slab's free list.
        var cursor = unsafe slab.pointee.heapFree
        while cursor != Self.endOfList {
            guard cursor != offset else { panic("heap: double free") }
            cursor = unsafe objectAddress(slab, cursor).load(as: UInt16.self)
        }

        let wasFull = unsafe slab.pointee.heapFree == Self.endOfList
        unsafe object.initializeMemory(as: UInt8.self, repeating: Self.poison, count: objectSize)
        unsafe object.storeBytes(of: slab.pointee.heapFree, as: UInt16.self)
        unsafe slab.pointee.heapFree = offset
        unsafe slab.pointee.heapInUse -= 1
        bytesInUse -= objectSize

        if unsafe slab.pointee.heapInUse == 0 {
            if !wasFull { unsafe unlinkPartial(slab, c) }
            unsafe pmm.free(slab.pointee.physical)
            slabPages -= 1
        } else if wasFull {
            unsafe pushPartial(slab, c)
        }
    }

    // MARK: Slab lists

    private func record(_ address: UInt64) -> UnsafeMutablePointer<Page> {
        unsafe UnsafeMutablePointer<Page>(bitPattern: UInt(address))!
    }

    @unsafe private func objectAddress(_ slab: UnsafeMutablePointer<Page>, _ offset: UInt16) -> UnsafeMutableRawPointer {
        unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(slab.pointee.physical)))! + Int(offset)
    }

    @unsafe private mutating func pushPartial(_ slab: UnsafeMutablePointer<Page>, _ c: Int) {
        let address = UInt64(UInt(bitPattern: slab))
        unsafe slab.pointee.prev = 0
        unsafe slab.pointee.next = partial[c]
        if partial[c] != 0 {
            unsafe record(partial[c]).pointee.prev = address
        }
        partial[c] = address
    }

    @unsafe private mutating func unlinkPartial(_ slab: UnsafeMutablePointer<Page>, _ c: Int) {
        let next = unsafe slab.pointee.next
        let prev = unsafe slab.pointee.prev
        if prev != 0 {
            unsafe record(prev).pointee.next = next
        } else {
            partial[c] = next
        }
        if next != 0 {
            unsafe record(next).pointee.prev = prev
        }
        unsafe slab.pointee.next = 0
        unsafe slab.pointee.prev = 0
    }
}

// MARK: C interface (kernel.h)

private let ENOMEM: Int32 = 12
private let EINVAL: Int32 = 22

@c @implementation
func posix_memalign(_ memptr: UnsafeMutablePointer<UnsafeMutableRawPointer?>, _ alignment: Int, _ size: Int) -> Int32 {
    guard alignment >= MemoryLayout<UInt>.size, alignment & (alignment - 1) == 0 else {
        return EINVAL
    }
    guard let pointer = unsafe heap.allocate(size: size, alignment: alignment) else { return ENOMEM }
    unsafe memptr.pointee = pointer
    return 0
}

@c @implementation
func malloc(_ size: Int) -> UnsafeMutableRawPointer? {
    unsafe heap.allocate(size: size)
}

@c @implementation
func free(_ pointer: UnsafeMutableRawPointer?) {
    if let pointer = unsafe pointer {
        unsafe heap.free(pointer)
    }
}
