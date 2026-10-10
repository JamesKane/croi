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

    /// Whether the command line has this space-separated word.
    static func has(_ word: StaticString) -> Bool {
        let wanted = unsafe Span<UInt8>(_unsafeStart: word.utf8Start, count: word.utf8CodeUnitCount)
        var start = 0
        while start < length {
            var end = start
            while end < length, storage[end] != UInt8(ascii: " ") { end += 1 }
            if end - start == wanted.count {
                var same = true
                for i in 0..<wanted.count where storage[start + i] != wanted[i] { same = false }
                if same { return true }
            }
            start = end + 1
        }
        return false
    }

    /// The decimal number in a `prefix<digits>` word (e.g.
    /// "croi.contiguous_pool=" in "croi.contiguous_pool=16"), if present.
    static func number(after prefix: StaticString) -> UInt64? {
        let wanted = unsafe Span<UInt8>(_unsafeStart: prefix.utf8Start, count: prefix.utf8CodeUnitCount)
        var start = 0
        while start < length {
            var end = start
            while end < length, storage[end] != UInt8(ascii: " ") { end += 1 }
            if end - start > wanted.count {
                var same = true
                for i in 0..<wanted.count where storage[start + i] != wanted[i] { same = false }
                if same {
                    var value: UInt64 = 0
                    for i in (start + wanted.count)..<end {
                        let digit = storage[i] &- UInt8(ascii: "0")
                        guard digit < 10 else { return nil }
                        value = value * 10 + UInt64(digit)
                    }
                    return value
                }
            }
            start = end + 1
        }
        return nil
    }

    /// The command line's words as NUL-terminated strings, one after
    /// another (userboot's environment, K8b).
    static func withEnvironment<R, E: Error>(_ body: (Span<UInt8>) throws(E) -> R) throws(E) -> R {
        var words = InlineArray<1025, UInt8>(repeating: 0)
        var count = 0
        var inWord = false
        for i in 0..<length {
            if storage[i] == UInt8(ascii: " ") {
                if inWord { count += 1 }  // the NUL already there
                inWord = false
            } else {
                words[count] = storage[i]
                count += 1
                inWord = true
            }
        }
        if inWord { count += 1 }
        return try body(words.span.extracting(0..<count))
    }

    static func write(to out: some TextOutput) {
        out.write(utf8: storage.span.extracting(0..<length))
    }
}
