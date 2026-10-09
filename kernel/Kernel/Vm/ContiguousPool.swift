import CKernel
import Synchronization

/// Memory set aside at boot for contiguous VMOs (Todhchai's boot-time
/// contiguous reservation; Zircon has none), placed below 4 GiB where
/// possible for 32-bit DMA engines such as the Q8B's scan-out. Contiguous
/// VMOs come from here first, so they still succeed once RAM is
/// fragmented. `croi.contiguous_pool=<MiB>` sizes it (default 8, 0 for
/// none). Lending free pool pages to the system (Zircon-style loaning)
/// comes later.
enum ContiguousPool {
    nonisolated(unsafe) private(set) static var base: UInt64 = 0
    nonisolated(unsafe) private(set) static var pages = 0
    /// One bit per pool page, set when allocated.
    nonisolated(unsafe) private static var used = UniqueArray<UInt64>()
    private static let lock = SpinLock()

    static func initialize() {
        let megabytes = BootOptions.number(after: "croi.contiguous_pool=") ?? 8
        let count = megabytes * (1 << 20) / KernelLayout.pageSize
        guard count > 0 else { return }
        guard let phys = pmm.allocateContiguous(count, alignLog2: 21, .vmo, limit: 1 << 32)
                ?? pmm.allocateContiguous(count, alignLog2: 21, .vmo) else { return }
        base = phys
        pages = Int(count)
        used = UniqueArray<UInt64>(repeating: 0, count: (pages + 63) / 64)
    }

    static func contains(_ phys: UInt64) -> Bool {
        pages > 0 && phys >= base && phys < base + UInt64(pages) * KernelLayout.pageSize
    }

    static var freePages: Int {
        lock.withLock {
            var free = 0
            for i in 0..<pages where used[i / 64] & (1 << UInt64(i % 64)) == 0 { free += 1 }
            return free
        }
    }

    /// `count` contiguous pool pages aligned to 2^alignLog2, ending at or
    /// below `limit`; nil if the pool can't.
    static func allocate(_ count: Int, alignLog2: Int, limit: UInt64) -> UInt64? {
        guard pages > 0, count > 0 else { return nil }
        let page = KernelLayout.pageSize
        let alignment = max(UInt64(1) << UInt64(alignLog2), page)
        return lock.withLock { () -> UInt64? in
            var phys = (base + alignment - 1) & ~(alignment - 1)
            while contains(phys), Int((base + UInt64(pages) * page - phys) / page) >= count {
                guard phys + UInt64(count) * page <= limit else { return nil }
                let first = Int((phys - base) / page)
                var run = 0
                while run < count, !isUsed(first + run) { run += 1 }
                if run == count {
                    for i in first..<(first + count) { used[i / 64] |= 1 << UInt64(i % 64) }
                    return phys
                }
                phys = (base + UInt64(first + run + 1) * page + alignment - 1) & ~(alignment - 1)
            }
            return nil
        }
    }

    static func free(_ phys: UInt64, _ count: Int) {
        lock.withLock {
            let first = Int((phys - base) / KernelLayout.pageSize)
            for i in first..<(first + count) {
                guard isUsed(i) else { panic("pool: double free") }
                used[i / 64] &= ~(1 << UInt64(i % 64))
            }
        }
    }

    private static func isUsed(_ i: Int) -> Bool { used[i / 64] & (1 << UInt64(i % 64)) != 0 }
}

/// The data cache line used for VMO cache ops (0: none on this platform).
enum VmoCache {
    nonisolated(unsafe) private(set) static var line: UInt64 = 0

    static func initialize(_ acpi: AcpiTables?) {
        #if arch(riscv64)
        if let acpi, RiscvIsa.everyHartHas("zicbom", acpi) {
            line = RiscvIsa.cacheBlockSize(acpi) ?? 64
        }
        #else
        line = arch_cache_line()
        #endif
    }
}
