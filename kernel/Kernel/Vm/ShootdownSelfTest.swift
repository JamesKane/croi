import CKernel
import Fmt
import Synchronization

/// Boot self-test for targeted TLB shootdowns: a user address space's
/// changes reach the CPUs running it, and (amd64; rv64 without ASIDs) no
/// others. A reader on one CPU keeps a page's translation hot while the
/// page is unmapped, then made read-only: its next access must fault, not
/// hit a stale entry. An idle bystander CPU must take none of the IPIs.
/// Panics on failure.
enum ShootdownSelfTest {
    nonisolated(unsafe) static var aspace: UInt64 = 0
    nonisolated(unsafe) static var at: UInt64 = 0
    /// 0: warming up; 1: warm (the reader has the entry); 2: changed.
    static let phase = Atomic<Int>(0)
    static var page: UInt64 { KernelLayout.pageSize }

    static func run(_ console: Uart) {
        guard Smp.count >= 3 else {
            console.write("  tlb:    fewer than 3 CPUs, targeted shootdown not tested\n")
            return
        }
        // The reader and the bystander are other CPUs than this thread's
        // (it doesn't block between choosing and changing, so it stays put:
        // a shootdown from the reader's own CPU would be local).
        func cpus() -> (Int, Int) {
            let me = Int(Cpu.current)
            return ((me + 1) % Smp.count, (me + 2) % Smp.count)
        }
        var targeted = false
        do throws(VmError) {
            let a = try UserAspace()
            aspace = a.record.address
            let data = try Vmo(anonymous: 2 * page)
            data.writeWord(at: 0, 0x5EED)
            data.writeWord(at: page, 0x5EEE)

            // Unmap under a reader.
            at = try a.map(data, size: page, rights: .read)
            var (reader, bystander) = cpus()
            phase.store(0, ordering: .relaxed)
            let loads = spawn(reader, keepLoading)
            while phase.load(ordering: .acquiring) == 0 { arch_spin_pause() }
            var before = (TlbShootdown.received(reader), TlbShootdown.received(bystander))
            try a.unmap(at, size: page)
            var after = (TlbShootdown.received(reader), TlbShootdown.received(bystander))
            phase.store(2, ordering: .releasing)
            guard loads.join() == 0 else { panic("tlb self-test: a stale entry survived unmap on another CPU") }

            // Read-only under a writer.
            at = try a.map(data, offset: page, size: page, rights: .read | .write)
            (reader, bystander) = cpus()
            phase.store(0, ordering: .relaxed)
            let stores = spawn(reader, keepStoring)
            while phase.load(ordering: .acquiring) == 0 { arch_spin_pause() }
            let protectBefore = (TlbShootdown.received(reader), TlbShootdown.received(bystander))
            try a.protect(at, size: page, rights: .read)
            let protectAfter = (TlbShootdown.received(reader), TlbShootdown.received(bystander))
            phase.store(2, ordering: .releasing)
            guard stores.join() == 0 else { panic("tlb self-test: a stale writable entry survived protect") }
            try a.unmap(at, size: page)

            before = (before.0 + protectBefore.0, before.1 + protectBefore.1)
            after = (after.0 + protectAfter.0, after.1 + protectAfter.1)
            // amd64 and rv64 without ASIDs target; arm64 broadcasts in
            // hardware and rv64 with ASIDs by IPI (ArchAspace.flushOthers).
            targeted = !Asids.keepsEntriesAcrossSwitches
            if targeted {
                guard after.0 >= before.0 + 2 else { panic("tlb self-test: the CPU running the space got no shootdown") }
                guard after.1 == before.1 else { panic("tlb self-test: an idle CPU got a user space's shootdown") }
            }
        } catch {
            panic("tlb self-test: out of memory")
        }
        console.write("  tlb:    unmap and protect reach a CPU running the space (no stale entry)")
        console.write(targeted ? ", and only those CPUs\n" : "; broadcast to all (ASIDs keep entries)\n")
    }

    /// Loads the page until it is unmapped; the next load must fault.
    private static let keepLoading: Thread.Entry = { _ in
        Scheduler.setAspace(UserAspacePointer(address: aspace))
        defer { Scheduler.setAspace(nil) }
        var value: UInt64 = 0
        for _ in 0..<64 {
            guard unsafe arch_user_load_u64(at, &value) == 0, value == 0x5EED else { return 2 }
        }
        phase.store(1, ordering: .releasing)
        // Until told: the change may show up here before the word does.
        while phase.load(ordering: .acquiring) == 1 { _ = unsafe arch_user_load_u64(at, &value) }
        return unsafe arch_user_load_u64(at, &value) != 0 ? 0 : 1
    }

    /// Stores to the page until it is made read-only; the next store must
    /// fault.
    private static let keepStoring: Thread.Entry = { _ in
        Scheduler.setAspace(UserAspacePointer(address: aspace))
        defer { Scheduler.setAspace(nil) }
        for _ in 0..<64 {
            guard arch_user_store_u64(at, 0x5EEF) == 0 else { return 2 }
        }
        phase.store(1, ordering: .releasing)
        while phase.load(ordering: .acquiring) == 1 { _ = arch_user_store_u64(at, 0x5EEF) }
        return arch_user_store_u64(at, 0x5EEF) != 0 ? 0 : 1
    }

    private static func spawn(_ cpu: Int, _ entry: Thread.Entry) -> ThreadHandle {
        do throws(VmError) {
            return try Scheduler.spawn("tlb", cpu: cpu, entry, 0)
        } catch {
            panic("tlb self-test: spawn failed")
        }
    }
}
