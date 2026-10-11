import CKernel
import Fmt

#if arch(x86_64)
/// Interrupt remapping (K12f; VT-d chapter 5): every device interrupt goes
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
enum InterruptRemapping {
    nonisolated(unsafe) static var enabled = false
    /// x2APIC destinations (EIME): 32-bit APIC ids.
    nonisolated(unsafe) static var extended = false
    nonisolated(unsafe) static var table: UInt64 = 0  // physical
    static var entryCount: Int { 8192 }               // IRTA.S = 12
    static var msiFirst: Int { 128 }
    static let lock = SpinLock()

    static func gsiIndex(_ gsi: UInt32) -> Int { Int(gsi) }

    static func msiIndex(cpu: Int, vector: UInt32) -> Int {
        msiFirst + cpu * Int(DeviceIrqs.msiVectorCount) + Int(vector - DeviceIrqs.msiFirstVector)
    }

    /// Whether an APIC id can be a destination.
    static func reaches(_ apicId: UInt64) -> Bool { extended ? apicId <= 0xFFFF_FFFF : apicId <= 0xFF }

    /// What a device writes for entry `index`: the remappable format
    /// (interrupt format bit 4, SHV bit 3, handle in bits 19:5 and 2), data
    /// the subhandle (0; a multi-message MSI adds its message number).
    static func message(_ index: Int) -> (address: UInt64, data: UInt32) {
        let handle = UInt64(index)
        return (0xFEE0_0000 | (handle & 0x7FFF) << 5 | ((handle >> 15) & 1) << 2 | 1 << 4 | 1 << 3, 0)
    }

    /// Writes entry `index` (present: fixed delivery, physical destination)
    /// and invalidates it on every unit. `source`: the requester id to
    /// verify, or nil for none.
    static func set(_ index: Int, vector: UInt32, apicId: UInt64, level: Bool, source: UInt16?) {
        let destination = extended ? apicId : (apicId & 0xFF) << 8  // xAPIC: bits 47:40
        let low = 1 | (level ? 1 << 4 : 0) | UInt64(vector) << 16 | destination << 32
        let high: UInt64 = source.map { UInt64($0) | 1 << 18 } ?? 0  // SID, SQ 0, SVT 01
        write(index, low: low, high: high)
    }

    /// Entry `index` not present (its interrupts fault), invalidated.
    static func clear(_ index: Int) {
        write(index, low: 0, high: 0)
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
