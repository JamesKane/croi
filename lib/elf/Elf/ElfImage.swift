/// An ELF64 image for this architecture, little endian, as croi loads
/// them: the loader (the kernel, a static PIE), the kernel (userboot, a
/// static executable) and userboot (programs from bootfs). Page-aligned
/// PT_LOAD segments, sorted and not overlapping, never writable and
/// executable; static PIEs may carry R_*_RELATIVE relocations only.
/// Parsing reads only through bounds-checked loads.
public struct ElfImage {
    public enum Kind: UInt16 {
        case executable = 2  // ET_EXEC: runs at its link address
        case pie = 3         // ET_DYN: a static PIE
    }

    public struct Segment {
        public var offset: UInt64 = 0
        public var vaddr: UInt64 = 0
        public var filesz: UInt64 = 0
        public var memsz: UInt64 = 0
        public var flags: UInt32 = 0

        public init() {}

        public var readable: Bool { flags & 4 != 0 }
        public var writable: Bool { flags & 2 != 0 }
        public var executable: Bool { flags & 1 != 0 }
    }

    public struct Error: Swift.Error {
        public let reason: StaticString

        public init(_ reason: StaticString) {
            self.reason = reason
        }
    }

    #if arch(x86_64)
    static var machine: UInt16 { 62 }
    static var relativeRelocation: UInt32 { 8 }
    #elseif arch(arm64)
    static var machine: UInt16 { 183 }
    static var relativeRelocation: UInt32 { 1027 }
    #elseif arch(riscv64)
    static var machine: UInt16 { 243 }
    static var relativeRelocation: UInt32 { 3 }
    #endif

    public static var pageSize: UInt64 { 4096 }

    public let kind: Kind
    /// Entry point (link-time virtual address).
    public private(set) var entry: UInt64 = 0
    /// Lowest PT_LOAD address: where the image is linked to run.
    public private(set) var base: UInt64 = 0
    /// Bytes from `base` to the end of the last segment, page rounded.
    public private(set) var size: UInt64 = 0
    public private(set) var segments = InlineArray<8, Segment>(repeating: Segment())
    public private(set) var segmentCount = 0
    /// PT_GNU_STACK's size, if the link set one (`-z stack-size=`).
    public private(set) var stackSize: UInt64?
    /// PT_DYNAMIC address, if any.
    private var dynamic: UInt64?

    public init(parsing file: RawSpan) throws(Error) {
        let truncated = Error("truncated ELF header")
        guard try file.elfRead(UInt32.self, at: 0, else: truncated) == 0x464C_457F,  // "\x7fELF"
              try file.elfRead(UInt8.self, at: 4, else: truncated) == 2,              // ELFCLASS64
              try file.elfRead(UInt8.self, at: 5, else: truncated) == 1               // little endian
        else { throw Error("not an ELF64 little-endian file") }
        guard let kind = Kind(rawValue: try file.elfRead(UInt16.self, at: 16, else: truncated)) else {
            throw Error("neither an executable nor a static PIE")
        }
        self.kind = kind
        guard try file.elfRead(UInt16.self, at: 18, else: truncated) == Self.machine else {
            throw Error("built for another architecture")
        }
        entry = try file.elfRead(UInt64.self, at: 24, else: truncated)
        let phoff = try file.elfRead(UInt64.self, at: 32, else: truncated)
        let phentsize = UInt64(try file.elfRead(UInt16.self, at: 54, else: truncated))
        let phnum = UInt64(try file.elfRead(UInt16.self, at: 56, else: truncated))
        guard phentsize >= 56 else { throw Error("program headers too small") }

        let badPhdr = Error("program header out of bounds")
        var end: UInt64 = 0
        for i in 0..<phnum {
            let ph = phoff &+ i &* phentsize
            let type = try file.elfRead(UInt32.self, at: ph, else: badPhdr)
            if type == 2 {  // PT_DYNAMIC
                dynamic = try file.elfRead(UInt64.self, at: ph + 16, else: badPhdr)
            }
            if type == 0x6474_E551 {  // PT_GNU_STACK
                let size = try file.elfRead(UInt64.self, at: ph + 40, else: badPhdr)
                if size != 0 { stackSize = size }
            }
            guard type == 1 else { continue }  // PT_LOAD

            var segment = Segment()
            segment.flags = try file.elfRead(UInt32.self, at: ph + 4, else: badPhdr)
            segment.offset = try file.elfRead(UInt64.self, at: ph + 8, else: badPhdr)
            segment.vaddr = try file.elfRead(UInt64.self, at: ph + 16, else: badPhdr)
            segment.filesz = try file.elfRead(UInt64.self, at: ph + 32, else: badPhdr)
            segment.memsz = try file.elfRead(UInt64.self, at: ph + 40, else: badPhdr)

            guard segment.vaddr % Self.pageSize == 0, segment.offset % Self.pageSize == 0 else {
                throw Error("PT_LOAD not page aligned")
            }
            guard segment.filesz <= segment.memsz,
                  segment.offset <= UInt64(file.byteCount),
                  segment.filesz <= UInt64(file.byteCount) - segment.offset
            else { throw Error("PT_LOAD outside the file") }
            guard !segment.executable || !segment.writable else {
                throw Error("PT_LOAD is writable and executable")
            }
            if segmentCount == 0 {
                base = segment.vaddr
            } else if segment.vaddr < end {
                throw Error("PT_LOAD segments overlap or are unsorted")
            }
            guard segmentCount < segments.count else { throw Error("too many PT_LOAD segments") }
            segments[segmentCount] = segment
            segmentCount += 1
            end = segment.vaddr &+ segment.memsz
            guard end > segment.vaddr || segment.memsz == 0 else { throw Error("PT_LOAD wraps") }
            guard end <= UInt64.max - Self.pageSize else { throw Error("PT_LOAD wraps") }
        }
        guard segmentCount > 0 else { throw Error("no PT_LOAD segments") }
        guard entry >= base, entry < end else { throw Error("entry point outside the image") }
        size = (end - base + Self.pageSize - 1) & ~(Self.pageSize - 1)
    }

    /// Copies the segments into `image` (zeroed, `size` bytes) and applies
    /// relocations for running at virtual address `runAddress`.
    public func load(from file: RawSpan, into image: inout MutableRawSpan, runningAt runAddress: UInt64) throws(Error) {
        guard UInt64(image.byteCount) >= size else { throw Error("image buffer too small") }
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

    private func relocate(_ image: inout MutableRawSpan, runAddress: UInt64) throws(Error) {
        guard let dynamic else { return }
        guard kind == .pie else { throw Error("an executable with a dynamic section") }
        let bad = Error("bad dynamic section")

        var rela: UInt64?
        var relaSize: UInt64 = 0
        var relaEntry: UInt64 = 24
        guard dynamic >= base else { throw bad }
        var offset = dynamic - base
        while true {
            let tag = try image.bytes.elfRead(UInt64.self, at: offset, else: bad)
            let value = try image.bytes.elfRead(UInt64.self, at: offset + 8, else: bad)
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
        guard rela >= base else { throw bad }

        let badReloc = Error("relocation out of bounds")
        var entryOffset = rela - base
        let end = entryOffset &+ relaSize
        while entryOffset < end {
            let target = try image.bytes.elfRead(UInt64.self, at: entryOffset, else: badReloc)
            let info = try image.bytes.elfRead(UInt64.self, at: entryOffset + 8, else: badReloc)
            let addend = try image.bytes.elfRead(UInt64.self, at: entryOffset + 16, else: badReloc)
            entryOffset += relaEntry

            let type = UInt32(truncatingIfNeeded: info)
            if type == 0 { continue }
            guard type == Self.relativeRelocation else { throw Error("unsupported relocation type") }
            guard target >= base, target - base <= size - 8 else { throw badReloc }
            image.storeBytes(of: (runAddress &- base &+ addend).littleEndian,
                             toByteOffset: Int(target - base), as: UInt64.self)
        }
    }
}

extension RawSpan {
    /// Bounds-checked little-endian load that reports failure instead of trapping.
    public func elfRead<T: FixedWidthInteger & ConvertibleFromBytes>(
        _: T.Type, at offset: UInt64, else error: ElfImage.Error
    ) throws(ElfImage.Error) -> T {
        guard offset <= UInt64(byteCount), UInt64(byteCount) - offset >= UInt64(MemoryLayout<T>.size) else {
            throw error
        }
        return T(littleEndian: load(fromByteOffset: Int(offset), as: T.self))
    }
}
