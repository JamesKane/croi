import CKernel
import Fmt
import Synchronization

/// Boot self-test for K5a: handles and rights, koids and lifetimes, event
/// signals, object_wait_one/many with deadlines, wakeups and cancellation.
/// Panics on failure.
enum ObjectSelfTest {
    nonisolated(unsafe) static var tableAddress: UInt64 = 0
    nonisolated(unsafe) static var events = InlineArray<3, UInt32>(repeating: 0)
    static let woke = Atomic<Int>(0)
    static let waiting = Atomic<Int>(0)
    static var ms: UInt64 { 1_000_000 }

    static func run(_ console: Uart) {
        let liveBefore = Objects.live.load(ordering: .relaxed)
        do throws(Status) {
            let table = HandleTable()
            tableAddress = table.address
            let event = try table.add(try EventObject.create(), rights: EventObject.defaultRights)

            // Errors in Zircon's order: bad handle, wrong type, access denied.
            guard status({ () throws(Status) in _ = try table.get(event, type: .port) }) == .wrongType,
                  status({ () throws(Status) in _ = try table.get(event, rights: .write) }) == .accessDenied,
                  status({ () throws(Status) in _ = try table.get(0x7FF) }) == .badHandle,
                  status({ () throws(Status) in _ = try table.get(event &+ 4) }) == .badHandle else {
                panic("object self-test: handle errors")
            }
            // Duplicate (subset), replace (old gone), stale handles.
            let readOnly = try table.duplicate(event, rights: [.wait, .inspect, .transfer])
            guard try table.rights(of: readOnly) == [.wait, .inspect, .transfer],
                  status({ () throws(Status) in _ = try table.duplicate(readOnly, rights: .sameRights) }) == .accessDenied,
                  status({ () throws(Status) in _ = try table.duplicate(event, rights: [.write]) }) == .invalidArgs else {
                panic("object self-test: duplicate")
            }
            let replaced = try table.replace(readOnly, rights: [.wait])
            guard status({ () throws(Status) in _ = try table.get(readOnly) }) == .badHandle else { panic("object self-test: replace") }
            try table.close(replaced)
            let reused = try table.add(try EventObject.create(), rights: EventObject.defaultRights)
            guard reused != replaced, status({ () throws(Status) in _ = try table.get(replaced) }) == .badHandle else {
                panic("object self-test: stale handle accepted")
            }
            let first = try table.get(event).koid, second = try table.get(reused).koid
            guard second > first, first >= 1024 else { panic("object self-test: koids") }

            // Signals: rights and allowed bits.
            let ref = try table.get(event, rights: .signal)
            guard status({ () throws(Status) in try ObjectSignal.signal(ref, clear: 0, set: 1 << 0) }) == .invalidArgs else {
                panic("object self-test: signal bits")
            }
            try ObjectSignal.signal(ref, clear: 0, set: Signals.user & (1 << 24))
            var observed: UInt32 = 0
            try ObjectWait.one(table, event, signals: 1 << 24, deadline: Clock.now() + ms, observed: &observed)
            guard observed & (1 << 24) != 0 else { panic("object self-test: already signaled") }
            try ObjectSignal.signal(ref, clear: Signals.user, set: 0)

            // A deadline passes.
            let start = Clock.now()
            guard status({ () throws(Status) in
                try ObjectWait.one(table, event, signals: Signals.signaled, deadline: start + 5 * ms, observed: &observed)
            }) == .timedOut, Clock.now() - start >= 5 * ms else { panic("object self-test: timeout") }

            // Woken from another CPU; then many waiters on one event.
            events[0] = event
            events[1] = try table.add(try EventObject.create(), rights: EventObject.defaultRights)
            events[2] = try table.add(try EventObject.create(), rights: EventObject.defaultRights)
            let waiter = spawn(Smp.count - 1, waitMany)
            waitUntil { waiting.load(ordering: .relaxed) == 1 }
            try ObjectSignal.signal(try table.get(events[1], rights: .signal), clear: 0, set: Signals.signaled)
            guard waiter.join() == 0 else { panic("object self-test: wait_many") }

            woke.store(0, ordering: .relaxed)
            waiting.store(0, ordering: .relaxed)
            var handles = UniqueArray<ThreadHandle>(capacity: 8)
            for i in 0..<8 { handles.append(spawn(i % Smp.count, waitOne)) }
            waitUntil { waiting.load(ordering: .relaxed) == 8 }
            try ObjectSignal.signal(try table.get(events[2], rights: .signal), clear: 0, set: Signals.signaled)
            while let handle = handles.popLast() { _ = handle.join() }
            guard woke.load(ordering: .relaxed) == 8 else { panic("object self-test: broadcast wake") }

            // Closing the handle cancels a wait through it.
            let doomed = try table.duplicate(event, rights: .sameRights)
            events[0] = doomed
            waiting.store(0, ordering: .relaxed)
            let canceled = spawn(Smp.count - 1, waitCanceled)
            waitUntil { waiting.load(ordering: .relaxed) == 1 }
            Scheduler.sleep(until: Clock.now() + ms)  // let it block
            try table.close(doomed)
            guard canceled.join() == 0 else { panic("object self-test: close didn't cancel the wait") }
        } catch {
            panic("object self-test: unexpected status")
        }
        guard Objects.live.load(ordering: .relaxed) == liveBefore else { panic("object self-test: objects leaked") }
        console.write("  object: handles (rights, generations, duplicate, replace), koids, signals, ")
        console.write("wait_one/many with deadlines, cross-CPU and broadcast wakes, cancel on close ok\n")
    }

    private static func status(_ body: () throws(Status) -> Void) -> Status? {
        do throws(Status) {
            try body()
            return nil
        } catch {
            return error
        }
    }

    private static func waitUntil(_ condition: () -> Bool) {
        let giveUp = Clock.now() + 2000 * ms
        while !condition() {
            guard Clock.now() < giveUp else { panic("object self-test: timed out waiting") }
            Scheduler.sleep(until: Clock.now() + ms / 4)
        }
    }

    /// A borrowed view of the test's table (it outlives the threads).
    private static func withTable<R>(_ body: (borrowing HandleTable) throws(Status) -> R) throws(Status) -> R {
        try HandleTable.withBorrowed(tableAddress, body)
    }

    private static let waitMany: Thread.Entry = { _ in
        do throws(Status) {
            return try withTable { (table: borrowing HandleTable) throws(Status) -> Int in
                var items = InlineArray<3, ObjectWait.WaitItem>(repeating: ObjectWait.WaitItem(handle: 0, waitFor: Signals.signaled))
                for i in 0..<3 { items[i].handle = events[i] }
                var span = items.mutableSpan
                waiting.store(1, ordering: .relaxed)
                try ObjectWait.many(table, &span, deadline: Clock.now() + 2000 * ms)
                return items[1].pending & Signals.signaled != 0 && items[0].pending & Signals.signaled == 0 ? 0 : 1
            }
        } catch {
            return 2
        }
    }

    private static let waitOne: Thread.Entry = { _ in
        do throws(Status) {
            try withTable { (table: borrowing HandleTable) throws(Status) in
                var observed: UInt32 = 0
                waiting.add(1, ordering: .relaxed)
                try ObjectWait.one(table, events[2], signals: Signals.signaled, deadline: Clock.now() + 2000 * ms,
                                   observed: &observed)
                if observed & Signals.signaled != 0 { woke.add(1, ordering: .relaxed) }
            }
        } catch {}
        return 0
    }

    private static let waitCanceled: Thread.Entry = { _ in
        do throws(Status) {
            return try withTable { (table: borrowing HandleTable) throws(Status) -> Int in
                var observed: UInt32 = 0
                waiting.store(1, ordering: .relaxed)
                do throws(Status) {
                    try ObjectWait.one(table, events[0], signals: 1 << 30, deadline: Clock.now() + 2000 * ms,
                                       observed: &observed)
                    return 1
                } catch {
                    return error == .canceled && observed & Signals.handleClosed != 0 ? 0 : 2
                }
            }
        } catch {
            return 3
        }
    }

    private static func spawn(_ cpu: Int, _ entry: Thread.Entry) -> ThreadHandle {
        do throws(VmError) {
            return try Scheduler.spawn("object", cpu: cpu, entry, 0)
        } catch {
            panic("object self-test: spawn failed")
        }
    }
}
