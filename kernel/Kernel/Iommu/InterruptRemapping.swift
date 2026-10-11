import CKernel
import Fmt

#if arch(x86_64)
/// Interrupt remapping (K12f, VT-d chapter 5; K12g, AMD-Vi): every device interrupt goes
/// through an interrupt remapping table entry (IRTE) the kernel wrote, so a
/// device can raise only the vectors, on only the CPUs, that it was given,
/// and destinations are 32-bit x2APIC ids (extended interrupt mode).
///
/// The kernel turns it on at boot (`Vtd.boot`) when the DMAR says the
/// platform supports it (INTR_REMAP), every remapping unit has IR and
/// queued invalidation, extended interrupt mode is there if the CPUs use
/// x2APIC, and `croi.intremap=off` isn't given. One table serves every
/// unit (each unit's IRTA points at it; a change is invalidated on all),
/// and compatibility-format interrupts are blocked (CFI clear): a device
/// writing an old-style MSI gets nothing delivered and the unit logs a
/// fault.
///
/// Entries are fixed per source, so nothing is allocated at interrupt
/// time: GSI g uses entry g (IOAPIC pins, vector 0x30 + g), and the MSI
/// vector v on CPU c entry 128 + c * 64 + (v - 0xB0), linear in v, so a
/// multi-message MSI's subhandle (added to the data's low bits by the
/// device) lands on the next vector's entry. IOAPIC entries verify the
/// IOAPIC's source id (the DMAR's IOAPIC scopes); a plain MSI verifies the
/// requester id its capability's ECAM address names; MSI-X entries, whose
/// table doesn't name the function, are unverified.
///
/// AMD-Vi (`Amdvi.boot`, K12g): an MSI's data bits 10:0 index the table
/// its device's table entry names, the address's destination unused. The
/// kernel can't tell which device an MSI-X table belongs to, so every
/// device entry names one 2048-entry table (no source verification; DMA
/// isolation is the device table's, unaffected). An IOAPIC pin's index is
/// its vector, 0x30 + GSI, so its redirection entry is the one it always
/// had and the end-of-interrupt broadcast still matches it; MSIs get
/// indices from 0x100 up, allocated with their vectors (`allocateMsi`),
/// consecutive and aligned for multi-message MSI, as data, the address
/// 0xFEE00000. Entries are 128-bit with x2APIC destinations (GA mode and
/// XT on every unit), else 32-bit with 8-bit ones; every change is
/// followed by INVALIDATE_IOMMU_ALL (IASup required).
enum InterruptRemapping {
    enum Mode { case vtd, amd }
    nonisolated(unsafe) static var mode = Mode.vtd
    nonisolated(unsafe) static var enabled = false
    /// x2APIC destinations (VT-d EIME, AMD-Vi GA + XT): 32-bit APIC ids.
    nonisolated(unsafe) static var extended = false
    nonisolated(unsafe) static var table: UInt64 = 0  // physical
    static var entryCount: Int { mode == .vtd ? 8192 : 2048 }  // VT-d IRTA.S = 12; AMD IntTabLen 11
    static var msiFirst: Int { mode == .vtd ? 128 : 0x100 }
    static let lock = SpinLock()
    /// AMD-Vi: each (CPU, MSI vector)'s index (0: none), heap; and the
    /// indices in use from `msiFirst`, a bit each.
    nonisolated(unsafe) static var amdIndices: UInt64 = 0
    nonisolated(unsafe) static var amdInUse = InlineArray<32, UInt64>(repeating: 0)

    static func gsiIndex(_ gsi: UInt32) -> Int {
        mode == .vtd ? Int(gsi) : Int(IoApic.firstVector + gsi)
    }

    private static func slot(cpu: Int, vector: UInt32) -> Int {
        cpu * Int(DeviceIrqs.msiVectorCount) + Int(vector - DeviceIrqs.msiFirstVector)
    }

    static func msiIndex(cpu: Int, vector: UInt32) -> Int {
        if mode == .vtd { return msiFirst + slot(cpu: cpu, vector: vector) }
        return Int(unsafe UnsafePointer<UInt16>(bitPattern: UInt(amdIndices))![slot(cpu: cpu, vector: vector)])
    }

    /// AMD-Vi: the table, and room to map each (CPU, vector) to an index.
    static func startAmd(extended: Bool) -> Bool {
        mode = .amd
        self.extended = extended
        let bytes = UInt64(entryCount * (extended ? 16 : 4))
        let pages = (bytes + KernelLayout.pageSize - 1) / KernelLayout.pageSize
        let slots = 64 * Int(DeviceIrqs.msiVectorCount)
        guard let table = pmm.allocateContiguous(pages, alignLog2: 12, .mmu),
              let map = unsafe heap.allocate(size: slots * 2) else { return false }
        unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(table)))!
            .initializeMemory(as: UInt8.self, repeating: 0, count: Int(pages * KernelLayout.pageSize))
        unsafe map.initializeMemory(as: UInt8.self, repeating: 0, count: slots * 2)
        self.table = table
        amdIndices = UInt64(UInt(bitPattern: map))
        return true
    }

    /// AMD-Vi: `count` (a power of two) consecutive indices, aligned to it,
    /// for the vectors from `vector` on `cpu`. False if none are free.
    static func allocateMsiIndices(cpu: Int, vector: UInt32, count: UInt32) -> Bool {
        guard enabled, mode == .amd else { return true }
        return lock.withLock { () -> Bool in
            var first = msiFirst
            while first + Int(count) <= entryCount {
                var free = true
                for i in first..<(first + Int(count)) where amdInUse[i / 64] & (1 << UInt64(i % 64)) != 0 { free = false }
                if free {
                    let map = unsafe UnsafeMutablePointer<UInt16>(bitPattern: UInt(amdIndices))!
                    for i in 0..<Int(count) {
                        amdInUse[(first + i) / 64] |= 1 << UInt64((first + i) % 64)
                        unsafe map[slot(cpu: cpu, vector: vector + UInt32(i))] = UInt16(first + i)
                    }
                    return true
                }
                first += Int(count)
            }
            return false
        }
    }

    static func freeMsiIndices(cpu: Int, vector: UInt32, count: UInt32) {
        guard enabled, mode == .amd else { return }
        lock.withLock {
            let map = unsafe UnsafeMutablePointer<UInt16>(bitPattern: UInt(amdIndices))!
            for i in 0..<Int(count) {
                let at = slot(cpu: cpu, vector: vector + UInt32(i))
                let index = Int(unsafe map[at])
                if index != 0 { amdInUse[index / 64] &= ~(1 << UInt64(index % 64)) }
                unsafe map[at] = 0
            }
        }
    }

    /// Whether an APIC id can be a destination.
    static func reaches(_ apicId: UInt64) -> Bool { extended ? apicId <= 0xFFFF_FFFF : apicId <= 0xFF }

    /// What a device writes for entry `index`: the remappable format
    /// (interrupt format bit 4, SHV bit 3, handle in bits 19:5 and 2), data
    /// the subhandle (0; a multi-message MSI adds its message number).
    static func message(_ index: Int) -> (address: UInt64, data: UInt32) {
        if mode == .amd { return (0xFEE0_0000, UInt32(index)) }  // AMD-Vi: the index is the data
        let handle = UInt64(index)
        return (0xFEE0_0000 | (handle & 0x7FFF) << 5 | ((handle >> 15) & 1) << 2 | 1 << 4 | 1 << 3, 0)
    }

    /// Writes entry `index` (present: fixed delivery, physical destination)
    /// and invalidates it on every unit. `source`: the requester id to
    /// verify, or nil for none.
    static func set(_ index: Int, vector: UInt32, apicId: UInt64, level: Bool, source: UInt16?) {
        if mode == .amd {
            // RemapEn, fixed, physical; 128-bit: destination 23:0 in bits
            // 31:8 and 31:24 in the high word's top byte, vector low there.
            if extended {
                writeAmd(index, low: 1 | (apicId & 0xFF_FFFF) << 8, high: UInt64(vector) | (apicId >> 24) << 56)
            } else {
                writeAmd(index, low: 1 | (apicId & 0xFF) << 8 | UInt64(vector) << 16, high: 0)
            }
            return
        }
        let destination = extended ? apicId : (apicId & 0xFF) << 8  // xAPIC: bits 47:40
        let low = 1 | (level ? 1 << 4 : 0) | UInt64(vector) << 16 | destination << 32
        let high: UInt64 = source.map { UInt64($0) | 1 << 18 } ?? 0  // SID, SQ 0, SVT 01
        write(index, low: low, high: high)
    }

    /// Entry `index` not present (its interrupts fault), invalidated.
    static func clear(_ index: Int) {
        if mode == .amd { return writeAmd(index, low: 0, high: 0) }
        write(index, low: 0, high: 0)
    }

    /// Points `gsi`'s IOAPIC pin at its entry: VT-d's remappable format;
    /// AMD-Vi's ordinary one (its vector is the index). Controller lock held.
    static func programIoApic(_ gsi: UInt32, level: Bool, activeLow: Bool) {
        if mode == .amd {
            IoApic.program(gsi, level: level, activeLow: activeLow, apicId: 0)  // the destination is the entry's
        } else {
            IoApic.programRemapped(gsi, level: level, activeLow: activeLow, index: gsiIndex(gsi))
        }
    }

    private static func writeAmd(_ index: Int, low: UInt64, high: UInt64) {
        guard enabled, index < entryCount else { return }
        lock.withLock {
            if extended {
                let entry = unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(table) + UInt64(index) * 16))!
                unsafe entry[0] = 0
                unsafe entry[1] = high
                unsafe entry[0] = low
            } else {
                unsafe UnsafeMutablePointer<UInt32>(bitPattern: UInt(KernelLayout.physmap(table) + UInt64(index) * 4))!
                    .pointee = UInt32(truncatingIfNeeded: low)
            }
        }
        Amdvi.invalidateInterrupts()
    }

    private static func write(_ index: Int, low: UInt64, high: UInt64) {
        guard enabled, index < entryCount else { return }
        lock.withLock {
            let entry = unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(table) + UInt64(index) * 16))!
            // Not present while it changes, high half before the low one.
            unsafe entry[0] = 0
            unsafe entry[1] = high
            unsafe entry[0] = low
        }
        Vtd.invalidateInterruptEntry(index, flush: table + UInt64(index) * 16)
    }
}
#endif
