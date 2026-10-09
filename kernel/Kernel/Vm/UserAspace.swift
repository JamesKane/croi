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
struct VmRights: OptionSet, Equatable {
    let rawValue: UInt8
    static var read: VmRights { VmRights(rawValue: 1) }
    static var write: VmRights { VmRights(rawValue: 2) }
    static var execute: VmRights { VmRights(rawValue: 4) }
}

/// A VMO range mapped into a user address space (Zircon's VmMapping). It
/// holds a reference to the VMO.
struct Mapping {
    var base: UInt64
    var size: UInt64
    let vmo: VmoPointer
    /// Byte offset into the VMO of `base`.
    let offset: UInt64
    let rights: VmRights

    func contains(_ virt: UInt64) -> Bool { virt >= base && virt - base < size }
}

/// A user address space's state (Zircon's user VmAspace): lower-half page
/// tables sharing the kernel half, an ASID, and its mappings (sorted by
/// base; the root VMAR. K4b adds sub-regions and reservations). Lives on
/// the heap at a fixed address; `lock` guards it. Lock order: aspace ->
/// vmo -> heap -> pmm.
struct UserAspaceRecord: ~Copyable {
    var arch: ArchAspace
    let asid: UInt64
    let lock = SpinLock()
    var mappings = UniqueArray<Mapping>()
    /// Threads bound to it (scheduler lock).
    var threads = 0
    /// CPUs that have it loaded, one bit each (they need its TLB flushes).
    let activeCpus = Atomic<UInt64>(0)
}

@safe struct UserAspacePointer: Equatable {
    let address: UInt64

    var pointee: UserAspaceRecord {
        unsafeAddress { unsafe UnsafePointer<UserAspaceRecord>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<UserAspaceRecord>(bitPattern: UInt(address))! }
    }
}

/// The owner of a user address space. Dropping it frees the tables and
/// the ASID; no thread may still use it.
struct UserAspace: ~Copyable {
    let record: UserAspacePointer

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
        UserAspaces.live.add(1, ordering: .relaxed)
    }

    /// Maps physical memory at a user address (the VMAR layer builds on
    /// this). `attributes.user` is forced on.
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

    // MARK: Mappings

    /// Maps [offset, offset+size) of `vmo` at `at`, or at the first free
    /// address with a guard page each side. Physical and contiguous VMOs
    /// are mapped at once (with large pages where aligned); anonymous ones
    /// page in on first touch. Returns the base.
    func map(_ vmo: borrowing Vmo, offset: UInt64 = 0, size: UInt64, at fixed: UInt64? = nil,
             rights: VmRights) throws(VmError) -> UInt64 {
        let page = KernelLayout.pageSize
        guard size > 0, size % page == 0, offset % page == 0, offset <= vmo.size, size <= vmo.size - offset,
              rights.contains(.read) || rights.isEmpty == false else { throw .invalidArgument }
        let pointer = vmo.record
        return try record.pointee.lock.withLock { () throws(VmError) -> UInt64 in
            let base: UInt64
            if let fixed {
                guard fixed % page == 0, UserLayout.contains(fixed, size), !overlaps(fixed, size) else {
                    throw .alreadyMapped(fixed)
                }
                base = fixed
            } else {
                base = try findGap(size)
            }
            if case .anonymous = pointer.pointee.kind {} else {
                try record.pointee.arch.map(virt: base, phys: pointer.commit(at: offset)!, size: size,
                                            attributes(rights, pointer.pointee.cache))
            }
            pointer.retain()
            let mapping = Mapping(base: base, size: size, vmo: pointer, offset: offset, rights: rights)
            var index = 0
            while index < record.pointee.mappings.count, record.pointee.mappings[index].base < base { index += 1 }
            record.pointee.mappings.insert(mapping, at: index)
            return base
        }
    }

    /// Removes the mapping that starts at `base` (whole mappings only until
    /// K4b's reservations split them).
    func unmap(mappingAt base: UInt64) throws(VmError) {
        let vmo = try record.pointee.lock.withLock { () throws(VmError) -> VmoPointer in
            guard let index = index(of: base) else { throw .notFound(base) }
            let mapping = record.pointee.mappings.remove(at: index)
            try record.pointee.arch.unmap(virt: mapping.base, size: mapping.size)
            return mapping.vmo
        }
        vmo.release()
    }

    var mappingCount: Int { record.pointee.lock.withLock { record.pointee.mappings.count } }

    private func index(of base: UInt64) -> Int? {
        for i in 0..<record.pointee.mappings.count where record.pointee.mappings[i].base == base { return i }
        return nil
    }

    private func overlaps(_ base: UInt64, _ size: UInt64) -> Bool {
        for i in 0..<record.pointee.mappings.count {
            let m = record.pointee.mappings[i]
            if base < m.base + m.size + KernelLayout.pageSize, m.base < base + size + KernelLayout.pageSize { return true }
        }
        return false
    }

    /// First fit above UserLayout.base, a guard page from each neighbour.
    private func findGap(_ size: UInt64) throws(VmError) -> UInt64 {
        var candidate = UserLayout.base
        for i in 0..<record.pointee.mappings.count {
            let m = record.pointee.mappings[i]
            if candidate + size + KernelLayout.pageSize <= m.base { return candidate }
            candidate = max(candidate, m.base + m.size + KernelLayout.pageSize)
        }
        guard UserLayout.contains(candidate, size) else { throw .noSpace }
        return candidate
    }

    deinit {
        guard Scheduler.locked({ record.pointee.threads }) == 0,
              record.pointee.activeCpus.load(ordering: .acquiring) == 0 else {
            panic("aspace: destroyed while in use")
        }
        while let mapping = record.pointee.mappings.popLast() {
            mapping.vmo.release()  // the tables go below, all at once
        }
        record.pointee.arch.destroyUser()
        Asids.free(record.pointee.asid)
        let raw = unsafe UnsafeMutablePointer<UserAspaceRecord>(bitPattern: UInt(record.address))!
        unsafe raw.deinitialize(count: 1)
        unsafe heap.free(UnsafeMutableRawPointer(raw))
        UserAspaces.live.subtract(1, ordering: .relaxed)
    }
}

/// Page tables attributes for a mapping's rights.
func attributes(_ rights: VmRights, _ cache: CachePolicy) -> MapAttributes {
    MapAttributes(writable: rights.contains(.write), executable: rights.contains(.execute), cache: cache,
                  global: false, user: true)
}

enum UserAspaces {
    static let live = Atomic<Int>(0)
    /// Faults resolved by paging something in.
    static let faultsResolved = Atomic<Int>(0)

    /// A page fault at a user address in the running thread's address
    /// space: maps the page if a mapping allows the access (committing an
    /// anonymous page on first touch). False if it doesn't.
    static func handleFault(at virt: UInt64, write: Bool, execute: Bool) -> Bool {
        guard UserLayout.contains(virt & ~(KernelLayout.pageSize - 1), KernelLayout.pageSize),
              let aspace = Scheduler.current.pointee.aspace else { return false }
        let page = virt & ~(KernelLayout.pageSize - 1)
        let flags = (write ? CROI_VM_FAULT_WRITE : 0) | (execute ? CROI_VM_FAULT_EXECUTE : 0)
        let resolved = aspace.pointee.lock.withLock { () -> Bool in
            var found: Mapping? = nil
            for i in 0..<aspace.pointee.mappings.count where aspace.pointee.mappings[i].contains(page) {
                found = aspace.pointee.mappings[i]
            }
            guard let mapping = found, mapping.rights.contains(.read),
                  !write || mapping.rights.contains(.write), !execute || mapping.rights.contains(.execute) else {
                return false
            }
            if let present = aspace.pointee.arch.query(page) {
                // Another CPU paged it in first, or a permission fault the
                // rights would allow: nothing to do but retry.
                return !write || present.attributes.writable
            }
            guard let phys = mapping.vmo.commit(at: mapping.offset + (page - mapping.base)) else { return false }
            do throws(VmError) {
                try aspace.pointee.arch.map(virt: page, phys: phys, size: KernelLayout.pageSize,
                                            attributes(mapping.rights, mapping.vmo.pointee.cache))
            } catch {
                return false
            }
            return true
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
