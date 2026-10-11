import CKernel
import Fmt
import Synchronization

/// Inter-processor interrupts: a per-CPU mailbox of pending kinds, and a
/// synchronous "run this on the other CPUs" call (Zircon's mp_sync_exec)
/// that TLB shootdown is built on.
///
/// Deadlock rules: a CPU waiting for others (for the call lock, or for
/// acknowledgements) keeps draining its own mailbox, so two CPUs calling
/// each other with interrupts masked still make progress. Only CPUs that
/// have set up their interrupt controller (`PerCpu.interruptsReady`) are
/// called.
enum Ipi {
    /// Mailbox bits.
    static var call: UInt32 { 1 << 0 }
    /// Run the scheduler when the interrupt returns.
    static var reschedule: UInt32 { 1 << 1 }
    /// Halt for good (power off and reset, K10e).
    static var stop: UInt32 { 1 << 2 }
    /// Print where this CPU was interrupted (lockup reports).
    static var report: UInt32 { 1 << 3 }

    typealias Function = @convention(c) (UInt64) -> Void

    // The one outstanding call, published before the mailbox bits are set.
    nonisolated(unsafe) private static var function: Function?
    nonisolated(unsafe) private static var argument: UInt64 = 0
    private static let remaining = Atomic<Int>(0)
    private static let busy = Atomic<Bool>(false)

    /// Runs `function(argument)` on every other ready CPU and waits until
    /// all have finished. Returns how many CPUs ran it. Any context.
    @discardableResult
    static func callOthers(_ function: Function, _ argument: UInt64) -> Int {
        call(cpus: ~0, function, argument)
    }

    /// Runs `function(argument)` on the other ready CPUs in `cpus` (a bit
    /// per CPU) and waits for them. Returns how many ran it.
    @discardableResult
    static func call(cpus: UInt64, _ function: Function, _ argument: UInt64) -> Int {
        call(mask: cpus, function, argument)
    }

    /// Runs `function(argument)` on CPU `cpu` (this CPU: directly) and
    /// waits for it. Returns false if that CPU can't take IPIs.
    @discardableResult
    static func call(onCpu cpu: Int, _ function: Function, _ argument: UInt64) -> Bool {
        if UInt32(cpu) == Cpu.current {
            let saved = arch_interrupts_save()
            function(argument)
            arch_interrupts_restore(saved)
            return true
        }
        return call(mask: 1 << UInt64(cpu), function, argument) == 1
    }

    /// Sends the reschedule kind to `cpu` (no waiting).
    static func requestReschedule(_ cpu: Int) {
        let record = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(Smp.records[cpu]))!
        _ = unsafe record.pointee.ipiPending.bitwiseOr(reschedule, ordering: .releasing)
        unsafe Interrupts.sendIpi(record)
    }

    /// Runs `function` on the other ready CPUs in `mask`.
    private static func call(mask: UInt64, _ function: Function, _ argument: UInt64) -> Int {
        let saved = arch_interrupts_save()
        defer { arch_interrupts_restore(saved) }

        while !busy.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged {
            drainThisCpu()
            arch_spin_pause()
        }
        let me = Cpu.current
        var targets = 0
        for i in 0..<Smp.count where UInt32(i) != me && isReady(i) && mask & (1 << UInt64(i)) != 0 {
            targets += 1
        }
        guard targets > 0 else {
            busy.store(false, ordering: .releasing)
            return 0
        }
        Self.function = function
        Self.argument = argument
        remaining.store(targets, ordering: .releasing)
        for i in 0..<Smp.count where UInt32(i) != me && isReady(i) && mask & (1 << UInt64(i)) != 0 {
            let record = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(Smp.records[i]))!
            _ = unsafe record.pointee.ipiPending.bitwiseOr(call, ordering: .releasing)
            unsafe Interrupts.sendIpi(record)
        }
        while remaining.load(ordering: .acquiring) > 0 {
            drainThisCpu()
            arch_spin_pause()
        }
        busy.store(false, ordering: .releasing)
        return targets
    }

    private static let stopped = Atomic<Int>(0)

    /// Halts every other ready CPU (interrupts masked, for good) and waits
    /// up to `patience` ns for them to stop. Returns how many did; a CPU
    /// running masked for longer is left running. No coming back.
    static func stopOthers(patience: UInt64) -> Int {
        let saved = arch_interrupts_save()
        defer { arch_interrupts_restore(saved) }
        let me = Cpu.current
        var targets = 0
        for i in 0..<Smp.count where UInt32(i) != me && isReady(i) {
            let record = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(Smp.records[i]))!
            _ = unsafe record.pointee.ipiPending.bitwiseOr(stop, ordering: .releasing)
            unsafe Interrupts.sendIpi(record)
            targets += 1
        }
        let deadline = Clock.now() + patience
        while stopped.load(ordering: .acquiring) < targets && Clock.now() < deadline {
            arch_spin_pause()
        }
        return stopped.load(ordering: .acquiring)
    }

    /// Asks `cpu` to print the context its IPI interrupts and a backtrace
    /// (no waiting: a CPU running masked never answers).
    static func requestReport(_ cpu: Int) {
        let record = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(Smp.records[cpu]))!
        _ = unsafe record.pointee.ipiPending.bitwiseOr(report, ordering: .releasing)
        unsafe Interrupts.sendIpi(record)
    }

    private static func reportHere(_ percpu: UnsafePointer<PerCpu>) {
        guard let console = panicConsole else { return }
        ConsoleLock.withLock { unsafe report(percpu, console) }  // one line, whole
    }

    private static func report(_ percpu: UnsafePointer<PerCpu>, _ console: Uart) {
        let frameAddress = unsafe percpu.pointee.interruptFrame
        console.write("cpu ")
        console.write(decimal: UInt64(Cpu.current))
        guard frameAddress != 0 else {
            console.write(": no interrupted context (drained outside an interrupt)\n")
            return
        }
        let frame = unsafe UnsafePointer<arch_exception_frame_t>(bitPattern: UInt(frameAddress))!
        var frames = InlineArray<16, UInt64>(repeating: 0)
        let (pc, count) = unsafe Sampler.backtrace(frame, Scheduler.current, &frames, encode: false)
        console.write(unsafe ExceptionFrame.fromUser(frame.pointee) ? " interrupted in user mode at " : " interrupted in the kernel at ")
        console.write(hex: pc)
        console.write(", frames:")
        for i in 0..<count {
            console.write(" ")
            console.write(hex: frames[i])
        }
        console.write("\n")
    }

    /// The IPI interrupt handler.
    static func handle() {
        // One count per IPI interrupt (CPU stats), by what it carries: a
        // reschedule alone, or anything else.
        if let percpu = unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(arch_percpu())) {
            if unsafe percpu.pointee.ipiPending.load(ordering: .relaxed) == reschedule {
                unsafe percpu.pointee.stats.rescheduleIpis += 1
            } else {
                unsafe percpu.pointee.stats.genericIpis += 1
            }
        }
        drainThisCpu()
    }

    /// Handles whatever is pending in this CPU's mailbox.
    static func drainThisCpu() {
        let record = arch_percpu()
        guard record != 0 else { return }
        let percpu = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(record))!
        let pending = unsafe percpu.pointee.ipiPending.exchange(0, ordering: .acquiring)
        if pending & call != 0, let function {
            function(argument)
            remaining.subtract(1, ordering: .releasing)
        }
        if pending & report != 0 { unsafe reportHere(percpu) }
        if pending & stop != 0 {
            stopped.add(1, ordering: .releasing)
            arch_halt()
        }
        if pending & reschedule != 0 {
            Scheduler.requestPreemption()
        }
    }

    static func isReady(_ cpu: Int) -> Bool {
        let record = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(Smp.records[cpu]))!
        return unsafe record.pointee.interruptsReady.load(ordering: .acquiring)
    }

    /// Ready CPUs other than this one.
    static var otherReadyCpus: Int {
        let me = Cpu.current
        var count = 0
        for i in 0..<Smp.count where UInt32(i) != me && isReady(i) {
            count += 1
        }
        return count
    }
}

/// Cross-CPU TLB invalidation after a page-table change. arm64's TLBI is
/// broadcast in hardware, so only amd64 and rv64 need IPIs.
enum TlbShootdown {
    /// Above this many pages, remote CPUs flush everything instead.
    private static var pageLimit: UInt64 { 32 }

    private struct Range {
        var start: UInt64
        var pages: UInt64
    }

    /// Invalidates [start, start+size) on the other ready CPUs in `cpus`
    /// (default: all). The caller has already invalidated it locally.
    static func flushOthers(_ start: UInt64, _ size: UInt64, cpus: UInt64 = ~0) {
        #if arch(x86_64) || arch(riscv64)
        let others = cpus & ~(1 << UInt64(Cpu.current))
        guard others != 0, Ipi.otherReadyCpus > 0 else { return }
        var range = Range(start: start, pages: (size + KernelLayout.pageSize - 1) / KernelLayout.pageSize)
        let address = withUnsafeMutablePointer(to: &range) { UInt64(UInt(bitPattern: $0)) }
        Ipi.call(cpus: others, invalidate, address)
        #endif
    }

    /// Shootdowns each CPU has taken (written only by that CPU; for the
    /// self-test and dumps).
    nonisolated(unsafe) private static var receivedCounts = InlineArray<64, UInt64>(repeating: 0)

    static func received(_ cpu: Int) -> UInt64 { receivedCounts[cpu] }

    private static let invalidate: Ipi.Function = { address in
        receivedCounts[Int(Cpu.current)] &+= 1
        let range = unsafe UnsafePointer<Range>(bitPattern: UInt(address))!.pointee
        if range.pages > pageLimit {
            arch_tlb_invalidate_all()
            return
        }
        for i in 0..<range.pages {
            arch_tlb_invalidate_page(range.start + i * KernelLayout.pageSize)
        }
    }
}
