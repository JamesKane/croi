import Synchronization
import CKernel

/// Channels, eventpairs and object info from user space (K7b; numbers in
/// user/include/croi/syscall.h, layouts in include/ipc.h). Zircon's calls;
/// channel_read packs its two capacities into one argument
/// (bytes | handles << 32) and writes both actual counts through one
/// pointer (two uint32_t).
extension Syscalls {
    static func ipcCall(_ number: UInt64, _ a: InlineArray<6, UInt64>, _ table: borrowing HandleTable) throws(Status) {
        let handle = UInt32(truncatingIfNeeded: a[0])
        switch number {
        case 80:  // channel_create(options, out0, out1)
            try Policy.check(UInt32(CROI_POL_NEW_CHANNEL))
            guard a[0] == 0 else { throw .invalidArgs }
            try check(a[1], 4)
            try check(a[2], 4)
            let (first, second) = try Channels.create()
            let h0: UInt32
            do throws(Status) {
                h0 = try table.add(first, rights: ChannelObject.defaultRights)
            } catch {
                second.release()
                throw error
            }
            let h1 = try table.add(second, rights: ChannelObject.defaultRights)
            try put(h0, a[1])
            try put(h1, a[2])
        case 81:  // channel_write(channel, options, bytes, num_bytes, handles, num_handles)
            let channel: ObjectRef
            do throws(Status) {
                guard a[1] == 0 else { throw .invalidArgs }
                channel = try table.get(handle, type: .channel, rights: .write)
            } catch {
                discard(table, handles: a[4], count: a[5])
                throw error
            }
            let message = try build(table, channel: channel.object, bytes: a[2], count: a[3], handles: a[4],
                                    handleCount: a[5])
            message.pointee.txid = message.pointee.bytes >= 4
                ? unsafe UnsafePointer<UInt32>(bitPattern: UInt(message.data))!.pointee : 0
            if try Channels.write(channel.object, message) {
                Policy.limitException(UInt32(CROI_EXCP_POLICY_CODE_CHANNEL_FULL_WRITE))
            }
        case 82, 214:  // channel_read(_etc)(channel, options, bytes, handles, num_bytes | num_handles << 32, actuals)
            // Zircon's order: the handle, then the options (MAY_DISCARD).
            let channel = try table.get(handle, type: .channel, rights: .read)
            guard a[1] & ~UInt64(CROI_CHANNEL_READ_MAY_DISCARD) == 0 else { throw .notSupported }
            try check(a[5], 8)
            let infos = number == 214
            let entry = infos ? MemoryLayout<croi_handle_info_t>.size : 4
            let capacity = (bytes: UInt32(truncatingIfNeeded: a[4]), handles: UInt32(truncatingIfNeeded: a[4] >> 32))
            // The message read is the one whose size was checked (another
            // reader may take it meanwhile: then peek again).
            var taken: MessagePointer? = nil
            while taken == nil {
                let size = try Channels.peek(channel.object)
                try put(UInt64(size.bytes) | UInt64(size.handles) << 32, a[5])
                guard size.bytes <= capacity.bytes, size.handles <= capacity.handles else {
                    if a[1] != 0, let dropped = Channels.discard(channel.object, ifLargerThan: capacity) { dropped.free() }
                    throw .bufferTooSmall
                }
                if size.bytes > 0 { try check(a[2], Int(size.bytes)) }
                if size.handles > 0 { try check(a[3], Int(size.handles) * entry) }
                taken = try Channels.read(channel.object, ifFits: size)
            }
            try deliver(taken!, to: table, bytes: a[2], handles: a[3], infos: infos)
        case 213:  // channel_write_etc(channel, options, bytes, num_bytes, dispositions, num_handles), K13e
            let channel: ObjectRef
            do throws(Status) {
                guard a[1] == 0 else { throw .invalidArgs }
                channel = try table.get(handle, type: .channel, rights: .write)
            } catch {
                discardDispositions(table, a[4], count: a[5])
                throw error
            }
            let message = try build(table, channel: channel.object, bytes: a[2], count: a[3], handles: a[4],
                                    handleCount: a[5], dispositions: true)
            message.pointee.txid = message.pointee.bytes >= 4
                ? unsafe UnsafePointer<UInt32>(bitPattern: UInt(message.data))!.pointee : 0
            if try Channels.write(channel.object, message) {
                Policy.limitException(UInt32(CROI_EXCP_POLICY_CODE_CHANNEL_FULL_WRITE))
            }
        case 215:  // channel_call_etc(channel, options, deadline, croi_channel_call_etc_args_t *, actual_bytes, actual_handles)
            var args = croi_channel_call_etc_args_t()
            let copied = withUnsafeMutableBytes(of: &args) { raw in
                unsafe UserCopy.from(raw.baseAddress!, a[3], UInt64(raw.count))
            }
            guard copied == 0 else { throw .invalidArgs }
            let channel: ObjectRef
            do throws(Status) {
                guard a[1] == 0 else { throw .invalidArgs }
                try check(a[4], 4)
                try check(a[5], 4)
                if args.rd_num_bytes > 0 { try check(args.rd_bytes, Int(args.rd_num_bytes)) }
                if args.rd_num_handles > 0 {
                    try check(args.rd_handles, Int(args.rd_num_handles) * MemoryLayout<croi_handle_info_t>.size)
                }
                channel = try table.get(handle, type: .channel, rights: .read | .write)
            } catch {
                discardDispositions(table, args.wr_handles, count: UInt64(args.wr_num_handles))
                throw error
            }
            let message = try build(table, channel: channel.object, bytes: args.wr_bytes, count: UInt64(args.wr_num_bytes),
                                    handles: args.wr_handles, handleCount: UInt64(args.wr_num_handles), dispositions: true)
            let reply = try Channels.call(channel.object, message, deadline: a[2])
            guard reply.pointee.bytes <= args.rd_num_bytes, reply.pointee.handles <= args.rd_num_handles else {
                reply.free()
                throw .bufferTooSmall  // Zircon writes no actual counts here
            }
            try put(reply.pointee.bytes, a[4])
            try put(reply.pointee.handles, a[5])
            try deliver(reply, to: table, bytes: args.rd_bytes, handles: args.rd_handles, infos: true)
        case 210:  // object_wait_many(croi_wait_item_t *items, count, deadline), K13e
            try waitMany(table, items: a[0], count: a[1], deadline: a[2])
        case 211:  // handle_close_many(const uint32_t *handles, count), K13e
            try closeMany(table, handles: a[0], count: a[1])
        case 212:  // port_cancel_key(port, options, key), K13e
            try Ports.cancelKey(table, port: handle, options: a[1], key: a[2])
        case 83:  // channel_call(channel, options, deadline, args, actual_bytes, actual_handles)
            // Unreadable args: the handles to send are unknown, so none
            // are consumed (Zircon's too).
            var args = croi_channel_call_args_t()
            let copied = withUnsafeMutableBytes(of: &args) { raw in
                unsafe UserCopy.from(raw.baseAddress!, a[3], UInt64(raw.count))
            }
            guard copied == 0 else { throw .invalidArgs }
            let channel: ObjectRef
            do throws(Status) {
                guard a[1] == 0 else { throw .invalidArgs }
                try check(a[4], 4)
                try check(a[5], 4)
                if args.rd_num_bytes > 0 { try check(args.rd_bytes, Int(args.rd_num_bytes)) }
                if args.rd_num_handles > 0 { try check(args.rd_handles, Int(args.rd_num_handles) * 4) }
                channel = try table.get(handle, type: .channel, rights: .read | .write)
            } catch {
                discard(table, handles: args.wr_handles, count: UInt64(args.wr_num_handles))
                throw error
            }
            let message = try build(table, channel: channel.object, bytes: args.wr_bytes, count: UInt64(args.wr_num_bytes),
                                    handles: args.wr_handles, handleCount: UInt64(args.wr_num_handles))
            let reply = try Channels.call(channel.object, message, deadline: a[2])
            try put(reply.pointee.bytes, a[4])
            try put(reply.pointee.handles, a[5])
            guard reply.pointee.bytes <= args.rd_num_bytes, reply.pointee.handles <= args.rd_num_handles else {
                reply.free()
                throw .bufferTooSmall
            }
            try deliver(reply, to: table, bytes: args.rd_bytes, handles: args.rd_handles)
        case 84:  // eventpair_create(options, out0, out1)
            try Policy.check(UInt32(CROI_POL_NEW_EVENTPAIR))
            guard a[0] == 0 else { throw .invalidArgs }
            try check(a[1], 4)
            try check(a[2], 4)
            let (first, second) = try Channels.createEventPair()
            let h0: UInt32
            do throws(Status) {
                h0 = try table.add(first, rights: EventPairObject.defaultRights)
            } catch {
                second.release()
                throw error
            }
            let h1 = try table.add(second, rights: EventPairObject.defaultRights)
            try put(h0, a[1])
            try put(h1, a[2])
        case 87:  // fifo_create(elem_count, elem_size, options, out0, out1), K13b
            guard a[2] == 0 else { throw .invalidArgs }
            try Policy.check(UInt32(CROI_POL_NEW_FIFO))
            try check(a[3], MemoryLayout<UInt32>.size)
            try check(a[4], MemoryLayout<UInt32>.size)
            let (first, second) = try Fifos.create(count: a[0], size: a[1])
            let h0: UInt32
            do throws(Status) {
                h0 = try table.add(first, rights: FifoObject.defaultRights)
            } catch {
                first.release()
                second.release()
                throw error
            }
            let h1 = try table.add(second, rights: FifoObject.defaultRights)
            try put(h0, a[3])
            try put(h1, a[4])
        case 88, 89:  // fifo_write / fifo_read(fifo, elem_size, data, count, size_t *actual)
            if a[4] != 0 { try check(a[4], MemoryLayout<UInt64>.size) }
            let fifo = try table.get(handle, type: .fifo, rights: number == 88 ? .write : .read)
            let moved = number == 88
                ? try Fifos.write(fifo.object, size: a[1], source: a[2], count: a[3])
                : try Fifos.read(fifo.object, size: a[1], destination: a[2], count: a[3])
            if a[4] != 0 { try put(moved, a[4]) }
        case 85:  // object_signal_peer(handle, clear, set)
            let object = try table.get(handle, rights: .signalPeer)
            try Channels.signalPeer(object.object, clear: UInt32(truncatingIfNeeded: a[1]),
                                    set: UInt32(truncatingIfNeeded: a[2]))
        case 86:  // object_get_info(handle, topic, buffer, buffer_size, size_t *actual, size_t *avail)
            if try taskInfo(a, table) { return }  // K13e's topics (InfoTopics.swift)
            if a[1] == UInt64(CROI_INFO_VMAR) {
                guard a[3] >= UInt64(MemoryLayout<croi_info_vmar_t>.size) else { throw .bufferTooSmall }
                try check(a[2], MemoryLayout<croi_info_vmar_t>.size)
                let vmar = try table.get(handle, type: .vmar, rights: .inspect)
                let v = VmarPointer(object: vmar.object).info
                try put(croi_info_vmar_t(base: v.base, len: v.size), a[2])
                return
            }
            if a[1] == UInt64(CROI_INFO_TASK_STATS) || a[1] == UInt64(CROI_INFO_TASK_STATS_V1) {
                let size = a[1] == UInt64(CROI_INFO_TASK_STATS) ? MemoryLayout<croi_info_task_stats_t>.size : 32
                guard a[3] >= UInt64(size) else { throw .bufferTooSmall }
                try check(a[2], size)
                let process = try table.get(handle, type: .process, rights: .inspect)
                let record = ProcessPointer(object: process.object).pointee.aspaceRecord
                let stats: croi_info_task_stats_t
                do throws(VmError) {
                    stats = try UserAspace.withView(record) { (aspace: borrowing UserAspace) throws(VmError) in
                        try aspace.taskStats()
                    }
                } catch {
                    throw .badState  // the process is gone
                }
                try putPrefix(stats, size, a[2])
                return
            }
            if a[1] == UInt64(CROI_INFO_KMEM_STATS) || a[1] == UInt64(CROI_INFO_KMEM_STATS_V1) {
                let v1 = a[1] == UInt64(CROI_INFO_KMEM_STATS_V1)
                let size = v1 ? MemoryLayout<croi_info_kmem_stats_v1_t>.size : MemoryLayout<croi_info_kmem_stats_t>.size
                guard a[3] >= UInt64(size) else { throw .bufferTooSmall }
                try check(a[2], size)
                try Resources.check(table, handle, system: UInt64(CROI_RSRC_SYSTEM_INFO_BASE))
                let k = KernelMemory.stats()
                if v1 {
                    try put(croi_info_kmem_stats_v1_t(
                        total_bytes: k.total_bytes, free_bytes: k.free_bytes, wired_bytes: k.wired_bytes,
                        total_heap_bytes: k.total_heap_bytes, free_heap_bytes: k.free_heap_bytes, vmo_bytes: k.vmo_bytes,
                        mmu_overhead_bytes: k.mmu_overhead_bytes, ipc_bytes: k.ipc_bytes, other_bytes: k.other_bytes), a[2])
                } else {
                    try put(k, a[2])
                }
                return
            }
            if a[1] == UInt64(CROI_INFO_BTI) {
                guard a[3] >= UInt64(MemoryLayout<croi_info_bti_t>.size) else { throw .bufferTooSmall }
                try check(a[2], MemoryLayout<croi_info_bti_t>.size)
                let bti = try table.get(handle, type: .bti, rights: .inspect)
                try put(Dma.info(bti.object), a[2])
                return
            }
            if a[1] == UInt64(CROI_INFO_BTI_PROPERTIES) {
                guard a[3] >= UInt64(MemoryLayout<croi_bti_properties_t>.size) else { throw .bufferTooSmall }
                try check(a[2], MemoryLayout<croi_bti_properties_t>.size)
                let bti = try table.get(handle, type: .bti, rights: .inspect)
                try put(Dma.properties(bti.object), a[2])
                return
            }
            if a[1] == UInt64(CROI_INFO_MSI) {
                guard a[3] >= UInt64(MemoryLayout<croi_info_msi_t>.size) else { throw .bufferTooSmall }
                try check(a[2], MemoryLayout<croi_info_msi_t>.size)
                let msi = try table.get(handle, type: .msi, rights: .inspect)
                try put(Msis.info(msi.object), a[2])
                return
            }
            if a[1] == UInt64(CROI_INFO_THREAD_TRACE) {  // K10d
                guard a[3] >= UInt64(MemoryLayout<croi_info_thread_trace_t>.size) else { throw .bufferTooSmall }
                try check(a[2], MemoryLayout<croi_info_thread_trace_t>.size)
                let thread = try table.get(handle, type: .thread, rights: .inspect)
                try put(croi_info_thread_trace_t(trace_id: Processes.traceId(thread.object), reserved: 0), a[2])
                return
            }
            if a[1] == UInt64(CROI_INFO_VMAR_JIT) {  // K15b
                guard a[3] >= UInt64(MemoryLayout<croi_info_vmar_jit_t>.size) else { throw .bufferTooSmall }
                try check(a[2], MemoryLayout<croi_info_vmar_jit_t>.size)
                let vmar = try table.get(handle, type: .vmar, rights: .inspect)
                let v = VmarPointer(object: vmar.object).info
                let kind = try vmStatus { () throws(VmError) -> (reservation: Bool, jit: Bool, key: UInt8) in
                    try UserAspace.withView(v.aspace) { (aspace: borrowing UserAspace) throws(VmError) -> (reservation: Bool, jit: Bool, key: UInt8) in
                        try aspace.regionKind(v.region)
                    }
                }
                var info = croi_info_vmar_jit_t()
                info.flags = (kind.reservation ? UInt32(CROI_VMAR_JIT_FLAG_RESERVATION) : 0)
                    | (kind.jit ? UInt32(CROI_VMAR_JIT_FLAG_JIT) : 0)
                info.mechanism = !kind.reservation ? UInt32(CROI_JIT_MECHANISM_NONE)
                    : kind.key != 0 ? UInt32(CROI_JIT_MECHANISM_PROTECTION_KEYS) : UInt32(CROI_JIT_MECHANISM_VIEWS)
                info.key = UInt32(kind.key)
                try put(info, a[2])
                return
            }
            if a[1] == UInt64(CROI_INFO_MEMORY_ACCOUNT) {  // K15a
                guard a[3] >= UInt64(MemoryLayout<croi_info_memory_account_t>.size) else { throw .bufferTooSmall }
                try check(a[2], MemoryLayout<croi_info_memory_account_t>.size)
                let account = try table.get(handle, type: .memoryAccount, rights: .inspect)
                try put(Accounts.info(account.object), a[2])
                return
            }
            if a[1] == UInt64(CROI_INFO_DEBUGLOG) {  // K10d
                guard a[3] >= UInt64(MemoryLayout<croi_info_debuglog_t>.size) else { throw .bufferTooSmall }
                try check(a[2], MemoryLayout<croi_info_debuglog_t>.size)
                _ = try table.get(handle, type: .log)
                try put(DebugLog.progress, a[2])
                return
            }
            if a[1] == UInt64(CROI_INFO_RESOURCE) {
                guard a[3] >= UInt64(MemoryLayout<croi_info_resource_t>.size) else { throw .bufferTooSmall }
                try check(a[2], MemoryLayout<croi_info_resource_t>.size)
                let resource = try table.get(handle, type: .resource, rights: .inspect)
                try put(Resources.info(resource.object), a[2])
                return
            }
            if a[1] == UInt64(CROI_INFO_STREAM) {  // K13c, INSPECT
                guard a[3] >= UInt64(MemoryLayout<croi_info_stream_t>.size) else { throw .bufferTooSmall }
                try check(a[2], MemoryLayout<croi_info_stream_t>.size)
                let stream = try table.get(handle, type: .stream, rights: .inspect)
                try put(Streams.info(stream.object), a[2])
                return
            }
            if a[1] == UInt64(CROI_INFO_SOCKET) {  // K13c, INSPECT
                guard a[3] >= UInt64(MemoryLayout<croi_info_socket_t>.size) else { throw .bufferTooSmall }
                try check(a[2], MemoryLayout<croi_info_socket_t>.size)
                let socket = try table.get(handle, type: .socket, rights: .inspect)
                try put(Sockets.info(socket.object), a[2])
                return
            }
            if a[1] == UInt64(CROI_INFO_HANDLE_COUNT) {  // K13a, Zircon's: INSPECT
                guard a[3] >= UInt64(MemoryLayout<croi_info_handle_count_t>.size) else { throw .bufferTooSmall }
                try check(a[2], MemoryLayout<croi_info_handle_count_t>.size)
                let object = try table.get(handle, rights: .inspect)
                try put(croi_info_handle_count_t(handle_count: object.object.header.handleCount.load(ordering: .relaxed)),
                        a[2])
                return
            }
            guard a[1] == UInt64(CROI_INFO_HANDLE_BASIC) else { throw .notSupported }
            guard a[3] >= UInt64(MemoryLayout<croi_info_handle_basic_t>.size) else { throw .bufferTooSmall }
            try check(a[2], MemoryLayout<croi_info_handle_basic_t>.size)
            var rights = Rights()
            let object = try table.get(handle, have: &rights)
            try put(croi_info_handle_basic_t(koid: object.koid, rights: rights.rawValue, type: object.type.rawValue,
                                             related_koid: Channels.relatedKoid(object.object), reserved: (0, 0)),
                    a[2])
        default:
            throw .notSupported
        }
    }

    /// A message from user memory: `count` bytes at `bytes`, and the
    /// handles listed at `handles` moved out of `table`. As in Zircon, the
    /// listed handles are consumed whether or not this succeeds (or the
    /// write after it: a failed write frees the message, closing them),
    /// unless the list itself can't be read. Each needs TRANSFER and may
    /// not be the channel written to; a repeat finds its handle gone (BAD_
    /// HANDLE). The first error is returned.
    private static func build(_ table: borrowing HandleTable, channel: ObjectPointer, bytes: UInt64, count: UInt64,
                              handles: UInt64, handleCount: UInt64, dispositions: Bool = false) throws(Status) -> MessagePointer {
        func consume(_ table: borrowing HandleTable) {
            if dispositions { discardDispositions(table, handles, count: handleCount) } else { discard(table, handles: handles, count: handleCount) }
        }
        guard count <= UInt64(CROI_CHANNEL_MAX_BYTES), handleCount <= UInt64(CROI_CHANNEL_MAX_HANDLES) else {
            consume(table)
            throw .outOfRange
        }
        guard let message = MessagePointer.allocate(bytes: UInt32(count), handles: UInt32(handleCount)) else {
            consume(table)
            throw .noMemory
        }
        if count > 0 {
            let copied = unsafe UserCopy.from(UnsafeMutableRawPointer(bitPattern: UInt(message.data))!, bytes, count)
            guard copied == 0 else {
                message.free()
                consume(table)
                throw .invalidArgs
            }
        }
        if dispositions {
            do throws(Status) {
                try place(table, channel: channel, message: message, dispositions: handles, count: Int(handleCount))
            } catch {
                message.free()
                throw error
            }
            return message
        }
        if handleCount == 0 { return message }  // no 256-byte buffer to clear
        var values = InlineArray<64, UInt32>(repeating: 0)
        if handleCount > 0 {
            var span = values.mutableSpan
            let copied = span.withUnsafeMutableBytes { raw in
                unsafe UserCopy.from(raw.baseAddress!, handles, handleCount * 4)
            }
            guard copied == 0 else {
                message.free()
                throw .invalidArgs
            }
        }
        var failure: Status? = nil
        for i in 0..<Int(handleCount) {
            do throws(Status) {
                let (object, rights) = try table.take(values[i])
                guard object.address != channel.address else {
                    object.releaseTaken()
                    throw .notSupported
                }
                guard rights.contains(.transfer) else {
                    object.releaseTaken()
                    throw .accessDenied
                }
                message.setHandle(i, object: object.address, rights: rights)
            } catch {
                if failure == nil { failure = error }
            }
        }
        if let failure {
            message.free()
            throw failure
        }
        return message
    }

    /// Zircon's remove_user_handles: closes the `count` handles listed at
    /// `handles`, 64 at a time, skipping bad values and stopping only where
    /// the list can't be read.
    private static func discard(_ table: borrowing HandleTable, handles: UInt64, count: UInt64) {
        let count = count & 0xFFFF_FFFF  // a uint32_t in the ABI
        var values = InlineArray<64, UInt32>(repeating: 0)
        var done: UInt64 = 0
        while done < count {
            let chunk = min(count - done, 64)
            var span = values.mutableSpan
            let copied = span.withUnsafeMutableBytes { raw in
                unsafe UserCopy.from(raw.baseAddress!, handles &+ done * 4, chunk * 4)
            }
            guard copied == 0 else { return }
            for i in 0..<Int(chunk) { try? table.close(values[i]) }
            done += chunk
        }
    }

    /// The *_etc calls' dispositions into `message` (Zircon's
    /// get_handle_disposition_for_message: every entry processed, MOVE takes
    /// the handle out whatever happens, DUPLICATE leaves it; each failure's
    /// status in its `result`, the whole array copied back if any failed,
    /// the first failure returned). An unreadable array consumes nothing.
    private static func place(_ table: borrowing HandleTable, channel: ObjectPointer, message: MessagePointer,
                              dispositions: UInt64, count: Int) throws(Status) {
        guard count > 0 else { return }
        var entries = InlineArray<64, croi_handle_disposition_t>(repeating: croi_handle_disposition_t())
        let size = UInt64(count * MemoryLayout<croi_handle_disposition_t>.size)
        var span = entries.mutableSpan
        let copied = span.withUnsafeMutableBytes { raw in unsafe UserCopy.from(raw.baseAddress!, dispositions, size) }
        guard copied == 0 else { throw .invalidArgs }
        var failure: Status? = nil
        for i in 0..<count {
            let entry = entries[i]
            do throws(Status) {
                let object: ObjectPointer, rights: Rights
                switch entry.operation {
                case UInt32(CROI_HANDLE_OP_MOVE):
                    (object, rights) = try table.take(entry.handle)
                case UInt32(CROI_HANDLE_OP_DUPLICATE):
                    var have = Rights()
                    let ref = try table.get(entry.handle, have: &have)
                    rights = have
                    ref.object.retain()  // the message's own
                    object = ref.object
                default:
                    let (taken, _) = try table.take(entry.handle)
                    taken.releaseTaken()
                    throw .invalidArgs
                }
                var wanted = Rights(rawValue: entry.rights)
                do throws(Status) {
                    guard rights.contains(.transfer) else { throw .accessDenied }
                    guard object.address != channel.address else { throw .notSupported }
                    guard entry.type == 0 || entry.type == object.header.type.rawValue else { throw .wrongType }
                    if wanted == .sameRights { wanted = rights }
                    guard rights.isSuperset(of: wanted) else { throw .invalidArgs }
                    if entry.operation == UInt32(CROI_HANDLE_OP_DUPLICATE), !rights.contains(.duplicate) {
                        throw .accessDenied
                    }
                } catch {
                    object.releaseTaken()  // a DUPLICATE's handle is still there: no hook
                    throw error
                }
                message.setHandle(i, object: object.address, rights: wanted)
            } catch {
                entries[i].result = error.rawValue
                if failure == nil { failure = error }
            }
        }
        if let failure {
            var back = entries.mutableSpan
            _ = back.withUnsafeMutableBytes { raw in unsafe UserCopy.to(dispositions, UnsafeRawPointer(raw.baseAddress!), size) }
            throw failure
        }
    }

    /// The handles a refused *_etc write consumes: every entry but the
    /// DUPLICATEs (errors ignored); nothing if the array can't be read.
    private static func discardDispositions(_ table: borrowing HandleTable, _ dispositions: UInt64, count: UInt64) {
        let count = min(count & 0xFFFF_FFFF, UInt64(CROI_CHANNEL_MAX_HANDLES))
        guard count > 0 else { return }
        var entries = InlineArray<64, croi_handle_disposition_t>(repeating: croi_handle_disposition_t())
        var span = entries.mutableSpan
        let copied = span.withUnsafeMutableBytes { raw in
            unsafe UserCopy.from(raw.baseAddress!, dispositions, count * UInt64(MemoryLayout<croi_handle_disposition_t>.size))
        }
        guard copied == 0 else { return }
        for i in 0..<Int(count) where entries[i].operation != UInt32(CROI_HANDLE_OP_DUPLICATE) {
            try? table.close(entries[i].handle)
        }
    }

    /// object_wait_many (K13e): count 0 sleeps to the deadline (TIMED_OUT);
    /// more than 64 OUT_OF_RANGE; every item's pending written back once
    /// the wait ran (OK, TIMED_OUT or CANCELED), none if a handle was bad.
    private static func waitMany(_ table: borrowing HandleTable, items: UInt64, count: UInt64,
                                 deadline: UInt64) throws(Status) {
        guard count > 0 else {
            Scheduler.sleepInterruptible(until: deadline)
            throw .timedOut
        }
        guard count <= UInt64(CROI_WAIT_MANY_MAX_ITEMS) else { throw .outOfRange }
        var raw = InlineArray<64, croi_wait_item_t>(repeating: croi_wait_item_t())
        let size = count * UInt64(MemoryLayout<croi_wait_item_t>.size)
        var rawSpan = raw.mutableSpan
        let copied = rawSpan.withUnsafeMutableBytes { bytes in unsafe UserCopy.from(bytes.baseAddress!, items, size) }
        guard copied == 0 else { throw .invalidArgs }
        var waits = InlineArray<64, ObjectWait.WaitItem>(repeating: ObjectWait.WaitItem(handle: 0, waitFor: 0))
        for i in 0..<Int(count) { waits[i] = ObjectWait.WaitItem(handle: raw[i].handle, waitFor: raw[i].waitfor) }
        var result: Status? = nil
        do throws(Status) {
            var whole = waits.mutableSpan
            var span = whole.extracting(0..<Int(count))
            try ObjectWait.many(table, &span, deadline: deadline)
        } catch {
            guard error == .timedOut || error == .canceled else { throw error }
            result = error
        }
        for i in 0..<Int(count) { raw[i].pending = waits[i].pending }
        var back = raw.mutableSpan
        let failed = back.withUnsafeMutableBytes { bytes in unsafe UserCopy.to(items, UnsafeRawPointer(bytes.baseAddress!), size) }
        guard failed == 0 else { throw .invalidArgs }
        if let result { throw result }
    }

    /// handle_close_many (K13e): 64 at a time; 0 (ZX_HANDLE_INVALID) skipped;
    /// a bad value BAD_HANDLE but the rest still closed; an unreadable
    /// chunk stops there.
    private static func closeMany(_ table: borrowing HandleTable, handles: UInt64, count: UInt64) throws(Status) {
        var values = InlineArray<64, UInt32>(repeating: 0)
        var done: UInt64 = 0
        var bad = false
        while done < count {
            let chunk = min(count - done, 64)
            var span = values.mutableSpan
            let copied = span.withUnsafeMutableBytes { raw in
                unsafe UserCopy.from(raw.baseAddress!, handles &+ done * 4, chunk * 4)
            }
            guard copied == 0 else { throw .invalidArgs }
            for i in 0..<Int(chunk) where values[i] != 0 {
                do throws(Status) { try table.close(values[i]) } catch { bad = true }
            }
            done += chunk
        }
        if bad { throw .badHandle }
    }

    /// Copies a message out: bytes to `bytes`, its objects into `table`
    /// with their values at `handles` (or, `infos`, croi_handle_info_t
    /// entries: value, type, rights). Frees it.
    private static func deliver(_ message: MessagePointer, to table: borrowing HandleTable, bytes: UInt64,
                                handles: UInt64, infos: Bool = false) throws(Status) {
        defer { message.free() }
        if message.pointee.bytes > 0 {
            let copied = unsafe UserCopy.to(bytes, UnsafeRawPointer(bitPattern: UInt(message.data))!,
                                            UInt64(message.pointee.bytes))
            guard copied == 0 else { throw .invalidArgs }
        }
        for i in 0..<Int(message.pointee.handles) {
            let entry = message.handle(i)
            let value = try table.add(ObjectPointer(address: entry.object), rights: entry.rights)
            ObjectPointer(address: entry.object).header.handleCount.subtract(1, ordering: .relaxed)  // landed
            message.setHandle(i, object: 0, rights: Rights(rawValue: 0))  // the table's now
            if infos {
                let info = croi_handle_info_t(handle: value, type: ObjectPointer(address: entry.object).header.type.rawValue,
                                              rights: entry.rights.rawValue, unused: 0)
                try put(info, handles + UInt64(i) * UInt64(MemoryLayout<croi_handle_info_t>.size))
            } else {
                try put(value, handles + UInt64(i) * 4)
            }
        }
    }
}
