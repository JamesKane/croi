import CKernel
import Fmt
import PageTables

/// Boot self-test for K4b-2: the contiguous pool, address limits, the RAM
/// deny list, cache ops and cache policy changes. Panics on failure.
enum PhysicalSelfTest {
    static func run(_ console: Uart) {
        let page = KernelLayout.pageSize
        let poolFree = ContiguousPool.freePages
        do throws(VmError) {
            // From the pool first, and back to it.
            let pooled = try Vmo(contiguous: 64 * page, alignLog2: 16)
            guard case .contiguous(let base) = pooled.record.pointee.kind else { panic("phys self-test: kind") }
            guard ContiguousPool.pages == 0 || (ContiguousPool.contains(base) && base % (64 << 10) == 0),
                  ContiguousPool.pages == 0 || ContiguousPool.freePages == poolFree - 64 else {
                panic("phys self-test: pool")
            }

            // An address limit: below 4 GiB; and one nothing satisfies.
            let low = try Vmo(contiguous: 16 * page, limit: 1 << 32)
            guard case .contiguous(let lowBase) = low.record.pointee.kind, lowBase + 16 * page <= 1 << 32 else {
                panic("phys self-test: limit ignored")
            }
            do throws(VmError) {
                _ = try Vmo(contiguous: 16 * page, limit: 1 << 16)
                panic("phys self-test: impossible limit satisfied")
            } catch {}

            // The deny list: kernel memory (a heap page) is RAM too.
            let heapPage = (Smp.records[0] - KernelLayout.physmapBase) & ~(page - 1)
            do throws(VmError) {
                _ = try Vmo(physical: heapPage, size: page, cache: .cached)
                panic("phys self-test: kernel memory was mappable")
            } catch {}

            // Cache ops keep the data; clean, then invalidate clean lines.
            for i in 0..<UInt64(64) { pooled.writeWord(at: i * page, 0xCAC4E + i) }
            try pooled.cacheOp(offset: 0, size: 64 * page, CROI_CACHE_CLEAN)
            try pooled.cacheOp(offset: 0, size: 64 * page, CROI_CACHE_INVALIDATE)
            try pooled.cacheOp(offset: 0, size: 64 * page, CROI_CACHE_CLEAN_INVALIDATE)
            for i in 0..<UInt64(64) where pooled.readWord(at: i * page) != 0xCAC4E + i {
                panic("phys self-test: cache ops lost data")
            }

            // A policy change is refused while mapped and applies after.
            let aspace = try UserAspace()
            let at = try aspace.map(low, size: 16 * page, rights: [.read])
            do throws(VmError) {
                try low.setCachePolicy(.writeCombining)
                panic("phys self-test: cache policy changed while mapped")
            } catch {}
            try aspace.unmap(mappingAt: at)
            try low.setCachePolicy(.writeCombining)
            let again = try aspace.map(low, size: 16 * page, rights: [.read])
            // Only where page tables carry memory types (rv64 without
            // Svpbmt leaves them to the PMAs).
            var typed = true
            #if arch(riscv64)
            typed = PageTableFormat.svpbmt
            #endif
            guard !typed || aspace.query(again)?.attributes.cache != .cached else {
                panic("phys self-test: new policy not used")
            }
        } catch {
            panic("phys self-test: out of memory")
        }
        guard ContiguousPool.freePages == poolFree else { panic("phys self-test: pool pages leaked") }
        console.write("  phys:   contiguous pool ")
        console.write(decimal: (UInt64(ContiguousPool.pages) * page) >> 20)
        console.write(" MiB at ")
        console.write(hex: ContiguousPool.base)
        console.write(", address limits, RAM denied to physical VMOs, cache ops (line ")
        console.write(decimal: VmoCache.line)
        console.write(" B), policy change while unmapped ok\n")
    }

}
