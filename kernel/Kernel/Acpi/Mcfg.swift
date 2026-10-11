import _Volatile
import PageTables
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

    /// The requester id whose configuration space holds `physical`, if an
    /// ECAM window covers it.
    static func requesterId(_ physical: UInt64) -> UInt16? {
        for i in 0..<count {
            let size = (UInt64(windows[i].endBus) - UInt64(windows[i].startBus) + 1) << 20
            guard physical >= windows[i].base, physical - windows[i].base < size else { continue }
            return UInt16(truncatingIfNeeded: UInt64(windows[i].startBus) << 8 + ((physical - windows[i].base) >> 12))
        }
        return nil
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

/// PCI configuration space through the first MCFG window (segment 0), a
/// bus (1 MiB) mapped the first time it is read and kept (K12h: which
/// function an MSI-X table belongs to).
enum Pci {
    nonisolated(unsafe) private static var buses = InlineArray<256, UInt64>(repeating: 0)
    private static let lock = SpinLock()

    /// Bus `bus`'s configuration space (kernel virtual), or nil.
    private static func bus(_ bus: Int) -> UInt64? {
        guard Mcfg.count > 0 else { return nil }
        let window = Mcfg.windows[0]
        guard bus >= Int(window.startBus), bus <= Int(window.endBus) else { return nil }
        if let mapped = lock.withLock({ buses[bus] == 0 ? nil : buses[bus] }) { return mapped }
        let physical = window.base + UInt64(bus - Int(window.startBus)) << 20
        guard let mapped = try? kernelAspace.mapPhysical(physical, size: 1 << 20,
                                                         MapAttributes(cache: .device, global: true), shared: true) else {
            return nil
        }
        return lock.withLock { () -> UInt64 in
            if buses[bus] == 0 { buses[bus] = mapped }
            return buses[bus]  // (a racing mapping of the same bus stays, unused)
        }
    }

    private static func read32(_ address: UInt64) -> UInt32 {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(address)).load()
    }

    /// The requester id of the function whose MSI-X table is at physical
    /// address `table` (its capability's BIR and offset into that BAR),
    /// walking from the window's first bus through bridges.
    static func msixOwner(_ table: UInt64) -> UInt16? {
        guard Mcfg.count > 0 else { return nil }
        var pending = InlineArray<32, Int>(repeating: 0)
        pending[0] = Int(Mcfg.windows[0].startBus)
        var count = 1, visited = 0
        while visited < count {
            let number = pending[visited]
            visited += 1
            guard let config = bus(number) else { continue }
            for device in 0..<32 {
                for function in 0..<8 {
                    let cfg = config + UInt64(device << 15 | function << 12)
                    let id = read32(cfg)
                    if id & 0xFFFF == 0xFFFF {
                        if function == 0 { break }
                        continue
                    }
                    let header = (read32(cfg + 0xC) >> 16) & 0xFF
                    if header & 0x7F == 1, count < pending.count {  // a bridge: its secondary bus
                        let secondary = Int((read32(cfg + 0x18) >> 8) & 0xFF)
                        if secondary > number { pending[count] = secondary; count += 1 }
                    } else if header & 0x7F == 0, read32(cfg + 4) & (1 << 20) != 0 {  // capabilities
                        var cap = UInt64(read32(cfg + 0x34) & 0xFC), hops = 0
                        while cap != 0, hops < 48 {
                            let word = read32(cfg + cap)
                            if word & 0xFF == 0x11 {  // MSI-X
                                let place = read32(cfg + cap + 4)
                                let bir = UInt64(place & 7)
                                if bir < 6 {
                                    let low = read32(cfg + 0x10 + bir * 4)
                                    var base = UInt64(low & ~0xF)
                                    if (low >> 1) & 3 == 2, bir < 5 { base |= UInt64(read32(cfg + 0x14 + bir * 4)) << 32 }
                                    if base != 0, base + UInt64(place & ~7) == table {
                                        return UInt16(number << 8 | device << 3 | function)
                                    }
                                }
                            }
                            cap = UInt64((word >> 8) & 0xFC)
                            hops += 1
                        }
                    }
                    if function == 0, header & 0x80 == 0 { break }  // single-function
                }
            }
        }
        return nil
    }
}
