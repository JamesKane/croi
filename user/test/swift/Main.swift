import CroiRuntime

/// The K8a boot self-test's Embedded Swift program: runs on the user
/// runtime from an ELF the kernel loads, prints over the debuglog it was
/// handed as stdout, and grows a heap through its root VMAR. The kernel
/// reads its records back and checks the exit code.
@main
struct SwiftTest {
    static func main() {
        print("swift: hello from user mode")

        // The heap: small blocks (size classes), then one too big for them.
        var squares: [Int] = []
        for i in 0..<1000 { squares.append(i * i) }
        var sum = 0
        for square in squares { sum += square }
        print("swift: \(squares.count) squares, sum \(sum)")
        let big = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 4096)
        unsafe big.initializeMemory(as: UInt8.self, repeating: 0xA5)
        let aligned = UInt(bitPattern: big.baseAddress) % 4096 == 0
        let last = unsafe big[64 * 1024 - 1]
        unsafe big.deallocate()

        // The environment from the bootstrap message.
        for i in 0..<croi_environ_count() {
            guard let entry = unsafe croi_environ(i) else { continue }
            print("swift: env \(unsafe String(cString: entry))")
        }

        let handles = croi_process_self() != 0 && croi_vmar_root_self() != 0 && croi_vdso_base() != 0
        let log = debuglogRoundTrip()
        croi_exit(sum == 332_833_500 && aligned && last == 0xA5 && handles && log ? 0x600D : 1)
    }

    /// debuglog_create/write/read from user mode: a write-only log needs no
    /// resource, a readable one does (the root resource, handed over for
    /// this test); a record written through one comes back through the
    /// other, READABLE until it has been read.
    static func debuglogRoundTrip() -> Bool {
        let resource = croi_take_startup_handle(croi_pa_hnd(UInt32(CROI_PA_RESOURCE), 0))
        var writer: UInt32 = 0
        var reader: UInt32 = 0
        guard syscall(CROI_SYS_DEBUGLOG_CREATE, 0, 0, address(&writer)) == 0,
              syscall(CROI_SYS_DEBUGLOG_CREATE, 0, UInt64(CROI_LOG_FLAG_READABLE), address(&reader)) == -11,  // BAD_HANDLE
              syscall(CROI_SYS_DEBUGLOG_CREATE, UInt64(resource), UInt64(CROI_LOG_FLAG_READABLE),
                      address(&reader)) == 0 else { return false }
        var record = InlineArray<256, UInt8>(repeating: 0)
        var buffer = record.mutableSpan
        let at = buffer.withUnsafeMutableBytes { UInt64(UInt(bitPattern: $0.baseAddress)) }
        // A write-only handle can't read (no READ right); the reader starts
        // at the oldest record, so drain it first.
        guard syscall(CROI_SYS_DEBUGLOG_READ, UInt64(writer), 0, at, 256) == -30 else { return false }  // ACCESS_DENIED
        while syscall(CROI_SYS_DEBUGLOG_READ, UInt64(reader), 0, at, 256) > 0 {}
        var observed: UInt32 = 0
        guard syscall(CROI_SYS_OBJECT_WAIT_ONE, UInt64(reader), UInt64(CROI_SIGNAL_READABLE), 0,
                      address(&observed)) == -21 else { return false }  // TIMED_OUT: nothing to read
        let text: StaticString = "swift: round trip"
        let textAddress = unsafe UInt64(UInt(bitPattern: text.utf8Start))
        guard syscall(CROI_SYS_DEBUGLOG_WRITE, UInt64(writer), 0, textAddress, UInt64(text.utf8CodeUnitCount)) == 0,
              syscall(CROI_SYS_OBJECT_WAIT_ONE, UInt64(reader), UInt64(CROI_SIGNAL_READABLE), .max,
                      address(&observed)) == 0 else { return false }
        let size = syscall(CROI_SYS_DEBUGLOG_READ, UInt64(reader), 0, at, 256)
        let headerSize = MemoryLayout<croi_log_record_t>.size
        guard size == Int64(headerSize + text.utf8CodeUnitCount) else { return false }
        let header = unsafe record.span.bytes.unsafeLoadUnaligned(as: croi_log_record_t.self)
        for i in 0..<text.utf8CodeUnitCount where unsafe record[headerSize + i] != text.utf8Start[i] {
            return false
        }
        let caughtUp = syscall(CROI_SYS_DEBUGLOG_READ, UInt64(reader), 0, at, 256) == -22  // SHOULD_WAIT
        for handle in [writer, reader, resource] { _ = syscall(CROI_SYS_HANDLE_CLOSE, UInt64(handle)) }
        return header.datalen == UInt16(text.utf8CodeUnitCount) && header.severity == UInt8(CROI_LOG_INFO)
            && header.pid != 0 && header.tid != 0 && caughtUp
    }

    static func syscall(_ number: UInt64, _ a0: UInt64 = 0, _ a1: UInt64 = 0, _ a2: UInt64 = 0,
                        _ a3: UInt64 = 0) -> Int64 {
        croi_syscall(number, a0, a1, a2, a3, 0)
    }

    static func address<T>(_ value: inout T) -> UInt64 {
        withUnsafeMutablePointer(to: &value) { UInt64(UInt(bitPattern: $0)) }
    }
}
