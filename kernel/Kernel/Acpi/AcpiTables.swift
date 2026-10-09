import PageTables

/// Read-only access to the firmware's ACPI tables (after Zircon's
/// acpi_lite). Every table is checksum-validated before use.
struct AcpiTables {
    /// Physical address of the RSDP.
    let rsdp: UInt64
    private let xsdt: UInt64

    init?(rsdp: UInt64) {
        guard rsdp != 0 else { return nil }
        let xsdt: UInt64? = withPhysicalBytes(rsdp, count: 36) { (bytes: RawSpan) -> UInt64? in
            guard bytes.load(fromByteOffset: 0, as: UInt64.self) == 0x2052_5450_2044_5352,  // "RSD PTR "
                  bytes.load(fromByteOffset: 15, as: UInt8.self) >= 2,
                  Self.checksum(bytes.extracting(0..<20)) == 0, Self.checksum(bytes) == 0
            else { return nil }
            return bytes.load(fromByteOffset: 24, as: UInt64.self)
        }
        guard let xsdt, Self.validLength(xsdt) != nil else { return nil }
        self.rsdp = rsdp
        self.xsdt = xsdt
    }

    /// Physical address of the first valid table with this signature.
    func table(_ signature: StaticString) -> UInt64? {
        let wanted = Self.signature(signature)
        guard let length = Self.validLength(xsdt) else { return nil }
        for i in 0..<(Int(length) - 36) / 8 {
            let address = withPhysicalBytes(xsdt + 36 + UInt64(i) * 8, count: 8) {
                $0.load(fromByteOffset: 0, as: UInt64.self)
            }
            let found = withPhysicalBytes(address, count: 4) { $0.load(fromByteOffset: 0, as: UInt32.self) }
            if found == wanted, Self.validLength(address) != nil {
                return address
            }
        }
        return nil
    }

    /// Runs `body` over the whole (validated) table at `address`.
    func withTable<R>(_ address: UInt64, _ body: (RawSpan) -> R) -> R {
        let length = Self.validLength(address) ?? 36
        return withPhysicalBytes(address, count: Int(length), body)
    }

    // MARK: Helpers

    static func signature(_ text: StaticString) -> UInt32 {
        var value: UInt32 = 0
        text.withUTF8Buffer { bytes in
            for i in 0..<min(4, bytes.count) {
                value |= UInt32(unsafe bytes[i]) << (8 * i)
            }
        }
        return value
    }

    /// The table's length if its header is sane and its checksum is right.
    private static func validLength(_ address: UInt64) -> UInt32? {
        let length = withPhysicalBytes(address, count: 8) { $0.load(fromByteOffset: 4, as: UInt32.self) }
        guard length >= 36, length < 1 << 20 else { return nil }
        return withPhysicalBytes(address, count: Int(length)) { checksum($0) } == 0 ? length : nil
    }

    private static func checksum(_ bytes: RawSpan) -> UInt8 {
        var sum: UInt8 = 0
        for i in 0..<bytes.byteCount {
            sum &+= bytes.load(fromByteOffset: i, as: UInt8.self)
        }
        return sum
    }
}

/// Runs `body` with a read-only view of physical memory [phys, phys+count):
/// through the physmap when it covers the range, otherwise through a
/// temporary mapping (firmware may put tables in memory the physmap skips).
func withPhysicalBytes<R>(_ phys: UInt64, count: Int, _ body: (RawSpan) -> R) -> R {
    let pageSize = KernelLayout.pageSize
    let first = phys & ~(pageSize - 1)
    let last = (phys + UInt64(max(count, 1)) - 1) & ~(pageSize - 1)
    var inPhysmap = true
    var page = first
    while page <= last {
        if kernelAspace.query(KernelLayout.physmap(page)) == nil {
            inPhysmap = false
            break
        }
        page += pageSize
    }
    if inPhysmap {
        let span = unsafe RawSpan(_unsafeStart: UnsafeRawPointer(bitPattern: UInt(KernelLayout.physmap(phys)))!,
                                  byteCount: count)
        return body(span)
    }
    let size = last - first + pageSize
    let window: UInt64
    do throws(VmError) {
        window = try kernelAspace.mapPhysical(first, size: size, MapAttributes(global: true))
    } catch {
        panic("acpi: can't map firmware table")
    }
    let span = unsafe RawSpan(_unsafeStart: UnsafeRawPointer(bitPattern: UInt(window + (phys - first)))!,
                              byteCount: count)
    let result = body(span)
    try? kernelAspace.free(window)
    return result
}
