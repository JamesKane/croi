import CKernel
import PageTables

/// Driver syscalls (K9a; numbers in user/include/croi/syscall.h, values
/// in resource.h and vmo.h): resources, physical VMOs, cache policy and
/// VMO range ops. Zircon's calls; resource_create packs the parent and
/// options into one register (parent | options << 32), as vmar_* do.
extension Syscalls {
    static func driverCall(_ number: UInt64, _ a: InlineArray<6, UInt64>,
                           _ table: borrowing HandleTable) throws(Status) {
        let handle = UInt32(truncatingIfNeeded: a[0])
        switch number {
        case 45:  // vmo_op_range(vmo, op, offset, size, buffer, buffer_size)
            try vmoOpRange(table, handle, op: UInt32(truncatingIfNeeded: a[1]), offset: a[2], size: a[3],
                           buffer: a[4], bufferSize: a[5])
        case 46:  // vmo_set_cache_policy(vmo, policy)
            let ref = try table.get(handle, type: .vmo, rights: .map)
            let policy: CachePolicy
            switch a[1] {
            case UInt64(CROI_CACHE_POLICY_CACHED): policy = .cached
            case UInt64(CROI_CACHE_POLICY_UNCACHED), UInt64(CROI_CACHE_POLICY_UNCACHED_DEVICE): policy = .device
            case UInt64(CROI_CACHE_POLICY_WRITE_COMBINING): policy = .writeCombining
            default: throw .invalidArgs
            }
            do throws(VmError) {
                try Vmo.withBorrowed(VmoPointer(address: UnsafeVmoObject(ref.object).vmo)) { (vmo: borrowing Vmo) throws(VmError) in
                    try vmo.setCachePolicy(policy)
                }
            } catch {
                guard case .denied = error else { throw .badState }  // mapped
                throw .accessDenied  // firmware memory: cached only
            }
        case 47:  // vmo_create_physical(resource, paddr, size, out)
            try Policy.check(UInt32(CROI_POL_NEW_VMO))
            try check(a[3], MemoryLayout<UInt32>.size)
            let page = KernelLayout.pageSize
            guard a[2] > 0, a[1] % page == 0, a[2] % page == 0 else { throw .invalidArgs }
            try Resources.validate(table, handle, kind: UInt32(CROI_RSRC_KIND_MMIO), base: a[1], size: a[2])
            let vmo: Vmo
            do throws(VmError) {
                // Zircon's default: uncached (firmware memory: cached).
                vmo = try Vmo(physical: a[1], size: a[2], cache: .device)
            } catch {
                throw error == .outOfMemory ? .noMemory : .accessDenied
            }
            let object = try VmoObject.wrap(vmo.record)
            let value: UInt32
            do throws(Status) {
                value = try table.add(object, rights: VmoObject.physicalRights)
            } catch {
                object.release()
                throw error
            }
            try put(value, a[3])
        case 130:  // resource_create(parent | options << 32, base, size, name, name_size, out)
            try check(a[5], MemoryLayout<UInt32>.size)
            var name = InlineArray<32, UInt8>(repeating: 0)
            let length = min(a[4], 31)
            if length > 0 {
                var span = name.mutableSpan
                let copied = span.withUnsafeMutableBytes { raw in unsafe UserCopy.from(raw.baseAddress!, a[3], length) }
                guard copied == 0 else { throw .invalidArgs }
            }
            let value = try Resources.create(table, parent: handle, options: UInt32(truncatingIfNeeded: a[0] >> 32),
                                             base: a[1], size: a[2], name: name.span.extracting(0..<Int(length)))
            do throws(Status) {
                try put(value, a[5])
            } catch {
                try? table.close(value)
                throw error
            }
        case 131, 132:  // ioports_request / ioports_release(resource, io_addr, len): amd64
            try IoPorts.change(table, resource: handle, base: a[1], count: a[2], allow: number == 131)
        case 140...148:
            try interruptCall(number, a, table)
        default:
            throw .notSupported
        }
    }

    /// A new object's handle written to `address` (the object released if
    /// it can't be added, the handle closed if it can't be written).
    static func addAndPut(_ object: ObjectPointer, rights: Rights, _ address: UInt64,
                                  _ table: borrowing HandleTable) throws(Status) {
        let value: UInt32
        do throws(Status) {
            value = try table.add(object, rights: rights)
        } catch {
            object.release()
            throw error
        }
        do throws(Status) {
            try put(value, address)
        } catch {
            try? table.close(value)
            throw error
        }
    }

    /// Interrupt objects (K9c) and MSI (K9d; values in interrupt.h):
    /// Zircon's calls and rights, plus interrupt_set_affinity.
    private static func interruptCall(_ number: UInt64, _ a: InlineArray<6, UInt64>,
                                      _ table: borrowing HandleTable) throws(Status) {
        let handle = UInt32(truncatingIfNeeded: a[0])
        switch number {
        case 140:  // interrupt_create(resource, number, options, out)
            try check(a[3], MemoryLayout<UInt32>.size)
            let options = UInt32(truncatingIfNeeded: a[2])
            let object: ObjectPointer
            if options & UInt32(CROI_INTERRUPT_VIRTUAL) != 0 {
                object = try InterruptObjects.createVirtual(options: options)
            } else {
                guard a[1] <= UInt64(UInt32.max) else { throw .invalidArgs }
                try Resources.validate(table, handle, kind: UInt32(CROI_RSRC_KIND_IRQ), base: a[1], size: 1)
                object = try InterruptObjects.create(number: UInt32(a[1]), options: options)
            }
            try addAndPut(object, rights: InterruptObject.defaultRights, a[3], table)
        case 141:  // interrupt_bind(interrupt, port, key, options)
            guard a[3] == UInt64(CROI_INTERRUPT_BIND) || a[3] == UInt64(CROI_INTERRUPT_UNBIND) else {
                throw .invalidArgs
            }
            let interrupt = try table.get(handle, type: .interrupt, rights: .read)
            let port = try table.get(UInt32(truncatingIfNeeded: a[1]), type: .port, rights: .write)
            guard PortPointer(object: port.object).pointee.bindToInterrupt else { throw .wrongType }
            if a[3] == UInt64(CROI_INTERRUPT_BIND) {
                try InterruptObjects.bind(interrupt.object, port: port.object, key: a[2])
            } else {
                try InterruptObjects.unbind(interrupt.object, port: port.object)
            }
        case 142:  // interrupt_ack(interrupt)
            try InterruptObjects.ack(try table.get(handle, type: .interrupt, rights: .write).object)
        case 143:  // interrupt_wait(interrupt, timestamp out or 0)
            if a[1] != 0 { try check(a[1], MemoryLayout<UInt64>.size) }
            let interrupt = try table.get(handle, type: .interrupt, rights: .wait)
            let timestamp = try InterruptObjects.wait(interrupt.object, table: table.address, handle: handle)
            if a[1] != 0 { try put(timestamp, a[1]) }
        case 144:  // interrupt_destroy(interrupt)
            if let status = InterruptObjects.destroy(try table.get(handle, type: .interrupt).object) { throw status }
        case 145:  // interrupt_trigger(interrupt, options, timestamp)
            guard a[1] == 0 else { throw .invalidArgs }
            try InterruptObjects.trigger(try table.get(handle, type: .interrupt, rights: .signal).object, timestamp: a[2])
        case 146:  // interrupt_set_affinity(interrupt, cpu mask)
            try InterruptObjects.setAffinity(try table.get(handle, type: .interrupt, rights: .write).object, mask: a[1])
        case 147:  // msi_allocate(MSI resource, count, out)
            try check(a[2], MemoryLayout<UInt32>.size)
            try Resources.check(table, handle, system: UInt64(CROI_RSRC_SYSTEM_MSI_BASE))
            guard a[1] <= UInt64(UInt32.max) else { throw .invalidArgs }
            try addAndPut(try Msis.allocate(count: UInt32(a[1])), rights: MsiObject.defaultRights, a[2], table)
        case 148:  // msi_create(allocation, options, id, vmo, vmo_offset, out)
            try check(a[5], MemoryLayout<UInt32>.size)
            let allocation = try table.get(handle, type: .msi)
            let vmo = try table.get(UInt32(truncatingIfNeeded: a[3]), type: .vmo, rights: .map)
            guard a[2] <= UInt64(UInt32.max) else { throw .invalidArgs }
            let object = try MsiInterrupts.create(allocation.object, options: UInt32(truncatingIfNeeded: a[1]),
                                                  id: UInt32(a[2]), vmo: VmoPointer(address: UnsafeVmoObject(vmo.object).vmo),
                                                  offset: a[4])
            try addAndPut(object, rights: InterruptObject.defaultRights, a[5], table)
        default:
            throw .notSupported
        }
    }

    /// vmo_op_range: Zircon's ops and rights. COMMIT and PREFETCH round
    /// out to pages; DECOMMIT needs page alignment; ZERO and the cache ops
    /// take bytes (cache ops refuse size 0). Out of the VMO: OUT_OF_RANGE.
    private static func vmoOpRange(_ table: borrowing HandleTable, _ handle: UInt32, op: UInt32, offset: UInt64,
                                   size: UInt64, buffer: UInt64, bufferSize: UInt64) throws(Status) {
        var rights = Rights()
        let ref = try table.get(handle, type: .vmo, have: &rights)
        let holder = VmoPointer(address: UnsafeVmoObject(ref.object).vmo)
        // K14g: an alias's pages are its root's, from its offset there.
        let (record, shift) = holder.target
        // Past 2^64 is past any VMO (review fix: the sum trapped).
        let (at, wrapped) = offset.addingReportingOverflow(shift)
        guard !wrapped else { throw .outOfRange }
        let page = KernelLayout.pageSize
        func need(_ right: Rights) throws(Status) {
            guard rights.contains(right) else { throw .accessDenied }
        }
        func inRange() throws(Status) {
            guard !offset.addingReportingOverflow(size).overflow, offset + size <= holder.sizeOwner.pointee.size else {
                throw .outOfRange
            }
        }
        let cacheOp: UInt32
        switch op {
        case UInt32(CROI_VMO_OP_COMMIT), UInt32(CROI_VMO_OP_PREFETCH):
            try need(op == UInt32(CROI_VMO_OP_COMMIT) ? .write : .read)
            try inRange()
            guard size > 0 else { return }
            // Zircon's PrefetchRange commits nothing of a VMO no pager backs
            // (review fix: a READ handle committed anonymous pages).
            if op == UInt32(CROI_VMO_OP_PREFETCH), record.pointee.pager == nil, !record.pointee.readsFromPager { return }
            let start = at & ~(page - 1), end = (at + size + page - 1) & ~(page - 1)
            try Pagers.ensureRange(record, start, end - start)
            try vm { () throws(VmError) in
                try Vmo.withBorrowed(record) { (vmo: borrowing Vmo) throws(VmError) in
                    try vmo.commit(offset: start, size: end - start)
                }
            }
            return
        case UInt32(CROI_VMO_OP_DECOMMIT):
            try need(.write)
            guard offset % page == 0, size % page == 0 else { throw .invalidArgs }
            try inRange()
            // Anonymous VMOs free the pages; contiguous ones lend them (K14f).
            switch record.pointee.kind {
            case .anonymous: break
            case .contiguous: guard Loans.enabled else { throw .notSupported }
            case .physical: throw .notSupported
            }
            guard size > 0 else { return }
            try vm { () throws(VmError) in
                try Vmo.withBorrowed(record) { (vmo: borrowing Vmo) throws(VmError) in
                    try vmo.decommit(offset: at, size: size)
                }
            }
            return
        case UInt32(CROI_VMO_OP_ZERO):
            try need(.write)
            try inRange()
            guard record.inPhysmap else { throw .notSupported }
            try Pagers.ensureWritableForZero(record, at, size)  // a pager VMO's whole pages: a zero interval (K14k)
            try vm { () throws(VmError) in
                try Vmo.withBorrowed(record) { (vmo: borrowing Vmo) throws(VmError) in
                    try vmo.zero(offset: at, size: size)
                }
            }
            return
        case UInt32(CROI_VMO_OP_CACHE_SYNC):
            try need(.read)
            guard size > 0 else { throw .invalidArgs }
            try inRange()
            try vm { () throws(VmError) in
                try Vmo.withBorrowed(record) { (vmo: borrowing Vmo) throws(VmError) in
                    try vmo.syncInstructions(offset: at, size: size)
                }
            }
            return
        case UInt32(CROI_VMO_OP_CACHE_CLEAN):
            try need(.read)
            cacheOp = CROI_CACHE_CLEAN
        case UInt32(CROI_VMO_OP_CACHE_CLEAN_INVALIDATE):
            try need(.read)
            cacheOp = CROI_CACHE_CLEAN_INVALIDATE
        case UInt32(CROI_VMO_OP_CACHE_INVALIDATE):
            // Zircon checks its debugging-syscalls switch before the right;
            // croi has no invalidate at all (review fix: ACCESS_DENIED first).
            throw .notSupported  // Zircon: debugging syscalls only (it can drop dirty lines)
        case UInt32(CROI_VMO_OP_LOCK):  // K14a: discardable VMOs only
            guard rights.contains(.read) || rights.contains(.write) else { throw .accessDenied }
            let was = try Reclaim.lock(record, offset: offset, size: size, tryOnly: false)
            // Zircon's order: locked, then the buffer checked (the lock undone).
            do throws(Status) {
                guard bufferSize >= UInt64(MemoryLayout<croi_vmo_lock_state_t>.size) else { throw .invalidArgs }
                try Syscalls.put(croi_vmo_lock_state_t(offset: offset, size: size, discarded_offset: 0,
                                                       discarded_size: was ? size : 0), buffer)
            } catch {
                try? Reclaim.unlock(record, offset: offset, size: size)
                throw error
            }
            return
        case UInt32(CROI_VMO_OP_TRY_LOCK):
            guard rights.contains(.read) || rights.contains(.write) else { throw .accessDenied }
            _ = try Reclaim.lock(record, offset: offset, size: size, tryOnly: true)
            return
        case UInt32(CROI_VMO_OP_UNLOCK):
            guard rights.contains(.read) || rights.contains(.write) else { throw .accessDenied }
            try Reclaim.unlock(record, offset: offset, size: size)
            return
        case UInt32(CROI_VMO_OP_DONT_NEED), UInt32(CROI_VMO_OP_ALWAYS_NEED):  // hints: no rights (Zircon's)
            // A VMO no pager backs ignores them, range and all (Zircon's
            // HintRange; review fix: OUT_OF_RANGE first).
            guard record.pointee.pager != nil || record.pointee.readsFromPager else { return }
            try inRange()
            Reclaim.hint(record, offset: at, size: size, alwaysNeed: op == UInt32(CROI_VMO_OP_ALWAYS_NEED))
            return
        default:
            throw .invalidArgs
        }
        guard size > 0 else { throw .invalidArgs }
        try inRange()
        try vm { () throws(VmError) in
            try Vmo.withBorrowed(record) { (vmo: borrowing Vmo) throws(VmError) in
                try vmo.cacheOp(offset: at, size: size, cacheOp)
            }
        }
    }
}
