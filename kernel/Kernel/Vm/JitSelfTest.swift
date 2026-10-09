import CKernel
import Fmt
import PageTables
import Synchronization

/// Boot self-test for K4c: W^X everywhere, and per-thread JIT writes in a
/// JIT reservation (protection keys) or dual views (no keys). Panics on
/// failure.
enum JitSelfTest {
    nonisolated(unsafe) static var aspace: UInt64 = 0
    nonisolated(unsafe) static var code: UInt64 = 0
    nonisolated(unsafe) static var key: UInt8 = 0
    static let phase = Atomic<Int>(0)
    static let otherRefused = Atomic<Int>(-1)

    static func run(_ console: Uart) {
        let page = KernelLayout.pageSize
        let rwx: VmRights = [.read, .write, .execute]
        var keysAvailable = 0
        do throws(VmError) {
            let a = try UserAspace()
            aspace = a.record.address
            let vmo = try Vmo(anonymous: 4 * page)

            // W^X outside JIT reservations: refused by map, mapView, protect.
            func refused(_ body: () throws(VmError) -> Void) -> Bool {
                do throws(VmError) { try body(); return false } catch { return true }
            }
            let plain = try a.allocateRegion(size: 8 * page, reservation: true)
            let data = try a.map(vmo, size: 4 * page, rights: [.read, .write])
            guard refused({ () throws(VmError) in _ = try a.map(vmo, size: 4 * page, rights: rwx) }),
                  refused({ () throws(VmError) in try a.mapView(vmo, size: 4 * page, at: plain.base, in: plain.id, rights: rwx) }),
                  refused({ () throws(VmError) in try a.protect(data, size: page, rights: rwx) }) else {
                panic("jit self-test: writable+executable mapping allowed")
            }

            let jit = try a.allocateRegion(size: 16 * page, reservation: true, jit: true)
            switch Jit.mechanism {
            case .protectionKeys:
                guard jit.jitKey != 0 else { panic("jit self-test: no key for a JIT reservation") }
                key = jit.jitKey
                try a.mapView(vmo, size: 4 * page, at: jit.base, in: jit.id, rights: rwx)
                code = jit.base
                phase.store(0, ordering: .relaxed)
                otherRefused.store(-1, ordering: .relaxed)
                let writer = spawn(0, writerThread)
                let other = spawn(max(0, Smp.count - 1), otherThread)
                // Join both before judging: a failed guard ends the address
                // space's lifetime early, while a thread may still use it.
                let (wrote, refused) = (writer.join(), other.join())
                guard wrote == 0, refused == 0, otherRefused.load(ordering: .relaxed) == 1 else {
                    panic("jit self-test: JIT writes weren't per thread")
                }
                guard let entry = a.query(code)?.attributes, entry.writable, entry.executable,
                      entry.protectionKey == key else { panic("jit self-test: JIT page entry") }
                // Keys run out at 15 (key 0 is everyone's).
                var regions = UniqueArray<UInt32>()
                while true {
                    do throws(VmError) {
                        regions.append(try a.allocateRegion(size: page, reservation: true, jit: true).id)
                    } catch {
                        break
                    }
                }
                keysAvailable = regions.count + 1
                guard keysAvailable == 15 else { panic("jit self-test: key count") }
                while let id = regions.popLast() { try a.destroyRegion(id) }
                let again = try a.allocateRegion(size: page, reservation: true, jit: true)
                guard again.jitKey != 0 else { panic("jit self-test: keys not returned") }
            case .views:
                guard jit.jitKey == 0,
                      refused({ () throws(VmError) in try a.mapView(vmo, size: 4 * page, at: jit.base, in: jit.id, rights: rwx) }) else {
                    panic("jit self-test: writable+executable view without keys")
                }
                try a.mapView(vmo, size: 4 * page, at: jit.base, in: jit.id, rights: [.read, .write])
                try a.mapView(vmo, size: 4 * page, at: jit.base + 8 * page, in: jit.id, rights: [.read, .execute])
                code = jit.base
                guard run(viewsThread) == 0 else { panic("jit self-test: views don't share their VMO") }
            }
        } catch {
            panic("jit self-test: out of memory")
        }
        console.write("  jit:    W^X refused everywhere else; ")
        switch Jit.mechanism {
        case .protectionKeys:
            console.write("PKU keys: per-thread write toggling, another CPU still refused, ")
            console.write(decimal: UInt64(keysAvailable))
            console.write(" keys\n")
        case .views:
            console.write(Jit.poePresent ? "POE present but unused: " : "no keys: ")
            console.write("dual RW/RX views share one VMO\n")
        }
    }

    /// Refused by default; writes once opened; refused again once closed.
    private static let writerThread: Thread.Entry = { _ in
        Scheduler.setAspace(UserAspacePointer(address: aspace))
        defer { Scheduler.setAspace(nil) }
        guard arch_user_store_u64(code, 1) == -1 else { return 1 }
        Scheduler.setJitWritable(key, true)
        guard arch_user_store_u64(code, 0xC0DE) == 0 else { return 2 }
        phase.store(1, ordering: .releasing)  // the other thread tries now
        let giveUp = Clock.now() + 2_000_000_000
        while phase.load(ordering: .acquiring) != 2 {
            guard Clock.now() < giveUp else { return 3 }
            arch_spin_pause()
        }
        Scheduler.setJitWritable(key, false)
        var value: UInt64 = 0
        guard arch_user_store_u64(code, 2) == -1, unsafe arch_user_load_u64(code, &value) == 0, value == 0xC0DE else {
            return 4
        }
        return 0
    }

    /// While the writer has writes open, this thread still can't write.
    private static let otherThread: Thread.Entry = { _ in
        Scheduler.setAspace(UserAspacePointer(address: aspace))
        defer { Scheduler.setAspace(nil) }
        let giveUp = Clock.now() + 2_000_000_000
        while phase.load(ordering: .acquiring) != 1 {
            guard Clock.now() < giveUp else { return 1 }
            arch_spin_pause()
        }
        var value: UInt64 = 0
        let refused = arch_user_store_u64(code, 0xBAD) == -1
        let readable = unsafe arch_user_load_u64(code, &value) == 0 && value == 0xC0DE
        otherRefused.store(refused && readable ? 1 : 0, ordering: .relaxed)
        phase.store(2, ordering: .releasing)
        return 0
    }

    private static let viewsThread: Thread.Entry = { _ in
        Scheduler.setAspace(UserAspacePointer(address: aspace))
        defer { Scheduler.setAspace(nil) }
        var value: UInt64 = 0
        let page = KernelLayout.pageSize
        guard arch_user_store_u64(code, 0xC0DE) == 0 else { return 1 }
        guard unsafe arch_user_load_u64(code + 8 * page, &value) == 0, value == 0xC0DE else { return 2 }
        guard arch_user_store_u64(code + 8 * page, 1) == -1 else { return 3 }  // the RX view isn't writable
        return 0
    }

    private static func run(_ entry: Thread.Entry) -> Int {
        do throws(VmError) {
            return try Scheduler.spawn("jit", entry, 0).join()
        } catch {
            panic("jit self-test: spawn failed")
        }
    }

    private static func spawn(_ cpu: Int, _ entry: Thread.Entry) -> ThreadHandle {
        do throws(VmError) {
            return try Scheduler.spawn("jit", cpu: cpu, entry, 0)
        } catch {
            panic("jit self-test: spawn failed")
        }
    }
}
