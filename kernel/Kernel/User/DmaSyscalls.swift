import CKernel
import PageTables

/// DMA syscalls (K9e; numbers in user/include/croi/syscall.h, values in
/// dma.h): Zircon's iommu_create, bti_create, bti_pin, bti_release_
/// quarantine, pmt_unpin and vmo_create_contiguous, plus croi's
/// bti_set_properties. bti_pin packs bti | options << 32 and vmo |
/// addrs_count << 32 into two registers (eight arguments, six registers).
extension Syscalls {
    static func dmaCall(_ number: UInt64, _ a: InlineArray<6, UInt64>,
                        _ table: borrowing HandleTable) throws(Status) {
        let handle = UInt32(truncatingIfNeeded: a[0])
        switch number {
        case 150:  // iommu_create(resource, type, desc, desc_size, out)
            try check(a[4], MemoryLayout<UInt32>.size)
            try Resources.check(table, handle, system: UInt64(CROI_RSRC_SYSTEM_IOMMU_BASE))
            guard a[3] <= UInt64(CROI_IOMMU_MAX_DESC_LEN) else { throw .invalidArgs }
            guard let copy = unsafe heap.allocate(size: max(Int(a[3]), 1)) else { throw .noMemory }
            defer { unsafe heap.free(copy) }
            if a[3] > 0 {
                guard unsafe UserCopy.from(copy, a[2], a[3]) == 0 else { throw .invalidArgs }
            }
            let descriptor = unsafe RawSpan(_unsafeStart: copy, byteCount: Int(a[3]))
            try addAndPut(try Dma.createIommu(type: UInt32(truncatingIfNeeded: a[1]), descriptor: descriptor),
                          rights: IommuObject.defaultRights, a[4], table)
        case 151:  // bti_create(iommu, options, bti_id, out)
            guard a[1] == 0 else { throw .invalidArgs }
            try check(a[3], MemoryLayout<UInt32>.size)
            let iommu = try table.get(handle, type: .iommu)
            try addAndPut(try Dma.createBti(iommu.object, id: a[2]), rights: BtiObject.defaultRights, a[3], table)
        case 152:
            try pin(a, table)
        case 153:  // bti_release_quarantine(bti)
            Dma.releaseQuarantine(try table.get(handle, type: .bti, rights: .write).object)
        case 154:  // pmt_unpin(pmt): consumes the handle
            let pmt = try table.get(handle, type: .pmt)
            try Dma.unpin(pmt.object)
            try table.close(handle)
        case 155:  // vmo_create_contiguous(bti, size, alignment_log2, out)
            try check(a[3], MemoryLayout<UInt32>.size)
            let page = KernelLayout.pageSize
            guard a[1] > 0, a[1] % page == 0 else { throw .invalidArgs }
            // K15a: an account handle (CHARGE) in bits 63:32 charges it the
            // whole size; else the caller's process's account.
            let low = a[2] & 0xFFFF_FFFF, chargeTo = UInt32(truncatingIfNeeded: a[2] >> 32)
            let alignLog2 = low == 0 ? 12 : low
            guard alignLog2 >= 12, alignLog2 < 64 else { throw .invalidArgs }
            try Policy.check(UInt32(CROI_POL_NEW_VMO))
            let bti = try table.get(handle, type: .bti, rights: .map)
            let account = try Accounts.forNewVmo(table, chargeTo: chargeTo != 0 ? chargeTo : nil)
            defer { account?.release() }
            let vmo = try Dma.createContiguous(bti.object, size: a[1], alignLog2: Int(alignLog2), account: account)
            try addAndPut(try VmoObject.wrap(vmo.record), rights: VmoObject.defaultRights, a[3], table)
        case 156:  // bti_set_properties(bti, const croi_bti_properties_t *)
            let bti = try table.get(handle, type: .bti, rights: .setProperty)
            var wanted = croi_bti_properties_t()
            let size = UInt64(MemoryLayout<croi_bti_properties_t>.size)
            guard unsafe UserCopy.from(&wanted, a[1], size) == 0 else { throw .invalidArgs }
            try Dma.setProperties(bti.object, wanted)
        default:
            throw .notSupported
        }
    }

    /// bti_pin(bti | options << 32, vmo | addrs_count << 32, offset, size,
    /// addrs, pmt out): Zircon's checks and address formats.
    private static func pin(_ a: InlineArray<6, UInt64>, _ table: borrowing HandleTable) throws(Status) {
        let options = UInt32(truncatingIfNeeded: a[0] >> 32)
        let vmoHandle = UInt32(truncatingIfNeeded: a[1])
        let count = a[1] >> 32
        let (offset, size) = (a[2], a[3])
        let page = KernelLayout.pageSize
        let bti = try table.get(UInt32(truncatingIfNeeded: a[0]), type: .bti, rights: .map)
        guard offset % page == 0, size % page == 0, count <= 64 * page / 8 else { throw .invalidArgs }
        var vmoRights = Rights()
        let vmo = try table.get(vmoHandle, type: .vmo, rights: .map, have: &vmoRights)
        let holder = VmoPointer(address: UnsafeVmoObject(vmo.object).vmo)
        // K14g: an alias pins its root's pages, inside its own window.
        let (record, shift) = holder.target
        if record != holder, holder.pointee.slice,
           offset.addingReportingOverflow(size).overflow || offset + size > holder.pointee.size {
            throw .invalidArgs  // as the VMO's own range check
        }

        var remaining = options
        if remaining & UInt32(CROI_BTI_PERM_READ) != 0 {
            guard vmoRights.contains(.read) else { throw .accessDenied }
            remaining &= ~UInt32(CROI_BTI_PERM_READ)
        }
        if remaining & UInt32(CROI_BTI_PERM_WRITE) != 0 {
            guard vmoRights.contains(.write) else { throw .accessDenied }
            remaining &= ~UInt32(CROI_BTI_PERM_WRITE)
        }
        if remaining & UInt32(CROI_BTI_PERM_EXECUTE) != 0 {
            guard vmoRights.contains(.read) else { throw .accessDenied }  // the device's execute: READ
            remaining &= ~UInt32(CROI_BTI_PERM_EXECUTE)
        }
        var compress = false, contiguous = false
        let both = UInt32(CROI_BTI_COMPRESS | CROI_BTI_CONTIGUOUS)
        if remaining & both != both {  // both at once stay set: refused below
            if remaining & UInt32(CROI_BTI_COMPRESS) != 0 {
                compress = true
                remaining &= ~UInt32(CROI_BTI_COMPRESS)
            }
            if remaining & UInt32(CROI_BTI_CONTIGUOUS) != 0, case .contiguous = record.pointee.kind {
                contiguous = true
                remaining &= ~UInt32(CROI_BTI_CONTIGUOUS)
            }
        }
        guard remaining == 0 else { throw .invalidArgs }
        _ = compress  // the stub's minimum contiguity is a page: COMPRESS reports pages
        let expected = contiguous ? 1 : size / page
        guard size > 0, count == expected else { throw .invalidArgs }
        try check(a[4], Int(count) * 8)
        try check(a[5], MemoryLayout<UInt32>.size)

        let pmt = try Dma.pin(bti.object, vmo: record, offset: offset + shift, size: size,
                              writable: options & UInt32(CROI_BTI_PERM_WRITE) != 0)
        do throws(Status) {
            for i in 0..<count {
                try put(Dma.address(pmt, at: i * page), a[4] + i * 8)
            }
            let value = try table.add(pmt, rights: PmtObject.defaultRights)
            do throws(Status) {
                try put(value, a[5])
            } catch {
                try? Dma.unpin(pmt)
                try? table.close(value)
                throw error
            }
        } catch {
            if PmtPointer(object: pmt).pointee.state == .live {
                try? Dma.unpin(pmt)
                pmt.release()
            }
            throw error
        }
    }
}
