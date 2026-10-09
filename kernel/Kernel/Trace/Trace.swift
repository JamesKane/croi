import CKernel
import PageTables
import Synchronization

/// The kernel trace (roadmap "Trace", the core of requirement 18): one
/// ring per CPU of fixed 32-byte records (include/trace.h), each written
/// only by its own CPU with interrupts masked, so no lock.
///
/// A probe is `Trace.event(category, kind, a, b)`: inlined, it costs one
/// relaxed load of the category mask and a branch when the category is
/// off, and evaluates its arguments only when it is on.
///
/// Stopping needs no IPI (ADR-0049): a writer sets its CPU's
/// `traceWriting` flag and then re-reads the mask; `stop` clears the mask
/// and then waits until it has seen every flag clear. Both sides use
/// sequentially consistent accesses, so a writer either sees the mask
/// clear or is waited for.
///
/// Each CPU's ring is a contiguous VMO, mapped into the kernel to write;
/// K5 hands the VMOs out through a capability, and user space maps them
/// read-only (the layout is the ABI).
enum Trace {
    nonisolated(unsafe) private static var session: UInt64 = 0
    nonisolated(unsafe) private static var pagesPerCpu = 0
    nonisolated(unsafe) private static var ringVmos = InlineArray<64, UInt64>(repeating: 0)

    /// Records an event if `category` is on.
    @inline(__always)
    static func event(_ category: UInt32, _ kind: UInt16, _ a: @autoclosure () -> UInt64 = 0,
                      _ b: @autoclosure () -> UInt64 = 0) {
        if croi_trace_categories() & category != 0 {
            write(category, kind, a(), b())
        }
    }

    @inline(never)
    static func write(_ category: UInt32, _ kind: UInt16, _ a: UInt64, _ b: UInt64) {
        let saved = arch_interrupts_save()
        let address = arch_percpu()
        guard address != 0 else {
            arch_interrupts_restore(saved)
            return
        }
        let percpu = unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(address))!
        unsafe percpu.pointee.traceWriting.store(true, ordering: .sequentiallyConsistent)
        let ringAddress = unsafe percpu.pointee.traceRing
        if croi_trace_categories_ordered() & category != 0, ringAddress != 0 {
            let ring = unsafe UnsafeMutablePointer<croi_trace_ring_t>(bitPattern: UInt(ringAddress))!
            let time = arch_counter_read()
            let head = unsafe ring.pointee.head
            if unsafe ring.pointee.mode == UInt32(CROI_TRACE_ONESHOT), unsafe head >= ring.pointee.capacity {
                if unsafe ring.pointee.drops == 0 { unsafe ring.pointee.first_drop = time }
                unsafe ring.pointee.drops += 1
                unsafe ring.pointee.last_drop = time
            } else {
                let slot = unsafe head & (ring.pointee.capacity - 1)  // a power of two
                let records = unsafe UnsafeMutableRawPointer(ring) + Int(KernelLayout.pageSize)
                let record = unsafe (records + Int(slot) * MemoryLayout<croi_trace_record_t>.stride)
                    .assumingMemoryBound(to: croi_trace_record_t.self)
                unsafe record.pointee = croi_trace_record_t(
                    time: time, kind: kind, cpu: UInt16(truncatingIfNeeded: percpu.pointee.number),
                    thread: percpu.pointee.traceThread, a: a, b: b)
                atomicMemoryFence(ordering: .releasing)  // the record before the head that publishes it
                unsafe ring.pointee.head = head + 1
            }
        }
        unsafe percpu.pointee.traceWriting.store(false, ordering: .releasing)
        arch_interrupts_restore(saved)
    }

    // MARK: Control

    /// Starts recording `categories` into rings of `pages` pages of
    /// records per CPU (128 records a page; rounded up to a power of two,
    /// so the writer masks instead of dividing), discarding what was there.
    static func start(categories: UInt32, pages requested: Int, mode: UInt32) throws(VmError) {
        stop()
        var pages = 1
        while pages < requested { pages *= 2 }
        if pages != pagesPerCpu {
            release()
            for cpu in 0..<Smp.count {
                let size = UInt64(1 + pages) * KernelLayout.pageSize
                let vmo = try Vmo(contiguous: size)
                guard case .contiguous(let base) = vmo.record.pointee.kind else { panic("trace: ring VMO") }
                let ring = try kernelAspace.mapPhysical(base, size: size, MapAttributes(writable: true, global: true))
                ringVmos[cpu] = vmo.keep().address
                unsafe percpu(cpu).pointee.traceRing = ring
            }
            pagesPerCpu = pages
        }
        session += 1
        for cpu in 0..<Smp.count {
            unsafe ring(cpu)!.pointee = croi_trace_ring_t(
                head: 0, capacity: UInt64(pages) * KernelLayout.pageSize / UInt64(MemoryLayout<croi_trace_record_t>.stride),
                drops: 0, first_drop: 0, last_drop: 0, frequency: Clock.frequency, session: session,
                mode: mode, cpu: UInt32(cpu))
        }
        croi_trace_set_categories(categories)
    }

    /// Stops recording; returns once no CPU is mid-record.
    static func stop() {
        croi_trace_set_categories(0)
        for cpu in 0..<Smp.count {
            while unsafe percpu(cpu).pointee.traceWriting.load(ordering: .sequentiallyConsistent) {
                arch_spin_pause()
            }
        }
    }

    /// Stops and frees the rings.
    static func release() {
        stop()
        guard pagesPerCpu > 0 else { return }
        for cpu in 0..<Smp.count {
            let ring = unsafe percpu(cpu).pointee.traceRing
            unsafe percpu(cpu).pointee.traceRing = 0
            do throws(VmError) {
                try kernelAspace.free(ring)
            } catch {
                panic("trace: freeing an unknown ring")
            }
            VmoPointer(address: ringVmos[cpu]).release()
            ringVmos[cpu] = 0
        }
        pagesPerCpu = 0
    }

    static var categories: UInt32 { croi_trace_categories() }

    /// A CPU's ring header (stop first for a stable view).
    static func header(_ cpu: Int) -> croi_trace_ring_t? {
        unsafe ring(cpu)?.pointee
    }

    /// The records a CPU's ring holds, oldest first.
    static func forEachRecord(_ cpu: Int, _ body: (croi_trace_record_t) -> Void) {
        guard let ring = unsafe ring(cpu) else { return }
        let head = unsafe ring.pointee.head, capacity = unsafe ring.pointee.capacity
        let first = head > capacity ? head - capacity : 0
        let records = unsafe UnsafeRawPointer(ring) + Int(KernelLayout.pageSize)
        for index in first..<head {
            let slot = index & (capacity - 1)
            body(unsafe (records + Int(slot) * MemoryLayout<croi_trace_record_t>.stride)
                .load(as: croi_trace_record_t.self))
        }
    }

    private static func percpu(_ cpu: Int) -> UnsafeMutablePointer<PerCpu> {
        unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(Smp.records[cpu]))!
    }

    private static func ring(_ cpu: Int) -> UnsafeMutablePointer<croi_trace_ring_t>? {
        let address = unsafe percpu(cpu).pointee.traceRing
        guard address != 0 else { return nil }
        return unsafe UnsafeMutablePointer<croi_trace_ring_t>(bitPattern: UInt(address))
    }
}
