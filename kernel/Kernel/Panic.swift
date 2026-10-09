import CKernel
import Fmt

/// The console that panics and exception reports go to. Set as soon as
/// kernel_main has a UART, and moved when the UART mapping moves.
nonisolated(unsafe) var panicConsole: Uart?

/// Breakpoints taken and resumed (see the boot self-test in kernel_main).
nonisolated(unsafe) var breakpointsHandled = 0

/// Reports a fatal kernel error and stops this CPU.
func panic(_ message: StaticString) -> Never {
    if let console = panicConsole {
        console.write("\ncroi kernel: PANIC: ")
        console.write(message)
        console.write("\n")
    }
    arch_halt()
}

extension TextOutput {
    /// Writes `name=0x…` padded into a column, for register dumps.
    func write(register name: StaticString, _ value: UInt64) {
        write(" ")
        write(name)
        write("=")
        var digits = InlineArray<16, UInt8>(repeating: UInt8(ascii: "0"))
        var v = value
        for i in (0..<16).reversed() {
            let d = UInt8(truncatingIfNeeded: v & 0xF)
            digits[i] = d < 10 ? UInt8(ascii: "0") + d : UInt8(ascii: "a") + d - 10
            v >>= 4
        }
        write(utf8: digits.span)
    }
}
