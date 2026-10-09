import CKernel

/// An anonymous VMO's committed pages: a radix tree of 512-entry nodes
/// (4 KiB each, from the heap), deep enough for the VMO's size, grown only
/// where pages are committed. A 64 GiB VMO with three pages committed costs
/// a handful of nodes, not a 128 MiB flat array. Guarded by the VMO lock.
struct PageList: ~Copyable {
    private var root: UInt64 = 0
    private let levels: Int
    private static var fanout: Int { 512 }

    init(pages: Int) {
        var levels = 1, capacity = Self.fanout
        while capacity < pages {
            levels += 1
            capacity *= Self.fanout
        }
        self.levels = levels
    }

    /// The page at `index`, or 0 if not committed.
    func lookup(_ index: Int) -> UInt64 {
        var node = root
        for level in 0..<levels {
            guard node != 0 else { return 0 }
            node = Self.slot(node, index, level, levels).pointee
        }
        return node
    }

    /// Records `phys` at `index`. False if a node couldn't be allocated.
    mutating func set(_ index: Int, _ phys: UInt64) -> Bool {
        if root == 0 {
            guard let node = Self.makeNode() else { return false }
            root = node
        }
        var node = root
        for level in 0..<(levels - 1) {
            let slot = Self.slot(node, index, level, levels)
            if slot.pointee == 0 {
                guard let child = Self.makeNode() else { return false }
                slot.pointee = child
            }
            node = slot.pointee
        }
        Self.slot(node, index, levels - 1, levels).pointee = phys
        return true
    }

    /// Forgets `index`, returning what was there (0 if nothing). Interior
    /// nodes stay until the list goes.
    mutating func clear(_ index: Int) -> UInt64 {
        var node = root
        for level in 0..<(levels - 1) {
            guard node != 0 else { return 0 }
            node = Self.slot(node, index, level, levels).pointee
        }
        guard node != 0 else { return 0 }
        let slot = Self.slot(node, index, levels - 1, levels)
        let old = slot.pointee
        slot.pointee = 0
        return old
    }

    /// Calls `body(index, phys)` for every committed page.
    func forEach(_ body: (Int, UInt64) -> Void) {
        Self.walk(root, level: 0, levels: levels, base: 0, body)
    }

    deinit {
        Self.freeNodes(root, level: 0, levels: levels)
    }

    // MARK: Nodes

    private static func walk(_ node: UInt64, level: Int, levels: Int, base: Int, _ body: (Int, UInt64) -> Void) {
        guard node != 0 else { return }
        let span = power(levels - 1 - level)
        for i in 0..<fanout {
            let entry = slotAt(node, i).pointee
            guard entry != 0 else { continue }
            if level == levels - 1 { body(base + i, entry) } else { walk(entry, level: level + 1, levels: levels, base: base + i * span, body) }
        }
    }

    private static func freeNodes(_ node: UInt64, level: Int, levels: Int) {
        guard node != 0 else { return }
        if level < levels - 1 {
            for i in 0..<fanout { freeNodes(slotAt(node, i).pointee, level: level + 1, levels: levels) }
        }
        unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(node))!)
    }

    private static func makeNode() -> UInt64? {
        guard let raw = unsafe heap.allocate(size: 8 * fanout, alignment: 4096) else { return nil }
        unsafe raw.initializeMemory(as: UInt8.self, repeating: 0, count: 8 * fanout)
        return UInt64(UInt(bitPattern: raw))
    }

    private static func power(_ n: Int) -> Int {
        var result = 1
        for _ in 0..<max(0, n) { result *= fanout }
        return result
    }

    private static func slot(_ node: UInt64, _ index: Int, _ level: Int, _ levels: Int) -> SlotPointer {
        slotAt(node, (index / power(levels - 1 - level)) % fanout)
    }

    private static func slotAt(_ node: UInt64, _ i: Int) -> SlotPointer {
        SlotPointer(address: node + UInt64(i) * 8)
    }
}

/// One 8-byte slot of a page-list node.
@safe struct SlotPointer {
    let address: UInt64

    var pointee: UInt64 {
        get { unsafe UnsafePointer<UInt64>(bitPattern: UInt(address))!.pointee }
        nonmutating set { unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(address))!.pointee = newValue }
    }
}
