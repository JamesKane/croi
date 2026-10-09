/// A processor described by the MADT.
struct CpuDescriptor {
    /// What the hardware calls this CPU: the local APIC ID (amd64), the
    /// MPIDR affinity bits (arm64), or the hart ID (rv64).
    var hardwareId: UInt64
    var acpiUid: UInt32
    /// Usable now (as opposed to hot-pluggable later).
    var enabled: Bool
}

/// The MADT ("APIC"): interrupt controllers and the CPUs they belong to.
enum Madt {
    /// Calls `body` for every processor entry for this architecture.
    static func forEachCpu(_ acpi: AcpiTables, _ body: (CpuDescriptor) -> Void) {
        forEachEntry(acpi) { type, entry in
            if let cpu = decode(type: type, entry) {
                body(cpu)
            }
        }
    }

    /// Calls `body(type, entry)` for every interrupt controller structure.
    static func forEachEntry(_ acpi: AcpiTables, _ body: (UInt8, RawSpan) -> Void) {
        guard let madt = acpi.table("APIC") else { return }
        acpi.withTable(madt) { (table: RawSpan) in
            var offset = 44
            while offset + 2 <= table.byteCount {
                let type = table.load(fromByteOffset: offset, as: UInt8.self)
                let length = Int(table.load(fromByteOffset: offset + 1, as: UInt8.self))
                guard length >= 2, offset + length <= table.byteCount else { break }
                body(type, table.extracting(offset..<(offset + length)))
                offset += length
            }
        }
    }

    /// The header's local interrupt controller address and flags (amd64:
    /// the local APIC base; flag bit 0: dual 8259s are present).
    static func header(_ acpi: AcpiTables) -> (localController: UInt64, flags: UInt32)? {
        guard let madt = acpi.table("APIC") else { return nil }
        return acpi.withTable(madt) { (table: RawSpan) in
            (UInt64(table.load(fromByteOffset: 36, as: UInt32.self)), table.load(fromByteOffset: 40, as: UInt32.self))
        }
    }

    private static func decode(type: UInt8, _ e: RawSpan) -> CpuDescriptor? {
        #if arch(x86_64)
        switch type {
        case 0 where e.byteCount >= 8:  // Processor Local APIC
            let flags = e.load(fromByteOffset: 4, as: UInt32.self)
            return CpuDescriptor(hardwareId: UInt64(e.load(fromByteOffset: 3, as: UInt8.self)),
                                 acpiUid: UInt32(e.load(fromByteOffset: 2, as: UInt8.self)),
                                 enabled: flags & 1 != 0)
        case 9 where e.byteCount >= 16:  // Processor Local x2APIC
            let flags = e.load(fromByteOffset: 8, as: UInt32.self)
            return CpuDescriptor(hardwareId: UInt64(e.load(fromByteOffset: 4, as: UInt32.self)),
                                 acpiUid: e.load(fromByteOffset: 12, as: UInt32.self),
                                 enabled: flags & 1 != 0)
        default:
            return nil
        }
        #elseif arch(arm64)
        guard type == 0x0B, e.byteCount >= 76 else { return nil }  // GIC CPU Interface (GICC)
        let flags = e.load(fromByteOffset: 12, as: UInt32.self)
        let mpidr = e.load(fromByteOffset: 68, as: UInt64.self) & 0xFF_00FF_FFFF  // Aff3..Aff0
        return CpuDescriptor(hardwareId: mpidr, acpiUid: e.load(fromByteOffset: 8, as: UInt32.self),
                             enabled: flags & 1 != 0)
        #elseif arch(riscv64)
        guard type == 0x18, e.byteCount >= 20 else { return nil }  // RISC-V Hart Local Interrupt Controller
        let flags = e.load(fromByteOffset: 4, as: UInt32.self)
        return CpuDescriptor(hardwareId: e.load(fromByteOffset: 8, as: UInt64.self),
                             acpiUid: e.load(fromByteOffset: 16, as: UInt32.self),
                             enabled: flags & 1 != 0)
        #endif
    }
}
