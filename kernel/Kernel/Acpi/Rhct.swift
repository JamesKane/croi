import Fmt

#if arch(riscv64)
/// The RISC-V Hart Capabilities Table: ISA strings per hart.
enum RiscvIsa {
    /// Whether every ISA string node lists multi-letter extension `name`
    /// (lowercase, e.g. "svpbmt"). False if there is no RHCT.
    static func everyHartHas(_ name: StaticString, _ acpi: AcpiTables) -> Bool {
        var nodes = 0
        var matches = 0
        forEachIsaString(acpi) { isa in
            nodes += 1
            if contains(isa, extension: name) { matches += 1 }
        }
        return nodes > 0 && matches == nodes
    }

    /// Writes the first ISA string (the harts' are identical on QEMU).
    static func writeBootIsa(_ acpi: AcpiTables, to out: some TextOutput) {
        var written = false
        forEachIsaString(acpi) { isa in
            if !written { out.write(utf8: isa.extracting(0..<min(isa.count, 160))) }
            written = true
        }
    }

    /// Calls `body` with each ISA string node's string (no NUL).
    private static func forEachIsaString(_ acpi: AcpiTables, _ body: (Span<UInt8>) -> Void) {
        guard let rhct = acpi.table("RHCT") else { return }
        acpi.withTable(rhct) { (table: RawSpan) in
            guard table.byteCount >= 56 else { return }
            let count = Int(table.load(fromByteOffset: 48, as: UInt32.self))
            var offset = Int(table.load(fromByteOffset: 52, as: UInt32.self))
            for _ in 0..<count {
                guard offset + 8 <= table.byteCount else { return }
                let type = table.load(fromByteOffset: offset, as: UInt16.self)
                let length = Int(table.load(fromByteOffset: offset + 2, as: UInt16.self))
                guard length >= 8, offset + length <= table.byteCount else { return }
                if type == 0 {  // ISA string node
                    let isaLength = Int(table.load(fromByteOffset: offset + 6, as: UInt16.self))
                    let bytes = table.extracting((offset + 8)..<min(offset + 8 + isaLength, offset + length))
                    var end = 0
                    while end < bytes.byteCount, bytes.load(fromByteOffset: end, as: UInt8.self) != 0 { end += 1 }
                    bytes.withUnsafeBytes { raw in
                        let span = unsafe Span<UInt8>(_unsafeStart: raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                                      count: end)
                        body(span)
                    }
                }
                offset += length
            }
        }
    }

    /// Multi-letter extensions follow '_' separators: "rv64imac_zicsr_svpbmt".
    private static func contains(_ isa: Span<UInt8>, extension name: StaticString) -> Bool {
        let wanted = unsafe Span<UInt8>(_unsafeStart: name.utf8Start, count: name.utf8CodeUnitCount)
        var start = 0
        while start <= isa.count {
            var end = start
            while end < isa.count, isa[end] != UInt8(ascii: "_") { end += 1 }
            if end - start == wanted.count {
                var same = true
                for i in 0..<wanted.count where isa[start + i] | 0x20 != wanted[i] {
                    same = false
                }
                if same { return true }
            }
            start = end + 1
        }
        return false
    }
}
#endif
