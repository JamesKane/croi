import _Volatile
import CKernel
import Fmt
import PageTables
import Synchronization

#if arch(arm64)
/// The GICv3 ITS (K12h; the GICv3/v4 architecture specification, IHI 0069,
/// chapters 5-6): MSIs on arm64, and the arm64 side of interrupt
/// remapping. A device writes an EventID to GITS_TRANSLATER; the ITS turns
/// (DeviceID, EventID) into an LPI through the device's interrupt
/// translation table (ITT) and delivers it to a collection, one per CPU.
/// DeviceIDs come from the IORT (a root complex's mapping, or an SMMUv3
/// stream id's), so a device can raise only the events mapped for it.
///
/// Zircon's msi_allocate comes before the device is known, so EventIDs are
/// global: an allocation takes `count` consecutive ones, aligned, from 2048
/// (LPI = 8192 + EventID), and each device's ITT covers all 2048. msi_create
/// finds the device and maps the event (MAPD once per device, MAPTI, the
/// LPI enabled, INV, SYNC); set_affinity is a MOVI (the message stays);
/// the end is a DISCARD.
///
/// LPI tables: one configuration table for every redistributor (14 INTID
/// bits: LPIs 8192-16383, a byte each: priority 0x80, enable), a pending
/// table per CPU (64 KiB aligned), both programmed before each CPU's
/// EnableLPIs (`enableThisCpu`, from GicV3.initializeThisCpu). Commands go
/// through a 4 KiB queue; a batch ends with SYNC and a poll of CREADR (a
/// bounded spin: the ITS starts before the clock does).
///
/// Not yet: GICv4 (vLPIs), two-level device tables (a flat one of up to
/// 2^16 DeviceIDs), more than one ITS.
enum Its {
    nonisolated(unsafe) static var ready = false
    nonisolated(unsafe) private static var registers: UInt64 = 0   // virtual: control frame, translation frame
    nonisolated(unsafe) static var translater: UInt64 = 0          // physical GITS_TRANSLATER
    nonisolated(unsafe) private static var queue: UInt64 = 0       // physical
    nonisolated(unsafe) private static var writer: UInt64 = 0      // CWRITER's offset
    nonisolated(unsafe) private static var ittEntry: UInt64 = 8
    nonisolated(unsafe) private static var deviceBits: Int = 16
    nonisolated(unsafe) private static var targetAddresses = false  // GITS_TYPER.PTA
    nonisolated(unsafe) private static var configTable: UInt64 = 0  // physical
    /// Per CPU: the redistributor's RDbase as MAPC and SYNC want it.
    nonisolated(unsafe) private static var rdBases = InlineArray<64, UInt64>(repeating: 0)
    /// Devices with an ITT: (DeviceID, ITT).
    nonisolated(unsafe) private static var devices = InlineArray<64, (id: UInt32, itt: UInt64)>(repeating: (0, 0))
    nonisolated(unsafe) private static var deviceCount = 0
    nonisolated(unsafe) private static var eventsInUse = InlineArray<32, UInt64>(repeating: 0)
    /// Interrupt objects by EventID (0: none), heap.
    nonisolated(unsafe) private static var handlers: UInt64 = 0
    static let lock = SpinLock()

    static var eventBits: Int { 11 }
    static var events: Int { 1 << eventBits }
    static var firstLpi: UInt32 { 8192 }
    static var idBits: UInt64 { 13 }  // GICR_PROPBASER.IDbits: 14 INTID bits

    // Registers.
    private static var ctlr: UInt64 { 0x0 }
    private static var typer: UInt64 { 0x8 }
    private static var cbaser: UInt64 { 0x80 }
    private static var cwriter: UInt64 { 0x88 }
    private static var creadr: UInt64 { 0x90 }
    private static func baser(_ n: Int) -> UInt64 { 0x100 + UInt64(n) * 8 }

    private static func read32(_ offset: UInt64) -> UInt32 {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(registers + offset)).load()
    }
    private static func write32(_ offset: UInt64, _ value: UInt32) {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(registers + offset)).store(value)
    }
    private static func read64(_ offset: UInt64) -> UInt64 {
        unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: UInt(registers + offset)).load()
    }
    private static func write64(_ offset: UInt64, _ value: UInt64) {
        unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: UInt(registers + offset)).store(value)
    }

    /// Zeroed, `alignLog2`-aligned contiguous memory, cleaned to memory
    /// (the ITS and redistributors may not snoop), or nil.
    private static func table(_ bytes: UInt64, alignLog2: Int) -> UInt64? {
        let pages = (bytes + KernelLayout.pageSize - 1) / KernelLayout.pageSize
        guard let phys = pmm.allocateContiguous(pages, alignLog2: alignLog2, .mmu) else { return nil }
        let virt = KernelLayout.physmap(phys)
        unsafe UnsafeMutableRawPointer(bitPattern: UInt(virt))!
            .initializeMemory(as: UInt8.self, repeating: 0, count: Int(pages * KernelLayout.pageSize))
        arch_cache_op(virt, pages * KernelLayout.pageSize, CROI_CACHE_CLEAN, VmoCache.line)
        return phys
    }

    // MARK: Bring-up (boot CPU, from GicV3.initializeBootCpu)

    /// Maps and starts the ITS at `base`: its tables, the command queue,
    /// the LPI configuration table. False (no MSIs) if anything is missing.
    static func initialize(_ base: UInt64) -> Bool {
        guard base != 0,
              let mapped = try? kernelAspace.mapPhysical(base, size: 0x2_0000,
                                                         MapAttributes(writable: true, cache: .device, global: true)) else {
            return false
        }
        registers = mapped
        translater = base + 0x1_0040
        write32(ctlr, 0)
        var spins = 0
        while read32(ctlr) & (1 << 31) == 0, spins < 10_000_000 { arch_spin_pause(); spins += 1 }  // Quiescent
        let type = read64(typer)
        guard type & 1 != 0 else { return false }  // physical LPIs
        ittEntry = ((type >> 4) & 0xF) + 1
        deviceBits = min(Int((type >> 13) & 0x1F) + 1, 16)
        targetAddresses = type & (1 << 19) != 0
        // Device and collection tables, 64 KiB pages, inner shareable, write-back.
        for n in 0..<8 {
            let value = read64(baser(n))
            let kind = (value >> 56) & 7
            guard kind == 1 || kind == 4 else { continue }  // devices, collections
            let entrySize = ((value >> 48) & 0x1F) + 1
            let entries: UInt64 = kind == 1 ? 1 << UInt64(deviceBits) : 64
            let bytes = (entries * entrySize + 0xFFFF) & ~0xFFFF
            guard bytes / 0x1_0000 <= 256, let phys = table(bytes, alignLog2: 16) else { return false }
            write64(baser(n), 1 << 63 | 7 << 59 | kind << 56 | (entrySize - 1) << 48 | phys | 1 << 10 | 2 << 8
                    | (bytes / 0x1_0000 - 1))
        }
        guard let commands = table(KernelLayout.pageSize, alignLog2: 12),
              let config = table(1 << (idBits + 1) - UInt64(firstLpi), alignLog2: 12),
              let objects = unsafe heap.allocate(size: events * 8) else { return false }
        unsafe objects.initializeMemory(as: UInt8.self, repeating: 0, count: events * 8)
        handlers = UInt64(UInt(bitPattern: objects))
        queue = commands
        configTable = config
        write64(cbaser, 1 << 63 | 7 << 59 | commands | 1 << 10)  // one page
        write64(cwriter, 0)
        write32(ctlr, 1)  // Enabled
        ready = true
        return true
    }

    /// This CPU's LPIs (GicV3.initializeThisCpu, every CPU): the shared
    /// configuration table, a pending table of its own, EnableLPIs; then
    /// its collection (ICID = CPU number) mapped to its redistributor.
    static func enableThisCpu(frame: UInt64, physicalFrame: UInt64) {
        guard ready, let pending = table(0x1_0000, alignLog2: 16) else { return }
        func write64(_ at: UInt64, _ value: UInt64) {
            unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: UInt(at)).store(value)
        }
        let cacheable: UInt64 = 7 << 7 | 1 << 10  // inner write-back, inner shareable
        write64(frame + 0x70, configTable | cacheable | idBits)    // GICR_PROPBASER
        write64(frame + 0x78, pending | cacheable | 1 << 62)       // GICR_PENDBASER, PTZ
        let control = unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(frame))
        control.store(control.load() | 1)                   // EnableLPIs
        let processor = (unsafe VolatileMappedRegister<UInt64>(unsafeBitPattern: UInt(frame + 8)).load() >> 8) & 0xFFFF
        let cpu = Int(Cpu.current)
        guard cpu < rdBases.count else { return }
        rdBases[cpu] = targetAddresses ? physicalFrame >> 16 : processor
        lock.withLock {
            submit(0x09, 0, 1 << 63 | rdBases[cpu] << 16 | UInt64(cpu))  // MAPC
            sync(cpu)
        }
    }

    // MARK: Commands (lock held)

    private static func submit(_ d0: UInt64, _ d1: UInt64, _ d2: UInt64) {
        let next = (writer + 32) % KernelLayout.pageSize
        while read64(creadr) & ~0x1F == next { arch_spin_pause() }  // full: wait for one to go
        let at = unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(queue) + writer))!
        unsafe at[0] = d0
        unsafe at[1] = d1
        unsafe at[2] = d2
        unsafe at[3] = 0
        arch_cache_op(KernelLayout.physmap(queue) + writer, 32, CROI_CACHE_CLEAN, VmoCache.line)
        writer = next
        write64(cwriter, writer)
    }

    /// SYNC to `cpu`'s redistributor, then waits for the queue to drain.
    private static func sync(_ cpu: Int) {
        submit(0x05, 0, rdBases[cpu] << 16)
        var spins = 0
        while read64(creadr) & ~0x1F != writer, spins < 100_000_000 {
            if read64(creadr) & 1 != 0 {  // Stalled: a command error
                panicConsole?.write("its: command queue stalled\n")
                return
            }
            arch_spin_pause()
            spins += 1
        }
    }

    // MARK: Events

    /// `count` (a power of two) consecutive, aligned EventIDs; the first
    /// LPI, or nil.
    static func allocate(count: UInt32) -> UInt32? {
        guard ready else { return nil }
        return lock.withLock { () -> UInt32? in
            var first = 0
            while first + Int(count) <= events {
                var free = true
                for i in first..<(first + Int(count)) where eventsInUse[i / 64] & (1 << UInt64(i % 64)) != 0 { free = false }
                if free {
                    for i in first..<(first + Int(count)) { eventsInUse[i / 64] |= 1 << UInt64(i % 64) }
                    return firstLpi + UInt32(first)
                }
                first += Int(count)
            }
            return nil
        }
    }

    static func free(lpi: UInt32, count: UInt32) {
        lock.withLock {
            for i in Int(lpi - firstLpi)..<Int(lpi - firstLpi + count) { eventsInUse[i / 64] &= ~(1 << UInt64(i % 64)) }
        }
    }

    /// Maps `lpi`'s event for device `deviceId` to CPU `cpu` and enables
    /// it. NO_MEMORY for no ITT, NO_RESOURCES for too many devices.
    static func map(deviceId: UInt32, lpi: UInt32, cpu: Int) throws(Status) {
        guard ready, deviceId < 1 << UInt32(deviceBits) else { throw .notSupported }
        var itt: UInt64 = 0
        let known = lock.withLock { () -> Bool in
            for i in 0..<deviceCount where devices[i].id == deviceId { return true }
            return false
        }
        if !known {
            guard let fresh = table(UInt64(events) * ittEntry, alignLog2: 12) else { throw .noMemory }
            itt = fresh
        }
        try lock.withLock { () throws(Status) in
            var mapped = false
            for i in 0..<deviceCount where devices[i].id == deviceId { mapped = true }
            if !mapped {
                guard deviceCount < devices.count else { throw .noResources }
                devices[deviceCount] = (deviceId, itt)
                deviceCount += 1
                submit(0x08 | UInt64(deviceId) << 32, UInt64(eventBits - 1), 1 << 63 | itt)  // MAPD
            } else if itt != 0 {
                pmm.free(itt, count: (UInt64(events) * ittEntry + KernelLayout.pageSize - 1) / KernelLayout.pageSize)
            }
            setConfig(lpi, enabled: true)
            let event = UInt64(lpi - firstLpi)
            submit(0x0A | UInt64(deviceId) << 32, event | UInt64(lpi) << 32, UInt64(cpu))  // MAPTI
            submit(0x0C | UInt64(deviceId) << 32, event, 0)                                // INV
            sync(cpu)
        }
    }

    /// Moves the event to `cpu`'s collection (the device's message stays).
    static func move(deviceId: UInt32, lpi: UInt32, to cpu: Int) {
        lock.withLock {
            submit(0x01 | UInt64(deviceId) << 32, UInt64(lpi - firstLpi), UInt64(cpu))  // MOVI
            sync(cpu)
        }
    }

    /// Unmaps the event: the device's writes of it go nowhere.
    static func unmap(deviceId: UInt32, lpi: UInt32, cpu: Int) {
        lock.withLock {
            setConfig(lpi, enabled: false)
            submit(0x0F | UInt64(deviceId) << 32, UInt64(lpi - firstLpi), 0)  // DISCARD
            sync(cpu)
        }
    }

    private static func setConfig(_ lpi: UInt32, enabled: Bool) {
        let at = KernelLayout.physmap(configTable) + UInt64(lpi - firstLpi)
        unsafe UnsafeMutablePointer<UInt8>(bitPattern: UInt(at))!.pointee = enabled ? 0x80 | 1 : 0x80
        arch_cache_op(at, 1, CROI_CACHE_CLEAN, VmoCache.line)
    }

    // MARK: Delivery (DeviceIrqs's table lock held)

    static func setHandler(lpi: UInt32, _ object: UInt64) {
        guard handlers != 0, lpi >= firstLpi, lpi < firstLpi + UInt32(events) else { return }
        unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(handlers))![Int(lpi - firstLpi)] = object
    }

    /// The interrupt object for `lpi`, or 0.
    static func handler(_ lpi: UInt32) -> UInt64 {
        guard handlers != 0, lpi >= firstLpi, lpi < firstLpi + UInt32(events) else { return 0 }
        return unsafe UnsafePointer<UInt64>(bitPattern: UInt(handlers))![Int(lpi - firstLpi)]
    }
}
#endif
