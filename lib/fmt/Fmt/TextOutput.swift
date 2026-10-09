/// A sink for console text: the loader's firmware console, the kernel UART.
///
/// Conformers implement `write(utf8:)`; everything else is built on it
/// without allocating. Generic helpers are `@inlinable` so Embedded Swift
/// can specialize them in the client module.
public protocol TextOutput {
    func write(utf8: Span<UInt8>)
}

extension TextOutput {
    @inlinable
    public func write(_ text: StaticString) {
        let count = text.utf8CodeUnitCount
        let span = unsafe Span(_unsafeStart: text.utf8Start, count: count)
        write(utf8: span)
    }

    /// `0x`-prefixed lowercase hex with no leading zeros.
    @inlinable
    public func write(hex value: UInt64) {
        var digits = InlineArray<18, UInt8>(repeating: 0)
        var n = 18
        var v = value
        repeat {
            n -= 1
            let d = UInt8(truncatingIfNeeded: v & 0xF)
            digits[n] = d < 10 ? UInt8(ascii: "0") + d : UInt8(ascii: "a") + d - 10
            v >>= 4
        } while v != 0
        n -= 2
        digits[n] = UInt8(ascii: "0")
        digits[n + 1] = UInt8(ascii: "x")
        write(utf8: digits.span.extracting(n...))
    }

    @inlinable
    public func write(decimal value: UInt64) {
        var digits = InlineArray<20, UInt8>(repeating: 0)
        var n = 20
        var v = value
        repeat {
            n -= 1
            digits[n] = UInt8(ascii: "0") + UInt8(truncatingIfNeeded: v % 10)
            v /= 10
        } while v != 0
        write(utf8: digits.span.extracting(n...))
    }
}
