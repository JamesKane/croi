import CEFI
import CHandoff

/// The ACPI tables the loader needs: where the RSDP is (for the kernel) and
/// SPCR (for the kernel's early console).
struct Acpi {
    /// Physical address of the ACPI 2.0+ RSDP.
    let rsdp: UInt64
    private let xsdt: UInt64

    /// Finds the RSDP in the UEFI configuration table and validates it.
    init?(systemTable: UnsafeMutablePointer<EFI_SYSTEM_TABLE>) {
        var found: UInt64?
        let count = unsafe Int(systemTable.pointee.NumberOfTableEntries)
        if let tables = unsafe systemTable.pointee.ConfigurationTable {
            for i in 0..<count {
                let entry = unsafe tables[i]
                if unsafe entry.VendorGuid.matches(.acpi20Table) {
                    found = unsafe UInt64(UInt(bitPattern: entry.VendorTable))
                }
            }
        }
        guard let address = found else { return nil }

        let valid: UInt64? = unsafe withPhysical(address, size: 36) { (rsdp: RawSpan) -> UInt64? in
            guard rsdp.load(fromByteOffset: 0, as: UInt64.self) == 0x2052_5450_2044_5352,  // "RSD PTR "
                  rsdp.load(fromByteOffset: 15, as: UInt8.self) >= 2,                     // revision
                  Self.checksum(rsdp.extracting(0..<20)) == 0,
                  Self.checksum(rsdp) == 0
            else { return nil }
            return rsdp.load(fromByteOffset: 24, as: UInt64.self)
        }
        guard let xsdt = valid else { return nil }
        rsdp = address
        self.xsdt = xsdt
    }

    /// Physical address of the first valid table with this signature.
    func table(_ signature: StaticString) -> UInt64? {
        var wanted: UInt32 = 0
        signature.withUTF8Buffer { bytes in
            for i in 0..<min(4, bytes.count) {
                wanted |= UInt32(unsafe bytes[i]) << (8 * i)
            }
        }
        guard let length = unsafe Self.validTableLength(at: xsdt), length >= 36 else { return nil }
        let count = (Int(length) - 36) / 8
        for i in 0..<count {
            let address = unsafe withPhysical(xsdt + 36 + UInt64(i) * 8, size: 8) {
                $0.load(fromByteOffset: 0, as: UInt64.self)
            }
            let signature = unsafe withPhysical(address, size: 4) { $0.load(fromByteOffset: 0, as: UInt32.self) }
            if signature == wanted, unsafe Self.validTableLength(at: address) != nil {
                return address
            }
        }
        return nil
    }

    /// The table's length if its checksum is correct.
    @unsafe private static func validTableLength(at address: UInt64) -> UInt32? {
        let length = unsafe withPhysical(address, size: 8) { $0.load(fromByteOffset: 4, as: UInt32.self) }
        guard length >= 36, length < 1 << 20 else { return nil }
        let sum = unsafe withPhysical(address, size: Int(length)) { checksum($0) }
        return sum == 0 ? length : nil
    }

    private static func checksum(_ bytes: RawSpan) -> UInt8 {
        var sum: UInt8 = 0
        for i in 0..<bytes.byteCount {
            sum &+= bytes.load(fromByteOffset: i, as: UInt8.self)
        }
        return sum
    }

    /// The console UART from SPCR, if it describes a usable one.
    func spcrConsole() -> croi_uart_t? {
        guard let spcr = table("SPCR") else { return nil }
        return unsafe withPhysical(spcr, size: 52) { (table: RawSpan) -> croi_uart_t? in
            // Interface type at 36, Generic Address Structure at 40.
            Self.uart(type: UInt16(table.load(fromByteOffset: 36, as: UInt8.self)), gas: table.extracting(40..<52))
        }
    }

    /// The first usable serial port in DBG2 (boards with no SPCR, such as
    /// the CIX Sky1, name their console here).
    func dbg2Console() -> croi_uart_t? {
        guard let dbg2 = table("DBG2") else { return nil }
        let length = unsafe withPhysical(dbg2, size: 8) { Int($0.load(fromByteOffset: 4, as: UInt32.self)) }
        return unsafe withPhysical(dbg2, size: length) { (table: RawSpan) -> croi_uart_t? in
            guard table.byteCount >= 44 else { return nil }
            var device = Int(table.load(fromByteOffset: 36, as: UInt32.self))
            let count = Int(table.load(fromByteOffset: 40, as: UInt32.self))
            for _ in 0..<count {
                guard device + 22 <= table.byteCount else { return nil }
                let deviceLength = Int(table.load(fromByteOffset: device + 1, as: UInt16.self))
                let registers = Int(table.load(fromByteOffset: device + 3, as: UInt8.self))
                let portType = table.load(fromByteOffset: device + 12, as: UInt16.self)
                let subtype = table.load(fromByteOffset: device + 14, as: UInt16.self)
                let gasOffset = Int(table.load(fromByteOffset: device + 18, as: UInt16.self))
                if portType == 0x8000, registers >= 1, device + gasOffset + 12 <= table.byteCount,
                   let uart = Self.uart(type: subtype, gas: table.extracting((device + gasOffset)..<(device + gasOffset + 12))) {
                    return uart
                }
                guard deviceLength > 0 else { return nil }
                device += deviceLength
            }
            return nil
        }
    }

    /// A UART from an SPCR interface type / DBG2 serial subtype (the two
    /// share their numbering) and its Generic Address Structure.
    private static func uart(type: UInt16, gas: RawSpan) -> croi_uart_t? {
        let space = gas.load(fromByteOffset: 0, as: UInt8.self)
        let accessSize = gas.load(fromByteOffset: 3, as: UInt8.self)
        let address = gas.load(fromByteOffset: 4, as: UInt64.self)
        guard address != 0 else { return nil }

        var uart = croi_uart_t()
        uart.base = address
        switch type {
        case 0x00, 0x01, 0x12:  // 16550 full / subset / with GAS
            if space == 1 {     // system I/O
                uart.kind = CROI_UART_NS16550_PIO
            } else if space == 0 {
                uart.kind = CROI_UART_NS16550_MMIO
                let width: UInt32 = accessSize == 3 ? 4 : 1  // dword : byte
                uart.access_width = width
                uart.reg_shift = width == 4 ? 2 : 0
            } else {
                return nil
            }
        case 0x03, 0x0D, 0x0E:  // PL011 / SBSA generic (32-bit)
            guard space == 0 else { return nil }
            uart.kind = CROI_UART_PL011
            uart.access_width = 4
        default:
            return nil  // e.g. 0x13, Qualcomm GENI: not supported yet
        }
        return uart
    }
}
