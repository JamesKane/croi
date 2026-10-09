import CKernel
import Fmt
import PageTables
import Synchronization

/// Boot self-test for K4b-3: memory accounts with pressure (ext 6),
/// device-local and pinned VMOs, and the sparse page list. Panics on
/// failure.
enum AccountSelfTest {
    static let hookCalls = Atomic<Int>(0)
    static let lastCharged = Atomic<UInt64>(0)

    static func run(_ console: Uart) {
        let page = KernelLayout.pageSize
        let freeBefore = pmm.freePages
        var sparseCost: UInt64 = 0
        do throws(VmError) {
            let account = MemoryAccount(limit: 16 * page, pressurePercent: 75)
            account.setPressureHook(pressure, 0)
            hookCalls.store(0, ordering: .relaxed)

            // Anonymous: charged per committed page; pressure at 12 pages.
            let anon = try Vmo(anonymous: 32 * page, account: account.record)
            try anon.commit(offset: 0, size: 11 * page)
            guard account.charged == 11 * page, hookCalls.load(ordering: .relaxed) == 0 else {
                panic("account self-test: early pressure")
            }
            try anon.commit(offset: 11 * page, size: 5 * page)
            guard account.charged == 16 * page, hookCalls.load(ordering: .relaxed) == 1,
                  lastCharged.load(ordering: .relaxed) == 12 * page else { panic("account self-test: no pressure") }
            do throws(VmError) {
                try anon.commit(offset: 16 * page, size: page)
                panic("account self-test: over budget")
            } catch {}
            // Decommit uncharges; pressure re-arms below 80% of its level.
            try anon.decommit(offset: 0, size: 10 * page)
            guard account.charged == 6 * page else { panic("account self-test: decommit didn't uncharge") }
            try anon.commit(offset: 0, size: 6 * page)
            guard hookCalls.load(ordering: .relaxed) == 2, account.pressureEvents == 2 else {
                panic("account self-test: pressure didn't re-arm")
            }
            try anon.decommit(offset: 0, size: 32 * page)

            // Pinned (contiguous) and device-local: charged in full, refused
            // over budget, never evictable.
            let pinned = try Vmo(contiguous: 8 * page, account: account.record)
            guard account.charged == 8 * page, pinned.record.pointee.neverEvict else { panic("account self-test: pinned") }
            do throws(VmError) {
                _ = try Vmo(contiguous: 16 * page, account: account.record)
                panic("account self-test: pinned over budget")
            } catch {}
            let vram = (PhysicalMap.highestEnd + (4 << 30)) & ~((1 << 30) - 1)
            let local = try Vmo(deviceLocal: vram, size: 8 * page, cache: .writeCombining, account: account.record)
            guard account.charged == 16 * page, local.record.pointee.neverEvict else { panic("account self-test: device-local") }
            _ = consume local
            _ = consume pinned
            _ = consume anon
            guard account.charged == 0 else { panic("account self-test: releases didn't uncharge") }

            // Sparse: a 64 GiB VMO with three far-apart pages committed.
            let before = pmm.freePages
            let huge = try Vmo(anonymous: 64 << 30)
            for offset in [0, 32 << 30, (64 << 30) - page] as InlineArray<3, UInt64> {
                huge.writeWord(at: offset, offset)
                guard huge.readWord(at: offset) == offset else { panic("account self-test: sparse lookup") }
            }
            guard huge.committedPages == 3 else { panic("account self-test: sparse commit") }
            sparseCost = before - pmm.freePages
            guard sparseCost < 16 else { panic("account self-test: page list isn't sparse") }
        } catch {
            panic("account self-test: out of memory")
        }
        guard pmm.freePages == freeBefore else { panic("account self-test: pages leaked") }
        console.write("  memacct: pages charged on commit, pressure once per crossing (re-armed), over budget refused, ")
        console.write("pinned and device-local charged in full; 64 GiB sparse VMO with 3 pages cost ")
        console.write(decimal: sparseCost)
        console.write(" pages\n")
    }

    private static let pressure: Timers.Callback = { _, charged in
        hookCalls.add(1, ordering: .relaxed)
        lastCharged.store(charged, ordering: .relaxed)
    }
}
