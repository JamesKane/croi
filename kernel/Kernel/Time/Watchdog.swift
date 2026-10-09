import _Volatile
import PageTables

/// The SBSA generic watchdog (Arm; described by the GTDT). During bring-up
/// a hang should become a reset, not a power cycle, so croi enables it and
/// refreshes it from a kernel timer. `croi.watchdog=off` leaves it alone.
///
/// The watchdog counts at the system counter frequency. Its first stage
/// fires after WOR ticks without a refresh, the second (a reset) after
/// another WOR, so the timeout is twice the offset.
struct SbsaWatchdog {
    /// How a refresh is done. The standard way writes the refresh frame;
    /// the CIX Sky1's refresh frame doesn't work and a refresh must rewrite
    /// WOR instead (a board rule chooses this).
    enum RefreshMethod {
        case refreshFrame
        case offsetRegister
    }

    /// Physical frames, as the GTDT gives them.
    struct Description: Equatable {
        var refreshFrame: UInt64
        var controlFrame: UInt64
        var interrupt: UInt32
    }

    let control: UInt64  // virtual
    let refresh: UInt64  // virtual
    let method: RefreshMethod
    private(set) var offset: UInt64 = 0

    init(control: UInt64, refresh: UInt64, method: RefreshMethod = .refreshFrame) {
        self.control = control
        self.refresh = refresh
        self.method = method
    }

    /// Programs a timeout of `ticks` (system counter ticks) and enables it.
    mutating func enable(timeoutTicks ticks: UInt64) {
        offset = ticks / 2
        write32(control + 0x8, UInt32(truncatingIfNeeded: offset))        // WOR[31:0]
        write32(control + 0xC, UInt32(truncatingIfNeeded: offset >> 32))  // WOR[47:32]
        write32(control + 0x0, 1)                                         // WCS.EN
    }

    func kick() {
        switch method {
        case .refreshFrame:
            write32(refresh + 0x0, 0)  // WRR: any write refreshes
        case .offsetRegister:
            write32(control + 0x8, UInt32(truncatingIfNeeded: offset))  // writing WOR refreshes
        }
    }

    // MARK: Discovery

    /// The first SBSA watchdog in the GTDT's platform timers.
    static func find(_ acpi: AcpiTables) -> Description? {
        guard let gtdt = acpi.table("GTDT") else { return nil }
        return acpi.withTable(gtdt) { (table: RawSpan) -> Description? in find(in: table) }
    }

    /// `find`, over a table already in hand (also used by the self-test).
    static func find(in table: RawSpan) -> Description? {
        guard table.byteCount >= 96 else { return nil }
        let count = Int(table.load(fromByteOffset: 88, as: UInt32.self))
        var offset = Int(table.load(fromByteOffset: 92, as: UInt32.self))
        for _ in 0..<count {
            guard offset >= 96, offset + 3 <= table.byteCount else { return nil }
            let type = table.load(fromByteOffset: offset, as: UInt8.self)
            let length = Int(table.load(fromByteOffset: offset + 1, as: UInt16.self))
            guard length > 0, offset + length <= table.byteCount else { return nil }
            if type == 1, length >= 28 {  // SBSA generic watchdog
                return Description(refreshFrame: table.load(fromByteOffset: offset + 4, as: UInt64.self),
                                   controlFrame: table.load(fromByteOffset: offset + 12, as: UInt64.self),
                                   interrupt: table.load(fromByteOffset: offset + 20, as: UInt32.self))
            }
            offset += length
        }
        return nil
    }

    private func write32(_ address: UInt64, _ value: UInt32) {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(address)).store(value)
    }
}

/// The running watchdog, refreshed by a timer on the boot CPU.
enum Watchdog {
    nonisolated(unsafe) private static var active: SbsaWatchdog?
    private static var timeoutSeconds: UInt64 { 30 }
    private static var refreshNanoseconds: UInt64 { 5_000_000_000 }

    /// Maps and enables the GTDT's watchdog. Returns false if there is none.
    static func start(_ acpi: AcpiTables) -> Bool {
        guard let description = SbsaWatchdog.find(acpi) else { return false }
        let device = MapAttributes(writable: true, cache: .device, global: true)
        let page = KernelLayout.pageSize
        let control: UInt64, refresh: UInt64
        do throws(VmError) {
            control = try kernelAspace.mapPhysical(description.controlFrame & ~(page - 1), size: page, device)
                + (description.controlFrame & (page - 1))
            refresh = try kernelAspace.mapPhysical(description.refreshFrame & ~(page - 1), size: page, device)
                + (description.refreshFrame & (page - 1))
        } catch {
            return false
        }
        var watchdog = SbsaWatchdog(control: control, refresh: refresh)
        watchdog.enable(timeoutTicks: Clock.frequency * timeoutSeconds)
        active = watchdog
        Timers.arm(deadline: Clock.now() + refreshNanoseconds, kickAndRearm, 0)
        return true
    }

    private static let kickAndRearm: Timers.Callback = { _, _ in
        active?.kick()
        Timers.arm(deadline: Clock.now() + refreshNanoseconds, kickAndRearm, 0)
    }
}
