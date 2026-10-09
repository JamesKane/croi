/// Page-table entry formats for each architecture croi supports, and the
/// attributes a mapping can have. Levels are numbered from the root (0).
///
/// Everything is `@inlinable`: Embedded Swift specializes it in clients.

/// The memory type of a mapping.
///
/// Not every architecture can tell all four apart: amd64 maps `uncached`
/// and `device` to the same UC type, arm64 and rv64 (Svpbmt NC) map
/// `uncached` and `writeCombining` to one non-cacheable type, and rv64
/// without Svpbmt leaves everything to the platform's PMAs, i.e. `cached`
/// in the page tables. Reading attributes back reports the type in use.
public enum CachePolicy: UInt8, Sendable {
    /// Normal write-back memory.
    case cached
    /// Memory-like but never cached (no speculation guarantees).
    case uncached
    /// Uncached, with writes combined into bursts: framebuffers.
    case writeCombining
    /// Device registers: uncached, strongly ordered, never executable.
    case device
}

/// How a range is mapped.
public struct MapAttributes: Sendable, Equatable {
    public var writable = false
    public var executable = false
    public var cache = CachePolicy.cached
    /// Kernel mappings are global (not tagged with an address space).
    public var global = false
    /// Accessible from user mode (EL0, U-mode, CPL 3). User mappings are
    /// never global and never executable by the kernel.
    public var user = false

    @inlinable
    public init(writable: Bool = false, executable: Bool = false, cache: CachePolicy = .cached, global: Bool = false,
                user: Bool = false) {
        self.writable = writable
        self.executable = executable
        self.cache = cache
        self.global = global
        self.user = user
    }
}

public enum PageTableFormat {
    #if arch(x86_64)
    // 4-level paging, 48-bit VAs. 2 MiB and 4 KiB leaves. Memory types use
    // PAT indices 0-3 (PWT/PCD; the PAT bit stays clear). The kernel
    // programs the PAT as WB, WC, UC-, UC; firmware's default has WB and UC
    // at indices 0 and 3, which is all the loader uses.
    @inlinable public static var levels: Int { 4 }
    @inlinable public static var identityLimit: UInt64 { 1 << 47 }
    @inlinable static var present: UInt64 { 1 << 0 }
    @inlinable static var writable: UInt64 { 1 << 1 }
    @inlinable static var userBit: UInt64 { 1 << 2 }
    @inlinable static var writeThrough: UInt64 { 1 << 3 }
    @inlinable static var cacheDisable: UInt64 { 1 << 4 }
    @inlinable static var accessed: UInt64 { 1 << 5 }
    @inlinable static var dirty: UInt64 { 1 << 6 }
    @inlinable static var large: UInt64 { 1 << 7 }
    @inlinable static var globalBit: UInt64 { 1 << 8 }
    @inlinable static var noExecute: UInt64 { 1 << 63 }
    @inlinable static var addressMask: UInt64 { 0x000F_FFFF_FFFF_F000 }

    @inlinable public static func leafAllowed(level: Int) -> Bool { level >= 2 }
    // Tables are always user-accessible; the leaf decides (U/S must be set
    // at every level for user access).
    @inlinable public static func table(_ phys: UInt64) -> UInt64 { phys | present | writable | userBit }
    @inlinable public static func leaf(_ phys: UInt64, level: Int, _ a: MapAttributes) -> UInt64 {
        var e = phys | present | accessed | dirty
        if a.writable { e |= writable }
        if a.user { e |= userBit }
        switch a.cache {
        case .cached: break
        case .writeCombining: e |= writeThrough                // PAT index 1
        case .uncached, .device: e |= writeThrough | cacheDisable  // PAT index 3
        }
        if a.global { e |= globalBit }
        if !a.executable { e |= noExecute }
        if level < levels - 1 { e |= large }
        return e
    }
    @inlinable public static func isPresent(_ e: UInt64) -> Bool { e & present != 0 }
    @inlinable public static func isTable(_ e: UInt64, level: Int) -> Bool {
        isPresent(e) && level < levels - 1 && e & large == 0
    }
    @inlinable public static func address(_ e: UInt64) -> UInt64 { e & addressMask }
    @inlinable public static func attributes(_ e: UInt64, level: Int) -> MapAttributes {
        let cache: CachePolicy = switch e & (writeThrough | cacheDisable) {
        case 0: .cached
        case writeThrough: .writeCombining
        default: .device
        }
        return MapAttributes(writable: e & writable != 0, executable: e & noExecute == 0,
                             cache: cache, global: e & globalBit != 0, user: e & userBit != 0)
    }

    #elseif arch(arm64)
    // Stage 1, 4 KiB granule, 48-bit VAs in both TTBR0 and TTBR1.
    // 1 GiB and 2 MiB blocks, 4 KiB pages. MAIR (boot/arch/arm64/enter.S):
    // 0 Normal WB, 1 Device-nGnRE, 2 Normal non-cacheable, 3 Device-nGnRnE.
    @inlinable public static var levels: Int { 4 }
    @inlinable public static var identityLimit: UInt64 { 1 << 48 }
    @inlinable static var valid: UInt64 { 1 << 0 }
    @inlinable static var tableOrPage: UInt64 { 1 << 1 }
    @inlinable static func attrIndex(_ index: UInt64) -> UInt64 { index << 2 }
    @inlinable static var attrIndexMask: UInt64 { 7 << 2 }
    @inlinable static var userAccess: UInt64 { 1 << 6 }  // AP[1]: EL0 may access
    @inlinable static var readOnly: UInt64 { 2 << 6 }
    @inlinable static var innerShareable: UInt64 { 3 << 8 }
    @inlinable static var accessFlag: UInt64 { 1 << 10 }
    @inlinable static var notGlobal: UInt64 { 1 << 11 }
    @inlinable static var privilegedNoExecute: UInt64 { 1 << 53 }
    @inlinable static var unprivilegedNoExecute: UInt64 { 1 << 54 }
    @inlinable static var addressMask: UInt64 { 0x0000_FFFF_FFFF_F000 }

    @inlinable public static func leafAllowed(level: Int) -> Bool { level >= 1 }
    @inlinable public static func table(_ phys: UInt64) -> UInt64 { phys | valid | tableOrPage }
    @inlinable public static func leaf(_ phys: UInt64, level: Int, _ a: MapAttributes) -> UInt64 {
        var e = phys | valid | accessFlag
        if level == levels - 1 { e |= tableOrPage }
        switch a.cache {
        case .cached: e |= attrIndex(0) | innerShareable
        case .uncached, .writeCombining: e |= attrIndex(2) | innerShareable
        case .device: e |= attrIndex(1)
        }
        if !a.writable { e |= readOnly }
        if a.user {
            // EL0's; the kernel never executes it.
            e |= userAccess | privilegedNoExecute | notGlobal
            if !a.executable || a.cache == .device { e |= unprivilegedNoExecute }
        } else {
            e |= unprivilegedNoExecute
            if !a.executable || a.cache == .device { e |= privilegedNoExecute }
            if !a.global { e |= notGlobal }
        }
        return e
    }
    @inlinable public static func isPresent(_ e: UInt64) -> Bool { e & valid != 0 }
    @inlinable public static func isTable(_ e: UInt64, level: Int) -> Bool {
        isPresent(e) && level < levels - 1 && e & tableOrPage != 0
    }
    @inlinable public static func address(_ e: UInt64) -> UInt64 { e & addressMask }
    @inlinable public static func attributes(_ e: UInt64, level: Int) -> MapAttributes {
        let cache: CachePolicy = switch e & attrIndexMask {
        case attrIndex(0): .cached
        case attrIndex(2): .writeCombining
        default: .device
        }
        let user = e & userAccess != 0
        return MapAttributes(writable: e & readOnly == 0,
                             executable: e & (user ? unprivilegedNoExecute : privilegedNoExecute) == 0,
                             cache: cache, global: e & notGlobal == 0, user: user)
    }

    #elseif arch(riscv64)
    // Sv39. Leaves allowed at every level (1 GiB, 2 MiB, 4 KiB). Memory
    // types come from the platform PMAs unless `svpbmt` is set (the kernel
    // sets it from the RHCT; the bits are reserved, and fault, without it).

    /// Use Svpbmt's PBMT field: NC for uncached/WC, IO for device.
    nonisolated(unsafe) public static var svpbmt = false
    @inlinable static var pbmtNonCacheable: UInt64 { 1 << 61 }
    @inlinable static var pbmtIo: UInt64 { 2 << 61 }
    @inlinable static var pbmtMask: UInt64 { 3 << 61 }
    @inlinable public static var levels: Int { 3 }
    @inlinable public static var identityLimit: UInt64 { 1 << 38 }
    @inlinable static var valid: UInt64 { 1 << 0 }
    @inlinable static var read: UInt64 { 1 << 1 }
    @inlinable static var write: UInt64 { 1 << 2 }
    @inlinable static var execute: UInt64 { 1 << 3 }
    @inlinable static var userBit: UInt64 { 1 << 4 }
    @inlinable static var globalBit: UInt64 { 1 << 5 }
    @inlinable static var accessed: UInt64 { 1 << 6 }
    @inlinable static var dirty: UInt64 { 1 << 7 }

    @inlinable public static func leafAllowed(level: Int) -> Bool { true }
    @inlinable public static func table(_ phys: UInt64) -> UInt64 { (phys >> 12) << 10 | valid }
    @inlinable public static func leaf(_ phys: UInt64, level: Int, _ a: MapAttributes) -> UInt64 {
        var e = (phys >> 12) << 10 | valid | read | accessed | dirty
        if a.writable { e |= write }
        if a.executable && a.cache != .device { e |= execute }
        if a.global { e |= globalBit }
        if a.user { e |= userBit }  // S-mode reaches it only with sstatus.SUM
        if svpbmt {
            switch a.cache {
            case .cached: break
            case .uncached, .writeCombining: e |= pbmtNonCacheable
            case .device: e |= pbmtIo
            }
        }
        return e
    }
    @inlinable public static func isPresent(_ e: UInt64) -> Bool { e & valid != 0 }
    @inlinable public static func isTable(_ e: UInt64, level: Int) -> Bool {
        isPresent(e) && e & (read | write | execute) == 0
    }
    @inlinable public static func address(_ e: UInt64) -> UInt64 { ((e >> 10) & ((1 << 44) - 1)) << 12 }
    @inlinable public static func attributes(_ e: UInt64, level: Int) -> MapAttributes {
        let cache: CachePolicy = switch e & pbmtMask {
        case pbmtNonCacheable: .writeCombining
        case pbmtIo: .device
        default: .cached
        }
        return MapAttributes(writable: e & write != 0, executable: e & execute != 0,
                             cache: cache, global: e & globalBit != 0, user: e & userBit != 0)
    }
    #endif

    /// A present entry that maps memory (rather than pointing at a table).
    @inlinable public static func isLeaf(_ e: UInt64, level: Int) -> Bool {
        isPresent(e) && !isTable(e, level: level)
    }

    /// The physical base of a leaf's page (low bits that are attributes at
    /// large-page levels, e.g. x86 PAT, masked off).
    @inlinable public static func leafAddress(_ e: UInt64, level: Int) -> UInt64 {
        address(e) & ~(pageSize(level: level) - 1)
    }

    @inlinable public static func shift(level: Int) -> UInt64 { UInt64(12 + 9 * (levels - 1 - level)) }
    @inlinable public static func pageSize(level: Int) -> UInt64 { 1 << shift(level: level) }
    @inlinable public static func index(_ virt: UInt64, level: Int) -> Int { Int((virt >> shift(level: level)) & 0x1FF) }
}
