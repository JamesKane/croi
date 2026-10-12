import CKernel
import PageTables
import Synchronization

/// User address space layout: [base, top) in the lower half.
enum UserLayout {
    static var base: UInt64 { 0x20_0000 }  // nothing below 2 MiB: null-ish pointers fault
    #if arch(riscv64)
    static var top: UInt64 { (1 << 38) - (1 << 30) }  // Sv39 lower half, less a guard GiB
    #else
    static var top: UInt64 { (1 << 47) - (1 << 30) }
    #endif

    static func contains(_ virt: UInt64, _ size: UInt64) -> Bool {
        virt >= base && size <= top - base && virt <= top - size
    }
}

/// What a mapping allows user code to do.
struct VmRights: BitFlags {
    let rawValue: UInt8
    static var read: VmRights { VmRights(rawValue: 1) }
    static var write: VmRights { VmRights(rawValue: 2) }
    static var execute: VmRights { VmRights(rawValue: 4) }
    /// Guarded (BTI) where executable (K14r, CROI_VM_PERM_GUARDED).
    static var guarded: VmRights { VmRights(rawValue: 8) }
}

/// A sub-region of a user address space (Zircon's child VMAR). Region 0 is
/// the root: all of UserLayout. A reservation holds its whole range for
/// its owner: nothing else is placed there, and inside it views are mapped
/// and unmapped atomically (ext 7).
struct Region {
    let id: UInt32
    let base: UInt64
    let size: UInt64
    let parent: UInt32
    let reservation: Bool
    /// A JIT reservation (ext 7): its protection key (PKU), or 0.
    var jit = false
    var jitKey: UInt8 = 0

    func contains(_ base: UInt64, _ size: UInt64) -> Bool {
        base >= self.base && size <= self.size && base - self.base <= self.size - size
    }
}

/// A VMO range mapped into a user address space (Zircon's VmMapping). It
/// holds a reference to the VMO mapped (`holder`), and the VMO whose pages
/// it maps (`vmo`) lists the address space (for decommit). They differ for
/// an alias (K14g: a slice or reference of an anonymous VMO), whose pages
/// are its root's: `vmo` and `offset` are the root's, so faults, unmaps
/// and reclaim see the root's pages wherever they are mapped.
struct Mapping {
    var base: UInt64
    var size: UInt64
    let vmo: VmoPointer
    /// Byte offset into `vmo` of `base`.
    var offset: UInt64
    var rights: VmRights
    /// The most `rights` may ever be (review fix): what the VMO handle
    /// allowed when it was mapped, read only for a shared read-only VMO.
    /// `protect` refuses more (Zircon keeps the same ceiling per mapping).
    let ceiling: VmRights
    let region: UInt32
    /// Its region's JIT protection key (0: none).
    var key: UInt8 = 0
    /// The VMO mapped (its handle's): the mapping's reference, its koid
    /// and name in the info topics.
    let holder: VmoPointer

    /// `vmo` at `offset` as mapped; an alias resolves to its root.
    init(base: UInt64, size: UInt64, vmo: VmoPointer, offset: UInt64, rights: VmRights, ceiling: VmRights,
         region: UInt32, key: UInt8 = 0) {
        let (pages, shift) = vmo.target
        let most = vmo.pointee.sharedReadOnly ? ceiling.intersection(.read) : ceiling
        self.init(base: base, size: size, vmo: pages, offset: offset + shift, rights: rights, ceiling: most,
                  region: region, key: key, holder: vmo)
    }

    /// A piece of an existing mapping (already resolved).
    init(base: UInt64, size: UInt64, vmo: VmoPointer, offset: UInt64, rights: VmRights, ceiling: VmRights,
         region: UInt32, key: UInt8, holder: VmoPointer) {
        self.base = base
        self.size = size
        self.ceiling = ceiling
        self.vmo = vmo
        self.offset = offset
        self.rights = rights
        self.region = region
        self.key = key
        self.holder = holder
    }

    func contains(_ virt: UInt64) -> Bool { virt >= base && virt - base < size }
    func overlaps(_ base: UInt64, _ size: UInt64) -> Bool { base < self.base + self.size && self.base < base + size }

    /// `offset` in the mapped VMO's terms.
    var holderOffset: UInt64 { holder == vmo ? offset : offset - holder.target.offset }
}

/// A user address space's state (Zircon's user VmAspace): lower-half page
/// tables sharing the kernel half, an ASID, its regions and its mappings
/// (each sorted by base, mappings never overlapping). Lives on the heap at
/// a fixed address, reference counted (the owner, plus a decommit walking
/// it); `lock` guards the rest. Lock order: aspace -> vmo -> heap -> pmm.
struct UserAspaceRecord: ~Copyable {
    var arch: ArchAspace
    let asid: UInt64
    let lock = SpinLock()
    var mappings = UniqueArray<Mapping>()
    /// Ext 7 (K15b): the protection keys its JIT reservations hold (bit n:
    /// key n; key 0 is everything else's). Keys are per address space: a
    /// PTE's key and a thread's PKRU mean nothing outside it (K4c had 15
    /// for the whole system).
    var jitKeys: UInt16 = 1
    /// arm64 (K14s): this process's own pointer authentication key (APIA),
    /// random at creation; each CPU loads it at returns to EL0 of its threads.
    var pacKeyLo: UInt64 = 0
    var pacKeyHi: UInt64 = 0
    /// Bumped (under the lock) whenever `mappings` changes: a thread's
    /// cached out-pointer check is good while it is unchanged (K14m).
    let mapGeneration = Atomic<UInt64>(0)
    var regions = UniqueArray<Region>()
    var nextRegion: UInt32 = 1
    /// Torn down: its tables are gone; holders of a reference skip it.
    var dead = false
    let references = Atomic<Int>(1)
    /// Threads bound to it (scheduler lock).
    var threads = 0
    /// CPUs that have it loaded, one bit each (they need its TLB flushes).
    let activeCpus = Atomic<UInt64>(0)
    /// amd64: the process's I/O permission bitmap (IoPorts; 8 KiB on the
    /// heap, under `lock`) and its never-reused id, or 0.
    var ioBitmap: UInt64 = 0
    var ioBitmapId: UInt64 = 0
}

@safe struct UserAspacePointer: Equatable {
    let address: UInt64

    var pointee: UserAspaceRecord {
        unsafeAddress { unsafe UnsafePointer<UserAspaceRecord>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<UserAspaceRecord>(bitPattern: UInt(address))! }
    }

    func retain() {
        guard pointee.references.add(1, ordering: .relaxed).newValue > 1 else { panic("aspace: retained after release") }
    }

    /// The last reference frees the record (the tables went at teardown).
    func release() {
        guard pointee.references.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 else { return }
        let raw = unsafe UnsafeMutablePointer<UserAspaceRecord>(bitPattern: UInt(address))!
        if pointee.ioBitmap != 0 { unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(pointee.ioBitmap))!) }
        unsafe raw.deinitialize(count: 1)
        unsafe heap.free(UnsafeMutableRawPointer(raw))
        UserAspaces.live.subtract(1, ordering: .relaxed)
    }
}

/// The owner of a user address space. Dropping it unmaps everything and
/// frees the tables and the ASID; no thread may still use it.
struct UserAspace: ~Copyable {
    let record: UserAspacePointer

    /// The root region's id.
    static var root: UInt32 { 0 }

    fileprivate static func view(_ record: UserAspacePointer) -> UserAspace {
        UserAspace(viewing: record)
    }

    private init(viewing record: UserAspacePointer) {
        self.record = record
    }

    /// Ends a view without tearing anything down.
    @export(interface)
    consuming func forget() {
        discard self
    }

    init() throws(VmError) {
        let arch = try kernelAspace.makeUserTables()
        guard let raw = unsafe heap.allocate(size: MemoryLayout<UserAspaceRecord>.size,
                                             alignment: max(16, MemoryLayout<UserAspaceRecord>.alignment)) else {
            arch.destroyUser()
            throw .outOfMemory
        }
        unsafe raw.bindMemory(to: UserAspaceRecord.self, capacity: 1)
            .initialize(to: UserAspaceRecord(arch: arch, asid: Asids.allocate()))
        record = UserAspacePointer(address: UInt64(UInt(bitPattern: raw)))
        record.pointee.arch.owner = record.address  // shootdowns reach its active CPUs only
        #if arch(arm64)
        record.pointee.pacKeyLo = Random.word()  // K14s: one key per process
        record.pointee.pacKeyHi = Random.word()
        #endif
        UserAspaces.live.add(1, ordering: .relaxed)
    }

    /// A non-owning view of a running thread's address space (the owner
    /// keeps it alive); `mapKeeping` is all it is for.
    static func borrowing(_ record: UserAspacePointer) -> BorrowedAspace {
        BorrowedAspace(record: record)
    }

    /// Maps physical memory at a user address, outside the region and
    /// mapping bookkeeping (tests of the tables themselves).
    func map(virt: UInt64, phys: UInt64, size: UInt64, _ attributes: MapAttributes) throws(VmError) {
        guard UserLayout.contains(virt, size) else { throw .outOfRange(virt) }
        var attributes = attributes
        attributes.user = true
        attributes.global = false
        try record.pointee.lock.withLock { () throws(VmError) in
            try record.pointee.arch.map(virt: virt, phys: phys, size: size, attributes)
        }
    }

    func unmap(virt: UInt64, size: UInt64) throws(VmError) {
        guard UserLayout.contains(virt, size) else { throw .outOfRange(virt) }
        try record.pointee.lock.withLock { () throws(VmError) in
            try record.pointee.arch.unmap(virt: virt, size: size)
        }
    }

    func query(_ virt: UInt64) -> Translation? {
        record.pointee.lock.withLock { record.pointee.arch.query(virt) }
    }

    var mappingCount: Int { record.pointee.lock.withLock { record.pointee.mappings.count } }
    var regionCount: Int { record.pointee.lock.withLock { record.pointee.regions.count } }

    // MARK: Regions

    /// A sub-region of `parent` (`size` bytes, aligned), placed first fit.
    /// A reservation holds its range for views (`mapView`).
    /// A JIT reservation (`jit`, entitled code generation) gets a
    /// protection key where the hardware has them (see Jit).
    func allocateRegion(size: UInt64, alignment: UInt64 = KernelLayout.pageSize, in parent: UInt32 = root,
                        at fixed: UInt64? = nil, reservation: Bool = false, jit: Bool = false) throws(VmError) -> Region {
        guard size > 0, size % KernelLayout.pageSize == 0, alignment % KernelLayout.pageSize == 0,
              alignment & (alignment - 1) == 0, !jit || reservation else { throw .invalidArgument }
        return try record.pointee.lock.withLock { () throws(VmError) -> Region in
            // A key where the hardware has them and one is left; else the
            // reservation is views-only (key 0: never RWX).
            var key: UInt8 = 0
            if jit, Jit.mechanism == .protectionKeys {
                for k in 1..<16 where record.pointee.jitKeys & (1 << UInt16(k)) == 0 {
                    key = UInt8(k)
                    break
                }
            }
            let container = try region(parent)
            guard !container.reservation else { throw .invalidArgument }
            let base: UInt64
            do throws(VmError) {
                if let fixed {
                    // vmar_allocate's SPECIFIC (K11b: a loader's random base).
                    guard fixed % KernelLayout.pageSize == 0, container.contains(fixed, size),
                          isFree(fixed, size, in: container) else { throw .alreadyMapped(fixed) }
                    base = fixed
                } else {
                    base = try findGap(size, alignment, in: container)
                }
            } catch {
                throw error
            }
            record.pointee.jitKeys |= 1 << UInt16(key)
            let region = Region(id: record.pointee.nextRegion, base: base, size: size, parent: parent,
                                reservation: reservation, jit: jit, jitKey: key)
            record.pointee.nextRegion += 1
            var index = 0
            while index < record.pointee.regions.count, record.pointee.regions[index].base < base { index += 1 }
            record.pointee.regions.insert(region, at: index)
            return region
        }
    }

    /// Whether [base, base+size) of the root region is free (nothing mapped
    /// or reserved there): a loader picking a random base (K11b).
    func isRangeFree(_ base: UInt64, size: UInt64) -> Bool {
        record.pointee.lock.withLock { () -> Bool in
            guard let container = try? region(Self.root), container.contains(base, size) else { return false }
            return isFree(base, size, in: container)
        }
    }

    /// Removes a region, its sub-regions and everything mapped in them.
    func destroyRegion(_ id: UInt32) throws(VmError) {
        var released = UniqueArray<UInt64>()
        try record.pointee.lock.withLock { () throws(VmError) in
            let target = try region(id)
            guard id != Self.root else { throw .invalidArgument }
            try removeMappings(target.base, target.size, collecting: &released)
            var i = 0
            while i < record.pointee.regions.count {
                let r = record.pointee.regions[i]
                if target.contains(r.base, r.size) {
                    if r.jitKey != 0 { record.pointee.jitKeys &= ~(1 << UInt16(r.jitKey)) }
                    _ = record.pointee.regions.remove(at: i)
                } else {
                    i += 1
                }
            }
        }
        release(released)
    }

    // MARK: Mappings

    /// Maps [offset, offset+size) of `vmo` in `region` (not a reservation:
    /// see `mapView`), at `at` or first fit with a guard page each side.
    /// Physical and contiguous VMOs are mapped at once (large pages where
    /// aligned); anonymous ones page in on first touch. Returns the base.
    /// `ceiling` bounds later `protect`s (nil: `rights`, without guarded).
    func map(_ vmo: borrowing Vmo, offset: UInt64 = 0, size: UInt64, at fixed: UInt64? = nil,
             in id: UInt32 = root, rights: VmRights, ceiling: VmRights? = nil) throws(VmError) -> UInt64 {
        try checkMapping(vmo, offset, size, rights)
        let pointer = vmo.record
        return try record.pointee.lock.withLock { () throws(VmError) -> UInt64 in
            let container = try region(id)
            guard !container.reservation, Jit.allows(rights, key: 0) else { throw .invalidArgument }
            let base: UInt64
            if let fixed {
                guard fixed % KernelLayout.pageSize == 0, container.contains(fixed, size),
                      isFree(fixed, size, in: container) else { throw .alreadyMapped(fixed) }
                base = fixed
            } else {
                base = try findGap(size, KernelLayout.pageSize, in: container)
            }
            try insert(Mapping(base: base, size: size, vmo: pointer, offset: offset, rights: rights,
                               ceiling: ceiling ?? rights.subtracting(.guarded), region: id))
            return base
        }
    }

    /// Ext 7: maps a view of `vmo` at [at, at+size) inside reservation
    /// `id`, replacing whatever views were there, atomically: other threads
    /// see the old view or the new one, never a hole (their faults wait for
    /// the lock and find the new mapping).
    func mapView(_ vmo: borrowing Vmo, offset: UInt64 = 0, size: UInt64, at base: UInt64, in id: UInt32,
                 rights: VmRights, ceiling: VmRights? = nil) throws(VmError) {
        try checkMapping(vmo, offset, size, rights)
        let pointer = vmo.record
        var released = UniqueArray<UInt64>()
        try record.pointee.lock.withLock { () throws(VmError) in
            let reservation = try region(id)
            guard reservation.reservation, base % KernelLayout.pageSize == 0, reservation.contains(base, size),
                  Jit.allows(rights, key: reservation.jitKey) else { throw .invalidArgument }
            try removeMappings(base, size, collecting: &released)
            try insert(Mapping(base: base, size: size, vmo: pointer, offset: offset, rights: rights,
                               ceiling: ceiling ?? rights.subtracting(.guarded), region: id,
                               // Only an RWX view carries the key (K15b): RW and RX
                               // views work as anywhere, so dual views stay usable in
                               // a keyed reservation (threads start write-disabled).
                               key: rights.contains(.write) && rights.contains(.execute) ? reservation.jitKey : 0))
        }
        release(released)
    }

    /// Ext 7: unmaps the views in [at, at+size) of reservation `id`; the
    /// range stays reserved.
    func unmapView(at base: UInt64, size: UInt64, in id: UInt32) throws(VmError) {
        var released = UniqueArray<UInt64>()
        try record.pointee.lock.withLock { () throws(VmError) in
            let reservation = try region(id)
            guard reservation.reservation, reservation.contains(base, size) else { throw .invalidArgument }
            try removeMappings(base, size, collecting: &released)
        }
        release(released)
    }

    /// Unmaps [base, base+size): mappings inside go, ones overlapping an
    /// edge are trimmed, one spanning the range is split. Regions stay.
    func unmap(_ base: UInt64, size: UInt64) throws(VmError) {
        guard base % KernelLayout.pageSize == 0, size % KernelLayout.pageSize == 0, size > 0,
              UserLayout.contains(base, size) else { throw .invalidArgument }
        var released = UniqueArray<UInt64>()
        try record.pointee.lock.withLock { () throws(VmError) in
            guard !record.pointee.dead else { throw .dead }
            try removeMappings(base, size, collecting: &released)
        }
        release(released)
    }

    /// Removes the mapping that starts at `base`, whole.
    func unmap(mappingAt base: UInt64) throws(VmError) {
        let size = try record.pointee.lock.withLock { () throws(VmError) -> UInt64 in
            for i in 0..<record.pointee.mappings.count where record.pointee.mappings[i].base == base {
                return record.pointee.mappings[i].size
            }
            throw .notFound(base)
        }
        try unmap(base, size: size)
    }

    /// Whether mappings with at least `rights` cover all of
    /// [base, base+size) (syscalls check out-pointers before acting).
    func covers(_ base: UInt64, size: UInt64, rights: VmRights) -> Bool {
        coverage(base, size: size, rights: rights) != nil
    }

    /// `covers`, and when one mapping covers it all, that mapping's range
    /// and the mapping generation it was seen at (0, 0 and 0 when several
    /// do): a range inside it is covered as long as the generation holds
    /// (K14m, `Syscalls.check`). nil if not covered.
    func coverage(_ base: UInt64, size: UInt64, rights: VmRights) -> (start: UInt64, end: UInt64, generation: UInt64)? {
        guard size > 0, UserLayout.contains(base, size) else { return nil }
        return record.pointee.lock.withLock { () -> (UInt64, UInt64, UInt64)? in
            guard !record.pointee.dead else { return nil }
            // Syscalls ask this for every out-pointer: a binary search for
            // the first mapping ending past `base` (sorted, disjoint), not a
            // scan of them all.
            var low = 0
            var high = record.pointee.mappings.count
            while low < high {
                let middle = (low + high) / 2
                let m = record.pointee.mappings[middle]
                if m.base + m.size <= base { low = middle + 1 } else { high = middle }
            }
            var covered: UInt64 = 0
            var i = low
            while i < record.pointee.mappings.count, record.pointee.mappings[i].base < base + size {
                let m = record.pointee.mappings[i]
                guard m.rights.isSuperset(of: rights) else { return nil }
                covered += min(m.base + m.size, base + size) - max(m.base, base)
                i += 1
            }
            guard covered == size else { return nil }
            guard i == low + 1 else { return (0, 0, 0) }
            let m = record.pointee.mappings[low]
            return (m.base, m.base + m.size, record.pointee.mapGeneration.load(ordering: .relaxed))
        }
    }

    /// Changes the rights of everything mapped in [base, base+size), which
    /// must be mapped throughout; mappings are split at the edges.
    func protect(_ base: UInt64, size: UInt64, rights: VmRights) throws(VmError) {
        guard base % KernelLayout.pageSize == 0, size % KernelLayout.pageSize == 0, size > 0,
              UserLayout.contains(base, size) else { throw .invalidArgument }
        try record.pointee.lock.withLock { () throws(VmError) in
            guard !record.pointee.dead else { throw .dead }
            var covered: UInt64 = 0
            for i in 0..<record.pointee.mappings.count where record.pointee.mappings[i].overlaps(base, size) {
                let m = record.pointee.mappings[i]
                covered += min(m.base + m.size, base + size) - max(m.base, base)
            }
            guard covered == size else { throw .notFound(base) }
            var key: UInt8 = 0
            for i in 0..<record.pointee.mappings.count where record.pointee.mappings[i].overlaps(base, size) {
                key = record.pointee.mappings[i].key
                guard Jit.allows(rights, key: key) else { throw .invalidArgument }  // W^X
                // Never past what the mapping was allowed (the vDSO, shared
                // pages, a VMO mapped through a read-only handle).
                guard record.pointee.mappings[i].ceiling.contains(rights.subtracting(.guarded)) else {
                    throw .accessDenied
                }
            }
            try split(at: base)
            try split(at: base + size)
            for i in 0..<record.pointee.mappings.count where record.pointee.mappings[i].overlaps(base, size) {
                record.pointee.mappings[i].rights = rights
                record.pointee.mapGeneration.add(1, ordering: .releasing)
                let m = record.pointee.mappings[i]
                // A pager VMO's pages stay read only until written (K13d:
                // its clean pages must fault on a write, and dirty ones
                // are made writable again by that fault).
                let effective = m.vmo.pointee.pager != nil ? rights.subtracting(.write) : rights
                try record.pointee.arch.protect(virt: m.base, size: m.size, attributes(effective, m.vmo.pointee.cache, key: key))
            }
        }
    }

    // MARK: Helpers (lock held)

    /// An anonymous VMO may be mapped past its end (K13h, Zircon's: it
    /// may grow; until then a fault there fails), a reference to one too
    /// (K14g); others only inside (a slice's window most of all: past it
    /// are its root's other pages).
    private func checkMapping(_ vmo: borrowing Vmo, _ offset: UInt64, _ size: UInt64, _ rights: VmRights) throws(VmError) {
        let page = KernelLayout.pageSize
        guard size > 0, size % page == 0, offset % page == 0, !rights.isEmpty,
              !offset.addingReportingOverflow(size).overflow else { throw .invalidArgument }
        if case .anonymous = vmo.record.pointee.kind, !vmo.record.pointee.slice { return }
        guard offset <= vmo.size, size <= vmo.size - offset else { throw .invalidArgument }
    }

    /// Ext 7 (K15b): whether region `id` is a reservation, a JIT one, and
    /// its protection key (0: views only), for CROI_INFO_VMAR_JIT.
    func regionKind(_ id: UInt32) throws(VmError) -> (reservation: Bool, jit: Bool, key: UInt8) {
        try record.pointee.lock.withLock { () throws(VmError) -> (Bool, Bool, UInt8) in
            let r = try region(id)
            return (r.reservation, r.jit, r.jitKey)
        }
    }

    private func region(_ id: UInt32) throws(VmError) -> Region {
        guard !record.pointee.dead else { throw .dead }
        if id == Self.root {
            return Region(id: 0, base: UserLayout.base, size: UserLayout.top - UserLayout.base, parent: 0,
                          reservation: false)
        }
        for i in 0..<record.pointee.regions.count where record.pointee.regions[i].id == id {
            return record.pointee.regions[i]
        }
        throw .notFound(UInt64(id))
    }

    /// Whether [base, base+size) inside `container` touches none of its
    /// mappings or sub-regions.
    private func isFree(_ base: UInt64, _ size: UInt64, in container: Region) -> Bool {
        for i in 0..<record.pointee.mappings.count where record.pointee.mappings[i].overlaps(base, size) {
            return false
        }
        for i in 0..<record.pointee.regions.count {
            let r = record.pointee.regions[i]
            if r.parent == container.id, base < r.base + r.size, r.base < base + size { return false }
        }
        return true
    }

    /// First fit in `container`, a guard page from each mapping and
    /// sub-region in it.
    private func findGap(_ size: UInt64, _ alignment: UInt64, in container: Region) throws(VmError) -> UInt64 {
        let page = KernelLayout.pageSize
        var candidate = (container.base + alignment - 1) & ~(alignment - 1)
        while container.contains(candidate, size) {
            var bumped = false
            for i in 0..<record.pointee.mappings.count {
                let m = record.pointee.mappings[i]
                if candidate < m.base + m.size + page, m.base < candidate + size + page {
                    candidate = (m.base + m.size + page + alignment - 1) & ~(alignment - 1)
                    bumped = true
                }
            }
            for i in 0..<record.pointee.regions.count {
                let r = record.pointee.regions[i]
                if r.parent == container.id, candidate < r.base + r.size + page, r.base < candidate + size + page {
                    candidate = (r.base + r.size + page + alignment - 1) & ~(alignment - 1)
                    bumped = true
                }
            }
            if !bumped { return candidate }
        }
        throw .noSpace
    }

    /// Adds a mapping (mapping physical/contiguous VMOs at once), taking a
    /// VMO reference and listing this address space on the VMO.
    private func insert(_ mapping: Mapping) throws(VmError) {
        if mapping.vmo.pointee.sharedReadOnly, mapping.rights != .read { throw .invalidArgument }
        mapping.holder.retain()
        // A mapper before it is mapped, and a contiguous VMO's lent pages
        // (K14f) read in the same locked step: a decommit either sees the
        // mapper and unmaps here, or this sees its pages lent and skips them.
        let lent = mapping.vmo.addMapper(record.address, lentIn: mapping.offset, mapping.size)
        if case .anonymous = mapping.vmo.pointee.kind {} else {
            let base = mapping.vmo.physicalBase + mapping.offset
            let page = KernelLayout.pageSize
            let attributes = attributes(mapping.rights, mapping.vmo.pointee.cache, key: mapping.key)
            do throws(VmError) {
                if lent.isEmpty {
                    try record.pointee.arch.map(virt: mapping.base, phys: base, size: mapping.size, attributes)
                } else {
                    var run: UInt64 = 0  // runs of pages not lent
                    var at: UInt64 = 0
                    while at <= mapping.size {
                        let index = Int(at / page)
                        if at == mapping.size || lent[index / 64] & (1 << UInt64(index % 64)) != 0 {
                            if at > run {
                                try record.pointee.arch.map(virt: mapping.base + run, phys: base + run, size: at - run,
                                                            attributes)
                            }
                            run = at + page
                        }
                        at += page
                    }
                }
            } catch {
                // What was mapped before the failure goes too (review fix:
                // the entries outlived the mapping, and the pages its VMO).
                try? record.pointee.arch.unmap(virt: mapping.base, size: mapping.size)
                mapping.vmo.removeMapper(record.address)
                mapping.holder.release()
                throw error
            }
        }
        var index = 0
        while index < record.pointee.mappings.count, record.pointee.mappings[index].base < mapping.base { index += 1 }
        record.pointee.mappings.insert(mapping, at: index)
        record.pointee.mapGeneration.add(1, ordering: .releasing)
    }

    /// Splits the mapping spanning `at` (if any) into two at that address.
    private func split(at: UInt64) throws(VmError) {
        for i in 0..<record.pointee.mappings.count {
            let m = record.pointee.mappings[i]
            guard at > m.base, at < m.base + m.size else { continue }
            record.pointee.mappings[i].size = at - m.base
            record.pointee.mapGeneration.add(1, ordering: .releasing)
            m.holder.retain()
            m.vmo.addMapper(record.address)
            record.pointee.mappings.insert(Mapping(base: at, size: m.base + m.size - at, vmo: m.vmo,
                                                   offset: m.offset + (at - m.base), rights: m.rights,
                                                   ceiling: m.ceiling, region: m.region, key: m.key,
                                                   holder: m.holder), at: i + 1)
            return
        }
    }

    /// Unmaps [base, base+size): trims and splits mappings at the edges,
    /// drops the ones inside (their VMOs go into `released`, to be released
    /// once the lock is dropped).
    private func removeMappings(_ base: UInt64, _ size: UInt64, collecting released: inout UniqueArray<UInt64>) throws(VmError) {
        try split(at: base)
        try split(at: base + size)
        var i = 0
        while i < record.pointee.mappings.count {
            let m = record.pointee.mappings[i]
            if m.base >= base, m.base + m.size <= base + size {
                _ = record.pointee.mappings.remove(at: i)
                record.pointee.mapGeneration.add(1, ordering: .releasing)
                m.vmo.removeMapper(record.address)
                released.append(m.holder.address)
            } else {
                i += 1
            }
        }
        try record.pointee.arch.unmap(virt: base, size: size)
    }

    private func release(_ vmos: borrowing UniqueArray<UInt64>) {
        for i in 0..<vmos.count { VmoPointer(address: vmos[i]).release() }
    }

    deinit {
        guard Scheduler.locked({ record.pointee.threads }) == 0,
              record.pointee.activeCpus.load(ordering: .acquiring) == 0 else {
            panic("aspace: destroyed while in use")
        }
        var released = UniqueArray<UInt64>()
        record.pointee.lock.withLock {
            record.pointee.dead = true
            record.pointee.mapGeneration.add(1, ordering: .releasing)
            while let region = record.pointee.regions.popLast() {
                if region.jitKey != 0 { record.pointee.jitKeys &= ~(1 << UInt16(region.jitKey)) }
            }
            while let mapping = record.pointee.mappings.popLast() {
                mapping.vmo.removeMapper(record.address)
                released.append(mapping.holder.address)
            }
            record.pointee.arch.destroyUser()  // every table, at once
        }
        release(released)
        Asids.free(record.pointee.asid)
        record.release()
    }
}

extension UserAspacePointer {
    /// process_write_memory into a mapping that isn't writable (K13g,
    /// Zircon's ForceWritable): the mapping now maps a snapshot child of its
    /// range instead (its pages copied at first touch), so the write stays
    /// this address space's. Returns the new mapping.
    func privatize(_ mapping: Mapping) throws(Status) -> Mapping {
        let child: VmoPointer
        do throws(VmError) {
            child = try Vmo(childOf: mapping.vmo, offset: mapping.offset, size: mapping.size).keep()  // the mapping's reference
        } catch {
            throw error.status
        }
        do throws(Status) {
            let (fresh, oldHolder) = try pointee.lock.withLock { () throws(Status) -> (Mapping, VmoPointer) in
                guard !pointee.dead else { throw .badState }
                for i in 0..<pointee.mappings.count where pointee.mappings[i].base == mapping.base {
                    let old = pointee.mappings[i]
                    guard old.vmo == mapping.vmo, old.size == mapping.size else { break }
                    let fresh = Mapping(base: old.base, size: old.size, vmo: child, offset: 0, rights: old.rights,
                                        ceiling: old.ceiling, region: old.region, key: old.key)
                    child.addMapper(address)
                    pointee.mappings[i] = fresh
                    pointee.mapGeneration.add(1, ordering: .releasing)
                    try? pointee.arch.unmap(virt: old.base, size: old.size)
                    old.vmo.removeMapper(address)
                    child.retain()  // the caller's (review fix: an unmap could free it once we unlock)
                    return (fresh, old.holder)
                }
                throw .notFound
            }
            oldHolder.release()  // the old mapping's, outside the lock: it may be the last
            return fresh
        } catch {
            child.release()
            throw error
        }
    }
}

extension UserAspacePointer {
    /// vmar_op_range's map step (K13e): every page of [base, base+size)
    /// whose VMO has it (its own: a child's untouched pages still fault)
    /// gets its entry now; a pager VMO's clean pages read only.
    func mapPresent(_ base: UInt64, _ size: UInt64) {
        let page = KernelLayout.pageSize
        pointee.lock.withLock {
            guard !pointee.dead else { return }
            var at = base
            while at < base + size {
                defer { at += page }
                guard pointee.arch.query(at) == nil else { continue }
                var found: Mapping? = nil
                for i in 0..<pointee.mappings.count where pointee.mappings[i].contains(at) { found = pointee.mappings[i] }
                guard let m = found else { continue }
                let offset = m.offset + (at - m.base)
                guard let phys = m.vmo.lookup(at: offset) else { continue }
                let clean = m.vmo.pointee.pager != nil
                    && m.vmo.pointee.lock.withLock { m.vmo.dirtLocked(offset) } != PageDirt.dirty
                let rights = clean ? m.rights.subtracting(.write) : m.rights
                try? pointee.arch.map(virt: at, phys: phys, size: page, attributes(rights, m.vmo.pointee.cache, key: m.key))
            }
        }
    }
}

/// Page tables attributes for a mapping's rights (and JIT key).
func attributes(_ rights: VmRights, _ cache: CachePolicy, key: UInt8 = 0) -> MapAttributes {
    MapAttributes(writable: rights.contains(.write), executable: rights.contains(.execute), cache: cache,
                  global: false, user: true, protectionKey: key, guarded: rights.contains(.guarded))
}

enum UserAspaces {
    static let live = Atomic<Int>(0)
    /// Faults resolved by paging something in.
    static let faultsResolved = Atomic<Int>(0)

    /// A page fault at a user address in the running thread's address
    /// space: maps the page if a mapping allows the access (committing an
    /// anonymous page on first touch). False if it doesn't. A page a
    /// pager must supply (K13d) is waited for outside the aspace lock, then
    /// the fault is retried; unless `mayBlock` is false (the faulting code
    /// had interrupts masked), which refuses it.
    static func handleFault(at virt: UInt64, write: Bool, execute: Bool, protectionKey: Bool = false,
                            mayBlock: Bool = true) -> Bool {
        // A protection-key fault is this thread's PKRU saying no: final.
        guard !protectionKey else {
            Trace.event(CROI_TRACE_VM, UInt16(CROI_TK_FAULT), virt, write ? CROI_VM_FAULT_WRITE : 0)
            return false
        }
        guard UserLayout.contains(virt & ~(KernelLayout.pageSize - 1), KernelLayout.pageSize),
              let aspace = Scheduler.current.pointee.aspace else { return false }
        let page = virt & ~(KernelLayout.pageSize - 1)
        let flags = (write ? CROI_VM_FAULT_WRITE : 0) | (execute ? CROI_VM_FAULT_EXECUTE : 0)
        var resolved = false
        while true {
            // A pager's page to wait for (K13d), or one to make dirty.
            var paged: (vmo: VmoPointer, offset: UInt64, write: Bool)? = nil
            var stale = false  // K14f: an entry left on a swapped page, removed: again
            resolved = aspace.pointee.lock.withLock { () -> Bool in
                var found: Mapping? = nil
                for i in 0..<aspace.pointee.mappings.count where aspace.pointee.mappings[i].contains(page) {
                    found = aspace.pointee.mappings[i]
                }
                guard let mapping = found, mapping.rights.contains(.read),
                      !write || mapping.rights.contains(.write), !execute || mapping.rights.contains(.execute) else {
                    return false
                }
                let offset = mapping.offset + (page - mapping.base)
                // A pager VMO's clean page is mapped read only (part 2): a
                // write faults here and dirties it first.
                let tracked = mapping.vmo.pointee.pager != nil
                let dirty = tracked && mapping.vmo.pointee.lock.withLock { mapping.vmo.dirtLocked(offset) == PageDirt.dirty }
                if let present = aspace.pointee.arch.query(page) {
                    // Another CPU paged it in first, a permission fault the
                    // rights would allow, or (K14a) an access to a page whose
                    // accessed bit aging cleared, where the hardware faults
                    // instead of setting it (arm64, rv64 Svade): set it, and
                    // the page is newest again.
                    if !write || present.attributes.writable {
                        if mapping.vmo.pointee.reclaimable {
                            _ = aspace.pointee.arch.markAccessed(page)
                            mapping.vmo.pointee.lock.withLock { Reclaim.touch(present.physical) }
                        } else {
                            _ = aspace.pointee.arch.markAccessed(page)
                        }
                        return true
                    }
                    guard tracked else { return false }
                    // K14f: an entry still on a page swapped for another (a
                    // borrowed one and its ordinary copy) is only ever read;
                    // made writable it would take writes the VMO loses.
                    if mapping.vmo.lookup(at: offset) != present.physical {
                        try? aspace.pointee.arch.unmap(virt: page, size: KernelLayout.pageSize)
                        stale = true
                        return false
                    }
                    guard dirty else {
                        mapping.vmo.retain()  // the mapping may go while we wait
                        paged = (mapping.vmo, offset, true)
                        return false
                    }
                    do throws(VmError) {
                        try aspace.pointee.arch.protect(virt: page, size: KernelLayout.pageSize,
                                                        attributes(mapping.rights, mapping.vmo.pointee.cache, key: mapping.key))
                    } catch {
                        return false
                    }
                    return true
                }
                if mapping.vmo.pointee.pager != nil || mapping.vmo.pointee.readsFromPager,
                   mapping.vmo.pagerGap(at: offset) != nil {
                    mapping.vmo.retain()
                    paged = (mapping.vmo, offset, false)
                    return false
                }
                // A contiguous VMO's lent page (K14f): taken back outside
                // the lock (Pagers.ensure), then the fault is retried.
                if mapping.vmo.pointee.lentPages > 0,
                   mapping.vmo.pointee.lock.withLock({ mapping.vmo.lentLocked(Int(offset / KernelLayout.pageSize)) }) {
                    mapping.vmo.retain()
                    paged = (mapping.vmo, offset, false)
                    return false
                }
                if tracked, write, !dirty {
                    mapping.vmo.retain()
                    paged = (mapping.vmo, offset, true)
                    return false
                }
                guard let phys = mapping.vmo.commit(at: offset) else { return false }
                let rights = tracked && !dirty ? mapping.rights.subtracting(.write) : mapping.rights
                do throws(VmError) {
                    try aspace.pointee.arch.map(virt: page, phys: phys, size: KernelLayout.pageSize,
                                                attributes(rights, mapping.vmo.pointee.cache, key: mapping.key))
                } catch {
                    return false
                }
                return true
            }
            if stale { continue }
            guard let (vmo, offset, dirtying) = paged else { break }
            defer { vmo.release() }
            guard mayBlock else { break }
            do throws(Status) {
                if dirtying { try Pagers.prepareWrite(vmo, offset) } else { try Pagers.ensure(vmo, offset) }
            } catch {
                break
            }
        }
        Trace.event(CROI_TRACE_VM, UInt16(CROI_TK_FAULT), virt, flags | (resolved ? CROI_VM_FAULT_RESOLVED : 0))
        if resolved { faultsResolved.add(1, ordering: .relaxed) }
        return resolved
    }

    /// Once, before the first user address space.
    static func initialize() {
        do throws(VmError) {
            try kernelAspace.prepareForUserAspaces()
        } catch {
            panic("aspace: no memory for the kernel half's tables")
        }
        Asids.initialize()
    }

    /// Loads `aspace`'s tables on this CPU (nil: the kernel's only), moving
    /// this CPU's bit between the address spaces' active sets. Interrupts
    /// masked (the scheduler, at a switch).
    static func activate(_ aspace: UserAspacePointer?, replacing old: UserAspacePointer?) {
        let bit: UInt64 = 1 << UInt64(Cpu.current)
        if let aspace {
            _ = aspace.pointee.activeCpus.bitwiseOr(bit, ordering: .acquiringAndReleasing)
            arch_switch_user_tables(aspace.pointee.arch.rootLow, aspace.pointee.asid, Asids.flushOnSwitch ? 1 : 0)
        } else {
            arch_switch_user_tables(kernelAspace.kernelOnlyRoot, 0, Asids.flushOnSwitch ? 1 : 0)
        }
        if let old { _ = old.pointee.activeCpus.bitwiseAnd(~bit, ordering: .acquiringAndReleasing) }
    }
}

/// ASIDs (arm64, rv64): 0 is the kernel-only tables'; user address spaces
/// get one each and give it back, flushed, when destroyed. Without ASIDs
/// (amd64 today, rv64 with ASIDLEN 0) every switch drops the old entries.
enum Asids {
    nonisolated(unsafe) private static var inUse = InlineArray<4, UInt64>(repeating: 0)
    nonisolated(unsafe) private(set) static var count = 0
    nonisolated(unsafe) private(set) static var flushOnSwitch = false
    private static let lock = SpinLock()

    /// Whether a CPU keeps an address space's TLB entries after switching
    /// away (ASIDs in use): shootdowns can't skip CPUs that aren't running
    /// it now. arm64 broadcasts its TLBIs, so this is about rv64.
    static var keepsEntriesAcrossSwitches: Bool { count > 0 && !flushOnSwitch }

    static func initialize() {
        let bits = min(arch_asid_bits(), 8)  // 256 tracked; arm64 runs with 8-bit ASIDs
        count = bits == 0 ? 0 : 1 << Int(bits)
        #if arch(riscv64)
        flushOnSwitch = count == 0
        #endif
        inUse[0] = 1  // ASID 0: kernel-only tables
    }

    static func allocate() -> UInt64 {
        guard count > 0 else { return 0 }
        return lock.withLock { () -> UInt64 in
            for asid in 1..<count where inUse[asid / 64] & (1 << UInt64(asid % 64)) == 0 {
                inUse[asid / 64] |= 1 << UInt64(asid % 64)
                return UInt64(asid)
            }
            panic("aspace: out of ASIDs (recycling by generation comes later)")
        }
    }

    /// Flushes `asid` everywhere, then lets it be reused.
    static func free(_ asid: UInt64) {
        guard asid != 0 else { return }
        #if arch(riscv64)
        arch_tlb_invalidate_asid(asid)
        Ipi.callOthers(invalidate, asid)
        #else
        arch_tlb_invalidate_asid(asid)  // arm64: broadcast
        #endif
        lock.withLock { inUse[Int(asid) / 64] &= ~(1 << (asid % 64)) }
    }

    private static let invalidate: Ipi.Function = { asid in
        arch_tlb_invalidate_asid(asid)
    }
}

extension UserAspace {
    /// Runs `body` on a non-owning view of `record`, which its caller keeps
    /// alive (a VMAR's reference). A dead address space refuses everything
    /// (`.dead`), checked under its lock by each operation.
    static func withView<R>(_ record: UserAspacePointer,
                            _ body: (borrowing UserAspace) throws(VmError) -> R) throws(VmError) -> R {
        let view = UserAspace.view(record)
        let result: R
        do throws(VmError) {
            result = try body(view)
        } catch {
            view.forget()
            throw error
        }
        view.forget()
        return result
    }
}

/// A running thread's own address space, borrowed for a syscall.
struct BorrowedAspace {
    let record: UserAspacePointer

    func coverage(_ base: UInt64, size: UInt64, rights: VmRights) -> (start: UInt64, end: UInt64, generation: UInt64)? {
        let view = UserAspace.view(record)
        let result = view.coverage(base, size: size, rights: rights)
        view.forget()
        return result
    }

    func covers(_ base: UInt64, size: UInt64, rights: VmRights) -> Bool {
        let view = UserAspace.view(record)
        let result = view.covers(base, size: size, rights: rights)
        view.forget()
        return result
    }

    /// `UserAspace.map` in the root region (vmo_map, until VMARs).
    func mapKeeping(_ vmo: borrowing Vmo, offset: UInt64, size: UInt64, rights: VmRights) throws(VmError) -> UInt64 {
        let view = UserAspace.view(record)
        let base: UInt64
        do throws(VmError) {
            base = try view.map(vmo, offset: offset, size: size, rights: rights)
        } catch {
            view.forget()
            throw error
        }
        view.forget()
        return base
    }
}

// MARK: Statistics (ZX_INFO_TASK_STATS)

extension UserAspace {
    /// Zircon's task stats for the mappings: mapped bytes, and committed
    /// bytes split into private (its VMO mapped by this address space only)
    /// and shared (by others too; croi has no copy-on-write clones), the
    /// shared ones also scaled by how many address spaces map them. A VMO
    /// mapped twice here counts twice, as in Zircon.
    func taskStats() throws(VmError) -> croi_info_task_stats_t {
        try record.pointee.lock.withLock { () throws(VmError) -> croi_info_task_stats_t in
            guard !record.pointee.dead else { throw .dead }
            var stats = croi_info_task_stats_t()
            let fullByte: UInt64 = 1 << 63
            for i in 0..<record.pointee.mappings.count {
                let m = record.pointee.mappings[i]
                stats.mem_mapped_bytes += m.size
                // An alias's pages are its root's, attributed to the root's
                // mappings only (Zircon: a reference has none attributed).
                guard m.holder == m.vmo else { continue }
                let (committed, spaces) = m.vmo.attribution(offset: m.offset, size: m.size)
                guard committed > 0 else { continue }
                if spaces <= 1 {
                    stats.mem_private_bytes += committed
                } else {
                    stats.mem_shared_bytes += committed
                    stats.mem_scaled_shared_bytes += committed / spaces
                    // The remainder's share in 63-bit fixed point (0x8000... = 1 byte).
                    let remainder = committed % spaces
                    let fraction = spaces.dividingFullWidth((high: remainder >> 1, low: remainder << 63)).quotient
                    stats.mem_fractional_scaled_shared_bytes += fraction
                    if stats.mem_fractional_scaled_shared_bytes >= fullByte {
                        stats.mem_fractional_scaled_shared_bytes -= fullByte
                        stats.mem_scaled_shared_bytes += 1
                    }
                }
            }
            return stats
        }
    }
}

extension VmoPointer {
    /// Committed bytes of [offset, offset+size), and how many address
    /// spaces map the VMO. Physical VMOs (device memory, the kernel's shared
    /// pages) count nothing, as Zircon's don't. Aspace lock held (aspace ->
    /// vmo order).
    func attribution(offset: UInt64, size: UInt64) -> (bytes: UInt64, spaces: UInt64) {
        pointee.lock.withLock { () -> (UInt64, UInt64) in
            let page = KernelLayout.pageSize
            let bytes: UInt64
            switch pointee.kind {
            case .physical: bytes = 0
            case .contiguous: bytes = size - lentBytesLocked(offset, size)  // lent pages aren't its (K14f)
            case .anonymous:
                let first = Int(offset / page), end = Int((offset + size + page - 1) / page)
                bytes = UInt64(pointee.pages.count(from: first, to: end)) * page
            }
            var spaces: UInt64 = 0
            for i in 0..<pointee.mappers.count {
                var seen = false
                for j in 0..<i where pointee.mappers[j] == pointee.mappers[i] { seen = true }
                if !seen { spaces += 1 }
            }
            return (bytes, spaces)
        }
    }
}
