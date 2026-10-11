import CKernel

/// The user pager (K13d): syscalls 202-206, Zircon's checks in Zircon's
/// order (the pinned tree's pager.rs).
extension Syscalls {
    static func pagerCall(_ number: UInt64, _ a: InlineArray<6, UInt64>, _ table: borrowing HandleTable) throws(Status) {
        let handle = UInt32(truncatingIfNeeded: a[0])
        let page = KernelLayout.pageSize
        switch number {
        case 202:  // pager_create(options, out)
            try Policy.check(UInt32(CROI_POL_NEW_PAGER))
            guard a[0] == 0 else { throw .invalidArgs }
            try check(a[1], MemoryLayout<UInt32>.size)
            let pager = try Pagers.create()
            let out: UInt32
            do throws(Status) {
                out = try table.add(pager, rights: PagerObject.defaultRights)
            } catch {
                pager.release()
                throw error
            }
            try put(out, a[1])
        case 203:  // pager_create_vmo(pager, options, port, key, size, out)
            try Policy.check(UInt32(CROI_POL_NEW_VMO))
            let pager = try table.get(handle, type: .pager, rights: .attachVmo)
            let port = try table.get(UInt32(truncatingIfNeeded: a[2]), type: .port, rights: .write)
            var options = UInt32(truncatingIfNeeded: a[1])
            guard UInt64(options) == a[1] else { throw .invalidArgs }
            let trapDirty = options & UInt32(CROI_VMO_TRAP_DIRTY) != 0
            options &= ~UInt32(CROI_VMO_TRAP_DIRTY)
            let resizable = UInt32(CROI_VMO_RESIZABLE), unbounded = UInt32(CROI_VMO_UNBOUNDED)
            let discardable = UInt32(CROI_VMO_DISCARDABLE)
            if options & resizable != 0, options & unbounded != 0 { throw .invalidArgs }
            guard options & ~(resizable | unbounded | discardable) == 0 else { throw .invalidArgs }
            guard a[4] <= UInt64.max - (page - 1) else { throw .outOfRange }
            if options & discardable != 0 { throw .invalidArgs }
            // croi has no resizable VMOs (and so none without bounds).
            if options & (resizable | unbounded) != 0 { throw .notSupported }
            if trapDirty { throw .notSupported }  // K13d, part 2
            try check(a[5], MemoryLayout<UInt32>.size)
            let vmo = try Pagers.createVmo(pager.object, port: port.object, key: a[3], size: a[4])
            let out: UInt32
            do throws(Status) {
                out = try table.add(vmo, rights: VmoObject.defaultRights)
            } catch {
                vmo.release()
                throw error
            }
            try put(out, a[5])
        case 204:  // pager_detach_vmo(pager, vmo)
            let pager = try table.get(handle, type: .pager, rights: .attachVmo | .manageVmo)
            let vmoRef = try Pagers.vmo(table, UInt32(truncatingIfNeeded: a[1]), rights: .write, of: pager.object)
            let vmo = VmoPointer(address: UnsafeVmoObject(vmoRef.object).vmo)
            Pagers.detach(vmo.pointee.pager!, complete: true)
        case 205:  // pager_supply_pages(pager, vmo, offset, length, aux_vmo, aux_offset)
            guard a[2] % page == 0, a[3] % page == 0, a[5] % page == 0 else { throw .invalidArgs }
            let pager = try table.get(handle, type: .pager, rights: .manageVmo)
            let vmoRef = try Pagers.vmo(table, UInt32(truncatingIfNeeded: a[1]), rights: .write, of: pager.object)
            let vmo = VmoPointer(address: UnsafeVmoObject(vmoRef.object).vmo)
            let auxRef = try table.get(UInt32(truncatingIfNeeded: a[4]), type: .vmo, rights: .read | .write)
            let aux = VmoPointer(address: UnsafeVmoObject(auxRef.object).vmo)
            // The aux VMO's pages, taken (moved, not copied).
            guard case .anonymous = aux.pointee.kind else { throw .notSupported }
            guard !a[5].addingReportingOverflow(a[3]).overflow, a[5] + a[3] <= aux.pointee.size else { throw .outOfRange }
            guard aux.pointee.pager == nil, aux.pointee.parent == nil else { throw .notSupported }
            guard a[3] > 0 else {
                guard !a[2].addingReportingOverflow(a[3]).overflow, a[2] <= vmo.pointee.size else { throw .outOfRange }
                return
            }
            var pages = UniqueArray<UInt64>()
            do throws(VmError) {
                try Vmo.withBorrowed(aux) { (v: borrowing Vmo) throws(VmError) in
                    let held = v.record.pointee.lock.withLock { v.record.pinnedLocked(a[5], a[3]) }
                    guard !held else { throw .pinned }
                    var taken = try v.take(offset: a[5], size: a[3])
                    swap(&taken, &pages)
                }
            } catch {
                throw error.status
            }
            var count: UInt64 = 0
            for i in 0..<pages.count where pages[i] != 0 { count += 1 }
            aux.pointee.account?.uncharge(count * page)
            guard !a[2].addingReportingOverflow(a[3]).overflow, a[2] + a[3] <= vmo.pointee.size else {
                for i in 0..<pages.count where pages[i] != 0 { pmm.free(pages[i]) }
                throw .outOfRange
            }
            try Pagers.supply(vmo, offset: a[2], pages: pages)
        case 206:  // pager_op_range(pager, op, vmo, offset, length, data)
            guard a[3] % page == 0, a[4] % page == 0 else { throw .invalidArgs }
            let pager = try table.get(handle, type: .pager, rights: .manageVmo)
            let vmoRef = try Pagers.vmo(table, UInt32(truncatingIfNeeded: a[2]), rights: .write, of: pager.object)
            let vmo = VmoPointer(address: UnsafeVmoObject(vmoRef.object).vmo)
            switch a[1] {
            case UInt64(CROI_PAGER_OP_FAIL):
                let data = Int64(bitPattern: a[5])
                guard data >= Int64(Int32.min), data <= Int64(Int32.max) else { throw .invalidArgs }
                let status = Int32(data)
                let allowed: InlineArray<5, Status> = [.io, .ioDataIntegrity, .badState, .noSpace, .bufferTooSmall]
                var ok = false
                for i in 0..<5 where allowed[i].rawValue == status { ok = true }
                guard ok else { throw .invalidArgs }
                guard !a[3].addingReportingOverflow(a[4]).overflow, a[3] + a[4] <= vmo.pointee.size else { throw .outOfRange }
                try Pagers.fail(vmo, offset: a[3], length: a[4], status: status)
            case UInt64(CROI_PAGER_OP_DIRTY), UInt64(CROI_PAGER_OP_WRITEBACK_BEGIN), UInt64(CROI_PAGER_OP_WRITEBACK_END):
                throw .notSupported  // K13d, part 2
            default:
                throw .notSupported
            }
        default:
            throw .notSupported
        }
    }
}
