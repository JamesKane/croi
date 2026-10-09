import CKernel
import PageTables
import Synchronization

/// A virtual memory object's state (Zircon's VmObject): a range of pages
/// that address spaces map. Lives on the heap at a fixed address,
/// reference counted by its handle and by every mapping of it.
///
/// - anonymous: zero-filled pages committed on first touch (paged);
/// - physical: someone's physical range, e.g. device memory (never owned);
/// - contiguous: physically contiguous pages committed at creation, with
///   an alignment (K4b adds an address limit and the boot-time pool).
struct VmoRecord: ~Copyable {
    enum Kind: Equatable {
        case anonymous
        case physical(base: UInt64)
        case contiguous(base: UInt64)
    }

    let kind: Kind
    /// Bytes, a whole number of pages.
    let size: UInt64
    let cache: CachePolicy
    /// Names the VMO in trace records (no kernel addresses there).
    let traceId: UInt64
    let lock = SpinLock()
    let references = Atomic<Int>(1)
    /// Anonymous: each page's physical address, or 0 if not committed yet.
    /// A flat array for now; a sparse radix tree replaces it before VMOs
    /// get large (K4b).
    var pages = UniqueArray<UInt64>()
    var committedPages: UInt64 = 0

    var pageCount: Int { Int(size / KernelLayout.pageSize) }
}

@safe struct VmoPointer: Equatable {
    let address: UInt64

    var pointee: VmoRecord {
        unsafeAddress { unsafe UnsafePointer<VmoRecord>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<VmoRecord>(bitPattern: UInt(address))! }
    }

    /// Another owner (a mapping).
    func retain() {
        guard pointee.references.add(1, ordering: .relaxed).newValue > 1 else { panic("vmo: retained after release") }
    }

    /// Drops an owner; the last frees the VMO and the pages it owns.
    func release() {
        guard pointee.references.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 else { return }
        switch pointee.kind {
        case .anonymous:
            for i in 0..<pointee.pageCount where pointee.pages[i] != 0 { pmm.free(pointee.pages[i]) }
        case .contiguous(let base):
            pmm.free(base, count: UInt64(pointee.pageCount))
        case .physical:
            break
        }
        let raw = unsafe UnsafeMutablePointer<VmoRecord>(bitPattern: UInt(address))!
        unsafe raw.deinitialize(count: 1)
        unsafe heap.free(UnsafeMutableRawPointer(raw))
        Vmos.live.subtract(1, ordering: .relaxed)
    }

    /// The physical page holding byte `offset`, committing it (zeroed) if
    /// this is an anonymous VMO and it isn't yet. nil if out of memory.
    func commit(at offset: UInt64) -> UInt64? {
        let index = Int(offset / KernelLayout.pageSize)
        switch pointee.kind {
        case .physical(let base), .contiguous(let base):
            return base + UInt64(index) * KernelLayout.pageSize
        case .anonymous:
            return pointee.lock.withLock { () -> UInt64? in
                if pointee.pages[index] != 0 { return pointee.pages[index] }
                guard let phys = pmm.allocatePage(.vmo) else { return nil }
                unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(phys)))!
                    .initializeMemory(as: UInt8.self, repeating: 0, count: Int(KernelLayout.pageSize))
                pointee.pages[index] = phys
                pointee.committedPages += 1
                Trace.event(CROI_TRACE_VM, UInt16(CROI_TK_COMMIT), pointee.traceId, UInt64(index))
                return phys
            }
        }
    }

    /// The physical page holding byte `offset` if committed (no commit).
    func lookup(at offset: UInt64) -> UInt64? {
        let index = Int(offset / KernelLayout.pageSize)
        switch pointee.kind {
        case .physical(let base), .contiguous(let base):
            return base + UInt64(index) * KernelLayout.pageSize
        case .anonymous:
            return pointee.lock.withLock { pointee.pages[index] == 0 ? nil : pointee.pages[index] }
        }
    }
}

/// The owner of a VMO (the handle; K5 makes it a dispatcher). Mappings hold
/// their own references, so the memory outlives the handle while mapped.
struct Vmo: ~Copyable {
    let record: VmoPointer

    /// Zero-filled pages, committed when first touched.
    init(anonymous size: UInt64) throws(VmError) {
        record = try Self.make(.anonymous, size: size, cache: .cached)
    }

    /// An existing physical range (device memory, a framebuffer). The VMO
    /// doesn't own it.
    init(physical base: UInt64, size: UInt64, cache: CachePolicy) throws(VmError) {
        guard base % KernelLayout.pageSize == 0 else { throw .unaligned(base) }
        record = try Self.make(.physical(base: base), size: size, cache: cache)
    }

    /// Physically contiguous pages, zeroed, aligned to 2^alignLog2 bytes.
    init(contiguous size: UInt64, alignLog2: Int = 12, cache: CachePolicy = .cached) throws(VmError) {
        guard size > 0, size % KernelLayout.pageSize == 0 else { throw .invalidArgument }
        guard let base = pmm.allocateContiguous(size / KernelLayout.pageSize, alignLog2: alignLog2, .vmo) else {
            throw .outOfMemory
        }
        unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(base)))!
            .initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        do throws(VmError) {
            record = try Self.make(.contiguous(base: base), size: size, cache: cache)
        } catch {
            pmm.free(base, count: size / KernelLayout.pageSize)
            throw error
        }
    }

    private static func make(_ kind: VmoRecord.Kind, size: UInt64, cache: CachePolicy) throws(VmError) -> VmoPointer {
        guard size > 0, size % KernelLayout.pageSize == 0 else { throw .invalidArgument }
        guard let raw = unsafe heap.allocate(size: MemoryLayout<VmoRecord>.size,
                                             alignment: max(16, MemoryLayout<VmoRecord>.alignment)) else {
            throw .outOfMemory
        }
        var record = VmoRecord(kind: kind, size: size, cache: cache, traceId: Vmos.nextTraceId())
        if kind == .anonymous {
            record.pages = UniqueArray<UInt64>(repeating: 0, count: Int(size / KernelLayout.pageSize))
        }
        unsafe raw.bindMemory(to: VmoRecord.self, capacity: 1).initialize(to: record)
        Vmos.live.add(1, ordering: .relaxed)
        return VmoPointer(address: UInt64(UInt(bitPattern: raw)))
    }

    var size: UInt64 { record.pointee.size }
    var committedPages: UInt64 { record.pointee.lock.withLock { record.pointee.committedPages } }

    /// Kernel-side read of a committed word (tests; syscalls copy in K6).
    func readWord(at offset: UInt64) -> UInt64? {
        guard let phys = record.lookup(at: offset) else { return nil }
        let address = KernelLayout.physmap(phys) + offset % KernelLayout.pageSize
        return unsafe UnsafePointer<UInt64>(bitPattern: UInt(address))!.pointee
    }

    /// Gives up the handle without releasing the VMO: for kernel-held
    /// objects whose owner keeps the pointer (release it later).
    @export(interface)
    consuming func keep() -> VmoPointer {
        let record = self.record
        discard self
        return record
    }

    deinit {
        record.release()
    }
}

enum Vmos {
    static let live = Atomic<Int>(0)
    private static let traceIds = Atomic<UInt64>(0)

    static func nextTraceId() -> UInt64 {
        traceIds.add(1, ordering: .relaxed).newValue
    }
}
