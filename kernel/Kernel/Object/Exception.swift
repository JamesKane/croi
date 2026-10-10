import CKernel
import Synchronization

/// Exceptions and job policy (K7d, requirement 11; Zircon's exception
/// channels and ZX_POL_*).
///
/// A user thread's fault (or a policy exception) is offered to exception
/// channels in Zircon's order: the thread's, its process's, then each job
/// up the tree. Each offer is a message (croi_exception_info_t) carrying a
/// handle to a new exception object; the faulting thread waits
/// (interruptibly) until that object's last reference goes, then reads
/// the state the handler left: HANDLED resumes it (with any registers the
/// handler wrote through thread_write_state), THREAD_EXIT ends it,
/// TRY_NEXT goes on to the next channel. With no handler left, the
/// process is killed (exception kill). The kernel keeps its end of each
/// task's channel; a closed user end just skips that task.

/// Where the faulting thread waits; shared with the exception object.
struct ExceptionWait: ~Copyable {
    let queue = QueuePointer.allocate()
    var done = false
    var state = UInt32(CROI_EXCEPTION_STATE_TRY_NEXT)
    let references = Atomic<Int>(2)
}

@safe struct ExceptionWaitPointer {
    let address: UInt64

    var pointee: ExceptionWait {
        unsafeAddress { unsafe UnsafePointer<ExceptionWait>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<ExceptionWait>(bitPattern: UInt(address))! }
    }

    static func allocate() -> ExceptionWaitPointer? {
        guard let raw = unsafe heap.allocate(size: MemoryLayout<ExceptionWait>.size, alignment: 16) else { return nil }
        unsafe raw.bindMemory(to: ExceptionWait.self, capacity: 1).initialize(to: ExceptionWait())
        return ExceptionWaitPointer(address: UInt64(UInt(bitPattern: raw)))
    }

    func release() {
        guard pointee.references.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 else { return }
        pointee.queue.deallocate()
        let raw = unsafe UnsafeMutablePointer<ExceptionWait>(bitPattern: UInt(address))!
        unsafe raw.deinitialize(count: 1)
        unsafe heap.free(UnsafeMutableRawPointer(raw))
    }
}

struct ExceptionObject: ~Copyable {
    var header = ObjectHeader(type: .exception)
    /// Retained.
    let thread: ObjectPointer
    let process: ObjectPointer
    let type: UInt32
    var state = UInt32(CROI_EXCEPTION_STATE_TRY_NEXT)
    let wait: ExceptionWaitPointer

    static var defaultRights: Rights { [.transfer, .duplicate, .wait, .inspect, .getProperty, .setProperty] }
}

@safe struct ExceptionPointer {
    let object: ObjectPointer

    var pointee: ExceptionObject {
        unsafeAddress { unsafe UnsafePointer<ExceptionObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<ExceptionObject>(bitPattern: UInt(object.address))! }
    }
}

enum Exceptions {
    enum Disposition { case resume, exitThread, unhandled }

    // MARK: Raising

    /// Offers the calling thread's exception (`type`, registers at
    /// `frame`) to its handlers.
    static func raise(_ type: UInt32, frame: UnsafeMutablePointer<arch_exception_frame_t>) -> Disposition {
        let me = Scheduler.current
        guard me.pointee.object != 0 else { return .unhandled }  // a kernel test's bare user thread
        let thread = ObjectPointer(address: me.pointee.object)
        let threadObject = ThreadObjectPointer(object: thread)
        let process = threadObject.pointee.process
        let frameAddress = UInt64(UInt(bitPattern: frame))
        thread.header.lock.withLock { threadObject.pointee.exceptionFrame = frameAddress }
        defer { thread.header.lock.withLock { threadObject.pointee.exceptionFrame = 0 } }

        // The handlers, in order, each retained while we use it.
        var channels = InlineArray<16, UInt64>(repeating: 0)
        var count = 0
        func take(_ endpoint: UInt64) {
            guard endpoint != 0, count < channels.count else { return }
            let channel = ObjectPointer(address: endpoint)
            if channel.tryRetain() {
                channels[count] = endpoint
                count += 1
            }
        }
        take(thread.header.lock.withLock { threadObject.pointee.exceptionChannel })
        take(process.header.lock.withLock { ProcessPointer(object: process).pointee.exceptionChannel })
        var job: ObjectPointer? = ProcessPointer(object: process).pointee.job
        while let current = job {
            take(current.header.lock.withLock { JobPointer(object: current).pointee.exceptionChannel })
            job = JobPointer(object: current).pointee.parent
        }

        var disposition = Disposition.unhandled
        for i in 0..<count where disposition == .unhandled {
            let channel = ObjectPointer(address: channels[i])
            switch offer(type, to: channel, thread: thread, process: process) {
            case .some(UInt32(CROI_EXCEPTION_STATE_HANDLED)): disposition = .resume
            case .some(UInt32(CROI_EXCEPTION_STATE_THREAD_EXIT)): disposition = .exitThread
            case .none: disposition = .exitThread  // killed while waiting
            default: break  // TRY_NEXT, or nobody listening
            }
        }
        for i in 0..<count { ObjectPointer(address: channels[i]).release() }
        return disposition
    }

    /// One handler's turn: the state it left, TRY_NEXT if the message
    /// couldn't be sent, nil if the thread was killed meanwhile.
    private static func offer(_ type: UInt32, to channel: ObjectPointer, thread: ObjectPointer,
                              process: ObjectPointer) -> UInt32? {
        let tryNext = UInt32(CROI_EXCEPTION_STATE_TRY_NEXT)
        guard let wait = ExceptionWaitPointer.allocate() else { return tryNext }
        thread.retain()
        process.retain()
        guard let exception = Objects.allocate(ExceptionObject(thread: thread, process: process, type: type,
                                                               wait: wait)) else {
            thread.release()
            process.release()
            wait.release()
            wait.release()
            return tryNext
        }
        guard let message = MessagePointer.allocate(bytes: UInt32(MemoryLayout<croi_exception_info_t>.size),
                                                    handles: 1) else {
            exception.release()
            wait.release()
            return tryNext
        }
        let info = croi_exception_info_t(pid: process.header.koid, tid: thread.header.koid, type: type, padding: 0)
        unsafe UnsafeMutablePointer<croi_exception_info_t>(bitPattern: UInt(message.data))!.pointee = info
        message.setHandle(0, object: exception.address, rights: ExceptionObject.defaultRights)  // its reference
        do throws(Status) {
            try Channels.write(channel, message)
        } catch {
            wait.release()  // the message (and the exception) went with the failure
            return tryNext
        }
        var interrupted = false
        let state = Scheduler.locked { () -> UInt32 in
            while !wait.pointee.done {
                if Scheduler.block(on: wait.pointee.queue, deadline: .max, interruptible: true) == .interrupted {
                    interrupted = true
                    return tryNext
                }
            }
            return wait.pointee.state
        }
        wait.release()
        return interrupted ? nil : state
    }

    /// The exception object's last reference went: its handler is done.
    static func destroy(_ object: ObjectPointer) {
        let exception = ExceptionPointer(object: object)
        let wait = exception.pointee.wait
        let state = exception.pointee.state
        Scheduler.locked {
            wait.pointee.state = state
            wait.pointee.done = true
            Scheduler.wakeAll(wait.pointee.queue)
        }
        wait.release()
        exception.pointee.thread.release()
        exception.pointee.process.release()
        Objects.free(object, as: ExceptionObject.self)
    }

    // MARK: Channels

    /// task_create_exception_channel: a new channel whose kernel end the
    /// task keeps. One per task while its user end is open.
    static func createChannel(for task: ObjectPointer) throws(Status) -> ObjectPointer {
        let (kernelEnd, userEnd) = try Channels.create()
        var replaced: UInt64 = 0
        let bound = task.header.lock.withLock { () -> Bool in
            let existing = channel(of: task)
            if existing != 0, ChannelPointer(object: ObjectPointer(address: existing)).pointee.peer != 0 { return true }
            replaced = existing
            setChannel(of: task, kernelEnd.address)
            return false
        }
        guard !bound else {
            kernelEnd.release()
            userEnd.release()
            throw .alreadyBound
        }
        releaseChannel(replaced)
        return userEnd
    }

    /// The task's kernel channel end (its lock held).
    private static func channel(of task: ObjectPointer) -> UInt64 {
        switch task.header.type {
        case .thread: ThreadObjectPointer(object: task).pointee.exceptionChannel
        case .process: ProcessPointer(object: task).pointee.exceptionChannel
        default: JobPointer(object: task).pointee.exceptionChannel
        }
    }

    private static func setChannel(of task: ObjectPointer, _ endpoint: UInt64) {
        switch task.header.type {
        case .thread: ThreadObjectPointer(object: task).pointee.exceptionChannel = endpoint
        case .process: ProcessPointer(object: task).pointee.exceptionChannel = endpoint
        default: JobPointer(object: task).pointee.exceptionChannel = endpoint
        }
    }

    static func releaseChannel(_ endpoint: UInt64) {
        if endpoint != 0 { ObjectPointer(address: endpoint).release() }
    }

    // MARK: Properties and registers

    static func setState(_ object: ObjectPointer, _ state: UInt32) throws(Status) {
        guard state <= UInt32(CROI_EXCEPTION_STATE_THREAD_EXIT) else { throw .invalidArgs }
        object.header.lock.withLock { ExceptionPointer(object: object).pointee.state = state }
    }

    static func state(_ object: ObjectPointer) -> UInt32 {
        object.header.lock.withLock { ExceptionPointer(object: object).pointee.state }
    }

    /// The registers of `thread`, which must be waiting in an exception.
    static func readState(_ thread: ObjectPointer) throws(Status) -> croi_thread_state_general_regs_t {
        let frame = try unsafe frame(of: thread)
        return unsafe generalRegisters(frame.pointee)
    }

    static func writeState(_ thread: ObjectPointer, _ registers: croi_thread_state_general_regs_t) throws(Status) {
        let frame = try unsafe frame(of: thread)
        try unsafe setGeneralRegisters(&frame.pointee, registers)
    }

    private static func frame(of thread: ObjectPointer) throws(Status) -> UnsafeMutablePointer<arch_exception_frame_t> {
        let address = thread.header.lock.withLock { ThreadObjectPointer(object: thread).pointee.exceptionFrame }
        guard let frame = unsafe UnsafeMutablePointer<arch_exception_frame_t>(bitPattern: UInt(address)) else {
            throw .badState
        }
        return unsafe frame
    }

    #if arch(x86_64)
    private static func generalRegisters(_ f: arch_exception_frame_t) -> croi_thread_state_general_regs_t {
        croi_thread_state_general_regs_t(rax: f.rax, rbx: f.rbx, rcx: f.rcx, rdx: f.rdx, rsi: f.rsi, rdi: f.rdi,
                                         rbp: f.rbp, rsp: f.rsp, r8: f.r8, r9: f.r9, r10: f.r10, r11: f.r11,
                                         r12: f.r12, r13: f.r13, r14: f.r14, r15: f.r15, rip: f.rip,
                                         rflags: f.rflags, fs_base: 0, gs_base: 0)
    }

    private static func setGeneralRegisters(_ f: inout arch_exception_frame_t,
                                            _ r: croi_thread_state_general_regs_t) throws(Status) {
        guard r.rip < UserLayout.top else { throw .invalidArgs }
        f.rax = r.rax; f.rbx = r.rbx; f.rcx = r.rcx; f.rdx = r.rdx; f.rsi = r.rsi; f.rdi = r.rdi
        f.rbp = r.rbp; f.rsp = r.rsp; f.r8 = r.r8; f.r9 = r.r9; f.r10 = r.r10; f.r11 = r.r11
        f.r12 = r.r12; f.r13 = r.r13; f.r14 = r.r14; f.r15 = r.r15; f.rip = r.rip
        let userFlags: UInt64 = 0xCD5  // CF PF AF ZF SF DF OF
        f.rflags = (f.rflags & ~userFlags) | (r.rflags & userFlags)
    }
    #elseif arch(arm64)
    private static func generalRegisters(_ f: arch_exception_frame_t) -> croi_thread_state_general_regs_t {
        var r = croi_thread_state_general_regs_t()
        withUnsafeBytes(of: f.x) { x in
            withUnsafeMutableBytes(of: &r.r) { unsafe $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: x[0..<240])) }
        }
        r.lr = f.x.30
        r.sp = f.sp
        r.pc = f.elr
        r.cpsr = f.spsr
        return r
    }

    private static func setGeneralRegisters(_ f: inout arch_exception_frame_t,
                                            _ r: croi_thread_state_general_regs_t) throws(Status) {
        guard r.pc < UserLayout.top else { throw .invalidArgs }
        withUnsafeBytes(of: r.r) { source in
            withUnsafeMutableBytes(of: &f.x) { unsafe $0.copyMemory(from: source) }
        }
        f.x.30 = r.lr
        f.sp = r.sp
        f.elr = r.pc
        let nzcv: UInt64 = 0xF000_0000
        f.spsr = (f.spsr & ~nzcv) | (r.cpsr & nzcv)
    }
    #elseif arch(riscv64)
    private static func generalRegisters(_ f: arch_exception_frame_t) -> croi_thread_state_general_regs_t {
        var r = croi_thread_state_general_regs_t()
        r.pc = f.sepc
        withUnsafeBytes(of: f.x) { x in
            withUnsafeMutableBytes(of: &r.x) { unsafe $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: x[8..<256])) }
        }
        return r
    }

    private static func setGeneralRegisters(_ f: inout arch_exception_frame_t,
                                            _ r: croi_thread_state_general_regs_t) throws(Status) {
        guard r.pc < UserLayout.top else { throw .invalidArgs }
        f.sepc = r.pc
        withUnsafeBytes(of: r.x) { source in
            withUnsafeMutableBytes(of: &f.x) { unsafe UnsafeMutableRawBufferPointer(rebasing: $0[8..<256]).copyMemory(from: source) }
        }
    }
    #endif
}

// MARK: Policy

enum Policy {
    /// The action the calling thread's job sets for `condition`.
    static func action(_ condition: UInt32) -> UInt32 {
        let me = Scheduler.current
        guard me.pointee.object != 0, condition < UInt32(CROI_POL_CONDITIONS) else {
            return UInt32(CROI_POL_ACTION_ALLOW)
        }
        let process = ThreadObjectPointer(object: ObjectPointer(address: me.pointee.object)).pointee.process
        let job = ProcessPointer(object: process).pointee.job
        return job.header.lock.withLock { UInt32(JobPointer(object: job).pointee.policy[Int(condition)]) }
    }

    /// Applies the job's policy for `condition` to the calling thread's
    /// syscall: returns to allow it, throws ACCESS_DENIED to deny it. A
    /// kill marks the process killed (the thread exits on its way out); an
    /// exception action raises POLICY_ERROR first.
    static func check(_ condition: UInt32) throws(Status) {
        let action = action(condition)
        switch action {
        case UInt32(CROI_POL_ACTION_ALLOW):
            return
        case UInt32(CROI_POL_ACTION_KILL):
            killProcess(TaskReturnCode.policyKill)
            throw .accessDenied
        case UInt32(CROI_POL_ACTION_ALLOW_EXCEPTION), UInt32(CROI_POL_ACTION_DENY_EXCEPTION):
            let me = Scheduler.current
            let frame = unsafe UserTraps.userFrame(of: me)
            switch unsafe Exceptions.raise(UInt32(CROI_EXCP_POLICY_ERROR), frame: frame) {
            case .resume: break
            case .exitThread: Scheduler.locked { Scheduler.interrupt(me) }
            case .unhandled: killProcess(TaskReturnCode.exceptionKill)
            }
            if action == UInt32(CROI_POL_ACTION_DENY_EXCEPTION) { throw .accessDenied }
        default:
            throw .accessDenied
        }
    }

    private static func killProcess(_ code: Int64) {
        let me = Scheduler.current
        guard me.pointee.object != 0 else { return }
        let process = ThreadObjectPointer(object: ObjectPointer(address: me.pointee.object)).pointee.process
        Processes.kill(process: process, code: code)
    }

    /// job_set_policy: only while the job has no children. RELATIVE skips
    /// conditions the job already restricts; ABSOLUTE refuses a different
    /// action for one. NEW_ANY sets every NEW_* condition.
    static func set(_ job: ObjectPointer, options: UInt32, _ entries: InlineArray<16, croi_policy_basic_t>,
                    count: Int) throws(Status) {
        guard options <= UInt32(CROI_JOB_POL_ABSOLUTE), count <= 16 else { throw .invalidArgs }
        for i in 0..<count {
            guard entries[i].condition < UInt32(CROI_POL_CONDITIONS),
                  entries[i].policy <= UInt32(CROI_POL_ACTION_KILL) else { throw .invalidArgs }
        }
        let jobPointer = JobPointer(object: job)
        try job.header.lock.withLock { () throws(Status) in
            guard jobPointer.pointee.children.isEmpty else { throw .badState }
            var policy = jobPointer.pointee.policy
            for i in 0..<count {
                let action = UInt8(entries[i].policy)
                let condition = Int(entries[i].condition)
                let targets: InlineArray<9, Int> = condition == Int(CROI_POL_NEW_ANY)
                    ? [Int(CROI_POL_NEW_VMO), Int(CROI_POL_NEW_CHANNEL), Int(CROI_POL_NEW_EVENT),
                       Int(CROI_POL_NEW_EVENTPAIR), Int(CROI_POL_NEW_PORT), 9, 10, Int(CROI_POL_NEW_TIMER),
                       Int(CROI_POL_NEW_PROCESS)]
                    : [condition, condition, condition, condition, condition, condition, condition, condition,
                       condition]
                for t in 0..<9 {
                    let target = targets[t]
                    if policy[target] != UInt8(CROI_POL_ACTION_ALLOW), policy[target] != action {
                        if options == UInt32(CROI_JOB_POL_ABSOLUTE) { throw .alreadyExists }
                        continue
                    }
                    policy[target] = action
                }
            }
            jobPointer.pointee.policy = policy
        }
    }
}
