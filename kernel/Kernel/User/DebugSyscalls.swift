import CKernel

/// Debugging (K13g): process_read_memory (230), process_write_memory
/// (231), task_suspend (232; Zircon's task_suspend_token too). Zircon's
/// checks in its order (process.rs, task.rs). Writing another process's
/// memory needs `croi.debug_syscalls=on` (Zircon's
/// kernel.enable-debugging-syscalls; croi.test=1 implies it).
extension Syscalls {
    static var debuggingEnabled: Bool { BootOptions.has("croi.debug_syscalls=on") || BootOptions.has("croi.test=1") }

    static func debugCall(_ number: UInt64, _ a: InlineArray<6, UInt64>, _ table: borrowing HandleTable) throws(Status) {
        let handle = UInt32(truncatingIfNeeded: a[0])
        switch number {
        case 230, 231:  // process_read/write_memory(process, vaddr, buffer, buffer_size, size_t *actual)
            let write = number == 231
            if write { guard debuggingEnabled else { throw .notSupported } }
            guard a[2] != 0, a[3] > 0, a[3] <= 64 << 20 else { throw .invalidArgs }
            let process = try table.get(handle, type: .process, rights: write ? .write : .read | .write)
            if a[4] != 0 { try check(a[4], 8) }
            let moved = try Debug.transfer(process.object, address: a[1], buffer: a[2], size: a[3], write: write)
            if a[4] != 0 { try put(moved, a[4]) }
        case 232:  // task_suspend(task, out token)
            let task = try table.get(handle, rights: .write)
            try check(a[1], 4)
            let token = try Debug.suspend(task.object)
            let out: UInt32
            do throws(Status) {
                out = try table.add(token, rights: SuspendTokenObject.defaultRights)
            } catch {
                token.release()
                throw error
            }
            try put(out, a[1])
        default:
            throw .notSupported
        }
    }
}
