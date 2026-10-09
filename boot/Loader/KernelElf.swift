/// The kernel's ELF image: a little-endian ELF64 static PIE for this
/// architecture, with page-aligned PT_LOAD segments (see ld/image.ld) and
/// only R_*_RELATIVE dynamic relocations.
struct KernelElf {
    struct Segment {
        var offset: UInt64 = 0
        var vaddr: UInt64 = 0
        var filesz: UInt64 = 0
        var memsz: UInt64 = 0
        var flags: UInt32 = 0

        var executable: Bool { flags & 1 != 0 }
        var writable: Bool { flags & 2 != 0 }
    }

    #if arch(x86_64)
    static let machine: UInt16 = 62
    static let relativeRelocation: UInt32 = 8
    #elseif arch(arm64)
    static let machine: UInt16 = 183
    static let relativeRelocation: UInt32 = 1027
    #elseif arch(riscv64)
    static let machine: UInt16 = 243
    static let relativeRelocation: UInt32 = 3
    #endif

    /// Entry point (link-time virtual address).
    private(set) var entry: UInt64 = 0
    /// Lowest PT_LOAD address: where the image is linked to run.
    private(set) var base: UInt64 = 0
    /// Bytes from `base` to the end of the last segment, page rounded.
    private(set) var size: UInt64 = 0
    private(set) var segments = InlineArray<8, Segment>(repeating: Segment())
    private(set) var segmentCount = 0
    /// PT_DYNAMIC address, if any.
    private var dynamic: UInt64?

    init(parsing file: RawSpan) throws(LoaderError) {
        let truncated = LoaderError.kernel("truncated ELF header")
        guard try file.read(UInt32.self, at: 0, else: truncated) == 0x464C_457F,  // "\x7fELF"
              try file.read(UInt8.self, at: 4, else: truncated) == 2,              // ELFCLASS64
              try file.read(UInt8.self, at: 5, else: truncated) == 1               // little endian
        else { throw .kernel("not an ELF64 little-endian file") }
        guard try file.read(UInt16.self, at: 16, else: truncated) == 3 else {
            throw .kernel("not a static PIE (ET_DYN)")
        }
        guard try file.read(UInt16.self, at: 18, else: truncated) == Self.machine else {
            throw .kernel("built for another architecture")
        }
        entry = try file.read(UInt64.self, at: 24, else: truncated)
        let phoff = try file.read(UInt64.self, at: 32, else: truncated)
        let phentsize = UInt64(try file.read(UInt16.self, at: 54, else: truncated))
        let phnum = UInt64(try file.read(UInt16.self, at: 56, else: truncated))

        let badPhdr = LoaderError.kernel("program header out of bounds")
        var end: UInt64 = 0
        for i in 0..<phnum {
            let ph = phoff + i * phentsize
            let type = try file.read(UInt32.self, at: ph, else: badPhdr)
            if type == 2 {  // PT_DYNAMIC
                dynamic = try file.read(UInt64.self, at: ph + 16, else: badPhdr)
            }
            guard type == 1 else { continue }  // PT_LOAD

            var segment = Segment()
            segment.flags = try file.read(UInt32.self, at: ph + 4, else: badPhdr)
            segment.offset = try file.read(UInt64.self, at: ph + 8, else: badPhdr)
            segment.vaddr = try file.read(UInt64.self, at: ph + 16, else: badPhdr)
            segment.filesz = try file.read(UInt64.self, at: ph + 32, else: badPhdr)
            segment.memsz = try file.read(UInt64.self, at: ph + 40, else: badPhdr)

            guard segment.vaddr % pageSize == 0 else { throw .kernel("PT_LOAD not page aligned") }
            guard segment.filesz <= segment.memsz,
                  segment.offset <= UInt64(file.byteCount),
                  segment.filesz <= UInt64(file.byteCount) - segment.offset
            else { throw .kernel("PT_LOAD outside the file") }
            guard segment.executable == false || segment.writable == false else {
                throw .kernel("PT_LOAD is writable and executable")
            }
            if segmentCount == 0 {
                base = segment.vaddr
            } else if segment.vaddr < end {
                throw .kernel("PT_LOAD segments overlap or are unsorted")
            }
            guard segmentCount < segments.count else { throw .kernel("too many PT_LOAD segments") }
            segments[segmentCount] = segment
            segmentCount += 1
            end = segment.vaddr &+ segment.memsz
            guard end > segment.vaddr || segment.memsz == 0 else { throw .kernel("PT_LOAD wraps") }
        }
        guard segmentCount > 0 else { throw .kernel("no PT_LOAD segments") }
        guard entry >= base, entry < end else { throw .kernel("entry point outside the image") }
        size = roundUp(end - base, to: pageSize)
    }

    /// Copies the segments into `image` (zeroed, `size` bytes) and applies
    /// relocations for running at virtual address `runAddress`.
    func load(from file: RawSpan, into image: inout MutableRawSpan, runningAt runAddress: UInt64) throws(LoaderError) {
        for i in 0..<segmentCount {
            let segment = segments[i]
            let destination = Int(segment.vaddr - base)
            image.withUnsafeMutableBytes { dst in
                file.withUnsafeBytes { src in
                    unsafe (dst.baseAddress! + destination).copyMemory(
                        from: src.baseAddress! + Int(segment.offset), byteCount: Int(segment.filesz))
                }
            }
        }
        try relocate(&image, runAddress: runAddress)
    }

    private func relocate(_ image: inout MutableRawSpan, runAddress: UInt64) throws(LoaderError) {
        guard let dynamic else { return }
        let bad = LoaderError.kernel("bad dynamic section")

        var rela: UInt64?
        var relaSize: UInt64 = 0
        var relaEntry: UInt64 = 24
        var offset = dynamic - base
        while true {
            let tag = try image.bytes.read(UInt64.self, at: offset, else: bad)
            let value = try image.bytes.read(UInt64.self, at: offset + 8, else: bad)
            switch tag {
            case 0: break               // DT_NULL
            case 7: rela = value        // DT_RELA
            case 8: relaSize = value    // DT_RELASZ
            case 9: relaEntry = value   // DT_RELAENT
            default: ()
            }
            if tag == 0 { break }
            offset += 16
        }
        guard let rela, relaEntry >= 24 else { return }

        let badReloc = LoaderError.kernel("relocation out of bounds")
        var entryOffset = rela - base
        let end = entryOffset + relaSize
        while entryOffset < end {
            let target = try image.bytes.read(UInt64.self, at: entryOffset, else: badReloc)
            let info = try image.bytes.read(UInt64.self, at: entryOffset + 8, else: badReloc)
            let addend = try image.bytes.read(UInt64.self, at: entryOffset + 16, else: badReloc)
            entryOffset += relaEntry

            let type = UInt32(truncatingIfNeeded: info)
            if type == 0 { continue }
            guard type == Self.relativeRelocation else { throw .kernel("unsupported relocation type") }
            guard target >= base, target - base <= size - 8 else { throw badReloc }
            image.storeBytes(of: (runAddress &- base &+ addend).littleEndian,
                             toByteOffset: Int(target - base), as: UInt64.self)
        }
    }
}
