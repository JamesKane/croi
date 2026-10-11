import CKernel

/// ACPI's MCFG: PCIe ECAM windows, so the kernel can reach a function's
/// configuration space (the AMD IOMMU's MSI capability; the boot test's
/// device scan).
enum Mcfg {
    struct Window {
        var base: UInt64 = 0
        var segment: UInt16 = 0
        var startBus: UInt8 = 0
        var endBus: UInt8 = 0
    }

    nonisolated(unsafe) static var windows = InlineArray<8, Window>(repeating: Window())
    nonisolated(unsafe) static var count = 0

    static func initialize(_ acpi: AcpiTables) {
        guard count == 0, let mcfg = acpi.table("MCFG") else { return }
        acpi.withTable(mcfg) { (table: RawSpan) in
            var at = 44
            while at + 16 <= table.byteCount, count < windows.count {
                windows[count] = Window(base: unsafe table.unsafeLoadUnaligned(fromByteOffset: at, as: UInt64.self),
                                        segment: unsafe table.unsafeLoadUnaligned(fromByteOffset: at + 8, as: UInt16.self),
                                        startBus: table.load(fromByteOffset: at + 10, as: UInt8.self),
                                        endBus: table.load(fromByteOffset: at + 11, as: UInt8.self))
                count += 1
                at += 16
            }
        }
    }

    /// The physical address of a function's 4 KiB configuration space.
    static func configSpace(segment: UInt16, deviceId: UInt16) -> UInt64? {
        let bus = UInt8(deviceId >> 8)
        for i in 0..<count where windows[i].segment == segment && windows[i].startBus <= bus && bus <= windows[i].endBus {
            return windows[i].base + (UInt64(deviceId) - UInt64(windows[i].startBus) << 8) << 12
        }
        return nil
    }
}
