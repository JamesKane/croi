import CEFI
import Fmt

/// The firmware text console (`EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL`).
///
/// Text is converted to the NUL-terminated UCS-2 that `OutputString` expects
/// in small stack-buffered chunks. Only ASCII is passed through; other bytes
/// print as `?`. `\n` is expanded to `\r\n`. Unusable after ExitBootServices.
@safe struct Console: TextOutput {
    private let out: UnsafeMutablePointer<EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL>

    /// `out` must stay valid for the lifetime of the console, i.e. until
    /// ExitBootServices.
    @unsafe init(_ out: UnsafeMutablePointer<EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL>) {
        unsafe self.out = out
    }

    func write(utf8: Span<UInt8>) {
        // A fixed stack buffer: withTemporaryAllocation can fall back to the
        // heap, and the loader has none.
        var buffer = InlineArray<128, CHAR16>(repeating: 0)
        var count = 0
        for i in utf8.indices {
            let byte = utf8[i]
            if byte == UInt8(ascii: "\n") {
                buffer[count] = CHAR16(UInt8(ascii: "\r"))
                count += 1
            }
            buffer[count] = byte < 0x80 ? CHAR16(byte) : CHAR16(UInt8(ascii: "?"))
            count += 1
            if count >= buffer.count - 2 {
                flush(&buffer, &count)
            }
        }
        flush(&buffer, &count)
    }

    /// Sends the first `count` code units to firmware and empties the buffer.
    private func flush(_ buffer: inout InlineArray<128, CHAR16>, _ count: inout Int) {
        guard count > 0 else { return }
        buffer[count] = 0
        var span = buffer.mutableSpan
        span.withUnsafeMutableBufferPointer { codeUnits in
            _ = unsafe croi_efi_output_string(out, codeUnits.baseAddress!)
        }
        count = 0
    }
}
