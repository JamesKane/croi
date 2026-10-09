import CEFI

/// The kernel file read into loader pool memory.
@unsafe struct KernelFile {
    let buffer: UnsafeMutableRawPointer
    let size: Int
}

/// Reads `\croi\kernel.elf` from the volume the loader itself was loaded from.
func readKernelFile(image: EFI_HANDLE?, boot: BootServices) throws(LoaderError) -> KernelFile {
    guard let image = unsafe image else { throw .unsupported("no loader image handle", 0) }
    let loaded = try unsafe boot.handleProtocol(.loadedImage, on: image, as: EFI_LOADED_IMAGE_PROTOCOL.self)
    guard let device = unsafe loaded.pointee.DeviceHandle else {
        throw .unsupported("loader image has no device handle", 0)
    }
    let fs = try unsafe boot.handleProtocol(.simpleFileSystem, on: device, as: EFI_SIMPLE_FILE_SYSTEM_PROTOCOL.self)

    var root: UnsafeMutablePointer<EFI_FILE_PROTOCOL>? = nil
    var status = unsafe croi_efi_open_volume(fs, &root)
    guard status == EFI_SUCCESS, let root = unsafe root else { throw .firmware("OpenVolume", status) }
    defer { _ = unsafe croi_efi_file_close(root) }

    var file: UnsafeMutablePointer<EFI_FILE_PROTOCOL>? = nil
    status = unsafe withUCS2("\\croi\\kernel.elf") { path in unsafe croi_efi_file_open(root, &file, path) }
    guard status == EFI_SUCCESS, let file = unsafe file else { throw .firmware("open \\croi\\kernel.elf", status) }
    defer { _ = unsafe croi_efi_file_close(file) }

    var size: UInt64 = 0
    status = unsafe croi_efi_file_size(file, &size)
    guard status == EFI_SUCCESS else { throw .firmware("kernel.elf size", status) }
    guard size > 0, size < 1 << 30 else { throw .kernel("unreasonable file size") }

    let buffer = try unsafe boot.allocatePool(Int(size))
    var done: UInt64 = 0
    while done < size {
        var chunk = UInt(size - done)
        status = unsafe croi_efi_file_read(file, &chunk, buffer + Int(done))
        guard status == EFI_SUCCESS, chunk > 0 else {
            unsafe boot.freePool(buffer)
            throw .firmware("read kernel.elf", status)
        }
        done += UInt64(chunk)
    }
    return unsafe KernelFile(buffer: buffer, size: Int(size))
}

/// Calls `body` with `text` as a NUL-terminated UCS-2 string. ASCII only,
/// at most 63 characters (a stack buffer: the loader has no heap).
func withUCS2<R>(_ text: StaticString, _ body: (UnsafeMutablePointer<CHAR16>) -> R) -> R {
    var buffer = InlineArray<64, CHAR16>(repeating: 0)
    precondition(text.utf8CodeUnitCount < buffer.count)
    text.withUTF8Buffer { utf8 in
        for i in 0..<utf8.count {
            buffer[i] = CHAR16(unsafe utf8[i])
        }
    }
    var span = buffer.mutableSpan
    return span.withUnsafeMutableBufferPointer { unsafe body($0.baseAddress!) }
}
