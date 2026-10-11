import CroiRuntime

/// `userboot.shutdown=poweroff|reboot` (K10e): once the program userboot
/// started has exited, turn the machine off or reset it with
/// system_powerctl, so a test boot ends by itself and the kernel's part
/// is measured. amd64 shuts down only with ACPI_TRANSITION_S_STATE and
/// \_S5's sleep types, which belong to an AML interpreter; userboot has
/// none, so it finds the `Name (_S5, Package () {a, b, ...})` the DSDT
/// declares with a byte scan, as small kernels do. Todhchai's ACPI
/// service evaluates \_S5 properly.
enum Power {
    static func act(_ how: [UInt8], resource: UInt32, bootData: UInt32) throws(Userboot.Failure) {
        if how == Userboot.bytes("reboot") {
            Userboot.say("userboot: rebooting\n")
            try Userboot.call("rebooting", Userboot.sys(CROI_SYS_SYSTEM_POWERCTL, UInt64(resource),
                                                        UInt64(CROI_SYSTEM_POWERCTL_REBOOT), 0))
            return
        }
        guard how == Userboot.bytes("poweroff") else { throw Userboot.Failure(what: "userboot.shutdown=", status: -10) }
        #if arch(x86_64)
        var argument = croi_system_powerctl_arg_t()
        let (a, b) = try sleepTypes(resource: resource, bootData: bootData)
        argument.acpi_transition_s_state.target_s_state = 5
        argument.acpi_transition_s_state.sleep_type_a = a
        argument.acpi_transition_s_state.sleep_type_b = b
        Userboot.say("userboot: powering off\n")
        try Userboot.call("powering off", Userboot.sys(CROI_SYS_SYSTEM_POWERCTL, UInt64(resource),
                                                       UInt64(CROI_SYSTEM_POWERCTL_ACPI_TRANSITION_S_STATE),
                                                       Userboot.address(&argument)))
        #else
        Userboot.say("userboot: powering off\n")
        try Userboot.call("powering off", Userboot.sys(CROI_SYS_SYSTEM_POWERCTL, UInt64(resource),
                                                       UInt64(CROI_SYSTEM_POWERCTL_SHUTDOWN), 0))
        #endif
    }

    #if arch(x86_64)
    /// \_S5's two values: boot data -> RSDP -> XSDT -> FADT -> DSDT.
    static func sleepTypes(resource: UInt32, bootData: UInt32) throws(Userboot.Failure) -> (UInt8, UInt8) {
        let missing = Userboot.Failure(what: "finding \\_S5", status: -25)
        guard let rsdpAddress = rsdp(bootData) else { throw missing }
        let rsdp = unsafe try map(resource, rsdpAddress, 36)
        let xsdtAddress = unsafe rsdp.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
        let xsdt = unsafe try table(resource, xsdtAddress)
        var dsdtAddress: UInt64 = 0
        for entry in stride(from: 36, to: Int(unsafe xsdt.length), by: 8) {
            let address = unsafe xsdt.bytes.loadUnaligned(fromByteOffset: entry, as: UInt64.self)
            let header = unsafe try map(resource, address, 36)
            guard unsafe header.loadUnaligned(as: UInt32.self) == 0x5043_4146 else { continue }  // "FACP"
            let fadt = unsafe try table(resource, address)
            if unsafe fadt.length >= 148 { dsdtAddress = unsafe fadt.bytes.loadUnaligned(fromByteOffset: 140, as: UInt64.self) }
            if dsdtAddress == 0 { dsdtAddress = UInt64(unsafe fadt.bytes.loadUnaligned(fromByteOffset: 40, as: UInt32.self)) }
            break
        }
        guard dsdtAddress != 0 else { throw missing }
        let dsdt = unsafe try table(resource, dsdtAddress)
        guard let types = unsafe scan(dsdt.bytes, Int(dsdt.length)) else { throw missing }
        return types
    }

    /// The RSDP's address from the boot data container (zbi.h).
    static func rsdp(_ bootData: UInt32) -> UInt64? {
        var size: UInt64 = 0
        var base: UInt64 = 0
        guard Userboot.sys(CROI_SYS_VMO_GET_SIZE, UInt64(bootData), Userboot.address(&size)) == 0,
              Userboot.sys(CROI_SYS_VMAR_MAP, UInt64(croi_vmar_root_self()) | UInt64(CROI_VM_PERM_READ) << 32, 0,
                           UInt64(bootData), 0, size, Userboot.address(&base)) == 0 else { return nil }
        let header = UInt64(MemoryLayout<croi_zbi_header_t>.size)
        var at = header  // past the container's header
        while at + header <= size {
            let item = unsafe UnsafeRawPointer(bitPattern: UInt(base + at))!.loadUnaligned(as: croi_zbi_header_t.self)
            if item.type == UInt32(CROI_ZBI_TYPE_ACPI_RSDP), item.length == 8 {
                return unsafe UnsafeRawPointer(bitPattern: UInt(base + at + header))!.loadUnaligned(as: UInt64.self)
            }
            at += header + ((UInt64(item.length) + 7) & ~7)
        }
        return nil
    }

    /// `\_S5_`'s package: NameOp, the name, PackageOp, PkgLength,
    /// NumElements, then the first two integers (ZeroOp, OneOp, or a
    /// BytePrefix constant).
    static func scan(_ bytes: UnsafeRawPointer, _ length: Int) -> (UInt8, UInt8)? {
        func byte(_ i: Int) -> UInt8 { i < length ? unsafe bytes.load(fromByteOffset: i, as: UInt8.self) : 0 }
        var i = 36
        while i + 4 < length {
            defer { i += 1 }
            guard byte(i) == 0x5F, byte(i + 1) == 0x53, byte(i + 2) == 0x35, byte(i + 3) == 0x5F,  // "_S5_"
                  byte(i - 1) == 0x08 || (byte(i - 1) == 0x5C && byte(i - 2) == 0x08),         // NameOp [\]
                  byte(i + 4) == 0x12 else { continue }                                         // PackageOp
            var at = i + 5
            at += 1 + Int(byte(at) >> 6)  // PkgLength: extra bytes in bits 7:6
            at += 1                       // NumElements
            var values = InlineArray<2, UInt8>(repeating: 0)
            for k in 0..<2 {
                switch byte(at) {
                case 0x00, 0x01:
                    values[k] = byte(at)
                    at += 1
                case 0x0A:
                    values[k] = byte(at + 1)
                    at += 2
                default:
                    return nil
                }
            }
            return (values[0], values[1])
        }
        return nil
    }

    /// A whole ACPI table, mapped read-only.
    static func table(_ resource: UInt32, _ address: UInt64) throws(Userboot.Failure) -> (bytes: UnsafeRawPointer, length: UInt32) {
        let header = unsafe try map(resource, address, 36)
        let length = unsafe header.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        guard length >= 36, length < 1 << 20 else { throw Userboot.Failure(what: "reading an ACPI table", status: -10) }
        return unsafe (try map(resource, address, UInt64(length)), length)
    }

    /// Firmware memory through a physical VMO (always cached, K9b).
    static func map(_ resource: UInt32, _ address: UInt64, _ size: UInt64) throws(Userboot.Failure) -> UnsafeRawPointer {
        let page = Userboot.pageSize
        let first = address & ~(page - 1)
        let length = ((address + size + page - 1) & ~(page - 1)) - first
        var vmo: UInt32 = 0
        var at: UInt64 = 0
        try Userboot.call("mapping ACPI tables", Userboot.sys(CROI_SYS_VMO_CREATE_PHYSICAL, UInt64(resource), first, length,
                                                              Userboot.address(&vmo)))
        defer { _ = Userboot.sys(CROI_SYS_HANDLE_CLOSE, UInt64(vmo)) }
        try Userboot.call("mapping ACPI tables", Userboot.sys(CROI_SYS_VMO_SET_CACHE_POLICY, UInt64(vmo),
                                                              UInt64(CROI_CACHE_POLICY_CACHED)))
        try Userboot.call("mapping ACPI tables", Userboot.sys(CROI_SYS_VMAR_MAP,
                                                              UInt64(croi_vmar_root_self()) | UInt64(CROI_VM_PERM_READ) << 32,
                                                              0, UInt64(vmo), 0, length, Userboot.address(&at)))
        return unsafe UnsafeRawPointer(bitPattern: UInt(at + (address - first)))!
    }
    #endif
}
