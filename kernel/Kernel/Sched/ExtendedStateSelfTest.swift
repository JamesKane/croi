import CKernel
import Fmt
import Synchronization

/// Boot self-test for K3d: the sizes are sane for what was found, every
/// CPU measures the same again, and areas are allocated, aligned, in their
/// initial state and freed with their thread (kernel threads get none). Runs before the
/// scheduler starts; the thread part runs in `threads()` afterwards.
enum ExtendedStateSelfTest {
    static let sawArea = Atomic<Int>(0)

    static func run(_ console: Uart) {
        let facts = ExtendedState.facts
        let (eager, lazy) = (ExtendedState.eagerSize, ExtendedState.lazySize)
        guard ExtendedState.sizes(facts) == (eager, lazy) else { panic("xstate self-test: sizes not reproducible") }
        #if arch(x86_64)
        guard eager >= 512 else { panic("xstate self-test: smaller than FXSAVE") }
        if facts.features & (1 << 2) != 0 { guard eager >= 576 + 256 else { panic("xstate self-test: no room for AVX") } }
        guard !facts.xfd || facts.features & (1 << 18) == 0 || lazy >= 8192 else { panic("xstate self-test: AMX tiles") }
        #elseif arch(arm64)
        guard !facts.fp || eager >= 528 else { panic("xstate self-test: no room for V0-V31") }
        guard facts.sveLength == 0 || (facts.sveLength >= 16 && facts.sveLength <= 256 && facts.sveLength % 16 == 0) else {
            panic("xstate self-test: impossible SVE vector length")
        }
        // Each CPU now runs at the shared length: measuring again (asking
        // for no more than it) gives exactly that.
        if facts.sveLength > 0 { guard arch_sve_vector_length(facts.sveLength / 16 - 1) == facts.sveLength else {
            panic("xstate self-test: SVE length not settled")
        } }
        #elseif arch(riscv64)
        guard !facts.doubleFloat || eager >= 264 else { panic("xstate self-test: no room for f0-f31") }
        #endif
        guard ExtendedState.measure().common(facts) == facts else { panic("xstate self-test: boot CPU lost features") }

        console.write("  xstate: ")
        ExtendedState.describe(to: console)
        console.write("; ")
        console.write(decimal: UInt64(eager))
        console.write(" B per user thread + ")
        console.write(decimal: UInt64(lazy))
        console.write(" B on first use")
        console.write(ExtendedState.uniform ? ", same on every CPU\n" : ", CPUs differ: using what all share\n")
    }

    /// With the scheduler running: a thread spawned with an area sees it
    /// aligned and zeroed; a kernel thread has none; both are freed.
    static func threads() {
        let before = ExtendedState.liveAreas.load(ordering: .relaxed)
        let with = spawn(true)
        let without = spawn(false)
        guard with.join() == 0, without.join() == 0 else { panic("xstate self-test: thread saw a bad area") }
        guard ExtendedState.liveAreas.load(ordering: .relaxed) == before else { panic("xstate self-test: area leaked") }
    }

    private static let check: Thread.Entry = { wanted in
        let area = Scheduler.current.pointee.extendedState
        if wanted == 0 { return area == 0 ? 0 : 1 }
        guard ExtendedState.eagerSize > 0 else { return area == 0 ? 0 : 1 }
        guard area != 0, area % UInt64(ExtendedState.alignment) == 0 else { return 1 }
        let bytes = unsafe UnsafePointer<UInt8>(bitPattern: UInt(area))!
        for i in 0..<ExtendedState.eagerSize where unsafe bytes[i] != 0 {
            #if arch(x86_64)
            if i < 2 || (i >= 24 && i < 28) { continue }  // FCW and MXCSR start at their reset values
            #endif
            return 1
        }
        return 0
    }

    private static func spawn(_ withArea: Bool) -> ThreadHandle {
        do throws(VmError) {
            return try Scheduler.spawn("xstate", extendedState: withArea, check, withArea ? 1 : 0)
        } catch {
            panic("xstate self-test: spawn failed")
        }
    }
}
