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
            try vmoOpRange(table, handle, op: UInt32(truncatingIfNeeded: a[1]), offset: a[2], size: a[3])
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
                throw .badState  // mapped
            }
        case 47:  // vmo_create_physical(resource, paddr, size, out)
            try Policy.check(UInt32(CROI_POL_NEW_VMO))
            try check(a[3], MemoryLayout<UInt32>.size)
            let page = KernelLayout.pageSize
            guard a[2] > 0, a[1] % page == 0, a[2] % page == 0 else { throw .invalidArgs }
            try Resources.validate(table, handle, kind: UInt32(CROI_RSRC_KIND_MMIO), base: a[1], size: a[2])
            let vmo: Vmo
            do throws(VmError) {
                vmo = try Vmo(physical: a[1], size: a[2], cache: .device)  // Zircon's default: uncached
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
        default:
            throw .notSupported
        }
    }

    /// vmo_op_range: Zircon's ops and rights. COMMIT and PREFETCH round
    /// out to pages; DECOMMIT needs page alignment; ZERO and the cache ops
    /// take bytes (cache ops refuse size 0). Out of the VMO: OUT_OF_RANGE.
    private static func vmoOpRange(_ table: borrowing HandleTable, _ handle: UInt32, op: UInt32, offset: UInt64,
                                   size: UInt64) throws(Status) {
        let ref = try table.get(handle, type: .vmo)
        let rights = try table.rights(of: handle)
        let record = VmoPointer(address: UnsafeVmoObject(ref.object).vmo)
        let page = KernelLayout.pageSize
        func need(_ right: Rights) throws(Status) {
            guard rights.contains(right) else { throw .accessDenied }
        }
        func inRange() throws(Status) {
            guard !offset.addingReportingOverflow(size).overflow, offset + size <= record.pointee.size else {
                throw .outOfRange
            }
        }
        let cacheOp: UInt32
        switch op {
        case UInt32(CROI_VMO_OP_COMMIT), UInt32(CROI_VMO_OP_PREFETCH):
            try need(op == UInt32(CROI_VMO_OP_COMMIT) ? .write : .read)
            try inRange()
            guard size > 0 else { return }
            let start = offset & ~(page - 1), end = (offset + size + page - 1) & ~(page - 1)
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
            guard case .anonymous = record.pointee.kind else { throw .notSupported }
            guard size > 0 else { return }
            try vm { () throws(VmError) in
                try Vmo.withBorrowed(record) { (vmo: borrowing Vmo) throws(VmError) in
                    try vmo.decommit(offset: offset, size: size)
                }
            }
            return
        case UInt32(CROI_VMO_OP_ZERO):
            try need(.write)
            try inRange()
            guard record.inPhysmap else { throw .notSupported }
            try vm { () throws(VmError) in
                try Vmo.withBorrowed(record) { (vmo: borrowing Vmo) throws(VmError) in
                    try vmo.zero(offset: offset, size: size)
                }
            }
            return
        case UInt32(CROI_VMO_OP_CACHE_SYNC):
            try need(.read)
            guard size > 0 else { throw .invalidArgs }
            try inRange()
            try vm { () throws(VmError) in
                try Vmo.withBorrowed(record) { (vmo: borrowing Vmo) throws(VmError) in
                    try vmo.syncInstructions(offset: offset, size: size)
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
            try need(.write)
            throw .notSupported  // Zircon: debugging syscalls only (it can drop dirty lines)
        case 3, 4, 11:  // LOCK, UNLOCK, TRY_LOCK: discardable VMOs only
            throw .notSupported
        case 12, 13:  // DONT_NEED, ALWAYS_NEED: hints
            try inRange()
            return
        default:
            throw .invalidArgs
        }
        guard size > 0 else { throw .invalidArgs }
        try inRange()
        try vm { () throws(VmError) in
            try Vmo.withBorrowed(record) { (vmo: borrowing Vmo) throws(VmError) in
                try vmo.cacheOp(offset: offset, size: size, cacheOp)
            }
        }
    }
}
