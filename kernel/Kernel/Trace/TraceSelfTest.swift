import CKernel
import Fmt
import Synchronization

/// Boot self-test for the trace core: probe cost (disabled and enabled),
/// ring contents from real scheduler and interrupt activity, oneshot drop
/// accounting, and that `stop` stops. Panics on failure.
enum TraceSelfTest {
    nonisolated(unsafe) static var queue = QueuePointer(address: 0)
    nonisolated(unsafe) static var turn = 0
    static var rounds: Int { 50 }

    static func run(_ console: Uart) {
        let (disabled, enabled) = cost(console)
        let (wakes, switches, irqs) = contents()
        oneshotDrops()
        Trace.release()

        console.write("  trace:  probe off ")
        console.write(decimal: disabled)
        console.write(" ps, on ")
        console.write(decimal: enabled)
        console.write(" ns")
        console.write(enforcesCost ? " (budget 30 ns enforced)" : " (emulated: budget not enforced)")
        console.write("; ping-pong traced: ")
        console.write(decimal: UInt64(wakes))
        console.write(" wakes, ")
        console.write(decimal: UInt64(switches))
        console.write(" switches, ")
        console.write(decimal: UInt64(irqs))
        console.write(" irqs; oneshot drops counted, stop stops\n")
    }

    // MARK: Cost

    /// ps per disabled probe and ns per enabled one, from the bootstrap
    /// thread with interrupts on.
    private static func cost(_ console: Uart) -> (UInt64, UInt64) {
        let n: UInt64 = 200_000
        Trace.stop()
        var began = Clock.now()
        for i in 0..<n { Trace.event(CROI_TRACE_MARK, UInt16(CROI_TK_MARK), i) }
        let disabled = (Clock.now() - began) * 1000 / n

        start(CROI_TRACE_MARK, pages: 64, mode: CROI_TRACE_CIRCULAR)
        let events: UInt64 = 20_000
        began = Clock.now()
        for i in 0..<events { Trace.event(CROI_TRACE_MARK, UInt16(CROI_TK_MARK), i, i) }
        let enabled = (Clock.now() - began) / events
        Trace.stop()
        if enforcesCost, enabled >= 30 {
            console.write("  trace:  enabled probe costs ")
            console.write(decimal: enabled)
            console.write(" ns\n")
            panic("trace self-test: enabled probe over 30 ns")
        }
        return (disabled, enabled)
    }

    /// Timing means something on hardware or under KVM, not under TCG.
    static var enforcesCost: Bool {
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

    // MARK: Contents

    /// Ping-pong between two CPUs with sched and irq on: the rings must name
    /// who woke whom, the switches into each thread on its own CPU, and
    /// interrupt entry/exit pairs; time never goes back within a ring.
    private static func contents() -> (Int, Int, Int) {
        guard Smp.count > 2 else { return (0, 0, 0) }
        queue = QueuePointer.allocate()
        turn = 0
        start(CROI_TRACE_SCHED | CROI_TRACE_IRQ, pages: 64, mode: CROI_TRACE_ONESHOT)
        let ping = spawn("ping", 1, 0)
        let pong = spawn("pong", 2, 1)
        let pingId = UInt64(ping.thread.pointee.traceId), pongId = UInt64(pong.thread.pointee.traceId)
        guard ping.join() == 0, pong.join() == 0 else { panic("trace self-test: ping-pong") }
        Trace.stop()
        queue.deallocate()

        var wakes = 0, switchesIn = 0, irqs = 0
        for cpu in 0..<Smp.count {
            var enters = 0, exits = 0
            guard let header = Trace.header(cpu) else { panic("trace self-test: no ring") }
            guard header.drops == 0 else { panic("trace self-test: ring too small for the test") }
            var last: UInt64 = 0
            Trace.forEachRecord(cpu) { record in
                guard record.cpu == UInt16(cpu), record.time >= last else { panic("trace self-test: bad record order") }
                last = record.time
                switch record.kind {
                case UInt16(CROI_TK_WAKE):
                    if (UInt64(record.thread) == pingId && record.a == pongId)
                        || (UInt64(record.thread) == pongId && record.a == pingId) { wakes += 1 }
                case UInt16(CROI_TK_SWITCH):
                    if (cpu == 1 && record.a == pingId) || (cpu == 2 && record.a == pongId) { switchesIn += 1 }
                case UInt16(CROI_TK_IRQ_ENTER): enters += 1
                case UInt16(CROI_TK_IRQ_EXIT): exits += 1
                default: break
                }
            }
            // Starting or stopping mid-handler leaves at most one unmatched
            // record at each end of a ring.
            guard abs(enters - exits) <= 1 else { panic("trace self-test: irq records unpaired") }
            irqs += enters
        }
        // Most hand-overs are wakeups, and every wakeup of a blocked thread
        // is followed by a switch into it on its own CPU.
        guard wakes >= rounds, switchesIn >= wakes else { panic("trace self-test: wakes or switches missing") }
        guard irqs > 0 else { panic("trace self-test: no irq records") }
        return (wakes, switchesIn, irqs)
    }

    private static let pingPong: Thread.Entry = { me in
        for _ in 0..<rounds {
            Scheduler.locked {
                while turn != Int(me) {
                    _ = Scheduler.block(on: queue, deadline: .max)
                }
            }
            // Our turn. The partner handed over and went straight back to
            // waiting; give it time to block, so the hand-over below is a
            // real cross-CPU wakeup.
            let until = Clock.now() + 200_000
            while Clock.now() < until { arch_spin_pause() }
            Scheduler.locked {
                turn = 1 - Int(me)
                Scheduler.wakeAll(queue)
            }
        }
        return 0
    }

    // MARK: Oneshot

    /// 1000 marks into one-page oneshot rings (128 records each): every
    /// mark is either recorded or counted as dropped, and none is written
    /// after `stop`.
    private static func oneshotDrops() {
        start(CROI_TRACE_MARK, pages: 1, mode: CROI_TRACE_ONESHOT)
        for i in 0..<1000 { Trace.event(CROI_TRACE_MARK, UInt16(CROI_TK_MARK), UInt64(i)) }
        Trace.stop()
        var written: UInt64 = 0, dropped: UInt64 = 0
        for cpu in 0..<Smp.count {
            let header = Trace.header(cpu)!
            guard header.head <= header.capacity, header.capacity == 128 else { panic("trace self-test: oneshot overran") }
            written += header.head
            dropped += header.drops
        }
        guard written + dropped == 1000, dropped > 0 else { panic("trace self-test: drops not counted") }
        for i in 0..<100 { Trace.event(CROI_TRACE_MARK, UInt16(CROI_TK_MARK), UInt64(i)) }
        var after: UInt64 = 0
        for cpu in 0..<Smp.count { after += Trace.header(cpu)!.head + Trace.header(cpu)!.drops }
        guard after == 1000 else { panic("trace self-test: recorded after stop") }
    }

    // MARK: Helpers

    private static func start(_ categories: UInt32, pages: Int, mode: UInt32) {
        do throws(VmError) {
            try Trace.start(categories: categories, pages: pages, mode: mode)
        } catch {
            panic("trace self-test: no memory for rings")
        }
    }

    private static func spawn(_ name: StaticString, _ cpu: Int, _ argument: UInt64) -> ThreadHandle {
        do throws(VmError) {
            return try Scheduler.spawn(name, cpu: cpu, pingPong, argument)
        } catch {
            panic("trace self-test: spawn failed")
        }
    }
}
