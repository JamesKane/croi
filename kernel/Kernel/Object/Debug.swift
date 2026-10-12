import CKernel
import PageTables
import Synchronization

/// Debugging, K13g part 1 (Zircon's task_suspend and suspend tokens,
/// process_read_memory / process_write_memory).
///
/// Suspension: a thread object counts suspensions (`suspendCount`); while
/// it is above 0 the thread parks on its way back to user mode
/// (`UserTraps.leaving`, and before its first entry), its registers in the
/// frame at its kernel stack top, so thread_read/write_state work
/// (`suspended`; ZX_THREAD_SUSPENDED / RUNNING signals). A thread blocked in
/// a syscall that can simply be made again (object, port, futex, counter
/// and interrupt waits, sleeps, reads; `Syscalls.restartable`) is woken,
/// and the syscall is restarted from user mode (the PC rewound over the
/// syscall instruction, its registers untouched: Zircon's vDSO retries
/// instead, croi's programs call the kernel directly); a pager wait under a
/// user page fault is left the same way and the fault taken again. Other
/// waits (channel_call, exceptions) suspend when they end. A token (type
/// 27, TRANSFER | INSPECT: one resume each) resumes its task when its
/// handle closes. A process counts too: each of its threads is suspended
/// once, threads started meanwhile start suspended.
struct SuspendTokenObject: ~Copyable {
    var header = ObjectHeader(type: .suspendToken)
    /// The task (retained): a thread or a process.
    let task: ObjectPointer

    static var defaultRights: Rights { .transfer | .inspect }
}

enum Debug {
    static var threadSuspended: UInt32 { 1 << 5 }

    /// task_suspend(_token) after the handle's WRITE check.
    static func suspend(_ task: ObjectPointer) throws(Status) -> ObjectPointer {
        let me = Scheduler.current.pointee.object
        switch task.header.type {
        case .thread:
            guard task.address != me else { throw .notSupported }
            try suspend(thread: task)
        case .process:
            if me != 0, ThreadObjectPointer(object: ObjectPointer(address: me)).pointee.process == task {
                throw .notSupported
            }
            try suspend(process: task)
        default:
            throw .wrongType
        }
        task.retain()
        guard let token = Objects.allocate(SuspendTokenObject(task: task)) else {
            resume(task)
            task.release()
            throw .noMemory
        }
        return token
    }

    /// The token's last handle went.
    static func destroyToken(_ object: ObjectPointer) {
        let task = unsafe UnsafePointer<SuspendTokenObject>(bitPattern: UInt(object.address))!.pointee.task
        resume(task)
        task.release()
        Objects.free(object, as: SuspendTokenObject.self)
    }

    private static func resume(_ task: ObjectPointer) {
        if task.header.type == .thread { resume(thread: task) } else { resume(process: task) }
    }

    static func suspend(thread object: ObjectPointer) throws(Status) {
        let thread = ThreadObjectPointer(object: object)
        let scheduled = try object.header.lock.withLock { () throws(Status) -> UInt64 in
            guard thread.pointee.state != .dead else { throw .badState }
            let count = thread.pointee.suspendCount.add(1, ordering: .acquiringAndReleasing).newValue
            return count == 1 ? thread.pointee.thread : 0
        }
        guard scheduled != 0 else { return }
        let target = ThreadPointer(address: scheduled)
        Scheduler.locked { Scheduler.requestSuspend(target) }
    }

    static func resume(thread object: ObjectPointer) {
        let thread = ThreadObjectPointer(object: object)
        let scheduled = object.header.lock.withLock { () -> UInt64 in
            guard thread.pointee.suspendCount.load(ordering: .relaxed) > 0 else { return 0 }
            let count = thread.pointee.suspendCount.subtract(1, ordering: .acquiringAndReleasing).newValue
            return count == 0 ? thread.pointee.thread : 0
        }
        guard scheduled != 0 else { return }
        Scheduler.locked {
            ThreadPointer(address: scheduled).pointee.suspendPending = false
            _ = Scheduler.wakeAll(thread.pointee.suspendQueue)
        }
    }

    static func suspend(process object: ObjectPointer) throws(Status) {
        let process = ProcessPointer(object: object)
        var threads = UniqueArray<UInt64>()
        try object.header.lock.withLock { () throws(Status) in
            guard process.pointee.state == .initial || process.pointee.state == .running else { throw .badState }
            process.pointee.suspendCount += 1
            guard process.pointee.suspendCount == 1 else { return }
            for i in 0..<process.pointee.threads.count {
                let t = ObjectPointer(address: process.pointee.threads[i])
                if t.tryRetain() { threads.append(t.address) }
            }
        }
        for i in 0..<threads.count {
            let t = ObjectPointer(address: threads[i])
            try? suspend(thread: t)
            t.release()
        }
    }

    static func resume(process object: ObjectPointer) {
        let process = ProcessPointer(object: object)
        var threads = UniqueArray<UInt64>()
        object.header.lock.withLock {
            guard process.pointee.suspendCount > 0 else { return }
            process.pointee.suspendCount -= 1
            guard process.pointee.suspendCount == 0, process.pointee.state == .running || process.pointee.state == .initial else { return }
            for i in 0..<process.pointee.threads.count {
                let t = ObjectPointer(address: process.pointee.threads[i])
                if t.tryRetain() { threads.append(t.address) }
            }
        }
        for i in 0..<threads.count {
            let t = ObjectPointer(address: threads[i])
            resume(thread: t)
            t.release()
        }
    }

    /// The calling thread parks while suspended (or until killed). On its
    /// way to user mode, interrupts masked; returns masked.
    static func park() {
        let me = Scheduler.current
        guard me.pointee.object != 0 else { return }
        let object = ObjectPointer(address: me.pointee.object)
        let thread = ThreadObjectPointer(object: object)
        arch_interrupts_enable()
        let suspended = object.header.lock.withLock { () -> Bool in
            guard thread.pointee.suspendCount.load(ordering: .acquiring) > 0 else { return false }
            thread.pointee.suspended = true
            return true
        }
        if suspended {
            object.updateSignals(clear: Signals.threadRunning, set: threadSuspended)
            Scheduler.locked {
                while thread.pointee.suspendCount.load(ordering: .acquiring) > 0, !me.pointee.killPending {
                    _ = Scheduler.block(on: thread.pointee.suspendQueue, deadline: UInt64(Int64.max), interruptible: true)
                }
                me.pointee.suspendPending = false
            }
            object.header.lock.withLock { thread.pointee.suspended = false }
            object.updateSignals(clear: threadSuspended, set: me.pointee.killPending ? 0 : Signals.threadRunning)
        } else {
            Scheduler.locked { me.pointee.suspendPending = false }
        }
        _ = arch_interrupts_save()
    }

    // MARK: Memory

    /// process_read_memory / process_write_memory after the handle checks:
    /// within the one mapping at `address` (NOT_FOUND if none), clamped to
    /// its end and the VMO's; OUT_OF_RANGE if nothing could move. A write
    /// to a mapping that isn't writable first gives it a private copy
    /// (a snapshot child of its range: Zircon's ForceWritable), so a
    /// breakpoint never reaches the VMO behind it; the vDSO is refused.
    /// Code written is made visible to instruction fetch.
    static func transfer(_ process: ObjectPointer, address: UInt64, buffer: UInt64, size: UInt64,
                         write: Bool) throws(Status) -> UInt64 {
        let record = ProcessPointer(object: process).pointee.aspaceRecord
        var found: Mapping? = nil
        try record.pointee.lock.withLock { () throws(Status) in
            guard !record.pointee.dead else { throw .notFound }
            for i in 0..<record.pointee.mappings.count where record.pointee.mappings[i].contains(address & ~(KernelLayout.pageSize - 1)) {
                found = record.pointee.mappings[i]
            }
            found?.vmo.retain()  // under the lock (review fix: an unmap could free it first)
        }
        guard var mapping = found else { throw .notFound }
        defer { mapping.vmo.release() }
        if write, Vdso.owns(mapping.vmo) { throw .accessDenied }
        if write, !mapping.rights.contains(.write), case .anonymous = mapping.vmo.pointee.kind {
            let original = mapping.vmo
            mapping = try record.privatize(mapping)  // retained for us
            original.release()
        }
        let vmo = mapping.vmo
        let offset = mapping.offset + (address - mapping.base)
        let end = min(mapping.offset + mapping.size, vmo.pointee.size)
        guard offset < end else { throw .outOfRange }
        let length = min(size, end - offset)
        guard vmo.inPhysmap, vmo.pointee.cache == .cached else { throw .badState }
        var done: UInt64 = 0, faults = 0
        while done < length {
            let at = offset + done
            if write { try Pagers.ensureWritable(vmo, at, ahead: length - done) } else { try Pagers.ensure(vmo, at, readAhead: length - done) }
            // Copied under the page's owner's lock (K14h, VmoUserCopy).
            let chunk = min(length - done, KernelLayout.pageSize - at % KernelLayout.pageSize)
            switch write ? VmoUserCopy.write(vmo, at, from: buffer + done, chunk)
                         : VmoUserCopy.read(vmo, at, to: buffer + done, chunk) {
            case .copied:
                done += chunk
                faults = 0
            case .absent where !write && vmo.readsAsZero(at):  // a zero interval (K14k)
                guard VmoUserCopy.zeros(to: buffer + done, chunk) == .copied else { throw .invalidArgs }
                done += chunk
            case .absent:
                do throws(Status) {
                    try VmoUserCopy.commit(vmo, at)
                } catch {
                    throw error == .notFound || error == .outOfRange ? error : .noMemory
                }
            case .faulted:
                faults += 1
                guard faults < VmoUserCopy.attempts, VmoUserCopy.pageIn(buffer + done, chunk, write: !write) else {
                    throw .invalidArgs
                }
            }
        }
        if write, mapping.rights.contains(.execute) {
            try? Vmo.withBorrowed(vmo) { (v: borrowing Vmo) throws(VmError) in
                try v.syncInstructions(offset: offset, size: length)
            }
        }
        return length
    }
}
