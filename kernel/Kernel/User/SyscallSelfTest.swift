import CKernel
import Fmt
import Synchronization

/// Boot self-test for K6b: the object syscalls driven from a C program in
/// user mode (user/test/usertest.c), trace_configure and user marks with a
/// tracing resource, the syscall trace category, and SMAP/PAN/SUM: a plain
/// kernel load from a user page faults (and recovers) while the accessors
/// work. Panics on failure.
enum SyscallSelfTest {
    static var codeAt: UInt64 { 0x100_0000 }
    static var stackAt: UInt64 { 0x200_0000 }
    static var stackSize: UInt64 { 16 * 1024 }
    nonisolated(unsafe) static var aspace: UInt64 = 0
    nonisolated(unsafe) static var table: UInt64 = 0
    nonisolated(unsafe) static var resource: UInt32 = 0

    static func run(_ console: Uart) {
        let liveBefore = Objects.live.load(ordering: .relaxed)
        var syscallRecords = 0
        do throws(VmError) {
            let space = try UserAspace()
            aspace = space.record.address
            let size = (croi_user_program_size() + KernelLayout.pageSize - 1) & ~(KernelLayout.pageSize - 1)
            let code = try Vmo(anonymous: size)
            code.writeBytes(at: 0, from: croi_user_program_address(), count: croi_user_program_size())
            _ = try space.map(code, size: size, at: codeAt, rights: [.read, .execute])
            let stack = try Vmo(anonymous: stackSize)
            _ = try space.map(stack, size: stackSize, at: stackAt, rights: [.read, .write])

            // Objects from user mode.
            let handles = HandleTable()
            table = handles.address
            let objects = spawn(user, 0)
            let code0 = objects.join()
            guard code0 == 0x600D else {
                console.write("  sys:    user program failed check ")
                console.write(decimal: UInt64(bitPattern: Int64(code0)))
                console.write("\n")
                panic("syscall self-test: object syscalls")
            }
            guard handles.count == 0 else { panic("syscall self-test: user program leaked handles") }

            // Marks and the syscall category, with a tracing resource.
            do throws(Status) {
                Resources.root.retain()
                let root = try handles.add(Resources.root, rights: ResourceObject.defaultRights)
                resource = try Resources.create(handles, parent: root, kind: .system(base: ResourceObject.tracingBase))
                try handles.close(root)
            } catch {
                panic("syscall self-test: no tracing resource")
            }
            guard spawn(user, 1).join() == 0x600D else { panic("syscall self-test: trace_configure from user mode") }
            var marked = false
            for cpu in 0..<Smp.count {
                Trace.forEachRecord(cpu) { r in
                    if r.kind == UInt16(CROI_TK_MARK), r.a == 0xC401, r.b == 0xFEED { marked = true }
                    if r.kind == UInt16(CROI_TK_SYSCALL_ENTER) { syscallRecords += 1 }
                }
            }
            Trace.release()
            guard marked, syscallRecords >= 2 else { panic("syscall self-test: mark or syscall records missing") }

            // SMAP/PAN/SUM.
            guard spawn(probe, 0).join() == 0 else { panic("syscall self-test: kernel read user memory unprotected") }
        } catch {
            panic("syscall self-test: out of memory")
        }
        guard Objects.live.load(ordering: .relaxed) == liveBefore else { panic("syscall self-test: objects leaked") }
        console.write("  sys:    events, handles and rights, ports and async waits, VMO read/write/map, bad pointers ")
        console.write("refused, from user mode; user marks and ")
        console.write(decimal: UInt64(syscallRecords))
        console.write(" syscall records traced; user access protected")
        console.write(croi_user_protection != 0 ? " (SMAP/PAN/SUM on)\n" : " (no SMAP/PAN on this CPU)\n")
    }

    private static let user: Thread.Entry = { mode in
        UserTraps.enter(UserAspacePointer(address: aspace), handles: table, pc: codeAt, sp: stackAt + stackSize,
                        arg0: mode, arg1: mode == 1 ? UInt64(resource) : 0)
    }

    /// A plain kernel load from the user stack page must fault (recovered),
    /// while the accessor reads it.
    private static let probe: Thread.Entry = { _ in
        Scheduler.setAspace(UserAspacePointer(address: aspace))
        defer { Scheduler.setAspace(nil) }
        var value: UInt64 = 0
        let at = stackAt + stackSize - 8
        guard unsafe arch_user_load_u64(at, &value) == 0 else { return 1 }  // pages it in, too
        if croi_user_protection == 0 { return 0 }  // nothing to check on this CPU
        return arch_user_probe_unprotected(at) == -1 ? 0 : 2
    }

    private static func spawn(_ entry: Thread.Entry, _ argument: UInt64) -> ThreadHandle {
        do throws(VmError) {
            return try Scheduler.spawn("syscall", entry, argument)
        } catch {
            panic("syscall self-test: spawn failed")
        }
    }
}
