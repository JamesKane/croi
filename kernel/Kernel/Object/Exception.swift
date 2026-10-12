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
    var strategy = UInt32(CROI_EXCEPTION_STRATEGY_FIRST_CHANCE)
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
    /// K13g: the kind of channel it went to, and the debugger's choice of
    /// a second chance (ZX_PROP_EXCEPTION_STRATEGY; debugger channels only).
    var channelType: UInt32 = 0
    var strategy = UInt32(CROI_EXCEPTION_STRATEGY_FIRST_CHANCE)

    static var defaultRights: Rights { .transfer | .duplicate | .wait | .inspect | .getProperty | .setProperty }
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
    /// `frame`) to its handlers, Zircon's order (K13g): the process's
    /// debugger first; the thread's, the process's channel; the debugger
    /// again if it asked for a second chance; then each job's up the tree.
    static func raise(_ type: UInt32, frame: UnsafeMutablePointer<arch_exception_frame_t>,
                      synthCode: UInt32 = 0) -> Disposition {
        let me = Scheduler.current
        guard me.pointee.object != 0 else { return .unhandled }  // a kernel test's bare user thread
        let thread = ObjectPointer(address: me.pointee.object)
        let threadObject = ThreadObjectPointer(object: thread)
        let process = threadObject.pointee.process
        var handlers = Handlers()
        handlers.take(process.header.lock.withLock { ProcessPointer(object: process).pointee.debugChannel },
                      UInt32(CROI_EXCEPTION_CHANNEL_TYPE_DEBUGGER))
        handlers.take(thread.header.lock.withLock { threadObject.pointee.exceptionChannel },
                      UInt32(CROI_EXCEPTION_CHANNEL_TYPE_THREAD))
        handlers.take(process.header.lock.withLock { ProcessPointer(object: process).pointee.exceptionChannel },
                      UInt32(CROI_EXCEPTION_CHANNEL_TYPE_PROCESS))
        var job: ObjectPointer? = ProcessPointer(object: process).pointee.job
        while let current = job {
            handlers.take(current.header.lock.withLock { JobPointer(object: current).pointee.exceptionChannel },
                          UInt32(CROI_EXCEPTION_CHANNEL_TYPE_JOB))
            job = JobPointer(object: current).pointee.parent
        }
        var report = unsafe report(type, frame.pointee)
        report.context.synth_code = synthCode
        return unsafe deliver(type, frame: UInt64(UInt(bitPattern: frame)), report: report, handlers)
    }

    /// The synthetic exceptions (K13g): THREAD_STARTING to the process's
    /// debugger with the first registers in `frame` (which it may change),
    /// THREAD_EXITING with none (every handler's turn, the reply ignored),
    /// PROCESS_STARTING to every job debugger from the process's job up.
    /// The calling thread's.
    static func raiseSynthetic(_ type: UInt32, frame: UInt64) {
        let me = Scheduler.current
        guard me.pointee.object != 0 else { return }
        let thread = ObjectPointer(address: me.pointee.object)
        let process = ThreadObjectPointer(object: thread).pointee.process
        var handlers = Handlers()
        if type == UInt32(CROI_EXCP_PROCESS_STARTING) {
            takeJobDebuggers(from: ProcessPointer(object: process).pointee.job, into: &handlers)
        } else {
            handlers.take(process.header.lock.withLock { ProcessPointer(object: process).pointee.debugChannel },
                          UInt32(CROI_EXCEPTION_CHANNEL_TYPE_DEBUGGER))
        }
        guard handlers.count > 0 else { return }
        var report = croi_exception_report_t()
        report.header = croi_exception_header_t(size: UInt32(MemoryLayout<croi_exception_report_t>.size), type: type)
        if type == UInt32(CROI_EXCP_THREAD_EXITING) {
            for i in 0..<handlers.count { _ = deliver(type, frame: frame, report: report, handlers.one(i)) }
        } else {
            _ = deliver(type, frame: frame, report: report, handlers)
        }
    }

    /// thread_raise_exception (K14d, Zircon's OnUserExceptionForJobDebugger):
    /// ZX_EXCP_USER with the caller's code and data to every job debugger
    /// from the process's job up, one at a time, each reply ignored
    /// (single shot). The registers are the syscall's (thread_read_state
    /// works while it waits).
    static func raiseUser(code: UInt32, data: UInt32) {
        let me = Scheduler.current
        guard me.pointee.object != 0 else { return }
        let process = ThreadObjectPointer(object: ObjectPointer(address: me.pointee.object)).pointee.process
        var handlers = Handlers()
        takeJobDebuggers(from: ProcessPointer(object: process).pointee.job, into: &handlers)
        guard handlers.count > 0 else { return }
        let type = UInt32(CROI_EXCP_USER)
        var report = croi_exception_report_t()
        report.header = croi_exception_header_t(size: UInt32(MemoryLayout<croi_exception_report_t>.size), type: type)
        report.context.synth_code = code
        report.context.synth_data = data
        let frame = unsafe UInt64(UInt(bitPattern: UserTraps.userFrame(of: me)))
        for i in 0..<handlers.count { _ = deliver(type, frame: frame, report: report, handlers.one(i)) }
    }

    /// Every job debugger channel from `job` up the tree, in order. Closed
    /// ones are pruned on the way (as an attach prunes them), so a job that
    /// outlives its debuggers doesn't keep their kernel ends.
    private static func takeJobDebuggers(from job: ObjectPointer?, into handlers: inout Handlers) {
        var pruned = UniqueArray<UInt64>()
        var job = job
        while let current = job {
            current.header.lock.withLock {
                let j = JobPointer(object: current)
                var i = 0
                while i < j.pointee.debugChannels.count {
                    if live(j.pointee.debugChannels[i]) {
                        handlers.take(j.pointee.debugChannels[i], UInt32(CROI_EXCEPTION_CHANNEL_TYPE_JOB_DEBUGGER))
                        i += 1
                    } else {
                        pruned.append(j.pointee.debugChannels.remove(at: i))
                    }
                }
            }
            job = JobPointer(object: current).pointee.parent
        }
        while let old = pruned.popLast() { releaseChannel(old) }
    }

    /// Handlers in order, each channel retained.
    struct Handlers: ~Copyable {
        var channels = InlineArray<48, UInt64>(repeating: 0)
        var kinds = InlineArray<48, UInt32>(repeating: 0)
        var count = 0

        mutating func take(_ endpoint: UInt64, _ kind: UInt32) {
            guard endpoint != 0, count < 48 else { return }
            guard ObjectPointer(address: endpoint).tryRetain() else { return }
            channels[count] = endpoint
            kinds[count] = kind
            count += 1
        }

        /// A list of just the `i`th (its own reference).
        func one(_ i: Int) -> Handlers {
            var single = Handlers()
            single.take(channels[i], kinds[i])
            return single
        }

        deinit {
            for i in 0..<count { ObjectPointer(address: channels[i]).release() }
        }
    }

    /// Offers to each handler in turn until one resumes or ends the
    /// thread; a debugger that asked for a second chance gets the
    /// exception again after the process's channel (before the jobs').
    private static func deliver(_ type: UInt32, frame: UInt64, report: croi_exception_report_t,
                                _ handlers: borrowing Handlers) -> Disposition {
        let me = Scheduler.current
        let thread = ObjectPointer(address: me.pointee.object)
        let threadObject = ThreadObjectPointer(object: thread)
        let process = threadObject.pointee.process
        thread.header.lock.withLock {
            threadObject.pointee.exceptionFrame = frame
            threadObject.pointee.exceptionReport = report
            threadObject.pointee.inException = true
        }
        defer {
            thread.header.lock.withLock {
                threadObject.pointee.exceptionFrame = 0
                threadObject.pointee.inException = false
                threadObject.pointee.exceptionChannelType = 0
            }
        }
        let debuggerKind = UInt32(CROI_EXCEPTION_CHANNEL_TYPE_DEBUGGER)
        var disposition = Disposition.unhandled
        var secondChance: UInt64 = 0
        var i = 0
        while i < handlers.count, disposition == .unhandled {
            let kind = handlers.kinds[i]
            if secondChance != 0, kind == UInt32(CROI_EXCEPTION_CHANNEL_TYPE_JOB) {
                disposition = offerOnce(type, ObjectPointer(address: secondChance), kind: debuggerKind,
                                        thread: thread, process: process).0
                secondChance = 0
                continue
            }
            let (result, wantsSecond) = offerOnce(type, ObjectPointer(address: handlers.channels[i]), kind: kind,
                                                  thread: thread, process: process)
            disposition = result
            if wantsSecond, kind == debuggerKind { secondChance = handlers.channels[i] }
            i += 1
        }
        if disposition == .unhandled, secondChance != 0 {
            disposition = offerOnce(type, ObjectPointer(address: secondChance), kind: debuggerKind,
                                    thread: thread, process: process).0
        }
        return disposition
    }

    private static func offerOnce(_ type: UInt32, _ channel: ObjectPointer, kind: UInt32, thread: ObjectPointer,
                                  process: ObjectPointer) -> (Disposition, Bool) {
        thread.header.lock.withLock { ThreadObjectPointer(object: thread).pointee.exceptionChannelType = kind }
        let (state, strategy) = offer(type, to: channel, kind: kind, thread: thread, process: process)
        switch state {
        case .some(UInt32(CROI_EXCEPTION_STATE_HANDLED)): return (.resume, false)
        case .some(UInt32(CROI_EXCEPTION_STATE_THREAD_EXIT)): return (.exitThread, false)
        case .none: return (.exitThread, false)  // killed while waiting
        default: return (.unhandled, strategy == UInt32(CROI_EXCEPTION_STRATEGY_SECOND_CHANCE))
        }
    }

    /// An architectural exception's report (THREAD_EXCEPTION_REPORT):
    /// Zircon's arch context from the frame.
    private static func report(_ type: UInt32, _ f: arch_exception_frame_t) -> croi_exception_report_t {
        var report = croi_exception_report_t()
        report.header = croi_exception_header_t(size: UInt32(MemoryLayout<croi_exception_report_t>.size), type: type)
        #if arch(x86_64)
        report.context.arch.vector = f.vector
        report.context.arch.err_code = f.error_code
        if f.vector == 14 { report.context.arch.cr2 = arch_read_cr2() }
        #elseif arch(arm64)
        report.context.arch.esr = UInt32(truncatingIfNeeded: f.esr)
        report.context.arch.far = f.far
        #elseif arch(riscv64)
        report.context.arch.cause = f.scause
        report.context.arch.tval = f.stval
        #endif
        return report
    }

    /// One handler's turn: the state it left (TRY_NEXT if the message
    /// couldn't be sent, nil if the thread was killed meanwhile) and the
    /// strategy a debugger chose.
    private static func offer(_ type: UInt32, to channel: ObjectPointer, kind: UInt32, thread: ObjectPointer,
                              process: ObjectPointer) -> (UInt32?, UInt32) {
        let tryNext = UInt32(CROI_EXCEPTION_STATE_TRY_NEXT)
        let first = UInt32(CROI_EXCEPTION_STRATEGY_FIRST_CHANCE)
        guard let wait = ExceptionWaitPointer.allocate() else { return (tryNext, first) }
        thread.retain()
        process.retain()
        guard let exception = Objects.allocate(ExceptionObject(thread: thread, process: process, type: type,
                                                               wait: wait, channelType: kind)) else {
            thread.release()
            process.release()
            wait.release()
            wait.release()
            return (tryNext, first)
        }
        guard let message = MessagePointer.allocate(bytes: UInt32(MemoryLayout<croi_exception_info_t>.size),
                                                    handles: 1) else {
            exception.release()
            wait.release()
            return (tryNext, first)
        }
        let info = croi_exception_info_t(pid: process.header.koid, tid: thread.header.koid, type: type, padding: 0)
        unsafe UnsafeMutablePointer<croi_exception_info_t>(bitPattern: UInt(message.data))!.pointee = info
        message.setHandle(0, object: exception.address, rights: ExceptionObject.defaultRights)  // its reference
        do throws(Status) {
            try Channels.write(channel, message)
        } catch {
            wait.release()  // the message (and the exception) went with the failure
            return (tryNext, first)
        }
        var interrupted = false
        let (state, strategy) = Scheduler.locked { () -> (UInt32, UInt32) in
            while !wait.pointee.done {
                if Scheduler.block(on: wait.pointee.queue, deadline: .max, interruptible: true) == .interrupted {
                    interrupted = true
                    return (tryNext, first)
                }
            }
            return (wait.pointee.state, wait.pointee.strategy)
        }
        wait.release()
        return (interrupted ? nil : state, strategy)
    }

    /// The exception object's last reference went: its handler is done.
    static func destroy(_ object: ObjectPointer) {
        let exception = ExceptionPointer(object: object)
        let wait = exception.pointee.wait
        let state = exception.pointee.state
        let strategy = exception.pointee.strategy
        Scheduler.locked {
            wait.pointee.state = state
            wait.pointee.strategy = strategy
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
    /// task keeps. One per task while its user end is open; with
    /// `debugger` (K13g) the process's debugger channel (one) or one of a
    /// job's (up to 32, closed ones pruned).
    static func createChannel(for task: ObjectPointer, debugger: Bool = false) throws(Status) -> ObjectPointer {
        let (kernelEnd, userEnd) = try Channels.create()
        var replaced = UniqueArray<UInt64>()
        let refused = task.header.lock.withLock { () -> Status? in
            if debugger, task.header.type == .job {
                let job = JobPointer(object: task)
                var i = 0
                while i < job.pointee.debugChannels.count {
                    if live(job.pointee.debugChannels[i]) { i += 1 } else { replaced.append(job.pointee.debugChannels.remove(at: i)) }
                }
                guard job.pointee.debugChannels.count < Int(CROI_EXCEPTION_CHANNEL_JOB_DEBUGGER_MAX_COUNT) else {
                    return .alreadyBound
                }
                job.pointee.debugChannels.append(kernelEnd.address)
                return nil
            }
            if debugger {
                let process = ProcessPointer(object: task)
                guard process.pointee.state != .dead else { return .badState }
                if live(process.pointee.debugChannel) { return .alreadyBound }
                if process.pointee.debugChannel != 0 { replaced.append(process.pointee.debugChannel) }
                process.pointee.debugChannel = kernelEnd.address
                return nil
            }
            let existing = channel(of: task)
            if live(existing) { return .alreadyBound }
            if existing != 0 { replaced.append(existing) }
            setChannel(of: task, kernelEnd.address)
            return nil
        }
        if let refused {
            kernelEnd.release()
            userEnd.release()
            throw refused
        }
        while let old = replaced.popLast() { releaseChannel(old) }
        return userEnd
    }

    /// A kernel end whose user end is still open.
    private static func live(_ endpoint: UInt64) -> Bool {
        endpoint != 0 && ChannelPointer(object: ObjectPointer(address: endpoint)).pointee.peer != 0
    }

    /// A live debugger channel: the process's (ZX_INFO_PROCESS's
    /// DEBUGGER_ATTACHED), or any of a job's. Task lock held.
    static func debuggerAttachedLocked(_ task: ObjectPointer) -> Bool {
        if task.header.type == .process { return live(ProcessPointer(object: task).pointee.debugChannel) }
        let job = JobPointer(object: task)
        for i in 0..<job.pointee.debugChannels.count where live(job.pointee.debugChannels[i]) { return true }
        return false
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

    /// The registers of `thread`, which must be waiting in an exception
    /// (so its TLS registers are in its record: Thread.tls).
    static func readState(_ thread: ObjectPointer) throws(Status) -> croi_thread_state_general_regs_t {
        try unsafe withStopped(thread) { (frame, running) throws(Status) -> croi_thread_state_general_regs_t in
            var registers = unsafe generalRegisters(frame.pointee)
            #if arch(x86_64)
            registers.fs_base = running.pointee.tls
            registers.gs_base = running.pointee.gs
            #elseif arch(arm64)
            registers.tpidr = running.pointee.tls
            #endif
            return registers
        }
    }

    static func writeState(_ thread: ObjectPointer, _ registers: croi_thread_state_general_regs_t) throws(Status) {
        #if arch(x86_64)
        guard isCanonical(registers.fs_base), isCanonical(registers.gs_base) else { throw .invalidArgs }
        #endif
        try unsafe withStopped(thread) { (frame, running) throws(Status) in
            try unsafe setGeneralRegisters(&frame.pointee, registers)
            // Loaded when it next switches in (object -> scheduler: the order).
            Scheduler.locked {
                #if arch(x86_64)
                running.pointee.tls = registers.fs_base
                running.pointee.gs = registers.gs_base
                #elseif arch(arm64)
                running.pointee.tls = registers.tpidr
                #endif
            }
        }
    }

    #if arch(x86_64)
    /// A user FS/GS base: in the user range (review fix: any canonical
    /// value was taken, kernel half included, and an NMI or #MC in an entry
    /// window, which picks GS from the saved CS, could then run on a GS
    /// base user code chose; Linux's arch_prctl limit).
    static func isCanonical(_ address: UInt64) -> Bool {
        address < UserLayout.top
    }
    #endif

    /// Runs `body` on a stopped thread's registers (in an exception, or
    /// parked suspended: K13g's frame at its kernel stack top) and its
    /// scheduler thread, all under the thread object's lock (review fix:
    /// the frame was used after the lock, while the thread could resume,
    /// exit and have its stack freed; the thread leaves either state only
    /// under this lock). BAD_STATE if it isn't stopped.
    static func withStopped<R>(_ thread: ObjectPointer,
                               _ body: (UnsafeMutablePointer<arch_exception_frame_t>, ThreadPointer) throws(Status) -> R)
        throws(Status) -> R {
        try thread.header.lock.withLock { () throws(Status) -> R in
            let t = ThreadObjectPointer(object: thread)
            guard t.pointee.thread != 0 else { throw .badState }
            let scheduled = ThreadPointer(address: t.pointee.thread)  // alive: exit clears `thread` under this lock
            let address: UInt64
            if t.pointee.exceptionFrame != 0 {
                address = t.pointee.exceptionFrame
            } else {
                if t.pointee.inException { throw .notSupported }  // THREAD_EXITING: no registers (Zircon's)
                // Parked before its first entry has no frame yet.
                guard t.pointee.suspended, scheduled.pointee.enteredUser else { throw .badState }
                address = UInt64(UInt(bitPattern: unsafe UserTraps.userFrame(of: scheduled)))
            }
            let frame = unsafe UnsafeMutablePointer<arch_exception_frame_t>(bitPattern: UInt(address))!
            return try unsafe body(frame, scheduled)
        }
    }

    #if arch(x86_64)
    private static func generalRegisters(_ f: arch_exception_frame_t) -> croi_thread_state_general_regs_t {
        croi_thread_state_general_regs_t(rax: f.rax, rbx: f.rbx, rcx: f.rcx, rdx: f.rdx, rsi: f.rsi, rdi: f.rdi,
                                         rbp: f.rbp, rsp: f.rsp, r8: f.r8, r9: f.r9, r10: f.r10, r11: f.r11,
                                         r12: f.r12, r13: f.r13, r14: f.r14, r15: f.r15, rip: f.rip,
                                         rflags: f.rflags, fs_base: 0, gs_base: 0)  // readState fills them
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
        // A new PC drops the pending branch type (SPSR.BTYPE, 11:10): it
        // belonged to the old one, and a guarded page would refuse the new
        // PC (review fix).
        if f.elr != r.pc { f.spsr &= ~(UInt64(3) << 10) }
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

    /// A resource limit passed by the calling thread's syscall (Zircon's
    /// SignalPolicyException): POLICY_ERROR with `code` as synth_code; a
    /// handler may resume it, unhandled the process is killed. No locks held.
    static func limitException(_ code: UInt32) {
        let me = Scheduler.current
        guard me.pointee.object != 0 else { return }
        let frame = unsafe UserTraps.userFrame(of: me)
        switch unsafe Exceptions.raise(UInt32(CROI_EXCP_POLICY_ERROR), frame: frame, synthCode: code) {
        case .resume: break
        case .exitThread: Scheduler.locked { Scheduler.interrupt(me) }
        case .unhandled: killProcess(TaskReturnCode.exceptionKill)
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
                let targets: InlineArray<10, Int> = condition == Int(CROI_POL_NEW_ANY)
                    ? [Int(CROI_POL_NEW_VMO), Int(CROI_POL_NEW_CHANNEL), Int(CROI_POL_NEW_EVENT),
                       Int(CROI_POL_NEW_EVENTPAIR), Int(CROI_POL_NEW_PORT), 9, 10, Int(CROI_POL_NEW_TIMER),
                       Int(CROI_POL_NEW_PROCESS), Int(CROI_POL_NEW_PAGER)]
                    : [condition, condition, condition, condition, condition, condition, condition, condition,
                       condition, condition]
                for t in 0..<10 {
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
