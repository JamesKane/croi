/// The boot page tables the kernel starts on: all RAM identity mapped, the
/// UART mapped as device memory, and the kernel image at its link address.

/// How a range is mapped.
struct MapAttributes {
    var writable = false
    var executable = false
    var device = false
    /// Kernel mappings are global (not tagged with an address space).
    var global = false

    /// The temporary RAM identity map: RWX so the loader keeps running
    /// across the switch. The kernel replaces it.
    static var identityRam: MapAttributes { MapAttributes(writable: true, executable: true) }
    static var identityDevice: MapAttributes { MapAttributes(writable: true, device: true) }
}

/// Page-table entry formats. Levels are numbered from the root (0).
enum Mmu {
    #if arch(x86_64)
    // 4-level paging, 48-bit VAs. 2 MiB and 4 KiB leaves.
    static let levels = 4
    static let identityLimit: UInt64 = 1 << 47
    private static let present: UInt64 = 1 << 0
    private static let writable: UInt64 = 1 << 1
    private static let writeThrough: UInt64 = 1 << 3
    private static let cacheDisable: UInt64 = 1 << 4
    private static let accessed: UInt64 = 1 << 5
    private static let dirty: UInt64 = 1 << 6
    private static let large: UInt64 = 1 << 7
    private static let globalBit: UInt64 = 1 << 8
    private static let noExecute: UInt64 = 1 << 63
    private static let addressMask: UInt64 = 0x000F_FFFF_FFFF_F000

    static func leafAllowed(level: Int) -> Bool { level >= 2 }
    static func table(_ phys: UInt64) -> UInt64 { phys | present | writable }
    static func leaf(_ phys: UInt64, level: Int, _ a: MapAttributes) -> UInt64 {
        var e = phys | present | accessed | dirty
        if a.writable { e |= writable }
        if a.device { e |= writeThrough | cacheDisable }
        if a.global { e |= globalBit }
        if !a.executable { e |= noExecute }
        if level < levels - 1 { e |= large }
        return e
    }
    static func isPresent(_ e: UInt64) -> Bool { e & present != 0 }
    static func isTable(_ e: UInt64, level: Int) -> Bool {
        isPresent(e) && level < levels - 1 && e & large == 0
    }
    static func address(_ e: UInt64) -> UInt64 { e & addressMask }

    #elseif arch(arm64)
    // Stage 1, 4 KiB granule, 48-bit VAs in both TTBR0 and TTBR1.
    // 1 GiB and 2 MiB blocks, 4 KiB pages. MAIR (enter.S): 0 normal, 1 device.
    static let levels = 4
    static let identityLimit: UInt64 = 1 << 48
    private static let valid: UInt64 = 1 << 0
    private static let tableOrPage: UInt64 = 1 << 1
    private static let attrDevice: UInt64 = 1 << 2
    private static let readOnly: UInt64 = 2 << 6
    private static let innerShareable: UInt64 = 3 << 8
    private static let accessFlag: UInt64 = 1 << 10
    private static let notGlobal: UInt64 = 1 << 11
    private static let privilegedNoExecute: UInt64 = 1 << 53
    private static let unprivilegedNoExecute: UInt64 = 1 << 54
    private static let addressMask: UInt64 = 0x0000_FFFF_FFFF_F000

    static func leafAllowed(level: Int) -> Bool { level >= 1 }
    static func table(_ phys: UInt64) -> UInt64 { phys | valid | tableOrPage }
    static func leaf(_ phys: UInt64, level: Int, _ a: MapAttributes) -> UInt64 {
        var e = phys | valid | accessFlag | unprivilegedNoExecute
        if level == levels - 1 { e |= tableOrPage }
        if a.device { e |= attrDevice } else { e |= innerShareable }
        if !a.writable { e |= readOnly }
        if !a.executable || a.device { e |= privilegedNoExecute }
        if !a.global { e |= notGlobal }
        return e
    }
    static func isPresent(_ e: UInt64) -> Bool { e & valid != 0 }
    static func isTable(_ e: UInt64, level: Int) -> Bool {
        isPresent(e) && level < levels - 1 && e & tableOrPage != 0
    }
    static func address(_ e: UInt64) -> UInt64 { e & addressMask }

    #elseif arch(riscv64)
    // Sv39. Leaves allowed at every level (1 GiB, 2 MiB, 4 KiB).
    static let levels = 3
    static let identityLimit: UInt64 = 1 << 38
    private static let valid: UInt64 = 1 << 0
    private static let read: UInt64 = 1 << 1
    private static let write: UInt64 = 1 << 2
    private static let execute: UInt64 = 1 << 3
    private static let globalBit: UInt64 = 1 << 5
    private static let accessed: UInt64 = 1 << 6
    private static let dirty: UInt64 = 1 << 7

    static func leafAllowed(level: Int) -> Bool { true }
    static func table(_ phys: UInt64) -> UInt64 { (phys >> 12) << 10 | valid }
    static func leaf(_ phys: UInt64, level: Int, _ a: MapAttributes) -> UInt64 {
        var e = (phys >> 12) << 10 | valid | read | accessed | dirty
        if a.writable { e |= write }
        if a.executable && !a.device { e |= execute }
        if a.global { e |= globalBit }
        return e
    }
    static func isPresent(_ e: UInt64) -> Bool { e & valid != 0 }
    static func isTable(_ e: UInt64, level: Int) -> Bool {
        isPresent(e) && e & (read | write | execute) == 0
    }
    static func address(_ e: UInt64) -> UInt64 { ((e >> 10) & ((1 << 44) - 1)) << 12 }
    #endif

    static func shift(level: Int) -> UInt64 { UInt64(12 + 9 * (levels - 1 - level)) }
    static func pageSize(level: Int) -> UInt64 { 1 << shift(level: level) }
    static func index(_ virt: UInt64, level: Int) -> Int { Int((virt >> shift(level: level)) & 0x1FF) }
}

/// Builds page tables in firmware-allocated pages (CroiMemoryType.handoff).
struct BootPageTables {
    private let boot: BootServices
    private var poolNext: UInt64 = 0
    private var poolEnd: UInt64 = 0

    /// Root for the low half (and everything, except on arm64).
    private(set) var rootLow: UInt64 = 0
    /// Root for the high half: TTBR1 on arm64, the same table elsewhere.
    private(set) var rootHigh: UInt64 = 0

    init(boot: BootServices) throws(LoaderError) {
        self.boot = boot
        rootLow = try allocateTable()
        #if arch(arm64)
        rootHigh = try allocateTable()
        #else
        rootHigh = rootLow
        #endif
    }

    private mutating func allocateTable() throws(LoaderError) -> UInt64 {
        if poolNext == poolEnd {
            let batch: UInt64 = 32
            poolNext = try boot.allocatePages(batch, type: CroiMemoryType.handoff)
            poolEnd = poolNext + batch * pageSize
        }
        defer { poolNext += pageSize }
        return poolNext
    }

    /// Maps [virt, virt+size) to [phys, phys+size) using the largest pages
    /// that fit. All three must be page aligned; overlaps are an error.
    mutating func map(virt: UInt64, phys: UInt64, size: UInt64, _ attributes: MapAttributes) throws(LoaderError) {
        guard virt % pageSize == 0, phys % pageSize == 0, size % pageSize == 0 else {
            throw .unsupported("unaligned boot mapping", virt)
        }
        var virt = virt, phys = phys, left = size
        while left > 0 {
            var level = Mmu.levels - 1
            for candidate in 0..<Mmu.levels where Mmu.leafAllowed(level: candidate) {
                let page = Mmu.pageSize(level: candidate)
                if virt % page == 0, phys % page == 0, left >= page {
                    level = candidate
                    break
                }
            }
            try mapOne(virt: virt, phys: phys, level: level, attributes)
            let page = Mmu.pageSize(level: level)
            virt &+= page
            phys += page
            left -= page
        }
    }

    private mutating func mapOne(virt: UInt64, phys: UInt64, level: Int, _ attributes: MapAttributes) throws(LoaderError) {
        var table = virt >> 63 != 0 ? rootHigh : rootLow
        for walk in 0..<level {
            let slot = unsafe entries(table) + Mmu.index(virt, level: walk)
            let entry = unsafe slot.pointee
            if Mmu.isPresent(entry) {
                guard Mmu.isTable(entry, level: walk) else { throw .unsupported("overlapping boot mapping", virt) }
                table = Mmu.address(entry)
            } else {
                let next = try allocateTable()
                unsafe slot.pointee = Mmu.table(next)
                table = next
            }
        }
        let slot = unsafe entries(table) + Mmu.index(virt, level: level)
        guard unsafe !Mmu.isPresent(slot.pointee) else { throw .unsupported("overlapping boot mapping", virt) }
        unsafe slot.pointee = Mmu.leaf(phys, level: level, attributes)
    }

    /// Tables live in identity-mapped RAM while boot services are active.
    private func entries(_ table: UInt64) -> UnsafeMutablePointer<UInt64> {
        unsafe UnsafeMutablePointer(bitPattern: UInt(table))!
    }
}
