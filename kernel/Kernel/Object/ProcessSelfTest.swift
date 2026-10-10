import CKernel
import Fmt
import PageTables
import Synchronization

/// Boot self-tests that run the user test program as a process.
///
/// K7a (mode 6): it creates, starts, waits for, kills and inspects child
/// processes, a job and VMARs from user mode. Afterwards every process,
/// address space and object it made must be gone: a process holding its
/// own handle included.
///
/// K7b (mode 7): channels, eventpairs and calls between two of its threads,
/// the client on a deadline context the kernel provides, which must be lent
/// to the server while it serves (ext 2); the `ipc` trace records of a call
/// share one flow id, the one user space computes. Panics on failure.
enum ProcessSelfTest {
    static func run(_ console: Uart) {
        let before = Counts()
        let exitCode = runInProcess(mode: 6)
        guard exitCode == 0x600D else {
            console.write("  proc:   user program failed check ")
            console.write(decimal: UInt64(bitPattern: exitCode))
            console.write("\n")
            panic("process self-test: user side")
        }
        before.expectUnchanged(console)
        console.write("  proc:   processes from user mode: create, map, start, exit codes, kill, fault, ")
        console.write("multi-thread exit, job kill, VMARs; all torn down (a process holding itself too)\n")
    }

    static func runIpc(_ console: Uart) {
        let before = Counts()
        let context: SchedContext
        do throws(AdmissionRefusal) {
            context = try SchedContext(deadline: DeadlineParams(capacity: 3_000_000, deadline: 10_000_000,
                                                               period: 10_000_000))
        } catch {
            panic("ipc self-test: no deadline context")
        }
        TestHooks.deadlineContext = context.record
        do throws(VmError) {
            try Trace.start(categories: CROI_TRACE_IPC, pages: 16, mode: UInt32(CROI_TRACE_ONESHOT))
        } catch {
            panic("ipc self-test: trace start")
        }
        let exitCode = runInProcess(mode: 7)
        Trace.stop()
        TestHooks.deadlineContext = nil
        releaseWhenUnbound(context)
        guard exitCode == 0x600D else {
            console.write("  ipc:    user program failed check ")
            console.write(decimal: UInt64(bitPattern: exitCode))
            console.write("\n")
            panic("ipc self-test: user side")
        }
        // The last call's flow, as user space computed it from the channel's
        // koids and the txid: its call, read, donation and reply.
        let flow = Syscalls.reported.load(ordering: .relaxed)
        var writes = 0, reads = 0, donations = 0
        for cpu in 0..<Smp.count {
            Trace.forEachRecord(cpu) { record in
                guard record.a == flow else { return }
                switch record.kind {
                case UInt16(CROI_TK_CHANNEL_WRITE): writes += 1
                case UInt16(CROI_TK_CHANNEL_READ): reads += 1
                case UInt16(CROI_TK_DONATE): donations += 1
                default: break
                }
            }
        }
        guard writes == 2, reads >= 1, donations == 1 else {
            console.write("  ipc:    flow records: writes ")
            console.write(decimal: UInt64(writes))
            console.write(", reads ")
            console.write(decimal: UInt64(reads))
            console.write(", donations ")
            console.write(decimal: UInt64(donations))
            console.write("\n")
            panic("ipc self-test: a call's trace records don't share its flow")
        }
        before.expectUnchanged(console)
        console.write("  ipc:    channels (bytes, handles moved, limits, peer closed), eventpairs, info; calls with ")
        console.write("txids, timeout, peer closed; a deadline caller's profile lent to the server (ext 2); ")
        console.write("call, read, donation and reply share the flow user space computes\n")
    }

    /// K7c (mode 8): futexes (inheritance through an owner, requeue,
    /// wake_single_owner) and timers (fire, cancel, zero slack on a deadline
    /// profile), from a process with a deadline context to bind to.
    static func runSync(_ console: Uart) {
        let before = Counts()
        let context: SchedContext
        do throws(AdmissionRefusal) {
            context = try SchedContext(deadline: DeadlineParams(capacity: 3_000_000, deadline: 10_000_000,
                                                               period: 10_000_000))
        } catch {
            panic("sync self-test: no deadline context")
        }
        TestHooks.deadlineContext = context.record
        let exitCode = runInProcess(mode: 8)
        TestHooks.deadlineContext = nil
        releaseWhenUnbound(context)
        guard exitCode == 0x600D else {
            console.write("  sync:   user program failed check ")
            console.write(decimal: UInt64(bitPattern: exitCode))
            console.write("\n")
            panic("sync self-test: user side")
        }
        before.expectUnchanged(console)
        guard Futexes.live.load(ordering: .relaxed) == 0 else { panic("sync self-test: futex records left") }
        console.write("  sync:   futexes (wait/wake, an owner inheriting a deadline waiter's profile, requeue, ")
        console.write("wake_single_owner), timers (fire, cancel, already due, zero slack on a deadline profile)\n")
    }

    /// A user thread that failed a check may exit still bound, and its
    /// process is marked exited just before the thread unbinds on its way
    /// out: drop the context once nothing uses it.
    private static func releaseWhenUnbound(_ context: consuming SchedContext) {
        let record = context.record
        let giveUp = Clock.now() + 2_000_000_000
        while Scheduler.locked({ record.pointee.boundThreads }) != 0, Clock.now() < giveUp {
            Scheduler.sleep(until: Clock.now() + 1_000_000)
        }
        _ = consume context
    }

    /// Live processes, address spaces and objects, to check nothing leaked.
    struct Counts {
        let processes = Processes.live.load(ordering: .relaxed)
        let aspaces = UserAspaces.live.load(ordering: .relaxed)
        let objects = Objects.live.load(ordering: .relaxed)

        /// The last thread drops its references just after the process is
        /// marked exited, on its way out: gives it a moment, then panics if
        /// anything is still left.
        func expectUnchanged(_ console: Uart) {
            let settle = Clock.now() + 2_000_000_000
            var now = Counts()
            while !same(now), Clock.now() < settle {
                Scheduler.sleep(until: Clock.now() + 1_000_000)
                now = Counts()
            }
            guard !same(now) else { return }
            console.write("  proc:   leaked: processes ")
            console.write(decimal: UInt64(now.processes - processes))
            console.write(", address spaces ")
            console.write(decimal: UInt64(now.aspaces - aspaces))
            console.write(", objects ")
            console.write(decimal: UInt64(now.objects - objects))
            console.write("\n")
            panic("process self-test: something outlived its process")
        }

        private func same(_ other: Counts) -> Bool {
            other.processes == processes && other.aspaces == aspaces && other.objects == objects
        }
    }

    /// Runs the user test program as a process in `mode`, with a startup
    /// block at 0x3000000 (job, self, root VMAR, code VMO, code size), and
    /// returns its return code once it has exited.
    static func runInProcess(mode: UInt64) -> Int64 {
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
            try Processes.start(thread: thread, pc: 0x100_0000, sp: 0x200_0000 + 16 * 1024, arg0: mode,
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
        return exitCode
    }
}
