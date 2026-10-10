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
                channel = try table.get(handle, type: .channel, rights: [.read, .write])
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
        case 85:  // object_signal_peer(handle, clear, set)
            let object = try table.get(handle, rights: .signalPeer)
            try Channels.signalPeer(object.object, clear: UInt32(truncatingIfNeeded: a[1]),
                                    set: UInt32(truncatingIfNeeded: a[2]))
        case 86:  // object_get_info(handle, topic, buffer, buffer_size)
            if a[1] == UInt64(CROI_INFO_VMAR) {
                guard a[3] >= UInt64(MemoryLayout<croi_info_vmar_t>.size) else { throw .bufferTooSmall }
                try check(a[2], MemoryLayout<croi_info_vmar_t>.size)
                let vmar = try table.get(handle, type: .vmar, rights: .inspect)
                let v = VmarPointer(object: vmar.object).info
                try put(croi_info_vmar_t(base: v.base, len: v.size), a[2])
                return
            }
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
    /// handles listed at `handles` moved out of `table`. As in Zircon, the
    /// listed handles are consumed whether or not this succeeds (or the
    /// write after it: a failed write frees the message, closing them),
    /// unless the list itself can't be read. Each needs TRANSFER and may
    /// not be the channel written to; a repeat finds its handle gone (BAD_
    /// HANDLE). The first error is returned.
    private static func build(_ table: borrowing HandleTable, channel: ObjectPointer, bytes: UInt64, count: UInt64,
                              handles: UInt64, handleCount: UInt64) throws(Status) -> MessagePointer {
        guard count <= UInt64(CROI_CHANNEL_MAX_BYTES), handleCount <= UInt64(CROI_CHANNEL_MAX_HANDLES) else {
            discard(table, handles: handles, count: handleCount)
            throw .outOfRange
        }
        guard let message = MessagePointer.allocate(bytes: UInt32(count), handles: UInt32(handleCount)) else {
            discard(table, handles: handles, count: handleCount)
            throw .noMemory
        }
        if count > 0 {
            let copied = unsafe UserCopy.from(UnsafeMutableRawPointer(bitPattern: UInt(message.data))!, bytes, count)
            guard copied == 0 else {
                message.free()
                discard(table, handles: handles, count: handleCount)
                throw .invalidArgs
            }
        }
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
                    object.release()
                    throw .notSupported
                }
                guard rights.contains(.transfer) else {
                    object.release()
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
