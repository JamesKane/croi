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
    /// Changed only while unmapped (`setCachePolicy`).
    var cache: CachePolicy
    /// Names the VMO in trace records (no kernel addresses there).
    let traceId: UInt64
    let lock = SpinLock()
    let references = Atomic<Int>(1)
    /// Anonymous: the committed pages (sparse).
    var pages: PageList
    /// The budget it is charged to (ext 6), if any.
    var account: MemoryAccountPointer? = nil
    /// Device-local or pinned: never paged or evicted (for the pager to
    /// come); charged in full.
    var neverEvict = false
    var committedPages: UInt64 = 0
    /// The address spaces mapping it, once per mapping (for decommit).
    var mappers = UniqueArray<UInt64>()

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
        if let account = pointee.account {
            switch pointee.kind {
            case .anonymous: account.uncharge(pointee.committedPages * KernelLayout.pageSize)
            case .contiguous, .physical: if pointee.neverEvict { account.uncharge(pointee.size) }
            }
            account.release()
        }
        switch pointee.kind {
        case .anonymous:
            pointee.pages.forEach { _, phys in pmm.free(phys) }
        case .contiguous(let base):
            if ContiguousPool.contains(base) {
                ContiguousPool.free(base, pointee.pageCount)
            } else {
                pmm.free(base, count: UInt64(pointee.pageCount))
            }
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
                let present = pointee.pages.lookup(index)
                if present != 0 { return present }
                if let account = pointee.account, !account.charge(KernelLayout.pageSize) { return nil }
                guard let phys = pmm.allocatePage(.vmo) else {
                    pointee.account?.uncharge(KernelLayout.pageSize)
                    return nil
                }
                guard pointee.pages.set(index, phys) else {
                    pmm.free(phys)
                    pointee.account?.uncharge(KernelLayout.pageSize)
                    return nil
                }
                unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(phys)))!
                    .initializeMemory(as: UInt8.self, repeating: 0, count: Int(KernelLayout.pageSize))
                pointee.committedPages += 1
                Trace.event(CROI_TRACE_VM, UInt16(CROI_TK_COMMIT), pointee.traceId, UInt64(index))
                return phys
            }
        }
    }

    func addMapper(_ aspace: UInt64) {
        pointee.lock.withLock { pointee.mappers.append(aspace) }
    }

    func removeMapper(_ aspace: UInt64) {
        pointee.lock.withLock {
            for i in 0..<pointee.mappers.count where pointee.mappers[i] == aspace {
                _ = pointee.mappers.remove(at: i)
                return
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
            return pointee.lock.withLock { () -> UInt64? in
                let phys = pointee.pages.lookup(index)
                return phys == 0 ? nil : phys
            }
        }
    }
}

/// The owner of a VMO (the handle; K5 makes it a dispatcher). Mappings hold
/// their own references, so the memory outlives the handle while mapped.
struct Vmo: ~Copyable {
    let record: VmoPointer

    /// Zero-filled pages, committed when first touched, charged to
    /// `account` (a MemoryAccount's record) as they are.
    init(anonymous size: UInt64, account: MemoryAccountPointer? = nil) throws(VmError) {
        let made = try Self.make(.anonymous, size: size, cache: .cached)
        if let account { Self.attach(made, account) }
        record = made
    }

    /// Ext 6: device-local memory (VRAM, a BAR window): a physical range
    /// that is never paged or evicted and is charged to `account` in full.
    init(deviceLocal base: UInt64, size: UInt64, cache: CachePolicy, account: MemoryAccountPointer) throws(VmError) {
        guard base % KernelLayout.pageSize == 0 else { throw .unaligned(base) }
        guard !PhysicalMap.overlapsDenied(base, size) else { throw .denied(base) }
        guard account.charge(size) else { throw .outOfMemory }
        let made: VmoPointer
        do throws(VmError) {
            made = try Self.make(.physical(base: base), size: size, cache: cache)
        } catch {
            account.uncharge(size)
            throw error
        }
        made.pointee.neverEvict = true
        Self.attach(made, account)
        record = made
    }

    private static func attach(_ record: VmoPointer, _ account: MemoryAccountPointer) {
        account.retain()
        record.pointee.account = account
    }

    private static func attach(_ record: VmoPointer, _ account: MemoryAccountPointer, upFront: UInt64) {
        account.retain()
        record.pointee.account = account
    }

    /// An existing physical range (device memory, a framebuffer). The VMO
    /// doesn't own it.
    init(physical base: UInt64, size: UInt64, cache: CachePolicy) throws(VmError) {
        guard base % KernelLayout.pageSize == 0 else { throw .unaligned(base) }
        guard !PhysicalMap.overlapsDenied(base, size) else { throw .denied(base) }
        record = try Self.make(.physical(base: base), size: size, cache: cache)
    }

    /// Physically contiguous pages, zeroed, aligned to 2^alignLog2 bytes,
    /// ending at or below `limit` (a device's DMA reach). From the boot
    /// pool if it can, else from free RAM.
    init(contiguous size: UInt64, alignLog2: Int = 12, cache: CachePolicy = .cached,
         limit: UInt64 = .max, account: MemoryAccountPointer? = nil) throws(VmError) {
        guard size > 0, size % KernelLayout.pageSize == 0 else { throw .invalidArgument }
        if let account, !account.charge(size) { throw .outOfMemory }
        let count = size / KernelLayout.pageSize
        guard let base = ContiguousPool.allocate(Int(count), alignLog2: alignLog2, limit: limit)
                ?? pmm.allocateContiguous(count, alignLog2: alignLog2, .vmo, limit: limit) else {
            account?.uncharge(size)
            throw .outOfMemory
        }
        unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(base)))!
            .initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        do throws(VmError) {
            let made = try Self.make(.contiguous(base: base), size: size, cache: cache)
            if let account {
                made.pointee.neverEvict = true  // pinned
                Self.attach(made, account)
            }
            record = made
        } catch {
            account?.uncharge(size)
            if ContiguousPool.contains(base) { ContiguousPool.free(base, Int(count)) } else { pmm.free(base, count: count) }
            throw error
        }
    }

    private static func make(_ kind: VmoRecord.Kind, size: UInt64, cache: CachePolicy) throws(VmError) -> VmoPointer {
        guard size > 0, size % KernelLayout.pageSize == 0 else { throw .invalidArgument }
        guard let raw = unsafe heap.allocate(size: MemoryLayout<VmoRecord>.size,
                                             alignment: max(16, MemoryLayout<VmoRecord>.alignment)) else {
            throw .outOfMemory
        }
        let record = VmoRecord(kind: kind, size: size, cache: cache, traceId: Vmos.nextTraceId(),
                               pages: PageList(pages: kind == .anonymous ? Int(size / KernelLayout.pageSize) : 0))
        unsafe raw.bindMemory(to: VmoRecord.self, capacity: 1).initialize(to: record)
        Vmos.live.add(1, ordering: .relaxed)
        return VmoPointer(address: UInt64(UInt(bitPattern: raw)))
    }

    var size: UInt64 { record.pointee.size }
    var committedPages: UInt64 { record.pointee.lock.withLock { record.pointee.committedPages } }

    /// Commits every page of [offset, offset+size) now (anonymous VMOs;
    /// others are always committed).
    func commit(offset: UInt64, size: UInt64) throws(VmError) {
        try checkRange(offset, size)
        var at = offset
        while at < offset + size {
            guard record.commit(at: at) != nil else { throw .outOfMemory }  // or over the account's budget
            at += KernelLayout.pageSize
        }
    }

    /// Frees the committed pages of [offset, offset+size) (anonymous VMOs):
    /// they read as zero again. Every mapping of them is unmapped first.
    ///
    /// Order, since faults lock aspace -> vmo: take the pages out of the
    /// VMO (a fault from here on commits fresh ones), then remove their
    /// entries from each address space mapping the VMO (held by a reference
    /// meanwhile, in case it is being torn down), then free the pages.
    func decommit(offset: UInt64, size: UInt64) throws(VmError) {
        try checkRange(offset, size)
        guard case .anonymous = record.pointee.kind else { throw .invalidArgument }
        var freed = UniqueArray<UInt64>()
        var aspaces = UniqueArray<UInt64>()
        record.pointee.lock.withLock {
            let first = Int(offset / KernelLayout.pageSize), count = Int(size / KernelLayout.pageSize)
            for i in first..<(first + count) {
                let phys = record.pointee.pages.clear(i)
                guard phys != 0 else { continue }
                freed.append(phys)
                record.pointee.committedPages -= 1
            }
            for i in 0..<record.pointee.mappers.count {
                let aspace = record.pointee.mappers[i]
                var seen = false
                for j in 0..<aspaces.count where aspaces[j] == aspace { seen = true }
                if !seen {
                    UserAspacePointer(address: aspace).retain()
                    aspaces.append(aspace)
                }
            }
        }
        for i in 0..<aspaces.count {
            let aspace = UserAspacePointer(address: aspaces[i])
            aspace.pointee.lock.withLock {
                guard !aspace.pointee.dead else { return }
                for j in 0..<aspace.pointee.mappings.count {
                    let m = aspace.pointee.mappings[j]
                    guard m.vmo == record, m.offset < offset + size, offset < m.offset + m.size else { continue }
                    let start = max(m.offset, offset), end = min(m.offset + m.size, offset + size)
                    do throws(VmError) {
                        try aspace.pointee.arch.unmap(virt: m.base + (start - m.offset), size: end - start)
                    } catch {
                        panic("vmo: decommit couldn't unmap")
                    }
                }
            }
            aspace.release()
        }
        for i in 0..<freed.count { pmm.free(freed[i]) }
        record.pointee.account?.uncharge(UInt64(freed.count) * KernelLayout.pageSize)
    }

    /// Cache maintenance over the committed pages of [offset, offset+size)
    /// (non-coherent DMA). No-op where the platform has no cache ops.
    func cacheOp(offset: UInt64, size: UInt64, _ op: UInt32) throws(VmError) {
        try checkRange(offset, size)
        var at = offset
        while at < offset + size {
            if let phys = record.lookup(at: at) {
                arch_cache_op(KernelLayout.physmap(phys), KernelLayout.pageSize, op, VmoCache.line)
            }
            at += KernelLayout.pageSize
        }
    }

    /// Changes the memory type future mappings use. Only while unmapped:
    /// committed pages are cleaned and invalidated first, so no line of
    /// the old type outlives the change.
    func setCachePolicy(_ policy: CachePolicy) throws(VmError) {
        try record.pointee.lock.withLock { () throws(VmError) in
            guard record.pointee.mappers.count == 0 else { throw .alreadyMapped(0) }
        }
        try cacheOp(offset: 0, size: size, CROI_CACHE_CLEAN_INVALIDATE)
        record.pointee.lock.withLock { record.pointee.cache = policy }
    }

    private func checkRange(_ offset: UInt64, _ size: UInt64) throws(VmError) {
        guard offset % KernelLayout.pageSize == 0, size % KernelLayout.pageSize == 0, size > 0,
              offset <= self.size, size <= self.size - offset else { throw .invalidArgument }
    }

    /// Kernel-side write of `count` bytes from `source` at `offset`,
    /// committing pages (loading user programs until K8's loader).
    func writeBytes(at offset: UInt64, from source: UInt64, count: UInt64) {
        var done: UInt64 = 0
        while done < count {
            let at = offset + done
            guard let phys = record.commit(at: at) else { panic("vmo: out of memory") }
            let within = at % KernelLayout.pageSize
            let chunk = min(count - done, KernelLayout.pageSize - within)
            unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(phys) + within))!
                .copyMemory(from: UnsafeRawPointer(bitPattern: UInt(source + done))!, byteCount: Int(chunk))
            done += chunk
        }
    }

    /// Kernel-side write of a word, committing its page (tests; K6 copies).
    func writeWord(at offset: UInt64, _ value: UInt64) {
        guard let phys = record.commit(at: offset) else { panic("vmo: out of memory") }
        let address = KernelLayout.physmap(phys) + offset % KernelLayout.pageSize
        unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(address))!.pointee = value
    }

    /// Kernel-side read of a committed word (tests; syscalls copy in K6).
    func readWord(at offset: UInt64) -> UInt64? {
        guard let phys = record.lookup(at: offset) else { return nil }
        let address = KernelLayout.physmap(phys) + offset % KernelLayout.pageSize
        return unsafe UnsafePointer<UInt64>(bitPattern: UInt(address))!.pointee
    }

    /// A handle over a VMO someone else holds a reference to (no reference
    /// of its own): `keep()` it when done, never drop it.
    static func borrowing(_ record: VmoPointer) -> Vmo {
        Vmo(borrowed: record)
    }

    private init(borrowed record: VmoPointer) {
        self.record = record
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
