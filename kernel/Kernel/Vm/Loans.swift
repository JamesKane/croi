import CKernel
import PageTables
import Synchronization

/// Page loaning (K14f; Zircon's physical page borrowing; Todhchai's
/// requirement 3: contiguous memory set aside for scan-out and DMA isn't
/// wasted while unused). Lenders are a decommitted range of a contiguous
/// VMO and the contiguous pool's free pages: their pages go on the PMM's
/// loaned list (`Pmm.lend`), which only borrowers draw from
/// (`Pmm.allocateLoaned`): pages that can always be given back, a pager
/// VMO's clean ones (part 2). The lender takes a page back when it needs
/// it (`reclaim`): free, at once; borrowed, the borrower lets go of it
/// (evicted: the pager supplies it again). Its physical address never
/// changes, so a contiguous VMO stays contiguous.
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
                switch pmm.unloan(page) {
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

    /// A borrower lets go of `phys`, its page `index`: taken out under its
    /// lock, unmapped, freed (which returns it to its lender). If the VMO
    /// is going (its release frees the page) or has moved the page on, the
    /// caller asks the PMM again.
    private static func evict(_ vmo: VmoPointer, index: UInt64, phys: UInt64) {
        guard vmo.tryRetain() else {
            Scheduler.sleep(until: Clock.now() + 50_000)
            return
        }
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

    /// Borrowed pages made to go back to their lenders.
    static let evictions = Atomic<UInt64>(0)

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
