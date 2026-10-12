import CKernel
import PageTables
import Synchronization

/// Page loaning (K14f; Zircon's physical page borrowing; Todhchai's
/// requirement 3: contiguous memory set aside for scan-out and DMA isn't
/// wasted while unused). Lenders are a decommitted range of a contiguous
/// VMO and the contiguous pool's free pages: their pages go on the PMM's
/// loaned list (`Pmm.lend`), which only borrowers draw from
/// (`Pmm.allocateLoaned`): pages that can always be given back. The only
/// borrowers are a pager VMO's clean pages (Zircon's rule: not TRAP_DIRTY,
/// never pinned), swapped onto lent pages by the aging pass (`borrow`,
/// Zircon's borrow-on-MRU sweep), which frees the originals for anyone. A
/// borrowed page is swapped back to an ordinary one before it is dirtied,
/// pinned or hinted ALWAYS_NEED (`unborrow`). The lender takes a page back
/// when it needs it (`reclaim`): free, at once; borrowed, the borrower
/// lets go of it (evicted: the pager supplies it again on the next
/// access). Its physical address never changes, so a contiguous VMO stays
/// contiguous.
///
/// `croi.ppb.loan=off` turns lending off: contiguous decommit is then
/// NOT_SUPPORTED (Zircon's kernel.ppb.loan, default off there; on here).
enum Loans {
    nonisolated(unsafe) private(set) static var enabled = false

    /// Serializes contiguous VMOs' lending and taking back (decommit, and
    /// commit or an access), so no page is lent and its lender's at once.
    /// Outermost: taken with no other lock held.
    static let mutex = Mutex()

    static func initialize() {
        enabled = !BootOptions.has("croi.ppb.loan=off")
    }

    /// Takes the lent pages [phys, +count pages) back for their lender
    /// (pages not lent are left as they are). Thread context, no locks
    /// held: a borrower is made to let go, which may take a moment.
    static func reclaim(_ phys: UInt64, count: Int) {
        for i in 0..<count {
            let page = phys + UInt64(i) * KernelLayout.pageSize
            while true {
                switch pmm.unloan(page, retaining: { VmoPointer(address: $0).tryRetain() }) {
                case .back:
                    break
                case .evict(let vmo, let index):
                    evict(VmoPointer(address: vmo), index: index, phys: page)
                    continue
                case .wait:
                    Scheduler.sleep(until: Clock.now() + 50_000)
                    continue
                }
                break
            }
        }
    }

    /// A borrower (retained by `unloan`) lets go of `phys`, its page
    /// `index`: taken out under its lock, unmapped, freed (which returns
    /// it to its lender). If it moved the page on meanwhile, the caller
    /// asks the PMM again.
    private static func evict(_ vmo: VmoPointer, index: UInt64, phys: UInt64) {
        defer { vmo.release() }
        let taken = vmo.pointee.lock.withLock { () -> Bool in
            guard vmo.pointee.pages.lookup(Int(index)) == phys else { return false }
            _ = vmo.pointee.pages.clear(Int(index))
            vmo.pointee.committedPages -= 1
            vmo.pointee.reclamationEvents += 1
            return true
        }
        guard taken else { return }
        vmo.unmapEverywhere(index * KernelLayout.pageSize, KernelLayout.pageSize)
        pmm.free(phys)
        evictions.add(1, ordering: .relaxed)
    }

    /// Borrowed pages made to go back to their lenders, pages swapped onto
    /// lent ones, and borrowed pages swapped back.
    static let evictions = Atomic<UInt64>(0)
    static let borrowed = Atomic<UInt64>(0)
    static let unborrowed = Atomic<UInt64>(0)

    // MARK: Borrowers

    /// The aging pass's sweep over a reclaimable VMO: a pager VMO's clean,
    /// unpinned pages that aren't ALWAYS_NEED move onto free lent pages
    /// (copied; their age and hints kept), and the originals are freed.
    /// Clean pager pages are mapped read only, so a mapping left on an old
    /// page until the unmap below can only be read (and the write fault
    /// path checks it maps the current page).
    static func borrow(_ vmo: VmoPointer) {
        guard enabled, pmm.freeLoanedPages > 0, !vmo.pointee.everPinned, let source = vmo.pointee.pager else { return }
        guard source.pointee.lock.withLock({ !source.pointee.trapDirty && !source.pointee.detached }) else { return }
        let page = KernelLayout.pageSize
        var swapped = UniqueArray<UInt64>()  // index, old page pairs
        vmo.pointee.lock.withLock {
            var candidates = UniqueArray<UInt64>()
            vmo.pointee.pages.forEach { index, phys in
                let offset = UInt64(index) * page
                guard !pmm.isLoaned(phys), vmo.dirtLocked(offset) == 0, !vmo.pinnedLocked(offset, page),
                      let record = unsafe pmm.page(for: phys),
                      unsafe record.pointee.reclaimFlags & Reclaim.alwaysNeed == 0 else { return }
                candidates.append(UInt64(index))
                candidates.append(phys)
            }
            var i = 0
            while i < candidates.count {
                let index = candidates[i], old = candidates[i + 1]
                i += 2
                guard let new = pmm.allocateLoaned(for: vmo.address, index: index) else { break }
                copyPage(from: old, to: new)
                pmm.copyReclaimState(from: old, to: new)
                _ = vmo.pointee.pages.set(Int(index), new)  // an existing slot: nothing to allocate
                swapped.append(index)
                swapped.append(old)
            }
        }
        var i = 0
        while i < swapped.count {
            vmo.unmapEverywhere(swapped[i] * page, page)
            pmm.free(swapped[i + 1])
            i += 2
        }
        borrowed.add(UInt64(swapped.count / 2), ordering: .relaxed)
    }

    /// A borrowed page of `vmo` at `offset` (if it is one) becomes an
    /// ordinary page with the same contents, before it is dirtied, pinned
    /// or hinted ALWAYS_NEED; the lent one goes back to the loaned list
    /// (or its lender). False if there was no memory for the copy.
    @discardableResult
    static func unborrow(_ vmo: VmoPointer, _ offset: UInt64) -> Bool {
        let page = KernelLayout.pageSize
        let index = Int(offset / page)
        let borrowed = vmo.pointee.lock.withLock { () -> Bool in
            let phys = vmo.pointee.pages.lookup(index)
            return phys != 0 && pmm.isLoaned(phys)
        }
        guard borrowed else { return true }
        guard let new = pmm.allocatePage(.vmo) else { return false }
        let old = vmo.pointee.lock.withLock { () -> UInt64 in
            let phys = vmo.pointee.pages.lookup(index)
            guard phys != 0, pmm.isLoaned(phys) else { return 0 }
            copyPage(from: phys, to: new)
            pmm.copyReclaimState(from: phys, to: new)
            _ = vmo.pointee.pages.set(index, new)
            return phys
        }
        guard old != 0 else {
            pmm.free(new)
            return true
        }
        vmo.unmapEverywhere(UInt64(index) * page, page)
        pmm.free(old)
        unborrowed.add(1, ordering: .relaxed)
        return true
    }

    private static func copyPage(from source: UInt64, to destination: UInt64) {
        unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(destination)))!
            .copyMemory(from: UnsafeRawPointer(bitPattern: UInt(KernelLayout.physmap(source)))!,
                        byteCount: Int(KernelLayout.pageSize))
    }

    // MARK: Contiguous VMOs

    /// Decommit of [offset, +size) of a contiguous VMO: its pages are lent
    /// (Zircon's, with kernel.ppb.loan): unmapped everywhere, reading as
    /// zero when committed again. Not on a slice or a VMO with children
    /// (they share the pages) or over pinned pages.
    static func decommit(_ vmo: VmoPointer, offset: UInt64, size: UInt64) throws(VmError) {
        guard enabled else { throw .notSupported }
        guard case .contiguous(let base) = vmo.pointee.kind, !vmo.pointee.slice else { throw .notSupported }
        let page = KernelLayout.pageSize
        mutex.lock()
        defer { mutex.unlock() }
        var lending = UniqueArray<UInt64>()
        try vmo.pointee.lock.withLock { () throws(VmError) in
            guard vmo.pointee.children == 0 else { throw .badState }
            guard !vmo.pinnedLocked(offset, size) else { throw .pinned }
            if vmo.pointee.lent.isEmpty {
                vmo.pointee.lent = UniqueArray<UInt64>(repeating: 0, count: (vmo.pointee.pageCount + 63) / 64)
            }
            var at = offset
            while at < offset + size {
                let index = Int(at / page)
                if !vmo.lentLocked(index) {
                    vmo.pointee.lent[index / 64] |= 1 << UInt64(index % 64)
                    vmo.pointee.lentPages += 1
                    lending.append(base + at)
                }
                at += page
            }
        }
        // Gone from every mapping before anyone may borrow them.
        vmo.unmapEverywhere(offset, size)
        for i in 0..<lending.count { pmm.lend(lending[i], count: 1) }
    }

    /// Before an access to [offset, +length) of a contiguous VMO: its lent
    /// pages there are taken back, zeroed (and written back to memory for
    /// an uncached VMO: borrowers wrote through the cached physmap) and
    /// its own again.
    static func ensure(_ vmo: VmoPointer, _ offset: UInt64, _ length: UInt64) {
        guard vmo.pointee.lentPages > 0, case .contiguous(let base) = vmo.pointee.kind else { return }
        let page = KernelLayout.pageSize
        let first = offset & ~(page - 1)
        let (end, overflow) = offset.addingReportingOverflow(max(length, 1))
        let last = overflow ? vmo.pointee.size : min(vmo.pointee.size, (end + page - 1) & ~(page - 1))
        mutex.lock()
        defer { mutex.unlock() }
        var at = first
        while at < last {
            let index = Int(at / page)
            let lent = vmo.pointee.lock.withLock { vmo.lentLocked(index) }
            if lent {
                reclaim(base + at, count: 1)
                let address = KernelLayout.physmap(base + at)
                unsafe UnsafeMutableRawPointer(bitPattern: UInt(address))!
                    .initializeMemory(as: UInt8.self, repeating: 0, count: Int(page))
                if vmo.pointee.cache != .cached {
                    arch_cache_op(address, page, UInt32(CROI_CACHE_CLEAN_INVALIDATE), VmoCache.line)
                }
                vmo.pointee.lock.withLock {
                    vmo.pointee.lent[index / 64] &= ~(1 << UInt64(index % 64))
                    vmo.pointee.lentPages -= 1
                }
            }
            at += page
        }
    }

    /// A contiguous VMO's last reference: whatever it lent comes back
    /// before its pages are freed.
    static func endOfLender(_ vmo: VmoPointer) {
        guard vmo.pointee.lentPages > 0, case .contiguous(let base) = vmo.pointee.kind else { return }
        for index in 0..<vmo.pointee.pageCount where vmo.lentLocked(index) {
            reclaim(base + UInt64(index) * KernelLayout.pageSize, count: 1)
        }
        vmo.pointee.lentPages = 0
    }
}

extension VmoPointer {
    /// Whether page `index` of a contiguous VMO is lent (decommitted).
    /// VMO lock held, or the VMO otherwise quiet.
    func lentLocked(_ index: Int) -> Bool {
        pointee.lentPages > 0 && pointee.lent[index / 64] & (1 << UInt64(index % 64)) != 0
    }

    /// Lent pages in [offset, +size) of a contiguous VMO. Lock held.
    func lentBytesLocked(_ offset: UInt64, _ size: UInt64) -> UInt64 {
        guard pointee.lentPages > 0 else { return 0 }
        let page = KernelLayout.pageSize
        var bytes: UInt64 = 0
        var at = offset & ~(page - 1)
        while at < offset + size, at < pointee.size {
            if lentLocked(Int(at / page)) { bytes += page }
            at += page
        }
        return bytes
    }
}
