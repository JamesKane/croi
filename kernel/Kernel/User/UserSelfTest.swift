import CKernel
import Fmt
import Synchronization

/// Boot self-test for K6a: user mode. A small built-in program (user.h)
/// runs in a user address space: syscalls with registers preserved, a
/// message written from user mode, null-syscall timing, a fault and a
/// privileged instruction that kill it, and preemption of user code that
/// never enters the kernel. Panics on failure.
enum UserSelfTest {
    static var codeAt: UInt64 { 0x100_0000 }
    static var stackAt: UInt64 { 0x200_0000 }
    static var stackSize: UInt64 { 16 * 1024 }
    nonisolated(unsafe) static var aspace: UInt64 = 0
    static let observerProgress = Atomic<Int>(0)
    static let spinnerDone = Atomic<Bool>(false)

    static func run(_ console: Uart) {
        let liveBefore = UserAspaces.live.load(ordering: .relaxed)
        var nullNs: UInt64 = 0
        var progress = 0
        do throws(VmError) {
            let space = try UserAspace()
            aspace = space.record.address
            let size = (croi_user_test_size() + KernelLayout.pageSize - 1) & ~(KernelLayout.pageSize - 1)
            let code = try Vmo(anonymous: size)
            code.writeBytes(at: 0, from: croi_user_test_address(), count: croi_user_test_size())
            _ = try space.map(code, size: size, at: codeAt, rights: [.read, .execute])
            let stack = try Vmo(anonymous: stackSize)
            _ = try space.map(stack, size: stackSize, at: stackAt, rights: [.read, .write])

            // Mode 0: syscalls, registers, a message, timing.
            guard run(mode: 0) == 0x600D else { panic("user self-test: syscalls or registers") }
            nullNs = Syscalls.reported.load(ordering: .relaxed) / 1000
            // Modes 1 and 3: killed.
            guard run(mode: 1) == UserTraps.killedByFault else { panic("user self-test: user fault not fatal") }
            guard run(mode: 3) == UserTraps.killedByException else { panic("user self-test: privileged instruction") }

            // Mode 2: user code that never enters the kernel is preempted.
            let cpu = Smp.count - 1
            observerProgress.store(0, ordering: .relaxed)
            spinnerDone.store(false, ordering: .relaxed)
            let spinner = spawn(cpu, user, 2)
            let observer = spawn(cpu, observe, 0)
            let spun = spinner.join()
            guard spun == 0x5917 else {
                console.write("  user:   spinner exit code ")
                console.write(hex: UInt64(bitPattern: Int64(spun)))
                console.write("\n")
                panic("user self-test: spinner")
            }
            progress = observerProgress.load(ordering: .relaxed)
            spinnerDone.store(true, ordering: .releasing)
            _ = observer.join()
            guard progress > 0 else { panic("user self-test: user code wasn't preempted") }
        } catch {
            panic("user self-test: out of memory")
        }
        guard UserAspaces.live.load(ordering: .relaxed) == liveBefore else { panic("user self-test: address space leaked") }
        console.write("  user:   syscalls (registers kept), a fault and a privileged instruction killed, ")
        console.write("user code preempted; null syscall ")
        console.write(decimal: nullNs)
        console.write(" ns\n")
    }

    private static let user: Thread.Entry = { mode in
        UserTraps.enter(UserAspacePointer(address: aspace), pc: codeAt, sp: stackAt + stackSize, arg0: mode, arg1: 0)
    }

    private static let observe: Thread.Entry = { _ in
        while !spinnerDone.load(ordering: .acquiring) {
            observerProgress.add(1, ordering: .relaxed)
            for _ in 0..<64 { arch_spin_pause() }
        }
        return 0
    }

    private static func run(mode: UInt64) -> Int {
        spawn(nil, user, mode).join()
    }

    private static func spawn(_ cpu: Int?, _ entry: Thread.Entry, _ argument: UInt64) -> ThreadHandle {
        do throws(VmError) {
            return try Scheduler.spawn("user", cpu: cpu, entry, argument)
        } catch {
            panic("user self-test: spawn failed")
        }
    }
}
