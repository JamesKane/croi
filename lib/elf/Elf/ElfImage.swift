/// An ELF64 image for this architecture, little endian, as croi loads
/// them: the loader (the kernel, a static PIE), the kernel (userboot, a
/// static executable) and userboot (programs from bootfs). Page-aligned
/// PT_LOAD segments, sorted and not overlapping, never writable and
/// executable; static PIEs may carry R_*_RELATIVE relocations only.
/// PT_GNU_RELRO must lie in one writable PT_LOAD; loaders make its pages
/// read only once they have written the relocations. Parsing reads only
/// through bounds-checked loads.
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
    /// PT_GNU_RELRO's pages (link-time addresses, page aligned): read
    /// only once relocated. Both ends rounded down to a page, glibc's rule
    /// (the start is the segment's in what lld makes, the end padded to a
    /// page); nil if there is none or it rounds to nothing.
    public private(set) var relro: (start: UInt64, end: UInt64)?
    /// arm64 (K14r): the GNU property note (PT_GNU_PROPERTY) says every
    /// object was built with BTI landing pads (GNU_PROPERTY_AARCH64_FEATURE_1_AND,
    /// bit 0), so loaders map its executable segments guarded.
    public private(set) var branchTargets = false
    /// PT_DYNAMIC address, if any.
    private var dynamic: UInt64?

    /// Whether the property notes in [offset, +length) set the AArch64 BTI
    /// feature: NT_GNU_PROPERTY_TYPE_0 notes named "GNU", whose properties
    /// (type, size, data padded to 8) include FEATURE_1_AND with bit 0. A
    /// malformed note is an error; another architecture's: false.
    private static func propertyHasBti(_ file: RawSpan, _ offset: UInt64, _ length: UInt64) throws(Error) -> Bool {
        #if arch(arm64)
        let bad = Error("GNU property note out of bounds")
        guard offset <= UInt64(file.byteCount), length <= UInt64(file.byteCount) - offset else { throw bad }
        var at = offset
        let end = offset + length
        var bti = false
        while at + 12 <= end {
            let nameSize = UInt64(try file.elfRead(UInt32.self, at: at, else: bad))
            let descSize = UInt64(try file.elfRead(UInt32.self, at: at + 4, else: bad))
            let type = try file.elfRead(UInt32.self, at: at + 8, else: bad)
            let desc = at + 12 + ((nameSize + 3) & ~3)
            guard desc <= end, descSize <= end - desc else { throw bad }
            if type == 5, nameSize == 4, try file.elfRead(UInt32.self, at: at + 12, else: bad) == 0x0055_4E47 {  // "GNU\0"
                var p = desc
                while p + 8 <= desc + descSize {
                    let propertyType = try file.elfRead(UInt32.self, at: p, else: bad)
                    let dataSize = UInt64(try file.elfRead(UInt32.self, at: p + 4, else: bad))
                    guard dataSize <= desc + descSize - (p + 8) else { throw bad }
                    if propertyType == 0xC000_0000, dataSize >= 4,  // GNU_PROPERTY_AARCH64_FEATURE_1_AND
                       try file.elfRead(UInt32.self, at: p + 8, else: bad) & 1 != 0 {
                        bti = true
                    }
                    p += 8 + ((dataSize + 7) & ~7)
                }
            }
            at = desc + ((descSize + 7) & ~7)
        }
        return bti
        #else
        return false
        #endif
    }

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
        var relroRange: (vaddr: UInt64, memsz: UInt64)?
        for i in 0..<phnum {
            let ph = phoff &+ i &* phentsize
            let type = try file.elfRead(UInt32.self, at: ph, else: badPhdr)
            if type == 2 {  // PT_DYNAMIC
                dynamic = try file.elfRead(UInt64.self, at: ph + 16, else: badPhdr)
            }
            if type == 0x6474_E551 {  // PT_GNU_STACK
                let size = try file.elfRead(UInt64.self, at: ph + 40, else: badPhdr)
                // Bounded, so loaders can round it up (review fix: a size
                // near 2^64 trapped there).
                guard size <= 256 << 20 else { throw Error("PT_GNU_STACK larger than 256 MiB") }
                if size != 0 { stackSize = size }
            }
            if type == 0x6474_E553 {  // PT_GNU_PROPERTY
                let offset = try file.elfRead(UInt64.self, at: ph + 8, else: badPhdr)
                let length = try file.elfRead(UInt64.self, at: ph + 32, else: badPhdr)
                branchTargets = try Self.propertyHasBti(file, offset, length)
            }
            if type == 0x6474_E552 {  // PT_GNU_RELRO
                guard relroRange == nil else { throw Error("two PT_GNU_RELRO headers") }
                relroRange = (try file.elfRead(UInt64.self, at: ph + 16, else: badPhdr),
                              try file.elfRead(UInt64.self, at: ph + 40, else: badPhdr))
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
        if let (vaddr, memsz) = relroRange, memsz > 0 {
            var inside = false
            for i in 0..<segmentCount where segments[i].writable && vaddr >= segments[i].vaddr
                && vaddr - segments[i].vaddr <= segments[i].memsz && memsz <= segments[i].memsz - (vaddr - segments[i].vaddr) {
                inside = true
            }
            guard inside else { throw Error("PT_GNU_RELRO outside a writable PT_LOAD") }
            let start = vaddr & ~(Self.pageSize - 1), stop = (vaddr + memsz) & ~(Self.pageSize - 1)
            if stop > start { relro = (start, stop) }
        }
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

    /// The file offset of link-time address `vaddr` (within a segment's
    /// file bytes), or nil.
    public func fileOffset(of vaddr: UInt64, length: UInt64 = 1) -> UInt64? {
        for i in 0..<segmentCount {
            let segment = segments[i]
            if vaddr >= segment.vaddr, vaddr - segment.vaddr <= segment.filesz,
               length <= segment.filesz - (vaddr - segment.vaddr) {
                return segment.offset + (vaddr - segment.vaddr)
            }
        }
        return nil
    }

    /// Each R_*_RELATIVE relocation of a static PIE, read from the file:
    /// `body(target, addend)` with the target's link-time address; the
    /// value to store there is the run base - `base` + addend. Loaders that
    /// place segments in separate memory (VMOs) apply them themselves.
    public func forEachRelocation(in file: RawSpan, _ body: (UInt64, UInt64) throws(Error) -> Void) throws(Error) {
        guard let dynamic else { return }
        let bad = Error("bad dynamic section")
        var rela: UInt64?
        var relaSize: UInt64 = 0
        var relaEntry: UInt64 = 24
        var other = Self.OtherRelocations()
        var at = dynamic
        while true {
            guard let offset = fileOffset(of: at, length: 16) else { throw bad }
            let tag = try file.elfRead(UInt64.self, at: offset, else: bad)
            let value = try file.elfRead(UInt64.self, at: offset + 8, else: bad)
            switch tag {
            case 7: rela = value        // DT_RELA
            case 8: relaSize = value    // DT_RELASZ
            case 9: relaEntry = value   // DT_RELAENT
            default: other.note(tag, value)
            }
            if tag == 0 { break }
            at += 16
        }
        try checkDynamic(rela: rela, relaSize: relaSize, other)
        // An entry no bigger than the table (review fix: a huge DT_RELAENT
        // overflowed the walk).
        guard kind == .pie, let rela, relaEntry >= 24, relaSize > 0 else { return }
        guard relaEntry <= relaSize else { throw bad }
        guard let start = fileOffset(of: rela, length: relaSize) else { throw bad }
        let badReloc = Error("relocation out of bounds")
        var entry = start
        while entry < start + relaSize {
            let target = try file.elfRead(UInt64.self, at: entry, else: badReloc)
            let info = try file.elfRead(UInt64.self, at: entry + 8, else: badReloc)
            let addend = try file.elfRead(UInt64.self, at: entry + 16, else: badReloc)
            entry += relaEntry
            let type = UInt32(truncatingIfNeeded: info)
            if type == 0 { continue }
            guard type == Self.relativeRelocation else { throw Error("unsupported relocation type") }
            guard target >= base, target - base <= size - 8 else { throw badReloc }
            try body(target, addend)
        }
    }

    /// DT_REL / DT_JMPREL tables (sizes from DT_RELSZ / DT_PLTRELSZ):
    /// nothing croi applies.
    struct OtherRelocations {
        var rel = false, relSize: UInt64 = 0, jmprel = false, pltSize: UInt64 = 0

        mutating func note(_ tag: UInt64, _ value: UInt64) {
            switch tag {
            case 17: rel = true         // DT_REL
            case 18: relSize = value    // DT_RELSZ
            case 23: jmprel = true      // DT_JMPREL
            case 2: pltSize = value     // DT_PLTRELSZ
            default: ()
            }
        }
    }

    /// An ET_EXEC loads at its link addresses: its dynamic section (a
    /// program linked --export-dynamic for dlopen'd libraries) is only a
    /// symbol table, refused only if it has relocations to apply. Neither
    /// kind may carry REL or PLT relocations (static PIEs have RELATIVE
    /// RELA entries only).
    private func checkDynamic(rela: UInt64?, relaSize: UInt64, _ other: OtherRelocations) throws(Error) {
        if (other.rel && other.relSize > 0) || (other.jmprel && other.pltSize > 0) {
            throw Error("unsupported relocation tables")
        }
        if kind != .pie, rela != nil, relaSize > 0 { throw Error("an executable with relocations") }
    }

    private func relocate(_ image: inout MutableRawSpan, runAddress: UInt64) throws(Error) {
        guard let dynamic else { return }
        let bad = Error("bad dynamic section")

        var rela: UInt64?
        var relaSize: UInt64 = 0
        var relaEntry: UInt64 = 24
        var other = Self.OtherRelocations()
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
            default: other.note(tag, value)
            }
            if tag == 0 { break }
            offset += 16
        }
        try checkDynamic(rela: rela, relaSize: relaSize, other)
        guard kind == .pie, let rela, relaEntry >= 24 else { return }
        guard rela >= base, relaEntry <= max(relaSize, 24) else { throw bad }

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
