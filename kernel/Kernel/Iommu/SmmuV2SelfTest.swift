import CKernel
import Fmt

#if arch(arm64)
/// The SMMUv2 driver against a RAM stand-in (QEMU has no SMMUv2), set up
/// as the Q8B's apps SMMU is when UEFI hands over: on, firmware's streams
/// matched to identity banks, 36-bit input. Checks what the hypervisor
/// would police there: nothing written but the claimed entries and bank,
/// CBAR only ever 0x1f300, each stream's S2CR before its SMR, firmware's
/// entries and banks never reused, overlapping pairs refused, a released
/// bank reused. The stand-in's TLBSTATUS reads 0, so syncs end at once.
enum SmmuV2SelfTest {
    static var pageCount: UInt64 { 10 }  // GR0, GR1, 8 banks
    static var banks: UInt32 { 8 }
    static var entries: UInt32 { 16 }

    static func run(_ console: Uart) {
        let bytes = Int(pageCount * KernelLayout.pageSize)
        guard let phys = pmm.allocateContiguous(pageCount),
              let snapshot = unsafe heap.allocate(size: bytes),
              let log = unsafe heap.allocate(size: 256 * 8) else { panic("smmuv2 self-test: no memory") }
        let base = KernelLayout.physmap(phys)
        let regs = unsafe UnsafeMutablePointer<UInt32>(bitPattern: UInt(base))!
        unsafe UnsafeMutableRawPointer(regs).initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        func set(_ offset: UInt64, _ value: UInt32) { unsafe regs[Int(offset / 4)] = value }
        func get(_ offset: UInt64) -> UInt32 { unsafe regs[Int(offset / 4)] }
        let gr1 = KernelLayout.pageSize
        // ID registers: 16 entries; 4 KiB pages, one GR page pair (banks
        // from 8 KiB), 8 banks; IAS, OAS, UBS 36 bits.
        set(SmmuV2.scr0, 0x0024_0406)
        set(SmmuV2.idr0, entries)
        set(SmmuV2.idr1, banks)
        set(SmmuV2.idr2, 0x111)
        // Firmware's: SD 0x4e0 -> bank 2, display 0x800/0x7f -> bank 0, 0xc00
        // bypassed; bank 3 set up with no entry left on it; the rest free.
        set(SmmuV2.smr(0), SmmuV2.smrValid | 0x4E0)
        set(SmmuV2.s2cr(0), 2)
        set(SmmuV2.smr(1), SmmuV2.smrValid | 0x7F << 16 | 0x800)
        set(SmmuV2.s2cr(1), 0)
        set(SmmuV2.smr(2), SmmuV2.smrValid | 0xC00)
        set(SmmuV2.s2cr(2), 1 << 16)
        for n in 3..<Int(entries) { set(SmmuV2.s2cr(n), SmmuV2.s2crFault) }
        for b in [0, 2, 3] as InlineArray<3, Int> { set(gr1 + SmmuV2.cbar(b), SmmuV2.cbarStage1) }
        unsafe snapshot.copyMemory(from: UnsafeRawPointer(regs), byteCount: bytes)

        let unit: SmmuV2UnitPointer
        do throws(Status) {
            unit = try SmmuV2UnitPointer.make(registers: base, base: 0, span: pageCount * KernelLayout.pageSize,
                                              coherent: true, interrupts: 0, interruptCount: 0)
        } catch {
            panic("smmuv2 self-test: the stand-in was refused")
        }
        unit.pointee.log = UInt64(UInt(bitPattern: log))
        unit.pointee.logCapacity = 256
        func check(_ ok: Bool, _ what: StaticString) {
            guard ok else {
                console.write("  smmuv2: failed: ")
                console.write(what)
                console.write("\n")
                panic("smmuv2 self-test")
            }
        }
        let bankBase = 2 * KernelLayout.pageSize
        func bank(_ b: Int, _ offset: UInt64) -> UInt64 { bankBase + UInt64(b) * KernelLayout.pageSize + offset }
        func original(_ offset: UInt64) -> UInt32 {
            unsafe snapshot.load(fromByteOffset: Int(offset), as: UInt32.self)
        }
        check(unit.pointee.inputBits == 36 && unit.pointee.banks == 8 && unit.pointee.bankBase == bankBase, "configuration read")

        // The codec's two families (0x2a00 and 0x2a07, mask 0x400): bank 1,
        // entries 3 and 4.
        let codec: UInt64 = (0x2A00 | 0x400 << 16) | (0x2A07 | 0x400 << 16) << 32 | 1 << 63
        let domain: IoDomainPointer
        do throws(Status) {
            domain = try SmmuV2.attach(unit, streams: codec)
        } catch {
            panic("smmuv2 self-test: attach failed")
        }
        check(domain.pointee.domainId == 1 && domain.pointee.levels == 3 && domain.pointee.inputBits == 36, "bank 1, 3 levels")
        let root = domain.pointee.root
        // Only the claimed entries and bank changed.
        var word: UInt64 = 0
        while word < UInt64(bytes) {
            let changed = get(word) != original(word)
            let allowed = word == SmmuV2.smr(3) || word == SmmuV2.smr(4) || word == SmmuV2.s2cr(3) || word == SmmuV2.s2cr(4)
                || word == gr1 + SmmuV2.cbar(1) || word == gr1 + SmmuV2.cba2r(1)
                || (word >= bank(1, 0) && word < bank(2, 0))
            check(!changed || allowed, "only the claimed entries and bank written")
            word += 4
        }
        check(get(gr1 + SmmuV2.cbar(1)) == 0x1F300 && get(gr1 + SmmuV2.cba2r(1)) == 1, "CBAR 0x1f300, VA64")
        check(get(SmmuV2.s2cr(3)) == 1 && get(SmmuV2.s2cr(4)) == 1, "S2CRs translate through bank 1")
        check(get(SmmuV2.smr(3)) == SmmuV2.smrValid | 0x400 << 16 | 0x2A00
              && get(SmmuV2.smr(4)) == SmmuV2.smrValid | 0x400 << 16 | 0x2A07, "SMRs are the pairs given")
        check(get(bank(1, SmmuV2.sctlr)) == 0x1027 && get(bank(1, SmmuV2.tcr)) == 28 | 0x3500 | 1 << 23
              && get(bank(1, SmmuV2.contextIdr)) == 1 && get(bank(1, SmmuV2.mair0)) == 0x44FF, "bank registers")
        check(UInt64(get(bank(1, SmmuV2.ttbr0))) | UInt64(get(bank(1, SmmuV2.ttbr0 + 4))) << 32 == root | 1 << 48,
              "TTBR0: the level-1 table, ASID 1")
        // The order: the bank, then each S2CR before its SMR; CBAR only ever
        // 0x1f300; no global register besides the entries.
        var s2crAt = InlineArray<2, Int>(repeating: -1), smrAt = InlineArray<2, Int>(repeating: -1), sctlrOn = -1
        let entries = unsafe UnsafePointer<UInt64>(bitPattern: UInt(bitPattern: log))!
        for i in 0..<unit.pointee.logCount {
            let offset = unsafe entries[i] >> 32, value = unsafe UInt32(truncatingIfNeeded: entries[i])
            if offset >= gr1, offset < gr1 + 0x400 { check(value == SmmuV2.cbarStage1, "CBAR written as 0x1f300 only") }
            check(offset >= gr1 || offset >= SmmuV2.smr(0), "no global register written")
            if offset == SmmuV2.s2cr(3) { s2crAt[0] = i }
            if offset == SmmuV2.s2cr(4) { s2crAt[1] = i }
            if offset == SmmuV2.smr(3) { smrAt[0] = i }
            if offset == SmmuV2.smr(4) { smrAt[1] = i }
            if offset == bank(1, SmmuV2.sctlr), value & 1 != 0 { sctlrOn = i }
        }
        check(sctlrOn >= 0 && sctlrOn < s2crAt[0] && s2crAt[0] < smrAt[0] && s2crAt[1] < smrAt[1], "bank, S2CR, then SMR")

        // Overlaps are refused: firmware's SD stream, the display's masked
        // range, the codec's own; bits outside the pairs.
        func refused(_ streams: UInt64, _ status: Status) -> Bool {
            do throws(Status) {
                Iommus.detach(try SmmuV2.attach(unit, streams: streams))
                return false
            } catch {
                return error == status
            }
        }
        check(refused(0x4E0, .alreadyBound) && refused(0x810, .alreadyBound) && refused(0x2A00 | 0x400 << 16, .alreadyBound)
              && refused(0x2E07, .alreadyBound) && refused(1 << 15, .invalidArgs) && refused(1 << 40, .invalidArgs),
              "overlapping or malformed pairs refused")

        // A page at the codec's window: a level-3 leaf with AF, nG, inner
        // shareable, unprivileged read/write, write-back.
        guard let page = pmm.allocatePage() else { panic("smmuv2 self-test: no memory") }
        let iova: UInt64 = 0x2580_1000
        do throws(Status) {
            _ = try IoDomains.reserve(domain, at: iova, size: KernelLayout.pageSize)
            try IoDomains.map(domain, iova: iova, phys: page, write: true)
        } catch {
            panic("smmuv2 self-test: map failed")
        }
        func leaf() -> UInt64 {
            var table = root
            for shift in [UInt64(30), 21] as InlineArray<2, UInt64> {
                let entry = unsafe UnsafePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(table)))![Int((iova >> shift) & 0x1FF)]
                guard entry & 3 == 3 else { return 0 }
                table = entry & 0x000F_FFFF_FFFF_F000
            }
            return unsafe UnsafePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(table)))![Int((iova >> 12) & 0x1FF)]
        }
        check(leaf() == page | 0xF43, "leaf attributes")
        let before = unit.pointee.logCount
        IoDomains.unmap(domain, iova: iova, size: KernelLayout.pageSize)
        IoDomains.release(domain, iova: iova)
        pmm.free(page)
        var invalidated = false
        for i in before..<unit.pointee.logCount where unsafe entries[i] >> 32 == bank(1, SmmuV2.tlbiAsid) {
            invalidated = unsafe UInt32(truncatingIfNeeded: entries[i]) == 1
        }
        check(leaf() == 0 && invalidated, "unmap clears the leaf and invalidates ASID 1")

        // Release: the entries fault again, the bank is off, CBAR stays.
        Iommus.detach(domain)
        check(get(SmmuV2.smr(3)) == 0 && get(SmmuV2.smr(4)) == 0 && get(SmmuV2.s2cr(3)) == SmmuV2.s2crFault
              && get(SmmuV2.s2cr(4)) == SmmuV2.s2crFault && get(bank(1, SmmuV2.sctlr)) == 0
              && get(gr1 + SmmuV2.cbar(1)) == 0x1F300, "released: entries faulting, bank off, CBAR kept")

        // Bank 1 is this driver's: reused though its CBAR isn't 0. Then claim
        // until none is free: banks 1, 4-7, never firmware's 0, 2 and 3.
        var claimed = InlineArray<6, UInt64>(repeating: 0)
        var count = 0
        while count < 6 {
            do throws(Status) {
                let next = try SmmuV2.attach(unit, streams: UInt64(0x100 + count))
                let b = next.pointee.domainId
                check(b == 1 || b >= 4, "only free banks")
                check(count > 0 || b == 1, "a released bank is reused")
                claimed[count] = next.address
                count += 1
            } catch {
                check(error == .noResources && count == 5, "five banks free")
                break
            }
        }
        for i in 0..<count { Iommus.detach(IoDomainPointer(address: claimed[i])) }
        // Firmware's state is as it was.
        for offset in [SmmuV2.scr0, SmmuV2.smr(0), SmmuV2.smr(1), SmmuV2.smr(2), SmmuV2.s2cr(0), SmmuV2.s2cr(1),
                       SmmuV2.s2cr(2), gr1 + SmmuV2.cbar(0), gr1 + SmmuV2.cbar(2),
                       gr1 + SmmuV2.cbar(3)] as InlineArray<10, UInt64> {
            check(get(offset) == original(offset), "firmware's entries and banks untouched")
        }

        unsafe heap.free(log)
        unsafe heap.free(snapshot)
        unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(unit.address))!)
        for i in 0..<pageCount { pmm.free(phys + i * KernelLayout.pageSize) }
        console.write("  smmuv2: on a Q8B-like stand-in: firmware's entries and banks untouched, CBAR 0x1f300 only, ")
        console.write("bank then S2CR then SMR, overlaps refused, 36-bit walks, released banks reused\n")
    }
}
#endif
