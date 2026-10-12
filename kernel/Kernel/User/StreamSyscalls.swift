import CKernel

/// Streams (K13c): syscalls 194-201, Zircon's checks in Zircon's order.
extension Syscalls {
    static func streamCall(_ number: UInt64, _ a: InlineArray<6, UInt64>, _ table: borrowing HandleTable) throws(Status) {
        let handle = UInt32(truncatingIfNeeded: a[0])
        switch number {
        case 194:  // stream_create(options, vmo, seek, out)
            let options = UInt32(truncatingIfNeeded: a[0])
            guard options & ~(Streams.modeRead | Streams.modeWrite | Streams.modeAppend) == 0 else { throw .invalidArgs }
            var needed = Rights(), granted = StreamObject.defaultRights
            if options & Streams.modeRead != 0 { needed = needed | .read; granted = granted | .read }
            if options & (Streams.modeWrite | Streams.modeAppend) != 0 { needed = needed | .write }
            if options & Streams.modeWrite != 0 { granted = granted | .write }
            try check(a[3], MemoryLayout<UInt32>.size)
            let ref = try table.get(UInt32(truncatingIfNeeded: a[1]), type: .vmo, rights: needed)
            let stream = try Streams.create(options: options, vmo: VmoPointer(address: UnsafeVmoObject(ref.object).vmo), seek: a[2])
            let out: UInt32
            do throws(Status) {
                out = try table.add(stream, rights: granted)
            } catch {
                stream.release()
                throw error
            }
            try put(out, a[3])
        case 195, 197:  // stream_writev / stream_readv(stream, options, vector, count, size_t *actual)
            let options = UInt32(truncatingIfNeeded: a[1])
            guard options & ~(number == 195 ? UInt32(CROI_STREAM_APPEND) : 0) == 0 else { throw .invalidArgs }
            guard a[2] != 0 else { throw .invalidArgs }
            let stream = try table.get(handle, type: .stream, rights: number == 195 ? .write : .read)
            if a[4] != 0 { try check(a[4], MemoryLayout<UInt64>.size) }
            let moved = number == 195
                ? try Streams.writeAtSeek(stream.object, append: options & UInt32(CROI_STREAM_APPEND) != 0, a[2], a[3])
                : try Streams.readAtSeek(stream.object, a[2], a[3])
            if a[4] != 0 { try put(moved, a[4]) }
        case 196, 198:  // stream_writev_at / stream_readv_at(stream, options, offset, vector, count, size_t *actual)
            guard a[1] == 0, a[3] != 0 else { throw .invalidArgs }
            let stream = try table.get(handle, type: .stream, rights: number == 196 ? .write : .read)
            if a[5] != 0 { try check(a[5], MemoryLayout<UInt64>.size) }
            let moved = number == 196
                ? try Streams.write(stream.object, at: a[2], append: false, a[3], a[4]).1
                : try Streams.read(stream.object, at: a[2], a[3], a[4])
            if a[5] != 0 { try put(moved, a[5]) }
        case 199:  // stream_seek(stream, whence, offset, out)
            var rights = Rights()
            let stream = try table.get(handle, type: .stream, have: &rights)
            guard rights.contains(.read) || rights.contains(.write) else { throw .accessDenied }
            if a[3] != 0 { try check(a[3], MemoryLayout<UInt64>.size) }
            let at = try Streams.seek(stream.object, whence: UInt32(truncatingIfNeeded: a[1]), Int64(bitPattern: a[2]))
            if a[3] != 0 { try put(at, a[3]) }
        case 200:  // vmo_get_stream_size(vmo, out)
            try check(a[1], MemoryLayout<UInt64>.size)
            let ref = try table.get(handle, type: .vmo)
            let vmo = VmoPointer(address: UnsafeVmoObject(ref.object).vmo)
            guard case .anonymous = vmo.pointee.kind else { return try put(UInt64(0), a[1]) }
            try put(Streams.streamSize(vmo), a[1])
        case 201:  // vmo_set_stream_size(vmo, size)
            let ref = try table.get(handle, type: .vmo, rights: .write)
            try Streams.setStreamSize(VmoPointer(address: UnsafeVmoObject(ref.object).vmo), a[1])
        default:
            throw .notSupported
        }
    }
}
