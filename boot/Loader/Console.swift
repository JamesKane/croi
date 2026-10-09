import CEFI

/// The firmware text console (`EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL`).
///
/// Text is converted to the NUL-terminated UCS-2 that `OutputString` expects
/// in small stack-allocated chunks. Only ASCII is passed through; other bytes
/// print as `?`. `\n` is expanded to `\r\n`.
@safe struct Console {
    private let out: UnsafeMutablePointer<EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL>

    /// `out` must stay valid for the lifetime of the console, i.e. until
    /// ExitBootServices.
    @unsafe init(_ out: UnsafeMutablePointer<EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL>) {
        unsafe self.out = out
    }

    /// Code units per OutputString call, excluding the terminator.
    private static let chunk = 126

    func write(_ text: StaticString) {
        text.withUTF8Buffer { utf8 in
            withTemporaryAllocation(of: CHAR16.self, capacity: Self.chunk + 1) { buf in
                for unsafe byte in unsafe utf8 {
                    if byte == UInt8(ascii: "\n") {
                        buf.append(CHAR16(UInt8(ascii: "\r")))
                    }
                    buf.append(byte < 0x80 ? CHAR16(byte) : CHAR16(UInt8(ascii: "?")))
                    if buf.count >= Self.chunk - 1 {
                        flush(&buf)
                    }
                }
                flush(&buf)
            }
        }
    }

    /// Sends the buffered text to firmware and empties the buffer.
    private func flush(_ buf: inout OutputSpan<CHAR16>) {
        guard !buf.isEmpty else { return }
        buf.append(0)
        unsafe buf.withUnsafeMutableBufferPointer { codeUnits, _ in
            _ = unsafe croi_efi_output_string(out, codeUnits.baseAddress!)
        }
        buf.removeAll()
    }
}
