import CKernel

/// Sockets (K13c): syscalls 190-193, Zircon's checks in Zircon's order.
extension Syscalls {
    static func socketCall(_ number: UInt64, _ a: InlineArray<6, UInt64>, _ table: borrowing HandleTable) throws(Status) {
        let handle = UInt32(truncatingIfNeeded: a[0])
        switch number {
        case 190:  // socket_create(options, out0, out1)
            try Policy.check(UInt32(CROI_POL_NEW_SOCKET))
            try check(a[1], MemoryLayout<UInt32>.size)
            try check(a[2], MemoryLayout<UInt32>.size)
            let (first, second) = try Sockets.create(options: UInt32(truncatingIfNeeded: a[0]))
            let h0: UInt32
            do throws(Status) {
                h0 = try table.add(first, rights: SocketObject.defaultRights)
            } catch {
                first.release()
                second.release()
                throw error
            }
            let h1 = try table.add(second, rights: SocketObject.defaultRights)
            try put(h0, a[1])
            try put(h1, a[2])
        case 191, 192:  // socket_write / socket_read(socket, options, buffer, size, size_t *actual)
            let options = UInt32(truncatingIfNeeded: a[1])
            guard a[2] != 0 || a[3] == 0 else { throw .invalidArgs }
            guard options & ~(number == 192 ? UInt32(CROI_SOCKET_PEEK) : 0) == 0 else { throw .invalidArgs }
            let socket = try table.get(handle, type: .socket, rights: number == 191 ? .write : .read)
            if a[4] != 0 { try check(a[4], MemoryLayout<UInt64>.size) }
            let moved = number == 191
                ? try Sockets.write(socket.object, a[2], a[3])
                : try Sockets.read(socket.object, a[2], a[3], peek: options & UInt32(CROI_SOCKET_PEEK) != 0)
            if a[4] != 0 { try put(moved, a[4]) }
        case 193:  // socket_set_disposition(socket, disposition, disposition_peer)
            let valid = { (d: UInt64) -> Bool in
                d == 0 || d == UInt64(CROI_SOCKET_DISPOSITION_WRITE_DISABLED) || d == UInt64(CROI_SOCKET_DISPOSITION_WRITE_ENABLED)
            }
            guard valid(a[1]), valid(a[2]) else { throw .invalidArgs }
            let socket = try table.get(handle, type: .socket, rights: .manageSocket)
            guard a[1] != 0 || a[2] != 0 else { return }
            try Sockets.setDisposition(socket.object, UInt32(a[1]), UInt32(a[2]))
        default:
            throw .notSupported
        }
    }
}
