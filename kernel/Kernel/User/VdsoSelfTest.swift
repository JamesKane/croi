import CKernel
import Fmt
import PageTables
import Synchronization

/// Boot self-test for K6c: the vDSO and shared pages in a user address
/// space: page rights, the vDSO clock against the syscall's, the topology
/// page, and the seqlock under a concurrent kernel writer. Panics on
/// failure.
enum VdsoSelfTest {
    static var codeAt: UInt64 { 0x100_0000 }
    static var stackAt: UInt64 { 0x200_0000 }
    static var stackSize: UInt64 { 16 * 1024 }
    nonisolated(unsafe) static var aspace: UInt64 = 0
    nonisolated(unsafe) static var vdsoAt: UInt64 = 0
    static let stop = Atomic<Bool>(false)

    static func run(_ console: Uart) {
        var report: UInt64 = 0
        do throws(VmError) {
            let space = try UserAspace()
            aspace = space.record.address
            let size = (croi_user_program_size() + KernelLayout.pageSize - 1) & ~(KernelLayout.pageSize - 1)
            let code = try Vmo(anonymous: size)
            code.writeBytes(at: 0, from: croi_user_program_address(), count: croi_user_program_size())
            _ = try space.map(code, size: size, at: codeAt, rights: [.read, .execute])
            let stack = try Vmo(anonymous: stackSize)
            _ = try space.map(stack, size: stackSize, at: stackAt, rights: [.read, .write])
            vdsoAt = try Vdso.map(into: space)

            // Every shared page read only (mapped at once: physical VMOs).
            for i in 0..<UInt64(3) {
                let at = vdsoAt + Vdso.codeSize + i * KernelLayout.pageSize
                guard let entry = space.query(at)?.attributes, !entry.writable, !entry.executable else {
                    panic("vdso self-test: shared page mapping")
                }
            }
            do throws(VmError) {
                let shared = try Vmo(sharedKernelPage: Clock.timePage)
                _ = try space.map(shared, size: KernelLayout.pageSize, rights: [.read, .write])
                panic("vdso self-test: a shared page mapped writable")
            } catch {}

            stop.store(false, ordering: .relaxed)
            let writer = spawn(0, write, 0)
            let user = spawn(Smp.count - 1, runUser, 0)
            let code0 = user.join()
            stop.store(true, ordering: .releasing)
            _ = writer.join()
            guard code0 == 0x600D else {
                console.write("  vdso:   user program failed check ")
                console.write(decimal: UInt64(bitPattern: Int64(code0)))
                console.write("\n")
                panic("vdso self-test: user side")
            }
            report = Syscalls.reported.load(ordering: .relaxed)
            // The code faulted in as the program ran: read/execute only.
            guard let codeEntry = space.query(vdsoAt)?.attributes, codeEntry.executable, !codeEntry.writable,
                  codeEntry.user else { panic("vdso self-test: code mapping") }
        } catch {
            panic("vdso self-test: out of memory")
        }
        console.write("  vdso:   clock (")
        console.write(decimal: report & 0xFFFF)
        console.write(" ns vs syscall ")
        console.write(decimal: (report >> 16) & 0xFFFF)
        console.write(" ns), topology page (")
        console.write(decimal: UInt64(Smp.count))
        console.write(" CPUs), power page seqlock under a writer (")
        console.write(decimal: report >> 32)
        console.write(" values seen, none torn), pages read only\n")
    }

    private static let runUser: Thread.Entry = { _ in
        UserTraps.enter(UserAspacePointer(address: aspace), pc: codeAt, sp: stackAt + stackSize, arg0: 2, arg1: vdsoAt)
    }

    private static let write: Thread.Entry = { _ in
        var value: UInt64 = 1
        while !stop.load(ordering: .acquiring) {
            SharedPages.writeTestPair(value)
            value += 1
        }
        return 0
    }

    private static func spawn(_ cpu: Int, _ entry: Thread.Entry, _ argument: UInt64) -> ThreadHandle {
        do throws(VmError) {
            return try Scheduler.spawn("vdso", cpu: cpu, entry, argument)
        } catch {
            panic("vdso self-test: spawn failed")
        }
    }
}
