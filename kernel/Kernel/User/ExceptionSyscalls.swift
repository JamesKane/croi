import CKernel

/// Exceptions, properties, thread state and job policy from user space
/// (K7d; numbers in user/include/croi/syscall.h, layouts in task.h).
/// Zircon's calls.
extension Syscalls {
    static func exceptionCall(_ number: UInt64, _ a: InlineArray<6, UInt64>,
                              _ table: borrowing HandleTable) throws(Status) {
        let handle = UInt32(truncatingIfNeeded: a[0])
        switch number {
        case 100:  // task_create_exception_channel(task, options, out)
            guard a[1] == 0 else { throw .invalidArgs }
            try check(a[2], 4)
            let task = try table.get(handle, rights: [.inspect, .write])
            guard task.type == .thread || task.type == .process || task.type == .job else { throw .wrongType }
            let channel = try Exceptions.createChannel(for: task.object)
            try put(try table.add(channel, rights: [.transfer, .wait, .read, .inspect]), a[2])
        case 101, 102:  // exception_get_thread / exception_get_process(exception, out)
            try check(a[1], 4)
            let exception = try table.get(handle, type: .exception)
            let e = ExceptionPointer(object: exception.object)
            let task = number == 101 ? e.pointee.thread : e.pointee.process
            task.retain()
            let rights = number == 101 ? ThreadObject.defaultRights : ProcessObject.defaultRights
            let value: UInt32
            do throws(Status) {
                value = try table.add(task, rights: rights)
            } catch {
                task.release()
                throw error
            }
            try put(value, a[1])
        case 103:  // object_get_property(handle, property, value, size)
            guard a[1] == UInt64(CROI_PROP_EXCEPTION_STATE) else { throw .notSupported }
            guard a[3] >= 4 else { throw .bufferTooSmall }
            try check(a[2], 4)
            let exception = try table.get(handle, type: .exception, rights: .getProperty)
            try put(Exceptions.state(exception.object), a[2])
        case 104:  // object_set_property(handle, property, value, size)
            guard a[1] == UInt64(CROI_PROP_EXCEPTION_STATE) else { throw .notSupported }
            guard a[3] >= 4 else { throw .bufferTooSmall }
            var state: UInt32 = 0
            let copied = withUnsafeMutableBytes(of: &state) { unsafe UserCopy.from($0.baseAddress!, a[2], 4) }
            guard copied == 0 else { throw .invalidArgs }
            let exception = try table.get(handle, type: .exception, rights: .setProperty)
            try Exceptions.setState(exception.object, state)
        case 105:  // thread_read_state(thread, kind, buffer, size)
            guard a[1] == UInt64(CROI_THREAD_STATE_GENERAL_REGS) else { throw .invalidArgs }
            guard a[3] >= UInt64(MemoryLayout<croi_thread_state_general_regs_t>.size) else { throw .bufferTooSmall }
            try check(a[2], MemoryLayout<croi_thread_state_general_regs_t>.size)
            let thread = try table.get(handle, type: .thread, rights: .read)
            try put(try Exceptions.readState(thread.object), a[2])
        case 106:  // thread_write_state(thread, kind, buffer, size)
            guard a[1] == UInt64(CROI_THREAD_STATE_GENERAL_REGS) else { throw .invalidArgs }
            guard a[3] == UInt64(MemoryLayout<croi_thread_state_general_regs_t>.size) else { throw .invalidArgs }
            var registers = croi_thread_state_general_regs_t()
            let copied = withUnsafeMutableBytes(of: &registers) { raw in
                unsafe UserCopy.from(raw.baseAddress!, a[2], UInt64(raw.count))
            }
            guard copied == 0 else { throw .invalidArgs }
            let thread = try table.get(handle, type: .thread, rights: .write)
            try Exceptions.writeState(thread.object, registers)
        case 107:  // job_set_policy(job, options, topic, croi_policy_basic_t *policy, count)
            guard a[2] == 0 else { throw .invalidArgs }  // the basic topic
            guard a[4] <= 16 else { throw .outOfRange }
            var entries = InlineArray<16, croi_policy_basic_t>(repeating: croi_policy_basic_t())
            if a[4] > 0 {
                var span = entries.mutableSpan
                let copied = span.withUnsafeMutableBytes { raw in
                    unsafe UserCopy.from(raw.baseAddress!, a[3], a[4] * UInt64(MemoryLayout<croi_policy_basic_t>.size))
                }
                guard copied == 0 else { throw .invalidArgs }
            }
            let job = try table.get(handle, type: .job, rights: .setPolicy)
            try Policy.set(job.object, options: UInt32(truncatingIfNeeded: a[1]), entries, count: Int(a[4]))
        default:
            throw .notSupported
        }
    }
}
