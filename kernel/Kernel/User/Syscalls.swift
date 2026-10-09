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
            return
        }
        if unsafe ExceptionFrame.isSyscall(frame.pointee) {
            unsafe Syscalls.dispatch(frame)
            return
        }
        if let fault = unsafe ExceptionFrame.pageFault(frame.pointee) {
            arch_interrupts_enable()
            let resolved = UserAspaces.handleFault(at: fault.address, write: fault.write, execute: fault.execute,
                                                   protectionKey: fault.protectionKey)
            _ = arch_interrupts_save()
            if resolved { return }
            Scheduler.exit(killedByFault)
        }
        Scheduler.exit(killedByException)
    }

    /// Starts the calling thread in user mode in `aspace`. Never returns.
    static func enter(_ aspace: UserAspacePointer, pc: UInt64, sp: UInt64, arg0: UInt64, arg1: UInt64) -> Never {
        Scheduler.setAspace(aspace)
        let top = Scheduler.current.pointee.stack.top
        Scheduler.setKernelStack(top)
        arch_enter_user(pc, sp, arg0, arg1, top)
    }
}

/// The syscall table (K6a's first few; K6b adds the object calls).
enum Syscalls {
    static var null: UInt64 { 0 }
    static var debugWrite: UInt64 { 1 }
    static var exit: UInt64 { 2 }
    static var clockMonotonic: UInt64 { 3 }
    static var nanosleep: UInt64 { 4 }
    static var testReport: UInt64 { 5 }

    static let reported = Atomic<UInt64>(0)
    static let count = Atomic<UInt64>(0)

    /// Runs the syscall in `frame` with interrupts on, and leaves its result
    /// in the return register. Back with interrupts masked.
    static func dispatch(_ frame: UnsafeMutablePointer<arch_exception_frame_t>) {
        arch_interrupts_enable()
        let number = unsafe ExceptionFrame.syscallNumber(frame.pointee)
        let a0 = unsafe ExceptionFrame.syscallArgument(frame.pointee, 0)
        let a1 = unsafe ExceptionFrame.syscallArgument(frame.pointee, 1)
        count.add(1, ordering: .relaxed)
        var result: Int64 = 0
        switch number {
        case null:
            result = 0
        case debugWrite:
            result = write(a0, min(a1, 256))
        case exit:
            Scheduler.exit(Int(a0))
        case clockMonotonic:
            result = Int64(bitPattern: Clock.now())
        case nanosleep:
            Scheduler.sleep(until: a0)
        case testReport:
            reported.store(a0, ordering: .relaxed)
        default:
            result = Int64(Status.notSupported.rawValue)
        }
        unsafe ExceptionFrame.setSyscallResult(&frame.pointee, UInt64(bitPattern: result))
        Scheduler.preemptIfRequested()
        _ = arch_interrupts_save()
    }

    private static func write(_ address: UInt64, _ length: UInt64) -> Int64 {
        var buffer = InlineArray<256, UInt8>(repeating: 0)
        var span = buffer.mutableSpan
        let copied = span.withUnsafeMutableBufferPointer { unsafe arch_copy_from_user($0.baseAddress!, address, length) }
        guard copied == 0 else { return Int64(Status.invalidArgs.rawValue) }
        guard let console = panicConsole else { return 0 }
        console.write("  user:   ")
        for i in 0..<Int(length) { console.write(utf8: buffer.span.extracting(i..<(i + 1))) }
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
