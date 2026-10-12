import CHandoff
import CKernel

/// A resource (Zircon's ResourceDispatcher): the authority for privileged
/// operations over a range of one kind's space (MMIO addresses, IRQ
/// vectors, IO ports, SMC function IDs, system resources). A size of 0 is
/// that kind's ranged root, which mints any range the root filter allows;
/// the root resource (kind ROOT, Zircon's retired kind 3, handed out as
/// PA_RESOURCE) is every kind's ranged root.
struct ResourceObject: ~Copyable {
    var header = ObjectHeader(type: .resource)
    let kind: UInt32
    let base: UInt64
    let size: UInt64
    let flags: UInt32
    var name = InlineArray<32, UInt8>(repeating: 0)

    /// ZX_DEFAULT_RESOURCE_RIGHTS: basic less WAIT, plus WRITE (to mint
    /// children) and GET_PROPERTY.
    static var defaultRights: Rights { .transfer | .duplicate | .inspect | .write | .getProperty }

    var exclusive: Bool { flags & UInt32(CROI_RSRC_FLAG_EXCLUSIVE) != 0 }

    func isRangedRoot(_ kind: UInt32) -> Bool {
        self.kind == UInt32(CROI_RSRC_KIND_ROOT) || (self.kind == kind && size == 0)
    }
}

/// Guards `Resources`' list of live ranged resources.
let resourceLock = SpinLock()

enum Resources {
    /// The root resource, made at boot (userboot gets a handle).
    nonisolated(unsafe) private(set) static var root = ObjectPointer(address: 0)
    /// Each kind's ranged root (index by kind; ROOT's slot unused). nil
    /// where the arch has no such space (IOPORT off amd64, SMC off arm64).
    nonisolated(unsafe) private(set) static var rangedRoots = InlineArray<6, UInt64>(repeating: 0)

    /// A live resource with a range (not a root), for exclusivity.
    private struct Entry {
        let kind: UInt32
        let base: UInt64
        let size: UInt64
        let exclusive: Bool
        let object: UInt64
    }
    nonisolated(unsafe) private static var live = UniqueArray<Entry>()

    static func initialize() {
        RootFilter.initialize()
        root = make(ResourceObject(kind: UInt32(CROI_RSRC_KIND_ROOT), base: 0, size: 0, flags: 0), name: "root")
        for kind in 0..<UInt32(CROI_RSRC_KIND_COUNT) where kind != UInt32(CROI_RSRC_KIND_ROOT) && space(kind) != nil {
            rangedRoots[Int(kind)] = make(ResourceObject(kind: kind, base: 0, size: 0, flags: 0), name: "root").address
        }
    }

    private static func make(_ resource: consuming ResourceObject, name: StaticString) -> ObjectPointer {
        let count = min(name.utf8CodeUnitCount, 31)
        for i in 0..<count { resource.name[i] = unsafe name.utf8Start[i] }
        guard let object = Objects.allocate(resource) else { panic("resource: out of memory") }
        return object
    }

    /// The range a kind's resources come from (Zircon's per-kind region
    /// allocators), or nil if this arch has none.
    static func space(_ kind: UInt32) -> (base: UInt64, size: UInt64)? {
        switch kind {
        case UInt32(CROI_RSRC_KIND_MMIO): return (0, 1 << 52)
        case UInt32(CROI_RSRC_KIND_IRQ): return (0, 1 << 32)
        case UInt32(CROI_RSRC_KIND_IOPORT):
            #if arch(x86_64)
            return (0, 0x1_0000)
            #else
            return nil
            #endif
        case UInt32(CROI_RSRC_KIND_SMC):
            #if arch(arm64)
            return (0, 1 << 32)
            #else
            return nil
            #endif
        case UInt32(CROI_RSRC_KIND_SYSTEM): return (0, UInt64(CROI_RSRC_SYSTEM_COUNT))
        default: return nil
        }
    }

    static func pointer(_ object: ObjectPointer) -> UnsafePointer<ResourceObject> {
        unsafe UnsafePointer<ResourceObject>(bitPattern: UInt(object.address))!
    }

    // MARK: Creating

    /// resource_create (Zircon's checks, in its order).
    static func create(_ table: borrowing HandleTable, parent: UInt32, options: UInt32, base: UInt64, size: UInt64,
                       name: Span<UInt8>) throws(Status) -> UInt32 {
        guard !base.addingReportingOverflow(size).overflow else { throw .invalidArgs }
        let parentRef = try table.get(parent, type: .resource, rights: .write)
        let kind = options & 0xFFFF, flags = options & ~0xFFFF
        guard kind < UInt32(CROI_RSRC_KIND_COUNT), kind != UInt32(CROI_RSRC_KIND_ROOT),
              flags & ~UInt32(CROI_RSRC_FLAGS_MASK) == 0 else { throw .invalidArgs }
        do throws(Status) {
            try validate(parentRef.object, kind: kind, base: base, size: size, strict: true)
        } catch {
            throw .accessDenied
        }
        let parentResource = unsafe pointer(parentRef.object)
        let exclusive = flags & UInt32(CROI_RSRC_FLAG_EXCLUSIVE) != 0
        guard unsafe parentResource.pointee.isRangedRoot(kind) || !(parentResource.pointee.exclusive || exclusive) else {
            throw .invalidArgs
        }
        guard size > 0 else { throw .invalidArgs }
        guard let space = space(kind) else { throw .badState }
        guard base >= space.base, base + size <= space.base + space.size else { throw .notFound }

        var resource = ResourceObject(kind: kind, base: base, size: size, flags: flags)
        for i in 0..<min(name.count, 31) { resource.name[i] = name[i] }
        guard let object = Objects.allocate(resource) else { throw .noMemory }
        let conflict = resourceLock.withLock { () -> Bool in
            for i in 0..<live.count where live[i].kind == kind && live[i].base < base + size
                && base < live[i].base + live[i].size && (exclusive || live[i].exclusive) {
                return true
            }
            live.append(Entry(kind: kind, base: base, size: size, exclusive: exclusive, object: object.address))
            return false
        }
        guard !conflict else {
            object.release()  // never listed: destroy finds nothing to remove
            throw .notFound
        }
        do throws(Status) {
            return try table.add(object, rights: ResourceObject.defaultRights)
        } catch {
            object.release()
            throw error
        }
    }

    /// A system resource at `base` (kernel self-tests).
    static func create(_ table: borrowing HandleTable, parent: UInt32, system base: UInt64) throws(Status) -> UInt32 {
        let none = InlineArray<1, UInt8>(repeating: 0)
        return try create(table, parent: parent, options: UInt32(CROI_RSRC_KIND_SYSTEM), base: base, size: 1,
                          name: none.span.extracting(0..<0))
    }

    static func destroy(_ object: ObjectPointer) {
        resourceLock.withLock {
            for i in 0..<live.count where live[i].object == object.address {
                _ = live.remove(at: i)
                break
            }
        }
        Objects.free(object, as: ResourceObject.self)
    }

    // MARK: Checking

    /// Zircon's validate_ranged_resource: `object` grants [base,
    /// base+size) of `kind`. A ranged root grants what the root filter
    /// allows (ACCESS_DENIED otherwise); any other resource must be of
    /// `kind` (WRONG_TYPE) and contain the range (OUT_OF_RANGE). Not
    /// strict: an MMIO resource grants the whole pages it touches.
    static func validate(_ object: ObjectPointer, kind: UInt32, base: UInt64, size: UInt64,
                         strict: Bool = false) throws(Status) {
        let resource = unsafe pointer(object)
        let page = KernelLayout.pageSize
        if unsafe resource.pointee.isRangedRoot(kind) {
            // A range that wraps (or would on rounding to pages) would pass
            // every overlap test below with its wrapped end (review fix).
            guard !base.addingReportingOverflow(size).overflow, base + size <= UInt64.max - (page - 1) else {
                throw .outOfRange
            }
            var checkBase = base, checkSize = size
            if kind == UInt32(CROI_RSRC_KIND_MMIO) {
                checkBase = base & ~(page - 1)
                checkSize = (base - checkBase + size + page - 1) & ~(page - 1)
            }
            guard RootFilter.allows(kind, checkBase, checkSize) else { throw .accessDenied }
            return
        }
        guard unsafe resource.pointee.kind == kind else { throw .wrongType }
        var rbase = unsafe resource.pointee.base, rsize = unsafe resource.pointee.size
        if !strict, kind == UInt32(CROI_RSRC_KIND_MMIO) {
            let aligned = rbase & ~(page - 1)
            rsize = (rbase - aligned + rsize + page - 1) & ~(page - 1)
            rbase = aligned
        }
        guard base >= rbase, !base.addingReportingOverflow(size).overflow, base + size <= rbase + rsize else {
            throw .outOfRange
        }
    }

    /// `handle` grants [base, base+size) of `kind` (no rights needed, as
    /// in Zircon).
    static func validate(_ table: borrowing HandleTable, _ handle: UInt32, kind: UInt32, base: UInt64,
                         size: UInt64) throws(Status) {
        let ref = try table.get(handle, type: .resource)
        try validate(ref.object, kind: kind, base: base, size: size)
    }

    /// Whether `handle` grants the system resource at `base`.
    static func check(_ table: borrowing HandleTable, _ handle: UInt32, system base: UInt64) throws(Status) {
        try validate(table, handle, kind: UInt32(CROI_RSRC_KIND_SYSTEM), base: base, size: 1)
    }

    static func info(_ object: ObjectPointer) -> croi_info_resource_t {
        let resource = unsafe pointer(object)
        var info = croi_info_resource_t()
        unsafe info.kind = resource.pointee.kind
        unsafe info.flags = resource.pointee.flags
        unsafe info.base = resource.pointee.base
        unsafe info.size = resource.pointee.size
        let name = unsafe resource.pointee.name
        withUnsafeMutableBytes(of: &info.name) { bytes in
            for i in 0..<32 { unsafe bytes[i] = name[i] }
        }
        return info
    }
}

/// What no resource may grant (Zircon's root resource filter): RAM and
/// firmware memory (VMOs from the PMM are the way to RAM), the device
/// registers the kernel drives itself, and on amd64 the IO ports it
/// owns. Item 20 (K9b) opens the firmware ranges.
enum RootFilter {
    nonisolated(unsafe) private static var kernelMmio = InlineArray<32, (UInt64, UInt64)>(repeating: (0, 0))
    nonisolated(unsafe) private static var kernelMmioCount = 0
    private static let lock = SpinLock()

    /// The ranges that are the kernel's whatever it maps: the console
    /// UART's page, and on amd64 the local APIC / MSI window.
    static func initialize() {
        if bootHandoff.uart.kind == UInt32(CROI_UART_NS16550_MMIO) || bootHandoff.uart.kind == UInt32(CROI_UART_PL011) {
            recordKernelMmio(bootHandoff.uart.base & ~(KernelLayout.pageSize - 1), KernelLayout.pageSize)
        }
        #if arch(x86_64)
        recordKernelMmio(0xFEE0_0000, 0x10_0000)
        #endif
    }

    /// The kernel maps device registers at [base, base+size).
    static func recordKernelMmio(_ base: UInt64, _ size: UInt64) {
        lock.withLock {
            for i in 0..<kernelMmioCount where kernelMmio[i].0 <= base && base + size <= kernelMmio[i].1 { return }
            if kernelMmioCount < 32 {
                kernelMmio[kernelMmioCount] = (base, base + size)
                kernelMmioCount += 1
            } else {
                panic("resource: too many kernel MMIO ranges")
            }
        }
    }

    static func allows(_ kind: UInt32, _ base: UInt64, _ size: UInt64) -> Bool {
        guard !base.addingReportingOverflow(size).overflow else { return false }
        let end = base + size
        switch kind {
        case UInt32(CROI_RSRC_KIND_MMIO):
            if PhysicalMap.overlapsDenied(base, size) { return false }
            return lock.withLock { () -> Bool in
                for i in 0..<kernelMmioCount where base < kernelMmio[i].1 && kernelMmio[i].0 < end { return false }
                return true
            }
        case UInt32(CROI_RSRC_KIND_IOPORT):
            #if arch(x86_64)
            // The 8259s (kept masked) and the console UART.
            if base < 0x22 && 0x20 < end { return false }
            if base < 0xA2 && 0xA0 < end { return false }
            // Not the reset control register (0xCF9): it lies inside PCI's
            // CONFIG_ADDRESS dword at 0xCF8, which port-based config access
            // needs (denying it in review round 1 broke Todhchai's PCI
            // driver), and Zircon allows it.
            if bootHandoff.uart.kind == UInt32(CROI_UART_NS16550_PIO) {
                let uart = bootHandoff.uart.base
                if base < uart + 8 && uart < end { return false }
            }
            #endif
            return true
        case UInt32(CROI_RSRC_KIND_SMC):
            // PSCI calls that change CPU or system state are the kernel's
            // (K13i): CPU_SUSPEND, CPU_OFF, CPU_ON, MIGRATE, SYSTEM_OFF,
            // SYSTEM_RESET, CPU_FREEZE, CPU_DEFAULT_SUSPEND,
            // SYSTEM_SUSPEND, SYSTEM_RESET2, and (review round 1)
            // SET_SUSPEND_MODE, MEM_PROTECT and PSCI 1.3's SYSTEM_OFF2, in
            // either calling convention.
            let kernels: InlineArray<13, UInt64> = [1, 2, 3, 5, 8, 9, 0xB, 0xC, 0xE, 0x12, 0xF, 0x13, 0x15]
            for convention in [0x8400_0000, 0xC400_0000] as InlineArray<2, UInt64> {
                for i in 0..<13 {
                    let id = convention | kernels[i]
                    if base <= id && id < end { return false }
                }
            }
            return true
        default:
            return true
        }
    }
}
