import CKernel
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
    /// Retained; nil for the root job.
    let parent: ObjectPointer?
    /// Child processes and jobs (not retained: each removes itself).
    var children = UniqueArray<UInt64>()
    var dead = false

    static var defaultRights: Rights {
        [.basic, .read, .write, .getProperty, .setProperty, .getPolicy, .setPolicy, .enumerate, .destroy, .signal,
         .manageJob, .manageProcess, .manageThread]
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
    /// Retained.
    let job: ObjectPointer
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

    static var defaultRights: Rights {
        [.basic, .read, .write, .getProperty, .setProperty, .enumerate, .destroy, .signal, .manageProcess,
         .manageThread]
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

    static var defaultRights: Rights {
        [.basic, .read, .write, .getProperty, .setProperty, .destroy, .signal, .manageThread]
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

    static var defaultRights: Rights { [.transfer, .inspect, .read, .write, .execute] }
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
    static var exceptionKill: Int64 { -1025 }
}

// MARK: Operations

enum Processes {
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
        let added = parent.header.lock.withLock { () -> Bool in
            guard !parentJob.pointee.dead else { return false }
            parentJob.pointee.children.append(job.address)
            return true
        }
        guard added else {
            job.release()
            throw .badState
        }
        return job
    }

    /// The job's record is going (Objects.destroy).
    static func destroyJob(_ object: ObjectPointer) {
        let job = JobPointer(object: object)
        if let parent = job.pointee.parent {
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
        let added = job.header.lock.withLock { () -> Bool in
            guard !JobPointer(object: job).pointee.dead else { return false }
            JobPointer(object: job).pointee.children.append(process.address)
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
        removeChild(object, from: process.pointee.job)
        process.pointee.job.release()
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
        object.header.lock.withLock {
            process.pointee.state = .dead
            handles = process.pointee.handles.take()
            aspace = process.pointee.aspace.take()
        }
        _ = handles.take()  // closes every handle
        if let record = aspace?.record {
            // Threads that exited before the last one may not have left yet
            // (one may even be waiting to run on this CPU): let them.
            while Scheduler.locked({ record.pointee.threads }) != 0
                || record.pointee.activeCpus.load(ordering: .acquiring) != 0 {
                Scheduler.yield()
            }
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
        let process = thread.pointee.process
        process.header.lock.withLock {
            let p = ProcessPointer(object: process)
            for i in 0..<p.pointee.threads.count where p.pointee.threads[i] == object.address {
                _ = p.pointee.threads.remove(at: i)
                break
            }
        }
        process.release()
        Objects.free(object, as: ThreadObject.self)
    }

    /// thread_start (and process_start's first thread): runs `thread` at
    /// `pc` with `sp`, arguments in the first two argument registers and
    /// the vDSO's base in the third.
    static func start(thread object: ObjectPointer, pc: UInt64, sp: UInt64, arg0: UInt64, arg1: UInt64,
                      first: Bool) throws(Status) {
        let thread = ThreadObjectPointer(object: object)
        let process = thread.pointee.process
        let p = ProcessPointer(object: process)
        try process.header.lock.withLock { () throws(Status) in
            guard first ? p.pointee.state == .initial : p.pointee.state == .running else { throw .badState }
            try object.header.lock.withLock { () throws(Status) in
                guard thread.pointee.state == .initial else { throw .badState }
                thread.pointee.state = .running
                thread.pointee.pc = pc
                thread.pointee.sp = sp
                thread.pointee.arg0 = arg0
                thread.pointee.arg1 = arg1
            }
            p.pointee.state = .running
            p.pointee.running += 1
        }
        object.retain()  // the scheduler thread's
        do throws(VmError) {
            _ = try Scheduler.spawn("user", extendedState: true, userThreadEntry, object.address)  // detached
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
        UserTraps.enter(process.pointee.aspaceRecord, handles: handles, pc: thread.pointee.pc, sp: thread.pointee.sp,
                        arg0: thread.pointee.arg0, arg1: thread.pointee.arg1, arg2: process.pointee.vdsoBase)
    }

    /// Ends the calling thread (thread_exit, or killed). The process's last
    /// running thread tears it down first.
    static func exitThread(_ code: Int) -> Never {
        let me = Scheduler.current
        guard me.pointee.object != 0 else { Scheduler.exit(code) }  // a kernel test's user thread
        let object = ObjectPointer(address: me.pointee.object)
        let thread = ThreadObjectPointer(object: object)
        object.header.lock.withLock {
            thread.pointee.state = .dead
            thread.pointee.thread = 0
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
            for i in 0..<process.pointee.threads.count { threads.append(process.pointee.threads[i]) }
        }
        for i in 0..<threads.count { kill(thread: ObjectPointer(address: threads[i]), sparing: spared) }
        // Never started: nothing will run to tear it down.
        if object.header.lock.withLock({ process.pointee.running == 0 && process.pointee.handles != nil }) {
            teardown(object)
        }
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
            job.pointee.dead = true
            for i in 0..<job.pointee.children.count {
                let child = ObjectPointer(address: job.pointee.children[i])
                // Only those still referenced elsewhere: a child on its way
                // out (count 0) is skipped.
                if child.header.references.load(ordering: .relaxed) > 0 {
                    child.retain()
                    children.append(child.address)
                }
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

extension VmError {
    /// The Zircon status a syscall reports for it.
    var status: Status {
        switch self {
        case .outOfMemory, .noSpace: .noMemory
        case .dead: .badState
        case .notFound: .notFound
        case .alreadyMapped: .alreadyExists
        case .denied: .accessDenied
        case .unaligned, .outOfRange, .invalidArgument: .invalidArgs
        }
    }
}
