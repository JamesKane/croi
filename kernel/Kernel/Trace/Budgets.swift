import CKernel
import Fmt

/// Budget reports (K9f; Todhchai's performance.md): every timing the boot
/// measures against a budget is printed as one line,
///
///     budget name=<name> value=<n> unit=<ns|count> [limit=<n>] [target=<n>]
///
/// which tools/bench.py collects, takes medians of over several boots and
/// judges against this machine's history. A `limit` fails the boot only
/// where timing is real (KVM or hardware, not TCG) and the command line
/// says `croi.enforce_budgets=1`, i.e. on a quiet machine: on a shared
/// one other work makes timings noisy, so they are reported, not judged.
/// A `target` is the budget proper where croi doesn't meet it yet.
enum Budgets {
    /// Timing means something on hardware or under KVM, not under TCG.
    static var timingIsReal: Bool {
        #if arch(x86_64)
        var regs = InlineArray<4, UInt32>(repeating: 0)
        var span = regs.mutableSpan
        span.withUnsafeMutableBufferPointer { unsafe arch_cpuid(0x4000_0000, 0, $0.baseAddress!) }
        // "TCGTCGTCGTCG" in EBX, ECX, EDX.
        return !(regs[1] == 0x5447_4354 && regs[2] == 0x4354_4743 && regs[3] == 0x4743_5447)
        #else
        return false  // only QEMU's TCG runs these today
        #endif
    }

    /// Whether limits fail the boot.
    static var enforced: Bool { timingIsReal && BootOptions.has("croi.enforce_budgets=1") }

    static func report(_ out: Uart, _ name: StaticString, _ value: UInt64, unit: StaticString = "ns",
                       limit: UInt64? = nil, target: UInt64? = nil) {
        out.write("  budget name=")
        out.write(name)
        out.write(" value=")
        out.write(decimal: value)
        out.write(" unit=")
        out.write(unit)
        if let limit {
            out.write(" limit=")
            out.write(decimal: limit)
        }
        if let target {
            out.write(" target=")
            out.write(decimal: target)
        }
        out.write("\n")
    }
}
