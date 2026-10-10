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
            guard a[1] == 0 else { throw .invalidArgs }
            let channel = try table.get(handle, type: .channel, rights: .write)
            let message = try build(table, channel: handle, bytes: a[2], count: a[3], handles: a[4],
                                    handleCount: a[5])
            message.pointee.txid = message.pointee.bytes >= 4
                ? unsafe UnsafePointer<UInt32>(bitPattern: UInt(message.data))!.pointee : 0
            try Channels.write(channel.object, message)
        case 82:  // channel_read(channel, options, bytes, handles, num_bytes | num_handles << 32, actuals)
            guard a[1] == 0 else { throw .invalidArgs }
            try check(a[5], 8)
            let channel = try table.get(handle, type: .channel, rights: .read)
            let capacity = (bytes: UInt32(truncatingIfNeeded: a[4]), handles: UInt32(truncatingIfNeeded: a[4] >> 32))
            let size = try Channels.peek(channel.object)
            try put(UInt64(size.bytes) | UInt64(size.handles) << 32, a[5])
            guard size.bytes <= capacity.bytes, size.handles <= capacity.handles else { throw .bufferTooSmall }
            if size.bytes > 0 { try check(a[2], Int(size.bytes)) }
            if size.handles > 0 { try check(a[3], Int(size.handles) * 4) }
            let message = try Channels.read(channel.object)
            try deliver(message, to: table, bytes: a[2], handles: a[3])
        case 83:  // channel_call(channel, options, deadline, args, actual_bytes, actual_handles)
            guard a[1] == 0 else { throw .invalidArgs }
            var args = croi_channel_call_args_t()
            let copied = withUnsafeMutableBytes(of: &args) { raw in
                unsafe UserCopy.from(raw.baseAddress!, a[3], UInt64(raw.count))
            }
            guard copied == 0 else { throw .invalidArgs }
            try check(a[4], 4)
            try check(a[5], 4)
            if args.rd_num_bytes > 0 { try check(args.rd_bytes, Int(args.rd_num_bytes)) }
            if args.rd_num_handles > 0 { try check(args.rd_handles, Int(args.rd_num_handles) * 4) }
            let channel = try table.get(handle, type: .channel, rights: [.read, .write])
            let message = try build(table, channel: handle, bytes: args.wr_bytes, count: UInt64(args.wr_num_bytes),
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
        case 85:  // object_signal_peer(handle, clear, set)
            let object = try table.get(handle, rights: .signalPeer)
            try Channels.signalPeer(object.object, clear: UInt32(truncatingIfNeeded: a[1]),
                                    set: UInt32(truncatingIfNeeded: a[2]))
        case 86:  // object_get_info(handle, topic, buffer, buffer_size)
            guard a[1] == UInt64(CROI_INFO_HANDLE_BASIC) else { throw .notSupported }
            guard a[3] >= UInt64(MemoryLayout<croi_info_handle_basic_t>.size) else { throw .bufferTooSmall }
            try check(a[2], MemoryLayout<croi_info_handle_basic_t>.size)
            let rights = try table.rights(of: handle)
            let object = try table.get(handle)
            try put(croi_info_handle_basic_t(koid: object.koid, rights: rights.rawValue, type: object.type.rawValue,
                                             related_koid: Channels.relatedKoid(object.object), reserved: (0, 0)),
                    a[2])
        default:
            throw .notSupported
        }
    }

    /// A message from user memory: `count` bytes at `bytes`, and the
    /// handles listed at `handles` moved out of `table` (each needs
    /// TRANSFER; never the channel written to; no repeats). Handles leave
    /// the table only once everything checked out.
    private static func build(_ table: borrowing HandleTable, channel: UInt32, bytes: UInt64, count: UInt64,
                              handles: UInt64, handleCount: UInt64) throws(Status) -> MessagePointer {
        guard count <= UInt64(CROI_CHANNEL_MAX_BYTES), handleCount <= UInt64(CROI_CHANNEL_MAX_HANDLES) else {
            throw .outOfRange
        }
        var values = InlineArray<64, UInt32>(repeating: 0)
        if handleCount > 0 {
            var span = values.mutableSpan
            let copied = span.withUnsafeMutableBytes { raw in
                unsafe UserCopy.from(raw.baseAddress!, handles, handleCount * 4)
            }
            guard copied == 0 else { throw .invalidArgs }
        }
        for i in 0..<Int(handleCount) {
            guard values[i] != channel else { throw .notSupported }
            for j in 0..<i where values[j] == values[i] { throw .invalidArgs }
            guard try table.rights(of: values[i]).contains(.transfer) else { throw .accessDenied }
        }
        guard let message = MessagePointer.allocate(bytes: UInt32(count), handles: UInt32(handleCount)) else {
            throw .noMemory
        }
        if count > 0 {
            let copied = unsafe UserCopy.from(UnsafeMutableRawPointer(bitPattern: UInt(message.data))!, bytes, count)
            guard copied == 0 else {
                message.free()
                throw .invalidArgs
            }
        }
        for i in 0..<Int(handleCount) {
            do throws(Status) {
                let rights = try table.rights(of: values[i])
                let ref = try table.get(values[i])
                ref.object.retain()
                message.setHandle(i, object: ref.object.address, rights: rights)
                try table.close(values[i])
            } catch {
                message.free()
                throw error
            }
        }
        return message
    }

    /// Copies a message out: bytes to `bytes`, its objects into `table`
    /// with their values at `handles`. Frees it.
    private static func deliver(_ message: MessagePointer, to table: borrowing HandleTable, bytes: UInt64,
                                handles: UInt64) throws(Status) {
        defer { message.free() }
        if message.pointee.bytes > 0 {
            let copied = unsafe UserCopy.to(bytes, UnsafeRawPointer(bitPattern: UInt(message.data))!,
                                            UInt64(message.pointee.bytes))
            guard copied == 0 else { throw .invalidArgs }
        }
        for i in 0..<Int(message.pointee.handles) {
            let entry = message.handle(i)
            let value = try table.add(ObjectPointer(address: entry.object), rights: entry.rights)
            message.setHandle(i, object: 0, rights: Rights(rawValue: 0))  // the table's now
            try put(value, handles + UInt64(i) * 4)
        }
    }
}
