import CKernel
import Fmt
import Synchronization

/// Boot self-test for K5c: VMO objects and their mapping rights, resources
/// (root mints; the tracing resource gates trace_configure), and the trace
/// rings as read-only VMOs mapped into an address space. Panics on failure.
enum ResourceSelfTest {
    nonisolated(unsafe) static var aspace: UInt64 = 0
    nonisolated(unsafe) static var ringAt: UInt64 = 0
    static let frequencySeen = Atomic<UInt64>(0)

    static func run(_ console: Uart) {
        let liveBefore = Objects.live.load(ordering: .relaxed)
        var rings = 0
        do throws(Status) {
            let table = HandleTable()
            Resources.root.retain()
            let root = try table.add(Resources.root, rights: ResourceObject.defaultRights)
            let tracing = try Resources.create(table, parent: root, kind: .system(base: ResourceObject.tracingBase))
            let other = try Resources.create(table, parent: root, kind: .system(base: 1))
            let event = try table.add(try EventObject.create(), rights: EventObject.defaultRights)
            guard status({ () throws(Status) in _ = try Resources.create(table, parent: tracing, kind: .root) }) == .accessDenied,
                  status({ () throws(Status) in try TraceControl.stop(table, event) }) == .wrongType,
                  status({ () throws(Status) in try TraceControl.stop(table, other) }) == .accessDenied else {
                panic("resource self-test: trace gate")
            }

            // Start, mark, stop; the rings come back read-only.
            try TraceControl.start(table, tracing, categories: CROI_TRACE_MARK, pages: 1, mode: UInt32(CROI_TRACE_ONESHOT))
            try TraceControl.mark(table, tracing, 0x1234, 0x5678)
            try TraceControl.stop(table, tracing)
            var marked = false
            for cpu in 0..<Smp.count {
                Trace.forEachRecord(cpu) { r in if r.kind == UInt16(CROI_TK_MARK), r.a == 0x1234, r.b == 0x5678 { marked = true } }
            }
            guard marked else { panic("resource self-test: mark not recorded") }
            var handles = try TraceControl.rings(table, tracing)
            rings = handles.count
            guard rings == Smp.count, try !table.rights(of: handles[0]).contains(.write),
                  status({ () throws(Status) in _ = try VmoObject.forMapping(table, handles[0], [.read, .write]) }) == .accessDenied else {
                panic("resource self-test: rings writable")
            }

            // Map CPU 0's ring read-only and read its header from "user".
            let vmo = try VmoObject.forMapping(table, handles[0], [.read])
            do throws(VmError) {
                let space = try UserAspace()
                aspace = space.record.address
                let borrowed = Vmo.borrowing(vmo)
                ringAt = try space.map(borrowed, size: borrowed.size, rights: [.read])
                _ = borrowed.keep()
                guard run(readHeader) == 0, frequencySeen.load(ordering: .relaxed) == Clock.frequency else {
                    panic("resource self-test: ring not readable through a mapping")
                }
            } catch {
                panic("resource self-test: out of memory")
            }
            vmo.release()
            try TraceControl.rewind(table, tracing)
            guard Trace.header(0)?.head == 0 else { panic("resource self-test: rewind") }
            while let handle = handles.popLast() { try table.close(handle) }
            Trace.release()

            // vmo_create and mapping rights.
            let made = try table.add(try VmoObject.create(size: 4 * KernelLayout.pageSize), rights: VmoObject.defaultRights)
            VmoObject.forMappingReleasing(table, made, [.read, .write])
            let readOnly = try table.replace(made, rights: [.basic, .read, .map])
            guard status({ () throws(Status) in _ = try VmoObject.forMapping(table, readOnly, [.read, .write]) }) == .accessDenied,
                  status({ () throws(Status) in _ = try VmoObject.forMapping(table, readOnly, [.read, .execute]) }) == .accessDenied else {
                panic("resource self-test: VMO rights not enforced")
            }
            VmoObject.forMappingReleasing(table, readOnly, [.read])
        } catch {
            panic("resource self-test: unexpected status")
        }
        guard Objects.live.load(ordering: .relaxed) == liveBefore else { panic("resource self-test: objects leaked") }
        console.write("  rsrc:   root mints, tracing resource gates trace_configure (start, mark, stop, rewind), ")
        console.write(decimal: UInt64(rings))
        console.write(" ring VMOs read-only and mapped, VMO mapping rights ok\n")
    }

    private static let readHeader: Thread.Entry = { _ in
        Scheduler.setAspace(UserAspacePointer(address: aspace))
        defer { Scheduler.setAspace(nil) }
        var value: UInt64 = 0
        guard unsafe arch_user_load_u64(ringAt + 40, &value) == 0 else { return 1 }  // croi_trace_ring_t.frequency
        frequencySeen.store(value, ordering: .relaxed)
        return arch_user_store_u64(ringAt, 0) == -1 ? 0 : 2  // read-only
    }

    private static func run(_ entry: Thread.Entry) -> Int {
        do throws(VmError) {
            return try Scheduler.spawn("rsrc", entry, 0).join()
        } catch {
            panic("resource self-test: spawn failed")
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
}
