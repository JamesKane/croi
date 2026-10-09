/// Physical memory access while UEFI's identity mapping is active.

/// Runs `body` with a read-only view of `size` bytes at physical `address`.
/// The caller asserts the range is mapped and holds what it expects.
@unsafe func withPhysical<R, E: Error>(
    _ address: UInt64, size: Int, _ body: (RawSpan) throws(E) -> R
) throws(E) -> R {
    let span = unsafe RawSpan(_unsafeStart: UnsafeRawPointer(bitPattern: UInt(address))!, byteCount: size)
    return try body(span)
}

/// Runs `body` with a writable view of `size` bytes at physical `address`.
@unsafe func withPhysicalMutable<R, E: Error>(
    _ address: UInt64, size: Int, _ body: (inout MutableRawSpan) throws(E) -> R
) throws(E) -> R {
    var span = unsafe MutableRawSpan(
        _unsafeStart: UnsafeMutableRawPointer(bitPattern: UInt(address))!, byteCount: size)
    return try body(&span)
}

extension RawSpan {
    /// Bounds-checked little-endian load that reports failure instead of trapping.
    func read<T: FixedWidthInteger & ConvertibleFromBytes>(
        _: T.Type, at offset: UInt64, else error: LoaderError
    ) throws(LoaderError) -> T {
        guard offset <= UInt64(byteCount), UInt64(byteCount) - offset >= UInt64(MemoryLayout<T>.size) else {
            throw error
        }
        return T(littleEndian: load(fromByteOffset: Int(offset), as: T.self))
    }
}

func roundUp(_ value: UInt64, to alignment: UInt64) -> UInt64 {
    (value + alignment - 1) & ~(alignment - 1)
}
