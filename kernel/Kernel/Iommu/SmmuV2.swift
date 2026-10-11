import _Volatile
import CKernel
import Fmt
import PageTables
import Synchronization

#if arch(arm64)
/// Arm SMMUv1/v2 (MMU-500) DMA translation (K12d; the SMMU architecture
/// specification v2, IHI 0062, and AbyssBSD's qcom_smmu/qcom_apps_smmu on
/// the Radxa Dragon Q8B, whose rules this follows). Zircon's ABI:
/// iommu_create(ARM_SMMU, zx_iommu_desc_arm_smmu_t) with an IORT SMMUv1/v2
/// node's base; bti_create's id names stream match pairs, as Zircon's
/// (value | mask << 16, 15 bits each), plus croi's second pair in bits
/// 32-62 when bit 63 is set (a device with two stream families, such as
/// the Q8B's video codec).
///
/// Firmware owns the SMMU: it is on, faulting streams nobody matched, with
/// entries and banks for firmware's own devices (the Q8B's display, USB,
/// PCIe and SD go through identity banks UEFI set up), and a hypervisor
/// may police every write (the Q8B's resets the SoC, with no dump, on a
/// CBAR written other than as stage 1, or on stream match pairs other than
/// Linux's). So this driver never touches the global registers, never
/// resets, and never changes what firmware set up:
/// - a stream match entry is free if it is invalid and faulting; a bank if
///   no valid entry routes to it and its CBAR is 0, or this driver set it
///   up and let it go;
/// - a claim programs the bank (CBAR only ever 0x1f300: stage 1, stage 2
///   bypass, write-back attributes, as Linux writes it), then each S2CR,
///   then each SMR, which makes the stream live; pairs overlapping a valid
///   entry are refused (ALREADY_BOUND);
/// - a release makes the SMRs invalid and the S2CRs faulting, then turns
///   the bank's translation off (SCTLR only) and invalidates its TLB.
/// The pairs are the caller's: the hypervisor checks them exactly.
///
/// Banks translate one domain's stage-1 tables (ASID = bank index) with a
/// 36- to 48-bit input (IDR2.UBS; 36 starts the walk at level 1). Each
/// bank's context fault interrupt (IORT order is bank order, edge) is the
/// kernel's once the bank is used; faults are counted and logged, then
/// cleared (the transaction is terminated, not stalled).
///
/// Not yet: SMMUs firmware left disabled (CLIENTPD; nothing to inherit,
/// NOT_SUPPORTED), extended stream ids, the GPU's split TTBR1 and per-
/// process TTBR0, global fault reporting (some hypervisors reboot instead).
enum SmmuV2 {
    nonisolated(unsafe) static var units = InlineArray<4, UInt64>(repeating: 0)
    nonisolated(unsafe) static var unitCount = 0
    static let unitsLock = Mutex()

    // GR0 offsets.
    static var scr0: UInt64 { 0x000 }
    static var idr0: UInt64 { 0x020 }
    static var idr1: UInt64 { 0x024 }
    static var idr2: UInt64 { 0x028 }
    static func smr(_ n: Int) -> UInt64 { 0x800 + UInt64(n) * 4 }
    static func s2cr(_ n: Int) -> UInt64 { 0xC00 + UInt64(n) * 4 }
    // GR1 offsets (one page above GR0).
    static func cbar(_ n: Int) -> UInt64 { UInt64(n) * 4 }
    static func cba2r(_ n: Int) -> UInt64 { 0x800 + UInt64(n) * 4 }
    // Context bank offsets.
    static var sctlr: UInt64 { 0x000 }
    static var tcr2: UInt64 { 0x010 }
    static var ttbr0: UInt64 { 0x020 }
    static var tcr: UInt64 { 0x030 }
    static var contextIdr: UInt64 { 0x034 }
    static var mair0: UInt64 { 0x038 }
    static var mair1: UInt64 { 0x03C }
    static var fsr: UInt64 { 0x058 }
    static var far: UInt64 { 0x060 }
    static var fsynr0: UInt64 { 0x068 }
    static var tlbiAsid: UInt64 { 0x610 }
    static var tlbSync: UInt64 { 0x7F0 }
    static var tlbStatus: UInt64 { 0x7F4 }

    static var smrValid: UInt32 { 1 << 31 }
    static var s2crFault: UInt32 { 2 << 16 }
    /// Stage 1 translation, stage 2 bypass, bypass shareability NSH,
    /// write-back attributes: the only CBAR value written.
    static var cbarStage1: UInt32 { 1 << 16 | 0xF << 12 | 3 << 8 }
    static var fsrFaults: UInt32 { 0xC000_01FE }

    static func create(_ descriptor: RawSpan) throws(Status) -> UInt64 {
        guard descriptor.byteCount == MemoryLayout<UInt64>.size else { throw .invalidArgs }
        let base = unsafe descriptor.unsafeLoadUnaligned(as: UInt64.self)
        guard let index = Iort.smmuV2(base) else { throw .notFound }
        unitsLock.lock()
        defer { unitsLock.unlock() }
        for i in 0..<unitCount where SmmuV2UnitPointer(address: units[i]).pointee.registerBase == base {
            let unit = SmmuV2UnitPointer(address: units[i])
            guard !unit.pointee.bound else { throw .alreadyBound }
            unit.pointee.bound = true
            return unit.address
        }
        guard unitCount < units.count else { throw .noResources }
        let node = Iort.v2Nodes[index]
        let registers: UInt64
        do throws(VmError) {
            registers = try kernelAspace.mapPhysical(base, size: (node.span + KernelLayout.pageSize - 1) & ~(KernelLayout.pageSize - 1),
                                                     MapAttributes(writable: true, cache: .device, global: true))
        } catch {
            throw .noMemory
        }
        let unit = try SmmuV2UnitPointer.make(registers: registers, base: base, span: node.span,
                                              coherent: node.coherentWalks, interrupts: node.interrupts,
                                              interruptCount: node.contextInterrupts)
        unit.pointee.bound = true
        units[unitCount] = unit.address
        unitCount += 1
        return unit.address
    }

    static func unbind(_ address: UInt64) {
        unitsLock.lock()
        SmmuV2UnitPointer(address: address).pointee.bound = false
        unitsLock.unlock()
    }

    static func faultsCounted() -> UInt64 {
        var total: UInt64 = 0
        for i in 0..<unitCount { total += SmmuV2UnitPointer(address: units[i]).pointee.faults }
        return total
    }

    /// A bank's fault interrupt: the argument is unit index << 8 | bank.
    static let faultInterrupt: DeviceIrqs.KernelHandler = { argument in
        let index = Int(argument >> 8)
        guard index < SmmuV2.unitCount else { return }
        SmmuV2UnitPointer(address: SmmuV2.units[index]).drainFaults(bank: Int(argument & 0xFF))
    }

    // MARK: Devices

    /// The pairs bti_create's id names: (id, mask), and how many (1 or 2).
    /// INVALID_ARGS for bits outside them.
    static func pairs(_ streams: UInt64) throws(Status) -> (InlineArray<2, (id: UInt16, mask: UInt16)>, Int) {
        var out = InlineArray<2, (id: UInt16, mask: UInt16)>(repeating: (0, 0))
        let first = UInt32(truncatingIfNeeded: streams)
        guard first & (1 << 15 | 1 << 31) == 0 else { throw .invalidArgs }
        out[0] = (UInt16(first & 0x7FFF), UInt16(first >> 16))
        guard streams & (1 << 63) != 0 else {
            guard streams >> 32 == 0 else { throw .invalidArgs }
            return (out, 1)
        }
        let second = UInt32(truncatingIfNeeded: streams >> 32) & 0x7FFF_FFFF
        guard second & (1 << 15) == 0 else { throw .invalidArgs }
        out[1] = (UInt16(second & 0x7FFF), UInt16(second >> 16))
        return (out, 2)
    }

    /// Claims the streams `streams` names: a free bank translating a domain
    /// of its own, free stream match entries routing them to it.
    static func attach(_ unit: SmmuV2UnitPointer, streams: UInt64) throws(Status) -> IoDomainPointer {
        let (wanted, count) = try pairs(streams)
        // Choose under the lock; the bank and entries are reserved by
        // marking them (bank: `claimed`; entries: written last, so a
        // concurrent claim must not pick them: `pending`).
        let (bank, entries) = try unit.pointee.lock.withLock { () throws(Status) -> (Int, InlineArray<2, Int>) in
            try unit.choose(wanted, count)
        }
        let levels = unit.pointee.inputBits <= 39 ? 3 : 4
        guard let domain = IoDomains.make(.smmuV2, unit: unit.address, id: UInt16(bank), deviceId: UInt16(truncatingIfNeeded: streams),
                                          levels: levels, inputBits: unit.pointee.inputBits) else {
            unit.pointee.lock.withLock { unit.unreserve(bank, entries, count) }
            throw .noMemory
        }
        domain.pointee.extra = UInt64(bank) | UInt64(entries[0]) << 8 | UInt64(count == 2 ? entries[1] : 0xFF) << 16
        unit.installInterrupt(bank)
        unit.pointee.lock.withLock {
            unit.programBankLocked(bank, root: domain.pointee.root)
            for i in 0..<count {
                // What points at the bank, then what makes the stream live.
                unit.write32(SmmuV2.s2cr(entries[i]), UInt32(bank))
                arch_device_write_barrier()
                unit.write32(SmmuV2.smr(entries[i]), SmmuV2.smrValid | UInt32(wanted[i].mask) << 16 | UInt32(wanted[i].id))
                arch_device_write_barrier()
            }
            unit.clearPending(entries, count)
        }
        return domain
    }

    /// The streams fault again and the bank stops translating (CBAR is left
    /// as it is); the bank stays this driver's to set up again.
    static func detach(_ domain: IoDomainPointer) {
        let unit = SmmuV2UnitPointer(address: domain.pointee.unit)
        let extra = domain.pointee.extra
        let bank = Int(extra & 0xFF)
        unit.pointee.lock.withLock {
            for i in 0..<2 {
                let entry = Int((extra >> UInt64(8 + 8 * i)) & 0xFF)
                guard entry != 0xFF else { continue }
                unit.write32(SmmuV2.smr(entry), 0)
                arch_device_write_barrier()
                unit.write32(SmmuV2.s2cr(entry), SmmuV2.s2crFault)
                arch_device_write_barrier()
            }
            unit.bankWrite(bank, SmmuV2.sctlr, 0)
            unit.invalidateBankLocked(bank)
            unit.pointee.claimed[bank / 64] &= ~(1 << UInt64(bank % 64))
        }
        IoDomains.free(domain)
    }
}

/// One SMMUv2's state (heap, never freed).
struct SmmuV2Unit: ~Copyable {
    let registers: UInt64     // virtual
    let registerBase: UInt64  // physical (0: the self-test's stand-in)
    let pageSize: UInt64
    let bankBase: UInt64      // offset of bank 0's page
    let streamMatches: Int
    let banks: Int
    let outputSize: UInt32    // IDR2.OAS = TCR2.PASIZE
    let inputBits: UInt64
    let coherent: Bool
    let interrupts: UInt64    // heap: GSIV | edge << 32 per bank, 0: none
    let interruptCount: Int
    let lock = SpinLock()
    /// Banks this driver programmed (reusable though CBAR isn't 0), banks
    /// claimed now, entries chosen but not yet written, interrupts taken.
    var ours = InlineArray<2, UInt64>(repeating: 0)
    var claimed = InlineArray<2, UInt64>(repeating: 0)
    var pending = InlineArray<2, UInt64>(repeating: 0)
    var installed = InlineArray<2, UInt64>(repeating: 0)
    var bound = false
    var faults: UInt64 = 0
    /// Self-test: register writes recorded (offset << 32 | value), heap.
    var log: UInt64 = 0
    var logCount = 0
    var logCapacity = 0
}

@safe struct SmmuV2UnitPointer {
    let address: UInt64

    var pointee: SmmuV2Unit {
        unsafeAddress { unsafe UnsafePointer<SmmuV2Unit>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<SmmuV2Unit>(bitPattern: UInt(address))! }
    }

    func read32(_ offset: UInt64) -> UInt32 {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(pointee.registers + offset)).load()
    }

    func write32(_ offset: UInt64, _ value: UInt32) {
        if pointee.log != 0, pointee.logCount < pointee.logCapacity {
            unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(pointee.log))![pointee.logCount] = offset << 32 | UInt64(value)
            pointee.logCount += 1
        }
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(pointee.registers + offset)).store(value)
    }

    func gr1(_ offset: UInt64) -> UInt64 { pointee.pageSize + offset }
    func bank(_ n: Int, _ offset: UInt64) -> UInt64 { pointee.bankBase + UInt64(n) * pointee.pageSize + offset }
    func bankRead(_ n: Int, _ offset: UInt64) -> UInt32 { read32(bank(n, offset)) }
    func bankWrite(_ n: Int, _ offset: UInt64, _ value: UInt32) { write32(bank(n, offset), value) }

    // MARK: Creation

    /// Reads the configuration of a firmware-enabled SMMU at `registers`.
    static func make(registers: UInt64, base: UInt64, span: UInt64, coherent: Bool,
                     interrupts: UInt64, interruptCount: Int) throws(Status) -> SmmuV2UnitPointer {
        func read(_ offset: UInt64) -> UInt32 {
            unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(registers + offset)).load()
        }
        let idr0 = read(SmmuV2.idr0), idr1 = read(SmmuV2.idr1), idr2 = read(SmmuV2.idr2)
        guard read(SmmuV2.scr0) & 1 == 0 else { throw .notSupported }  // CLIENTPD: firmware left it off
        let pageSize: UInt64 = idr1 & (1 << 31) != 0 ? 0x10000 : 0x1000
        let bankBase = pageSize << UInt64(((idr1 >> 28) & 7) + 1)
        let banks = min(Int(idr1 & 0xFF), 128)
        let streamMatches = min(Int(idr0 & 0xFF), 128)
        let outputSize = min((idr2 >> 4) & 0xF, 5)
        let ubs = (idr2 >> 8) & 0xF
        let inputBits: UInt64 = ubs == 0 ? 32 : ubs == 1 ? 36 : ubs == 2 ? 40 : ubs == 3 ? 42 : ubs == 4 ? 44 : 48
        guard banks > 0, streamMatches > 0, bankBase + UInt64(banks) * pageSize <= span else { throw .notSupported }
        guard let raw = unsafe heap.allocate(size: MemoryLayout<SmmuV2Unit>.size, alignment: 64) else { throw .noMemory }
        unsafe raw.bindMemory(to: SmmuV2Unit.self, capacity: 1).initialize(to: SmmuV2Unit(
            registers: registers, registerBase: base, pageSize: pageSize, bankBase: bankBase,
            streamMatches: streamMatches, banks: banks, outputSize: outputSize, inputBits: inputBits,
            coherent: coherent, interrupts: interrupts, interruptCount: interruptCount))
        return SmmuV2UnitPointer(address: UInt64(UInt(bitPattern: raw)))
    }

    // MARK: Choosing (unit lock held)

    private func bit(_ set: InlineArray<2, UInt64>, _ n: Int) -> Bool { set[n / 64] & (1 << UInt64(n % 64)) != 0 }

    /// A free bank and free entries for the pairs, reserved; ALREADY_BOUND
    /// if a pair overlaps a valid entry, NO_RESOURCES if none are free.
    func choose(_ wanted: InlineArray<2, (id: UInt16, mask: UInt16)>, _ count: Int) throws(Status) -> (Int, InlineArray<2, Int>) {
        var routed = InlineArray<2, UInt64>(repeating: 0)  // banks a valid translating entry uses
        for n in 0..<pointee.streamMatches {
            let smr = read32(SmmuV2.smr(n))
            guard smr & SmmuV2.smrValid != 0 || bit(pointee.pending, n) else { continue }
            let id = smr & 0x7FFF, mask = (smr >> 16) & 0x7FFF
            for i in 0..<count where (id ^ UInt32(wanted[i].id)) & ~(mask | UInt32(wanted[i].mask)) & 0x7FFF == 0 {
                if smr & SmmuV2.smrValid != 0 { throw .alreadyBound }
            }
            let s2cr = read32(SmmuV2.s2cr(n))
            if (s2cr >> 16) & 3 == 0 { routed[Int(s2cr & 0xFF) / 64] |= 1 << UInt64((s2cr & 0xFF) % 64) }
        }
        var entries = InlineArray<2, Int>(repeating: -1)
        var found = 0
        for n in 0..<pointee.streamMatches where found < count {
            guard !bit(pointee.pending, n), read32(SmmuV2.smr(n)) & SmmuV2.smrValid == 0,
                  (read32(SmmuV2.s2cr(n)) >> 16) & 3 == 2 else { continue }
            entries[found] = n
            found += 1
        }
        guard found == count else { throw .noResources }
        for b in 0..<pointee.banks where !bit(routed, b) && !bit(pointee.claimed, b) {
            guard read32(gr1(SmmuV2.cbar(b))) == 0 || bit(pointee.ours, b) else { continue }
            pointee.claimed[b / 64] |= 1 << UInt64(b % 64)
            pointee.ours[b / 64] |= 1 << UInt64(b % 64)
            for i in 0..<count { pointee.pending[entries[i] / 64] |= 1 << UInt64(entries[i] % 64) }
            return (b, entries)
        }
        throw .noResources
    }

    func unreserve(_ bank: Int, _ entries: InlineArray<2, Int>, _ count: Int) {
        pointee.claimed[bank / 64] &= ~(1 << UInt64(bank % 64))
        clearPending(entries, count)
    }

    func clearPending(_ entries: InlineArray<2, Int>, _ count: Int) {
        for i in 0..<count { pointee.pending[entries[i] / 64] &= ~(1 << UInt64(entries[i] % 64)) }
    }

    // MARK: Banks (unit lock held)

    /// As Linux and AbyssBSD set a bank up: off, attributes, translation
    /// controls, ASID = the bank's index, MAIR (0: write-back, 1:
    /// non-cacheable), faults cleared, then on, terminating faults.
    func programBankLocked(_ n: Int, root: UInt64) {
        let walk: UInt32 = pointee.coherent ? 1 << 8 | 1 << 10 | 3 << 12 : 0  // IRGN0/ORGN0 WBWA, SH0 inner
        bankWrite(n, SmmuV2.sctlr, 0)
        write32(gr1(SmmuV2.cba2r(n)), 1)  // VA64
        write32(gr1(SmmuV2.cbar(n)), SmmuV2.cbarStage1)
        bankWrite(n, SmmuV2.tcr2, pointee.outputSize | 7 << 15)  // PASIZE, SEP_UPSTREAM
        bankWrite(n, SmmuV2.tcr, UInt32(64 - pointee.inputBits) | walk | 1 << 23)  // T0SZ, 4 KiB, EPD1
        bankWrite(n, SmmuV2.contextIdr, UInt32(n))
        let ttbr = root | UInt64(n) << 48
        bankWrite(n, SmmuV2.ttbr0, UInt32(truncatingIfNeeded: ttbr))
        bankWrite(n, SmmuV2.ttbr0 + 4, UInt32(truncatingIfNeeded: ttbr >> 32))
        bankWrite(n, SmmuV2.mair0, 0x44FF)
        bankWrite(n, SmmuV2.mair1, 0)
        bankWrite(n, SmmuV2.fsr, bankRead(n, SmmuV2.fsr))
        let interrupt: UInt32 = bit(pointee.installed, n) ? 1 << 6 : 0  // CFIE
        // M, TRE, AFE, CFRE, ASIDPNE.
        bankWrite(n, SmmuV2.sctlr, 1 | 1 << 1 | 1 << 2 | 1 << 5 | 1 << 12 | interrupt)
        invalidateBankLocked(n)
    }

    /// TLBIASID and a sync (10 ms at most).
    func invalidateBankLocked(_ n: Int) {
        arch_device_write_barrier()
        bankWrite(n, SmmuV2.tlbiAsid, UInt32(n))
        bankWrite(n, SmmuV2.tlbSync, 0)
        let giveUp = Clock.now() + 10_000_000
        while bankRead(n, SmmuV2.tlbStatus) & 1 != 0 {
            guard Clock.now() < giveUp else {
                panicConsole?.write("iommu: SMMUv2 TLB sync timed out\n")
                return
            }
            arch_spin_pause()
        }
    }

    func invalidateBank(_ n: Int) {
        pointee.lock.withLock { invalidateBankLocked(n) }
    }

    func flushTables(_ phys: UInt64, _ size: UInt64) {
        if !pointee.coherent { arch_cache_op(KernelLayout.physmap(phys), size, CROI_CACHE_CLEAN, VmoCache.line) }
    }

    // MARK: Faults

    /// Takes bank `n`'s fault interrupt for the kernel, once.
    func installInterrupt(_ n: Int) {
        guard n < pointee.interruptCount, pointee.interrupts != 0, !bit(pointee.installed, n) else { return }
        var index = 0
        for i in 0..<SmmuV2.unitCount where SmmuV2.units[i] == address { index = i }
        let word = unsafe UnsafePointer<UInt64>(bitPattern: UInt(pointee.interrupts))![n]
        let edge = word >> 32 != 0
        if DeviceIrqs.setKernelHandler(UInt32(truncatingIfNeeded: word), level: !edge, SmmuV2.faultInterrupt,
                                       UInt64(index) << 8 | UInt64(n)) {
            pointee.installed[n / 64] |= 1 << UInt64(n % 64)
        }
    }

    /// Reads, logs and clears bank `n`'s faults (a few per interrupt: the
    /// edge-triggered interrupt stays asserted while FSR has any set).
    func drainFaults(bank n: Int) {
        pointee.lock.withLock {
            var handled = 0
            while handled < 16 {
                let status = bankRead(n, SmmuV2.fsr) & SmmuV2.fsrFaults
                guard status != 0 else { return }
                pointee.faults += 1
                if handled < 4, let console = panicConsole {
                    let address = UInt64(bankRead(n, SmmuV2.far)) | UInt64(bankRead(n, SmmuV2.far + 4)) << 32
                    console.write("iommu: DMA fault in SMMUv2 bank ")
                    console.write(decimal: UInt64(n))
                    console.write(bankRead(n, SmmuV2.fsynr0) & (1 << 4) != 0 ? " writing " : " reading ")
                    console.write(hex: address)
                    console.write(", FSR ")
                    console.write(hex: UInt64(status))
                    console.write("\n")
                }
                bankWrite(n, SmmuV2.fsr, status)
                handled += 1
            }
            bankWrite(n, SmmuV2.fsr, SmmuV2.fsrFaults)
        }
    }
}
#endif
