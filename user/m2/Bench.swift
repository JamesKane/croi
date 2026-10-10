import CroiRuntime

/// A trace session from user space (trace_configure with the root
/// resource): categories on, marks, then every CPU's ring read back
/// through its VMO.
enum Tracing {
    nonisolated(unsafe) static var resource: UInt32 = 0

    static func start(_ categories: UInt32) throws(Failure) {
        try Sys.check("starting the trace", Sys.call(CROI_SYS_TRACE_CONFIGURE, UInt64(resource), CROI_TRACE_OP_START,
                                                     UInt64(categories), 64, UInt64(CROI_TRACE_ONESHOT), 0))
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
        var wakeErrorP99: UInt64 = 0     // ns
    }

    static var cpus: (client: UInt64, waiter: UInt64, sleeper: UInt64) { (1 << 1, 1 << 2, 1 << 3) }

    static func run(resource: UInt32, thread: UInt32) throws(Failure) -> Results {
        Tracing.resource = resource
        var results = Results()
        results.nullSyscall = try nullSyscall()
        results.channelCall = try channelCall(resource: resource, thread: thread)
        (results.portWakeMedian, results.portWakeP99) = try portWake(resource: resource, thread: thread)
        results.wakeErrorP99 = try wakeError(resource: resource, thread: thread)
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
        Sys.close(client)  // the server sees PEER_CLOSED and exits
        Sys.close(worker)
        let (records, frequency) = try Tracing.records()
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
}
