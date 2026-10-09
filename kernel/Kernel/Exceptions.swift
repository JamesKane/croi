import CKernel
import Fmt

/// Common entry for every exception (kernel.h). Breakpoints resume after
/// the instruction; anything else is unexpected this early and is fatal.
@c @implementation
func arch_exception(_ frame: UnsafeMutablePointer<arch_exception_frame_t>) {
    if unsafe ExceptionFrame.fromUser(frame.pointee) {
        unsafe UserTraps.handle(frame)
        return
    }
    if unsafe ExceptionFrame.isInterrupt(frame.pointee) {
        unsafe Interrupts.handle(frame)
        Scheduler.preemptIfRequested()
        return
    }
    #if arch(arm64)
    if unsafe ExceptionFrame.isSError(frame.pointee) {
        let kind = unsafe SErrorPolicy.classify(esr: frame.pointee.esr)
        if kind == .corrected {
            SErrorPolicy.corrected += 1
            return
        }
        // Recoverable kinds will go to the faulting process once there is
        // user mode; from the kernel they are fatal like the rest.
        if let console = panicConsole {
            console.write("\ncroi kernel: SError: ")
            console.write(SErrorPolicy.describe(kind))
        }
    }
    #endif
    // A page fault on one of the kernel's user-access instructions: page
    // the user memory in if a mapping allows it, else resume at the
    // instruction's recovery point (it returns an error).
    if let fault = unsafe ExceptionFrame.pageFault(frame.pointee),
       let recovery = unsafe Fixups.recovery(for: ExceptionFrame.programCounter(frame.pointee)) {
        // A synchronous fault is thread context: run the handler with the
        // faulting code's interrupt state, so that while it waits for a
        // lock it still answers IPIs (a TLB shootdown from the holder).
        // A protection fault (SMAP/PAN/SUM: the access didn't open user
        // access) is final; retrying the present page would loop.
        // So is any fault in interrupt context (a sampler reading user
        // frames): it must not take locks or sleep to page memory in.
        let inInterrupt = unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!.pointee.interruptFrame != 0
        guard unsafe !ExceptionFrame.userAccessBlocked(frame.pointee), !inInterrupt else {
            Trace.event(CROI_TRACE_VM, UInt16(CROI_TK_FAULT), fault.address, fault.write ? CROI_VM_FAULT_WRITE : 0)
            unsafe ExceptionFrame.setProgramCounter(&frame.pointee, recovery)
            return
        }
        let enable = unsafe ExceptionFrame.interruptsWereEnabled(frame.pointee)
        if enable { arch_interrupts_enable() }
        let resolved = UserAspaces.handleFault(at: fault.address, write: fault.write, execute: fault.execute,
                                               protectionKey: fault.protectionKey)
        if enable { _ = arch_interrupts_save() }
        if !resolved {
            unsafe ExceptionFrame.setProgramCounter(&frame.pointee, recovery)
        }
        return
    }
    if unsafe ExceptionFrame.isBreakpoint(frame.pointee) {
        unsafe ExceptionFrame.skipBreakpoint(&frame.pointee)
        breakpointsHandled += 1
        return
    }
    if let console = panicConsole {
        if unsafe ExceptionFrame.isStackOverflow(frame.pointee) {
            #if arch(x86_64)
            console.write("\ncroi kernel: double fault, usually a kernel stack overflow (handled on IST1)")
            #else
            console.write("\ncroi kernel: kernel stack overflow (handled on the emergency stack)")
            #endif
        }
        unsafe ExceptionFrame.report(frame.pointee, to: console)
    }
    panic("unhandled exception")
}

/// Per-architecture decoding of `arch_exception_frame_t`.
enum ExceptionFrame {
    #if arch(x86_64)
    static func isBreakpoint(_ f: arch_exception_frame_t) -> Bool { f.vector == 3 }
    static func pageFault(_ f: arch_exception_frame_t) -> PageFault? {
        guard f.vector == 14 else { return nil }  // #PF: CR2 and the error code
        return PageFault(address: arch_read_cr2(), write: f.error_code & 2 != 0, execute: f.error_code & 16 != 0,
                         protectionKey: f.error_code & 32 != 0)
    }
    static func programCounter(_ f: arch_exception_frame_t) -> UInt64 { f.rip }
    static func framePointer(_ f: arch_exception_frame_t) -> UInt64 { f.rbp }
    static func stackPointer(_ f: arch_exception_frame_t) -> UInt64 { f.rsp }
    static func interruptsWereEnabled(_ f: arch_exception_frame_t) -> Bool { f.rflags & (1 << 9) != 0 }  // IF
    static func fromUser(_ f: arch_exception_frame_t) -> Bool { f.cs & 3 == 3 }
    /// SMAP: a supervisor access to a present user page with AC clear.
    static func userAccessBlocked(_ f: arch_exception_frame_t) -> Bool {
        f.vector == 14 && f.error_code & 1 != 0 && f.error_code & 4 == 0 && croi_user_protection != 0
            && f.rflags & (1 << 18) == 0
    }
    static func isSyscall(_ f: arch_exception_frame_t) -> Bool { f.vector == 0x100 }
    static func syscallNumber(_ f: arch_exception_frame_t) -> UInt64 { f.rax }
    static func syscallArgument(_ f: arch_exception_frame_t, _ i: Int) -> UInt64 {
        switch i {
        case 0: f.rdi
        case 1: f.rsi
        case 2: f.rdx
        case 3: f.r10
        case 4: f.r8
        default: f.r9
        }
    }
    static func setSyscallResult(_ f: inout arch_exception_frame_t, _ value: UInt64) { f.rax = value }
    static func setProgramCounter(_ f: inout arch_exception_frame_t, _ pc: UInt64) { f.rip = pc }
    static func isInterrupt(_ f: arch_exception_frame_t) -> Bool { f.vector >= 32 }

    /// Overflowing onto a guard page raises #PF, which can't push its frame
    /// on the same stack, so the CPU escalates to #DF (on its IST stack).
    static func isStackOverflow(_ f: arch_exception_frame_t) -> Bool { f.vector == 8 }

    /// int3 is a trap: rip already points past it.
    static func skipBreakpoint(_ f: inout arch_exception_frame_t) {}

    static func report(_ f: arch_exception_frame_t, to out: some TextOutput) {
        out.write("\ncroi kernel: exception ")
        out.write(decimal: f.vector)
        out.write(" (")
        out.write(name(vector: f.vector))
        out.write(") error ")
        out.write(hex: f.error_code)
        if f.vector == 14 {
            out.write(", fault address ")
            out.write(hex: arch_read_cr2())
        }
        out.write("\n")
        out.write(register: "rip", f.rip); out.write(register: "rsp", f.rsp)
        out.write(register: "rfl", f.rflags); out.write(register: "cs ", f.cs); out.write("\n")
        out.write(register: "rax", f.rax); out.write(register: "rbx", f.rbx)
        out.write(register: "rcx", f.rcx); out.write(register: "rdx", f.rdx); out.write("\n")
        out.write(register: "rsi", f.rsi); out.write(register: "rdi", f.rdi)
        out.write(register: "rbp", f.rbp); out.write(register: "r8 ", f.r8); out.write("\n")
        out.write(register: "r9 ", f.r9); out.write(register: "r10", f.r10)
        out.write(register: "r11", f.r11); out.write(register: "r12", f.r12); out.write("\n")
        out.write(register: "r13", f.r13); out.write(register: "r14", f.r14)
        out.write(register: "r15", f.r15); out.write("\n")
    }

    static func name(vector: UInt64) -> StaticString {
        switch vector {
        case 0: "divide error"
        case 1: "debug"
        case 2: "NMI"
        case 3: "breakpoint"
        case 4: "overflow"
        case 5: "bound range"
        case 6: "invalid opcode"
        case 7: "device not available"
        case 8: "double fault"
        case 10: "invalid TSS"
        case 11: "segment not present"
        case 12: "stack fault"
        case 13: "general protection"
        case 14: "page fault"
        case 16: "x87 FP error"
        case 17: "alignment check"
        case 18: "machine check"
        case 19: "SIMD FP error"
        case 20: "virtualization"
        case 21: "control protection"
        default: vector < 32 ? "reserved" : "interrupt"
        }
    }

    #elseif arch(arm64)
    static func exceptionClass(_ f: arch_exception_frame_t) -> UInt64 { (f.esr >> 26) & 0x3F }

    /// Synchronous exception from the current EL (SP_ELx) with EC = BRK.
    static func isBreakpoint(_ f: arch_exception_frame_t) -> Bool {
        f.slot == 4 && exceptionClass(f) == 0x3C
    }

    /// SError from any of the four vector groups.
    static func isSError(_ f: arch_exception_frame_t) -> Bool { f.slot & 3 == 3 }

    /// Data or instruction aborts whose status is a translation, access
    /// flag or permission fault (DFSC/IFSC 0b0001xx..0b0011xx).
    static func pageFault(_ f: arch_exception_frame_t) -> PageFault? {
        let ec = exceptionClass(f)
        guard ec == 0x20 || ec == 0x21 || ec == 0x24 || ec == 0x25, f.slot & 3 == 0 else { return nil }
        let status = f.esr & 0x3F
        guard status >= 0x04, status <= 0x0F else { return nil }
        let instruction = ec == 0x20 || ec == 0x21
        return PageFault(address: f.far, write: !instruction && f.esr & (1 << 6) != 0, execute: instruction)
    }
    static func programCounter(_ f: arch_exception_frame_t) -> UInt64 { f.elr }
    static func framePointer(_ f: arch_exception_frame_t) -> UInt64 { f.x.29 }
    static func stackPointer(_ f: arch_exception_frame_t) -> UInt64 { f.sp }
    static func interruptsWereEnabled(_ f: arch_exception_frame_t) -> Bool { f.spsr & (1 << 7) == 0 }  // PSTATE.I
    /// PAN: a permission fault with PSTATE.PAN set (ldtr/sttr, which the
    /// accessors use, aren't subject to PAN, so it was a plain access).
    static func userAccessBlocked(_ f: arch_exception_frame_t) -> Bool {
        let ec = exceptionClass(f)
        return (ec == 0x24 || ec == 0x25) && (0x0C...0x0F).contains(f.esr & 0x3F) && f.spsr & (1 << 22) != 0
    }
    /// Slots 8-15: from a lower EL.
    static func fromUser(_ f: arch_exception_frame_t) -> Bool { f.slot >= 8 && f.slot < 16 }
    static func isSyscall(_ f: arch_exception_frame_t) -> Bool { f.slot == 8 && exceptionClass(f) == 0x15 }  // SVC64
    static func syscallNumber(_ f: arch_exception_frame_t) -> UInt64 { f.x.16 }  // x16, as Zircon
    static func syscallArgument(_ f: arch_exception_frame_t, _ i: Int) -> UInt64 {
        withUnsafeBytes(of: f.x) { unsafe $0.load(fromByteOffset: 8 * i, as: UInt64.self) }
    }
    static func setSyscallResult(_ f: inout arch_exception_frame_t, _ value: UInt64) { f.x.0 = value }
    static func setProgramCounter(_ f: inout arch_exception_frame_t, _ pc: UInt64) { f.elr = pc }

    /// IRQ, from the current EL or from EL0 (slots 1, 5, 9, 13).
    static func isInterrupt(_ f: arch_exception_frame_t) -> Bool { f.slot < 16 && f.slot & 3 == 1 }  // IRQ, any EL

    /// The vector found the stack overflowed and switched stacks (slot + 16).
    static func isStackOverflow(_ f: arch_exception_frame_t) -> Bool { f.slot >= 16 }

    /// brk leaves elr pointing at itself.
    static func skipBreakpoint(_ f: inout arch_exception_frame_t) { f.elr += 4 }

    static func report(_ f: arch_exception_frame_t, to out: some TextOutput) {
        out.write("\ncroi kernel: exception: ")
        out.write(kind(slot: f.slot & 15))
        out.write(", ")
        out.write(name(exceptionClass: exceptionClass(f)))
        out.write("\n")
        out.write(register: "elr ", f.elr); out.write(register: "esr ", f.esr)
        out.write(register: "far ", f.far); out.write("\n")
        out.write(register: "spsr", f.spsr); out.write(register: "sp  ", f.sp); out.write("\n")
        withUnsafeBytes(of: f.x) { bytes in
            let x = unsafe RawSpan(_unsafeBytes: bytes)
            for i in 0..<31 {
                out.write(register: registerName(i), x.load(fromByteOffset: i * 8, as: UInt64.self))
                if i % 4 == 3 || i == 30 { out.write("\n") }
            }
        }
    }

    static func kind(slot: UInt64) -> StaticString {
        switch slot {
        case 0...3: "current EL with SP_EL0"
        case 4: "synchronous"
        case 5: "IRQ"
        case 6: "FIQ"
        case 7: "SError"
        default: "from a lower EL"
        }
    }

    static func name(exceptionClass ec: UInt64) -> StaticString {
        switch ec {
        case 0x00: "unknown reason"
        case 0x07: "FP/SIMD access"
        case 0x0E: "illegal execution state"
        case 0x15: "SVC"
        case 0x20, 0x21: "instruction abort"
        case 0x22: "PC alignment fault"
        case 0x24, 0x25: "data abort"
        case 0x26: "SP alignment fault"
        case 0x2F: "SError"
        case 0x3C: "BRK"
        default: "other"
        }
    }

    static func registerName(_ i: Int) -> StaticString {
        switch i {
        case 0: "x0 "; case 1: "x1 "; case 2: "x2 "; case 3: "x3 "; case 4: "x4 "
        case 5: "x5 "; case 6: "x6 "; case 7: "x7 "; case 8: "x8 "; case 9: "x9 "
        case 10: "x10"; case 11: "x11"; case 12: "x12"; case 13: "x13"; case 14: "x14"
        case 15: "x15"; case 16: "x16"; case 17: "x17"; case 18: "x18"; case 19: "x19"
        case 20: "x20"; case 21: "x21"; case 22: "x22"; case 23: "x23"; case 24: "x24"
        case 25: "x25"; case 26: "x26"; case 27: "x27"; case 28: "x28"; case 29: "fp "
        default: "lr "
        }
    }

    #elseif arch(riscv64)
    static func isBreakpoint(_ f: arch_exception_frame_t) -> Bool { f.scause == 3 && f.overflow == 0 }
    static func pageFault(_ f: arch_exception_frame_t) -> PageFault? {
        guard f.overflow == 0, f.scause == 12 || f.scause == 13 || f.scause == 15 else { return nil }
        return PageFault(address: f.stval, write: f.scause == 15, execute: f.scause == 12)
    }
    static func programCounter(_ f: arch_exception_frame_t) -> UInt64 { f.sepc }
    static func framePointer(_ f: arch_exception_frame_t) -> UInt64 { f.x.8 }  // s0
    static func stackPointer(_ f: arch_exception_frame_t) -> UInt64 { f.x.2 }
    static func interruptsWereEnabled(_ f: arch_exception_frame_t) -> Bool { f.sstatus & (1 << 5) != 0 }  // SPIE
    /// SUM was clear: the access didn't go through an accessor.
    static func userAccessBlocked(_ f: arch_exception_frame_t) -> Bool { f.sstatus & (1 << 18) == 0 }
    /// sstatus.SPP clear: the trap came from U-mode.
    static func fromUser(_ f: arch_exception_frame_t) -> Bool { f.sstatus & (1 << 8) == 0 }
    static func isSyscall(_ f: arch_exception_frame_t) -> Bool { f.scause == 8 }  // ecall from U
    static func syscallNumber(_ f: arch_exception_frame_t) -> UInt64 { f.x.17 }  // a7
    static func syscallArgument(_ f: arch_exception_frame_t, _ i: Int) -> UInt64 {
        withUnsafeBytes(of: f.x) { unsafe $0.load(fromByteOffset: 8 * (10 + i), as: UInt64.self) }  // a0...
    }
    /// a0, and past the ecall.
    static func setSyscallResult(_ f: inout arch_exception_frame_t, _ value: UInt64) {
        f.x.10 = value
        f.sepc += 4
    }
    static func setProgramCounter(_ f: inout arch_exception_frame_t, _ pc: UInt64) { f.sepc = pc }
    static func isInterrupt(_ f: arch_exception_frame_t) -> Bool { f.scause >> 63 != 0 }

    /// The entry found the stack overflowed and switched stacks.
    static func isStackOverflow(_ f: arch_exception_frame_t) -> Bool { f.overflow != 0 }

    /// ebreak leaves sepc pointing at itself; it may be compressed (2 bytes).
    static func skipBreakpoint(_ f: inout arch_exception_frame_t) {
        let low = unsafe UnsafePointer<UInt16>(bitPattern: UInt(f.sepc))!.pointee
        f.sepc += low & 0x3 == 0x3 ? 4 : 2
    }

    static func report(_ f: arch_exception_frame_t, to out: some TextOutput) {
        let interrupt = f.scause >> 63 != 0
        let code = f.scause & ~(1 << 63)
        out.write("\ncroi kernel: ")
        out.write(interrupt ? "interrupt " : "exception ")
        out.write(decimal: code)
        out.write(" (")
        out.write(interrupt ? "interrupt" : name(cause: code))
        out.write(")\n")
        out.write(register: "sepc   ", f.sepc); out.write(register: "stval  ", f.stval); out.write("\n")
        out.write(register: "sstatus", f.sstatus); out.write(register: "scause ", f.scause); out.write("\n")
        withUnsafeBytes(of: f.x) { bytes in
            let x = unsafe RawSpan(_unsafeBytes: bytes)
            for i in 1..<32 {
                out.write(register: registerName(i), x.load(fromByteOffset: i * 8, as: UInt64.self))
                if i % 4 == 3 || i == 31 { out.write("\n") }
            }
        }
    }

    static func name(cause: UInt64) -> StaticString {
        switch cause {
        case 0: "instruction address misaligned"
        case 1: "instruction access fault"
        case 2: "illegal instruction"
        case 3: "breakpoint"
        case 4: "load address misaligned"
        case 5: "load access fault"
        case 6: "store address misaligned"
        case 7: "store access fault"
        case 8: "ecall from U-mode"
        case 9: "ecall from S-mode"
        case 12: "instruction page fault"
        case 13: "load page fault"
        case 15: "store page fault"
        default: "other"
        }
    }

    static func registerName(_ i: Int) -> StaticString {
        switch i {
        case 1: "ra "; case 2: "sp "; case 3: "gp "; case 4: "tp "; case 5: "t0 "
        case 6: "t1 "; case 7: "t2 "; case 8: "s0 "; case 9: "s1 "; case 10: "a0 "
        case 11: "a1 "; case 12: "a2 "; case 13: "a3 "; case 14: "a4 "; case 15: "a5 "
        case 16: "a6 "; case 17: "a7 "; case 18: "s2 "; case 19: "s3 "; case 20: "s4 "
        case 21: "s5 "; case 22: "s6 "; case 23: "s7 "; case 24: "s8 "; case 25: "s9 "
        case 26: "s10"; case 27: "s11"; case 28: "t3 "; case 29: "t4 "; case 30: "t5 "
        default: "t6 "
        }
    }
    #endif
}

#if arch(arm64)
/// What an SError's syndrome says about recovery (ESR_EL1, EC 0x2F).
/// Corrected errors are counted and execution continues. Restartable and
/// recoverable ones (RAS) will be delivered to the faulting process once
/// there is user mode; anything else, and anything from the kernel, is
/// fatal. (Zircon only counts SErrors.)
enum SErrorPolicy {
    enum Kind: Equatable {
        case corrected
        case recoverable      // UER: the error was contained
        case restartable      // UEO
        case unrecoverable    // UEU
        case uncontainable    // UC
        case unclassified     // implementation defined, or no RAS syndrome
    }

    nonisolated(unsafe) static var corrected = 0

    static func classify(esr: UInt64) -> Kind {
        guard (esr >> 26) & 0x3F == 0x2F, esr & (1 << 24) == 0 else { return .unclassified }  // EC, IDS
        guard esr & 0x3F == 0x11 else { return .unclassified }  // DFSC: asynchronous SError
        switch (esr >> 10) & 0x7 {  // AET
        case 0b000: return .uncontainable
        case 0b001: return .unrecoverable
        case 0b010: return .restartable
        case 0b011: return .recoverable
        case 0b110: return .corrected
        default: return .unclassified
        }
    }

    static func describe(_ kind: Kind) -> StaticString {
        switch kind {
        case .corrected: "corrected"
        case .recoverable: "recoverable (UER)"
        case .restartable: "restartable (UEO)"
        case .unrecoverable: "unrecoverable (UEU)"
        case .uncontainable: "uncontainable (UC)"
        case .unclassified: "unclassified"
        }
    }
}
#endif

/// A page fault, decoded from an exception frame.
struct PageFault {
    var address: UInt64
    var write: Bool
    var execute: Bool
    /// amd64: the access broke the thread's PKRU (error code bit 5).
    var protectionKey = false
}

/// The .croi_fixups table (usercopy.h): user-access instructions and where
/// each resumes if its fault can't be resolved.
enum Fixups {
    static func recovery(for pc: UInt64) -> UInt64? {
        var here = croi_fixups_begin()
        while here < croi_fixups_end() {
            let entry = unsafe UnsafeRawPointer(bitPattern: UInt(here))!
            let instruction = here &+ UInt64(bitPattern: Int64(unsafe entry.load(as: Int32.self)))
            if instruction == pc {
                return here &+ 4 &+ UInt64(bitPattern: Int64(unsafe entry.load(fromByteOffset: 4, as: Int32.self)))
            }
            here += 8
        }
        return nil
    }

    static var count: Int {
        Int(croi_fixups_end() - croi_fixups_begin()) / 8
    }
}
