import CKernel
import Fmt
import Synchronization

/// User mode (K6a): traps and syscalls from user threads, and starting
/// them. A user thread's registers are an arch_exception_frame_t at the top
/// of its kernel stack while it is in the kernel.
enum UserTraps {
    /// Exit codes for threads the kernel killed (the K7 exception channel
    /// replaces this).
    static var killedByFault: Int { 0xDEAD_0001 }
    static var killedByException: Int { 0xDEAD_0002 }

    /// Anything arch_exception gets from user mode.
    static func handle(_ frame: UnsafeMutablePointer<arch_exception_frame_t>) {
        if unsafe ExceptionFrame.isInterrupt(frame.pointee) {
            unsafe Interrupts.handle(frame)
            Scheduler.preemptIfRequested()
            leaving()
            return
        }
        if unsafe ExceptionFrame.isSyscall(frame.pointee) {
            unsafe Syscalls.dispatch(frame)
            leaving()
            return
        }
        if let fault = unsafe ExceptionFrame.pageFault(frame.pointee) {
            arch_interrupts_enable()
            let resolved = UserAspaces.handleFault(at: fault.address, write: fault.write, execute: fault.execute,
                                                   protectionKey: fault.protectionKey)
            _ = arch_interrupts_save()
            if resolved {
                leaving()
                return
            }
            unsafe killed("page fault", frame.pointee)
            die(killedByFault)
        }
        unsafe killed("exception", frame.pointee)
        die(killedByException)
    }

    /// On every way back to user mode: a killed thread exits instead.
    private static func leaving() {
        guard Scheduler.current.pointee.killPending else { return }
        arch_interrupts_enable()
        Processes.checkKilled()
    }

    /// A fault or exception nothing handles: a process's thread takes its
    /// whole process with it (K7d brings exception channels); a kernel
    /// test's bare user thread just exits with `code`.
    private static func die(_ code: Int) -> Never {
        arch_interrupts_enable()
        guard Scheduler.current.pointee.object != 0 else { Scheduler.exit(code) }
        Processes.killCurrentProcess(code: TaskReturnCode.exceptionKill)
    }

    /// Logs why a user thread dies (until K7's exception channels report it).
    private static func killed(_ what: StaticString, _ f: arch_exception_frame_t) {
        guard let console = panicConsole else { return }
        console.write("  user:   thread killed by ")
        console.write(what)
        #if arch(x86_64)
        console.write(", vector ")
        console.write(decimal: f.vector)
        console.write(" at ")
        console.write(hex: f.rip)
        #elseif arch(arm64)
        console.write(", ESR ")
        console.write(hex: f.esr)
        console.write(" at ")
        console.write(hex: f.elr)
        #elseif arch(riscv64)
        console.write(", scause ")
        console.write(decimal: f.scause)
        console.write(" at ")
        console.write(hex: f.sepc)
        #endif
        console.write("\n")
    }

    /// Starts the calling thread in user mode in `aspace`, its syscalls
    /// using the handle table at `handles` (0: none). Never returns.
    static func enter(_ aspace: UserAspacePointer, handles: UInt64 = 0, pc: UInt64, sp: UInt64, arg0: UInt64,
                      arg1: UInt64, arg2: UInt64 = 0) -> Never {
        let thread = Scheduler.current
        thread.pointee.handleTable = handles
        // Every user thread has FP/SIMD state (K6d), loaded before it runs.
        if thread.pointee.extendedState == 0 { thread.pointee.extendedState = ExtendedState.allocate() }
        if thread.pointee.extendedState != 0 {
            _ = arch_interrupts_save()  // no switch between loading and entering
            unsafe arch_xstate_restore(UnsafeRawPointer(bitPattern: UInt(thread.pointee.extendedState))!)
        }
        Scheduler.setAspace(aspace)
        let top = Scheduler.current.pointee.stack.top
        Scheduler.setKernelStack(top)
        arch_enter_user(pc, sp, arg0, arg1, arg2, top)
    }
}

/// The syscall table (user/include/croi/syscall.h has the numbers and
/// calling convention). Results are a status (0 or a negative Zircon code)
/// or a value; out-parameters are written through the fault-recovering
/// copies, so a bad user pointer is INVALID_ARGS, never a crash.
enum Syscalls {
    static let reported = Atomic<UInt64>(0)
    static let count = Atomic<UInt64>(0)

    /// Runs the syscall in `frame` with interrupts on, and leaves its result
    /// in the return register. Back with interrupts masked.
    static func dispatch(_ frame: UnsafeMutablePointer<arch_exception_frame_t>) {
        arch_interrupts_enable()
        let number = unsafe ExceptionFrame.syscallNumber(frame.pointee)
        var a = InlineArray<6, UInt64>(repeating: 0)
        for i in 0..<6 { a[i] = unsafe ExceptionFrame.syscallArgument(frame.pointee, i) }
        count.add(1, ordering: .relaxed)
        Trace.event(CROI_TRACE_SYSCALL, UInt16(CROI_TK_SYSCALL_ENTER), number, a[0])
        let result = run(number, a)
        Trace.event(CROI_TRACE_SYSCALL, UInt16(CROI_TK_SYSCALL_EXIT), number, UInt64(bitPattern: result))
        unsafe ExceptionFrame.setSyscallResult(&frame.pointee, UInt64(bitPattern: result))
        Scheduler.preemptIfRequested()
        _ = arch_interrupts_save()
    }

    private static func run(_ number: UInt64, _ a: InlineArray<6, UInt64>) -> Int64 {
        switch number {
        case 0: return 0  // null
        case 1: return write(a[0], a[1])
        case 2: Processes.exitThread(Int(Int64(bitPattern: a[0])))
        case 63: Processes.exitProcess(Int64(bitPattern: a[0]))  // process_exit: no handles needed
        case 6: return TestHooks.profile(a[0])
        case 3: return Int64(bitPattern: Clock.now())
        case 4:
            Scheduler.sleepInterruptible(until: a[0])
            return 0
        case 5:
            reported.store(a[0], ordering: .relaxed)
            return 0
        default:
            break
        }
        let table = Scheduler.current.pointee.handleTable
        guard table != 0 else { return Int64(Status.badState.rawValue) }
        do throws(Status) {
            return try HandleTable.withBorrowed(table) { (handles: borrowing HandleTable) throws(Status) -> Int64 in
                try objectCall(number, a, handles)
            }
        } catch {
            return Int64(error.rawValue)
        }
    }

    private static func objectCall(_ number: UInt64, _ a: InlineArray<6, UInt64>,
                                   _ table: borrowing HandleTable) throws(Status) -> Int64 {
        let handle = UInt32(truncatingIfNeeded: a[0])
        switch number {
        case 10:  // handle_close
            try table.close(handle)
        case 11:  // handle_duplicate
            try put(try table.duplicate(handle, rights: Rights(rawValue: UInt32(truncatingIfNeeded: a[1]))), a[2])
        case 12:  // handle_replace
            try put(try table.replace(handle, rights: Rights(rawValue: UInt32(truncatingIfNeeded: a[1]))), a[2])
        case 20:  // object_signal
            let ref = try table.get(handle, rights: .signal)
            try ObjectSignal.signal(ref, clear: UInt32(truncatingIfNeeded: a[1]), set: UInt32(truncatingIfNeeded: a[2]))
        case 21:  // object_wait_one
            var observed: UInt32 = 0
            var status: Status? = nil
            do throws(Status) {
                try ObjectWait.one(table, handle, signals: UInt32(truncatingIfNeeded: a[1]), deadline: a[2],
                                   observed: &observed)
            } catch {
                status = error
            }
            if a[3] != 0 { try put(observed, a[3]) }
            if let status { throw status }
        case 22:  // object_wait_async
            try Observers.waitAsync(table, handle, port: UInt32(truncatingIfNeeded: a[1]), key: a[2],
                                    signals: UInt32(truncatingIfNeeded: a[3]), options: UInt32(truncatingIfNeeded: a[4]))
        case 30:  // event_create
            try check(a[1], MemoryLayout<UInt32>.size)
            try put(try table.add(try EventObject.create(), rights: EventObject.defaultRights), a[1])
        case 31:  // port_create
            try check(a[1], MemoryLayout<UInt32>.size)
            try put(try table.add(try Ports.create(), rights: PortObject.defaultRights), a[1])
        case 32:  // port_queue
            try Ports.queue(table, handle, try getPacket(a[1]))
        case 33:  // port_wait
            try check(a[2], MemoryLayout<PortPacket>.size)
            let packet = try Ports.wait(table, handle, deadline: a[1])
            try putPacket(packet, a[2])
        case 34:  // port_cancel
            try Ports.cancel(table, port: handle, source: UInt32(truncatingIfNeeded: a[1]), key: a[2])
        case 40:  // vmo_create
            try check(a[2], MemoryLayout<UInt32>.size)
            try put(try table.add(try VmoObject.create(size: a[0]), rights: VmoObject.defaultRights), a[2])
        case 41:  // vmo_read
            try vmoCopy(table, handle, user: a[1], offset: a[2], length: a[3], toUser: true)
        case 42:  // vmo_write
            try vmoCopy(table, handle, user: a[1], offset: a[2], length: a[3], toUser: false)
        case 43:  // vmo_map (into the thread's address space, until VMARs)
            var rights = VmRights()
            if a[3] & 1 != 0 { rights.insert(.read) }
            if a[3] & 2 != 0 { rights.insert(.write) }
            if a[3] & 4 != 0 { rights.insert(.execute) }
            try check(a[4], MemoryLayout<UInt64>.size)
            let vmo = try VmoObject.forMapping(table, handle, rights)
            defer { vmo.release() }
            guard let aspace = Scheduler.current.pointee.aspace else { throw .badState }
            let borrowed = Vmo.borrowing(vmo)
            let mapped: UInt64
            do throws(VmError) {
                mapped = try UserAspace.borrowing(aspace).mapKeeping(borrowed, offset: a[1], size: a[2], rights: rights)
            } catch {
                _ = borrowed.keep()
                throw error == .noSpace || error == .outOfMemory ? .noMemory : .invalidArgs
            }
            _ = borrowed.keep()
            try put(mapped, a[4])
        case 50:  // trace_configure
            switch a[1] {
            case 0: try TraceControl.start(table, handle, categories: UInt32(truncatingIfNeeded: a[2]), pages: Int(a[3]),
                                           mode: UInt32(truncatingIfNeeded: a[4]), sampleHz: a[5])
            case 1: try TraceControl.stop(table, handle)
            case 2: try TraceControl.rewind(table, handle)
            case 3: try TraceControl.mark(table, handle, a[2], a[3])
            default: throw .invalidArgs
            }
        case 51:  // pmu_configure
            try pmuConfigure(table, handle, a)
        case 60...79:
            try taskCall(number, a, table)
        case 80...89:
            try ipcCall(number, a, table)
        case 90...99:
            try syncCall(number, a, table)
        default:
            throw .notSupported
        }
        return 0
    }

    /// pmu_configure: a thread's own counters need nothing; sampling
    /// (every thread on every CPU) needs the tracing resource.
    private static func pmuConfigure(_ table: borrowing HandleTable, _ handle: UInt32,
                                     _ a: InlineArray<6, UInt64>) throws(Status) {
        switch a[1] {
        case 0:
            try check(a[2], MemoryLayout<croi_pmu_info_t>.size)
            try put(croi_pmu_info_t(kind: Pmu.kind, counters: UInt32(Pmu.threadCounters), events: Pmu.events,
                                    sampling: Pmu.canSample ? 1 : 0), a[2])
        case 1:
            try Resources.check(table, handle, system: ResourceObject.tracingBase)
            try Pmu.startSampling(event: UInt32(truncatingIfNeeded: a[2]), period: a[3])
        case 2:
            try Resources.check(table, handle, system: ResourceObject.tracingBase)
            Pmu.stopSampling()
        case 3:
            guard a[2] >= 1, a[2] <= UInt64(CROI_PMU_THREAD_EVENTS) else { throw .invalidArgs }
            var events = InlineArray<4, UInt32>(repeating: 0)
            var span = events.mutableSpan
            let copied = span.withUnsafeMutableBytes { raw in
                unsafe UserCopy.from(raw.baseAddress!, a[3], a[2] * 4)
            }
            guard copied == 0 else { throw .invalidArgs }
            try Pmu.enableThread(events, count: Int(a[2]))
        case 4:
            try check(a[2], 32)
            guard let values = Pmu.readThread() else { throw .badState }
            try put(values, a[2])
        case 5:
            Pmu.disableThread()
        default:
            throw .invalidArgs
        }
    }

    // MARK: User memory

    /// Copies `value` out to user address `address`.
    static func put<T: BitwiseCopyable>(_ value: T, _ address: UInt64) throws(Status) {
        var copy = value
        let result = withUnsafeBytes(of: &copy) { unsafe UserCopy.to(address, $0.baseAddress!, UInt64($0.count)) }
        guard result == 0 else { throw .invalidArgs }
    }

    /// Checks an out-pointer is writable before doing anything (so a bad
    /// pointer doesn't leave a handle created that nobody can close).
    static func check(_ address: UInt64, _ size: Int) throws(Status) {
        guard UserLayout.contains(address & ~(KernelLayout.pageSize - 1), KernelLayout.pageSize) else {
            throw .invalidArgs
        }
        guard size <= 64 else { panic("syscalls: out-parameter larger than the probe") }
        var probe = InlineArray<64, UInt8>(repeating: 0)
        var span = probe.mutableSpan
        let read = span.withUnsafeMutableBufferPointer { unsafe UserCopy.from($0.baseAddress!, address, UInt64(size)) }
        guard read == 0 else { throw .invalidArgs }
        let written = probe.span.withUnsafeBufferPointer { unsafe UserCopy.to(address, $0.baseAddress!, UInt64(size)) }
        guard written == 0 else { throw .invalidArgs }
    }

    private static func getPacket(_ address: UInt64) throws(Status) -> PortPacket {
        var raw = InlineArray<6, UInt64>(repeating: 0)  // key, type|status, payload[4]
        var span = raw.mutableSpan
        let copied = span.withUnsafeMutableBufferPointer { unsafe UserCopy.from($0.baseAddress!, address, 48) }
        guard copied == 0 else { throw .invalidArgs }
        var packet = PortPacket(key: raw[0], type: UInt32(truncatingIfNeeded: raw[1]),
                                status: Int32(truncatingIfNeeded: Int64(bitPattern: raw[1] >> 32)))
        for i in 0..<4 { packet.payload[i] = raw[2 + i] }
        return packet
    }

    private static func putPacket(_ packet: PortPacket, _ address: UInt64) throws(Status) {
        var raw = InlineArray<6, UInt64>(repeating: 0)
        raw[0] = packet.key
        raw[1] = UInt64(packet.type) | UInt64(UInt32(bitPattern: packet.status)) << 32
        for i in 0..<4 { raw[2 + i] = packet.payload[i] }
        let copied = raw.span.withUnsafeBufferPointer { unsafe UserCopy.to(address, $0.baseAddress!, 48) }
        guard copied == 0 else { throw .invalidArgs }
    }

    /// vmo_read / vmo_write: page by page between the user buffer and the
    /// VMO's pages through the physmap (needs read / write rights).
    private static func vmoCopy(_ table: borrowing HandleTable, _ handle: UInt32, user: UInt64, offset: UInt64,
                                length: UInt64, toUser: Bool) throws(Status) {
        let ref = try table.get(handle, type: .vmo, rights: toUser ? .read : .write)
        let vmo = VmoPointer(address: UnsafeVmoObject(ref.object).vmo)
        guard offset <= vmo.pointee.size, length <= vmo.pointee.size - offset else { throw .outOfRange }
        var done: UInt64 = 0
        while done < length {
            let at = offset + done
            guard let phys = toUser ? (vmo.lookup(at: at) ?? vmo.commit(at: at)) : vmo.commit(at: at) else { throw .noMemory }
            let within = at % KernelLayout.pageSize
            let chunk = min(length - done, KernelLayout.pageSize - within)
            let kernel = KernelLayout.physmap(phys) + within
            let result = toUser
                ? unsafe UserCopy.to(user + done, UnsafeRawPointer(bitPattern: UInt(kernel))!, chunk)
                : unsafe UserCopy.from(UnsafeMutableRawPointer(bitPattern: UInt(kernel))!, user + done, chunk)
            guard result == 0 else { throw .invalidArgs }
            done += chunk
        }
    }

    private static func write(_ address: UInt64, _ requested: UInt64) -> Int64 {
        let length = min(requested, 256)
        var buffer = InlineArray<256, UInt8>(repeating: 0)
        var span = buffer.mutableSpan
        let copied = span.withUnsafeMutableBufferPointer { unsafe UserCopy.from($0.baseAddress!, address, length) }
        guard copied == 0 else { return Int64(Status.invalidArgs.rawValue) }
        guard let console = panicConsole else { return 0 }
        console.write("  user:   ")
        console.write(utf8: buffer.span.extracting(0..<Int(length)))
        console.write("\n")
        return 0
    }
}

#if arch(x86_64)
/// The SYSCALL entry's handler (exceptions.S).
@c @implementation
func arch_syscall(_ frame: UnsafeMutablePointer<arch_exception_frame_t>) {
    unsafe Syscalls.dispatch(frame)
}
#endif

/// The only way syscalls touch user memory: the user range is checked
/// first (the fault-recovering copies would happily write kernel pages
/// through a pointer user space chose: SMAP only guards user pages), then
/// the arch copy. 0 or -1, as the arch functions.
enum UserCopy {
    @unsafe static func from(_ destination: UnsafeMutableRawPointer, _ source: UInt64, _ length: UInt64) -> Int32 {
        guard length == 0 || UserLayout.contains(source, length) else { return -1 }
        return unsafe arch_copy_from_user(destination, source, length)
    }

    /// A 32-bit user word, without paging anything in (interrupts must be
    /// masked, e.g. under the scheduler lock): nil if it isn't resident or
    /// isn't readable.
    static func wordNoPageIn(_ address: UInt64) -> UInt32? {
        guard UserLayout.contains(address, 4) else { return nil }
        let percpu = unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!
        unsafe percpu.pointee.noPageIn = true
        var value: UInt32 = 0
        let result = withUnsafeMutableBytes(of: &value) { unsafe arch_copy_from_user($0.baseAddress!, address, 4) }
        unsafe percpu.pointee.noPageIn = false
        return result == 0 ? value : nil
    }

    @unsafe static func to(_ destination: UInt64, _ source: UnsafeRawPointer, _ length: UInt64) -> Int32 {
        guard length == 0 || UserLayout.contains(destination, length) else { return -1 }
        return unsafe arch_copy_to_user(destination, source, length)
    }
}

/// Test-only syscall 6 (`test_profile`), until profiles are objects:
/// op 0 reports whether the calling thread's effective profile is a
/// deadline one (1) or fair (0); op 1 binds the caller to the deadline
/// context a kernel self-test provided; op 2 unbinds it.
enum TestHooks {
    nonisolated(unsafe) static var deadlineContext: SchedContextPointer? = nil

    static func profile(_ op: UInt64) -> Int64 {
        let me = Scheduler.current
        switch op {
        case 0: return Scheduler.effectiveProfile(of: me).discipline == .deadline ? 1 : 0
        case 1:
            guard let context = deadlineContext else { return Int64(Status.badState.rawValue) }
            Scheduler.bind(me, context)
            return 0
        case 2:
            Scheduler.bind(me, nil)
            return 0
        default: return Int64(Status.invalidArgs.rawValue)
        }
    }
}
