import CEFI
import CHandoff

/// A firmware memory map held in loader pool memory. Sized with slack once,
/// then refilled in place, so refreshing it never allocates (the final
/// refresh happens right before ExitBootServices).
@safe struct MemoryMap {
    private let buffer: UnsafeMutableRawPointer
    private let capacity: Int
    private var size: UInt = 0
    private(set) var key: UInt = 0
    private var descriptorSize: UInt = 0

    init(boot: BootServices) throws(LoaderError) {
        var needed: UInt = 0
        var key: UInt = 0
        var descriptorSize: UInt = 0
        let status = unsafe boot.getMemoryMap(nil, size: &needed, key: &key, descriptorSize: &descriptorSize)
        guard status == EFI_BUFFER_TOO_SMALL, descriptorSize >= UInt(MemoryLayout<EFI_MEMORY_DESCRIPTOR>.size) else {
            throw .firmware("GetMemoryMap", status)
        }
        // Room for the descriptors our own later allocations will add.
        capacity = Int(needed + 64 * descriptorSize)
        unsafe buffer = try unsafe boot.allocatePool(capacity)
        try refresh(boot: boot)
    }

    mutating func refresh(boot: BootServices) throws(LoaderError) {
        size = UInt(capacity)
        let status = unsafe boot.getMemoryMap(buffer, size: &size, key: &key, descriptorSize: &descriptorSize)
        guard status == EFI_SUCCESS else { throw .firmware("GetMemoryMap", status) }
    }

    /// Upper bound on descriptors the map can ever hold.
    var maxCount: Int { descriptorSize == 0 ? 0 : capacity / Int(descriptorSize) }

    /// Calls `body(type, base, size)` for each descriptor.
    func forEach<E: Error>(_ body: (UInt32, UInt64, UInt64) throws(E) -> Void) throws(E) {
        let stride = Int(descriptorSize)
        let count = Int(size) / stride
        try unsafe withPhysical(UInt64(UInt(bitPattern: buffer)), size: count * stride) { (map: RawSpan) throws(E) in
            for i in 0..<count {
                let at = i * stride
                let type = map.load(fromByteOffset: at, as: UInt32.self)
                let base = map.load(fromByteOffset: at + 8, as: UInt64.self)
                let pages = map.load(fromByteOffset: at + 24, as: UInt64.self)
                try body(type, base, pages * pageSize)
            }
        }
    }

    /// Whether memory of this firmware type is RAM (as opposed to MMIO or holes).
    static func isRam(_ type: UInt32) -> Bool {
        switch type {
        case EfiLoaderCode, EfiLoaderData, EfiBootServicesCode, EfiBootServicesData,
             EfiRuntimeServicesCode, EfiRuntimeServicesData, EfiConventionalMemory,
             EfiACPIReclaimMemory, EfiACPIMemoryNVS, EfiPersistentMemory,
             CroiMemoryType.kernel, CroiMemoryType.handoff, CroiMemoryType.bootfs:
            return true
        default:
            return false
        }
    }

    /// What the kernel should make of memory of this firmware type, once
    /// boot services are gone.
    static func handoffType(_ type: UInt32) -> UInt32 {
        switch type {
        case EfiConventionalMemory, EfiLoaderCode, EfiLoaderData, EfiBootServicesCode, EfiBootServicesData:
            return CROI_MEM_FREE
        case EfiRuntimeServicesCode, EfiRuntimeServicesData: return CROI_MEM_FIRMWARE_RUNTIME
        case EfiACPIReclaimMemory: return CROI_MEM_ACPI_RECLAIM
        case EfiACPIMemoryNVS: return CROI_MEM_ACPI_NVS
        case EfiMemoryMappedIO, EfiMemoryMappedIOPortSpace: return CROI_MEM_MMIO
        case EfiPersistentMemory: return CROI_MEM_PERSISTENT
        case EfiUnusableMemory: return CROI_MEM_UNUSABLE
        case CroiMemoryType.kernel: return CROI_MEM_KERNEL
        case CroiMemoryType.handoff: return CROI_MEM_HANDOFF
        case CroiMemoryType.bootfs: return CROI_MEM_BOOTFS
        default: return CROI_MEM_RESERVED  // includes unaccepted memory
        }
    }
}

/// Writes the final memory map into the handoff's range table: converted
/// to croi types, sorted by base, adjacent same-type ranges merged. Runs
/// after ExitBootServices, so it must not fail or call firmware.
@unsafe func buildRangeTable(
    from map: MemoryMap, into ranges: UnsafeMutablePointer<croi_mem_range_t>, capacity: Int
) -> Int {
    var count = 0
    map.forEach { (type: UInt32, base: UInt64, size: UInt64) in
        guard size > 0, count < capacity else { return }
        unsafe ranges[count] = croi_mem_range_t(base: base, size: size, type: MemoryMap.handoffType(type), reserved: 0)
        count += 1
    }
    // Insertion sort: the map is small and usually sorted already.
    for i in 1..<max(count, 1) {
        let item = unsafe ranges[i]
        var j = i
        while j > 0, unsafe ranges[j - 1].base > item.base {
            unsafe ranges[j] = ranges[j - 1]
            j -= 1
        }
        unsafe ranges[j] = item
    }
    return unsafe mergeRanges(ranges, count: count)
}

/// Re-types [base, base+size) as `type`, splitting the ranges it overlaps.
/// Needs room for two more ranges. Returns the new count.
@unsafe func overlayRange(
    _ ranges: UnsafeMutablePointer<croi_mem_range_t>, count: Int, capacity: Int,
    base: UInt64, size: UInt64, type: UInt32
) -> Int {
    guard size > 0 else { return count }
    let end = base + size
    var i = 0
    var count = count
    while i < count {
        let r = unsafe ranges[i]
        let rEnd = r.base + r.size
        guard r.base < end, base < rEnd, count + 2 <= capacity else {
            i += 1
            continue
        }
        // Up to three pieces: before, overlapped, after.
        var pieces = InlineArray<3, croi_mem_range_t>(repeating: croi_mem_range_t())
        var n = 0
        if r.base < base {
            pieces[n] = croi_mem_range_t(base: r.base, size: base - r.base, type: r.type, reserved: 0)
            n += 1
        }
        let midBase = max(r.base, base)
        let midEnd = min(rEnd, end)
        pieces[n] = croi_mem_range_t(base: midBase, size: midEnd - midBase, type: type, reserved: 0)
        n += 1
        if rEnd > end {
            pieces[n] = croi_mem_range_t(base: end, size: rEnd - end, type: r.type, reserved: 0)
            n += 1
        }
        // Make room for n - 1 extra entries after i.
        if n > 1 {
            var j = count - 1
            while j > i {
                unsafe ranges[j + n - 1] = ranges[j]
                j -= 1
            }
            count += n - 1
        }
        for k in 0..<n {
            unsafe ranges[i + k] = pieces[k]
        }
        i += n
    }
    return unsafe mergeRanges(ranges, count: count)
}

/// Merges adjacent same-type ranges (input sorted by base).
@unsafe private func mergeRanges(_ ranges: UnsafeMutablePointer<croi_mem_range_t>, count: Int) -> Int {
    var merged = 0
    for i in 0..<count {
        let item = unsafe ranges[i]
        if merged > 0, unsafe ranges[merged - 1].type == item.type,
           unsafe ranges[merged - 1].base + ranges[merged - 1].size == item.base {
            unsafe ranges[merged - 1].size += item.size
        } else {
            unsafe ranges[merged] = item
            merged += 1
        }
    }
    return merged
}
