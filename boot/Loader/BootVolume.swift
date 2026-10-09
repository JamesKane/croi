import CEFI

/// The volume the loader was started from (the ESP), for reading croi's
/// files: `\croi\kernel.elf`, `\croi\bootfs.img`, `\croi\cmdline`.
///
/// Dropping it closes the volume through firmware, so it must be consumed
/// before ExitBootServices.
@safe struct BootVolume: ~Copyable {
    private let boot: BootServices
    private let root: UnsafeMutablePointer<EFI_FILE_PROTOCOL>

    init(image: EFI_HANDLE?, boot: BootServices) throws(LoaderError) {
        guard let image = unsafe image else { throw .unsupported("no loader image handle", 0) }
        let loaded = try unsafe boot.handleProtocol(.loadedImage, on: image, as: EFI_LOADED_IMAGE_PROTOCOL.self)
        guard let device = unsafe loaded.pointee.DeviceHandle else {
            throw .unsupported("loader image has no device handle", 0)
        }
        let fs = try unsafe boot.handleProtocol(.simpleFileSystem, on: device, as: EFI_SIMPLE_FILE_SYSTEM_PROTOCOL.self)
        var root: UnsafeMutablePointer<EFI_FILE_PROTOCOL>? = nil
        let status = unsafe croi_efi_open_volume(fs, &root)
        guard status == EFI_SUCCESS, let root = unsafe root else { throw .firmware("OpenVolume", status) }
        self.boot = boot
        unsafe self.root = root
    }

    deinit {
        _ = unsafe croi_efi_file_close(root)
    }

    /// Reads `path` into memory from `allocate(size)`, which must return at
    /// least `size` bytes. Returns nil if the file doesn't exist.
    func read(
        _ path: StaticString, allocate: (Int) throws(LoaderError) -> UnsafeMutableRawPointer
    ) throws(LoaderError) -> (buffer: UnsafeMutableRawPointer, size: Int)? {
        var file: UnsafeMutablePointer<EFI_FILE_PROTOCOL>? = nil
        var status = unsafe withUCS2(path) { name in unsafe croi_efi_file_open(root, &file, name) }
        if status == EFI_NOT_FOUND { return nil }
        guard status == EFI_SUCCESS, let file = unsafe file else { throw .firmware("open file", status) }
        defer { _ = unsafe croi_efi_file_close(file) }

        var size: UInt64 = 0
        status = unsafe croi_efi_file_size(file, &size)
        guard status == EFI_SUCCESS else { throw .firmware("file size", status) }
        guard size < 1 << 32 else { throw .unsupported("file too large", size) }

        let buffer = try unsafe allocate(max(Int(size), 1))
        var done: UInt64 = 0
        while done < size {
            var chunk = UInt(size - done)
            status = unsafe croi_efi_file_read(file, &chunk, buffer + Int(done))
            guard status == EFI_SUCCESS, chunk > 0 else { throw .firmware("read file", status) }
            done += UInt64(chunk)
        }
        return unsafe (buffer, Int(size))
    }

    /// Reads `path` into loader pool memory (freed with `freePool`).
    func readIntoPool(_ path: StaticString) throws(LoaderError) -> (buffer: UnsafeMutableRawPointer, size: Int)? {
        try unsafe read(path) { (size: Int) throws(LoaderError) in try unsafe boot.allocatePool(size) }
    }

    /// Reads `path` into fresh pages of memory type `type`.
    func readIntoPages(_ path: StaticString, type: EFI_MEMORY_TYPE) throws(LoaderError) -> (phys: UInt64, size: Int)? {
        let result = try unsafe read(path) { (size: Int) throws(LoaderError) in
            let pages = (UInt64(size) + pageSize - 1) / pageSize
            return unsafe UnsafeMutableRawPointer(bitPattern: UInt(try boot.allocatePages(pages, type: type)))!
        }
        guard let result = unsafe result else { return nil }
        return unsafe (UInt64(UInt(bitPattern: result.buffer)), result.size)
    }
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
