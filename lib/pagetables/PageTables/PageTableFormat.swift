/// Page-table entry formats for each architecture croi supports, and the
/// attributes a mapping can have. Levels are numbered from the root (0).
///
/// Everything is `@inlinable`: Embedded Swift specializes it in clients.

/// How a range is mapped.
public struct MapAttributes: Sendable, Equatable {
    public var writable = false
    public var executable = false
    public var device = false
    /// Kernel mappings are global (not tagged with an address space).
    public var global = false

    @inlinable
    public init(writable: Bool = false, executable: Bool = false, device: Bool = false, global: Bool = false) {
        self.writable = writable
        self.executable = executable
        self.device = device
        self.global = global
    }
}

public enum PageTableFormat {
    #if arch(x86_64)
    // 4-level paging, 48-bit VAs. 2 MiB and 4 KiB leaves.
    @inlinable public static var levels: Int { 4 }
    @inlinable public static var identityLimit: UInt64 { 1 << 47 }
    @inlinable static var present: UInt64 { 1 << 0 }
    @inlinable static var writable: UInt64 { 1 << 1 }
    @inlinable static var writeThrough: UInt64 { 1 << 3 }
    @inlinable static var cacheDisable: UInt64 { 1 << 4 }
    @inlinable static var accessed: UInt64 { 1 << 5 }
    @inlinable static var dirty: UInt64 { 1 << 6 }
    @inlinable static var large: UInt64 { 1 << 7 }
    @inlinable static var globalBit: UInt64 { 1 << 8 }
    @inlinable static var noExecute: UInt64 { 1 << 63 }
    @inlinable static var addressMask: UInt64 { 0x000F_FFFF_FFFF_F000 }

    @inlinable public static func leafAllowed(level: Int) -> Bool { level >= 2 }
    @inlinable public static func table(_ phys: UInt64) -> UInt64 { phys | present | writable }
    @inlinable public static func leaf(_ phys: UInt64, level: Int, _ a: MapAttributes) -> UInt64 {
        var e = phys | present | accessed | dirty
        if a.writable { e |= writable }
        if a.device { e |= writeThrough | cacheDisable }
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
        MapAttributes(writable: e & writable != 0, executable: e & noExecute == 0,
                      device: e & cacheDisable != 0, global: e & globalBit != 0)
    }

    #elseif arch(arm64)
    // Stage 1, 4 KiB granule, 48-bit VAs in both TTBR0 and TTBR1.
    // 1 GiB and 2 MiB blocks, 4 KiB pages. MAIR (enter.S): 0 normal, 1 device.
    @inlinable public static var levels: Int { 4 }
    @inlinable public static var identityLimit: UInt64 { 1 << 48 }
    @inlinable static var valid: UInt64 { 1 << 0 }
    @inlinable static var tableOrPage: UInt64 { 1 << 1 }
    @inlinable static var attrDevice: UInt64 { 1 << 2 }
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
        var e = phys | valid | accessFlag | unprivilegedNoExecute
        if level == levels - 1 { e |= tableOrPage }
        if a.device { e |= attrDevice } else { e |= innerShareable }
        if !a.writable { e |= readOnly }
        if !a.executable || a.device { e |= privilegedNoExecute }
        if !a.global { e |= notGlobal }
        return e
    }
    @inlinable public static func isPresent(_ e: UInt64) -> Bool { e & valid != 0 }
    @inlinable public static func isTable(_ e: UInt64, level: Int) -> Bool {
        isPresent(e) && level < levels - 1 && e & tableOrPage != 0
    }
    @inlinable public static func address(_ e: UInt64) -> UInt64 { e & addressMask }
    @inlinable public static func attributes(_ e: UInt64, level: Int) -> MapAttributes {
        MapAttributes(writable: e & readOnly == 0, executable: e & privilegedNoExecute == 0,
                      device: e & attrDevice != 0, global: e & notGlobal == 0)
    }

    #elseif arch(riscv64)
    // Sv39. Leaves allowed at every level (1 GiB, 2 MiB, 4 KiB).
    @inlinable public static var levels: Int { 3 }
    @inlinable public static var identityLimit: UInt64 { 1 << 38 }
    @inlinable static var valid: UInt64 { 1 << 0 }
    @inlinable static var read: UInt64 { 1 << 1 }
    @inlinable static var write: UInt64 { 1 << 2 }
    @inlinable static var execute: UInt64 { 1 << 3 }
    @inlinable static var globalBit: UInt64 { 1 << 5 }
    @inlinable static var accessed: UInt64 { 1 << 6 }
    @inlinable static var dirty: UInt64 { 1 << 7 }

    @inlinable public static func leafAllowed(level: Int) -> Bool { true }
    @inlinable public static func table(_ phys: UInt64) -> UInt64 { (phys >> 12) << 10 | valid }
    @inlinable public static func leaf(_ phys: UInt64, level: Int, _ a: MapAttributes) -> UInt64 {
        var e = (phys >> 12) << 10 | valid | read | accessed | dirty
        if a.writable { e |= write }
        if a.executable && !a.device { e |= execute }
        if a.global { e |= globalBit }
        return e
    }
    @inlinable public static func isPresent(_ e: UInt64) -> Bool { e & valid != 0 }
    @inlinable public static func isTable(_ e: UInt64, level: Int) -> Bool {
        isPresent(e) && e & (read | write | execute) == 0
    }
    @inlinable public static func address(_ e: UInt64) -> UInt64 { ((e >> 10) & ((1 << 44) - 1)) << 12 }
    @inlinable public static func attributes(_ e: UInt64, level: Int) -> MapAttributes {
        MapAttributes(writable: e & write != 0, executable: e & execute != 0,
                      device: false, global: e & globalBit != 0)
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
