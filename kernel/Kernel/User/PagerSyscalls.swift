import CKernel

/// The user pager (K13d): syscalls 202-208, Zircon's checks in Zircon's
/// order (the pinned tree's pager.rs). query_dirty_ranges has eight
/// arguments in Zircon; croi packs pager | vmo << 32 and writes actual and
/// avail into one two-word out-parameter (either may be 0: none).
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
            // K13h: resizable ones; K14i: unbounded ones (Vmos.createSize).
            let vmoSize = try Vmos.createSize(a[4], unbounded: options & unbounded != 0,
                                              resizable: options & resizable != 0)
            guard options & ~(resizable | unbounded | discardable) == 0 else { throw .invalidArgs }
            if options & discardable != 0 { throw .invalidArgs }
            try check(a[5], MemoryLayout<UInt32>.size)
            let vmo = try Pagers.createVmo(pager.object, port: port.object, key: a[3], size: a[4], vmoSize: vmoSize,
                                           trapDirty: trapDirty, resizable: options & resizable != 0)
            let out: UInt32
            do throws(Status) {
                out = try table.add(vmo, rights: options & resizable != 0 ? VmoObject.defaultRights | .resize : VmoObject.defaultRights)
            } catch {
                vmo.release()
                throw error
            }
            try put(out, a[5])
        case 204:  // pager_detach_vmo(pager, vmo)
            let pager = try table.get(handle, type: .pager, rights: .attachVmo | .manageVmo)
            let vmoRef = try Pagers.vmo(table, UInt32(truncatingIfNeeded: a[1]), rights: .write, of: pager.object)
            let vmo = VmoPointer(address: UnsafeVmoObject(vmoRef.object).vmo)
            Pagers.detach(vmo.pointee.pager!, vmo: vmo, complete: true)
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
            // The pager VMO's range before anything is taken, and the move
            // in 2 MiB chunks (review fix: `take` listed every page of the
            // range at once, under the aux VMO's spinlock: a 2^40-byte
            // supply ran the heap out or held a CPU masked for minutes).
            // A range that doesn't fit leaves the aux pages where they are
            // (Zircon takes them first; only a range that could never be
            // supplied differs).
            guard !a[2].addingReportingOverflow(a[3]).overflow, a[2] + a[3] <= vmo.pointee.size else { throw .outOfRange }
            do throws(VmError) {
                try Vmo.withBorrowed(aux) { (v: borrowing Vmo) throws(VmError) in
                    let held = v.record.pointee.lock.withLock { v.record.pinnedLocked(a[5], a[3]) }
                    guard !held else { throw .pinned }
                }
            } catch {
                throw error.status
            }
            let chunk = 512 * page
            var done: UInt64 = 0
            while done < a[3] {
                if Scheduler.current.pointee.killPending { throw .canceled }  // it exits on the way out
                let length = min(a[3] - done, chunk)
                var pages = UniqueArray<UInt64>()
                do throws(VmError) {
                    try Vmo.withBorrowed(aux) { (v: borrowing Vmo) throws(VmError) in
                        var taken = try v.take(offset: a[5] + done, size: length)
                        swap(&taken, &pages)
                    }
                } catch {
                    throw error.status
                }
                var count: UInt64 = 0
                for i in 0..<pages.count where pages[i] != 0 { count += 1 }
                aux.pointee.account?.uncharge(count * page)
                try Pagers.supply(vmo, offset: a[2] + done, pages: pages)
                done += length
            }
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
            case UInt64(CROI_PAGER_OP_DIRTY):
                guard a[5] == 0 else { throw .invalidArgs }
                // The range first (Zircon's GetCowRange; review fix).
                guard !a[3].addingReportingOverflow(a[4]).overflow, a[3] + a[4] <= vmo.pointee.size else { throw .outOfRange }
                guard vmo.pointee.pager!.pointee.trapDirty else { throw .notSupported }
                try Pagers.dirty(vmo, offset: a[3], length: a[4])
            case UInt64(CROI_PAGER_OP_WRITEBACK_BEGIN):
                guard a[5] == 0 || a[5] == UInt64(CROI_VMO_DIRTY_RANGE_IS_ZERO) else { throw .invalidArgs }
                guard !a[3].addingReportingOverflow(a[4]).overflow, a[3] + a[4] <= vmo.pointee.size else { throw .outOfRange }
                Pagers.writebackBegin(vmo, offset: a[3], length: a[4], zeroRange: a[5] != 0)
            case UInt64(CROI_PAGER_OP_WRITEBACK_END):
                guard a[5] == 0 else { throw .invalidArgs }
                guard !a[3].addingReportingOverflow(a[4]).overflow, a[3] + a[4] <= vmo.pointee.size else { throw .outOfRange }
                Pagers.writebackEnd(vmo, offset: a[3], length: a[4])
            default:
                throw .notSupported
            }
        case 207:  // pager_query_dirty_ranges(pager | vmo << 32, offset, length, buffer, buffer_size, size_t out[2])
            let pager = try table.get(handle, type: .pager, rights: .manageVmo)
            let vmoRef = try Pagers.vmo(table, UInt32(truncatingIfNeeded: a[0] >> 32), rights: .read, of: pager.object)
            let vmo = VmoPointer(address: UnsafeVmoObject(vmoRef.object).vmo)
            guard !a[1].addingReportingOverflow(a[2]).overflow, a[1] + a[2] <= vmo.pointee.size else { throw .outOfRange }
            let start = a[1] & ~(page - 1), end = (a[1] + a[2] + page - 1) & ~(page - 1)
            let ranges = Pagers.dirtyRanges(vmo, offset: start, end: end)
            let entry = UInt64(MemoryLayout<croi_vmo_dirty_range_t>.size)
            let room = a[4] / entry
            var written: UInt64 = 0
            for i in 0..<ranges.count where UInt64(i) < room {
                var item = croi_vmo_dirty_range_t()
                item.offset = ranges[i].offset
                item.length = ranges[i].end - ranges[i].offset
                item.options = ranges[i].zero ? UInt64(CROI_VMO_DIRTY_RANGE_IS_ZERO) : 0
                let failed = withUnsafeBytes(of: &item) { unsafe UserCopy.to(a[3] + UInt64(i) * entry, $0.baseAddress!, entry) }
                guard failed == 0 else { throw .invalidArgs }
                written += 1
            }
            if a[5] != 0 {
                try check(a[5], 16)
                try put(written, a[5])
                try put(UInt64(ranges.count), a[5] + 8)
            }
        case 208:  // pager_query_vmo_stats(pager, vmo, options, buffer, buffer_size)
            let pager = try table.get(handle, type: .pager, rights: .manageVmo)
            let vmoRef = try Pagers.vmo(table, UInt32(truncatingIfNeeded: a[1]), rights: .read, of: pager.object)
            let vmo = VmoPointer(address: UnsafeVmoObject(vmoRef.object).vmo)
            guard a[4] >= UInt64(MemoryLayout<croi_pager_vmo_stats_t>.size) else { throw .bufferTooSmall }
            guard a[2] & ~UInt64(CROI_PAGER_RESET_VMO_STATS) == 0 else { throw .invalidArgs }
            var stats = croi_pager_vmo_stats_t()
            stats.modified = Pagers.modified(vmo, reset: a[2] != 0) ? UInt32(CROI_PAGER_VMO_STATS_MODIFIED) : 0
            let failed = withUnsafeBytes(of: &stats) { unsafe UserCopy.to(a[3], $0.baseAddress!, 4) }
            guard failed == 0 else { throw .invalidArgs }  // the reset stands (Zircon's)
        default:
            throw .notSupported
        }
    }
}
