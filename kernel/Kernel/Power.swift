import CKernel
import Fmt
import Synchronization

/// Power control (K10e; Zircon's system_powerctl and platform halt, power.h):
/// shutdown and reboot for user space's power service.
///
/// A request stops nothing user space can see until it is certain to go
/// ahead: the arguments are checked first. Then the debuglog is given up
/// to 100 ms to reach the console (the caller's last words are in it),
/// every other CPU is halted, the kernel's part is reported as budget
/// `power.shutdown_kernel` / `power.reboot_kernel` (the wait for the
/// console as `power.log_drain`), and the hardware is told. A request that comes back failed leaves the machine halted
/// rather than half shut down, so the only failures returned are
/// refusals.
///
/// - amd64: S5 by writing SLP_TYP | SLP_EN to PM1a (and PM1b) control,
///   or the sleep control register on a hardware-reduced FADT, with the
///   values user space read from \_S5 (ACPI_TRANSITION_S_STATE). Reboot
///   through the FADT reset register, then 0xCF9 (Zircon's cf9 reset),
///   then the 8042. Only system-I/O registers; a memory-space one is
///   NOT_SUPPORTED until a machine needs it.
/// - arm64: PSCI SYSTEM_OFF / SYSTEM_RESET, through the FADT's conduit.
/// - rv64: SBI SRST (shutdown, cold reboot), else the legacy shutdown call.
enum Power {
    enum Action {
        case shutdown
        case reboot
    }

    #if arch(x86_64)
    /// A FADT register the kernel can reach: a system I/O port.
    struct Register {
        var port: UInt16 = 0
        var present: Bool { port != 0 }
    }

    nonisolated(unsafe) static var pm1a = Register()
    nonisolated(unsafe) static var pm1b = Register()
    /// Hardware-reduced ACPI: sleep control instead of PM1.
    nonisolated(unsafe) static var sleepControl = Register()
    nonisolated(unsafe) static var hardwareReduced = false
    /// A PM1 or sleep register is outside system I/O space.
    nonisolated(unsafe) static var unreachable = false
    nonisolated(unsafe) static var reset = Register()
    nonisolated(unsafe) static var resetValue: UInt8 = 0
    #elseif arch(arm64)
    nonisolated(unsafe) static var psci = PsciConduit.unavailable
    #endif

    /// Reads what the FADT says (boot, before user space).
    static func initialize(_ acpi: AcpiTables) {
        #if arch(x86_64)
        guard let fadt = acpi.table("FACP") else { return }
        acpi.withTable(fadt) { (table: RawSpan) in
            let length = table.byteCount
            func u32(_ offset: Int) -> UInt32 { offset + 4 <= length ? table.load(fromByteOffset: offset, as: UInt32.self) : 0 }
            /// A generic address structure: I/O ports only.
            func gas(_ offset: Int) -> (register: Register, given: Bool) {
                guard offset + 12 <= length else { return (Register(), false) }
                let space = table.load(fromByteOffset: offset, as: UInt8.self)
                let address = table.load(fromByteOffset: offset + 4, as: UInt64.self)
                guard address != 0 else { return (Register(), false) }
                guard space == 1, address <= 0xFFFF else { return (Register(), true) }
                return (Register(port: UInt16(address)), true)
            }
            let flags = u32(112)
            hardwareReduced = flags & (1 << 20) != 0
            if hardwareReduced {
                let (register, given) = gas(244)
                sleepControl = register
                unreachable = given && !register.present
            } else {
                // The X_ block wins when present (ACPI 2.0+).
                func pm1(legacy: Int, extended: Int) -> (register: Register, given: Bool) {
                    let (register, given) = gas(extended)
                    if given { return (register, true) }
                    let port = u32(legacy)
                    return port != 0 && port <= 0xFFFF ? (Register(port: UInt16(port)), true) : (Register(), false)
                }
                let a = pm1(legacy: 64, extended: 172)
                let b = pm1(legacy: 68, extended: 184)
                pm1a = a.register
                pm1b = b.register
                unreachable = (a.given && !a.register.present) || (b.given && !b.register.present)
            }
            if flags & (1 << 10) != 0, length >= 129 {  // RESET_REG_SUP
                reset = gas(116).register
                resetValue = table.load(fromByteOffset: 128, as: UInt8.self)
            }
        }
        #elseif arch(arm64)
        psci = PsciConduit(acpi)
        #endif
    }

    /// system_powerctl(power resource, cmd, const croi_system_powerctl_arg_t *).
    static func call(_ a: InlineArray<6, UInt64>, _ table: borrowing HandleTable) throws(Status) -> Never {
        let started = Clock.now()
        try Resources.check(table, UInt32(truncatingIfNeeded: a[0]), system: UInt64(CROI_RSRC_SYSTEM_POWER_BASE))
        let command = UInt32(truncatingIfNeeded: a[1])
        var argument = croi_system_powerctl_arg_t()
        if command == UInt32(CROI_SYSTEM_POWERCTL_ACPI_TRANSITION_S_STATE) {
            guard unsafe UserCopy.from(&argument, a[2], UInt64(MemoryLayout<croi_system_powerctl_arg_t>.size)) == 0 else {
                throw .invalidArgs
            }
        }
        try control(command, argument, started: started)
    }

    /// system_powerctl's command `command`, `argument` already copied in.
    /// Returns only refusals.
    static func control(_ command: UInt32, _ argument: croi_system_powerctl_arg_t,
                        started: UInt64) throws(Status) -> Never {
        switch command {
        case UInt32(CROI_SYSTEM_POWERCTL_SHUTDOWN):
            #if arch(x86_64)
            throw .notSupported  // needs \_S5: ACPI_TRANSITION_S_STATE
            #else
            try check(.shutdown)
            halt(.shutdown, started: started)
            #endif
        case UInt32(CROI_SYSTEM_POWERCTL_REBOOT):
            try check(.reboot)
            halt(.reboot, started: started)
        case UInt32(CROI_SYSTEM_POWERCTL_ACPI_TRANSITION_S_STATE):
            #if arch(x86_64)
            let state = argument.acpi_transition_s_state
            guard (1...5).contains(state.target_s_state) else { throw .invalidArgs }
            guard state.target_s_state == 5 else { throw .notSupported }  // no suspend
            guard state.sleep_type_a < 8, state.sleep_type_b < 8 else { throw .invalidArgs }
            try check(.shutdown)
            sleepTypes = (state.sleep_type_a, state.sleep_type_b)
            halt(.shutdown, started: started)
            #else
            throw .notSupported
            #endif
        case 1...9:
            throw .notSupported
        default:
            throw .invalidArgs
        }
    }

    #if arch(x86_64)
    nonisolated(unsafe) private static var sleepTypes: (UInt8, UInt8) = (0, 0)
    #endif

    /// K14a: the memory watchdog's out-of-memory reboot (Zircon's default
    /// OOM behavior); halts if the machine can't.
    static func reboot() -> Never {
        halt(.reboot, started: Clock.now())
    }

    /// Whether this machine can do `action` at all (before anything stops).
    private static func check(_ action: Action) throws(Status) {
        #if arch(x86_64)
        if action == .shutdown {
            guard !unreachable, hardwareReduced ? sleepControl.present : pm1a.present else { throw .notSupported }
        }
        #elseif arch(arm64)
        guard psci.available else { throw .notSupported }
        #endif
    }

    /// Lets the debuglog drain, stops the other CPUs, reports and does it.
    private static func halt(_ action: Action, started: UInt64) -> Never {
        let draining = Clock.now()
        let written = DebugLog.progress.written
        let patience = Clock.now() + 100_000_000
        while DebugLog.progress.printed < written && Clock.now() < patience {
            Scheduler.sleep(until: min(Clock.now() + 1_000_000, patience))
        }
        let drained = Clock.now()
        // The dumper finishes the line it is on and stops, so no CPU is
        // halted part way through the console (a capped drain left one
        // there).
        DebugLog.quiet.store(true, ordering: .releasing)
        _ = arch_interrupts_save()  // masked from here on
        _ = Ipi.stopOthers(patience: 50_000_000)
        // The kernel's own part, without waiting for the console: that
        // depends on how much log is still queued (m2's last lines take
        // ~20 ms through a KVM serial port, a byte per exit), so it is
        // reported apart.
        let elapsed = (draining - started) + (Clock.now() - drained)
        if let console = panicConsole {
            if action == .shutdown {
                console.write("croi kernel: powering off\n")
                Budgets.report(console, "power.shutdown_kernel", elapsed, limit: 10_000_000)
                Budgets.report(console, "power.log_drain", drained - draining)
            } else {
                console.write("croi kernel: rebooting\n")
                Budgets.report(console, "power.reboot_kernel", elapsed, limit: 10_000_000)
                Budgets.report(console, "power.log_drain", drained - draining)
            }
        }
        panicConsole?.drain(patience: 100_000_000)  // an emulator drops what is left
        // The hardware (an emulator's main loop) may take a while: wait
        // before saying it didn't act, and ask twice.
        for _ in 0..<2 {
            switch action {
            case .shutdown: powerOff()
            case .reboot: resetMachine()
            }
            Clock.delay(nanoseconds: 1_000_000_000)
        }
        panicConsole?.write("croi kernel: the hardware didn't act; halted\n")
        arch_halt()
    }

    private static func powerOff() {
        #if arch(x86_64)
        let slpEn: UInt16 = 1 << 13
        if hardwareReduced {
            // SLP_TYPx in bits 4:2, SLP_EN bit 5 (8-bit register).
            arch_outb(sleepControl.port, UInt8(sleepTypes.0 & 7) << 2 | 1 << 5)
            return
        }
        // SLP_TYP into both blocks first, then SLP_EN (as Linux does: the
        // pair takes effect together).
        func setType(_ register: Register, _ type: UInt8) {
            guard register.present else { return }
            arch_outw(register.port, arch_inw(register.port) & ~(7 << 10) | UInt16(type & 7) << 10)
        }
        func enable(_ register: Register) {
            guard register.present else { return }
            arch_outw(register.port, arch_inw(register.port) | slpEn)
        }
        setType(pm1a, sleepTypes.0)
        setType(pm1b, sleepTypes.1)
        enable(pm1a)
        enable(pm1b)
        #elseif arch(arm64)
        _ = arch_psci_call(0x8400_0008, 0, 0, 0, psci.useHvc ? 1 : 0)  // SYSTEM_OFF
        #elseif arch(riscv64)
        _ = arch_sbi_call(0x5352_5354, 0, 0, 0, 0)  // SRST: shutdown, no reason
        _ = arch_sbi_call(8, 0, 0, 0, 0)            // legacy shutdown
        #endif
    }

    private static func resetMachine() {
        #if arch(x86_64)
        if reset.present { arch_outb(reset.port, resetValue) }
        Clock.delay(nanoseconds: 50_000_000)
        arch_outb(0xCF9, 0x02)  // Zircon's cf9_reboot_system: hard reset
        Clock.delay(nanoseconds: 1_000)
        arch_outb(0xCF9, 0x06)
        Clock.delay(nanoseconds: 50_000_000)
        arch_outb(0x64, 0xFE)  // the 8042's reset line
        #elseif arch(arm64)
        _ = arch_psci_call(0x8400_0009, 0, 0, 0, psci.useHvc ? 1 : 0)  // SYSTEM_RESET
        #elseif arch(riscv64)
        _ = arch_sbi_call(0x5352_5354, 0, 1, 0, 0)  // SRST: cold reboot
        #endif
    }
}
