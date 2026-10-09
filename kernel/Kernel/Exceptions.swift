import CKernel
import Fmt

/// Common entry for every exception (kernel.h). Breakpoints resume after
/// the instruction; anything else is unexpected this early and is fatal.
@c @implementation
func arch_exception(_ frame: UnsafeMutablePointer<arch_exception_frame_t>) {
    if unsafe ExceptionFrame.isBreakpoint(frame.pointee) {
        unsafe ExceptionFrame.skipBreakpoint(&frame.pointee)
        breakpointsHandled += 1
        return
    }
    if let console = panicConsole {
        unsafe ExceptionFrame.report(frame.pointee, to: console)
    }
    panic("unhandled exception")
}

/// Per-architecture decoding of `arch_exception_frame_t`.
enum ExceptionFrame {
    #if arch(x86_64)
    static func isBreakpoint(_ f: arch_exception_frame_t) -> Bool { f.vector == 3 }

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

    /// brk leaves elr pointing at itself.
    static func skipBreakpoint(_ f: inout arch_exception_frame_t) { f.elr += 4 }

    static func report(_ f: arch_exception_frame_t, to out: some TextOutput) {
        out.write("\ncroi kernel: exception: ")
        out.write(kind(slot: f.slot))
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
    static func isBreakpoint(_ f: arch_exception_frame_t) -> Bool { f.scause == 3 }

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
