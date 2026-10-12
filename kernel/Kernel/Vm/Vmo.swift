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
///
/// K14g, the other child kinds. A full SNAPSHOT copies what its parent
/// shows at creation (no read-through); SNAPSHOT_MODIFIED is one, except
/// under a pager, where it copies what the parent has made its own and
/// reads the rest through as above. A SLICE or REFERENCE of an anonymous
/// VMO is an alias: no pages of its own, its `parent` the root whose pages
/// it shows from `parentOffset` (`target`); syscalls and mappings resolve
/// it there. A reference's sizes are its root's (`sizeOwner`).
struct VmoRecord: ~Copyable {
    enum Kind: Equatable {
        case anonymous
        case physical(base: UInt64)
        case contiguous(base: UInt64)
    }

    let kind: Kind
    /// Bytes, a whole number of pages. Changes only for a resizable VMO
    /// (K13h: `Vmo.resize`), under the lock.
    var size: UInt64
    var resizable = false
    /// K14k: a pager VMO's zero intervals (Zircon's): ranges of absent
    /// pages that read as zeros the pager isn't asked for, sorted and
    /// disjoint (Pager.swift, `ZeroInterval`).
    var zeros = UniqueArray<ZeroInterval>()
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
    /// K14g: a reference to an anonymous VMO (its root's pages and sizes).
    var reference = false
    /// K14g: the VMO it was created from, where that isn't `parent` (an
    /// alias of an alias, a full snapshot, a SNAPSHOT_MODIFIED child
    /// reading through to its grandparent): its ZERO_CHILDREN counts this
    /// one. A reference held.
    var owner: VmoPointer? = nil
    /// K14g: a snapshot child of any kind (ZX_INFO_VMO's IS_COW_CLONE;
    /// decommit refused, Zircon's), and where reads through `parent` stop
    /// (bytes; a SNAPSHOT_MODIFIED child's parent's end).
    var clone = false
    var parentLimit = UInt64.max
    /// K14g: live aliases of this root (its cache policy stays).
    var aliases = 0
    /// Live children (K13a's ZERO_CHILDREN), and the VMO object to signal
    /// (0 once it is gone; cleared under this lock by its destroy).
    var children = 0
    var object: UInt64 = 0
    /// K13c: the stream ("content") size, byte-granular, shared by every
    /// stream over this VMO; nil until set, reading as the VMO's size.
    var streamSize: UInt64? = nil
    /// The wait queue of this VMO's size lock (`Streams.withSizeLock`: a
    /// blocking mutex serializing stream size changes and vmo_set_size,
    /// Zircon's per-VMO StreamSizeManager), made on first use; 0 until then.
    var sizeQueue: UInt64 = 0
    /// K13d: a pager VMO's source (pages come from user space: Pagers),
    /// and, for a snapshot child, whether an ancestor is a pager VMO.
    var pager: PagerSourcePointer? = nil
    var readsFromPager = false
    /// A pager VMO's page states (`PageState`: absent is clean), and
    /// whether it was written since the stats were last reset.
    var states = PageList(pages: 0)
    var modified = false
    /// ZX_PROP_NAME (K13e), and its object's koid (kept after the object goes).
    var name = ObjectName(repeating: 0)
    var koid: UInt64 = 0
    /// K14a (Vm/Reclaim.swift): on the reclaimable list (a pager VMO or a
    /// discardable one), its links there, and how often reclamation took
    /// pages (ZX_INFO_VMO's committed_change_events).
    var reclaimable = false
    var reclaimNext: UInt64 = 0
    var reclaimPrev: UInt64 = 0
    var reclamationEvents: UInt64 = 0
    /// DISCARDABLE (K14a): LOCK / UNLOCK nest; unlocked it may be
    /// discarded whole.
    var discardable = false
    var lockCount: UInt64 = 0
    var discard = DiscardState.unset
    /// K14f (Vm/Loans.swift): a contiguous VMO's decommitted pages, lent
    /// to the system (a bit each, allocated at the first decommit), and
    /// how many; they read as absent until taken back.
    var lent = UniqueArray<UInt64>()
    var lentPages = 0
    /// Pinned at some point: it never borrows lent pages (K14f; Zircon's
    /// mitigation against DMA into a page after it is given back).
    var everPinned = false

    var pageCount: Int { Int(size / KernelLayout.pageSize) }

    /// A slice or reference of an anonymous VMO (K14g).
    var isAlias: Bool { reference || (slice && kind == .anonymous) }
}

/// A discardable VMO's state (Zircon's DiscardableVmoTracker): reclaimable
/// only once it has been locked and unlocked; discarded, every access
/// fails (NOT_FOUND) until the next LOCK, which finds it empty.
enum DiscardState: UInt8 {
    case unset
    case locked
    case reclaimable
    case discarded
}

@safe struct VmoPointer: Equatable {
    let address: UInt64

    var pointee: VmoRecord {
        unsafeAddress { unsafe UnsafePointer<VmoRecord>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<VmoRecord>(bitPattern: UInt(address))! }
    }

    /// Where its pages are (K14g): an alias's root and its offset there,
    /// else itself at 0.
    var target: (vmo: VmoPointer, offset: UInt64) {
        pointee.isAlias ? (pointee.parent!, pointee.parentOffset) : (self, 0)
    }

    /// Whose size and stream size it has: a reference's root's, else its own.
    var sizeOwner: VmoPointer { pointee.reference ? pointee.parent! : self }

    /// Another owner (a mapping).
    func retain() {
        guard pointee.references.add(1, ordering: .relaxed).newValue > 1 else { panic("vmo: retained after release") }
    }

    /// Drops an owner; the last frees the VMO and the pages it owns.
    func release() {
        guard pointee.references.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 else { return }
        if pointee.reclaimable { Reclaim.unregister(self) }
        if let source = pointee.pager { Pagers.vmoGone(source) }
        if let account = pointee.account {
            switch pointee.kind {
            case .anonymous: account.uncharge(pointee.committedPages * KernelLayout.pageSize)
            case .contiguous, .physical: if pointee.neverEvict { account.uncharge(pointee.size) }
            }
            account.release()
        }
        if let owner = pointee.owner {
            owner.childGone()
            owner.release()
        }
        if let parent = pointee.parent {
            if pointee.owner == nil { parent.childGone() }
            if pointee.isAlias { parent.pointee.lock.withLock { parent.pointee.aliases -= 1 } }
            parent.release()
        }
        switch pointee.kind {
        case .anonymous:
            pointee.pages.forEach { _, phys in pmm.free(phys) }
        case .contiguous where pointee.slice:
            break  // the parent's pages
        case .contiguous(let base):
            Loans.endOfLender(self)  // K14f: lent pages come back first
            if ContiguousPool.contains(base) {
                ContiguousPool.free(base, pointee.pageCount)
            } else {
                pmm.free(base, count: UInt64(pointee.pageCount))
            }
        case .physical:
            break
        }
        if pointee.sizeQueue != 0 { QueuePointer(address: pointee.sizeQueue).deallocate() }  // nobody can hold it now
        let raw = unsafe UnsafeMutablePointer<VmoRecord>(bitPattern: UInt(address))!
        unsafe raw.deinitialize(count: 1)
        unsafe heap.free(UnsafeMutableRawPointer(raw))
        Vmos.live.subtract(1, ordering: .relaxed)
    }

    /// A child of this VMO was created (K13a): counted, and the object's
    /// ZERO_CHILDREN cleared. The object's lock serializes the signal with
    /// `childGone`, which rechecks the count under it (as Zircon does).
    func childAdded() {
        _ = childAdded(unlessLent: false)
    }

    /// `childAdded`, refused (false, nothing counted) with `unlessLent` if
    /// it has lent pages (K14f: a slice shares them), checked under the
    /// same lock decommit takes.
    func childAdded(unlessLent: Bool) -> Bool {
        let object = pointee.lock.withLock { () -> UInt64? in
            if unlessLent, pointee.lentPages > 0 { return nil }
            pointee.children += 1
            return pointee.object
        }
        guard let object else { return false }
        signalChildren(object)
        return true
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
        if pointee.isAlias { return pointee.parent!.commit(at: pointee.parentOffset + offset) }  // K14g
        let index = Int(offset / KernelLayout.pageSize)
        switch pointee.kind {
        case .contiguous(let base):
            // A lent page (K14f) is absent until `Loans.ensure` takes it back.
            if pointee.lentPages > 0, pointee.lock.withLock({ lentLocked(index) }) { return nil }
            return base + UInt64(index) * KernelLayout.pageSize
        case .physical(let base):
            return base + UInt64(index) * KernelLayout.pageSize
        case .anonymous:
            // A pager VMO's missing page comes from its pager, and a child
            // reading through to one waits for it too (Pagers.ensure first).
            if pointee.readsFromPager, let parent = pointee.parent, lookup(at: offset) == nil,
               parent.pagerGap(at: pointee.parentOffset + offset) != nil {
                return nil
            }
            return pointee.lock.withLock { () -> UInt64? in
                guard offset < pointee.size else { return nil }  // past the end (a resizable VMO, K13h)
                guard pointee.discard != .discarded else { return nil }  // K14a: NOT_FOUND until locked
                let present = pointee.pages.lookup(index)
                if present != 0 {
                    if pointee.reclaimable { Reclaim.touch(present) }
                    return present
                }
                // A pager's page is the pager's to supply, except in a zero
                // interval (K13h's grown space, K14k): zeros, dirty.
                let zero = pointee.pager != nil && !pointee.zeros.isEmpty && zeroStateLocked(offset) != nil
                if pointee.pager != nil, !zero { return nil }
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
                // A child's first touch: what it reads now, copied in, under
                // the lock of the VMO that has it (so it can't be freed and
                // reused meanwhile).
                let page = unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(phys)))!
                let copied = offset < pointee.parentLimit && pointee.parent.map { parent in
                    parent.withContent(at: pointee.parentOffset + offset) { source in
                        guard let source else { return false }
                        unsafe page.copyMemory(from: UnsafeRawPointer(bitPattern: UInt(KernelLayout.physmap(source)))!,
                                               byteCount: Int(KernelLayout.pageSize))
                        return true
                    }
                } ?? false
                if !copied {
                    unsafe page.initializeMemory(as: UInt8.self, repeating: 0, count: Int(KernelLayout.pageSize))
                }
                pointee.committedPages += 1
                if zero {
                    let start = offset & ~(KernelLayout.pageSize - 1)
                    carveZerosLocked(start, start + KernelLayout.pageSize)  // the page splits it
                    setDirtLocked(start, PageDirt.dirty)
                    pointee.modified = true
                }
                Trace.event(CROI_TRACE_VM, UInt16(CROI_TK_COMMIT), pointee.traceId, UInt64(index))
                return phys
            }
        }
    }

    func addMapper(_ aspace: UInt64) {
        pointee.lock.withLock { pointee.mappers.append(aspace) }
    }

    /// `addMapper`, and in the same locked step which pages of [offset,
    /// +size) a contiguous VMO has lent (K14f): a bit per page from
    /// `offset`, empty if none.
    func addMapper(_ aspace: UInt64, lentIn offset: UInt64, _ size: UInt64) -> UniqueArray<UInt64> {
        let saved = pointee.lock.acquire()  // withLock can't return a ~Copyable value
        defer { pointee.lock.release(saved) }
        pointee.mappers.append(aspace)
        var bits = UniqueArray<UInt64>()
        guard pointee.lentPages > 0, lentBytesLocked(offset, size) > 0 else { return bits }
        let page = KernelLayout.pageSize
        let count = Int(size / page)
        bits = UniqueArray<UInt64>(repeating: 0, count: (count + 63) / 64)
        for i in 0..<count where lentLocked(Int(offset / page) + i) { bits[i / 64] |= 1 << UInt64(i % 64) }
        return bits
    }

    /// A physical or contiguous VMO's first page (0 for anonymous ones).
    var physicalBase: UInt64 {
        switch pointee.kind {
        case .physical(let base), .contiguous(let base): return base
        case .anonymous: return 0
        }
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
        if pointee.isAlias { return pointee.parent!.content(at: pointee.parentOffset + offset) }  // K14g
        guard offset < pointee.size else { return nil }
        if let own = lookup(at: offset) { return own }
        guard offset < pointee.parentLimit, let parent = pointee.parent else { return nil }
        return parent.content(at: pointee.parentOffset + offset)
    }

    /// `content(at:)` (an anonymous VMO's), with the lock of the VMO that
    /// has the page held while `body` reads it (nil: zeros), so it isn't
    /// freed meanwhile. Lock order child -> parent: the caller may hold
    /// a descendant's lock, never an ancestor's.
    func withContent<R>(at offset: UInt64, _ body: (UInt64?) -> R) -> R {
        if pointee.isAlias { return pointee.parent!.withContent(at: pointee.parentOffset + offset, body) }  // K14g
        switch pointee.kind {
        case .anonymous: break
        case .physical, .contiguous:
            // Fixed pages, except a contiguous VMO's lent ones (K14f), which
            // read as absent until taken back.
            return pointee.lock.withLock { body(ownLocked(at: offset)) }
        }
        var result: R? = nil
        var up: (VmoPointer, UInt64)? = nil
        pointee.lock.withLock {
            let phys = offset < pointee.size ? pointee.pages.lookup(Int(offset / KernelLayout.pageSize)) : 0
            if phys != 0 {
                if pointee.reclaimable { Reclaim.touch(phys) }
                result = body(phys)
            } else if offset < pointee.size, offset < pointee.parentLimit, let parent = pointee.parent {
                up = (parent, pointee.parentOffset + offset)
            } else {
                result = body(nil)
            }
        }
        if let result { return result }
        let (parent, at) = up!
        return parent.withContent(at: at, body)
    }

    /// The physical page holding byte `offset` if committed (no commit).
    func lookup(at offset: UInt64) -> UInt64? {
        if pointee.isAlias { return pointee.parent!.lookup(at: pointee.parentOffset + offset) }  // K14g
        let index = Int(offset / KernelLayout.pageSize)
        switch pointee.kind {
        case .contiguous(let base):
            if pointee.lentPages > 0, pointee.lock.withLock({ lentLocked(index) }) { return nil }  // lent (K14f)
            return base + UInt64(index) * KernelLayout.pageSize
        case .physical(let base):
            return base + UInt64(index) * KernelLayout.pageSize
        case .anonymous:
            return pointee.lock.withLock { () -> UInt64? in
                guard offset < pointee.size else { return nil }  // shrunk (K13h)
                let phys = pointee.pages.lookup(index)
                // A lookup is an access (Zircon's LookupCursor): a reader
                // copying from the page keeps it from eviction meanwhile.
                if phys != 0, pointee.reclaimable { Reclaim.touch(phys) }
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
    /// Removes [offset, offset+size)'s entries from every address space
    /// mapping this VMO (each held by a reference meanwhile, in case it is
    /// being torn down); the next access faults. VMO lock not held (faults
    /// lock aspace -> vmo).
    func unmapEverywhere(_ offset: UInt64, _ size: UInt64) {
        var aspaces = UniqueArray<UInt64>()
        pointee.lock.withLock {
            for i in 0..<pointee.mappers.count {
                let aspace = pointee.mappers[i]
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
                    guard m.vmo == self, m.offset < offset + size, offset < m.offset + m.size else { continue }
                    let start = max(m.offset, offset), end = min(m.offset + m.size, offset + size)
                    do throws(VmError) {
                        try aspace.pointee.arch.unmap(virt: m.base + (start - m.offset), size: end - start)
                    } catch {
                        panic("vmo: couldn't unmap")
                    }
                }
            }
            aspace.release()
        }
    }

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

    /// A SNAPSHOT_AT_LEAST_ON_WRITE child of `parent` (anonymous: its own
    /// or a child, never an alias): `size` bytes reading as the parent's
    /// from `offset` (zero past its end), each page copied in at its first
    /// touch. Holds a parent reference; counted as a child of `owner` if
    /// given (K14g: the alias it was created through), else of `parent`.
    init(childOf parent: VmoPointer, offset: UInt64, size: UInt64, owner: VmoPointer? = nil,
         account: MemoryAccountPointer? = nil) throws(VmError) {
        guard case .anonymous = parent.pointee.kind else { throw .notSupported }
        guard offset % KernelLayout.pageSize == 0 else { throw .invalidArgument }
        let made = try Self.make(.anonymous, size: size, cache: .cached)
        if let account { Self.attach(made, account) }  // K15a: its own pages, as it copies them in
        made.pointee.readsFromPager = parent.pointee.pager != nil || parent.pointee.readsFromPager
        made.pointee.clone = true
        Self.link(made, parent: parent, at: offset, owner: owner)
        record = made
    }

    /// The child kinds of vmo_create_child that copy (K14g).
    enum Snapshot {
        case full, atLeastOnWrite, modified
    }

    /// vmo_create_child's snapshots of `holder`, in Zircon's order of
    /// checks (CreateClone, CreateCloneLocked): physical NOT_SUPPORTED,
    /// contiguous INVALID_ARGS; an unaligned offset INVALID_ARGS; uncached
    /// BAD_STATE; a full snapshot under a pager NOT_SUPPORTED. Zircon's
    /// "bidirectional" clones (full; modified of a child) can't be taken
    /// through a slice, and only pager hierarchies have the other kind, so
    /// a slice of an anonymous VMO takes none (NOT_SUPPORTED); bidirectional
    /// ones (and at-least-on-write of anonymous VMOs, bidirectional there)
    /// refuse a VMO with pinned pages (BAD_STATE). What croi builds:
    /// - at least on write: read-through (`init(childOf:)`);
    /// - full, and modified without a pager: every page the source shows
    ///   in range copied now, nothing read through (Zircon shares them
    ///   until written: same contents, more memory at once here);
    /// - modified of a pager VMO's child: the child's own pages copied, the
    ///   rest read through to the pager VMO as at least on write;
    /// - modified of a pager VMO itself: at least on write.
    static func snapshot(of holder: VmoPointer, _ type: Snapshot, offset: UInt64, size: UInt64,
                         account: MemoryAccountPointer? = nil) throws(VmError) -> Vmo {
        switch holder.pointee.kind {
        case .physical: throw .notSupported
        case .contiguous: throw .invalidArgument
        case .anonymous: break
        }
        let page = KernelLayout.pageSize
        guard offset % page == 0 else { throw .invalidArgument }
        let (source, shift) = holder.target
        guard source.pointee.lock.withLock({ source.pointee.cache }) == .cached else { throw .badState }
        let pagerTree = source.pointee.pager != nil || source.pointee.readsFromPager
        if type == .full, pagerTree { throw .notSupported }
        let (start, overflow) = shift.addingReportingOverflow(offset)
        guard !overflow, !start.addingReportingOverflow(size).overflow else { throw .invalidArgument }
        let hasParent = source.pointee.parent != nil || source.pointee.clone
        let bidirectional = type == .full || (type == .modified && hasParent)
        let throughSlice = holder.pointee.slice
        if bidirectional, throughSlice { throw .notSupported }
        let unidirectional = !bidirectional && pagerTree
        if !unidirectional {
            if throughSlice { throw .notSupported }
            guard source.pointee.lock.withLock({ source.pointee.pins.isEmpty }) else { throw .badState }
        }
        let owner = holder == source ? nil : holder
        if type == .atLeastOnWrite || unidirectional {
            return try Vmo(childOf: source, offset: start, size: size, owner: owner, account: account)
        }
        let made = try make(.anonymous, size: size, cache: .cached)
        made.pointee.clone = true
        if let account { attach(made, account) }  // charged per page copied (K15a)
        if pagerTree {
            // Modified of a pager VMO's child: its own pages now, the rest
            // through to its parent, up to where it stops reading through.
            guard let parent = source.pointee.parent else {
                made.release()
                throw .badState
            }
            do throws(VmError) {
                try copyContent(of: source, from: start, into: made, throughParents: false)
            } catch {
                made.release()
                throw error
            }
            let limit = min(source.pointee.size, source.pointee.parentLimit)
            made.pointee.parentLimit = limit > start ? limit - start : 0
            made.pointee.readsFromPager = true
            link(made, parent: parent, at: source.pointee.parentOffset + start, owner: holder)
            return Vmo(made: made)
        }
        do throws(VmError) {
            try copyContent(of: source, from: start, into: made, throughParents: true)
        } catch {
            made.release()
            throw error
        }
        holder.retain()
        made.pointee.owner = holder
        holder.childAdded()
        return Vmo(made: made)
    }

    private init(made: VmoPointer) {
        record = made
    }

    /// Sets a new child's parent (a reference taken) and counts it as a
    /// child of `owner` (a reference taken too) if given, else of `parent`.
    private static func link(_ made: VmoPointer, parent: VmoPointer, at offset: UInt64, owner: VmoPointer?) {
        parent.retain()
        made.pointee.parent = parent
        made.pointee.parentOffset = offset
        if let owner {
            owner.retain()
            made.pointee.owner = owner
            owner.childAdded()
        } else {
            parent.childAdded()
        }
    }

    /// Copies into `made` (new: nobody else sees it yet) the pages `source`
    /// shows over [start, +made's size): its own, and with `throughParents`
    /// its ancestors' where nearer ones have none, as `content(at:)` reads.
    /// One level at a time, each under its lock while its pages are copied.
    private static func copyContent(of source: VmoPointer, from start: UInt64, into made: VmoPointer,
                                    throughParents: Bool) throws(VmError) {
        let page = KernelLayout.pageSize
        var level = source, at = start, limit = made.pointee.size  // bytes of `made` this level may show
        while limit > 0 {
            var failed = false
            var next: (VmoPointer, UInt64, UInt64)? = nil
            level.pointee.lock.withLock {
                let end = level.pointee.size > at ? min(limit, level.pointee.size - at) : 0
                let first = Int(at / page), last = first + Int((end + page - 1) / page)
                level.pointee.pages.forEach { index, phys in
                    guard !failed, index >= first, index < last,
                          made.pointee.pages.lookup(index - first) == 0 else { return }  // a nearer level's
                    // Charged to the new VMO's account, if it has one (K15a:
                    // committedPages and the charge move together).
                    if let account = made.pointee.account, !account.charge(page) {
                        failed = true
                        return
                    }
                    guard let copy = pmm.allocatePage(.vmo) else {
                        made.pointee.account?.uncharge(page)
                        failed = true
                        return
                    }
                    unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(copy)))!
                        .copyMemory(from: UnsafeRawPointer(bitPattern: UInt(KernelLayout.physmap(phys)))!, byteCount: Int(page))
                    guard made.pointee.pages.set(index - first, copy) else {
                        pmm.free(copy)
                        made.pointee.account?.uncharge(page)
                        failed = true
                        return
                    }
                    made.pointee.committedPages += 1
                }
                if throughParents, let parent = level.pointee.parent {
                    let through = level.pointee.parentLimit > at ? min(end, level.pointee.parentLimit - at) : 0
                    next = (parent, level.pointee.parentOffset + at, through)
                }
            }
            if failed { throw .outOfMemory }
            guard let (parent, parentAt, through) = next else { return }
            level = parent
            at = parentAt
            limit = through
        }
    }

    /// vmo_create_child's SLICE: [offset, offset+size) of `holder`'s pages,
    /// page aligned and wholly inside (INVALID_ARGS). Physical and
    /// contiguous (K13a): a VMO of that kind over the range, with its root's
    /// cache policy and memory flags. Anonymous (K14g): an alias of the
    /// root (resizable: NOT_SUPPORTED; uncached: BAD_STATE, Zircon's). A
    /// slice of a slice is one of the root, counted as the slice's child
    /// (Zircon's parent). Holds a reference to the root (and the slice).
    /// K15a: `account` (CROI_VMO_CHARGE_TO) charges a slice of a physical
    /// VMO its whole size, never evicted (device-local memory: a BAR or VRAM
    /// window handed to a client); refused for other kinds (no pages of
    /// their own, or charged already).
    init(sliceOf holder: VmoPointer, offset: UInt64, size: UInt64, account: MemoryAccountPointer? = nil) throws(VmError) {
        let page = KernelLayout.pageSize
        let anonymous = holder.pointee.kind == .anonymous
        guard offset % page == 0, size % page == 0, size > 0 || anonymous,
              !offset.addingReportingOverflow(size).overflow, offset + size <= holder.sizeOwner.pointee.size else {
            throw .invalidArgument
        }
        var root = holder, at = offset
        if holder.pointee.slice || holder.pointee.reference, let up = holder.pointee.parent {
            root = up
            at += holder.pointee.parentOffset
        }
        let owner = holder == root ? nil : holder
        let kind: VmoRecord.Kind
        switch root.pointee.kind {
        case .physical(let base): kind = .physical(base: base + at)
        case .contiguous(let base): kind = .contiguous(base: base + at)
        case .anonymous:
            guard !holder.pointee.resizable, !root.pointee.resizable else { throw .notSupported }
            kind = .anonymous
        }
        let (cache, firmware, readOnly) = root.pointee.lock.withLock {
            (root.pointee.cache, root.pointee.cachedFirmware, root.pointee.sharedReadOnly)
        }
        if anonymous, cache != .cached { throw .badState }
        if let account {
            guard case .physical = kind else { throw .invalidArgument }
            guard account.charge(size) else { throw .outOfMemory }
        }
        let made: VmoPointer
        do throws(VmError) {
            made = try Self.make(kind, size: size, cache: cache)
        } catch {
            account?.uncharge(size)
            throw error
        }
        if let account {
            Self.attach(made, account)
            made.pointee.neverEvict = true  // released: uncharged in full
        }
        made.pointee.slice = true
        made.pointee.cachedFirmware = firmware
        made.pointee.sharedReadOnly = readOnly
        if let owner {
            // The slice it was cut from shares the root's pages, so the root
            // has a child and lends nothing (K14f).
            owner.retain()
            made.pointee.owner = owner
            owner.childAdded()
        } else {
            guard root.childAdded(unlessLent: true) else {  // K14f: not over lent pages
                made.release()
                throw .badState
            }
        }
        root.retain()
        made.pointee.parent = root
        made.pointee.parentOffset = at
        if anonymous { root.pointee.lock.withLock { root.pointee.aliases += 1 } }
        record = made
    }

    /// vmo_create_child's REFERENCE (K14g): the whole of `holder`'s root,
    /// its pages and sizes, under a VMO of its own (koid, name, handles,
    /// children), in Zircon's order: physical NOT_SUPPORTED, a range given
    /// INVALID_ARGS (the caller's), a slice or contiguous VMO NOT_SUPPORTED,
    /// RESIZABLE of a non-resizable VMO NOT_SUPPORTED, uncached BAD_STATE.
    /// Resizable if its root is (resizing it resizes the root).
    init(referenceOf holder: VmoPointer, resizable: Bool) throws(VmError) {
        switch holder.pointee.kind {
        case .physical, .contiguous: throw .notSupported
        case .anonymous: break
        }
        guard !holder.pointee.slice else { throw .notSupported }
        let root = holder.target.vmo
        if resizable, !root.pointee.resizable { throw .notSupported }
        guard root.pointee.lock.withLock({ root.pointee.cache }) == .cached else { throw .badState }
        let made = try Self.make(.anonymous, size: 0, cache: .cached)
        made.pointee.reference = true
        made.pointee.resizable = root.pointee.resizable
        Self.link(made, parent: root, at: 0, owner: holder == root ? nil : holder)
        root.pointee.lock.withLock { root.pointee.aliases += 1 }
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
        // A contiguous VMO lends its pages (K14f).
        if case .contiguous = record.pointee.kind { return try Loans.decommit(record, offset: offset, size: size) }
        guard case .anonymous = record.pointee.kind else { throw .invalidArgument }
        // A child's decommitted page would read as its parent's again, not
        // zero (Zircon: NOT_SUPPORTED on snapshot children, K14g's too).
        guard record.pointee.parent == nil, !record.pointee.clone else { throw .notSupported }
        // A pager VMO's page would come back from the pager, not zero.
        guard record.pointee.pager == nil else { throw .notSupported }
        let freed = try takePresent(offset: offset, size: size)
        for i in 0..<freed.count { pmm.free(freed[i]) }
        record.pointee.account?.uncharge(UInt64(freed.count) * KernelLayout.pageSize)
    }

    /// `take`, but only the pages present, found sparsely (K14i: decommit
    /// of an UNBOUNDED VMO's range costs its pages, not its length).
    func takePresent(offset: UInt64, size: UInt64) throws(VmError) -> UniqueArray<UInt64> {
        try checkRange(offset, size)
        guard case .anonymous = record.pointee.kind, record.pointee.parent == nil else { throw .notSupported }
        var freed = UniqueArray<UInt64>()
        try record.pointee.lock.withLock { () throws(VmError) in
            guard !record.pinnedLocked(offset, size) else { throw .pinned }
            let page = KernelLayout.pageSize
            var at = Int(offset / page)
            let end = Int((offset + size) / page)
            while let (index, _) = record.pointee.pages.next(from: at, before: end) {
                freed.append(record.pointee.pages.clear(index))
                record.pointee.committedPages -= 1
                at = index + 1
            }
        }
        record.unmapEverywhere(offset, size)
        return freed
    }

    /// vmo_set_size (K13h; `newSize` page aligned): a resizable anonymous
    /// VMO shrinks (the pages past the end unmapped everywhere and freed;
    /// pinned ones refuse it, .pinned) or grows (the page lists deepened;
    /// a pager VMO's new range zeros it owes nobody). Pager waiters past
    /// the new end are woken to find it gone.
    func resize(_ newSize: UInt64) throws(VmError) {
        guard case .anonymous = record.pointee.kind, record.pointee.resizable else { throw .notSupported }
        let page = KernelLayout.pageSize
        var freed = UniqueArray<UInt64>()
        let old = try record.pointee.lock.withLock { () throws(VmError) -> UInt64 in
            let old = record.pointee.size
            if newSize < old {
                guard !record.pinnedLocked(newSize, old - newSize) else { throw .pinned }
                record.pointee.size = newSize  // from here faults and copies past it fail
                // Only what is there (K14i: sparse).
                var at = Int(newSize / page)
                while let (index, _) = record.pointee.pages.next(from: at, before: Int(old / page)) {
                    freed.append(record.pointee.pages.clear(index))
                    record.pointee.committedPages -= 1
                    at = index + 1
                }
                if record.pointee.pager != nil {
                    at = Int(newSize / page)
                    while let (index, _) = record.pointee.states.next(from: at, before: Int(old / page)) {
                        _ = record.pointee.states.clear(index)
                        at = index + 1
                    }
                }
                record.carveZerosLocked(newSize, .max)
            } else if newSize > old {
                let pages = Int(newSize / page)
                guard record.pointee.pages.grow(toPages: pages),
                      record.pointee.pager == nil || record.pointee.states.grow(toPages: pages) else { throw .outOfMemory }
                if record.pointee.pager != nil { record.addZerosLocked(old, newSize, .dirty) }  // K13h: zeros, dirty
                record.pointee.size = newSize
            }
            if record.pointee.pager != nil { record.pointee.modified = true }
            return old
        }
        guard newSize < old else { return }
        record.unmapEverywhere(newSize, old - newSize)
        for i in 0..<freed.count { pmm.free(freed[i]) }
        record.pointee.account?.uncharge(UInt64(freed.count) * page)
        if let source = record.pointee.pager { Pagers.cut(source, at: newSize) }
    }

    /// Takes the pages of [offset, offset+size) out of an anonymous VMO
    /// with no parent (decommit; pager_supply_pages's aux VMO): one entry
    /// per page, 0 where none was committed. Every mapping of them is
    /// unmapped. The caller frees them (or gives them on) and uncharges.
    func take(offset: UInt64, size: UInt64) throws(VmError) -> UniqueArray<UInt64> {
        try checkRange(offset, size)
        guard case .anonymous = record.pointee.kind, record.pointee.parent == nil else { throw .notSupported }
        var freed = UniqueArray<UInt64>()
        try record.pointee.lock.withLock { () throws(VmError) in
            guard !record.pinnedLocked(offset, size) else { throw .pinned }
            let first = Int(offset / KernelLayout.pageSize), count = Int(size / KernelLayout.pageSize)
            for i in first..<(first + count) {
                let phys = record.pointee.pages.clear(i)
                freed.append(phys)
                if phys != 0 { record.pointee.committedPages -= 1 }
            }
        }
        record.unmapEverywhere(offset, size)
        return freed
    }

    /// Cache maintenance over the committed bytes of [offset, offset+size)
    /// (non-coherent DMA), through the physmap. No-op where the platform
    /// has no cache ops, and for device memory (physical VMOs outside
    /// RAM), which the physmap doesn't map and which isn't cached.
    func cacheOp(offset: UInt64, size: UInt64, _ op: UInt32) throws(VmError) {
        guard size > 0, offset <= self.size, size <= self.size - offset else { throw .invalidArgument }
        guard record.inPhysmap else { return }
        forEachPage(offset, offset + size) { phys, at, length in
            arch_cache_op(KernelLayout.physmap(phys) + at % KernelLayout.pageSize, length, op, VmoCache.line)
        }
    }

    /// Calls `body(phys, at, length)` for each page of [offset, end) the
    /// VMO has (its own; an alias's root's), clipped to the range, under
    /// the lock of the VMO that has it. Anonymous VMOs are walked sparsely
    /// (K14i), others page by page.
    private func forEachPage(_ offset: UInt64, _ end: UInt64, _ body: (UInt64, UInt64, UInt64) -> Void) {
        let (vmo, shift) = record.target
        let page = KernelLayout.pageSize
        var at = offset
        while at < end {
            let pageStart = at & ~(page - 1)
            let index: Int? = vmo.pointee.lock.withLock { () -> Int? in
                if case .anonymous = vmo.pointee.kind {
                    guard let (next, phys) = vmo.pointee.pages.next(from: Int((pageStart + shift) / page),
                                                                    before: Int((end + shift + page - 1) / page)) else {
                        return nil
                    }
                    let start = max(at, UInt64(next) * page - shift)
                    body(phys, start, min(end, UInt64(next) * page - shift + page) - start)
                    return next
                }
                if let phys = vmo.ownLocked(at: pageStart + shift) {
                    body(phys, at, min(end, pageStart + page) - at)
                }
                return Int((pageStart + shift) / page)
            }
            guard let index else { return }
            at = UInt64(index) * page - shift + page
        }
    }

    /// Code written into [offset, offset+size) becomes visible to
    /// instruction fetch on every CPU (vmo_op_range's CACHE_SYNC, and
    /// the program loader after copying code). arm64 by line; rv64 also
    /// asks the SBI for a fence.i on every other hart.
    func syncInstructions(offset: UInt64, size: UInt64) throws(VmError) {
        guard size > 0, offset <= self.size, size <= self.size - offset else { throw .invalidArgument }
        guard record.inPhysmap else { return }
        let dline = max(VmoCache.line, 16), iline = max(arch_icache_line(), 16)
        forEachPage(offset, offset + size) { phys, at, length in
            arch_sync_icache(KernelLayout.physmap(phys) + at % KernelLayout.pageSize, length, dline, iline)
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
        let end = offset + size
        // A plain anonymous VMO's absent pages already read as zero: its
        // whole pages are decommitted (pinned ones zeroed in place), found
        // sparsely (K14i), and only the partial pages at the ends zeroed.
        if case .anonymous = record.pointee.kind, record.pointee.parent == nil, !record.pointee.clone,
           record.pointee.pager == nil {
            let head = min(end, (offset + page - 1) & ~(page - 1))
            let tail = max(head, end & ~(page - 1))
            zeroOwn(offset, head)
            if head < tail {
                if record.pointee.lock.withLock({ !record.pinnedLocked(head, tail - head) }) {
                    try decommit(offset: head, size: tail - head)
                } else {
                    zeroOwn(head, tail)
                }
            }
            zeroOwn(tail, end)
            return
        }
        // A pager VMO (K14k): its whole pages become a dirty zero interval
        // (the partial ends were made writable, dirty, by the caller:
        // `Pagers.ensureWritableForZero`). Not under TRAP_DIRTY, whose pager
        // is asked before anything turns dirty: page by page there.
        if let source = record.pointee.pager, !source.pointee.trapDirty {
            let head = min(end, (offset + page - 1) & ~(page - 1))
            let tail = max(head, end & ~(page - 1))
            if offset < head { _ = record.commit(at: offset & ~(page - 1)) }
            zeroOwn(offset, head)
            Pagers.zeroPages(record, head, tail, .dirty)
            if tail < end { _ = record.commit(at: tail) }
            zeroOwn(tail, end)
            return
        }
        var at = offset
        while at < end {
            let pageStart = at & ~(page - 1)
            let length = min(end, pageStart + page) - at
            // A child's or pager VMO's page is made its own first (a page
            // that can't be is left, as before).
            if record.pointee.parent != nil || record.pointee.pager != nil { _ = record.commit(at: pageStart) }
            zeroOwn(at, at + length)
            at += length
        }
    }

    /// The VMO's own committed bytes in [offset, end) zeroed in place
    /// (sparsely for anonymous VMOs), each page under its lock, and cleaned
    /// out of the cache for an uncached VMO so a device sees it. Absent
    /// pages are left (K14i: the "untracked" zeroing past a stream size,
    /// as Zircon's zero_range_untracked, minus its zero markers).
    func zeroOwn(_ offset: UInt64, _ end: UInt64) {
        guard offset < end else { return }
        let uncached = record.pointee.cache != .cached
        forEachPage(offset, end) { phys, at, length in
            let address = KernelLayout.physmap(phys) + at % KernelLayout.pageSize
            unsafe UnsafeMutableRawPointer(bitPattern: UInt(address))!
                .initializeMemory(as: UInt8.self, repeating: 0, count: Int(length))
            if uncached { arch_cache_op(address, length, CROI_CACHE_CLEAN_INVALIDATE, VmoCache.line) }
        }
    }

    /// Changes the memory type future mappings use. Only while unmapped:
    /// committed pages are cleaned and invalidated first, so no line of
    /// the old type outlives the change.
    func setCachePolicy(_ policy: CachePolicy) throws(VmError) {
        try record.pointee.lock.withLock { () throws(VmError) in
            // Slices and references share their root's policy, so neither
            // side changes it (K14g: nor a root with aliases of aliases).
            guard !record.pointee.slice, !record.pointee.reference, record.pointee.children == 0,
                  record.pointee.aliases == 0 else { throw .badState }
            // K14a: a pager-backed or discardable VMO stays cached (Zircon's).
            guard policy == .cached || (record.pointee.pager == nil && !record.pointee.discardable) else { throw .badState }
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
            Loans.ensure(record, offset, size)  // K14f: lent pages back first
            if record.pointee.pager != nil {  // and borrowed ones swapped for their own
                var at = offset
                while at < offset + size {
                    guard Loans.unborrow(record, at) else { throw .outOfMemory }
                    at += page
                }
            }
            var at = offset
            while at < offset + size {
                guard record.commit(at: at) != nil else {
                    if record.pointee.lentPages > 0 { break }  // lent again meanwhile: once more
                    throw .outOfMemory
                }
                at += page
            }
            guard at >= offset + size else { continue }
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
                if record.pointee.lentPages > 0, record.lentBytesLocked(offset, size) > 0 { return false }
                // K14f: no borrowed page is pinned (swapped back first).
                if record.pointee.pager != nil {
                    var at = offset
                    while at < offset + size {
                        let phys = record.pointee.pages.lookup(Int(at / page))
                        if phys != 0, pmm.isLoaned(phys) { return false }
                        at += page
                    }
                }
                record.pointee.everPinned = true
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

    /// The largest VMO (Zircon's VmObject::MAX_SIZE: 2^64 rounded down to
    /// its page lists' 16-page nodes), and an UNBOUNDED one's size (K14i).
    /// Every page round-up below it stays in range.
    static var maxSize: UInt64 { 0xFFFF_FFFF_FFFF_0000 }

    /// vmo_create's and pager_create_vmo's size (Zircon's
    /// parse_create_syscall_flags): RESIZABLE with UNBOUNDED INVALID_ARGS;
    /// UNBOUNDED `maxSize`, else `size` rounded up to a page (OUT_OF_RANGE
    /// on overflow or past `maxSize`); OUT_OF_RANGE if the content size
    /// would pass it.
    static func createSize(_ size: UInt64, unbounded: Bool, resizable: Bool) throws(Status) -> UInt64 {
        if resizable, unbounded { throw .invalidArgs }
        if unbounded {
            guard size <= maxSize else { throw .outOfRange }
            return maxSize
        }
        let mask = KernelLayout.pageSize - 1
        guard size <= UInt64.max - mask, (size + mask) & ~mask <= maxSize else { throw .outOfRange }
        return (size + mask) & ~mask
    }
    private static let traceIds = Atomic<UInt64>(0)

    static func nextTraceId() -> UInt64 {
        traceIds.add(1, ordering: .relaxed).newValue
    }
}

extension VmoPointer {
    /// The VMO's own page holding byte `offset`, if it has one (no
    /// commit, no parent's): lock held. A contiguous VMO's lent page is
    /// absent (K14f); past the end, nothing.
    func ownLocked(at offset: UInt64) -> UInt64? {
        guard offset < pointee.size else { return nil }
        let index = Int(offset / KernelLayout.pageSize)
        switch pointee.kind {
        case .physical(let base): return base + UInt64(index) * KernelLayout.pageSize
        case .contiguous(let base): return lentLocked(index) ? nil : base + UInt64(index) * KernelLayout.pageSize
        case .anonymous:
            let phys = pointee.pages.lookup(index)
            return phys == 0 ? nil : phys
        }
    }
}

/// Copies between user memory and a VMO's pages (vmo_read/write, streams,
/// process_read/write_memory; K14h). A page is only read or written while
/// the lock of the VMO that has it is held, so a decommit, eviction, swap
/// or resize can't free it (and hand it to someone else) mid-copy, which
/// a copy after dropping the lock allowed. Under that spinlock user memory
/// can't be paged in, so the copy runs without (`UserCopy.*NoPageIn`): a
/// chunk that faults is `.faulted`, and the caller pages the user range
/// in (`pageIn`) with no lock held and tries again. Callers resolve
/// aliases first and make pages present (pagers, lent pages) as before.
enum VmoUserCopy {
    enum Chunk {
        case copied
        /// No page there: zeros for a reader; commit one and retry.
        case absent
        /// The user side faulted: page it in and retry.
        case faulted
    }

    /// `length` bytes (inside one page) from what `vmo` reads as at
    /// `offset` (its page or an ancestor's) to user `user`.
    static func read(_ vmo: VmoPointer, _ offset: UInt64, to user: UInt64, _ length: UInt64) -> Chunk {
        vmo.withContent(at: offset) { phys -> Chunk in
            guard let phys else { return .absent }
            let kernel = KernelLayout.physmap(phys) + offset % KernelLayout.pageSize
            let failed = unsafe UserCopy.toNoPageIn(user, UnsafeRawPointer(bitPattern: UInt(kernel))!, length)
            return failed == 0 ? .copied : .faulted
        }
    }

    /// `length` bytes (inside one page) from user `user` into `vmo`'s own
    /// page at `offset`.
    static func write(_ vmo: VmoPointer, _ offset: UInt64, from user: UInt64, _ length: UInt64) -> Chunk {
        let (vmo, shift) = vmo.target
        let at = offset + shift
        return vmo.pointee.lock.withLock { () -> Chunk in
            guard let phys = vmo.ownLocked(at: at) else { return .absent }
            let kernel = KernelLayout.physmap(phys) + at % KernelLayout.pageSize
            let failed = unsafe UserCopy.fromNoPageIn(UnsafeMutableRawPointer(bitPattern: UInt(kernel))!, user, length)
            return failed == 0 ? .copied : .faulted
        }
    }

    /// Pages [user, +length) in for the kernel to read (`write` false) or
    /// write, as a fault there would. False: not mapped for that.
    static func pageIn(_ user: UInt64, _ length: UInt64, write: Bool) -> Bool {
        guard length > 0 else { return true }
        // User addresses only (review fix: `user + length` trapped for a
        // buffer near 2^64, from streams and vmo_read/write).
        guard user < UserLayout.top, length <= UserLayout.top - user else { return false }
        let page = KernelLayout.pageSize
        var at = user & ~(page - 1)
        while at < user + length {
            guard UserAspaces.handleFault(at: at, write: write, execute: false) else { return false }
            at += page
        }
        return true
    }

    /// `length` zeros to user `user` (a read of a zero interval's page,
    /// K14k, which commits nothing).
    static func zeros(to user: UInt64, _ length: UInt64) -> Chunk {
        var zeros = InlineArray<256, UInt8>(repeating: 0)
        var span = zeros.mutableSpan
        var done: UInt64 = 0
        while done < length {
            let piece = min(length - done, 256)
            let failed = span.withUnsafeMutableBytes { unsafe UserCopy.to(user + done, UnsafeRawPointer($0.baseAddress!), piece) }
            guard failed == 0 else { return .faulted }
            done += piece
        }
        return .copied
    }

    /// After `.absent`: commits the page so the next try finds it (a read
    /// of an untouched page commits it, as vmo_read always has), or returns
    /// to try again when the next `Pagers.ensure*` makes it present (a
    /// pager's page, a lent one, gone again meanwhile). Throws NOT_FOUND
    /// for a discarded VMO (K14a), OUT_OF_RANGE past a shrunk end (K13h),
    /// NO_MEMORY otherwise.
    static func commit(_ vmo: VmoPointer, _ offset: UInt64) throws(Status) {
        let (vmo, shift) = vmo.target
        let at = offset + shift
        let index = Int(at / KernelLayout.pageSize)
        for _ in 0..<4 {
            guard vmo.commit(at: at) == nil else { return }
            if vmo.pointee.discard == .discarded { throw .notFound }
            if at >= vmo.pointee.size { throw .outOfRange }
            // A pager VMO's page, judged in one look under its lock:
            // present (supplied since commit looked) or the pager's (the
            // next ensure waits for it) is tried again; only a zero
            // interval's page, which commit allocates, failed. Review 2:
            // separate looks raced a supply, ZERO and writeback (check 740's
            // stress) into NO_MEMORY.
            if vmo.pointee.pager != nil {
                let zeroFailed = vmo.pointee.lock.withLock { () -> Bool in
                    vmo.pointee.pages.lookup(index) == 0 && !vmo.pointee.zeros.isEmpty && vmo.zeroStateLocked(at) != nil
                }
                if !zeroFailed { return }
                continue  // a zero interval now: commit allocates there, once more
            }
            if vmo.pagerGap(at: at) != nil || vmo.lookup(at: at) != nil { return }  // a child reading through
            if vmo.pointee.lentPages > 0, vmo.pointee.lock.withLock({ vmo.lentLocked(index) }) { return }
            break
        }
        throw .noMemory
    }

    /// How often one chunk may fault and be paged in before the copy is
    /// refused: a page evicted again at once is retried; a fault paging
    /// can't fix (a protection key's) would loop.
    static let attempts = 4
}
