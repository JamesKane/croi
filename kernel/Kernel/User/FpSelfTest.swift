import CKernel
import Fmt

/// Boot self-test for K6d: user FP/SIMD state survives switches. Two user
/// threads with different seeds share one CPU (and get preempted mid-way);
/// each must see its own registers (SSE; Neon and SVE; F/D and RVV) and
/// get the same floating-point result as when it ran alone. Panics on
/// failure.
enum FpSelfTest {
    static var codeAt: UInt64 { 0x100_0000 }
    static var stackAt: UInt64 { 0x200_0000 }
    static var stackSize: UInt64 { 16 * 1024 }
    nonisolated(unsafe) static var aspace: UInt64 = 0

    static func run(_ console: Uart) {
        // The address space lives until both threads are joined (a local
        // in a narrower scope would be torn down under them).
        do throws(VmError) {
            let space = try UserAspace()
            aspace = space.record.address
            let size = (croi_user_program_size() + KernelLayout.pageSize - 1) & ~(KernelLayout.pageSize - 1)
            let code = try Vmo(anonymous: size)
            code.writeBytes(at: 0, from: croi_user_program_address(), count: croi_user_program_size())
            _ = try space.map(code, size: size, at: codeAt, rights: [.read, .execute])
            for i in 0..<UInt64(2) {
                let stack = try Vmo(anonymous: stackSize)
                _ = try space.map(stack, size: stackSize, at: stackAt + i * 2 * stackSize, rights: [.read, .write])
            }
            check(console)
        } catch {
            panic("fp self-test: out of memory")
        }
    }

    private static func check(_ console: Uart) {
        let cpu = Smp.count - 1
        let alone = (spawn(cpu, 11, 0).join(), spawn(cpu, 22, 1).join())
        let a = spawn(cpu, 11, 0), b = spawn(cpu, 22, 1)
        let together = (a.join(), b.join())
        guard alone.0 & 0x7000_0000 == 0x1000_0000, alone.1 & 0x7000_0000 == 0x1000_0000 else {
            report(console, alone.0, alone.1)
            panic("fp self-test: registers lost alone")
        }
        guard together.0 == alone.0, together.1 == alone.1, alone.0 != alone.1 else {
            report(console, together.0, together.1)
            panic("fp self-test: FP/SIMD state mixed between threads")
        }
        console.write("  fp:     two user threads on one CPU keep their FP/SIMD registers")
        #if arch(x86_64)
        console.write(" (XSAVE ")
        console.write(hex: croi_xstate_config)
        console.write(")")
        #elseif arch(arm64)
        console.write(croi_xstate_config != 0 ? " (Neon + SVE)" : " (Neon)")
        #elseif arch(riscv64)
        console.write(croi_xstate_config != 0 ? " (F/D + RVV)" : " (F/D)")
        #endif
        console.write(" and results through preemption\n")
    }

    private static func report(_ console: Uart, _ a: Int, _ b: Int) {
        console.write("  fp:     exit codes ")
        console.write(hex: UInt64(bitPattern: Int64(a)))
        console.write(" ")
        console.write(hex: UInt64(bitPattern: Int64(b)))
        console.write("\n")
    }

    private static let user: Thread.Entry = { argument in
        let stack = argument >> 32
        UserTraps.enter(UserAspacePointer(address: aspace), pc: codeAt, sp: stackAt + stack * 2 * stackSize + stackSize,
                        arg0: 3, arg1: argument & 0xFFFF_FFFF)
    }

    private static func spawn(_ cpu: Int, _ seed: UInt64, _ stack: UInt64) -> ThreadHandle {
        var argument = seed | stack << 32
        #if arch(arm64) || arch(riscv64)
        if croi_xstate_config != 0 { argument |= 1 << 16 }  // SVE / V
        #endif
        do throws(VmError) {
            return try Scheduler.spawn("fp", cpu: cpu, user, argument)
        } catch {
            panic("fp self-test: spawn failed")
        }
    }
}
