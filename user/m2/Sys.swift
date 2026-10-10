import CroiRuntime

/// Syscall helpers for bin/m2: a failing call throws with what it was
/// doing and the status.
struct Failure: Error {
    let what: StaticString
    let status: Int64
}

enum Sys {
    static var sameRights: UInt64 { 1 << 31 }

    static func call(_ number: UInt64, _ a0: UInt64 = 0, _ a1: UInt64 = 0, _ a2: UInt64 = 0, _ a3: UInt64 = 0,
                     _ a4: UInt64 = 0, _ a5: UInt64 = 0) -> Int64 {
        croi_syscall6(number, a0, a1, a2, a3, a4, a5)
    }

    static func check(_ what: StaticString, _ status: Int64) throws(Failure) {
        guard status == 0 else { throw Failure(what: what, status: status) }
    }

    static func address<T>(_ value: inout T) -> UInt64 {
        withUnsafeMutablePointer(to: &value) { UInt64(UInt(bitPattern: $0)) }
    }

    static func now() -> UInt64 {
        UInt64(bitPattern: call(CROI_SYS_CLOCK_MONOTONIC))
    }

    static func close(_ handle: UInt32) {
        if handle != 0 { _ = call(CROI_SYS_HANDLE_CLOSE, UInt64(handle)) }
    }

    static func say(_ text: StaticString) {
        unsafe croi_write(UnsafeRawPointer(text.utf8Start).assumingMemoryBound(to: CChar.self), text.utf8CodeUnitCount)
    }

    static func event() throws(Failure) -> UInt32 {
        var handle: UInt32 = 0
        try check("creating an event", call(CROI_SYS_EVENT_CREATE, 0, address(&handle)))
        return handle
    }

    static func signal(_ handle: UInt32, clear: UInt32 = 0, set: UInt32) {
        _ = call(CROI_SYS_OBJECT_SIGNAL, UInt64(handle), UInt64(clear), UInt64(set))
    }

    /// Waits for `signals` on `handle` and clears them (events only).
    static func take(_ handle: UInt32, _ signals: UInt32 = UInt32(CROI_SIGNAL_SIGNALED)) {
        var observed: UInt32 = 0
        _ = call(CROI_SYS_OBJECT_WAIT_ONE, UInt64(handle), UInt64(signals), .max, address(&observed))
        signal(handle, clear: signals, set: 0)
    }

    /// A profile (needs the root resource): a priority or deadline
    /// parameters, on the CPUs in `mask` (0: anywhere).
    static func profile(_ resource: UInt32, priority: Int32? = nil, deadline: (UInt64, UInt64)? = nil,
                        mask: UInt64 = 0) throws(Failure) -> UInt32 {
        var info = croi_profile_info_t()
        if let priority {
            info.flags |= UInt32(CROI_PROFILE_INFO_FLAG_PRIORITY)
            info.priority = priority
        }
        if let (capacity, period) = deadline {
            info.flags |= UInt32(CROI_PROFILE_INFO_FLAG_DEADLINE)
            info.deadline_params = croi_sched_deadline_params_t(capacity: Int64(capacity),
                                                                relative_deadline: Int64(period),
                                                                period: Int64(period))
        }
        if mask != 0 {
            info.flags |= UInt32(CROI_PROFILE_INFO_FLAG_CPU_MASK)
            info.cpu_mask.0 = mask
        }
        var handle: UInt32 = 0
        try check("creating a profile", call(CROI_SYS_PROFILE_CREATE, UInt64(resource), 0, address(&info),
                                             address(&handle)))
        return handle
    }

    static func apply(_ profile: UInt32, to thread: UInt32) throws(Failure) {
        var refusal: UInt32 = 0
        try check("applying a profile", call(CROI_SYS_OBJECT_SET_PROFILE, UInt64(thread), UInt64(profile), 0,
                                             address(&refusal)))
    }

    typealias ThreadEntry = @convention(c) (UInt64, UInt64) -> Void

    /// Starts a thread in this process at `entry(argument, 0)` on a 64 KiB
    /// stack; returns its handle. The entry must end with thread_exit.
    static func spawn(_ entry: ThreadEntry, _ argument: UInt64) throws(Failure) -> UInt32 {
        let name: StaticString = "m2-worker"
        var thread: UInt32 = 0
        try check("creating a thread", call(CROI_SYS_THREAD_CREATE, UInt64(croi_process_self()),
                                            unsafe UInt64(UInt(bitPattern: name.utf8Start)),
                                            UInt64(name.utf8CodeUnitCount), 0, address(&thread)))
        let size: UInt64 = 64 * 1024
        var stack: UInt32 = 0
        var base: UInt64 = 0
        try check("making a stack", call(CROI_SYS_VMO_CREATE, size, 0, address(&stack)))
        try check("mapping a stack", call(CROI_SYS_VMAR_MAP, UInt64(croi_vmar_root_self())
                                              | UInt64(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) << 32,
                                          0, UInt64(stack), 0, size, address(&base)))
        close(stack)
        #if arch(x86_64)
        let sp = base + size - 8  // as if called: a C entry expects it
        #else
        let sp = base + size
        #endif
        let pc = unsafe UInt64(UInt(bitPattern: unsafeBitCast(entry, to: UnsafeRawPointer.self)))
        try check("starting a thread", call(CROI_SYS_THREAD_START, UInt64(thread), pc, sp, argument, 0))
        return thread
    }

    static func exitThread() -> Never {
        _ = call(CROI_SYS_THREAD_EXIT, 0)
        fatalError()
    }
}
