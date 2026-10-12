import CKernel
import Fmt
import Synchronization

/// Page reclamation (K14a), after Zircon's PageQueues, Evictor and
/// MemoryWatchdog, without their per-page queues: the reclaimable VMOs are
/// on one list and their pages carry an age.
///
/// - Reclaimable: a pager VMO's clean, unpinned pages (the pager supplies
///   them again on the next access), and a DISCARDABLE VMO, whole, while
///   it is unlocked.
/// - Ages (`Page.reclaimAge`): an access makes a page newest (0): a fault,
///   a lookup by the kernel (vmo_read, a child's copy, a pin), or the
///   accessed bit of a mapping, harvested before each aging pass and each
///   eviction. An aging pass (every `croi.reclaim.aging_ms`, default
///   15000, while any reclaimable VMO exists) adds one, up to 7. Ages 0
///   and 1 are never evicted (Zircon's two active queues).
/// - Eviction takes DONT_NEED pages first, then the oldest: ages 6 and 7
///   for the watchdog's eviction, down to 2 (and ALWAYS_NEED overridden)
///   at OOM. A discardable VMO goes when its first committed page's turn
///   comes (Zircon's). Pages are taken out of the VMO under its lock (only
///   pages nobody looked up since the choice), then unmapped everywhere,
///   then freed.
/// - Memory pressure (Zircon's watchdog): levels by free memory against
///   watermarks (`croi.oom.*`, Zircon's defaults: OOM 50 MiB, imminent OOM
///   +10, critical 150, warning 300, debounce 1), one kernel event per
///   level, exactly one signaled (system_get_event); a worse level is
///   signaled at once, a better one after the hysteresis (10 s). A worse
///   level at or below critical asks for eviction after a delay (5 s), to
///   the critical watermark + debounce; OOM evicts at once, newest and
///   hints included, then signals OOM and reboots (no HaltToken: after
///   `croi.oom.reboot_timeout_ms`, default 50000).
///
/// One kernel thread ("reclaim") ages, evicts and watches. The PMM tells
/// it when the free count leaves the band of the current level, through a
/// zero-delay timer (it may be told with any lock held).
enum Reclaim {
    // MARK: Pages

    static var maxAge: UInt8 { 7 }
    /// The newest age eviction may take (at OOM), and the watchdog's.
    static var newestEvictable: UInt8 { 2 }
    static var oldestAge: UInt8 { 6 }
    static var alwaysNeed: UInt8 { 1 }
    static var dontNeed: UInt8 { 2 }
    /// A DONT_NEED page's place in the eviction order: before every age.
    private static var dontNeedKey: UInt8 { 8 }

    /// An access: the page is newest again, and no longer DONT_NEED (as
    /// Zircon's MarkAccessed moves it out of the isolate list).
    static func touch(_ phys: UInt64) {
        guard let page = unsafe pmm.page(for: phys) else { return }
        unsafe page.pointee.reclaimAge = 0
        unsafe page.pointee.reclaimFlags &= ~dontNeed
    }

    /// Its place in the eviction order (DONT_NEED, else its age) and hints.
    private static func rank(_ phys: UInt64) -> (key: UInt8, flags: UInt8)? {
        guard let page = unsafe pmm.page(for: phys) else { return nil }
        let flags = unsafe page.pointee.reclaimFlags
        return (flags & dontNeed != 0 ? dontNeedKey : unsafe page.pointee.reclaimAge, flags)
    }

    // MARK: The reclaimable list

    /// Guards the list links only; a leaf (nothing else is taken under it
    /// but the heap, by `snapshot`).
    private static let registryLock = SpinLock()
    nonisolated(unsafe) private static var head: UInt64 = 0
    nonisolated(unsafe) private(set) static var registered = 0

    /// A pager VMO (at creation) or a discardable one.
    static func register(_ vmo: VmoPointer) {
        registryLock.withLock {
            vmo.pointee.reclaimable = true
            vmo.pointee.reclaimPrev = 0
            vmo.pointee.reclaimNext = head
            if head != 0 { VmoPointer(address: head).pointee.reclaimPrev = vmo.address }
            head = vmo.address
            registered += 1
        }
        wake()  // aging starts
    }

    /// Its last reference went (VmoPointer.release).
    static func unregister(_ vmo: VmoPointer) {
        registryLock.withLock {
            let next = vmo.pointee.reclaimNext, prev = vmo.pointee.reclaimPrev
            if prev != 0 { VmoPointer(address: prev).pointee.reclaimNext = next } else { head = next }
            if next != 0 { VmoPointer(address: next).pointee.reclaimPrev = prev }
            registered -= 1
        }
    }

    /// A reference to every live VMO on the list (the caller releases them).
    private static func snapshot() -> UniqueArray<UInt64> {
        var vmos = UniqueArray<UInt64>()
        registryLock.withLock {
            var at = head
            while at != 0 {
                let vmo = VmoPointer(address: at)
                if vmo.tryRetain() { vmos.append(at) }
                at = vmo.pointee.reclaimNext
            }
        }
        return vmos
    }

    private static func release(_ vmos: borrowing UniqueArray<UInt64>) {
        for i in 0..<vmos.count { VmoPointer(address: vmos[i]).release() }
    }

    // MARK: Aging

    static let agingPasses = Atomic<UInt64>(0)

    /// Moves the accessed bits of `vmo`'s mappings into its pages' ages
    /// (newest where set), clearing them.
    private static func harvest(_ vmo: VmoPointer) {
        let page = KernelLayout.pageSize
        var aspaces = UniqueArray<UInt64>()
        vmo.pointee.lock.withLock {
            for i in 0..<vmo.pointee.mappers.count {
                let aspace = vmo.pointee.mappers[i]
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
                for j in 0..<aspace.pointee.mappings.count where aspace.pointee.mappings[j].vmo == vmo {
                    let m = aspace.pointee.mappings[j]
                    var any = false
                    vmo.pointee.lock.withLock {
                        vmo.pointee.pages.forEach { index, phys in
                            let offset = UInt64(index) * page
                            guard offset >= m.offset, offset - m.offset < m.size else { return }
                            if aspace.pointee.arch.harvestAccessed(m.base + (offset - m.offset)) == true {
                                touch(phys)
                                any = true
                            }
                        }
                    }
                    if any { aspace.pointee.arch.flushAccessed(m.base, m.size) }
                }
            }
            aspace.release()
        }
    }

    /// One aging pass: harvest, then every page of every reclaimable VMO
    /// one older.
    static func age() {
        let vmos = snapshot()
        for i in 0..<vmos.count {
            let vmo = VmoPointer(address: vmos[i])
            harvest(vmo)
            vmo.pointee.lock.withLock {
                vmo.pointee.pages.forEach { _, phys in
                    guard let page = unsafe pmm.page(for: phys) else { return }
                    if unsafe page.pointee.reclaimAge < maxAge { unsafe page.pointee.reclaimAge += 1 }
                }
            }
            Loans.borrow(vmo)  // K14f: clean pager pages onto lent ones
        }
        release(vmos)
        agingPasses.add(1, ordering: .relaxed)
    }

    // MARK: Eviction

    private static let evicting = Mutex()
    static let pagesEvicted = Atomic<UInt64>(0)
    static let vmosDiscarded = Atomic<UInt64>(0)

    /// Evicts up to `target` pages and returns how many it freed: DONT_NEED
    /// pages first, then by age, oldest first, none younger than `minAge`;
    /// ALWAYS_NEED pages only with `ignoreHint`.
    static func evict(target: UInt64, minAge: UInt8, ignoreHint: Bool) -> UInt64 {
        guard target > 0 else { return 0 }
        return evicting.withLock { () -> UInt64 in
            let vmos = snapshot()
            for i in 0..<vmos.count { harvest(VmoPointer(address: vmos[i])) }
            var freed: UInt64 = 0
            var key = dontNeedKey
            while key >= max(minAge, 1), freed < target {
                for i in 0..<vmos.count where freed < target {
                    freed += evict(from: VmoPointer(address: vmos[i]), key: key, ignoreHint: ignoreHint,
                                   limit: target - freed)
                }
                key -= 1
            }
            release(vmos)
            pagesEvicted.add(freed, ordering: .relaxed)
            return freed
        }
    }

    /// Takes `vmo`'s pages whose eviction key is `key` (at most `limit`).
    private static func evict(from vmo: VmoPointer, key: UInt8, ignoreHint: Bool, limit: UInt64) -> UInt64 {
        if vmo.pointee.discardable { return discard(vmo, key: key) }
        guard let source = vmo.pointee.pager else { return 0 }
        // Once detached, nobody would supply a page again.
        guard !source.pointee.lock.withLock({ source.pointee.detached }) else { return 0 }
        let page = KernelLayout.pageSize
        var taken = UniqueArray<UInt64>()  // index, phys pairs, ascending
        vmo.pointee.lock.withLock {
            vmo.pointee.pages.forEach { index, phys in
                guard UInt64(taken.count / 2) < limit, let (k, flags) = rank(phys), k == key,
                      ignoreHint || flags & alwaysNeed == 0 else { return }
                let offset = UInt64(index) * page
                guard vmo.dirtLocked(offset) == 0, !vmo.pinnedLocked(offset, page) else { return }
                taken.append(UInt64(index))
                taken.append(phys)
            }
            var i = 0
            while i < taken.count {
                _ = vmo.pointee.pages.clear(Int(taken[i]))
                vmo.pointee.committedPages -= 1
                i += 2
            }
            if taken.count > 0 { vmo.pointee.reclamationEvents += 1 }
        }
        // Unmapped run by run, then freed.
        var i = 0
        while i < taken.count {
            var j = i + 2
            while j < taken.count, taken[j] == taken[j - 2] + 1 { j += 2 }
            vmo.unmapEverywhere(taken[i] * page, (taken[j - 2] - taken[i] + 1) * page)
            i = j
        }
        i = 1
        while i < taken.count {
            pmm.free(taken[i])
            i += 2
        }
        // Pager VMOs carry no account in v1 (K15a); kept balanced if one does.
        vmo.pointee.account?.uncharge(UInt64(taken.count / 2) * page)
        return UInt64(taken.count / 2)
    }

    /// Discards an unlocked discardable VMO whose first committed page's
    /// turn it is: every page goes, and it reads NOT_FOUND until locked.
    private static func discard(_ vmo: VmoPointer, key: UInt8) -> UInt64 {
        var taken = UniqueArray<UInt64>()
        vmo.pointee.lock.withLock {
            guard vmo.pointee.discard == .reclaimable, vmo.pointee.pins.count == 0 else { return }
            var first: UInt64 = 0
            vmo.pointee.pages.forEach { _, phys in if first == 0 { first = phys } }
            guard first != 0, let (k, _) = rank(first), k == key else { return }
            vmo.pointee.pages.forEach { index, phys in
                taken.append(UInt64(index))
                taken.append(phys)
            }
            var i = 0
            while i < taken.count {
                _ = vmo.pointee.pages.clear(Int(taken[i]))
                i += 2
            }
            vmo.pointee.committedPages = 0
            vmo.pointee.discard = .discarded
            vmo.pointee.reclamationEvents += 1
        }
        guard taken.count > 0 else { return 0 }
        vmo.unmapEverywhere(0, vmo.pointee.size)
        var i = 1
        while i < taken.count {
            pmm.free(taken[i])
            i += 2
        }
        let pages = UInt64(taken.count / 2)
        vmo.pointee.account?.uncharge(pages * KernelLayout.pageSize)
        vmosDiscarded.add(1, ordering: .relaxed)
        return pages
    }

    // MARK: Hints

    /// vmo_op_range / vmar_op_range DONT_NEED and ALWAYS_NEED over [offset,
    /// offset+size) (in range): a pager VMO's pages, or those a snapshot
    /// child reads through to; other VMOs ignore them (Zircon's). DONT_NEED
    /// marks clean, unpinned committed pages to go first (an access undoes
    /// it); ALWAYS_NEED pages the range in (errors ignored) and keeps its
    /// pages from eviction short of OOM, for as long as they are those
    /// pages (no undo, as Zircon's).
    static func hint(_ vmo: VmoPointer, offset: UInt64, size: UInt64, alwaysNeed always: Bool) {
        let page = KernelLayout.pageSize
        var target = vmo
        var start = offset
        while target.pointee.pager == nil {
            guard target.pointee.readsFromPager, let parent = target.pointee.parent else { return }
            start += target.pointee.parentOffset
            target = parent
        }
        guard size > 0 else { return }
        let first = start & ~(page - 1)
        let end = min((start + size + page - 1) & ~(page - 1), target.pointee.size)
        guard first < end else { return }
        if always { try? Pagers.ensureRange(target, first, end - first) }
        var borrowed = UniqueArray<UInt64>()  // K14f: lent pages to swap back
        target.pointee.lock.withLock {
            target.pointee.pages.forEach { index, phys in
                let at = UInt64(index) * page
                guard at >= first, at < end, let record = unsafe pmm.page(for: phys) else { return }
                if always {
                    unsafe record.pointee.reclaimFlags |= alwaysNeed
                    unsafe record.pointee.reclaimAge = 0
                    if pmm.isLoaned(phys) { borrowed.append(at) }
                } else if target.dirtLocked(at) == 0, !target.pinnedLocked(at, page) {
                    unsafe record.pointee.reclaimFlags |= dontNeed
                }
            }
        }
        // K14f: an ALWAYS_NEED page isn't left on a lent one (Zircon's).
        // Only the borrowed ones (K14i: not every page of the range).
        for i in 0..<borrowed.count { Loans.unborrow(target, borrowed[i]) }
    }

    // MARK: Discardable VMOs

    /// LOCK / TRY_LOCK (vmo_op_range 3 / 11): the whole VMO only
    /// (OUT_OF_RANGE). True if it had been discarded (LOCK; TRY_LOCK
    /// refuses that, UNAVAILABLE).
    static func lock(_ vmo: VmoPointer, offset: UInt64, size: UInt64, tryOnly: Bool) throws(Status) -> Bool {
        guard vmo.pointee.discardable else { throw .notSupported }
        return try vmo.pointee.lock.withLock { () throws(Status) -> Bool in
            guard offset == 0, size == vmo.pointee.size else { throw .outOfRange }
            let was = vmo.pointee.discard == .discarded
            if was, tryOnly { throw .unavailable }
            vmo.pointee.lockCount += 1
            vmo.pointee.discard = .locked
            return was
        }
    }

    /// UNLOCK (4): BAD_STATE if not locked; the last makes it reclaimable,
    /// its pages newest.
    static func unlock(_ vmo: VmoPointer, offset: UInt64, size: UInt64) throws(Status) {
        guard vmo.pointee.discardable else { throw .notSupported }
        try vmo.pointee.lock.withLock { () throws(Status) in
            guard offset == 0, size == vmo.pointee.size else { throw .outOfRange }
            guard vmo.pointee.lockCount > 0 else { throw .badState }
            vmo.pointee.lockCount -= 1
            guard vmo.pointee.lockCount == 0 else { return }
            vmo.pointee.discard = .reclaimable
            vmo.pointee.pages.forEach { _, phys in touch(phys) }
        }
    }

    // MARK: Statistics

    /// ZX_INFO_KMEM_STATS's reclaim fields: pages eviction could take
    /// (clean unpinned pager pages, unlocked discardable VMOs), the newest
    /// (ages 0-1) and oldest (6-7 or DONT_NEED) of them, and discardable
    /// VMOs' pages by lock state.
    static func fill(_ k: inout croi_info_kmem_stats_t) {
        let page = KernelLayout.pageSize
        let vmos = snapshot()
        var total: UInt64 = 0, newest: UInt64 = 0, oldest: UInt64 = 0, locked: UInt64 = 0, unlocked: UInt64 = 0
        for i in 0..<vmos.count {
            let vmo = VmoPointer(address: vmos[i])
            vmo.pointee.lock.withLock {
                let discardable = vmo.pointee.discardable
                let reclaimable = discardable && vmo.pointee.discard == .reclaimable
                vmo.pointee.pages.forEach { index, phys in
                    if discardable {
                        if vmo.pointee.lockCount > 0 { locked += page } else { unlocked += page }
                        guard reclaimable else { return }
                    } else {
                        let at = UInt64(index) * page
                        guard vmo.dirtLocked(at) == 0, !vmo.pinnedLocked(at, page) else { return }
                    }
                    guard let (k, _) = rank(phys) else { return }
                    total += page
                    if k < newestEvictable { newest += page }
                    if k >= oldestAge { oldest += page }
                }
            }
        }
        release(vmos)
        k.vmo_reclaim_total_bytes = total
        k.vmo_reclaim_newest_bytes = newest
        k.vmo_reclaim_oldest_bytes = oldest
        k.vmo_discardable_locked_bytes = locked
        k.vmo_discardable_unlocked_bytes = unlocked
    }

    // MARK: Memory pressure

    /// Zircon's levels, worst first.
    enum Level: Int {
        case outOfMemory = 0
        case imminentOutOfMemory
        case critical
        case warning
        case normal
    }

    /// The watchdog's settings (bytes, ns), from the command line; the
    /// test hook replaces them.
    struct Config {
        var outOfMemory: UInt64 = 50 << 20
        var imminent: UInt64 = 60 << 20
        var critical: UInt64 = 150 << 20
        var warning: UInt64 = 300 << 20
        var debounce: UInt64 = 1 << 20
        var hysteresis: UInt64 = 10_000_000_000
        var evictionDelay: UInt64 = 5_000_000_000
        var evictAtWarning = false
        var deltaAtOom: UInt64 = 10 << 20
        var rebootTimeout: UInt64 = 50_000_000_000
        var triggerOnAllocationFailure = true

        func watermark(_ i: Int) -> UInt64 {
            switch i {
            case 0: outOfMemory
            case 1: imminent
            case 2: critical
            default: warning
            }
        }

        var maxEvictionLevel: Level { evictAtWarning ? .warning : .critical }

        /// The free bytes that keep `level` (its watermarks, debounced).
        func bounds(_ level: Level) -> (UInt64, UInt64) {
            var lower: UInt64 = 0, upper = UInt64.max
            if level.rawValue > 0 {
                let below = watermark(level.rawValue - 1)
                lower = below > debounce ? below - debounce : 0
            }
            if level.rawValue < 4 { upper = watermark(level.rawValue) + debounce }
            return (lower, upper)
        }
    }

    private static let configLock = SpinLock()
    nonisolated(unsafe) private static var config = Config()
    nonisolated(unsafe) private static var defaults = Config()
    nonisolated(unsafe) private(set) static var watching = false
    nonisolated(unsafe) private static var agingInterval: UInt64 = 15_000_000_000
    nonisolated(unsafe) private static var evictionEnabled = true

    // The worker's own state.
    nonisolated(unsafe) private static var current = Level.normal
    nonisolated(unsafe) private static var signaled = Level.normal
    nonisolated(unsafe) private static var everSignaled = false
    nonisolated(unsafe) private static var lastEvaluation: UInt64 = 0
    nonisolated(unsafe) private static var evictAt = UInt64.max
    nonisolated(unsafe) private static var evictTarget: UInt64 = 0
    nonisolated(unsafe) private static var evictMinimum: UInt64 = 0

    /// One event per level (kernel-owned; handles get WAIT, DUPLICATE,
    /// TRANSFER).
    nonisolated(unsafe) private static var eventOutOfMemory: UInt64 = 0
    nonisolated(unsafe) private static var eventImminent: UInt64 = 0
    nonisolated(unsafe) private static var eventCritical: UInt64 = 0
    nonisolated(unsafe) private static var eventWarning: UInt64 = 0
    nonisolated(unsafe) private static var eventNormal: UInt64 = 0

    private static func event(_ level: Level) -> ObjectPointer {
        let address = switch level {
        case .outOfMemory: eventOutOfMemory
        case .imminentOutOfMemory: eventImminent
        case .critical: eventCritical
        case .warning: eventWarning
        case .normal: eventNormal
        }
        return ObjectPointer(address: address)
    }

    nonisolated(unsafe) private static var queue = QueuePointer(address: 0)
    private static let pending = Atomic<Bool>(false)
    private static let timerArmed = Atomic<Bool>(false)

    /// Reads the command line, makes the events and starts the thread
    /// (after the objects exist).
    static func initialize() {
        var c = Config()
        func mib(_ option: StaticString, _ value: inout UInt64) {
            if let n = BootOptions.number(after: option) { value = n << 20 }
        }
        mib("croi.oom.outofmemory_mb=", &c.outOfMemory)
        var delta: UInt64 = 10 << 20
        mib("croi.oom.imminent_oom_delta_mb=", &delta)
        mib("croi.oom.critical_mb=", &c.critical)
        mib("croi.oom.warning_mb=", &c.warning)
        mib("croi.oom.debounce_mb=", &c.debounce)
        mib("croi.oom.eviction_delta_at_oom_mb=", &c.deltaAtOom)
        c.imminent = c.outOfMemory + delta
        if let n = BootOptions.number(after: "croi.oom.hysteresis_seconds=") { c.hysteresis = n * 1_000_000_000 }
        if let n = BootOptions.number(after: "croi.oom.eviction_delay_ms=") { c.evictionDelay = n * 1_000_000 }
        if let n = BootOptions.number(after: "croi.oom.reboot_timeout_ms=") { c.rebootTimeout = n * 1_000_000 }
        c.evictAtWarning = BootOptions.has("croi.oom.evict_at_warning=1")
        c.triggerOnAllocationFailure = !BootOptions.has("croi.oom.trigger_on_alloc_failure=0")
        if let n = BootOptions.number(after: "croi.reclaim.aging_ms=") { agingInterval = max(n, 1000) * 1_000_000 }
        evictionEnabled = !BootOptions.has("croi.reclaim.eviction=off")
        // Zircon asserts the order; croi turns the watchdog off instead.
        let ordered = c.outOfMemory <= c.imminent && c.imminent + c.debounce < c.critical
            && c.critical + c.debounce < c.warning
        watching = !BootOptions.has("croi.oom.enable=0") && ordered
        config = c
        defaults = c
        guard let a = try? EventObject.create(), let b = try? EventObject.create(), let d = try? EventObject.create(),
              let e = try? EventObject.create(), let f = try? EventObject.create() else {
            panic("reclaim: no memory for the pressure events")
        }
        eventOutOfMemory = a.address
        eventImminent = b.address
        eventCritical = d.address
        eventWarning = e.address
        eventNormal = f.address
        queue = QueuePointer.allocate()
        do throws(VmError) {
            let thread = try Scheduler.spawn("reclaim", priority: Thread.maxPriority, worker, 0)
            _ = consume thread  // detached
        } catch {
            panic("reclaim: no thread")
        }
        if !ordered { log("memory-pressure: watermarks out of order; the watchdog is off") }
    }

    /// Something for the thread to look at.
    static func wake() {
        guard queue.address != 0 else { return }
        pending.store(true, ordering: .releasing)
        Scheduler.locked { _ = Scheduler.wakeAll(queue) }
    }

    /// The PMM's free count left the watchdog's band (or an allocation
    /// failed), with any lock held: a zero-delay timer wakes the thread.
    static func freeMemoryChanged() {
        guard !timerArmed.exchange(true, ordering: .acquiringAndReleasing) else { return }
        if Timers.arm(deadline: 0, slack: 0, changedCallback, 0) == nil {
            timerArmed.store(false, ordering: .releasing)  // the next change tries again
        }
    }

    private static let changedCallback: Timers.Callback = { _, _ in
        timerArmed.store(false, ordering: .releasing)
        wake()
    }

    private static let worker: Thread.Entry = { _ in
        var nextAge = UInt64.max
        while true {
            pending.store(false, ordering: .relaxed)
            var deadline = UInt64.max
            if watching { deadline = evaluate(Clock.now()) }
            if evictAt <= Clock.now() {
                evictAt = .max
                evictToTarget()
            }
            if registered > 0 {
                let now = Clock.now()
                if nextAge == .max {
                    nextAge = now + agingInterval
                } else if now >= nextAge {
                    age()
                    nextAge = Clock.now() + agingInterval
                }
            } else {
                nextAge = .max
            }
            let until = min(deadline, evictAt, nextAge)
            Scheduler.locked {
                while !pending.load(ordering: .acquiring), Clock.now() < until {
                    _ = Scheduler.block(on: queue, deadline: until)
                }
            }
        }
    }

    /// Zircon's MemoryWatchdog loop body: the level now, signaled if due,
    /// eviction asked for or done, the PMM's band set for it. Returns when
    /// to look again without being woken (a better level waiting out the
    /// hysteresis), or .max.
    private static func evaluate(_ now: UInt64) -> UInt64 {
        let c = configLock.withLock { config }
        let page = KernelLayout.pageSize
        func calculate() -> Level {
            let free = pmm.freePages * page
            let (lower, upper) = c.bounds(current)
            if free >= lower, free <= upper { return current }
            var n = 0
            while n < 4, free > c.watermark(n) { n += 1 }
            return Level(rawValue: n)!
        }
        var level = c.triggerOnAllocationFailure && pmm.singleAllocationFailed ? .outOfMemory : calculate()
        if level == .outOfMemory, evictionEnabled {
            // At once, the newest pages and ALWAYS_NEED too, while it helps.
            var reclaimed: UInt64 = 0
            while level == .outOfMemory {
                let got = evict(target: c.deltaAtOom / page, minAge: newestEvictable, ignoreHint: true)
                guard got > 0 else { break }
                reclaimed += got
                pmm.clearAllocationFailure()
                current = .outOfMemory
                level = calculate()
            }
            if reclaimed > 0 { log("memory-pressure: reclaimed ", reclaimed * page / 1024, " KiB to avoid OOM") }
        }
        current = level
        var deadline = UInt64.max
        if level != signaled || !everSignaled {
            if level.rawValue < signaled.rawValue || !everSignaled || now - lastEvaluation >= c.hysteresis {
                log("memory-pressure: memory availability state - ", name(level))
                if level.rawValue < signaled.rawValue, level.rawValue <= c.maxEvictionLevel.rawValue,
                   level != .outOfMemory, evictionEnabled {
                    let free = pmm.freePages * page
                    evictTarget = c.watermark(c.maxEvictionLevel.rawValue) + c.debounce
                    evictMinimum = free < evictTarget ? (evictTarget - free) / 2 : 0
                    evictAt = evictAt != .max || c.evictionDelay == 0 ? now : now + c.evictionDelay
                }
                if everSignaled { event(signaled).updateSignals(clear: Signals.signaled, set: 0) }
                event(level).updateSignals(clear: 0, set: Signals.signaled)
                signaled = level
                everSignaled = true
                lastEvaluation = now
                if level == .outOfMemory { outOfMemory(c) }
            } else {
                lastEvaluation = now
                deadline = now + c.hysteresis
            }
        }
        let (lower, upper) = c.bounds(current)
        if !pmm.setFreeMemorySignal(low: (lower + page - 1) / page, high: upper == .max ? .max : upper / page) {
            pending.store(true, ordering: .releasing)  // moved meanwhile: look again
        }
        return deadline
    }

    /// The watchdog's eviction: to its free target, at least the minimum,
    /// oldest pages only.
    private static func evictToTarget() {
        let page = KernelLayout.pageSize
        var freed: UInt64 = 0
        while true {
            let free = pmm.freePages * page
            let short = evictTarget > free ? evictTarget - free : 0
            let minimum = evictMinimum > freed ? evictMinimum - freed : 0
            let need = max(short, minimum)
            guard need > 0 else { break }
            let got = evict(target: (need + page - 1) / page, minAge: oldestAge, ignoreHint: false)
            guard got > 0 else { break }
            freed += got * page
        }
        if freed > 0 { log("memory-pressure: evicted ", freed / 1024, " KiB") }
    }

    /// Out of memory even after evicting (Zircon's default behavior,
    /// reboot): user space has the OOM event and the timeout, then the
    /// machine resets.
    private static func outOfMemory(_ c: Config) -> Never {
        log("memory-pressure: out of memory; rebooting in ", c.rebootTimeout / 1_000_000, " ms")
        Scheduler.sleep(until: Clock.now() + c.rebootTimeout)
        Power.reboot()
    }

    private static func name(_ level: Level) -> StaticString {
        switch level {
        case .outOfMemory: "OutOfMemory"
        case .imminentOutOfMemory: "ImminentOutOfMemory"
        case .critical: "Critical"
        case .warning: "Warning"
        case .normal: "Normal"
        }
    }

    private static func log(_ text: StaticString, _ value: UInt64? = nil, _ tail: StaticString = "") {
        KernelLog.write(UInt8(CROI_LOG_INFO)) { line in
            line.write(text)
            if let value { line.write(decimal: value) }
            line.write(tail)
        }
    }

    private static func log(_ text: StaticString, _ level: StaticString) {
        KernelLog.write(UInt8(CROI_LOG_INFO)) { line in
            line.write(text)
            line.write(level)
        }
    }

    // MARK: system_get_event

    /// system_get_event (235, Zircon's): the root job (OUT_OF_MEMORY needs
    /// MANAGE_PROCESS; any other job ACCESS_DENIED); the level's event.
    static func systemEvent(_ table: borrowing HandleTable, _ handle: UInt32, kind: UInt64) throws(Status) -> UInt32 {
        let needed = kind == UInt64(CROI_SYSTEM_EVENT_OUT_OF_MEMORY) ? Rights.manageProcess : Rights()
        let job = try table.get(handle, type: .job, rights: needed)
        guard job.object.address == Processes.rootJob.address else { throw .accessDenied }
        let level: Level
        switch kind {
        case UInt64(CROI_SYSTEM_EVENT_OUT_OF_MEMORY): level = .outOfMemory
        case UInt64(CROI_SYSTEM_EVENT_MEMORY_PRESSURE_CRITICAL): level = .critical
        case UInt64(CROI_SYSTEM_EVENT_MEMORY_PRESSURE_WARNING): level = .warning
        case UInt64(CROI_SYSTEM_EVENT_MEMORY_PRESSURE_NORMAL): level = .normal
        case UInt64(CROI_SYSTEM_EVENT_IMMINENT_OUT_OF_MEMORY): level = .imminentOutOfMemory
        default: throw .invalidArgs
        }
        let object = event(level)
        object.retain()
        do throws(Status) {
            return try table.add(object, rights: .wait | .duplicate | .transfer)
        } catch {
            object.release()
            throw error
        }
    }

    // MARK: Test hooks (syscall 6)

    /// 6: `count` aging passes; 7: evict(target, minAge, ignoreHint) ->
    /// pages; 8: watermarks (oom = imminent, critical, warning, bytes),
    /// hysteresis and eviction delay (ns), all 0: the command line's; 9:
    /// free bytes.
    static func testHook(_ a: InlineArray<6, UInt64>) -> Int64 {
        switch a[0] {
        case 6:
            for _ in 0..<a[1] { age() }
            return 0
        case 7:
            return Int64(evict(target: a[1], minAge: UInt8(truncatingIfNeeded: a[2]), ignoreHint: a[3] != 0))
        case 8:
            configLock.withLock {
                if a[1] == 0 {
                    config = defaults
                } else {
                    config.outOfMemory = a[1]
                    config.imminent = a[1]
                    config.critical = a[2]
                    config.warning = a[3]
                    config.hysteresis = a[4]
                    config.evictionDelay = a[5]
                }
            }
            wake()
            return 0
        case 9:
            return Int64(pmm.freePages * KernelLayout.pageSize)
        default:
            return Int64(Status.invalidArgs.rawValue)
        }
    }
}
