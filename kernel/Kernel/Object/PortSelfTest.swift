import CKernel
import Fmt
import Synchronization

/// Boot self-test for K5b: ports (user packets, waiting, many CPUs),
/// object_wait_async (level, edge, one-shot, timestamp), port_cancel,
/// cancel on close, and the kernel packet sources (ext 3 overruns, ext 6
/// pressure). Panics on failure.
enum PortSelfTest {
    nonisolated(unsafe) static var tableAddress: UInt64 = 0
    nonisolated(unsafe) static var portHandle: UInt32 = 0
    static let received = Atomic<UInt64>(0)  // bit per packet number
    static let receivedCount = Atomic<Int>(0)
    static var ms: UInt64 { 1_000_000 }

    static func run(_ console: Uart) {
        let liveBefore = Objects.live.load(ordering: .relaxed)
        var overrunPackets = 0
        var overruns: UInt64 = 0
        do throws(Status) {
            let table = HandleTable()
            tableAddress = table.address
            let port = try table.add(try Ports.create(), rights: PortObject.defaultRights)
            portHandle = port

            // User packets, FIFO; an empty port times out.
            for i in 0..<UInt64(3) {
                var packet = PortPacket(key: 100 + i)
                packet.payload[0] = i
                try Ports.queue(table, port, packet)
            }
            for i in 0..<UInt64(3) {
                let packet = try Ports.wait(table, port, deadline: Clock.now() + ms)
                guard packet.key == 100 + i, packet.type == PortPacket.user, packet.payload[0] == i else {
                    panic("port self-test: user packets out of order")
                }
            }
            guard status({ () throws(Status) in _ = try Ports.wait(table, port, deadline: Clock.now() + 2 * ms) }) == .timedOut else {
                panic("port self-test: empty port didn't time out")
            }

            // Async waits: level (fires at once), one-shot, edge, timestamp.
            let event = try table.add(try EventObject.create(), rights: EventObject.defaultRights)
            let signal = try table.get(event, rights: .signal)
            try ObjectSignal.signal(signal, clear: 0, set: Signals.signaled)
            try Observers.waitAsync(table, event, port: port, key: 7, signals: Signals.signaled, options: 0)
            var packet = try Ports.wait(table, port, deadline: Clock.now() + ms)
            guard packet.key == 7, packet.type == PortPacket.signalOne, packet.trigger == Signals.signaled,
                  packet.observed & Signals.signaled != 0 else { panic("port self-test: level async wait") }
            try Observers.waitAsync(table, event, port: port, key: 8, signals: Signals.signaled,
                                    options: Observers.edge | Observers.timestamp)
            guard status({ () throws(Status) in _ = try Ports.wait(table, port, deadline: Clock.now() + 2 * ms) }) == .timedOut else {
                panic("port self-test: edge wait fired on a level")
            }
            try ObjectSignal.signal(signal, clear: Signals.signaled, set: 0)
            let before = Clock.now()
            try ObjectSignal.signal(signal, clear: 0, set: Signals.signaled)
            packet = try Ports.wait(table, port, deadline: Clock.now() + ms)
            guard packet.key == 8, packet.payload[2] >= before else { panic("port self-test: edge or timestamp") }
            try ObjectSignal.signal(signal, clear: Signals.signaled, set: 0)
            try ObjectSignal.signal(signal, clear: 0, set: Signals.signaled)
            guard status({ () throws(Status) in _ = try Ports.wait(table, port, deadline: Clock.now() + 2 * ms) }) == .timedOut else {
                panic("port self-test: a one-shot wait fired twice")
            }

            // port_cancel drops a pending wait and a queued packet; closing
            // the handle drops its waits.
            try ObjectSignal.signal(signal, clear: Signals.signaled, set: 0)
            try Observers.waitAsync(table, event, port: port, key: 9, signals: Signals.signaled, options: 0)
            try Observers.waitAsync(table, event, port: port, key: 10, signals: 1 << 24, options: 0)
            try ObjectSignal.signal(signal, clear: 0, set: 1 << 24)  // queues key 10
            try Ports.cancel(table, port: port, source: event, key: 9)
            try Ports.cancel(table, port: port, source: event, key: 10)
            try ObjectSignal.signal(signal, clear: 0, set: Signals.signaled)
            guard status({ () throws(Status) in _ = try Ports.wait(table, port, deadline: Clock.now() + 2 * ms) }) == .timedOut else {
                panic("port self-test: port_cancel left a packet")
            }
            let dup = try table.duplicate(event, rights: .sameRights)
            try ObjectSignal.signal(signal, clear: Signals.signaled, set: 0)
            try Observers.waitAsync(table, dup, port: port, key: 11, signals: Signals.signaled, options: 0)
            try table.close(dup)
            try ObjectSignal.signal(signal, clear: 0, set: Signals.signaled)
            guard status({ () throws(Status) in _ = try Ports.wait(table, port, deadline: Clock.now() + 2 * ms) }) == .timedOut else {
                panic("port self-test: closed handle's wait still fired")
            }

            // Many CPUs: 4 receivers, 48 packets from 3 senders, each once.
            received.store(0, ordering: .relaxed)
            receivedCount.store(0, ordering: .relaxed)
            var handles = UniqueArray<ThreadHandle>(capacity: 7)
            for cpu in 0..<4 { handles.append(spawn(cpu % Smp.count, receive, 0)) }
            for sender in 0..<UInt64(3) { handles.append(spawn(Int(sender) % Smp.count, send, sender)) }
            while let handle = handles.popLast() {
                guard handle.join() == 0 else { panic("port self-test: a thread failed") }
            }
            guard receivedCount.load(ordering: .relaxed) == 48, received.load(ordering: .relaxed) == (1 << 48) - 1 else {
                panic("port self-test: packets lost or duplicated")
            }

            // Ext 3: a reservation that overruns reports to the port.
            let cpu = Smp.count - 1
            let context = try admit(cpu)
            try context.bindOverrunPort(try table.get(port), key: 0x0E3)
            let hog = spawnContext(context.record)
            _ = hog.join()
            var counted: UInt64 = 0
            while let p = try? Ports.wait(table, port, deadline: Clock.now() + ms) {
                guard p.type == PortPacket.budgetOverrun, p.key == 0x0E3 else { panic("port self-test: overrun packet") }
                overrunPackets += 1
                counted += p.count
            }
            guard overrunPackets > 0, counted == context.overruns else { panic("port self-test: overruns miscounted") }
            overruns = counted
            _ = consume context

            // Ext 6: memory pressure reports to the port.
            let account = MemoryAccount(limit: 8 * KernelLayout.pageSize, pressurePercent: 50)
            try account.bindPressurePort(try table.get(port), key: 0x0E6)
            do throws(VmError) {
                let vmo = try Vmo(anonymous: 8 * KernelLayout.pageSize, account: account.record)
                try vmo.commit(offset: 0, size: 6 * KernelLayout.pageSize)
            } catch {
                panic("port self-test: out of memory")
            }
            packet = try Ports.wait(table, port, deadline: Clock.now() + ms)
            guard packet.type == PortPacket.memoryPressure, packet.key == 0x0E6,
                  packet.payload[1] == 4 * KernelLayout.pageSize else { panic("port self-test: pressure packet") }
        } catch {
            panic("port self-test: unexpected status")
        }
        guard Objects.live.load(ordering: .relaxed) == liveBefore else { panic("port self-test: objects leaked") }
        console.write("  port:   user packets, async waits (level, edge, one-shot, timestamp), cancel, ")
        console.write("48 packets across 4 CPUs once each, ")
        console.write(decimal: overruns)
        console.write(" overruns in ")
        console.write(decimal: UInt64(overrunPackets))
        console.write(" coalesced packet(s) (ext 3), pressure packet (ext 6) ok\n")
    }

    private static func admit(_ cpu: Int) throws(Status) -> SchedContext {
        do throws(AdmissionRefusal) {
            return try SchedContext(deadline: DeadlineParams(capacity: 2 * ms, period: 10 * ms),
                                    affinity: 1 << UInt64(cpu))
        } catch {
            throw .noResources
        }
    }

    private static func status(_ body: () throws(Status) -> Void) -> Status? {
        do throws(Status) {
            try body()
            return nil
        } catch {
            return error
        }
    }

    private static let receive: Thread.Entry = { _ in
        do throws(Status) {
            return try HandleTable.withBorrowed(tableAddress) { (table: borrowing HandleTable) throws(Status) -> Int in
                while receivedCount.load(ordering: .relaxed) < 48 {
                    guard let packet = try? Ports.wait(table, portHandle, deadline: Clock.now() + 20 * ms) else { continue }
                    let bit: UInt64 = 1 << packet.payload[0]
                    guard received.bitwiseOr(bit, ordering: .relaxed).oldValue & bit == 0 else { return 1 }
                    receivedCount.add(1, ordering: .relaxed)
                }
                return 0
            }
        } catch {
            return 2
        }
    }

    private static let send: Thread.Entry = { sender in
        do throws(Status) {
            try HandleTable.withBorrowed(tableAddress) { (table: borrowing HandleTable) throws(Status) in
                for i in 0..<UInt64(16) {
                    var packet = PortPacket(key: sender)
                    packet.payload[0] = sender * 16 + i
                    try Ports.queue(table, portHandle, packet)
                }
            }
            return 0
        } catch {
            return 1
        }
    }

    private static let hogFor: Thread.Entry = { _ in
        let until = Clock.now() + 35 * 1_000_000
        while Clock.now() < until { arch_spin_pause() }
        return 0
    }

    private static func spawn(_ cpu: Int, _ entry: Thread.Entry, _ argument: UInt64) -> ThreadHandle {
        do throws(VmError) {
            return try Scheduler.spawn("port", cpu: cpu, entry, argument)
        } catch {
            panic("port self-test: spawn failed")
        }
    }

    private static func spawnContext(_ context: SchedContextPointer) -> ThreadHandle {
        do throws(VmError) {
            return try Scheduler.spawn("hog", context: context, hogFor, 0)
        } catch {
            panic("port self-test: spawn failed")
        }
    }
}
