import CroiRuntime

/// A trace session from user space (trace_configure with the root
/// resource): categories on, marks, then every CPU's ring read back
/// through its VMO.
enum Tracing {
    nonisolated(unsafe) static var resource: UInt32 = 0

    static func start(_ categories: UInt32, pages: UInt64 = 64, sampleHz: UInt64 = 0) throws(Failure) {
        try Sys.check("starting the trace", Sys.call(CROI_SYS_TRACE_CONFIGURE, UInt64(resource), CROI_TRACE_OP_START,
                                                     UInt64(categories), pages, UInt64(CROI_TRACE_ONESHOT), sampleHz))
    }

    static func stop() {
        _ = Sys.call(CROI_SYS_TRACE_CONFIGURE, UInt64(resource), CROI_TRACE_OP_STOP)
    }

    static func mark(_ a: UInt64, _ b: UInt64) {
        _ = Sys.call(CROI_SYS_TRACE_CONFIGURE, UInt64(resource), CROI_TRACE_OP_MARK, a, b)
    }

    /// Every record kept, each CPU's oldest first, and the counter's Hz.
    static func records() throws(Failure) -> (records: [croi_trace_record_t], frequency: UInt64) {
        var handles = [UInt32](repeating: 0, count: 64)
        let count = handles.withUnsafeMutableBufferPointer { buffer in
            Sys.call(CROI_SYS_TRACE_CONFIGURE, UInt64(resource), CROI_TRACE_OP_RINGS,
                     UInt64(UInt(bitPattern: buffer.baseAddress)), UInt64(buffer.count))
        }
        guard count > 0 else { throw Failure(what: "getting the trace rings", status: count) }
        var records: [croi_trace_record_t] = []
        var frequency: UInt64 = 0
        for i in 0..<Int(count) {
            defer { Sys.close(handles[i]) }
            var size: UInt64 = 0
            var base: UInt64 = 0
            try Sys.check("sizing a ring", Sys.call(CROI_SYS_VMO_GET_SIZE, UInt64(handles[i]), Sys.address(&size)))
            try Sys.check("mapping a ring", Sys.call(CROI_SYS_VMAR_MAP, UInt64(croi_vmar_root_self())
                                                         | UInt64(CROI_VM_PERM_READ) << 32,
                                                     0, UInt64(handles[i]), 0, size, Sys.address(&base)))
            let ring = unsafe UnsafePointer<croi_trace_ring_t>(bitPattern: UInt(base))!.pointee
            frequency = ring.frequency
            let first = unsafe UnsafePointer<croi_trace_record_t>(bitPattern: UInt(base) + 4096)!
            for j in 0..<Int(min(ring.head, ring.capacity)) { records.append(unsafe first[j]) }
            _ = Sys.call(CROI_SYS_VMAR_UNMAP, UInt64(croi_vmar_root_self()), base, size)
        }
        return (records, frequency)
    }

    /// Counter ticks as ns.
    static func ns(_ ticks: UInt64, _ frequency: UInt64) -> UInt64 {
        let product = ticks.multipliedFullWidth(by: 1_000_000_000)
        return frequency.dividingFullWidth((product.high, product.low)).quotient
    }
}

/// The M2 budgets (Todhchai performance.md §2), measured from the trace.
enum Bench {
    struct Results {
        var nullSyscall: UInt64 = 0      // ns, mean
        var channelCall: UInt64 = 0      // ns, median of batch means
        var portWakeMedian: UInt64 = 0   // ns
        var portWakeP99: UInt64 = 0
        var counterWakeMedian: UInt64 = 0  // ns (K10a)
        var counterWakeP99: UInt64 = 0
        var wakeErrorP99: UInt64 = 0     // ns
        var timelineWakeMedian: UInt64 = 0  // ns (K10b)
        var timelineWakeP99: UInt64 = 0
    }

    static var cpus: (client: UInt64, waiter: UInt64, sleeper: UInt64) { (1 << 1, 1 << 2, 1 << 3) }

    /// `m2.ipc_profile=1`: after the channel_call batches, one more traced
    /// with syscall, scheduler and IPC records, printed as a call's events
    /// and the median time between each and the one before (the probes
    /// themselves cost ~20 ns each; read the shares, not the sum).
    nonisolated(unsafe) static var profileCalls = false

    static func run(resource: UInt32, thread: UInt32) throws(Failure) -> Results {
        Tracing.resource = resource
        var results = Results()
        results.nullSyscall = try nullSyscall()
        results.channelCall = try channelCall(resource: resource, thread: thread)
        (results.portWakeMedian, results.portWakeP99) = try portWake(resource: resource, thread: thread)
        if profilePortWake { try portWakeProfile() }
        (results.counterWakeMedian, results.counterWakeP99) = try counterWake(resource: resource, thread: thread)
        results.wakeErrorP99 = try wakeError(resource: resource, thread: thread)
        (results.timelineWakeMedian, results.timelineWakeP99) = try timelineWake(resource: resource)
        return results
    }

    // MARK: Null syscall

    static func nullSyscall() throws(Failure) -> UInt64 {
        let n: UInt64 = 10_000
        try Tracing.start(UInt32(CROI_TRACE_MARK))
        Tracing.mark(1, 0)
        for _ in 0..<n { _ = Sys.call(CROI_SYS_NULL) }
        Tracing.mark(2, 0)
        Tracing.stop()
        let (records, frequency) = try Tracing.records()
        let marks = records.filter { $0.kind == UInt16(CROI_TK_MARK) }
        guard let start = marks.first(where: { $0.a == 1 }), let end = marks.first(where: { $0.a == 2 }) else {
            throw Failure(what: "finding null syscall marks", status: -25)
        }
        return Tracing.ns(end.time - start.time, frequency) / n
    }

    // MARK: channel_call with deadline donation, one core

    nonisolated(unsafe) static var serverChannel: UInt32 = 0

    static let server: Sys.ThreadEntry = { _, _ in
        var message: UInt64 = 0
        var actual: UInt64 = 0
        while true {
            var observed: UInt32 = 0
            _ = Sys.call(CROI_SYS_OBJECT_WAIT_ONE, UInt64(serverChannel),
                         UInt64(CROI_SIGNAL_READABLE | CROI_SIGNAL_PEER_CLOSED), .max, Sys.address(&observed))
            let read = Sys.call(CROI_SYS_CHANNEL_READ, UInt64(serverChannel), 0, Sys.address(&message), 0, 8,
                                Sys.address(&actual))
            if read != 0 {
                if read == -22 { continue }  // SHOULD_WAIT
                break                        // PEER_CLOSED: the client is done
            }
            // The reply carries the call's txid (its first four bytes).
            _ = Sys.call(CROI_SYS_CHANNEL_WRITE, UInt64(serverChannel), 0, Sys.address(&message), 8, 0, 0)
        }
        Sys.close(serverChannel)
        Sys.exitThread()
    }

    static func channelCall(resource: UInt32, thread: UInt32) throws(Failure) -> UInt64 {
        var client: UInt32 = 0
        try Sys.check("creating a channel", Sys.call(CROI_SYS_CHANNEL_CREATE, 0, Sys.address(&client),
                                                     Sys.address(&serverChannel)))
        let worker = try Sys.spawn(server, 0)
        let serverProfile = try Sys.profile(resource, priority: Int32(CROI_PRIORITY_DEFAULT), mask: cpus.client)
        let clientProfile = try Sys.profile(resource, deadline: (4_000_000, 10_000_000), mask: cpus.client)
        try Sys.apply(serverProfile, to: worker)
        try Sys.apply(clientProfile, to: thread)
        Sys.close(serverProfile)
        Sys.close(clientProfile)

        var request: UInt64 = 0
        var reply: UInt64 = 0
        var args = croi_channel_call_args_t()
        args.wr_bytes = Sys.address(&request)
        args.wr_num_bytes = 8
        args.rd_bytes = Sys.address(&reply)
        args.rd_num_bytes = 8
        var bytes: UInt32 = 0
        var handles: UInt32 = 0
        func call() -> Int64 {
            Sys.call(CROI_SYS_CHANNEL_CALL, UInt64(client), 0, .max, Sys.address(&args), Sys.address(&bytes),
                     Sys.address(&handles))
        }
        for _ in 0..<100 { try Sys.check("a warm-up call", call()) }
        let batches: UInt64 = 10, perBatch: UInt64 = 200
        try Tracing.start(UInt32(CROI_TRACE_MARK))
        for batch in 0..<batches {
            Tracing.mark(10, batch)
            for _ in 0..<perBatch { try Sys.check("a channel call", call()) }
            Tracing.mark(11, batch)
        }
        Tracing.stop()
        let (records, frequency) = try Tracing.records()
        if profileCalls {
            try Tracing.start(UInt32(CROI_TRACE_SYSCALL | CROI_TRACE_SCHED | CROI_TRACE_IPC | CROI_TRACE_MARK), pages: 256)
            for _ in 0..<200 { try Sys.check("a profiled call", call()) }
            Tracing.stop()
            try profile()
            // Where the time goes: PC samples (10 kHz) over many calls.
            try Tracing.start(UInt32(CROI_TRACE_SAMPLE), pages: 1024, sampleHz: 10_000)
            for _ in 0..<300_000 { try Sys.check("a sampled call", call()) }
            Tracing.stop()
            try samples()
        }
        Sys.close(client)  // the server sees PEER_CLOSED and exits
        Sys.close(worker)
        var means: [UInt64] = []
        for batch in 0..<batches {
            guard let start = records.first(where: { $0.kind == UInt16(CROI_TK_MARK) && $0.a == 10 && $0.b == batch }),
                  let end = records.first(where: { $0.kind == UInt16(CROI_TK_MARK) && $0.a == 11 && $0.b == batch })
            else { throw Failure(what: "finding channel call marks", status: -25) }
            means.append(Tracing.ns(end.time - start.time, frequency) / perBatch)
        }
        means.sort()
        return means[means.count / 2]
    }

    /// Splits the traced calls at each channel_call entry, keeps those
    /// with the most common sequence of events, and prints the median gap
    /// before each event.
    static func profile() throws(Failure) {
        let (records, frequency) = try Tracing.records()
        let callNumber = UInt64(CROI_SYS_CHANNEL_CALL)
        var calls: [[croi_trace_record_t]] = []
        for record in records {
            if record.kind == UInt16(CROI_TK_SYSCALL_ENTER), record.a == callNumber {
                calls.append([record])
            } else if !calls.isEmpty {
                calls[calls.count - 1].append(record)
            }
        }
        guard calls.count > 2 else { throw Failure(what: "finding profiled calls", status: -25) }
        calls.removeLast()  // may be cut short
        func signature(_ call: [croi_trace_record_t]) -> [UInt64] {
            call.map { UInt64($0.kind) << 32 | ($0.kind == UInt16(CROI_TK_SYSCALL_ENTER) || $0.kind == UInt16(CROI_TK_SYSCALL_EXIT) || $0.kind == UInt16(CROI_TK_MARK) ? $0.a : 0) }
        }
        var best: [UInt64] = []
        var bestCount = 0
        for call in calls {
            let shape = signature(call)
            var count = 0
            for other in calls where signature(other) == shape { count += 1 }
            if count > bestCount {
                best = shape
                bestCount = count
            }
        }
        let kept = calls.filter { signature($0) == best }
        print("m2: ipc profile: \(kept.count) of \(calls.count) calls share \(best.count) events (kind, syscall), median gap before each:")
        for i in 0..<best.count {
            var gaps: [UInt64] = []
            for call in kept {
                let previous = i == 0 ? call[call.count - 1].time : call[i - 1].time
                gaps.append(i == 0 ? 0 : Tracing.ns(call[i].time &- previous, frequency))
            }
            gaps.sort()
            let event = kept[0][i]
            let detail = event.kind == UInt16(CROI_TK_SYSCALL_ENTER) || event.kind == UInt16(CROI_TK_SYSCALL_EXIT) || event.kind == UInt16(CROI_TK_MARK) ? " \(event.a)" : ""
            print("m2: ipc profile:   +\(gaps[gaps.count / 2]) ns  kind \(event.kind)\(detail)  thread \(event.thread)")
        }
        var totals: [UInt64] = kept.map { Tracing.ns($0[$0.count - 1].time &- $0[0].time, frequency) }
        totals.sort()
        print("m2: ipc profile: first to last event, median \(totals[totals.count / 2]) ns")
    }

    /// The sampled PCs, most frequent first (kernel ones as image offsets
    /// with bit 63 set: llvm-symbolizer --obj=kernel.elf <link + offset>).
    static func samples() throws(Failure) {
        let (records, _) = try Tracing.records()
        var pcs: [UInt64] = []
        for record in records where record.kind == UInt16(CROI_TK_SAMPLE) && record.cpu == 1 { pcs.append(record.a) }
        pcs.sort()
        var counts: [(UInt64, Int)] = []
        for pc in pcs {
            if let last = counts.last, last.0 == pc { counts[counts.count - 1].1 += 1 } else { counts.append((pc, 1)) }
        }
        counts.sort { $0.1 > $1.1 }
        print("m2: ipc samples: \(pcs.count) on CPU 1, top PCs:")
        for (pc, count) in counts.prefix(40) { print("m2: ipc samples:   \(count) \(String(pc, radix: 16))") }
    }

    // MARK: Timed wake profile (m2.wake_profile=1)

    /// Todhchai's executor (K14n): fair worker threads waiting on one port
    /// with the soonest delayed job's deadline, which time out together.
    nonisolated(unsafe) static var sleepPort: UInt32 = 0
    nonisolated(unsafe) static var sleepBase: UInt64 = 0
    nonisolated(unsafe) static var sleepRounds: UInt64 = 0
    static var sleepGap: UInt64 { 5_000_000 }

    static let sleeper: Sys.ThreadEntry = { index, _ in
        var packet = croi_port_packet_t()
        for round in 0..<sleepRounds {
            let deadline = sleepBase + (round + 1) * sleepGap
            _ = Sys.call(CROI_SYS_PORT_WAIT, UInt64(sleepPort), deadline, Sys.address(&packet))
            let late = Sys.now() &- deadline
            Tracing.mark(30 + index, round << 32 | min(late, 0xFFFF_FFFF))
        }
        Sys.exitThread()
    }

    /// One fair thread, then four, timing out on a port every 5 ms: each
    /// wake's lateness (deadline to the thread back in user space, by the
    /// vDSO clock) and, from the trace, its split into the timer interrupt
    /// arriving late and the kernel's way from that interrupt back to user
    /// space. Printed, not budgets.
    static func wakeProfile(resource: UInt32) throws(Failure) {
        Tracing.resource = resource
        for threads in [UInt64(1), 4] {
            try Sys.check("creating a port", Sys.call(CROI_SYS_PORT_CREATE, 0, Sys.address(&sleepPort)))
            sleepRounds = 100
            sleepBase = Sys.now() + 2_000_000
            try Tracing.start(UInt32(CROI_TRACE_MARK | CROI_TRACE_IRQ | CROI_TRACE_SCHED), pages: 256)
            var workers: [UInt32] = []
            for i in 0..<threads { workers.append(try Sys.spawn(sleeper, i)) }
            for worker in workers {
                var observed: UInt32 = 0
                _ = Sys.call(CROI_SYS_OBJECT_WAIT_ONE, UInt64(worker), UInt64(CROI_SIGNAL_TASK_TERMINATED), .max,
                             Sys.address(&observed))
                Sys.close(worker)
            }
            Tracing.stop()
            Sys.close(sleepPort)
            let (records, frequency) = try Tracing.records()
            var late: [UInt64] = [], irqLate: [UInt64] = [], path: [UInt64] = []
            var first: [UInt64] = Array(repeating: .max, count: Int(sleepRounds))
            var last: [UInt64] = Array(repeating: 0, count: Int(sleepRounds))
            for (i, mark) in records.enumerated() where mark.kind == UInt16(CROI_TK_MARK) && mark.a >= 30 && mark.a < 30 + threads {
                let round = Int(mark.b >> 32), lateness = mark.b & 0xFFFF_FFFF
                late.append(lateness)
                first[round] = min(first[round], lateness)
                last[round] = max(last[round], lateness)
                // The interrupt that woke it: the last IRQ_ENTER on its CPU before.
                var j = i
                while j > 0 {
                    j -= 1
                    let r = records[j]
                    if r.cpu == mark.cpu, r.kind == UInt16(CROI_TK_IRQ_ENTER) {
                        let since = Tracing.ns(mark.time &- r.time, frequency)
                        path.append(since)
                        irqLate.append(lateness > since ? lateness - since : 0)
                        break
                    }
                    if r.cpu != mark.cpu { break }  // rings are per CPU, in order: none before on this one
                }
            }
            // A few wakes in full: every CPU's records from the deadline to
            // the thread's mark.
            var shown = 0
            for mark in records where mark.kind == UInt16(CROI_TK_MARK) && mark.a == 30 && shown < 3 && (mark.b & 0xFFFF_FFFF) > 150_000 {
                shown += 1
                let lateness = mark.b & 0xFFFF_FFFF
                let ticks = lateness * frequency / 1_000_000_000
                let from = mark.time &- ticks
                print("m2: wake profile:   round \(mark.b >> 32), \(lateness) ns late, on CPU \(mark.cpu):")
                var window: [croi_trace_record_t] = []
                for r in records where r.time >= from && r.time <= mark.time { window.append(r) }
                window.sort { $0.time < $1.time }
                for r in window {
                    print("m2: wake profile:     +\(Tracing.ns(r.time &- from, frequency)) ns cpu \(r.cpu) kind \(r.kind) a \(r.a) b \(r.b) thread \(r.thread)")
                }
            }
            func median(_ values: [UInt64]) -> UInt64 { values.isEmpty ? 0 : values.sorted()[values.count / 2] }
            func p99(_ values: [UInt64]) -> UInt64 { values.isEmpty ? 0 : values.sorted()[values.count * 99 / 100] }
            print("m2: wake profile, \(threads) fair thread(s) timing out on a port every 5 ms: late median \(median(late)) ns, p99 \(p99(late)) ns")
            print("m2: wake profile:   interrupt late median \(median(irqLate)) ns, p99 \(p99(irqLate)) ns; interrupt to user median \(median(path)) ns, p99 \(p99(path)) ns (\(path.count) found)")
            if threads > 1 {
                print("m2: wake profile:   first of the \(threads) median \(median(first)) ns, last median \(median(last)) ns")
            }
        }
    }

    // MARK: Port wake from another core

    nonisolated(unsafe) static var wakeEvent: UInt32 = 0
    nonisolated(unsafe) static var readyEvent: UInt32 = 0
    nonisolated(unsafe) static var goEvent: UInt32 = 0
    nonisolated(unsafe) static var wakePort: UInt32 = 0
    static var wakes: UInt64 { 200 }

    static let waiter: Sys.ThreadEntry = { _, _ in
        var packet = croi_port_packet_t()
        Sys.take(goEvent)  // pinned to its CPU first
        for i in 0..<wakes {
            _ = Sys.call(CROI_SYS_OBJECT_WAIT_ASYNC, UInt64(wakeEvent), UInt64(wakePort), i,
                         UInt64(CROI_SIGNAL_SIGNALED), 0)
            Sys.signal(readyEvent, set: UInt32(CROI_SIGNAL_SIGNALED))
            _ = Sys.call(CROI_SYS_PORT_WAIT, UInt64(wakePort), .max, Sys.address(&packet))
            Sys.signal(wakeEvent, clear: UInt32(CROI_SIGNAL_SIGNALED), set: 0)
        }
        Sys.exitThread()
    }

    /// From object_signal's entry on one CPU to port_wait's exit on another
    /// (syscall trace records): median and p99, ns.
    static func portWake(resource: UInt32, thread: UInt32) throws(Failure) -> (UInt64, UInt64) {
        wakeEvent = try Sys.event()
        readyEvent = try Sys.event()
        goEvent = try Sys.event()
        try Sys.check("creating a port", Sys.call(CROI_SYS_PORT_CREATE, 0, Sys.address(&wakePort)))
        let signaler = try Sys.profile(resource, priority: Int32(CROI_PRIORITY_DEFAULT), mask: cpus.client)
        try Sys.apply(signaler, to: thread)  // back to fair, from the call test's deadline
        Sys.close(signaler)
        try Tracing.start(UInt32(CROI_TRACE_SYSCALL))
        let worker = try Sys.spawn(waiter, 0)
        let waiterProfile = try Sys.profile(resource, priority: Int32(CROI_PRIORITY_DEFAULT), mask: cpus.waiter)
        try Sys.apply(waiterProfile, to: worker)
        Sys.close(waiterProfile)
        Sys.signal(goEvent, set: UInt32(CROI_SIGNAL_SIGNALED))
        for _ in 0..<wakes {
            Sys.take(readyEvent)
            _ = Sys.call(CROI_SYS_NANOSLEEP, Sys.now() + 100_000)  // the waiter is blocked by now
            Sys.signal(wakeEvent, set: UInt32(CROI_SIGNAL_SIGNALED))
        }
        var observed: UInt32 = 0
        _ = Sys.call(CROI_SYS_OBJECT_WAIT_ONE, UInt64(worker), UInt64(CROI_SIGNAL_TASK_TERMINATED), .max,
                     Sys.address(&observed))
        Tracing.stop()
        for handle in [worker, wakeEvent, readyEvent, goEvent, wakePort] { Sys.close(handle) }
        let (records, frequency) = try Tracing.records()
        let signals = records.filter {
            $0.kind == UInt16(CROI_TK_SYSCALL_ENTER) && $0.a == CROI_SYS_OBJECT_SIGNAL && $0.b == UInt64(wakeEvent)
                && (1 << UInt64($0.cpu)) == cpus.client
        }
        let returns = records.filter {
            $0.kind == UInt16(CROI_TK_SYSCALL_EXIT) && $0.a == CROI_SYS_PORT_WAIT && (1 << UInt64($0.cpu)) == cpus.waiter
        }
        guard signals.count == Int(wakes), returns.count == Int(wakes) else {
            throw Failure(what: "pairing port wakes", status: Int64(signals.count) << 16 | Int64(returns.count))
        }
        var latencies: [UInt64] = []
        for i in 0..<Int(wakes) where returns[i].time >= signals[i].time {
            latencies.append(Tracing.ns(returns[i].time - signals[i].time, frequency))
        }
        latencies.sort()
        guard !latencies.isEmpty else { throw Failure(what: "measuring port wakes", status: -1) }
        return (latencies[latencies.count / 2], latencies[latencies.count * 99 / 100])
    }

    /// `m2.portwake_profile=1` (K14o): the port wake again, traced, each
    /// wake's records from both CPUs merged in time from the signal's
    /// entry to port_wait's exit; the most common sequence's median gap
    /// before each record.
    nonisolated(unsafe) static var profilePortWake = false

    static func portWakeProfile() throws(Failure) {
        wakeEvent = try Sys.event()
        readyEvent = try Sys.event()
        goEvent = try Sys.event()
        try Sys.check("creating a port", Sys.call(CROI_SYS_PORT_CREATE, 0, Sys.address(&wakePort)))
        try Tracing.start(UInt32(CROI_TRACE_SYSCALL | CROI_TRACE_SCHED | CROI_TRACE_IRQ | CROI_TRACE_IPC | CROI_TRACE_MARK),
                          pages: 256)
        let worker = try Sys.spawn(waiter, 0)
        let waiterProfile = try Sys.profile(Tracing.resource, priority: Int32(CROI_PRIORITY_DEFAULT), mask: cpus.waiter)
        try Sys.apply(waiterProfile, to: worker)
        Sys.close(waiterProfile)
        Sys.signal(goEvent, set: UInt32(CROI_SIGNAL_SIGNALED))
        for _ in 0..<wakes {
            Sys.take(readyEvent)
            _ = Sys.call(CROI_SYS_NANOSLEEP, Sys.now() + 100_000)
            Sys.signal(wakeEvent, set: UInt32(CROI_SIGNAL_SIGNALED))
        }
        var observed: UInt32 = 0
        _ = Sys.call(CROI_SYS_OBJECT_WAIT_ONE, UInt64(worker), UInt64(CROI_SIGNAL_TASK_TERMINATED), .max,
                     Sys.address(&observed))
        Tracing.stop()
        for handle in [worker, wakeEvent, readyEvent, goEvent, wakePort] { Sys.close(handle) }
        var (records, frequency) = try Tracing.records()
        records.sort { $0.time < $1.time }
        var sequences: [[croi_trace_record_t]] = []
        var current: [croi_trace_record_t]? = nil
        for r in records where (1 << UInt64(r.cpu)) & (cpus.client | cpus.waiter) != 0 {
            if r.kind == UInt16(CROI_TK_SYSCALL_ENTER), r.a == CROI_SYS_OBJECT_SIGNAL, r.b == UInt64(wakeEvent),
               (1 << UInt64(r.cpu)) == cpus.client {
                current = [r]
            } else if current != nil {
                current!.append(r)
                if r.kind == UInt16(CROI_TK_SYSCALL_EXIT), r.a == CROI_SYS_PORT_WAIT, (1 << UInt64(r.cpu)) == cpus.waiter {
                    sequences.append(current!)
                    current = nil
                }
            }
        }
        func signature(_ seq: [croi_trace_record_t]) -> [UInt64] {
            seq.map { UInt64($0.cpu) << 48 | UInt64($0.kind) << 32 | ($0.kind == UInt16(CROI_TK_SYSCALL_ENTER) || $0.kind == UInt16(CROI_TK_SYSCALL_EXIT) || $0.kind == UInt16(CROI_TK_MARK) || $0.kind == UInt16(CROI_TK_IRQ_ENTER) ? $0.a : 0) }
        }
        var best: [UInt64] = [], bestCount = 0
        for seq in sequences {
            let shape = signature(seq)
            var count = 0
            for other in sequences where signature(other) == shape { count += 1 }
            if count > bestCount { best = shape; bestCount = count }
        }
        let kept = sequences.filter { signature($0) == best }
        guard !kept.isEmpty else { throw Failure(what: "finding port wakes", status: -25) }
        print("m2: port wake profile: \(kept.count) of \(sequences.count) wakes share \(best.count) records, median gap before each:")
        for i in 0..<best.count {
            var gaps: [UInt64] = []
            for seq in kept { gaps.append(i == 0 ? 0 : Tracing.ns(seq[i].time &- seq[i - 1].time, frequency)) }
            gaps.sort()
            let r = kept[0][i]
            print("m2: port wake profile:   +\(gaps[gaps.count / 2]) ns  cpu \(r.cpu) kind \(r.kind) a \(r.kind == UInt16(CROI_TK_SYSCALL_ENTER) || r.kind == UInt16(CROI_TK_SYSCALL_EXIT) || r.kind == UInt16(CROI_TK_MARK) || r.kind == UInt16(CROI_TK_IRQ_ENTER) ? r.a : 0)")
        }
        var totals = kept.map { Tracing.ns($0[$0.count - 1].time &- $0[0].time, frequency) }
        totals.sort()
        print("m2: port wake profile: signal entry to port_wait exit, median \(totals[totals.count / 2]) ns")
    }

    // MARK: Counter wake from another core (K10a)

    nonisolated(unsafe) static var wakeCounter: UInt32 = 0

    static let counterWaiter: Sys.ThreadEntry = { _, _ in
        Sys.take(goEvent)  // pinned to its CPU first
        for i in 0..<wakes {
            Sys.signal(readyEvent, set: UInt32(CROI_SIGNAL_SIGNALED))
            _ = Sys.call(CROI_SYS_COUNTER_WAIT, UInt64(wakeCounter), i + 1, .max)
        }
        Sys.exitThread()
    }

    /// From counter_add's entry on one CPU to counter_wait's exit on
    /// another, the waiter waiting for the value the add reaches: median
    /// and p99, ns (as port wake).
    static func counterWake(resource: UInt32, thread: UInt32) throws(Failure) -> (UInt64, UInt64) {
        readyEvent = try Sys.event()
        goEvent = try Sys.event()
        try Sys.check("creating a counter", Sys.call(CROI_SYS_COUNTER_CREATE, 0, Sys.address(&wakeCounter)))
        try Tracing.start(UInt32(CROI_TRACE_SYSCALL))
        let worker = try Sys.spawn(counterWaiter, 0)
        let waiterProfile = try Sys.profile(resource, priority: Int32(CROI_PRIORITY_DEFAULT), mask: cpus.waiter)
        try Sys.apply(waiterProfile, to: worker)
        Sys.close(waiterProfile)
        Sys.signal(goEvent, set: UInt32(CROI_SIGNAL_SIGNALED))
        for _ in 0..<wakes {
            Sys.take(readyEvent)
            _ = Sys.call(CROI_SYS_NANOSLEEP, Sys.now() + 100_000)  // the waiter is blocked by now
            _ = Sys.call(CROI_SYS_COUNTER_ADD, UInt64(wakeCounter), 1)
        }
        var observed: UInt32 = 0
        _ = Sys.call(CROI_SYS_OBJECT_WAIT_ONE, UInt64(worker), UInt64(CROI_SIGNAL_TASK_TERMINATED), .max,
                     Sys.address(&observed))
        Tracing.stop()
        for handle in [worker, wakeCounter, readyEvent, goEvent] { Sys.close(handle) }
        let (records, frequency) = try Tracing.records()
        let adds = records.filter {
            $0.kind == UInt16(CROI_TK_SYSCALL_ENTER) && $0.a == CROI_SYS_COUNTER_ADD && (1 << UInt64($0.cpu)) == cpus.client
        }
        let returns = records.filter {
            $0.kind == UInt16(CROI_TK_SYSCALL_EXIT) && $0.a == CROI_SYS_COUNTER_WAIT
                && (1 << UInt64($0.cpu)) == cpus.waiter
        }
        guard adds.count == Int(wakes), returns.count == Int(wakes) else {
            throw Failure(what: "pairing counter wakes", status: Int64(adds.count) << 16 | Int64(returns.count))
        }
        var latencies: [UInt64] = []
        for i in 0..<Int(wakes) where returns[i].time >= adds[i].time {
            latencies.append(Tracing.ns(returns[i].time - adds[i].time, frequency))
        }
        latencies.sort()
        guard !latencies.isEmpty else { throw Failure(what: "measuring counter wakes", status: -1) }
        return (latencies[latencies.count / 2], latencies[latencies.count * 99 / 100])
    }

    // MARK: Wake error, real-time intent

    /// A deadline thread sleeping to absolute deadlines: how late it runs,
    /// by the clock the deadlines come from, in a mark it records on
    /// waking. (Trace times turned into ns from an anchor mark disagreed
    /// with the clock by up to 170 µs under KVM.) p99, ns.
    static func wakeError(resource: UInt32, thread: UInt32) throws(Failure) -> UInt64 {
        let profile = try Sys.profile(resource, deadline: (1_000_000, 10_000_000), mask: cpus.sleeper)
        try Sys.apply(profile, to: thread)
        Sys.close(profile)
        let n: UInt64 = 200
        try Tracing.start(UInt32(CROI_TRACE_MARK))
        for _ in 0..<n {
            let deadline = Sys.now() + 500_000
            _ = Sys.call(CROI_SYS_NANOSLEEP, deadline)
            Tracing.mark(21, Sys.now() - deadline)
        }
        Tracing.stop()
        let (records, _) = try Tracing.records()
        var errors: [UInt64] = []
        for mark in records where mark.kind == UInt16(CROI_TK_MARK) && mark.a == 21 { errors.append(mark.b) }
        guard errors.count == Int(n) else { throw Failure(what: "finding wake marks", status: Int64(errors.count)) }
        errors.sort()
        return errors[errors.count * 99 / 100]
    }

    // MARK: Display timeline wake (K10b)

    /// A synthetic 1 ms timeline: the deadline thread (wake error's, on its
    /// own CPU, as a compositor's latch thread) waits for each next vblank;
    /// how late it runs after the vblank's time, from the timeline's page.
    /// Median and p99, ns.
    static func timelineWake(resource: UInt32) throws(Failure) -> (UInt64, UInt64) {
        var timeline: UInt32 = 0
        var pageVmo: UInt32 = 0
        var at: UInt64 = 0
        try Sys.check("creating a timeline", Sys.call(CROI_SYS_TIMELINE_CREATE, UInt64(resource),
                                                      UInt64(CROI_TIMELINE_SYNTHETIC), 1_000_000,
                                                      Sys.address(&timeline)))
        try Sys.check("getting its page", Sys.call(CROI_SYS_TIMELINE_GET_PAGE, UInt64(timeline), Sys.address(&pageVmo)))
        try Sys.check("mapping its page", Sys.call(CROI_SYS_VMAR_MAP,
                                                   UInt64(croi_vmar_root_self()) | UInt64(CROI_VM_PERM_READ) << 32,
                                                   0, UInt64(pageVmo), 0, 4096, Sys.address(&at)))
        let page = unsafe UnsafePointer<croi_timeline_page_t>(bitPattern: UInt(at))!
        var latencies: [UInt64] = []
        for _ in 0..<200 {
            var value: Int64 = 0
            _ = Sys.call(CROI_SYS_COUNTER_READ, UInt64(timeline), Sys.address(&value))
            let target = value + 1
            _ = Sys.call(CROI_SYS_COUNTER_WAIT, UInt64(timeline), UInt64(bitPattern: target), .max)
            let woke = Sys.now()
            let due = unsafe page.pointee.base_time_ns + UInt64(target - page.pointee.base_count) * page.pointee.period_ns
            latencies.append(woke >= due ? woke - due : 0)
        }
        _ = Sys.call(CROI_SYS_VMAR_UNMAP, UInt64(croi_vmar_root_self()), at, 4096)
        Sys.close(pageVmo)
        Sys.close(timeline)
        latencies.sort()
        return (latencies[latencies.count / 2], latencies[latencies.count * 99 / 100])
    }
}
