import CKernel
import Fmt
import PageTables
import Synchronization

/// Boot self-test for K7a: a process started by the kernel (the user test
/// program, mode 6) creates, starts, waits for, kills and inspects child
/// processes, a job and VMARs from user mode. Afterwards every process,
/// address space and object it made must be gone: a process holding its
/// own handle included. Panics on failure.
enum ProcessSelfTest {
    static func run(_ console: Uart) {
        let processesBefore = Processes.live.load(ordering: .relaxed)
        let aspacesBefore = UserAspaces.live.load(ordering: .relaxed)
        let objectsBefore = Objects.live.load(ordering: .relaxed)
        let page = KernelLayout.pageSize
        let codeSize = (croi_user_program_size() + page - 1) & ~(page - 1)
        var exitCode: Int64 = 0
        do throws(Status) {
            let created = try Processes.create(job: Processes.rootJob)
            let process = created.process
            let vmar = created.vmar
            let code = try vmStatus { () throws(VmError) -> Vmo in try Vmo(anonymous: codeSize) }
            code.writeBytes(at: 0, from: croi_user_program_address(), count: croi_user_program_size())
            let codeVmo = try VmoObject.wrap(code.record)
            let startup = try vmStatus { () throws(VmError) -> Vmo in try Vmo(anonymous: page) }
            let startupVmo = try VmoObject.wrap(startup.record)
            let stack = try vmStatus { () throws(VmError) -> Vmo in try Vmo(anonymous: 16 * 1024) }
            let record = VmarPointer(object: vmar).info.aspace
            try vmStatus { () throws(VmError) in
                try UserAspace.withView(record) { (aspace: borrowing UserAspace) throws(VmError) in
                    _ = try aspace.map(code, size: codeSize, at: 0x100_0000, rights: [.read, .execute])
                    _ = try aspace.map(stack, size: 16 * 1024, at: 0x200_0000, rights: [.read, .write])
                    _ = try aspace.map(startup, size: page, at: 0x300_0000, rights: [.read])
                }
            }
            // The startup block: job, self, root VMAR, code VMO, code size.
            let job = try Processes.addHandle(Processes.rootJob, rights: JobObject.defaultRights, to: process)
            let me = try Processes.addHandle(process, rights: ProcessObject.defaultRights, to: process)
            let root = try Processes.addHandle(vmar, rights: VmarObject.defaultRights, to: process)
            let codeHandle = try Processes.addHandle(codeVmo, rights: VmoObject.defaultRights.union(.execute),
                                                     to: process)
            var block = InlineArray<3, UInt64>(repeating: 0)
            block[0] = UInt64(job) | UInt64(me) << 32
            block[1] = UInt64(root) | UInt64(codeHandle) << 32
            block[2] = codeSize
            var span = block.mutableSpan
            span.withUnsafeMutableBytes { raw in
                startup.writeBytes(at: 0, from: UInt64(UInt(bitPattern: raw.baseAddress!)), count: 24)
            }
            codeVmo.release()
            startupVmo.release()
            vmar.release()
            let thread = try Processes.createThread(process: process)
            try Processes.start(thread: thread, pc: 0x100_0000, sp: 0x200_0000 + 16 * 1024, arg0: 6,
                                arg1: 0x300_0000, first: true)
            thread.release()
            let giveUp = Clock.now() + 30_000_000_000
            while !Processes.info(process: process).exited {
                guard Clock.now() < giveUp else { panic("process self-test: the test process never ended") }
                Scheduler.sleep(until: Clock.now() + 2_000_000)
            }
            exitCode = Processes.info(process: process).returnCode
            process.release()
        } catch {
            panic("process self-test: setting up the first process")
        }
        guard exitCode == 0x600D else {
            console.write("  proc:   user program failed check ")
            console.write(decimal: UInt64(bitPattern: exitCode))
            console.write("\n")
            panic("process self-test: user side")
        }
        // The last thread drops its references just after the process is
        // marked exited, on its way out: give it a moment.
        let settle = Clock.now() + 2_000_000_000
        while Processes.live.load(ordering: .relaxed) != processesBefore
            || UserAspaces.live.load(ordering: .relaxed) != aspacesBefore
            || Objects.live.load(ordering: .relaxed) != objectsBefore, Clock.now() < settle {
            Scheduler.sleep(until: Clock.now() + 1_000_000)
        }
        guard Processes.live.load(ordering: .relaxed) == processesBefore,
              UserAspaces.live.load(ordering: .relaxed) == aspacesBefore,
              Objects.live.load(ordering: .relaxed) == objectsBefore else {
            console.write("  proc:   leaked: processes ")
            console.write(decimal: UInt64(Processes.live.load(ordering: .relaxed) - processesBefore))
            console.write(", address spaces ")
            console.write(decimal: UInt64(UserAspaces.live.load(ordering: .relaxed) - aspacesBefore))
            console.write(", objects ")
            console.write(decimal: UInt64(Objects.live.load(ordering: .relaxed) - objectsBefore))
            console.write("\n")
            panic("process self-test: something outlived its process")
        }
        console.write("  proc:   processes from user mode: create, map, start, exit codes, kill, fault, ")
        console.write("multi-thread exit, job kill, VMARs; all torn down (a process holding itself too)\n")
    }
}
