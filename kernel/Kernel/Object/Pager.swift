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
/// wakes every waiter to BAD_STATE and queues COMPLETE; the pager's last
/// handle detaches every VMO without one.
///
/// Requests: each waiter needs one page (`PageWaiter`); a new one starts
/// an outstanding range (`PageRange`) from its page up to its read-ahead,
/// cut before the first present page and before the next outstanding
/// range, and queues one packet for it; a waiter whose page is already in
/// an outstanding range joins it with no packet (Zircon's overlap). A
/// supply trims the ranges and wakes the waiters whose pages arrived; a
/// FAIL drops the overlapping ranges, failing the waiters inside its range
/// and waking the others to ask again. A range no waiter needs any more
/// (killed, timed out after 300 s, Zircon's overtime limit) goes.
///
/// Differences from Zircon: a packet per request, allocated at the
/// request and freed when read (Zircon keeps one per VMO in flight and
/// queues the next when it is read, and withdraws packets for requests
/// resolved before they were read); the source holds the port, so closing
/// the port's handles doesn't free queued packets.
///
/// Lock order: pager -> source -> vmo, and source -> port packets ->
/// scheduler (packets are queued under the source lock, so a COMPLETE
/// never overtakes a READ).
struct PageRange {
    var offset: UInt64
    var end: UInt64
}

struct PageWaiter: ~Copyable {
    let offset: UInt64
    /// 1 while waiting; then 0 (look again) or a status.
    let status = Atomic<Int32>(1)
}

struct PagerSource: ~Copyable {
    let lock = SpinLock()
    /// The VMO's and the pager's list's.
    let references = Atomic<Int>(2)
    /// The pager object (no reference), 0 once it has gone.
    var pager: UInt64
    let pagerKoid: UInt64
    let port: ObjectPointer
    let key: UInt64
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
        if pointee.pager != nil { return (self, offset) }
        guard let parent = pointee.parent else { return nil }
        return parent.pagerGap(at: pointee.parentOffset + offset)
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
            source.pointee.lock.withLock { source.pointee.pager = 0 }
            detach(source, complete: false)
            source.release()
        }
        Objects.free(object, as: PagerObject.self)
    }

    /// pager_create_vmo's VMO: `size` (rounded to pages) bytes from `pager`,
    /// requests to `port` with `key`. The port reference is the source's.
    static func createVmo(_ pager: ObjectPointer, port: ObjectPointer, key: UInt64,
                          size: UInt64) throws(Status) -> ObjectPointer {
        let pageMask = KernelLayout.pageSize - 1
        let vmo: Vmo
        do throws(VmError) {
            vmo = try Vmo(anonymous: (size + pageMask) & ~pageMask)
        } catch {
            throw error == .invalidArgument ? .invalidArgs : .noMemory
        }
        guard let raw = unsafe heap.allocate(size: MemoryLayout<PagerSource>.size, alignment: 16) else { throw .noMemory }
        port.retain()
        unsafe raw.bindMemory(to: PagerSource.self, capacity: 1).initialize(
            to: PagerSource(pager: pager.address, pagerKoid: pager.header.koid, port: port, key: key))
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
        if size & pageMask != 0 { vmo.record.pointee.streamSize = size }
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
        let page = KernelLayout.pageSize
        let at = offset & ~(page - 1)
        let (last, overflow) = offset.addingReportingOverflow(max(readAhead, 1) - 1)
        var ahead = overflow ? maxRequest : (last & ~(page - 1)) + page - at
        while let (root, rootOffset) = vmo.pagerGap(at: at) {
            try wait(root, rootOffset, length: min(ahead, maxRequest))
            ahead = page
        }
    }

    /// `ensure` for every page of [offset, offset+size) (page aligned).
    static func ensureRange(_ vmo: VmoPointer, _ offset: UInt64, _ size: UInt64) throws(Status) {
        guard vmo.pointee.pager != nil || vmo.pointee.readsFromPager else { return }
        var at = offset
        while at < offset + size {
            try ensure(vmo, at, readAhead: offset + size - at)
            at += KernelLayout.pageSize
        }
    }

    private static func wait(_ root: VmoPointer, _ offset: UInt64, length: UInt64) throws(Status) {
        guard let source = root.pointee.pager else { return }
        let page = KernelLayout.pageSize
        guard let raw = unsafe heap.allocate(size: MemoryLayout<PageWaiter>.size) else { throw .noMemory }
        unsafe raw.bindMemory(to: PageWaiter.self, capacity: 1).initialize(to: PageWaiter(offset: offset))
        let waiter = UInt64(UInt(bitPattern: raw))
        let me = unsafe UnsafeMutablePointer<PageWaiter>(bitPattern: UInt(waiter))!
        defer {
            unsafe me.deinitialize(count: 1)
            unsafe heap.free(raw)
        }
        let packet = try? QueuedPacketPointer.allocate(PortPacket(key: source.pointee.key, type: PortPacket.pageRequest))
        var used = false
        // nil: registered; 0: present after all; else a status.
        let early = source.pointee.lock.withLock { () -> Int32? in
            if root.lookup(at: offset) != nil { return 0 }
            if source.pointee.detached { return Status.badState.rawValue }
            var covered = false
            var end = min(offset + length, root.pointee.size)
            for i in 0..<source.pointee.ranges.count {
                let range = source.pointee.ranges[i]
                if range.offset <= offset, offset < range.end { covered = true }
                if range.offset > offset { end = min(end, range.offset) }
            }
            if !covered {
                guard let packet else { return Status.noMemory.rawValue }
                var cut = offset + page
                while cut < end, root.lookup(at: cut) == nil { cut += page }
                source.pointee.ranges.append(PageRange(offset: offset, end: cut))
                packet.pointee.packet.payload[0] = UInt64(CROI_PAGER_VMO_READ)
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

    /// Outstanding ranges no waiter's page is in any more. Source locked.
    private static func dropUnneededLocked(_ source: PagerSourcePointer) {
        var i = 0
        while i < source.pointee.ranges.count {
            let range = source.pointee.ranges[i]
            var needed = false
            for j in 0..<source.pointee.waiters.count {
                let offset = unsafe UnsafePointer<PageWaiter>(bitPattern: UInt(source.pointee.waiters[j]))!.pointee.offset
                if range.offset <= offset, offset < range.end { needed = true }
            }
            if needed { i += 1 } else { _ = source.pointee.ranges.remove(at: i) }
        }
    }

    /// Takes out the waiters `decide` gives a status for, setting it. Source locked.
    private static func resolveLocked(_ source: PagerSourcePointer, _ decide: (UInt64) -> Int32?) {
        var i = 0
        while i < source.pointee.waiters.count {
            let pointer = unsafe UnsafePointer<PageWaiter>(bitPattern: UInt(source.pointee.waiters[i]))!
            if let status = decide(unsafe pointer.pointee.offset) {
                _ = source.pointee.waiters.remove(at: i)
                unsafe pointer.pointee.status.store(status, ordering: .releasing)
            } else {
                i += 1
            }
        }
    }

    private static func wakeWaiters(_ source: PagerSourcePointer) {
        Scheduler.locked { _ = Scheduler.wakeAll(source.pointee.queue) }
    }

    // MARK: The pager's operations

    /// Detaches: waiters retry (and find BAD_STATE); COMPLETE queued once
    /// if `complete`. Pages stay.
    static func detach(_ source: PagerSourcePointer, complete: Bool) {
        let packet = complete ? try? QueuedPacketPointer.allocate(PortPacket(key: source.pointee.key, type: PortPacket.pageRequest)) : nil
        var used = false
        source.pointee.lock.withLock {
            source.pointee.detached = true
            source.pointee.ranges.removeAll()
            resolveLocked(source) { _ in 0 }
            if !source.pointee.completeSent {
                source.pointee.completeSent = true
                if let packet {
                    packet.pointee.packet.payload[0] = UInt64(CROI_PAGER_VMO_COMPLETE)
                    Ports.enqueue(PortPointer(object: source.pointee.port), packet)
                    used = true
                }
            }
        }
        if !used { packet?.free() }
        wakeWaiters(source)
    }

    /// A pager VMO's last reference went.
    static func vmoGone(_ source: PagerSourcePointer) {
        detach(source, complete: true)
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
    /// in where the VMO has none; the rest are freed.
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
            var trimmed = UniqueArray<PageRange>()
            for i in 0..<source.pointee.ranges.count {
                let range = source.pointee.ranges[i]
                if range.end <= offset || end <= range.offset {
                    trimmed.append(range)
                    continue
                }
                if range.offset < offset { trimmed.append(PageRange(offset: range.offset, end: offset)) }
                if end < range.end { trimmed.append(PageRange(offset: end, end: range.end)) }
            }
            swap(&trimmed, &source.pointee.ranges)
            resolveLocked(source) { at in vmo.lookup(at: at) != nil ? 0 : nil }
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
            resolveLocked(source) { at in
                if offset <= at, at < end { return status }
                for j in 0..<dropped.count where dropped[j].offset <= at && at < dropped[j].end { return 0 }
                return nil
            }
        }
        wakeWaiters(source)
    }
}
