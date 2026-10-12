import CKernel
import Synchronization

/// The user pager (K13d; Zircon's PagerDispatcher, PagerProxy and
/// PageSource, type 28): a pager VMO's pages come from user space. Reading
/// a page the VMO doesn't have (a fault, vmo_read, a stream, a commit, a
/// pin, a snapshot child reading through) queues a READ request on the
/// VMO's port and waits until the pager supplies the page
/// (pager_supply_pages, which moves pages in from an anonymous VMO) or
/// fails it (pager_op_range FAIL with an I/O-class status, which the
/// waiter gets). Detaching (pager_detach_vmo, or the VMO's last reference)
/// wakes every waiter to BAD_STATE, drops the clean pages and queues
/// COMPLETE; the pager's last handle detaches every VMO without one.
///
/// Dirty tracking (part 2): each present page is clean, dirty or awaiting
/// clean (`VmoRecord.states`). A clean page is mapped read only even
/// where the mapping may write, so the first write faults; the write (and
/// every kernel write: vmo_write, streams, ZERO) goes through
/// `prepareWrite`, which makes the page dirty, first asking the pager with
/// a DIRTY request if the VMO was created with TRAP_DIRTY (the pager's
/// op DIRTY answers it). WRITEBACK_BEGIN turns dirty pages awaiting clean
/// and unmaps them, so a write during the writeback dirties them again;
/// WRITEBACK_END cleans what is still awaiting clean. query_dirty_ranges
/// reports every page not clean; query_vmo_stats whether anything was
/// written. croi has no zero intervals: IS_ZERO writeback has nothing to do.
///
/// Requests: each waiter needs one page, read or made dirty
/// (`PageWaiter`); a new one starts an outstanding range (`PageRange`) of
/// its kind from its page up to its read-ahead, cut before a page that
/// doesn't need it and before the next outstanding range, and queues one
/// packet for it; a waiter whose page is already in an outstanding range
/// joins it with no packet (Zircon's overlap). A supply or op DIRTY trims
/// the ranges and wakes the waiters it satisfied; a FAIL drops the
/// overlapping ranges, failing the waiters inside its range and waking the
/// others to ask again. A range no waiter needs any more (killed, or timed
/// out after 300 s, Zircon's overtime limit) goes.
///
/// Differences from Zircon: a packet per request, allocated at the
/// request and freed when read (Zircon keeps one per VMO in flight and
/// queues the next when it is read, and withdraws packets for requests
/// resolved before they were read); the source holds the port, so closing
/// the port's handles doesn't free queued packets.
///
/// Lock order: pager -> source -> vmo, and source -> port packets ->
/// scheduler (packets are queued under the source lock, so a COMPLETE
/// never overtakes a request).
struct PageRange {
    var offset: UInt64
    var end: UInt64
    var dirty: Bool
    /// query_dirty_ranges: grown space never written (IS_ZERO, K13h).
    var zero = false
}

struct PageWaiter: ~Copyable {
    let offset: UInt64
    let dirty: Bool
    /// 1 while waiting; then 0 (look again) or a status.
    let status = Atomic<Int32>(1)
}

/// A pager VMO page's state in `VmoRecord.states` (absent: clean).
enum PageDirt {
    static var dirty: UInt64 { 1 }
    static var awaitingClean: UInt64 { 2 }
}

struct PagerSource: ~Copyable {
    let lock = SpinLock()
    /// The VMO's and the pager's list's.
    let references = Atomic<Int>(2)
    /// The pager object (no reference), 0 once it has gone.
    var pager: UInt64
    let pagerKoid: UInt64
    /// The VMO (no reference), 0 once its last reference went.
    var vmo: UInt64 = 0
    let port: ObjectPointer
    let key: UInt64
    let trapDirty: Bool
    var detached = false
    var completeSent = false
    var ranges = UniqueArray<PageRange>()
    var waiters = UniqueArray<UInt64>()
    let queue = QueuePointer.allocate()
}

@safe struct PagerSourcePointer: Equatable {
    let address: UInt64

    var pointee: PagerSource {
        unsafeAddress { unsafe UnsafePointer<PagerSource>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<PagerSource>(bitPattern: UInt(address))! }
    }

    func release() {
        guard pointee.references.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 else { return }
        pointee.port.release()
        pointee.queue.deallocate()
        let raw = unsafe UnsafeMutablePointer<PagerSource>(bitPattern: UInt(address))!
        unsafe raw.deinitialize(count: 1)
        unsafe heap.free(UnsafeMutableRawPointer(raw))
    }
}

struct PagerObject: ~Copyable {
    var header = ObjectHeader(type: .pager)
    let lock = SpinLock()
    /// Every attached VMO's source (a reference each).
    var sources = UniqueArray<UInt64>()

    /// ZX_DEFAULT_PAGER_RIGHTS: INSPECT, TRANSFER, ATTACH_VMO, MANAGE_VMO.
    static var defaultRights: Rights { .inspect | .transfer | .attachVmo | .manageVmo }
}

@safe struct PagerPointer {
    let object: ObjectPointer

    var pointee: PagerObject {
        unsafeAddress { unsafe UnsafePointer<PagerObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<PagerObject>(bitPattern: UInt(object.address))! }
    }
}

extension VmoPointer {
    /// The pager-backed VMO and offset whose missing page byte `offset`
    /// would read as (its own, or a snapshot ancestor's), if any.
    func pagerGap(at offset: UInt64) -> (VmoPointer, UInt64)? {
        guard offset < pointee.size, pointee.pager != nil || pointee.readsFromPager else { return nil }
        if lookup(at: offset) != nil { return nil }
        if pointee.pager != nil {
            // Grown space is zeros nobody is asked for (K13h).
            return offset >= pointee.lock.withLock({ pointee.pagerZeroFrom }) ? nil : (self, offset)
        }
        guard offset < pointee.parentLimit, let parent = pointee.parent else { return nil }  // K14g
        return parent.pagerGap(at: pointee.parentOffset + offset)
    }

    /// A pager VMO page's state (PageDirt; 0 clean). VMO lock held.
    func dirtLocked(_ offset: UInt64) -> UInt64 {
        pointee.states.lookup(Int(offset / KernelLayout.pageSize))
    }

    /// Calls `body(offset, state)` for each page of [offset, end) not
    /// clean, found sparsely (K14i). VMO lock held; `body` may change the
    /// state of the page it is given.
    func forEachStateLocked(_ offset: UInt64, _ end: UInt64, _ body: (UInt64, UInt64) -> Void) {
        let page = KernelLayout.pageSize
        var i = Int(offset / page)
        let last = Int((end + page - 1) / page)
        while let (index, state) = pointee.states.next(from: i, before: last) {
            body(UInt64(index) * page, state)
            i = index + 1
        }
    }

    func setDirtLocked(_ offset: UInt64, _ state: UInt64) {
        let index = Int(offset / KernelLayout.pageSize)
        if state == 0 {
            _ = pointee.states.clear(index)
        } else if !pointee.states.set(index, state) {
            panic("pager: no memory for page states")  // a node per 512 pages
        }
    }

    /// Another reference, unless the last one already went.
    func tryRetain() -> Bool {
        var current = pointee.references.load(ordering: .relaxed)
        while current > 0 {
            let (exchanged, original) = pointee.references.compareExchange(
                expected: current, desired: current + 1, ordering: .acquiringAndReleasing)
            if exchanged { return true }
            current = original
        }
        return false
    }
}

enum Pagers {
    static var maxRequest: UInt64 { 256 * KernelLayout.pageSize }
    static var overtime: UInt64 { 300_000_000_000 }

    static func create() throws(Status) -> ObjectPointer {
        guard let object = Objects.allocate(PagerObject()) else { throw .noMemory }
        return object
    }

    /// Its last reference: every VMO detached, no COMPLETE.
    static func destroy(_ object: ObjectPointer) {
        let pager = PagerPointer(object: object)
        var sources = UniqueArray<UInt64>()
        pager.pointee.lock.withLock { swap(&sources, &pager.pointee.sources) }
        while let address = sources.popLast() {
            let source = PagerSourcePointer(address: address)
            let vmo = source.pointee.lock.withLock { () -> VmoPointer? in
                source.pointee.pager = 0
                let vmo = VmoPointer(address: source.pointee.vmo)
                return source.pointee.vmo != 0 && vmo.tryRetain() ? vmo : nil
            }
            detach(source, vmo: vmo, complete: false)
            vmo?.release()
            source.release()
        }
        Objects.free(object, as: PagerObject.self)
    }

    /// pager_create_vmo's VMO: `size` (rounded to pages) bytes from `pager`,
    /// requests to `port` with `key`. The port reference is the source's.
    static func createVmo(_ pager: ObjectPointer, port: ObjectPointer, key: UInt64, size: UInt64, vmoSize: UInt64,
                          trapDirty: Bool, resizable: Bool = false) throws(Status) -> ObjectPointer {
        let vmo: Vmo
        do throws(VmError) {
            vmo = try Vmo(anonymous: vmoSize)
        } catch {
            throw error == .invalidArgument ? .invalidArgs : .noMemory
        }
        guard let raw = unsafe heap.allocate(size: MemoryLayout<PagerSource>.size, alignment: 16) else { throw .noMemory }
        port.retain()
        unsafe raw.bindMemory(to: PagerSource.self, capacity: 1).initialize(
            to: PagerSource(pager: pager.address, pagerKoid: pager.header.koid, vmo: vmo.record.address, port: port,
                            key: key, trapDirty: trapDirty))
        let source = PagerSourcePointer(address: UInt64(UInt(bitPattern: raw)))
        let attached = PagerPointer(object: pager).pointee.lock.withLock { () -> Bool in
            guard pager.header.handleCount.load(ordering: .relaxed) > 0 else { return false }
            PagerPointer(object: pager).pointee.sources.append(source.address)
            return true
        }
        guard attached else {
            source.release(); source.release()
            throw .badState
        }
        vmo.record.pointee.pager = source
        vmo.record.pointee.resizable = resizable
        vmo.record.pointee.states = PageList(pages: vmo.record.pointee.pageCount)
        if size != vmoSize { vmo.record.pointee.streamSize = size }  // unaligned, or UNBOUNDED (K14i)
        Reclaim.register(vmo.record)  // K14a: its clean pages may be evicted
        return try VmoObject.wrap(vmo.record)
    }

    /// The pager-backed VMO behind `handle` (rights checked) if `pager`
    /// is its pager; else INVALID_ARGS (Zircon's koid check).
    static func vmo(_ table: borrowing HandleTable, _ handle: UInt32, rights: Rights,
                    of pager: ObjectPointer) throws(Status) -> ObjectRef {
        let ref = try table.get(handle, type: .vmo, rights: rights)
        let vmo = VmoPointer(address: UnsafeVmoObject(ref.object).vmo)
        guard let source = vmo.pointee.pager, source.pointee.pagerKoid == pager.header.koid else { throw .invalidArgs }
        return ref
    }

    // MARK: Waiting

    /// Makes sure byte `offset` of `vmo` can be read without a pager (its
    /// page, or an ancestor's, present): requests and waits as needed,
    /// asking for up to `readAhead` bytes from there. Throws the pager's
    /// failure, BAD_STATE once detached, TIMED_OUT, or CANCELED (killed).
    static func ensure(_ vmo: VmoPointer, _ offset: UInt64, readAhead: UInt64 = KernelLayout.pageSize) throws(Status) {
        Loans.ensure(vmo, offset, readAhead)  // K14f: a contiguous VMO's lent pages
        let page = KernelLayout.pageSize
        let at = offset & ~(page - 1)
        let (last, overflow) = offset.addingReportingOverflow(max(readAhead, 1) - 1)
        var ahead = overflow ? maxRequest : (last & ~(page - 1)) + page - at
        while let (root, rootOffset) = vmo.pagerGap(at: at) {
            try wait(root, rootOffset, length: min(ahead, maxRequest), dirty: false)
            ahead = page
        }
    }

    /// `ensure` for every page of [offset, offset+size) (page aligned).
    static func ensureRange(_ vmo: VmoPointer, _ offset: UInt64, _ size: UInt64) throws(Status) {
        Loans.ensure(vmo, offset, size)
        guard vmo.pointee.pager != nil || vmo.pointee.readsFromPager else { return }
        var at = offset
        while at < offset + size {
            try ensure(vmo, at, readAhead: offset + size - at)
            at += KernelLayout.pageSize
        }
    }

    /// Before writing byte `offset` of `vmo` (present: `ensure` first): a
    /// pager VMO's page becomes dirty, with the pager's leave first under
    /// TRAP_DIRTY (asking for the next `ahead` bytes' pages too).
    static func prepareWrite(_ vmo: VmoPointer, _ offset: UInt64, ahead: UInt64 = KernelLayout.pageSize) throws(Status) {
        guard let source = vmo.pointee.pager else { return }
        let page = KernelLayout.pageSize
        let at = offset & ~(page - 1)
        while true {
            var borrowed = false
            let done = vmo.pointee.lock.withLock { () -> Bool? in
                let phys = vmo.pointee.pages.lookup(Int(at / page))
                guard phys != 0 else { return nil }
                // K14f: a borrowed page is swapped for an ordinary one before
                // it is dirtied (giving it back means dropping it).
                if pmm.isLoaned(phys) {
                    borrowed = true
                    return false
                }
                vmo.pointee.modified = true
                if vmo.dirtLocked(at) == PageDirt.dirty { return true }
                guard !source.pointee.trapDirty else { return false }
                vmo.setDirtLocked(at, PageDirt.dirty)
                return true
            }
            if borrowed {
                guard Loans.unborrow(vmo, at) else { throw .noMemory }
                continue
            }
            switch done {
            case true: return
            case false: try wait(vmo, at, length: min(max(ahead, page), maxRequest), dirty: true)
            case nil: try ensure(vmo, at)  // gone (detach dropped it): BAD_STATE
            }
        }
    }

    /// `ensureWritable` for every page of [offset, offset+size) (page aligned).
    static func ensureWritableRange(_ vmo: VmoPointer, _ offset: UInt64, _ size: UInt64) throws(Status) {
        Loans.ensure(vmo, offset, size)
        guard vmo.pointee.pager != nil || vmo.pointee.readsFromPager else { return }
        var at = offset
        while at < offset + size {
            try ensureWritable(vmo, at, ahead: offset + size - at)
            at += KernelLayout.pageSize
        }
    }

    /// `ensure`, then `prepareWrite` (kernel writers of [offset, +length)).
    static func ensureWritable(_ vmo: VmoPointer, _ offset: UInt64, ahead: UInt64) throws(Status) {
        try ensure(vmo, offset, readAhead: ahead)
        try prepareWrite(vmo, offset, ahead: ahead)
    }

    /// Whether `root`'s page at `offset` is what a waiter of this kind
    /// waits for (read: present; dirty: dirty). Source locked.
    private static func satisfied(_ root: VmoPointer, _ offset: UInt64, dirty: Bool) -> Bool {
        root.pointee.lock.withLock { () -> Bool in
            let present = root.pointee.pages.lookup(Int(offset / KernelLayout.pageSize)) != 0
            return dirty ? !present || root.dirtLocked(offset) == PageDirt.dirty : present
        }
    }

    private static func wait(_ root: VmoPointer, _ offset: UInt64, length: UInt64, dirty: Bool) throws(Status) {
        guard let source = root.pointee.pager else { return }
        let page = KernelLayout.pageSize
        guard let raw = unsafe heap.allocate(size: MemoryLayout<PageWaiter>.size) else { throw .noMemory }
        unsafe raw.bindMemory(to: PageWaiter.self, capacity: 1).initialize(to: PageWaiter(offset: offset, dirty: dirty))
        let waiter = UInt64(UInt(bitPattern: raw))
        let me = unsafe UnsafeMutablePointer<PageWaiter>(bitPattern: UInt(waiter))!
        defer {
            unsafe me.deinitialize(count: 1)
            unsafe heap.free(raw)
        }
        let packet = try? QueuedPacketPointer.allocate(PortPacket(key: source.pointee.key, type: PortPacket.pageRequest))
        var used = false
        // nil: registered; 0: satisfied after all; else a status.
        let early = source.pointee.lock.withLock { () -> Int32? in
            if satisfied(root, offset, dirty: dirty) { return 0 }
            if source.pointee.detached { return Status.badState.rawValue }
            var covered = false
            var end = min(offset + length, root.pointee.size)
            for i in 0..<source.pointee.ranges.count where source.pointee.ranges[i].dirty == dirty {
                let range = source.pointee.ranges[i]
                if range.offset <= offset, offset < range.end { covered = true }
                if range.offset > offset { end = min(end, range.offset) }
            }
            if !covered {
                guard let packet else { return Status.noMemory.rawValue }
                var cut = offset + page
                while cut < end, !satisfied(root, cut, dirty: dirty),
                      !dirty || root.lookup(at: cut) != nil {  // DIRTY: a run of present pages
                    cut += page
                }
                source.pointee.ranges.append(PageRange(offset: offset, end: cut, dirty: dirty))
                packet.pointee.packet.payload[0] = UInt64(dirty ? CROI_PAGER_VMO_DIRTY : CROI_PAGER_VMO_READ)
                packet.pointee.packet.payload[1] = offset
                packet.pointee.packet.payload[2] = cut - offset
                Ports.enqueue(PortPointer(object: source.pointee.port), packet)
                used = true
            }
            source.pointee.waiters.append(waiter)
            return nil
        }
        if !used { packet?.free() }
        if let early {
            guard early == 0 else { throw Status(rawValue: early) ?? .internalError }
            return
        }
        let deadline = Clock.now() + overtime
        var ending = Thread.WaitResult.woken
        Scheduler.locked {
            while unsafe me.pointee.status.load(ordering: .acquiring) == 1 {
                let result = Scheduler.block(on: source.pointee.queue, deadline: deadline, interruptible: true)
                if result != .woken {
                    ending = result
                    return
                }
            }
        }
        if unsafe me.pointee.status.load(ordering: .acquiring) == 1 {
            // Killed or overtime: leave, unless a waker already took us out.
            source.pointee.lock.withLock {
                for i in 0..<source.pointee.waiters.count where source.pointee.waiters[i] == waiter {
                    _ = source.pointee.waiters.remove(at: i)
                    unsafe me.pointee.status.store(ending == .interrupted ? Status.canceled.rawValue : Status.timedOut.rawValue,
                                                   ordering: .releasing)
                    dropUnneededLocked(source)
                    break
                }
            }
        }
        let status = unsafe me.pointee.status.load(ordering: .acquiring)
        guard status == 0 else { throw Status(rawValue: status) ?? .internalError }
    }

    private static func waiter(_ address: UInt64) -> UnsafePointer<PageWaiter> {
        unsafe UnsafePointer<PageWaiter>(bitPattern: UInt(address))!
    }

    /// Outstanding ranges no waiter's page is in any more. Source locked.
    private static func dropUnneededLocked(_ source: PagerSourcePointer) {
        var i = 0
        while i < source.pointee.ranges.count {
            let range = source.pointee.ranges[i]
            var needed = false
            for j in 0..<source.pointee.waiters.count {
                let w = unsafe waiter(source.pointee.waiters[j])
                let (offset, dirty) = unsafe (w.pointee.offset, w.pointee.dirty)
                if dirty == range.dirty, range.offset <= offset, offset < range.end {
                    needed = true
                }
            }
            if needed { i += 1 } else { _ = source.pointee.ranges.remove(at: i) }
        }
    }

    /// Takes out the waiters `decide` gives a status for (by offset and
    /// kind), setting it. Source locked.
    private static func resolveLocked(_ source: PagerSourcePointer, _ decide: (UInt64, Bool) -> Int32?) {
        var i = 0
        while i < source.pointee.waiters.count {
            let pointer = unsafe waiter(source.pointee.waiters[i])
            if let status = unsafe decide(pointer.pointee.offset, pointer.pointee.dirty) {
                _ = source.pointee.waiters.remove(at: i)
                unsafe pointer.pointee.status.store(status, ordering: .releasing)
            } else {
                i += 1
            }
        }
    }

    /// Cuts [offset, end) out of the outstanding ranges of one kind. Source locked.
    private static func trimLocked(_ source: PagerSourcePointer, _ offset: UInt64, _ end: UInt64, dirty: Bool) {
        var trimmed = UniqueArray<PageRange>()
        for i in 0..<source.pointee.ranges.count {
            let range = source.pointee.ranges[i]
            if range.dirty != dirty || range.end <= offset || end <= range.offset {
                trimmed.append(range)
                continue
            }
            if range.offset < offset { trimmed.append(PageRange(offset: range.offset, end: offset, dirty: dirty)) }
            if end < range.end { trimmed.append(PageRange(offset: end, end: range.end, dirty: dirty)) }
        }
        swap(&trimmed, &source.pointee.ranges)
    }

    private static func wakeWaiters(_ source: PagerSourcePointer) {
        Scheduler.locked { _ = Scheduler.wakeAll(source.pointee.queue) }
    }

    // MARK: The pager's operations

    /// Detaches: waiters retry (and find BAD_STATE); the clean pages go
    /// (unmapped first; dirty, awaiting-clean and pinned ones stay, for
    /// the pager to write back) if `vmo` is given; COMPLETE queued once if
    /// `complete`.
    static func detach(_ source: PagerSourcePointer, vmo: VmoPointer?, complete: Bool) {
        let packet = complete ? try? QueuedPacketPointer.allocate(PortPacket(key: source.pointee.key, type: PortPacket.pageRequest)) : nil
        var used = false
        let first = source.pointee.lock.withLock { () -> Bool in
            let first = !source.pointee.detached
            source.pointee.detached = true
            source.pointee.ranges.removeAll()
            resolveLocked(source) { _, _ in 0 }
            if !source.pointee.completeSent {
                source.pointee.completeSent = true
                if let packet {
                    packet.pointee.packet.payload[0] = UInt64(CROI_PAGER_VMO_COMPLETE)
                    Ports.enqueue(PortPointer(object: source.pointee.port), packet)
                    used = true
                }
            }
            return first
        }
        if !used { packet?.free() }
        wakeWaiters(source)
        guard first, let vmo, vmo.pointee.size > 0 else { return }
        var dropped = UniqueArray<UInt64>()
        vmo.pointee.lock.withLock {
            let page = KernelLayout.pageSize
            var i = 0
            while let (index, _) = vmo.pointee.pages.next(from: i, before: vmo.pointee.pageCount) {  // sparse (K14i)
                i = index + 1
                let at = UInt64(index) * page
                guard vmo.dirtLocked(at) == 0, !vmo.pinnedLocked(at, page) else { continue }
                dropped.append(vmo.pointee.pages.clear(index))
                vmo.pointee.committedPages -= 1
            }
        }
        vmo.unmapEverywhere(0, vmo.pointee.size)
        for i in 0..<dropped.count { pmm.free(dropped[i]) }
        vmo.pointee.account?.uncharge(UInt64(dropped.count) * KernelLayout.pageSize)
    }

    /// A pager VMO's last reference went (its pages go with it).
    static func vmoGone(_ source: PagerSourcePointer) {
        source.pointee.lock.withLock { source.pointee.vmo = 0 }
        detach(source, vmo: nil, complete: true)
        let pagerAddress = source.pointee.lock.withLock { source.pointee.pager }
        if pagerAddress != 0 {
            let pager = ObjectPointer(address: pagerAddress)
            if pager.tryRetain() {
                let removed = PagerPointer(object: pager).pointee.lock.withLock { () -> Bool in
                    for i in 0..<PagerPointer(object: pager).pointee.sources.count
                    where PagerPointer(object: pager).pointee.sources[i] == source.address {
                        _ = PagerPointer(object: pager).pointee.sources.remove(at: i)
                        return true
                    }
                    return false
                }
                pager.release()
                if removed { source.release() }
            }
        }
        source.release()
    }

    /// pager_supply_pages after the checks: `pages` (one per page of the
    /// range, from the aux VMO; 0 for a gap there, supplied as zeros) go
    /// in, clean, where the VMO has none; the rest are freed.
    static func supply(_ vmo: VmoPointer, offset: UInt64, pages: consuming UniqueArray<UInt64>) throws(Status) {
        let page = KernelLayout.pageSize
        guard let source = vmo.pointee.pager else { throw .badState }
        for i in 0..<pages.count where pages[i] == 0 {
            guard let fresh = pmm.allocatePage(.vmo) else {
                for j in 0..<pages.count where pages[j] != 0 { pmm.free(pages[j]) }
                throw .noMemory
            }
            unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(fresh)))!
                .initializeMemory(as: UInt8.self, repeating: 0, count: Int(page))
            pages[i] = fresh
        }
        let detached = source.pointee.lock.withLock { source.pointee.detached }
        guard !detached else {
            for j in 0..<pages.count { pmm.free(pages[j]) }
            throw .badState
        }
        let first = Int(offset / page)
        vmo.pointee.lock.withLock {
            for i in 0..<pages.count {
                if vmo.pointee.pages.lookup(first + i) == 0, vmo.pointee.pages.set(first + i, pages[i]) {
                    vmo.pointee.committedPages += 1
                    pages[i] = 0
                }
            }
        }
        for i in 0..<pages.count where pages[i] != 0 { pmm.free(pages[i]) }
        let end = offset + UInt64(pages.count) * page
        source.pointee.lock.withLock {
            trimLocked(source, offset, end, dirty: false)
            resolveLocked(source) { at, dirty in !dirty && vmo.lookup(at: at) != nil ? 0 : nil }
        }
        wakeWaiters(source)
    }

    /// A resizable pager VMO shrank to `end` (K13h): requests past it go,
    /// and their waiters look again (finding the VMO ends first).
    static func cut(_ source: PagerSourcePointer, at end: UInt64) {
        source.pointee.lock.withLock {
            trimLocked(source, end, .max, dirty: false)
            trimLocked(source, end, .max, dirty: true)
            resolveLocked(source) { at, _ in at >= end ? 0 : nil }
        }
        wakeWaiters(source)
    }

    /// pager_op_range FAIL after the checks: waiters inside get `status`;
    /// others whose requests overlapped ask again.
    static func fail(_ vmo: VmoPointer, offset: UInt64, length: UInt64, status: Int32) throws(Status) {
        guard let source = vmo.pointee.pager else { throw .badState }
        let end = offset + length
        try source.pointee.lock.withLock { () throws(Status) in
            guard !source.pointee.detached else { throw .badState }
            var dropped = UniqueArray<PageRange>()
            var i = 0
            while i < source.pointee.ranges.count {
                let range = source.pointee.ranges[i]
                if range.offset < end, offset < range.end {
                    dropped.append(source.pointee.ranges.remove(at: i))
                } else {
                    i += 1
                }
            }
            resolveLocked(source) { at, dirty in
                if offset <= at, at < end { return status }
                for j in 0..<dropped.count
                where dropped[j].dirty == dirty && dropped[j].offset <= at && at < dropped[j].end {
                    return 0
                }
                return nil
            }
        }
        wakeWaiters(source)
    }

    /// pager_op_range DIRTY (range checked): every page present, else
    /// NOT_FOUND (the DIRTY requests there are still resolved: their
    /// waiters ask again); then all dirty, and their waiters go on.
    static func dirty(_ vmo: VmoPointer, offset: UInt64, length: UInt64) throws(Status) {
        guard let source = vmo.pointee.pager else { throw .badState }
        guard source.pointee.trapDirty else { throw .notSupported }
        let page = KernelLayout.pageSize
        let end = offset + length
        var result: Status? = nil
        source.pointee.lock.withLock {
            if source.pointee.detached {
                result = .badState
            } else {
                let complete = vmo.pointee.lock.withLock { () -> Bool in
                    var at = offset
                    while at < end {
                        guard vmo.pointee.pages.lookup(Int(at / page)) != 0 else { return false }
                        at += page
                    }
                    at = offset
                    while at < end {
                        vmo.setDirtLocked(at, PageDirt.dirty)
                        at += page
                    }
                    return true
                }
                if !complete { result = .notFound }
            }
            trimLocked(source, offset, end, dirty: true)
            resolveLocked(source) { at, dirty in dirty && offset <= at && at < end ? 0 : nil }
        }
        wakeWaiters(source)
        if let result { throw result }
    }

    /// WRITEBACK_BEGIN: dirty pages (not pinned) await clean, and are
    /// unmapped so the next write faults and dirties them again. With
    /// IS_ZERO only zero intervals would change (croi has none).
    static func writebackBegin(_ vmo: VmoPointer, offset: UInt64, length: UInt64, zeroRange: Bool) {
        guard !zeroRange, length > 0 else { return }
        let page = KernelLayout.pageSize
        vmo.pointee.lock.withLock {
            vmo.forEachStateLocked(offset, offset + length) { at, state in
                if state == PageDirt.dirty, !vmo.pinnedLocked(at, page) { vmo.setDirtLocked(at, PageDirt.awaitingClean) }
            }
        }
        vmo.unmapEverywhere(offset, length)
    }

    /// WRITEBACK_END: pages still awaiting clean are clean.
    static func writebackEnd(_ vmo: VmoPointer, offset: UInt64, length: UInt64) {
        vmo.pointee.lock.withLock {
            vmo.forEachStateLocked(offset, offset + length) { at, state in
                if state == PageDirt.awaitingClean { vmo.setDirtLocked(at, 0) }
            }
            // Grown zeros written back (K13h): from now on the pager's.
            let zeroFrom = vmo.pointee.pagerZeroFrom
            if offset <= zeroFrom, zeroFrom < offset + length {
                vmo.pointee.pagerZeroFrom = offset + length >= vmo.pointee.size ? .max : offset + length
            }
        }
    }

    /// query_dirty_ranges: the runs of pages not clean in [offset, end)
    /// (page aligned), as (offset, length).
    static func dirtyRanges(_ vmo: VmoPointer, offset: UInt64, end: UInt64) -> UniqueArray<PageRange> {
        let page = KernelLayout.pageSize
        var ranges = UniqueArray<PageRange>()
        // Pages not clean (`states` holds only those) and, where the VMO
        // grew (K13h), the pages never written there, in offset order;
        // both found sparsely (K14i: an UNBOUNDED VMO's range is huge).
        func add(_ ranges: inout UniqueArray<PageRange>, _ at: UInt64, _ length: UInt64, zero: Bool) {
            if ranges.count > 0, ranges[ranges.count - 1].end == at, ranges[ranges.count - 1].zero == zero {
                ranges[ranges.count - 1].end = at + length
            } else {
                ranges.append(PageRange(offset: at, end: at + length, dirty: true, zero: zero))
            }
        }
        vmo.pointee.lock.withLock {
            let last = Int((end + page - 1) / page)
            var dirty = Int(offset / page)
            var gap = Int(max(offset, vmo.pointee.pagerZeroFrom) / page)  // the next grown page not yet considered
            let grown = vmo.pointee.pagerZeroFrom < end
            while true {
                let nextDirty = vmo.pointee.states.next(from: dirty, before: last)
                let dirtyAt = nextDirty.map { $0.index } ?? last
                if grown, gap < dirtyAt {
                    // Grown pages before the next dirty one: the absent ones are zeros.
                    let present = vmo.pointee.pages.next(from: gap, before: dirtyAt)
                    let gapEnd = present.map { $0.index } ?? dirtyAt
                    if gapEnd > gap { add(&ranges, UInt64(gap) * page, UInt64(gapEnd - gap) * page, zero: true) }
                    gap = present.map { $0.index + 1 } ?? dirtyAt
                    continue
                }
                guard let (index, _) = nextDirty else { break }
                if vmo.pointee.pages.lookup(index) != 0 { add(&ranges, UInt64(index) * page, page, zero: false) }
                dirty = index + 1
                gap = max(gap, dirty)
            }
        }
        return ranges
    }

    /// query_vmo_stats: whether written since the last reset (reset if asked).
    static func modified(_ vmo: VmoPointer, reset: Bool) -> Bool {
        vmo.pointee.lock.withLock { () -> Bool in
            let modified = vmo.pointee.modified
            if reset { vmo.pointee.modified = false }
            return modified
        }
    }
}
