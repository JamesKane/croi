import CKernel

/// Single-step and hardware breakpoints, K13g part 3 (Zircon's
/// ZX_THREAD_STATE_SINGLE_STEP and ZX_THREAD_STATE_DEBUG_REGS, both
/// written only with debugging syscalls on). A thread's state
/// (`Thread.debugState`, a heap DebugState from its first write) is loaded
/// at a switch to it and cleared at a switch to a thread without one; it
/// is only written while the thread is stopped (suspended or in an
/// exception), so never while loaded on a CPU.
///
/// amd64: single-step is RFLAGS.TF in the thread's frame (it stays until
/// cleared); DR0-3, DR6 and DR7 (user bits only; the addresses user ones).
/// A #DB from user mode is ZX_EXCP_HW_BREAKPOINT with DR6 saved for the
/// debugger; one in the kernel (a watchpoint hit by a user copy) is
/// ignored, as Zircon's.
/// arm64: single-step is MDSCR_EL1.SS (per thread) plus SPSR.SS in its
/// frame: one instruction, then the step exception; the debugger writes
/// it again to go on (Zircon's). Breakpoint and watchpoint pairs up to
/// ID_AA64DFR0_EL1's counts, matching EL0 only (MDSCR_EL1.MDE while any is
/// enabled); breakpoint, step and watchpoint exceptions from EL0 are
/// HW_BREAKPOINT (a watchpoint's FAR and ESR saved). The OS lock is cleared
/// on every CPU at start (`arch_debug_cpu_init`).
/// rv64: neither (Zircon's either): single-step NOT_SUPPORTED, debug
/// registers a u32 written and ignored.
struct DebugState {
    var regs = croi_thread_state_debug_regs_t()
    var singleStep = false  // arm64: MDSCR_EL1.SS
}

enum HardwareDebug {
    static func state(_ thread: ThreadPointer) -> UnsafeMutablePointer<DebugState>? {
        unsafe UnsafeMutablePointer<DebugState>(bitPattern: UInt(thread.pointee.debugState))
    }

    private static func ensureState(_ thread: ThreadPointer) throws(Status) -> UnsafeMutablePointer<DebugState> {
        if let existing = unsafe state(thread) { return unsafe existing }
        guard let raw = unsafe heap.allocate(size: MemoryLayout<DebugState>.size, alignment: 16) else { throw .noMemory }
        let pointer = unsafe raw.bindMemory(to: DebugState.self, capacity: 1)
        unsafe pointer.initialize(to: DebugState())
        thread.pointee.debugState = UInt64(UInt(bitPattern: raw))
        return unsafe pointer
    }

    static func free(_ thread: ThreadPointer) {
        guard thread.pointee.debugState != 0 else { return }
        unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(thread.pointee.debugState))!)
        thread.pointee.debugState = 0
    }

    #if arch(arm64)
    static var breakpointCount: UInt64 { ((arch_debug_features() >> 12) & 0xF) + 1 }
    static var watchpointCount: UInt64 { ((arch_debug_features() >> 20) & 0xF) + 1 }
    #endif

    /// At a switch to `next` on CPU `me` (scheduler lock held): its debug
    /// state loaded, or whatever the last thread left cleared.
    static func switchTo(_ next: ThreadPointer, loaded: inout Bool) {
        guard let s = unsafe state(next), next.pointee.aspace != nil else {
            guard loaded else { return }
            #if arch(x86_64)
            arch_debug_write(7, 0x400)  // every breakpoint off
            #elseif arch(arm64)
            arch_debug_load(nil, 0, breakpointCount, watchpointCount)
            #endif
            loaded = false
            return
        }
        #if arch(x86_64)
        let dr = unsafe s.pointee.regs.dr
        arch_debug_write(0, dr.0)
        arch_debug_write(1, dr.1)
        arch_debug_write(2, dr.2)
        arch_debug_write(3, dr.3)
        arch_debug_write(6, unsafe s.pointee.regs.dr6)
        arch_debug_write(7, unsafe s.pointee.regs.dr7)
        #elseif arch(arm64)
        var mdscr: UInt64 = unsafe s.pointee.singleStep ? 1 : 0
        if unsafe anyEnabled(s.pointee.regs) { mdscr |= 1 << 15 }  // MDE
        unsafe withUnsafePointer(to: &s.pointee.regs) { unsafe arch_debug_load(UnsafeRawPointer($0), mdscr, breakpointCount, watchpointCount) }
        #endif
        loaded = true
    }

    #if arch(arm64)
    private static func anyEnabled(_ r: croi_thread_state_debug_regs_t) -> Bool {
        var any = false
        withUnsafeBytes(of: r) { bytes in
            for i in 0..<32 where unsafe bytes.load(fromByteOffset: i * 16, as: UInt32.self) & 1 != 0 { any = true }
        }
        return any
    }
    #endif

    // MARK: Registers (the thread stopped: Exceptions.stoppedFrame checked)

    static func readRegisters(_ thread: ThreadPointer) -> croi_thread_state_debug_regs_t {
        var regs = unsafe state(thread).map { unsafe $0.pointee.regs } ?? croi_thread_state_debug_regs_t()
        #if arch(arm64)
        regs.hw_bps_count = UInt8(breakpointCount)
        regs.hw_wps_count = UInt8(watchpointCount)
        #elseif arch(x86_64)
        if unsafe state(thread) == nil {
            regs.dr6 = 0xFFFF_0FF0
            regs.dr7 = 0x400
        }
        #endif
        return regs
    }

    static func writeRegisters(_ thread: ThreadPointer, _ input: croi_thread_state_debug_regs_t) throws(Status) {
        #if arch(x86_64)
        var regs = input
        let userTop: UInt64 = 1 << 47
        for address in [input.dr.0, input.dr.1, input.dr.2, input.dr.3] as InlineArray<4, UInt64> {
            guard address == 0 || address < userTop else { throw .invalidArgs }
        }
        // Enabled breakpoints: no I/O ones (RW 10b, undefined without
        // CR4.DE), and execution ones of length 1 (LEN 00), Linux's rule
        // (review fix: the fields were taken as given).
        for i in 0..<4 where (input.dr7 >> UInt64(2 * i)) & 3 != 0 {
            let rw = (input.dr7 >> UInt64(16 + 4 * i)) & 3, len = (input.dr7 >> UInt64(18 + 4 * i)) & 3
            guard rw != 2, rw != 0 || len == 0 else { throw .invalidArgs }
        }
        regs.dr6 = 0xFFFF_0FF0 | (input.dr6 & 0xE00F)                      // B0-3, BD, BS, BT
        regs.dr7 = (input.dr7 & 0xFFFF_00FF) | (1 << 10) | (1 << 8) | (1 << 9)  // L/G0-3, RW/LEN; LE, GE
        let s = try unsafe ensureState(thread)
        unsafe s.pointee.regs = regs
        #elseif arch(arm64)
        var regs = croi_thread_state_debug_regs_t()
        let userTop: UInt64 = 1 << 48
        let bps = Int(breakpointCount), wps = Int(watchpointCount)
        try withUnsafeBytes(of: input) { (from) throws(Status) in
            try withUnsafeMutableBytes(of: &regs) { (to) throws(Status) in
                for i in 0..<16 {
                    for (base, count, watch) in [(0, bps, false), (256, wps, true)] as InlineArray<2, (Int, Int, Bool)> {
                        guard i < count else { continue }
                        let control = unsafe from.load(fromByteOffset: base + i * 16, as: UInt32.self)
                        let value = unsafe from.load(fromByteOffset: base + i * 16 + 8, as: UInt64.self)
                        guard value == 0 || value < userTop else { throw .invalidArgs }
                        let enabled = control & 1 != 0
                        let newControl: UInt32 = !enabled ? 0
                            : watch ? (control & (1 | 0x18 | 0x1FE0)) | (0b10 << 1) | (0b01 << 14)  // E, LSC, BAS; EL0
                            : 1 | (0b10 << 1) | (0xF << 5)  // E, PMC EL0, BAS all
                        unsafe to.storeBytes(of: newControl, toByteOffset: base + i * 16, as: UInt32.self)
                        unsafe to.storeBytes(of: value & 0xFFFF_FFFF_FFFC, toByteOffset: base + i * 16 + 8, as: UInt64.self)
                    }
                }
            }
        }
        let s = try unsafe ensureState(thread)
        regs.far = unsafe s.pointee.regs.far
        regs.esr = unsafe s.pointee.regs.esr
        unsafe s.pointee.regs = regs
        #else
        _ = input
        #endif
    }

    static func singleStep(_ thread: ThreadPointer, _ frame: UnsafeMutablePointer<arch_exception_frame_t>) throws(Status) -> UInt32 {
        #if arch(x86_64)
        return unsafe frame.pointee.rflags & (1 << 8) != 0 ? 1 : 0
        #elseif arch(arm64)
        let armed = unsafe state(thread).map { unsafe $0.pointee.singleStep } ?? false
        let stepping = unsafe frame.pointee.spsr & (1 << 21) != 0
        return armed && stepping ? 1 : 0
        #else
        throw .notSupported
        #endif
    }

    static func setSingleStep(_ thread: ThreadPointer, _ frame: UnsafeMutablePointer<arch_exception_frame_t>,
                              _ on: Bool) throws(Status) {
        #if arch(x86_64)
        if on { unsafe frame.pointee.rflags |= 1 << 8 } else { unsafe frame.pointee.rflags &= ~(1 << 8) }
        #elseif arch(arm64)
        let s = try unsafe ensureState(thread)
        unsafe s.pointee.singleStep = on
        if on { unsafe frame.pointee.spsr |= 1 << 21 } else { unsafe frame.pointee.spsr &= ~(1 << 21) }
        #else
        throw .notSupported
        #endif
    }

    // MARK: Traps

    /// A debug trap from user mode, before it is offered: what the
    /// debugger reads afterwards (amd64 DR6, reset; arm64 a watchpoint's
    /// FAR and ESR).
    static func trapped(_ frame: UnsafeMutablePointer<arch_exception_frame_t>) {
        let me = Scheduler.current
        #if arch(x86_64)
        guard unsafe frame.pointee.vector == 1 else { return }
        let dr6 = arch_debug_read(6)
        arch_debug_write(6, 0xFFFF_0FF0)
        if let s = unsafe try? ensureState(me) { unsafe s.pointee.regs.dr6 = dr6 }
        #elseif arch(arm64)
        guard unsafe (frame.pointee.esr >> 26) & 0x3F == 0x34 else { return }  // watchpoint, lower EL
        if let s = unsafe try? ensureState(me) {
            unsafe s.pointee.regs.far = frame.pointee.far
            unsafe s.pointee.regs.esr = UInt32(truncatingIfNeeded: frame.pointee.esr)
        }
        #else
        _ = me
        _ = unsafe frame
        #endif
    }

    /// A debug trap taken in the kernel (amd64: a user watchpoint hit by a
    /// user copy): ignored. True if it was one.
    static func kernelTrap(_ frame: UnsafeMutablePointer<arch_exception_frame_t>) -> Bool {
        #if arch(x86_64)
        guard unsafe frame.pointee.vector == 1 else { return false }
        arch_debug_write(6, 0xFFFF_0FF0)
        return true
        #else
        _ = unsafe frame
        return false
        #endif
    }
}
