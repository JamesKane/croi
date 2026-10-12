import CKernel

/// Exceptions, properties, thread state and job policy from user space
/// (K7d; numbers in user/include/croi/syscall.h, layouts in task.h).
/// Zircon's calls.
extension Syscalls {
    static func exceptionCall(_ number: UInt64, _ a: InlineArray<6, UInt64>,
                              _ table: borrowing HandleTable) throws(Status) {
        let handle = UInt32(truncatingIfNeeded: a[0])
        switch number {
        case 236:  // thread_raise_exception(options, type, context): Zircon's checks, one INVALID_ARGS
            guard a[0] == UInt64(CROI_EXCEPTION_TARGET_JOB_DEBUGGER), a[1] == UInt64(CROI_EXCP_USER), a[2] != 0 else {
                throw .invalidArgs
            }
            var context = croi_exception_context_t()
            let copied = withUnsafeMutableBytes(of: &context) { unsafe UserCopy.from($0.baseAddress!, a[2], UInt64($0.count)) }
            guard copied == 0 else { throw .invalidArgs }
            Exceptions.raiseUser(code: context.synth_code, data: context.synth_data)
        case 100:  // task_create_exception_channel(task, options, out); Zircon's order (K13g)
            guard a[1] & ~UInt64(CROI_EXCEPTION_CHANNEL_DEBUGGER) == 0 else { throw .invalidArgs }
            let debugger = a[1] != 0
            try Policy.check(UInt32(CROI_POL_NEW_CHANNEL))
            try check(a[2], 4)
            var have = Rights()
            let task = try table.get(handle, rights: .inspect | .duplicate | .transfer | .manageThread, have: &have)
            if task.type == .thread, debugger { throw .invalidArgs }
            guard task.type == .thread || task.type == .process || task.type == .job else { throw .wrongType }
            if task.type != .thread, !have.contains(.enumerate) { throw .accessDenied }
            let channel = try Exceptions.createChannel(for: task.object, debugger: debugger)
            try put(try table.add(channel, rights: .transfer | .wait | .read), a[2])
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
            #if arch(x86_64)
            if a[1] == UInt64(CROI_PROP_REGISTER_FS) || a[1] == UInt64(CROI_PROP_REGISTER_GS) {
                let thread = try table.get(handle, rights: .getProperty)
                try requireCurrent(thread.object)
                guard a[3] >= 8 else { throw .bufferTooSmall }
                try check(a[2], 8)
                let me = Scheduler.current
                try put(a[1] == UInt64(CROI_PROP_REGISTER_FS) ? me.pointee.tls : me.pointee.gs, a[2])
                return
            }
            #endif
            if a[1] == UInt64(CROI_PROP_NAME) {
                guard a[2] != 0 else { throw .invalidArgs }
                let object = try table.get(handle, rights: .getProperty)
                guard a[3] >= UInt64(Names.maxLength) else { throw .bufferTooSmall }
                var name = try Names.get(object.object)
                var span = name.mutableSpan
                let failed = span.withUnsafeMutableBytes { unsafe UserCopy.to(a[2], UnsafeRawPointer($0.baseAddress!), 32) }
                guard failed == 0 else { throw .invalidArgs }
                return
            }
            if a[1] == UInt64(CROI_PROP_VMO_CONTENT_SIZE) {
                guard a[3] >= 8 else { throw .bufferTooSmall }
                try check(a[2], 8)
                let ref = try table.get(handle, type: .vmo, rights: .getProperty)
                let vmo = VmoPointer(address: UnsafeVmoObject(ref.object).vmo)
                guard case .anonymous = vmo.pointee.kind else { throw .notSupported }
                try put(Streams.streamSize(vmo), a[2])
                return
            }
            if a[1] == UInt64(CROI_PROP_STREAM_MODE_APPEND) {
                guard a[3] >= 1 else { throw .bufferTooSmall }
                try check(a[2], 1)
                let stream = try table.get(handle, type: .stream, rights: .getProperty)
                let on: UInt8 = StreamPointer(object: stream.object).pointee.mode & Streams.modeAppend != 0 ? 1 : 0
                try put(on, a[2])
                return
            }
            if a[1] == UInt64(CROI_PROP_SOCKET_RX_THRESHOLD) || a[1] == UInt64(CROI_PROP_SOCKET_TX_THRESHOLD) {
                guard a[3] >= 8 else { throw .bufferTooSmall }
                guard a[2] != 0 else { throw .invalidArgs }
                try check(a[2], 8)
                let socket = try table.get(handle, type: .socket, rights: .getProperty)
                try put(try Sockets.threshold(socket.object, transmit: a[1] == UInt64(CROI_PROP_SOCKET_TX_THRESHOLD)), a[2])
                return
            }
            if a[1] == UInt64(CROI_PROP_EXCEPTION_STRATEGY) {  // K13g
                guard a[3] >= 4 else { throw .bufferTooSmall }
                try check(a[2], 4)
                let exception = try table.get(handle, type: .exception, rights: .getProperty)
                try put(exception.object.header.lock.withLock { ExceptionPointer(object: exception.object).pointee.strategy }, a[2])
                return
            }
            guard a[1] == UInt64(CROI_PROP_EXCEPTION_STATE) else { throw .notSupported }
            guard a[3] >= 4 else { throw .bufferTooSmall }
            try check(a[2], 4)
            let exception = try table.get(handle, type: .exception, rights: .getProperty)
            try put(Exceptions.state(exception.object), a[2])
        case 104:  // object_set_property(handle, property, value, size)
            #if arch(x86_64)
            if a[1] == UInt64(CROI_PROP_REGISTER_FS) || a[1] == UInt64(CROI_PROP_REGISTER_GS) {
                let thread = try table.get(handle, rights: .setProperty)
                try requireCurrent(thread.object)
                guard a[3] >= 8 else { throw .bufferTooSmall }
                var base: UInt64 = 0
                let copied = withUnsafeMutableBytes(of: &base) { unsafe UserCopy.from($0.baseAddress!, a[2], 8) }
                guard copied == 0 else { throw .invalidArgs }
                guard Exceptions.isCanonical(base) else { throw .invalidArgs }
                if a[1] == UInt64(CROI_PROP_REGISTER_FS) { Scheduler.setUserTls(fs: base) } else { Scheduler.setUserTls(gs: base) }
                return
            }
            #endif
            if a[1] == UInt64(CROI_PROP_NAME) {
                guard a[2] != 0 else { throw .invalidArgs }
                let object = try table.get(handle, rights: .setProperty)
                try Names.set(object.object, try Names.fromUser(a[2], a[3]))
                return
            }
            if a[1] == UInt64(CROI_PROP_VMO_CONTENT_SIZE) {
                guard a[3] >= 8 else { throw .bufferTooSmall }
                var value: UInt64 = 0
                let copied = withUnsafeMutableBytes(of: &value) { unsafe UserCopy.from($0.baseAddress!, a[2], 8) }
                guard copied == 0 else { throw .invalidArgs }
                let ref = try table.get(handle, type: .vmo, rights: .setProperty | .write)
                try Streams.setStreamSize(VmoPointer(address: UnsafeVmoObject(ref.object).vmo), value)
                return
            }
            if a[1] == UInt64(CROI_PROP_STREAM_MODE_APPEND) {
                guard a[3] >= 1 else { throw .bufferTooSmall }
                var value: UInt8 = 0
                let copied = withUnsafeMutableBytes(of: &value) { unsafe UserCopy.from($0.baseAddress!, a[2], 1) }
                guard copied == 0 else { throw .invalidArgs }
                let stream = try table.get(handle, type: .stream, rights: .setProperty)
                Streams.setAppend(stream.object, value != 0)
                return
            }
            if a[1] == UInt64(CROI_PROP_SOCKET_RX_THRESHOLD) || a[1] == UInt64(CROI_PROP_SOCKET_TX_THRESHOLD) {
                guard a[3] >= 8 else { throw .bufferTooSmall }
                guard a[2] != 0 else { throw .invalidArgs }
                var value: UInt64 = 0
                let copied = withUnsafeMutableBytes(of: &value) { unsafe UserCopy.from($0.baseAddress!, a[2], 8) }
                guard copied == 0 else { throw .invalidArgs }
                let socket = try table.get(handle, type: .socket, rights: .setProperty)
                try Sockets.setThreshold(socket.object, transmit: a[1] == UInt64(CROI_PROP_SOCKET_TX_THRESHOLD), value)
                return
            }
            if a[1] == UInt64(CROI_PROP_EXCEPTION_STRATEGY) {  // K13g: the process debugger's only
                guard a[3] >= 4 else { throw .bufferTooSmall }
                var strategy: UInt32 = 0
                let copied = withUnsafeMutableBytes(of: &strategy) { unsafe UserCopy.from($0.baseAddress!, a[2], 4) }
                guard copied == 0 else { throw .invalidArgs }
                let exception = try table.get(handle, type: .exception, rights: .setProperty)
                guard strategy <= UInt32(CROI_EXCEPTION_STRATEGY_SECOND_CHANCE) else { throw .invalidArgs }
                try exception.object.header.lock.withLock { () throws(Status) in
                    let e = ExceptionPointer(object: exception.object)
                    guard e.pointee.channelType == UInt32(CROI_EXCEPTION_CHANNEL_TYPE_DEBUGGER) else { throw .badState }
                    e.pointee.strategy = strategy
                }
                return
            }
            guard a[1] == UInt64(CROI_PROP_EXCEPTION_STATE) else { throw .notSupported }
            guard a[3] >= 4 else { throw .bufferTooSmall }
            var state: UInt32 = 0
            let copied = withUnsafeMutableBytes(of: &state) { unsafe UserCopy.from($0.baseAddress!, a[2], 4) }
            guard copied == 0 else { throw .invalidArgs }
            let exception = try table.get(handle, type: .exception, rights: .setProperty)
            try Exceptions.setState(exception.object, state)
        case 105 where a[1] == UInt64(CROI_THREAD_STATE_DEBUG_REGS) || a[1] == UInt64(CROI_THREAD_STATE_SINGLE_STEP):
            // K13g: debug registers and single-step (HardwareDebug), Zircon's order.
            let size = a[1] == UInt64(CROI_THREAD_STATE_DEBUG_REGS) ? MemoryLayout<croi_thread_state_debug_regs_t>.size : 4
            guard a[3] >= UInt64(size) else { throw .bufferTooSmall }
            try check(a[2], size)
            let thread = try table.get(handle, type: .thread, rights: .read)
            // Read under the thread's lock, copied out after it.
            if a[1] == UInt64(CROI_THREAD_STATE_DEBUG_REGS) {
                var regs = try unsafe Exceptions.withStopped(thread.object) { (_, running) throws(Status) in
                    HardwareDebug.readRegisters(running)
                }
                let failed = withUnsafeBytes(of: &regs) { unsafe UserCopy.to(a[2], $0.baseAddress!, UInt64($0.count)) }
                guard failed == 0 else { throw .invalidArgs }
            } else {
                let stepping = try unsafe Exceptions.withStopped(thread.object) { (frame, running) throws(Status) -> UInt32 in
                    try unsafe HardwareDebug.singleStep(running, frame)
                }
                try put(stepping, a[2])
            }
        case 106 where a[1] == UInt64(CROI_THREAD_STATE_DEBUG_REGS) || a[1] == UInt64(CROI_THREAD_STATE_SINGLE_STEP):
            // Gated as Zircon's (a bit test: DEBUG_REGS and SINGLE_STEP).
            guard debuggingEnabled else { throw .notSupported }
            let size = a[1] == UInt64(CROI_THREAD_STATE_DEBUG_REGS) ? MemoryLayout<croi_thread_state_debug_regs_t>.size : 4
            guard a[3] >= UInt64(size) else { throw .bufferTooSmall }
            if a[1] == UInt64(CROI_THREAD_STATE_DEBUG_REGS) {
                var regs = croi_thread_state_debug_regs_t()
                let copied = withUnsafeMutableBytes(of: &regs) { unsafe UserCopy.from($0.baseAddress!, a[2], UInt64(size)) }
                guard copied == 0 else { throw .invalidArgs }
                let thread = try table.get(handle, type: .thread, rights: .write)
                try unsafe Exceptions.withStopped(thread.object) { (_, running) throws(Status) in
                    try HardwareDebug.writeRegisters(running, regs)
                }
            } else {
                var value: UInt32 = 0
                let copied = withUnsafeMutableBytes(of: &value) { unsafe UserCopy.from($0.baseAddress!, a[2], 4) }
                guard copied == 0 else { throw .invalidArgs }
                let thread = try table.get(handle, type: .thread, rights: .write)
                try unsafe Exceptions.withStopped(thread.object) { (frame, running) throws(Status) in
                    guard value <= 1 else { throw .invalidArgs }
                    try unsafe HardwareDebug.setSingleStep(running, frame, value == 1)
                }
            }
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
        case 108:  // job_set_cpu_reservation(job, CPU resource, cpu_mask), K10d
            let job = try table.get(handle, type: .job, rights: .setPolicy)
            try Resources.check(table, UInt32(truncatingIfNeeded: a[1]), system: UInt64(CROI_RSRC_SYSTEM_CPU_BASE))
            try Processes.setCpuReservation(job.object, mask: a[2])
        default:
            throw .notSupported
        }
    }

    #if arch(x86_64)
    /// Zircon's rule for the FS/GS properties: a thread object, and the
    /// calling thread's own.
    private static func requireCurrent(_ object: ObjectPointer) throws(Status) {
        guard object.header.type == .thread else { throw .wrongType }
        guard object.address == Scheduler.current.pointee.object else { throw .accessDenied }
    }
    #endif
}
