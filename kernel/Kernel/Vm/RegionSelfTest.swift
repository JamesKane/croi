import CKernel
import Fmt
import Synchronization

/// Boot self-test for K4b-1: regions, reservations with atomic views
/// (ext 7), partial unmap, protect, commit and decommit. Panics on failure.
enum RegionSelfTest {
    nonisolated(unsafe) static var aspace: UInt64 = 0
    nonisolated(unsafe) static var other: UInt64 = 0
    nonisolated(unsafe) static var viewAt: UInt64 = 0
    nonisolated(unsafe) static var plain: UInt64 = 0
    nonisolated(unsafe) static var sharedAt: UInt64 = 0
    static let stop = Atomic<Bool>(false)
    static let holes = Atomic<Int>(0)
    static let reads = Atomic<Int>(0)
    static var page: UInt64 { KernelLayout.pageSize }

    static func run(_ console: Uart) {
        let freeBefore = pmm.freePages
        let vmosBefore = Vmos.live.load(ordering: .relaxed)
        var swaps = 0
        do throws(VmError) {
            let a = try UserAspace(), b = try UserAspace()
            aspace = a.record.address
            other = b.record.address

            // Regions: aligned, nested, mappings confined, destroy frees.
            let outer = try a.allocateRegion(size: 16 * page, alignment: 64 << 10)
            guard outer.base % (64 << 10) == 0 else { panic("region self-test: alignment") }
            let inner = try a.allocateRegion(size: 4 * page, in: outer.id)
            guard outer.contains(inner.base, inner.size) else { panic("region self-test: nesting") }
            let scratch = try Vmo(anonymous: 4 * page)
            let inside = try a.map(scratch, size: 4 * page, in: inner.id, rights: [.read, .write])
            guard inner.contains(inside, 4 * page) else { panic("region self-test: mapping escaped its region") }
            do throws(VmError) {
                _ = try a.map(scratch, size: page, at: outer.base + 15 * page + page, in: inner.id, rights: [.read])
                panic("region self-test: mapped outside its region")
            } catch {}
            try scratch.commit(offset: 0, size: 4 * page)
            try a.destroyRegion(outer.id)
            guard a.regionCount == 0, a.mappingCount == 0 else { panic("region self-test: destroy left things behind") }
            _ = consume scratch

            // Reservation: views swap atomically under a reader.
            let reservation = try a.allocateRegion(size: 8 * page, reservation: true)
            let red = try Vmo(contiguous: 4 * page), green = try Vmo(contiguous: 4 * page)
            for i in 0..<UInt64(4) {
                red.writeWord(at: i * page, 0xEED0 + i)
                green.writeWord(at: i * page, 0x6EE0 + i)
            }
            viewAt = reservation.base + 2 * page
            try a.mapView(red, size: 4 * page, at: viewAt, in: reservation.id, rights: [.read])
            do throws(VmError) {
                _ = try a.map(red, size: page, at: reservation.base, rights: [.read])
                panic("region self-test: ordinary mapping inside a reservation")
            } catch {}
            stop.store(false, ordering: .relaxed)
            holes.store(0, ordering: .relaxed)
            reads.store(0, ordering: .relaxed)
            let reader = spawn(Smp.count - 1, readViews)
            let until = Clock.now() + 1_000_000_000
            while swaps < 200 || reads.load(ordering: .relaxed) < 1000 {
                guard Clock.now() < until else { break }
                if swaps % 2 == 0 {
                    try a.mapView(green, size: 4 * page, at: viewAt, in: reservation.id, rights: [.read])
                } else {
                    try a.mapView(red, size: 4 * page, at: viewAt, in: reservation.id, rights: [.read])
                }
                swaps += 1
            }
            stop.store(true, ordering: .releasing)
            guard reader.join() == 0 else { panic("region self-test: reader failed") }
            guard holes.load(ordering: .relaxed) == 0 else { panic("region self-test: a view swap left a hole") }
            try a.unmapView(at: viewAt, size: 4 * page, in: reservation.id)
            guard a.query(viewAt) == nil, a.regionCount == 1 else { panic("region self-test: unmapView") }
            _ = consume red
            _ = consume green

            // Partial unmap, protect, decommit (seen from two spaces).
            let data = try Vmo(anonymous: 8 * page)
            plain = try a.map(data, size: 8 * page, rights: [.read, .write])
            sharedAt = try b.map(data, size: 8 * page, rights: [.read])
            for i in 0..<UInt64(8) { data.writeWord(at: i * page, 0xDA7A + i) }
            try a.unmap(plain + 3 * page, size: 2 * page)
            guard a.mappingCount == 2 else { panic("region self-test: partial unmap didn't split") }
            try a.protect(plain, size: 2 * page, rights: [.read])
            // Fault pages 6-7 in through both spaces first, so decommit has
            // live entries to take down (else nothing could go stale).
            guard run(touchTail) == 0 else { panic("region self-test: couldn't read the pages to decommit") }
            try data.decommit(offset: 6 * page, size: 2 * page)
            guard data.committedPages == 6 else { panic("region self-test: decommit") }
            // New contents, through the VMO: a stale entry would still show
            // the old page (since reused for anything at all).
            data.writeWord(at: 6 * page, 0xF4E5)
            data.writeWord(at: 7 * page, 0xF4E6)
            guard run(checkPlain) == 0 else { panic("region self-test: unmap, protect or decommit seen wrong") }
        } catch {
            panic("region self-test: out of memory")
        }
        guard Vmos.live.load(ordering: .relaxed) == vmosBefore, pmm.freePages == freeBefore else {
            panic("region self-test: pages leaked")
        }
        console.write("  region: nested regions, reservations: ")
        console.write(decimal: UInt64(swaps))
        console.write(" atomic view swaps under a reader (")
        console.write(decimal: UInt64(reads.load(ordering: .relaxed)))
        console.write(" reads, no holes), partial unmap, protect, decommit ok\n")
    }

    /// Reads the view's first word until told to stop: it must always be one
    /// of the two views' values, never a fault.
    private static let readViews: Thread.Entry = { _ in
        Scheduler.setAspace(UserAspacePointer(address: aspace))
        defer { Scheduler.setAspace(nil) }
        var value: UInt64 = 0
        while !stop.load(ordering: .acquiring) {
            for i in 0..<UInt64(4) {
                if unsafe arch_user_load_u64(viewAt + i * page, &value) != 0
                    || (value != 0xEED0 + i && value != 0x6EE0 + i) {
                    holes.add(1, ordering: .relaxed)
                }
            }
            reads.add(1, ordering: .relaxed)
        }
        return 0
    }

    /// In A: pages 0-1 read-only (stores refused), 2 writable, 3-4 unmapped,
    /// 5 intact, 6-7 decommitted and rewritten. In B: the same.
    private static let checkPlain: Thread.Entry = { _ in
        Scheduler.setAspace(UserAspacePointer(address: aspace))
        var value: UInt64 = 0
        guard unsafe arch_user_load_u64(plain, &value) == 0, value == 0xDA7A else { return 1 }
        guard arch_user_store_u64(plain + page, 1) == -1 else { return 2 }
        guard arch_user_store_u64(plain + 2 * page, 0xDA7A + 2) == 0 else { return 3 }
        guard unsafe arch_user_load_u64(plain + 3 * page, &value) == -1,
              unsafe arch_user_load_u64(plain + 4 * page, &value) == -1 else { return 4 }
        guard unsafe arch_user_load_u64(plain + 5 * page, &value) == 0, value == 0xDA7A + 5 else { return 5 }
        guard unsafe arch_user_load_u64(plain + 6 * page, &value) == 0, value == 0xF4E5 else { return 6 }
        Scheduler.setAspace(UserAspacePointer(address: other))
        guard unsafe arch_user_load_u64(sharedAt + 7 * page, &value) == 0, value == 0xF4E6 else { return 7 }
        guard unsafe arch_user_load_u64(sharedAt + 5 * page, &value) == 0, value == 0xDA7A + 5 else { return 8 }
        Scheduler.setAspace(nil)
        return 0
    }

    private static let touchTail: Thread.Entry = { _ in
        var value: UInt64 = 0
        Scheduler.setAspace(UserAspacePointer(address: aspace))
        guard unsafe arch_user_load_u64(plain + 6 * page, &value) == 0, value == 0xDA7A + 6 else { return 1 }
        Scheduler.setAspace(UserAspacePointer(address: other))
        guard unsafe arch_user_load_u64(sharedAt + 7 * page, &value) == 0, value == 0xDA7A + 7 else { return 2 }
        Scheduler.setAspace(nil)
        return 0
    }

    private static func run(_ entry: Thread.Entry) -> Int {
        do throws(VmError) {
            return try Scheduler.spawn("region", entry, 0).join()
        } catch {
            panic("region self-test: spawn failed")
        }
    }

    private static func spawn(_ cpu: Int, _ entry: Thread.Entry) -> ThreadHandle {
        do throws(VmError) {
            return try Scheduler.spawn("region", cpu: cpu, entry, 0)
        } catch {
            panic("region self-test: spawn failed")
        }
    }
}
