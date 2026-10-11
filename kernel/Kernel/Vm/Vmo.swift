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
///
/// An anonymous VMO may have a parent (K11a, vmo_create_child's
/// SNAPSHOT_AT_LEAST_ON_WRITE): a page it hasn't committed reads as the
/// parent's at `parentOffset` + its offset (the parent's own parent's, and
/// so on; zero past the parent's end or where nobody has one), and its
/// first touch, read or write, copies that page in. Zircon's "at least on
/// write" allows the copy that early, so no hidden-node tree is needed:
/// the parent's later writes show in the child only where the child
/// hasn't touched. Lock order: child -> parent.
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
    /// A kernel shared page: user mappings are read only, always.
    var sharedReadOnly = false
    /// Physical, over firmware memory the physmap maps cached (K9b): the
    /// cache policy stays `.cached`.
    var cachedFirmware = false
    var committedPages: UInt64 = 0
    /// The address spaces mapping it, once per mapping (for decommit).
    var mappers = UniqueArray<UInt64>()
    /// Ranges pinned for DMA (K9e, a PMT each): their pages stay committed
    /// and in place, and the cache policy stays.
    var pins = UniqueArray<PinRange>()
    /// A child's parent (a reference held), or nil: a copy-on-first-touch
    /// child's (K11a) or a slice's (K13a).
    var parent: VmoPointer? = nil
    var parentOffset: UInt64 = 0
    /// A slice (K13a): the parent's pages, never its own.
    var slice = false
    /// Live children (K13a's ZERO_CHILDREN), and the VMO object to signal
    /// (0 once it is gone; cleared under this lock by its destroy).
    var children = 0
    var object: UInt64 = 0
    /// K13c: the stream ("content") size, byte-granular, shared by every
    /// stream over this VMO; nil until set, reading as the VMO's size.
    var streamSize: UInt64? = nil

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
        if let parent = pointee.parent {
            parent.childGone()
            parent.release()
        }
        switch pointee.kind {
        case .anonymous:
            pointee.pages.forEach { _, phys in pmm.free(phys) }
        case .contiguous where pointee.slice:
            break  // the parent's pages
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

    /// A child of this VMO was created (K13a): counted, and the object's
    /// ZERO_CHILDREN cleared. The object's lock serializes the signal with
    /// `childGone`, which rechecks the count under it (as Zircon does).
    func childAdded() {
        let object = pointee.lock.withLock { () -> UInt64 in
            pointee.children += 1
            return pointee.object
        }
        signalChildren(object)
    }

    /// One went (its last reference): ZERO_CHILDREN set if it was the last.
    func childGone() {
        let object = pointee.lock.withLock { () -> UInt64 in
            pointee.children -= 1
            return pointee.children == 0 ? pointee.object : 0
        }
        signalChildren(object)
    }

    /// Sets or clears the object's ZERO_CHILDREN from the count now.
    private func signalChildren(_ address: UInt64) {
        guard address != 0 else { return }
        let object = ObjectPointer(address: address)
        guard object.tryRetain() else { return }  // on its way out
        object.header.lock.withLock {
            let none = pointee.lock.withLock { pointee.children == 0 }
            let bit = UInt32(CROI_VMO_ZERO_CHILDREN)
            object.header.signals = none ? object.header.signals | bit : object.header.signals & ~bit
            Observers.notify(object)
        }
        object.release()
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
                // A child's first touch: what it reads now, copied in.
                let source = pointee.parent.flatMap { $0.content(at: pointee.parentOffset + offset) }
                guard let phys = pmm.allocatePage(.vmo) else {
                    pointee.account?.uncharge(KernelLayout.pageSize)
                    return nil
                }
                guard pointee.pages.set(index, phys) else {
                    pmm.free(phys)
                    pointee.account?.uncharge(KernelLayout.pageSize)
                    return nil
                }
                let page = unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(phys)))!
                if let source {
                    unsafe page.copyMemory(from: UnsafeRawPointer(bitPattern: UInt(KernelLayout.physmap(source)))!,
                                           byteCount: Int(KernelLayout.pageSize))
                } else {
                    unsafe page.initializeMemory(as: UInt8.self, repeating: 0, count: Int(KernelLayout.pageSize))
                }
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

    /// Its pages are RAM the physmap maps (anything but device memory: a
    /// physical VMO is RAM only for the kernel's shared read-only pages).
    var inPhysmap: Bool {
        if case .physical = pointee.kind { return pointee.sharedReadOnly }
        return true
    }

    /// The page whose bytes `offset` reads as, without committing: its own,
    /// else (a child) its parent's at the matching offset, recursively; nil
    /// for zero. Past the end: nil.
    func content(at offset: UInt64) -> UInt64? {
        guard offset < pointee.size else { return nil }
        if let own = lookup(at: offset) { return own }
        guard let parent = pointee.parent else { return nil }
        return parent.content(at: pointee.parentOffset + offset)
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

/// A pinned range of a VMO (bytes, page aligned).
struct PinRange: Equatable {
    let offset: UInt64
    let size: UInt64
}

extension VmoPointer {
    /// Whether any of [offset, offset+size) is pinned. VMO lock held.
    func pinnedLocked(_ offset: UInt64, _ size: UInt64) -> Bool {
        for i in 0..<pointee.pins.count {
            let pin = pointee.pins[i]
            if pin.offset < offset + size && offset < pin.offset + pin.size { return true }
        }
        return false
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

    /// An anonymous VMO over `size` bytes of wired RAM at `base` the loader
    /// filled (bootfs, K8b): it takes the pages over, committed, and frees
    /// them when it goes, like Zircon's VMO over the ZBI's pages.
    init(adopting base: UInt64, size: UInt64) throws(VmError) {
        guard base % KernelLayout.pageSize == 0 else { throw .unaligned(base) }
        let made = try Self.make(.anonymous, size: size, cache: .cached)
        let count = size / KernelLayout.pageSize
        guard pmm.adopt(base, count: count) else {
            made.release()
            throw .denied(base)
        }
        for i in 0..<Int(count) {
            guard made.pointee.pages.set(i, base + UInt64(i) * KernelLayout.pageSize) else {
                // Out of memory for the page list: the VMO frees what it holds.
                for j in i..<Int(count) { pmm.free(base + UInt64(j) * KernelLayout.pageSize) }
                made.release()
                throw .outOfMemory
            }
            made.pointee.committedPages += 1
        }
        record = made
    }

    /// Ext 6: device-local memory (VRAM, a BAR window): a physical range
    /// that is never paged or evicted and is charged to `account` in full.
    init(deviceLocal base: UInt64, size: UInt64, cache: CachePolicy, account: MemoryAccountPointer) throws(VmError) {
        guard base % KernelLayout.pageSize == 0 else { throw .unaligned(base) }
        guard !PhysicalMap.overlapsDenied(base, size), !PhysicalMap.overlapsFirmware(base, size) else {
            throw .denied(base)
        }
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

    /// An existing physical range (device memory, a framebuffer, firmware
    /// tables). The VMO doesn't own it. Firmware memory is always cached,
    /// whatever `cache` says, and a range only partly in it is refused.
    init(physical base: UInt64, size: UInt64, cache: CachePolicy) throws(VmError) {
        guard base % KernelLayout.pageSize == 0 else { throw .unaligned(base) }
        guard !PhysicalMap.overlapsDenied(base, size) else { throw .denied(base) }
        let firmware = PhysicalMap.overlapsFirmware(base, size)
        guard !firmware || PhysicalMap.firmwareCovers(base, size) else { throw .denied(base) }
        record = try Self.make(.physical(base: base), size: size, cache: firmware ? .cached : cache)
        record.pointee.cachedFirmware = firmware
    }

    /// One of the kernel's shared read-only pages (time, topology, power),
    /// for mapping read only into user space. The only RAM a physical VMO
    /// may cover: the kernel owns and writes it; user space only reads.
    init(sharedKernelPage phys: UInt64) throws(VmError) {
        record = try Self.make(.physical(base: phys), size: KernelLayout.pageSize, cache: .cached)
        record.pointee.sharedReadOnly = true
    }

    /// Physically contiguous pages, zeroed, aligned to 2^alignLog2 bytes,
    /// from `floor` up and ending at or below `limit` (a device's DMA
    /// reach). From the boot pool if it can, else from free RAM.
    init(contiguous size: UInt64, alignLog2: Int = 12, cache: CachePolicy = .cached,
         floor: UInt64 = 0, limit: UInt64 = .max, account: MemoryAccountPointer? = nil) throws(VmError) {
        guard size > 0, size % KernelLayout.pageSize == 0 else { throw .invalidArgument }
        if let account, !account.charge(size) { throw .outOfMemory }
        let count = size / KernelLayout.pageSize
        guard let base = ContiguousPool.allocate(Int(count), alignLog2: alignLog2, floor: floor, limit: limit)
                ?? pmm.allocateContiguous(count, alignLog2: alignLog2, .vmo, floor: floor, limit: limit) else {
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

    /// vmo_create_child's SNAPSHOT_AT_LEAST_ON_WRITE child of `parent`
    /// (anonymous: its own or a child; others are NOT_SUPPORTED, as
    /// Zircon refuses snapshots of physical and contiguous VMOs): `size`
    /// bytes reading as the parent's from `offset` (zero past its end),
    /// each page copied in at its first touch. Holds a parent reference.
    init(childOf parent: VmoPointer, offset: UInt64, size: UInt64) throws(VmError) {
        guard case .anonymous = parent.pointee.kind else { throw .notSupported }
        guard offset % KernelLayout.pageSize == 0 else { throw .invalidArgument }
        let made = try Self.make(.anonymous, size: size, cache: .cached)
        parent.retain()
        made.pointee.parent = parent
        made.pointee.parentOffset = offset
        parent.childAdded()
        record = made
    }

    /// vmo_create_child's SLICE (K13a) of a physical or contiguous VMO:
    /// [offset, offset+size) of its pages, page aligned and wholly inside,
    /// with its cache policy and memory flags; a slice of a slice is one of
    /// the root. Holds a reference to the root. Anonymous parents: not yet.
    init(sliceOf parent: VmoPointer, offset: UInt64, size: UInt64) throws(VmError) {
        let page = KernelLayout.pageSize
        guard offset % page == 0, size % page == 0, size > 0,
              !offset.addingReportingOverflow(size).overflow, offset + size <= parent.pointee.size else {
            throw .invalidArgument
        }
        var root = parent, at = offset
        if parent.pointee.slice, let up = parent.pointee.parent {
            root = up
            at += parent.pointee.parentOffset
        }
        let kind: VmoRecord.Kind
        switch root.pointee.kind {
        case .physical(let base): kind = .physical(base: base + at)
        case .contiguous(let base): kind = .contiguous(base: base + at)
        case .anonymous: throw .notSupported
        }
        let (cache, firmware, readOnly) = root.pointee.lock.withLock {
            (root.pointee.cache, root.pointee.cachedFirmware, root.pointee.sharedReadOnly)
        }
        let made = try Self.make(kind, size: size, cache: cache)
        made.pointee.slice = true
        made.pointee.cachedFirmware = firmware
        made.pointee.sharedReadOnly = readOnly
        root.retain()
        made.pointee.parent = root
        made.pointee.parentOffset = at
        root.childAdded()
        record = made
    }

    /// Size 0 only for anonymous VMOs (Zircon allows them: nothing to map).
    private static func make(_ kind: VmoRecord.Kind, size: UInt64, cache: CachePolicy) throws(VmError) -> VmoPointer {
        guard size % KernelLayout.pageSize == 0, size > 0 || kind == .anonymous else { throw .invalidArgument }
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
        // A child's decommitted page would read as its parent's again, not
        // zero (Zircon: NOT_SUPPORTED on snapshot children).
        guard record.pointee.parent == nil else { throw .notSupported }
        var freed = UniqueArray<UInt64>()
        var aspaces = UniqueArray<UInt64>()
        try record.pointee.lock.withLock { () throws(VmError) in
            guard !record.pinnedLocked(offset, size) else { throw .pinned }
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

    /// Cache maintenance over the committed bytes of [offset, offset+size)
    /// (non-coherent DMA), through the physmap. No-op where the platform
    /// has no cache ops, and for device memory (physical VMOs outside
    /// RAM), which the physmap doesn't map and which isn't cached.
    func cacheOp(offset: UInt64, size: UInt64, _ op: UInt32) throws(VmError) {
        guard size > 0, offset <= self.size, size <= self.size - offset else { throw .invalidArgument }
        guard record.inPhysmap else { return }
        let page = KernelLayout.pageSize
        var at = offset
        while at < offset + size {
            let pageStart = at & ~(page - 1)
            let length = min(offset + size, pageStart + page) - at
            if let phys = record.lookup(at: pageStart) {
                arch_cache_op(KernelLayout.physmap(phys) + (at - pageStart), length, op, VmoCache.line)
            }
            at += length
        }
    }

    /// Code written into [offset, offset+size) becomes visible to
    /// instruction fetch on every CPU (vmo_op_range's CACHE_SYNC, and
    /// the program loader after copying code). arm64 by line; rv64 also
    /// asks the SBI for a fence.i on every other hart.
    func syncInstructions(offset: UInt64, size: UInt64) throws(VmError) {
        guard size > 0, offset <= self.size, size <= self.size - offset else { throw .invalidArgument }
        guard record.inPhysmap else { return }
        let page = KernelLayout.pageSize
        let dline = max(VmoCache.line, 16), iline = max(arch_icache_line(), 16)
        var at = offset
        while at < offset + size {
            let pageStart = at & ~(page - 1)
            let length = min(offset + size, pageStart + page) - at
            if let phys = record.lookup(at: pageStart) {
                arch_sync_icache(KernelLayout.physmap(phys) + (at - pageStart), length, dline, iline)
            }
            at += length
        }
        #if arch(riscv64)
        _ = arch_sbi_call(0x5246_4E43, 0, 0, ~0, 0)  // RFENCE: remote_fence_i, every hart
        #endif
    }

    /// vmo_op_range's ZERO: [offset, offset+size) reads as zero. Whole
    /// pages of an anonymous VMO are decommitted; the rest is zeroed in
    /// place (and cleaned out of the cache if the VMO isn't cached, so a
    /// device sees it). Not for device memory.
    func zero(offset: UInt64, size: UInt64) throws(VmError) {
        guard offset <= self.size, size <= self.size - offset else { throw .invalidArgument }
        guard record.inPhysmap else { throw .denied(0) }
        let page = KernelLayout.pageSize
        var at = offset
        let end = offset + size
        while at < end {
            let pageStart = at & ~(page - 1)
            let length = min(end, pageStart + page) - at
            if case .anonymous = record.pointee.kind, length == page, record.pointee.parent == nil,
               !record.pointee.lock.withLock({ record.pinnedLocked(pageStart, page) }) {
                try decommit(offset: pageStart, size: page)
            } else if let phys = record.pointee.parent != nil ? record.commit(at: pageStart) : record.lookup(at: pageStart) {
                let address = KernelLayout.physmap(phys) + (at - pageStart)
                unsafe UnsafeMutableRawPointer(bitPattern: UInt(address))!
                    .initializeMemory(as: UInt8.self, repeating: 0, count: Int(length))
                if record.pointee.cache != .cached {
                    arch_cache_op(address, length, CROI_CACHE_CLEAN_INVALIDATE, VmoCache.line)
                }
            }
            at += length
        }
    }

    /// Changes the memory type future mappings use. Only while unmapped:
    /// committed pages are cleaned and invalidated first, so no line of
    /// the old type outlives the change.
    func setCachePolicy(_ policy: CachePolicy) throws(VmError) {
        try record.pointee.lock.withLock { () throws(VmError) in
            // Slices share their parent's policy, so neither side changes it.
            guard !record.pointee.slice, record.pointee.children == 0 else { throw .badState }
            guard !record.pointee.cachedFirmware || policy == .cached else { throw .denied(0) }
            guard !record.pointee.sharedReadOnly else { throw .denied(0) }  // the kernel writes it cached
            guard record.pointee.mappers.count == 0 else { throw .alreadyMapped(0) }
            guard record.pointee.pins.count == 0 else { throw .pinned }
        }
        if size > 0 { try cacheOp(offset: 0, size: size, CROI_CACHE_CLEAN_INVALIDATE) }
        record.pointee.lock.withLock { record.pointee.cache = policy }
    }

    /// Pins [offset, offset+size) (page aligned) for DMA: commits its pages
    /// and keeps them until `unpin` with the same range.
    func pin(offset: UInt64, size: UInt64) throws(VmError) {
        try checkRange(offset, size)
        let page = KernelLayout.pageSize
        while true {
            var at = offset
            while at < offset + size {
                guard record.commit(at: at) != nil else { throw .outOfMemory }
                at += page
            }
            // A decommit may have raced the commits: check under the lock
            // that pins them.
            let done = record.pointee.lock.withLock { () -> Bool in
                if case .anonymous = record.pointee.kind {
                    var at = offset
                    while at < offset + size {
                        guard record.pointee.pages.lookup(Int(at / page)) != 0 else { return false }
                        at += page
                    }
                }
                record.pointee.pins.append(PinRange(offset: offset, size: size))
                return true
            }
            if done { return }
        }
    }

    func unpin(offset: UInt64, size: UInt64) {
        record.pointee.lock.withLock {
            for i in 0..<record.pointee.pins.count where record.pointee.pins[i] == PinRange(offset: offset, size: size) {
                _ = record.pointee.pins.remove(at: i)
                return
            }
            panic("vmo: unpinning a range that isn't pinned")
        }
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

    /// Runs `body` with a borrowed handle over `record` (no reference of
    /// its own taken or dropped).
    static func withBorrowed<R>(_ record: VmoPointer, _ body: (borrowing Vmo) throws(VmError) -> R) throws(VmError) -> R {
        let vmo = borrowing(record)
        let result: R
        do throws(VmError) {
            result = try body(vmo)
        } catch {
            _ = vmo.keep()
            throw error
        }
        _ = vmo.keep()
        return result
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
