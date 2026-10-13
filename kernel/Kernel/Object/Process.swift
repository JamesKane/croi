import CKernel
import Fmt
import Synchronization

/// Jobs, processes, threads and VMARs (K7a; Zircon's JobDispatcher,
/// ProcessDispatcher, ThreadDispatcher and VmAddressRegionDispatcher).
///
/// A process owns its address space and handle table. Its threads are
/// user threads of the scheduler, each holding a reference to its thread
/// object (which holds the process). The last thread to exit tears the
/// process down from its own context: it switches itself to the kernel's
/// tables, closes every handle (breaking handle cycles, such as a process
/// holding its own handle) and destroys the address space. A process whose
/// threads never started is torn down when its last reference goes.
///
/// Killing marks every thread: interruptible waits end, and each thread
/// exits on its way back to user mode. Lock order: job -> process ->
/// thread object -> scheduler.

// MARK: Jobs

struct JobObject: ~Copyable {
    var header = ObjectHeader(type: .job)
    var name = ObjectName(repeating: 0)
    /// K13e: ZX_INFO_JOB's return code (task_kill's), and the runtime of
    /// the processes and jobs that have gone from it (TASK_RUNTIME).
    var returnCode: Int64 = 0
    var deadCpu: UInt64 = 0
    var deadQueue: UInt64 = 0
    /// Retained; nil for the root job.
    let parent: ObjectPointer?
    /// Child processes and jobs (not retained: each removes itself).
    var children = UniqueArray<UInt64>()
    var dead = false
    /// The kernel's end of its exception channel (retained), or 0.
    var exceptionChannel: UInt64 = 0
    /// K13g: its debugger channels' kernel ends (retained, at most 32).
    var debugChannels = UniqueArray<UInt64>()
    /// Job policy: an action per condition (CROI_POL_*), from the parent.
    var policy = InlineArray<16, UInt8>(repeating: 0)
    /// K10d, ext 8: the CPU reservation tag its threads carry (its own, or
    /// an ancestor's), and the CPUs it reserved itself.
    var reservation: UInt32 = 0
    var reservedCpus: UInt64 = 0

    static var defaultRights: Rights {
        .basic | .read | .write | .getProperty | .setProperty | .getPolicy | .setPolicy | .enumerate | .destroy | .signal
            | .manageJob | .manageProcess | .manageThread
    }
}

@safe struct JobPointer {
    let object: ObjectPointer

    var pointee: JobObject {
        unsafeAddress { unsafe UnsafePointer<JobObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<JobObject>(bitPattern: UInt(object.address))! }
    }
}

// MARK: Processes

struct ProcessObject: ~Copyable {
    enum State { case initial, running, dying, dead }

    var header = ObjectHeader(type: .process)
    var name = ObjectName(repeating: 0)
    /// K13e: when its first thread started (ZX_INFO_PROCESS), and the
    /// runtime of its threads that have exited (TASK_RUNTIME).
    var startTime: UInt64 = 0
    /// K13g: suspensions of the whole process (each of its threads holds one).
    var suspendCount = 0
    /// K13g: its debugger channel's kernel end (retained), or 0.
    var debugChannel: UInt64 = 0
    var deadCpu: UInt64 = 0
    var deadQueue: UInt64 = 0
    /// Retained.
    let job: ObjectPointer
    /// K15a: the memory account its VMOs charge (a reference), or nil.
    /// Its creator's at creation; process_set_account before it starts.
    var account: MemoryAccountPointer? = nil
    var state = State.initial
    var aspace: UserAspace?
    var handles: HandleTable?
    /// The address space's record (kept after teardown, for the VMARs).
    let aspaceRecord: UserAspacePointer
    let vdsoBase: UInt64
    /// Its thread objects (not retained: each removes itself when it dies).
    var threads = UniqueArray<UInt64>()
    /// Started threads still running.
    var running = 0
    var nextThreadIndex: UInt32 = 1
    var returnCode: Int64 = 0
    /// Trace records name its threads task << 12 | index.
    let taskId: UInt32
    /// Its job's CPU reservation tag (K10d), for its threads.
    var reservation: UInt32 = 0
    /// The kernel's end of its exception channel (retained), or 0.
    var exceptionChannel: UInt64 = 0

    static var defaultRights: Rights {
        .basic | .read | .write | .getProperty | .setProperty | .enumerate | .destroy | .signal | .manageProcess
            | .manageThread
    }
}

@safe struct ProcessPointer {
    let object: ObjectPointer

    var pointee: ProcessObject {
        unsafeAddress { unsafe UnsafePointer<ProcessObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<ProcessObject>(bitPattern: UInt(object.address))! }
    }
}

// MARK: Threads

struct ThreadObject: ~Copyable {
    enum State { case initial, running, dead }

    var header = ObjectHeader(type: .thread)
    var name = ObjectName(repeating: 0)
    /// K13e: the exception channel it waits on (ZX_EXCEPTION_CHANNEL_TYPE_*),
    /// and once dead its runtime and last CPU (THREAD_STATS, TASK_RUNTIME).
    var exceptionChannelType: UInt32 = 0
    /// K13g: suspensions (tokens) outstanding; parked meanwhile (Debug).
    let suspendCount = Atomic<Int>(0)
    var suspended = false
    let suspendQueue = QueuePointer.allocate()
    /// K13g: while an exception is offered, its report (THREAD_EXCEPTION_REPORT).
    var inException = false
    var exceptionReport = croi_exception_report_t()
    var startsProcess = false
    var finalCpuTime: UInt64 = 0
    var finalQueueTime: UInt64 = 0
    var lastCpu: UInt32 = 0xFFFF_FFFF
    /// Retained.
    let process: ObjectPointer
    var state = State.initial
    /// The scheduler thread while it runs, or 0.
    var thread: UInt64 = 0
    /// Killed before it got going: it exits instead of entering user mode.
    var killed = false
    let index: UInt32
    var pc: UInt64 = 0
    var sp: UInt64 = 0
    var arg0: UInt64 = 0
    var arg1: UInt64 = 0
    /// The kernel's end of its exception channel (retained), or 0.
    var exceptionChannel: UInt64 = 0
    /// Its user registers while it waits in an exception (an
    /// arch_exception_frame_t), for thread_read_state/write_state; else 0.
    var exceptionFrame: UInt64 = 0

    static var defaultRights: Rights {
        (.basic | .read | .write | .getProperty | .setProperty | .destroy | .signal | .manageThread)
    }
}

@safe struct ThreadObjectPointer {
    let object: ObjectPointer

    var pointee: ThreadObject {
        unsafeAddress { unsafe UnsafePointer<ThreadObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<ThreadObject>(bitPattern: UInt(object.address))! }
    }
}

// MARK: VMARs

/// A region of a process's address space (Zircon's VMAR). It holds a
/// reference to the address space's record, which outlives the process's
/// teardown: operations on a dead address space fail (BAD_STATE).
struct VmarObject: ~Copyable {
    var header = ObjectHeader(type: .vmar)
    let aspace: UserAspacePointer
    let region: UInt32
    let base: UInt64
    let size: UInt64

    static var defaultRights: Rights { .transfer | .inspect | .read | .write | .execute }
}

@safe struct VmarPointer {
    let object: ObjectPointer

    /// Its fields (all fixed at creation).
    struct Info {
        let aspace: UserAspacePointer
        let region: UInt32
        let base: UInt64
        let size: UInt64
    }

    var info: Info { Info(aspace: pointee.aspace, region: pointee.region, base: pointee.base, size: pointee.size) }

    var pointee: VmarObject {
        unsafeAddress { unsafe UnsafePointer<VmarObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<VmarObject>(bitPattern: UInt(object.address))! }
    }
}

/// Return codes of processes the kernel ended (Zircon's).
enum TaskReturnCode {
    static var syscallKill: Int64 { -1024 }
    static var policyKill: Int64 { -1026 }
    static var exceptionKill: Int64 { -1028 }
}

// MARK: Operations

enum Processes {
    /// object_get_child (Zircon's sys_object_get_child): a handle to a
    /// job's child job or process, or a process's thread, by koid. ENUMERATE
    /// on the parent (ACCESS_DENIED); SAME_RIGHTS alone means the parent
    /// handle's rights, anything else must be a subset of them
    /// (ACCESS_DENIED); a koid that isn't a live child NOT_FOUND (Zircon's
    /// lists drop a thread when it exits and a process when it is dead);
    /// other parents WRONG_TYPE. Returns the child retained.
    static func child(_ table: borrowing HandleTable, _ handle: UInt32, koid: UInt64,
                      rights wanted: UInt32) throws(Status) -> (ObjectPointer, Rights) {
        var have = Rights()
        let parent = try table.get(handle, have: &have)
        guard have.contains(.enumerate) else { throw .accessDenied }
        let rights = wanted == Rights.sameRights.rawValue ? have : Rights(rawValue: wanted)
        guard have.isSuperset(of: rights) else { throw .accessDenied }
        let found: ObjectPointer?
        switch parent.type {
        case .process:
            found = parent.object.header.lock.withLock { () -> ObjectPointer? in
                let process = ProcessPointer(object: parent.object)
                for i in 0..<process.pointee.threads.count {
                    let thread = ObjectPointer(address: process.pointee.threads[i])
                    if thread.header.koid == koid { return thread.tryRetain() ? thread : nil }
                }
                return nil
            }
        case .job:
            found = parent.object.header.lock.withLock { () -> ObjectPointer? in
                let job = JobPointer(object: parent.object)
                for i in 0..<job.pointee.children.count {
                    let child = ObjectPointer(address: job.pointee.children[i])
                    if child.header.koid == koid { return child.tryRetain() ? child : nil }
                }
                return nil
            }
        default:
            throw .wrongType
        }
        guard let child = found else { throw .notFound }
        // Dead children are still listed here until their last reference.
        let dead = child.header.lock.withLock { () -> Bool in
            switch child.header.type {
            case .thread: return ThreadObjectPointer(object: child).pointee.state == .dead
            case .process: return ProcessPointer(object: child).pointee.state == .dead
            default: return JobPointer(object: child).pointee.dead
            }
        }
        guard !dead else {
            child.release()
            throw .notFound
        }
        return (child, rights)
    }

    nonisolated(unsafe) private(set) static var rootJob = ObjectPointer(address: 0)
    static let live = Atomic<Int>(0)
    private static let taskIds = Atomic<UInt32>(0)

    static func initialize() {
        guard let job = Objects.allocate(JobObject(parent: nil)) else { panic("process: no memory for the root job") }
        rootJob = job
    }

    // MARK: Jobs

    static func createJob(parent: ObjectPointer) throws(Status) -> ObjectPointer {
        let parentJob = JobPointer(object: parent)
        parent.retain()
        guard let job = Objects.allocate(JobObject(parent: parent)) else {
            parent.release()
            throw .noMemory
        }
        let inherited = parent.header.lock.withLock { parentJob.pointee.policy }
        JobPointer(object: job).pointee.policy = inherited
        let added = parent.header.lock.withLock { () -> Bool in
            guard !parentJob.pointee.dead else { return false }
            parentJob.pointee.children.append(job.address)
            JobPointer(object: job).pointee.reservation = parentJob.pointee.reservation
            return true
        }
        guard added else {
            job.release()
            throw .badState
        }
        return job
    }

    /// job_set_cpu_reservation (K10d, ext 8): only while the job has no
    /// children, and not under an ancestor's reservation. The tag is the
    /// job's koid.
    static func setCpuReservation(_ object: ObjectPointer, mask: UInt64) throws(Status) {
        let job = JobPointer(object: object)
        try object.header.lock.withLock { () throws(Status) in
            guard job.pointee.children.isEmpty, !job.pointee.dead else { throw .badState }
            guard job.pointee.reservation == 0 || job.pointee.reservedCpus != 0 else { throw .badState }
            let tag = UInt32(truncatingIfNeeded: object.header.koid)
            try Scheduler.setReservation(mask: mask, previous: job.pointee.reservedCpus, tag: tag)
            job.pointee.reservedCpus = mask
            job.pointee.reservation = mask == 0 ? 0 : tag
        }
    }

    /// The thread's trace id (task << 12 | index), as its records carry it.
    static func traceId(_ thread: ObjectPointer) -> UInt32 {
        let t = ThreadObjectPointer(object: thread)
        return ProcessPointer(object: t.pointee.process).pointee.taskId << 12 | t.pointee.index
    }

    /// The job's record is going (Objects.destroy).
    static func destroyJob(_ object: ObjectPointer) {
        let job = JobPointer(object: object)
        Exceptions.releaseChannel(job.pointee.exceptionChannel)
        for i in 0..<job.pointee.debugChannels.count { Exceptions.releaseChannel(job.pointee.debugChannels[i]) }
        if job.pointee.reservedCpus != 0 {
            try? Scheduler.setReservation(mask: 0, previous: job.pointee.reservedCpus, tag: job.pointee.reservation)
        }
        if let parent = job.pointee.parent {
            let (cpu, queue) = (job.pointee.deadCpu, job.pointee.deadQueue)
            parent.header.lock.withLock {
                JobPointer(object: parent).pointee.deadCpu += cpu
                JobPointer(object: parent).pointee.deadQueue += queue
            }
            removeChild(object, from: parent)
            parent.release()
        }
        Objects.free(object, as: JobObject.self)
    }

    private static func removeChild(_ child: ObjectPointer, from parent: ObjectPointer) {
        let job = JobPointer(object: parent)
        let empty = parent.header.lock.withLock { () -> Bool in
            for i in 0..<job.pointee.children.count where job.pointee.children[i] == child.address {
                _ = job.pointee.children.remove(at: i)
                break
            }
            return job.pointee.children.isEmpty
        }
        if empty { parent.updateSignals(clear: 0, set: Signals.jobNoProcesses | Signals.jobNoJobs) }
    }

    // MARK: Processes

    /// A new process in `job`, with its address space (the vDSO mapped)
    /// and handle table, and a VMAR for the whole address space.
    static func create(job: ObjectPointer) throws(Status) -> (process: ObjectPointer, vmar: ObjectPointer) {
        guard job.header.type == .job else { throw .wrongType }
        let aspace: UserAspace
        let vdso: UInt64
        do throws(VmError) {
            aspace = try UserAspace()
        } catch {
            throw .noMemory
        }
        do throws(VmError) {
            vdso = try Vdso.map(into: aspace)
        } catch {
            throw .noMemory  // `aspace` goes with the error
        }
        let record = aspace.record
        record.retain()  // the process's own, kept past teardown for its VMARs
        job.retain()
        let taskId = taskIds.add(1, ordering: .relaxed).newValue & 0xF_FFFF
        guard let process = Objects.allocate(ProcessObject(job: job, aspace: aspace, handles: HandleTable(),
                                                           aspaceRecord: record, vdsoBase: vdso,
                                                           taskId: taskId)) else {
            job.release()
            record.release()
            throw .noMemory
        }
        live.add(1, ordering: .relaxed)
        // K15a: its creator's account, unless process_set_account replaces it.
        if let inherited = Accounts.current() {
            inherited.retain()
            ProcessPointer(object: process).pointee.account = inherited
        }
        let added = job.header.lock.withLock { () -> Bool in
            guard !JobPointer(object: job).pointee.dead else { return false }
            JobPointer(object: job).pointee.children.append(process.address)
            ProcessPointer(object: process).pointee.reservation = JobPointer(object: job).pointee.reservation
            return true
        }
        if added { job.updateSignals(clear: Signals.jobNoProcesses, set: 0) }
        guard added else {
            process.release()
            throw .badState
        }
        let vmar: ObjectPointer
        do throws(Status) {
            vmar = try makeVmar(record, region: UserAspace.root, base: UserLayout.base,
                                size: UserLayout.top - UserLayout.base)
        } catch {
            process.release()
            throw error
        }
        return (process, vmar)
    }

    /// The process's record is going (Objects.destroy): tears down what a
    /// process whose threads never ran still owns.
    static func destroyProcess(_ object: ObjectPointer) {
        let process = ProcessPointer(object: object)
        teardown(object)
        let (cpu, queue) = (process.pointee.deadCpu, process.pointee.deadQueue)  // every thread has exited
        process.pointee.job.header.lock.withLock {
            JobPointer(object: process.pointee.job).pointee.deadCpu += cpu
            JobPointer(object: process.pointee.job).pointee.deadQueue += queue
        }
        removeChild(object, from: process.pointee.job)
        process.pointee.job.release()
        process.pointee.account?.release()
        process.pointee.aspaceRecord.release()
        Objects.free(object, as: ProcessObject.self)
        live.subtract(1, ordering: .relaxed)
    }

    /// Closes the process's handles and destroys its address space, once.
    /// No thread of it may still run in it.
    private static func teardown(_ object: ObjectPointer) {
        let process = ProcessPointer(object: object)
        var handles: HandleTable? = nil
        var aspace: UserAspace? = nil
        var channel: UInt64 = 0, debugger: UInt64 = 0
        object.header.lock.withLock {
            process.pointee.state = .dead
            handles = process.pointee.handles.take()
            aspace = process.pointee.aspace.take()
            channel = process.pointee.exceptionChannel
            process.pointee.exceptionChannel = 0
            debugger = process.pointee.debugChannel
            process.pointee.debugChannel = 0
        }
        Exceptions.releaseChannel(channel)
        Exceptions.releaseChannel(debugger)
        _ = handles.take()  // closes every handle
        if let record = aspace?.record {
            // Threads that exited before the last one may not have left yet
            // (one may even be waiting to run on this CPU): let them.
            Scheduler.waitForLeavers(record)
        }
        aspace = nil
        object.updateSignals(clear: 0, set: Signals.taskTerminated)
    }

    // MARK: Threads

    static func createThread(process object: ObjectPointer) throws(Status) -> ObjectPointer {
        let process = ProcessPointer(object: object)
        object.retain()
        let index = object.header.lock.withLock { () -> UInt32? in
            guard process.pointee.state == .initial || process.pointee.state == .running else { return nil }
            let index = process.pointee.nextThreadIndex
            process.pointee.nextThreadIndex += 1
            return index
        }
        guard let index else {
            object.release()
            throw .badState
        }
        guard let thread = Objects.allocate(ThreadObject(process: object, index: index & 0xFFF)) else {
            object.release()
            throw .noMemory
        }
        object.header.lock.withLock { process.pointee.threads.append(thread.address) }
        return thread
    }

    static func destroyThread(_ object: ObjectPointer) {
        let thread = ThreadObjectPointer(object: object)
        Exceptions.releaseChannel(thread.pointee.exceptionChannel)
        let process = thread.pointee.process
        process.header.lock.withLock {
            let p = ProcessPointer(object: process)
            for i in 0..<p.pointee.threads.count where p.pointee.threads[i] == object.address {
                _ = p.pointee.threads.remove(at: i)
                break
            }
        }
        process.release()
        thread.pointee.suspendQueue.deallocate()
        Objects.free(object, as: ThreadObject.self)
    }

    /// thread_start (and process_start's first thread): runs `thread` at
    /// `pc` with `sp`, arguments in the first two argument registers and
    /// the vDSO's base in the third.
    static func start(thread object: ObjectPointer, pc: UInt64, sp: UInt64, arg0: UInt64, arg1: UInt64,
                      first: Bool) throws(Status) {
        // A user address (Zircon's is_user_accessible; review fix: amd64's
        // iretq to a non-canonical one faulted in ring 0, a panic).
        guard pc < UserLayout.top else { throw .invalidArgs }
        let thread = ThreadObjectPointer(object: object)
        let process = thread.pointee.process
        let p = ProcessPointer(object: process)
        try process.header.lock.withLock { () throws(Status) in
            guard first ? p.pointee.state == .initial : p.pointee.state == .running else { throw .badState }
            try object.header.lock.withLock { () throws(Status) in
                guard thread.pointee.state == .initial else { throw .badState }
                thread.pointee.state = .running
                thread.pointee.startsProcess = first
                thread.pointee.pc = pc
                thread.pointee.sp = sp
                thread.pointee.arg0 = arg0
                thread.pointee.arg1 = arg1
            }
            if p.pointee.state == .initial { p.pointee.startTime = Clock.now() }
            if p.pointee.suspendCount > 0 { thread.pointee.suspendCount.add(1, ordering: .relaxed) }  // starts suspended
            p.pointee.state = .running
            p.pointee.running += 1
        }
        object.retain()  // the scheduler thread's
        do throws(VmError) {
            let handle = try Scheduler.spawn("user", extendedState: true, reservation: p.pointee.reservation,
                                             userThreadEntry, object.address)
            // Linked now, not when it first runs: from here on it can be
            // named as a futex owner or killed. (It may already have run
            // and exited: then it stays unlinked.)
            object.header.lock.withLock {
                if thread.pointee.state == .running, thread.pointee.thread == 0 {
                    thread.pointee.thread = handle.thread.address
                }
            }
            _ = consume handle  // detached
        } catch {
            object.header.lock.withLock { thread.pointee.state = .dead }
            object.updateSignals(clear: 0, set: Signals.taskTerminated)
            exitBookkeeping(process: process)
            object.release()
            throw .noMemory
        }
        object.updateSignals(clear: 0, set: Signals.threadRunning)
    }

    private static let userThreadEntry: Thread.Entry = { address in
        let object = ObjectPointer(address: address)
        let thread = ThreadObjectPointer(object: object)
        let me = Scheduler.current
        me.pointee.object = address  // the reference start took
        let process = ProcessPointer(object: thread.pointee.process)
        let killed = object.header.lock.withLock { () -> Bool in
            thread.pointee.thread = me.address
            return thread.pointee.killed
        }
        if killed { Scheduler.locked { me.pointee.killPending = true } }
        let traceId = process.pointee.taskId << 12 | thread.pointee.index
        Scheduler.locked {
            me.pointee.traceId = traceId
            unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!.pointee.traceThread = traceId
        }
        let handles = process.pointee.handles?.address ?? 0
        if killed || handles == 0 { exitThread(0) }
        // Debuggers see it start (K13g): job debuggers the process's first
        // thread (PROCESS_STARTING), the process's debugger every thread
        // (THREAD_STARTING), with registers they may change.
        var start = StartValues(pc: thread.pointee.pc, sp: thread.pointee.sp, arg0: thread.pointee.arg0,
                                arg1: thread.pointee.arg1, arg2: process.pointee.vdsoBase)
        var frame = unsafe ExceptionFrame.startFrame(start)
        let address = withUnsafeMutablePointer(to: &frame) { UInt64(UInt(bitPattern: $0)) }
        if thread.pointee.startsProcess { Exceptions.raiseSynthetic(UInt32(CROI_EXCP_PROCESS_STARTING), frame: address) }
        Exceptions.raiseSynthetic(UInt32(CROI_EXCP_THREAD_STARTING), frame: address)
        start = unsafe ExceptionFrame.startValues(frame)
        if Scheduler.current.pointee.killPending { exitThread(0) }
        UserTraps.enter(process.pointee.aspaceRecord, handles: handles, pc: start.pc, sp: start.sp,
                        arg0: start.arg0, arg1: start.arg1, arg2: start.arg2)
    }

    /// Ends the calling thread (thread_exit, or killed). The process's last
    /// running thread tears it down first.
    static func exitThread(_ code: Int) -> Never {
        let me = Scheduler.current
        guard me.pointee.object != 0 else { Scheduler.exit(code) }  // a kernel test's user thread
        let object = ObjectPointer(address: me.pointee.object)
        let thread = ThreadObjectPointer(object: object)
        Exceptions.raiseSynthetic(UInt32(CROI_EXCP_THREAD_EXITING), frame: 0)  // its debugger (K13g)
        let (cpuTime, queueTime) = Scheduler.runtime(me)
        object.header.lock.withLock {
            thread.pointee.state = .dead
            thread.pointee.thread = 0
            thread.pointee.finalCpuTime = cpuTime
            thread.pointee.finalQueueTime = queueTime
            thread.pointee.lastCpu = UInt32(me.pointee.cpu)
        }
        let owner = thread.pointee.process
        owner.header.lock.withLock {
            ProcessPointer(object: owner).pointee.deadCpu += cpuTime
            ProcessPointer(object: owner).pointee.deadQueue += queueTime
        }
        object.updateSignals(clear: Signals.threadRunning, set: Signals.taskTerminated)
        Scheduler.dropOwnership()  // calls it received and never answered
        let process = thread.pointee.process
        if exitBookkeeping(process: process) {
            Scheduler.setAspace(nil)  // off its tables before they go
            me.pointee.handleTable = 0
            teardown(process)
        }
        me.pointee.object = 0
        object.release()
        Scheduler.exit(code)
    }

    /// One running thread fewer. True if it was the last: the process is
    /// dying, and its caller tears it down.
    @discardableResult
    private static func exitBookkeeping(process object: ObjectPointer) -> Bool {
        let process = ProcessPointer(object: object)
        return object.header.lock.withLock { () -> Bool in
            process.pointee.running -= 1
            guard process.pointee.running == 0 else { return false }
            process.pointee.state = .dying
            return true
        }
    }

    /// process_exit: ends every other thread, then the caller.
    static func exitProcess(_ code: Int64) -> Never {
        let me = Scheduler.current
        guard me.pointee.object != 0 else { Scheduler.exit(Int(code)) }  // a kernel test's user thread
        do {
            let process = ThreadObjectPointer(object: ObjectPointer(address: me.pointee.object)).pointee.process
            kill(process: process, code: code, sparing: me)
        }
        // Dying with the rest (Zircon kills the caller too): its THREAD_
        // EXITING doesn't wait for a debugger (K13g; one that is this
        // process would never answer).
        Scheduler.locked { me.pointee.killPending = true }
        exitThread(0)
    }

    // MARK: Killing

    /// task_kill on a process: every thread ends; its return code is
    /// `code` unless it already had one.
    static func kill(process object: ObjectPointer, code: Int64 = TaskReturnCode.syscallKill,
                     sparing spared: ThreadPointer? = nil) {
        let process = ProcessPointer(object: object)
        var threads = UniqueArray<UInt64>()
        object.header.lock.withLock {
            guard process.pointee.state == .initial || process.pointee.state == .running else { return }
            process.pointee.state = .dying
            process.pointee.returnCode = code
            // The list doesn't own its entries (destroyThread takes one out
            // under this lock, then frees it): hold each across the kill.
            // Without, a thread object freed meanwhile was locked through
            // its poisoned lock word, spinning forever (Todhchai's job kill).
            for i in 0..<process.pointee.threads.count {
                let thread = ObjectPointer(address: process.pointee.threads[i])
                if thread.tryRetain() { threads.append(thread.address) }
            }
        }
        for i in 0..<threads.count {
            let thread = ObjectPointer(address: threads[i])
            kill(thread: thread, sparing: spared)
            thread.release()
        }
        // Never started: nothing will run to tear it down.
        if object.header.lock.withLock({ process.pointee.running == 0 && process.pointee.handles != nil }) {
            teardown(object)
        }
        if threads.count > 0, spared == nil, BootOptions.has("croi.kill_watch=1") { watchKill(object) }
    }

    // MARK: Lockup reports

    /// With `croi.kill_watch=1`: a killed process should be dead within
    /// moments: a kernel thread
    /// holding a reference checks after 1 s and, if it isn't, prints its
    /// threads and the scheduler's state (lockup detection; Todhchai saw
    /// kills finish only when an unrelated interrupt came). A thread, not
    /// a timer: the last reference may go here, and teardown can't run in
    /// interrupt context.
    private static func watchKill(_ object: ObjectPointer) {
        object.retain()
        do throws(VmError) {
            let watcher = try Scheduler.spawn("kill-watch", killWatch, object.address)
            _ = consume watcher  // detached
        } catch {
            object.release()
        }
    }

    private static func writeSigned(_ value: Int, _ console: Uart) {
        if value < 0 { console.write("-") }
        console.write(decimal: UInt64(value.magnitude))
    }

    /// One live thread of a stuck process: the syscall (or trap) it
    /// entered by, and on amd64 the kernel return addresses from its saved
    /// context (raw, for llvm-symbolizer). Racy: a diagnostic.
    private static func describe(_ thread: ThreadPointer, index: UInt32, _ console: Uart) {
        console.write("  thread ")
        console.write(decimal: UInt64(index))
        let user = unsafe UserTraps.userFrame(of: thread)
        if unsafe ExceptionFrame.isSyscall(user.pointee) {
            console.write(" in syscall ")
            console.write(decimal: unsafe ExceptionFrame.syscallNumber(user.pointee))
        } else {
            console.write(" in a trap")
        }
        console.write(" from user pc ")
        console.write(hex: unsafe ExceptionFrame.programCounter(user.pointee))
        #if arch(x86_64)
        if thread != Scheduler.current, thread.pointee.state != .running {
            // arch_context_switch's frame: r15 r14 r13 r12 rbx rbp, return.
            let saved = unsafe UnsafePointer<UInt64>(bitPattern: UInt(thread.pointee.savedSp))!
            var frames = InlineArray<16, UInt64>(repeating: 0)
            frames[0] = unsafe saved[6]
            var count = 1
            unsafe Sampler.walkKernel(saved[5], stack: thread.pointee.savedSp, &frames, &count, encode: false)
            console.write(", kernel frames:")
            for i in 0..<count {
                console.write(" ")
                console.write(hex: frames[i])
            }
        }
        #endif
        console.write("\n")
    }

    private static let killWatch: Thread.Entry = { address in
        let object = ObjectPointer(address: address)
        let process = ProcessPointer(object: object)
        Scheduler.sleep(until: Clock.now() + 1_000_000_000)
        let stuck = object.header.lock.withLock { process.pointee.state != .dead }
        if stuck, let console = panicConsole {
            console.write("kill: process ")
            console.write(decimal: object.header.koid)
            console.write(" not terminated 1 s after its kill; running ")
            object.header.lock.withLock {
                console.write(decimal: UInt64(process.pointee.running))
                console.write(", threads:")
                for i in 0..<process.pointee.threads.count {
                    let thread = ThreadObjectPointer(object: ObjectPointer(address: process.pointee.threads[i]))
                    console.write(" ")
                    console.write(decimal: UInt64(thread.pointee.index))
                    console.write("=")
                    console.write(hex: thread.pointee.thread)
                    console.write(thread.pointee.state == .dead ? "(dead)" : "")
                }
            }
            console.write("\n")
            // Where each live one entered the kernel, and (amd64) the
            // kernel frames it switched out in.
            object.header.lock.withLock {
                for i in 0..<process.pointee.threads.count {
                    let thread = ThreadObjectPointer(object: ObjectPointer(address: process.pointee.threads[i]))
                    guard thread.pointee.thread != 0 else { continue }
                    describe(ThreadPointer(address: thread.pointee.thread), index: thread.pointee.index, console)
                }
            }
            // First, before any IPI of ours wakes a CPU and changes it.
            let saved = arch_interrupts_save()  // dump takes the scheduler lock masked
            Scheduler.dump(to: console)
            arch_interrupts_restore(saved)
            console.write("  locks held (cpu, -1 free): heap ")
            writeSigned(heapLock.holderCpu, console)
            console.write(", pmm ")
            writeSigned(pmmLock.holderCpu, console)
            console.write(", vm ")
            writeSigned(vmLock.holderCpu, console)
            console.write(", debuglog ")
            writeSigned(debugLogLock.holderCpu, console)
            console.write("\n")
            // Where every other CPU is (one that doesn't answer is running
            // with interrupts masked).
            let masked = arch_interrupts_save()
            for cpu in 0..<Smp.count where cpu != Int(Cpu.current) && Ipi.isReady(cpu) {
                Ipi.requestReport(cpu)
            }
            arch_interrupts_restore(masked)
            Scheduler.sleep(until: Clock.now() + 50_000_000)  // let them print
        }
        object.release()
        return 0
    }

    /// task_kill on a thread.
    static func kill(thread object: ObjectPointer, sparing spared: ThreadPointer? = nil) {
        let thread = ThreadObjectPointer(object: object)
        object.header.lock.withLock {
            thread.pointee.killed = true
            guard thread.pointee.thread != 0, thread.pointee.thread != spared?.address else { return }
            let target = ThreadPointer(address: thread.pointee.thread)
            Scheduler.locked { Scheduler.interrupt(target) }
        }
    }

    /// task_kill on a job: its processes and jobs, recursively.
    static func kill(job object: ObjectPointer) {
        let job = JobPointer(object: object)
        var children = UniqueArray<UInt64>()
        object.header.lock.withLock {
            if !job.pointee.dead { job.pointee.returnCode = TaskReturnCode.syscallKill }
            job.pointee.dead = true
            for i in 0..<job.pointee.children.count {
                let child = ObjectPointer(address: job.pointee.children[i])
                // Only those still referenced elsewhere: a child on its way
                // out (count 0) is skipped. One step: its last release can
                // come between a check and a retain.
                if child.tryRetain() { children.append(child.address) }
            }
        }
        for i in 0..<children.count {
            let child = ObjectPointer(address: children[i])
            switch child.header.type {
            case .process: kill(process: child)
            case .job: kill(job: child)
            default: break
            }
            child.release()
        }
        object.updateSignals(clear: 0, set: Signals.taskTerminated)
    }

    /// A user thread's fault or bad exception, until K7d's exception
    /// channels: the whole process dies (Zircon's default with no handler).
    static func killCurrentProcess(code: Int64) -> Never {
        let me = Scheduler.current
        guard me.pointee.object != 0 else { Scheduler.exit(Int(code)) }
        let process = ThreadObjectPointer(object: ObjectPointer(address: me.pointee.object)).pointee.process
        kill(process: process, code: code, sparing: me)
        exitThread(Int(code))
    }

    /// Adds a handle to `object` (a reference of its own) to `process`'s
    /// table: how the kernel hands a first process its handles.
    static func addHandle(_ object: ObjectPointer, rights: Rights, to process: ObjectPointer) throws(Status) -> UInt32 {
        let p = ProcessPointer(object: process)
        object.retain()
        do throws(Status) {
            return try process.header.lock.withLock { () throws(Status) -> UInt32 in
                guard let table = p.pointee.handles?.address else { throw .badState }
                return try HandleTable.withBorrowed(table) { (handles: borrowing HandleTable) throws(Status) -> UInt32 in
                    try handles.add(object, rights: rights)
                }
            }
        } catch {
            object.release()
            throw error
        }
    }

    /// The calling thread was killed: called on its way back to user mode.
    static func checkKilled() {
        let me = Scheduler.current
        if me.pointee.killPending { exitThread(Int(TaskReturnCode.syscallKill)) }
    }

    // MARK: Info

    struct ProcessInfo {
        var returnCode: Int64
        var started: Bool
        var exited: Bool
    }

    static func info(process object: ObjectPointer) -> ProcessInfo {
        let process = ProcessPointer(object: object)
        return object.header.lock.withLock {
            ProcessInfo(returnCode: process.pointee.returnCode, started: process.pointee.state != .initial,
                        exited: process.pointee.state == .dead)
        }
    }

    // MARK: VMARs

    static func makeVmar(_ aspace: UserAspacePointer, region: UInt32, base: UInt64,
                         size: UInt64) throws(Status) -> ObjectPointer {
        aspace.retain()
        guard let vmar = Objects.allocate(VmarObject(aspace: aspace, region: region, base: base, size: size)) else {
            aspace.release()
            throw .noMemory
        }
        return vmar
    }

    static func destroyVmar(_ object: ObjectPointer) {
        VmarPointer(object: object).pointee.aspace.release()
        Objects.free(object, as: VmarObject.self)
    }
}

/// Runs VM work for a syscall or a kernel caller that speaks Status.
func vmStatus<R: ~Copyable>(_ body: () throws(VmError) -> R) throws(Status) -> R {
    do throws(VmError) {
        return try body()
    } catch {
        throw error.status
    }
}

extension Processes {
    /// The scheduler thread of thread object `object`, pinned (review fix:
    /// it was read under the object's lock and used after, while the thread
    /// could exit and be freed); nil if it isn't running. The caller calls
    /// `Scheduler.unpin`.
    static func pinnedThread(_ object: ObjectPointer) -> ThreadPointer? {
        object.header.lock.withLock { () -> ThreadPointer? in
            let address = ThreadObjectPointer(object: object).pointee.thread
            guard address != 0 else { return nil }
            let thread = ThreadPointer(address: address)
            Scheduler.pin(thread)  // object -> scheduler: the documented order
            return thread
        }
    }
}

extension VmError {
    /// The Zircon status a syscall reports for it.
    var status: Status {
        switch self {
        case .outOfMemory, .noSpace: .noMemory
        case .dead, .pinned, .badState: .badState
        case .notFound: .notFound
        case .alreadyMapped: .alreadyExists
        case .denied, .accessDenied: .accessDenied
        case .unaligned, .outOfRange, .invalidArgument: .invalidArgs
        case .notSupported: .notSupported
        }
    }
}
