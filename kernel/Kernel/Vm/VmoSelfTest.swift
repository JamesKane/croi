import CKernel
import Fmt
import PageTables
import Synchronization

/// Boot self-test for VMOs, mappings and page faults (K4a). Panics on
/// failure.
enum VmoSelfTest {
    static var pages: UInt64 { 16 }
    nonisolated(unsafe) static var aspace: UInt64 = 0
    nonisolated(unsafe) static var other: UInt64 = 0
    nonisolated(unsafe) static var writable: UInt64 = 0
    nonisolated(unsafe) static var readOnly: UInt64 = 0
    nonisolated(unsafe) static var shared: UInt64 = 0
    nonisolated(unsafe) static var racing: UInt64 = 0
    static let go = Atomic<Bool>(false)

    static func run(_ console: Uart) {
        let freeBefore = pmm.freePages
        let vmosBefore = Vmos.live.load(ordering: .relaxed)
        var resolved = 0
        do throws(VmError) {
            let a = try UserAspace(), b = try UserAspace()
            let vmo = try Vmo(anonymous: pages * KernelLayout.pageSize)
            let size = vmo.size
            aspace = a.record.address
            other = b.record.address
            writable = try a.map(vmo, size: size, rights: [.read, .write])
            readOnly = try a.map(vmo, size: size, rights: [.read])
            shared = try b.map(vmo, size: size, rights: [.read])
            guard writable != readOnly, vmo.committedPages == 0 else { panic("vmo self-test: committed before use") }

            let before = UserAspaces.faultsResolved.load(ordering: .relaxed)
            try Trace.start(categories: CROI_TRACE_VM, pages: 4, mode: CROI_TRACE_ONESHOT)
            guard run(touch) == 0 else { panic("vmo self-test: demand paging, recovery or sharing") }
            Trace.stop()
            resolved = UserAspaces.faultsResolved.load(ordering: .relaxed) - before
            var faults = 0, refused = 0, commits = 0
            for cpu in 0..<Smp.count {
                Trace.forEachRecord(cpu) { record in
                    if record.kind == UInt16(CROI_TK_FAULT) {
                        if record.b & CROI_VM_FAULT_RESOLVED != 0 { faults += 1 } else { refused += 1 }
                    } else if record.kind == UInt16(CROI_TK_COMMIT), record.a == vmo.record.pointee.traceId {
                        commits += 1
                    }
                }
            }
            Trace.release()
            guard faults == resolved, refused >= 2, commits == Int(pages) else { panic("vmo self-test: vm trace records") }
            guard vmo.committedPages == pages else { panic("vmo self-test: wrong pages committed") }
            for i in 0..<pages {
                guard vmo.readWord(at: i * KernelLayout.pageSize) == 0x5E00 + i else {
                    panic("vmo self-test: stores didn't reach the VMO")
                }
            }

            // Four CPUs fault the same fresh pages at once.
            let fresh = try Vmo(anonymous: 32 * KernelLayout.pageSize)
            racing = try a.map(fresh, size: fresh.size, rights: [.read, .write])
            go.store(false, ordering: .relaxed)
            var handles = UniqueArray<ThreadHandle>(capacity: 4)
            for cpu in 0..<min(4, Smp.count) { handles.append(spawn(cpu, race)) }
            go.store(true, ordering: .releasing)
            while let handle = handles.popLast() {
                guard handle.join() == 0 else { panic("vmo self-test: racing faults") }
            }
            guard fresh.committedPages == 32 else { panic("vmo self-test: a page committed twice or not at all") }

            // Contiguous and physical VMOs are mapped at once; 2 MiB aligned
            // ones with large pages.
            let big = try Vmo(contiguous: 2 << 20, alignLog2: 21)
            let at = try a.map(big, size: big.size, at: 0x4000_0000, rights: [.read, .write])
            guard a.query(at + 0x1234)?.pageSize == 2 << 20 else { panic("vmo self-test: no large page") }
            // RAM is refused (the deny list); a hole in the memory map, as
            // device memory would be, is fine.
            guard let ram = pmm.allocatePage() else { panic("vmo self-test: out of memory") }
            do throws(VmError) {
                _ = try Vmo(physical: ram, size: KernelLayout.pageSize, cache: .uncached)
                panic("vmo self-test: a physical VMO over RAM was allowed")
            } catch {
                guard error == .denied(ram) else { panic("vmo self-test: wrong refusal for RAM") }
            }
            pmm.free(ram)
            let phys = (PhysicalMap.highestEnd + (2 << 30)) & ~((1 << 30) - 1)
            let device = try Vmo(physical: phys, size: KernelLayout.pageSize, cache: .uncached)
            let mapped = try a.map(device, size: KernelLayout.pageSize, rights: [.read])
            guard a.query(mapped)?.physical == phys else { panic("vmo self-test: physical VMO misplaced") }

            try a.unmap(mappingAt: readOnly)
            guard a.query(readOnly) == nil, a.mappingCount == 4 else { panic("vmo self-test: unmap") }
            _ = consume device
        } catch {
            panic("vmo self-test: out of memory")
        }
        // Address spaces and VMOs dropped: every page comes back.
        guard Vmos.live.load(ordering: .relaxed) == vmosBefore, pmm.freePages == freeBefore else {
            panic("vmo self-test: pages leaked")
        }
        console.write("  vmo:    demand paging (")
        console.write(decimal: UInt64(resolved))
        console.write(" faults), read-only refused and unmapped recovered, shared across spaces, ")
        console.write("racing faults commit once, contiguous on 2 MiB pages, physical, teardown ok; ")
        console.write(decimal: UInt64(Fixups.count))
        console.write(" fixups\n")
    }

    /// In A: store to each page through the writable mapping, read it back
    /// through the read-only one, see stores there refused, and see an
    /// unmapped address fail instead of panicking. In B: the same data.
    private static let touch: Thread.Entry = { _ in
        Scheduler.setAspace(UserAspacePointer(address: aspace))
        defer { Scheduler.setAspace(nil) }
        let page = KernelLayout.pageSize
        for i in 0..<pages {
            guard arch_user_store_u64(writable + i * page, 0x5E00 + i) == 0 else { return 1 }
        }
        var value: UInt64 = 0
        for i in 0..<pages {
            guard unsafe arch_user_load_u64(readOnly + i * page, &value) == 0, value == 0x5E00 + i else { return 2 }
        }
        guard arch_user_store_u64(readOnly, 1) == -1 else { return 3 }
        guard unsafe arch_user_load_u64(0x7000_0000, &value) == -1 else { return 4 }
        guard unsafe arch_user_load_u64(UserLayout.top + 0x1000, &value) == -1 else { return 5 }
        Scheduler.setAspace(UserAspacePointer(address: other))
        for i in 0..<pages {
            guard unsafe arch_user_load_u64(shared + i * page, &value) == 0, value == 0x5E00 + i else { return 6 }
        }
        return 0
    }

    private static let race: Thread.Entry = { cpu in
        Scheduler.setAspace(UserAspacePointer(address: aspace))
        defer { Scheduler.setAspace(nil) }
        while !go.load(ordering: .acquiring) { arch_spin_pause() }
        var value: UInt64 = 0
        for i in 0..<UInt64(32) {
            let address = racing + i * KernelLayout.pageSize + cpu * 8
            guard arch_user_store_u64(address, cpu + 1) == 0,
                  unsafe arch_user_load_u64(address, &value) == 0, value == cpu + 1 else { return 1 }
        }
        return 0
    }

    private static func run(_ entry: Thread.Entry) -> Int {
        do throws(VmError) {
            return try Scheduler.spawn("vmo", entry, 0).join()
        } catch {
            panic("vmo self-test: spawn failed")
        }
    }

    private static func spawn(_ cpu: Int, _ entry: Thread.Entry) -> ThreadHandle {
        do throws(VmError) {
            return try Scheduler.spawn("vmo", cpu: cpu, entry, UInt64(cpu))
        } catch {
            panic("vmo self-test: spawn failed")
        }
    }
}
