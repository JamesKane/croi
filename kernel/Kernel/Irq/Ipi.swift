import CKernel
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
        let saved = arch_interrupts_save()
        defer { arch_interrupts_restore(saved) }

        while !busy.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged {
            drainThisCpu()
            arch_spin_pause()
        }
        let me = Cpu.current
        var targets = 0
        for i in 0..<Smp.count where UInt32(i) != me && isReady(i) {
            targets += 1
        }
        Self.function = function
        Self.argument = argument
        remaining.store(targets, ordering: .releasing)
        for i in 0..<Smp.count where UInt32(i) != me && isReady(i) {
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

    /// The IPI interrupt handler.
    static func handle() {
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

    /// Invalidates [start, start+size) on every other ready CPU. The caller
    /// has already invalidated it locally.
    static func flushOthers(_ start: UInt64, _ size: UInt64) {
        #if arch(x86_64) || arch(riscv64)
        guard Ipi.otherReadyCpus > 0 else { return }
        var range = Range(start: start, pages: (size + KernelLayout.pageSize - 1) / KernelLayout.pageSize)
        let address = withUnsafeMutablePointer(to: &range) { UInt64(UInt(bitPattern: $0)) }
        Ipi.callOthers(invalidate, address)
        #endif
    }

    private static let invalidate: Ipi.Function = { address in
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
