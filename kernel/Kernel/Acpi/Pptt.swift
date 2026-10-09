/// Where a CPU sits: the data the topology page (roadmap ext 9) and the
/// scheduler's placement decisions will use. IDs are PPTT node offsets
/// (stable within a boot), 0 when unknown.
struct CpuTopology {
    var acpiUid: UInt32 = 0
    var package: UInt32 = 0
    var core: UInt32 = 0
    /// Last-level cache node (CPUs with the same value share it).
    var lastLevelCache: UInt32 = 0
    var isThread = false
    /// amd64 hybrid core type (CPUID 0x1A EAX[31:24]); arm64 MIDR
    /// implementer << 16 | part number; 0 otherwise.
    var coreType: UInt32 = 0
}

/// The Processor Properties Topology Table.
enum Pptt {
    /// Fills in package/core/thread/LLC for the CPU with this ACPI UID.
    /// False if there is no PPTT or no node for it.
    static func place(_ topology: inout CpuTopology, _ acpi: AcpiTables) -> Bool {
        guard let pptt = acpi.table("PPTT") else { return false }
        return acpi.withTable(pptt) { (table: RawSpan) -> Bool in place(&topology, in: table) }
    }

    /// `place`, over a table already in hand (also used by the self-test).
    static func place(_ topology: inout CpuTopology, in table: RawSpan) -> Bool {
        guard let leaf = findProcessor(topology.acpiUid, table) else { return false }
        let flags = table.load(fromByteOffset: leaf + 4, as: UInt32.self)
        topology.isThread = flags & (1 << 2) != 0
        topology.core = UInt32(topology.isThread ? parent(leaf, table) ?? leaf : leaf)
        topology.package = UInt32(package(of: leaf, table))
        topology.lastLevelCache = UInt32(lastLevelCache(from: leaf, table))
        return true
    }

    /// The processor node with this ACPI processor ID (preferring leaves).
    private static func findProcessor(_ uid: UInt32, _ table: RawSpan) -> Int? {
        var found: Int?
        forEachNode(table) { offset, type in
            guard type == 0 else { return }
            let flags = table.load(fromByteOffset: offset + 4, as: UInt32.self)
            guard flags & (1 << 1) != 0,  // ACPI processor ID valid
                  table.load(fromByteOffset: offset + 12, as: UInt32.self) == uid
            else { return }
            if found == nil || flags & (1 << 3) != 0 { found = offset }  // leaf
        }
        return found
    }

    private static func parent(_ node: Int, _ table: RawSpan) -> Int? {
        let parent = Int(table.load(fromByteOffset: node + 8, as: UInt32.self))
        return parent >= 36 && parent + 20 <= table.byteCount ? parent : nil
    }

    /// The nearest ancestor flagged as a physical package (else the root).
    private static func package(of node: Int, _ table: RawSpan) -> Int {
        var current = node
        for _ in 0..<16 {
            if table.load(fromByteOffset: current + 4, as: UInt32.self) & 1 != 0 { return current }
            guard let up = parent(current, table) else { return current }
            current = up
        }
        return current
    }

    /// The last cache reachable from this node and its ancestors: each
    /// node's private cache resources, followed along next-level links.
    private static func lastLevelCache(from node: Int, _ table: RawSpan) -> Int {
        var last = 0
        var current: Int? = node
        for _ in 0..<16 {
            guard let at = current else { break }
            let resources = Int(table.load(fromByteOffset: at + 16, as: UInt32.self))
            for i in 0..<min(resources, 64) {
                guard at + 20 + 4 * i + 4 <= table.byteCount else { break }
                var cache = Int(table.load(fromByteOffset: at + 20 + 4 * i, as: UInt32.self))
                for _ in 0..<8 {  // follow next-level links
                    guard cache >= 36, cache + 12 <= table.byteCount,
                          table.load(fromByteOffset: cache, as: UInt8.self) == 1  // cache type node
                    else { break }
                    last = cache
                    cache = Int(table.load(fromByteOffset: cache + 8, as: UInt32.self))
                }
            }
            current = parent(at, table)
        }
        return last
    }

    private static func forEachNode(_ table: RawSpan, _ body: (Int, UInt8) -> Void) {
        var offset = 36
        while offset + 2 <= table.byteCount {
            let type = table.load(fromByteOffset: offset, as: UInt8.self)
            let length = Int(table.load(fromByteOffset: offset + 1, as: UInt8.self))
            guard length >= 2, offset + length <= table.byteCount else { return }
            body(offset, type)
            offset += length
        }
    }
}
