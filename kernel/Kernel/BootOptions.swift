import CHandoff
import Fmt

/// The kernel command line (`\croi\cmdline`), copied out of the handoff
/// before the PMM reclaims it. ASCII; at most `capacity` bytes are kept.
enum BootOptions {
    static var capacity: Int { 1024 }

    nonisolated(unsafe) private static var storage = InlineArray<1024, UInt8>(repeating: 0)
    nonisolated(unsafe) private(set) static var length = 0

    /// Copies the command line from the handoff (still physmap-reachable).
    static func capture(_ handoff: croi_handoff_t) {
        guard handoff.cmdline != 0 else { return }
        let count = min(Int(handoff.cmdline_size), capacity)
        let bytes = unsafe UnsafePointer<UInt8>(bitPattern: UInt(KernelLayout.physmap(handoff.cmdline)))!
        for i in 0..<count {
            let byte = unsafe bytes[i]
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") || byte == 0 { break }
            storage[i] = byte
            length = i + 1
        }
    }

    static func write(to out: some TextOutput) {
        out.write(utf8: storage.span.extracting(0..<length))
    }
}
