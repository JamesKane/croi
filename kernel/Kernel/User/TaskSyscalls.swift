import CKernel

/// Jobs, processes, threads and VMARs from user space (K7a; numbers and
/// layouts in user/include/croi/syscall.h). Zircon's calls, adapted to six
/// argument registers: where Zircon passes seven, the VMAR handle and the
/// options share the first (handle | options << 32).
extension Syscalls {
    static func taskCall(_ number: UInt64, _ a: InlineArray<6, UInt64>,
                         _ table: borrowing HandleTable) throws(Status) {
        let handle = UInt32(truncatingIfNeeded: a[0])
        switch number {
        case 60:  // job_create(parent, options, out)
            guard a[1] == 0 else { throw .invalidArgs }
            try check(a[2], 4)
            let parent = try table.get(handle, type: .job, rights: .manageJob)
            let job = try Processes.createJob(parent: parent.object)
            try put(try table.add(job, rights: JobObject.defaultRights), a[2])
        case 61:  // process_create(job, name, name_len, options, out_process, out_vmar)
            try Policy.check(UInt32(CROI_POL_NEW_PROCESS))
            guard a[3] == 0 else { throw .invalidArgs }
            try checkName(a[1], a[2])
            try check(a[4], 4)
            try check(a[5], 4)
            let job = try table.get(handle, type: .job, rights: .manageProcess)
            let created = try Processes.create(job: job.object)
            try? Names.set(created.process, (try? Names.fromUser(a[1], a[2])) ?? ObjectName(repeating: 0))
            let process: UInt32
            do throws(Status) {
                process = try table.add(created.process, rights: ProcessObject.defaultRights)
            } catch {
                created.vmar.release()
                throw error
            }
            let vmar = try table.add(created.vmar, rights: VmarObject.defaultRights)
            try put(process, a[4])
            try put(vmar, a[5])
        case 62:  // process_start(process, thread, entry, stack, arg1 handle, arg2)
            let process = try table.get(handle, type: .process, rights: .write)
            let thread = try table.get(UInt32(truncatingIfNeeded: a[1]), type: .thread, rights: .write)
            guard ThreadObjectPointer(object: thread.object).pointee.process == process.object else {
                throw .accessDenied
            }
            let transferred = try transfer(UInt32(truncatingIfNeeded: a[4]), from: table, into: process.object)
            do throws(Status) {
                try Processes.start(thread: thread.object, pc: a[2], sp: a[3], arg0: UInt64(transferred), arg1: a[5],
                                    first: true)
            } catch {
                // The handle stays with the process; it is closed when the
                // process goes. Zircon closes it on failure too.
                throw error
            }
        case 64:  // thread_create(process, name, name_len, options, out)
            guard a[3] == 0 else { throw .invalidArgs }
            try checkName(a[1], a[2])
            try check(a[4], 4)
            let process = try table.get(handle, type: .process, rights: .manageThread)
            let thread = try Processes.createThread(process: process.object)
            try? Names.set(thread, (try? Names.fromUser(a[1], a[2])) ?? ObjectName(repeating: 0))
            try put(try table.add(thread, rights: ThreadObject.defaultRights), a[4])
        case 65:  // thread_start(thread, entry, stack, arg1, arg2)
            let thread = try table.get(handle, type: .thread, rights: .manageThread)
            try Processes.start(thread: thread.object, pc: a[1], sp: a[2], arg0: a[3], arg1: a[4], first: false)
        case 67:  // task_kill(task)
            let task = try table.get(handle, rights: .destroy)
            switch task.type {
            case .process: Processes.kill(process: task.object)
            case .thread: Processes.kill(thread: task.object)
            case .job: Processes.kill(job: task.object)
            default: throw .wrongType
            }
        case 78:  // object_get_child(parent, koid, rights, out)
            try check(a[3], MemoryLayout<UInt32>.size)
            let (child, rights) = try Processes.child(table, handle, koid: a[1], rights: UInt32(truncatingIfNeeded: a[2]))
            try put(try table.add(child, rights: rights), a[3])
        case 68:  // process_info(process, out croi_process_info_t)
            try check(a[1], MemoryLayout<croi_process_info_t>.size)
            let process = try table.get(handle, type: .process, rights: .inspect)
            let info = Processes.info(process: process.object)
            var flags: UInt32 = 0
            if info.started { flags |= UInt32(CROI_PROCESS_INFO_STARTED) }
            if info.exited { flags |= UInt32(CROI_PROCESS_INFO_EXITED) }
            try put(croi_process_info_t(return_code: info.returnCode, flags: flags, reserved: 0), a[1])
        case 70: try vmarAllocate(table, a)
        case 244: try vmarMapView(table, a)  // K15b
        case 71: try vmarMap(table, a)
        case 72:  // vmar_unmap(vmar, addr, len)
            try vmarUnmap(table, a)
        case 77:  // vmar_map_clock(vmar, options, vmar_offset, clock, len, mapped_addr), K13f
            try vmarMapClock(table, a)
        case 76:  // vmar_op_range(vmar, op, addr, len, buffer, buffer_size), K13e
            try vmarOpRange(table, a)
        case 73:  // vmar_protect(vmar | options << 32, addr, len)
            let rights = try vmRights(UInt32(truncatingIfNeeded: a[0] >> 32))
            let vmar = try table.get(handle, type: .vmar, rights: handleRights(rights))
            let v = VmarPointer(object: vmar.object).info
            guard inside(a[1], a[2], v.base, v.size) else { throw .invalidArgs }
            try vm { () throws(VmError) in
                try UserAspace.withView(v.aspace) { (aspace: borrowing UserAspace) throws(VmError) in
                    try aspace.protect(a[1], size: a[2], rights: rights)
                }
            }
        case 74:  // vmar_destroy(vmar)
            let vmar = try table.get(handle, type: .vmar, rights: .destroy)
            let v = VmarPointer(object: vmar.object).info
            guard v.region != UserAspace.root else { throw .accessDenied }
            try vm { () throws(VmError) in
                try UserAspace.withView(v.aspace) { (aspace: borrowing UserAspace) throws(VmError) in
                    try aspace.destroyRegion(v.region)
                }
            }
        default:
            throw .notSupported
        }
    }

    /// vmar_allocate(parent | options << 32, offset, size, out_child, out_addr):
    /// a sub-region placed first fit (SPECIFIC placement isn't supported
    /// yet). The child's rights are the parent's, limited by CAN_MAP_*.
    private static func vmarAllocate(_ table: borrowing HandleTable, _ a: InlineArray<6, UInt64>) throws(Status) {
        let options = UInt32(truncatingIfNeeded: a[0] >> 32)
        let canMap = UInt32(CROI_VM_CAN_MAP_READ | CROI_VM_CAN_MAP_WRITE | CROI_VM_CAN_MAP_EXECUTE)
        let specific = options & UInt32(CROI_VM_SPECIFIC) != 0
        // Ext 7 (K15b): a reservation for views (vmar_map_view), a JIT one
        // with a protection key where there is one.
        let reserve = UInt32(CROI_VM_RESERVATION), jit = UInt32(CROI_VM_JIT)
        guard options & ~(canMap | UInt32(CROI_VM_SPECIFIC) | reserve | jit) == 0, specific || a[1] == 0 else {
            throw .invalidArgs
        }
        try check(a[3], 4)
        try check(a[4], 8)
        var parentRights = Rights()
        let parent = try table.get(UInt32(truncatingIfNeeded: a[0]), type: .vmar, have: &parentRights)
        var rights: Rights = .transfer | .inspect | .destroy
        if options & UInt32(CROI_VM_CAN_MAP_READ) != 0 { rights.insert(.read) }
        if options & UInt32(CROI_VM_CAN_MAP_WRITE) != 0 { rights.insert(.write) }
        if options & UInt32(CROI_VM_CAN_MAP_EXECUTE) != 0 { rights.insert(.execute) }
        guard parentRights.contains(Rights(rawValue: rights.rawValue & (Rights.read.rawValue | Rights.write.rawValue
                                                                          | Rights.execute.rawValue))) else {
            throw .accessDenied
        }
        let v = VmarPointer(object: parent.object).info
        let region = try vm { () throws(VmError) -> Region in
            try UserAspace.withView(v.aspace) { (aspace: borrowing UserAspace) throws(VmError) -> Region in
                try aspace.allocateRegion(size: a[2], in: v.region,
                                          at: specific ? (a[1] <= UInt64.max - v.base ? v.base + a[1] : .max) : nil,
                                          reservation: options & (reserve | jit) != 0, jit: options & jit != 0)
            }
        }
        let child = try Processes.makeVmar(v.aspace, region: region.id, base: region.base, size: region.size)
        try put(try table.add(child, rights: rights), a[3])
        try put(region.base, a[4])
    }

    /// vmar_map_view(vmar | perms << 32, vmar_offset, vmo, vmo_offset, len),
    /// ext 7 (K15b): [vmar_offset, +len) of a reservation now shows the VMO
    /// range, replacing whatever views were there atomically. Rights as
    /// vmar_map's (the VMAR's CAN_MAP_*, the VMO handle's per permission);
    /// W^X but in a JIT reservation with a key; the ceiling for later
    /// vmar_protect is the VMO handle's.
    private static func vmarMapView(_ table: borrowing HandleTable, _ a: InlineArray<6, UInt64>) throws(Status) {
        let perms = UInt32(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE | CROI_VM_PERM_EXECUTE) | UInt32(CROI_VM_PERM_GUARDED)
        let options = UInt32(truncatingIfNeeded: a[0] >> 32)
        guard options & ~perms == 0 else { throw .invalidArgs }
        let rights = try vmRights(options)
        let vmar = try table.get(UInt32(truncatingIfNeeded: a[0]), type: .vmar, rights: handleRights(rights))
        let v = VmarPointer(object: vmar.object).info
        guard a[1] <= v.size, a[4] <= v.size - a[1] else { throw .invalidArgs }
        var vmoRights = Rights()
        let vmo = try VmoObject.forMapping(table, UInt32(truncatingIfNeeded: a[2]), rights, have: &vmoRights)
        defer { vmo.release() }
        var ceiling = VmRights()
        if vmoRights.contains(.read) { ceiling.insert(.read) }
        if vmoRights.contains(.write) { ceiling.insert(.write) }
        if vmoRights.contains(.execute) { ceiling.insert(.execute) }
        try vm { () throws(VmError) in
            try Vmo.withBorrowed(vmo) { (borrowed: borrowing Vmo) throws(VmError) in
                try UserAspace.withView(v.aspace) { (aspace: borrowing UserAspace) throws(VmError) in
                    try aspace.mapView(borrowed, offset: a[3], size: a[4], at: v.base + a[1], in: v.region,
                                       rights: rights, ceiling: ceiling)
                }
            }
        }
    }

    /// vmar_map(vmar | options << 32, vmar_offset, vmo, vmo_offset, len, out_addr).
    private static func vmarMap(_ table: borrowing HandleTable, _ a: InlineArray<6, UInt64>) throws(Status) {
        let options = UInt32(truncatingIfNeeded: a[0] >> 32)
        let perms = UInt32(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE | CROI_VM_PERM_EXECUTE) | UInt32(CROI_VM_PERM_GUARDED)
        let accepted = UInt32(CROI_VM_SPECIFIC) | UInt32(CROI_VM_REQUIRE_NON_RESIZABLE) | UInt32(CROI_VM_ALLOW_FAULTS)
        guard options & ~(perms | accepted) == 0 else { throw .invalidArgs }
        let rights = try vmRights(options & perms)
        try check(a[5], 8)
        let vmar = try table.get(UInt32(truncatingIfNeeded: a[0]), type: .vmar, rights: handleRights(rights))
        let v = VmarPointer(object: vmar.object).info
        var at: UInt64? = nil
        if options & UInt32(CROI_VM_SPECIFIC) != 0 {
            guard a[1] <= v.size, a[4] <= v.size - a[1] else { throw .invalidArgs }
            at = v.base + a[1]
        } else {
            guard a[1] == 0 else { throw .invalidArgs }
        }
        // What a later vmar_protect may grant: the VMO handle's rights.
        var vmoRights = Rights()
        let vmo = try VmoObject.forMapping(table, UInt32(truncatingIfNeeded: a[2]), rights, have: &vmoRights)
        defer { vmo.release() }
        var ceiling = VmRights()
        if vmoRights.contains(.read) { ceiling.insert(.read) }
        if vmoRights.contains(.write) { ceiling.insert(.write) }
        if vmoRights.contains(.execute) { ceiling.insert(.execute) }
        if options & UInt32(CROI_VM_REQUIRE_NON_RESIZABLE) != 0, vmo.pointee.resizable { throw .notSupported }  // K13h
        let mapped = try vm { () throws(VmError) -> UInt64 in
            try Vmo.withBorrowed(vmo) { (borrowed: borrowing Vmo) throws(VmError) -> UInt64 in
                try UserAspace.withView(v.aspace) { (aspace: borrowing UserAspace) throws(VmError) -> UInt64 in
                    try aspace.map(borrowed, offset: a[3], size: a[4], at: at, in: v.region, rights: rights,
                                   ceiling: ceiling)
                }
            }
        }
        try put(mapped, a[5])
    }

    /// Hands handle `value` (needs TRANSFER) from `table` to `process`'s
    /// table; returns its value there (0 for no handle).
    private static func transfer(_ value: UInt32, from table: borrowing HandleTable,
                                 into process: ObjectPointer) throws(Status) -> UInt32 {
        guard value != 0 else { return 0 }
        var rights = Rights()
        let object = try table.get(value, rights: .transfer, have: &rights)
        let p = ProcessPointer(object: process)
        object.object.retain()  // the new handle's
        let added = try process.header.lock.withLock { () throws(Status) -> UInt32 in
            guard let target = p.pointee.handles?.address else { throw .badState }
            return try HandleTable.withBorrowed(target) { (handles: borrowing HandleTable) throws(Status) -> UInt32 in
                try handles.add(object.object, rights: rights)
            }
        }
        try table.close(value)
        return added
    }

    /// Names are read (not kept yet: get_property comes later).
    private static func checkName(_ address: UInt64, _ length: UInt64) throws(Status) {
        guard length <= 32 else { throw .invalidArgs }
        guard length > 0 else { return }
        var name = InlineArray<32, UInt8>(repeating: 0)
        var span = name.mutableSpan
        let copied = span.withUnsafeMutableBytes { raw in unsafe UserCopy.from(raw.baseAddress!, address, length) }
        guard copied == 0 else { throw .invalidArgs }
    }

    private static func vmRights(_ perms: UInt32) throws(Status) -> VmRights {
        var rights = VmRights()
        if perms & UInt32(CROI_VM_PERM_READ) != 0 { rights.insert(.read) }
        if perms & UInt32(CROI_VM_PERM_WRITE) != 0 { rights.insert(.write) }
        if perms & UInt32(CROI_VM_PERM_EXECUTE) != 0 { rights.insert(.execute) }
        if perms & UInt32(CROI_VM_PERM_GUARDED) != 0 { rights.insert(.guarded) }  // K14r
        return rights
    }

    private static func handleRights(_ rights: VmRights) -> Rights {
        var needed = Rights()
        if rights.contains(.read) { needed.insert(.read) }
        if rights.contains(.write) { needed.insert(.write) }
        if rights.contains(.execute) { needed.insert(.execute) }
        return needed
    }

    private static func inside(_ base: UInt64, _ size: UInt64, _ regionBase: UInt64, _ regionSize: UInt64) -> Bool {
        base >= regionBase && size <= regionSize && base - regionBase <= regionSize - size
    }

    static func vm<R>(_ body: () throws(VmError) -> R) throws(Status) -> R {
        try vmStatus(body)
    }

    /// vmar_op_range (K13e, Zircon's order of checks): COMMIT, DECOMMIT,
    /// MAP_RANGE, ZERO, DONT_NEED and ALWAYS_NEED (K14a's hints),
    /// PREFETCH over the mappings of [addr, addr+len), which must leave no
    /// gap (BAD_STATE) and, unless the handle has OP_CHILDREN (and for
    /// COMMIT, DECOMMIT and PREFETCH always), be the VMAR's own. Checked
    /// whole under the aspace lock, then done piece by piece without it
    /// (pagers may be waited for); the first error stops it.
    private static func vmarOpRange(_ table: borrowing HandleTable, _ a: InlineArray<6, UInt64>) throws(Status) {
        let handle = UInt32(truncatingIfNeeded: a[0])
        var rights = Rights()
        let vmar = try table.get(handle, type: .vmar, have: &rights)
        let op = a[1]
        let commitOp = UInt64(CROI_VMO_OP_COMMIT), decommitOp = UInt64(CROI_VMO_OP_DECOMMIT)
        let mapRangeOp: UInt64 = 3, zeroOp = UInt64(CROI_VMO_OP_ZERO), dontNeedOp: UInt64 = 12, alwaysNeedOp: UInt64 = 13
        let prefetchOp = UInt64(CROI_VMO_OP_PREFETCH)
        let needed: Rights
        switch op {
        case commitOp, decommitOp, zeroOp: needed = .write
        case prefetchOp, mapRangeOp: needed = .read
        case dontNeedOp, alwaysNeedOp: needed = Rights()
        default: throw .invalidArgs
        }
        guard rights.contains(needed) else { throw .accessDenied }
        guard a[4] == 0, a[5] == 0 else { throw .invalidArgs }
        let page = KernelLayout.pageSize
        guard a[3] <= UInt64.max - (page - 1) else { throw .invalidArgs }
        let length = (a[3] + page - 1) & ~(page - 1)
        guard length > 0, a[2] % page == 0 else { throw .invalidArgs }
        let v = VmarPointer(object: vmar.object).info
        guard inside(a[2], length, v.base, v.size) else { throw .outOfRange }
        let start = a[2], end = a[2] + length
        let directOnly = op == commitOp || op == decommitOp || op == prefetchOp || !rights.contains(.opChildren)
        struct Piece { let vmo: VmoPointer; let offset: UInt64; let size: UInt64; let base: UInt64 }
        var pieces = UniqueArray<Piece>()
        defer { for i in 0..<pieces.count { pieces[i].vmo.release() } }
        try v.aspace.pointee.lock.withLock { () throws(Status) in
            guard !v.aspace.pointee.dead else { throw .badState }
            var expected = start
            for i in 0..<v.aspace.pointee.mappings.count {
                let m = v.aspace.pointee.mappings[i]
                guard m.base < end, start < m.base + m.size else { continue }
                if pieces.count > 0 || m.base > start { guard m.base == expected else { throw .badState } }
                guard !directOnly || m.region == v.region else { throw .invalidArgs }
                switch op {
                case commitOp, decommitOp, zeroOp: guard m.rights.contains(.write) else { throw .accessDenied }
                case prefetchOp: guard m.rights.contains(.read) else { throw .accessDenied }
                default: break
                }
                let from = max(m.base, start), to = min(m.base + m.size, end)
                m.vmo.retain()
                pieces.append(Piece(vmo: m.vmo, offset: m.offset + (from - m.base), size: to - from, base: from))
                expected = to
            }
            guard expected == end, pieces.count > 0 || start == end else { throw .badState }
        }
        for i in 0..<pieces.count {
            let p = pieces[i]
            switch op {
            case commitOp:
                try Pagers.ensureRange(p.vmo, p.offset, p.size)
                try vm { () throws(VmError) in
                    try Vmo.withBorrowed(p.vmo) { (vmo: borrowing Vmo) throws(VmError) in try vmo.commit(offset: p.offset, size: p.size) }
                }
                v.aspace.mapPresent(p.base, p.size)
            case decommitOp:
                guard case .anonymous = p.vmo.pointee.kind else { throw .notSupported }
                try vm { () throws(VmError) in
                    try Vmo.withBorrowed(p.vmo) { (vmo: borrowing Vmo) throws(VmError) in try vmo.decommit(offset: p.offset, size: p.size) }
                }
            case zeroOp:
                try Pagers.ensureWritableRange(p.vmo, p.offset, p.size)
                try vm { () throws(VmError) in
                    try Vmo.withBorrowed(p.vmo) { (vmo: borrowing Vmo) throws(VmError) in try vmo.zero(offset: p.offset, size: p.size) }
                }
            case prefetchOp:
                try Pagers.ensureRange(p.vmo, p.offset, p.size)
                v.aspace.mapPresent(p.base, p.size)
            case alwaysNeedOp:
                Reclaim.hint(p.vmo, offset: p.offset, size: p.size, alwaysNeed: true)  // pages in, errors ignored
                v.aspace.mapPresent(p.base, p.size)
            case mapRangeOp:
                v.aspace.mapPresent(p.base, p.size)
            default:
                Reclaim.hint(p.vmo, offset: p.offset, size: p.size, alwaysNeed: false)  // DONT_NEED
            }
        }
    }

    /// vmar_map_clock (K13f, Zircon's order): read-only permissions only,
    /// exactly a page, a MAPPABLE clock; its page as a VMO with the clock
    /// handle's READ and MAP.
    private static func vmarMapClock(_ table: borrowing HandleTable, _ a: InlineArray<6, UInt64>) throws(Status) {
        let options = UInt32(truncatingIfNeeded: a[1])
        guard UInt64(options) == a[1],
              options & (UInt32(CROI_VM_PERM_WRITE) | UInt32(CROI_VM_PERM_EXECUTE)) == 0,
              options & ~(UInt32(CROI_VM_PERM_READ) | UInt32(CROI_VM_SPECIFIC)) == 0 else { throw .invalidArgs }
        guard a[4] == KernelLayout.pageSize else { throw .invalidArgs }
        let clockHandle = UInt32(truncatingIfNeeded: a[3])
        var clockRights = Rights()
        let clock = try table.get(clockHandle, type: .clock, have: &clockRights)
        guard let page = ClockPointer(object: clock.object).pointee.page else { throw .invalidArgs }
        let vmar = try table.get(UInt32(truncatingIfNeeded: a[0]), type: .vmar, rights: .read)
        guard clockRights.contains(.read | .map) else { throw .accessDenied }
        try check(a[5], 8)
        let v = VmarPointer(object: vmar.object).info
        var at: UInt64? = nil
        if options & UInt32(CROI_VM_SPECIFIC) != 0 {
            guard a[2] <= v.size, a[4] <= v.size - a[2] else { throw .invalidArgs }
            at = v.base + a[2]
        } else {
            guard a[2] == 0 else { throw .invalidArgs }
        }
        page.retain()
        defer { page.release() }
        let mapped = try vm { () throws(VmError) -> UInt64 in
            try Vmo.withBorrowed(page) { (borrowed: borrowing Vmo) throws(VmError) -> UInt64 in
                try UserAspace.withView(v.aspace) { (aspace: borrowing UserAspace) throws(VmError) -> UInt64 in
                    try aspace.map(borrowed, offset: 0, size: a[4], at: at, in: v.region, rights: .read)
                }
            }
        }
        try put(mapped, a[5])
    }

    private static func vmarUnmap(_ table: borrowing HandleTable, _ a: InlineArray<6, UInt64>) throws(Status) {
        let vmar = try table.get(UInt32(truncatingIfNeeded: a[0]), type: .vmar)
        let v = VmarPointer(object: vmar.object).info
        guard inside(a[1], a[2], v.base, v.size) else { throw .invalidArgs }
        try vm { () throws(VmError) in
            try UserAspace.withView(v.aspace) { (aspace: borrowing UserAspace) throws(VmError) in
                try aspace.unmap(a[1], size: a[2])
            }
        }
    }

    /// vmar_unmap_handle_close_thread_exit(vmar, addr, len, close_handle),
    /// up to the exit (`run` does it, once nothing holds a reference):
    /// vmar_unmap's errors return; then 0, or 1 if the handle wouldn't
    /// close. The unmap may take the caller's own stack: it never runs
    /// user code again unless an exception handler resumes it.
    static func unmapAndClose(_ a: InlineArray<6, UInt64>, _ table: borrowing HandleTable) throws(Status) -> Int64 {
        try vmarUnmap(table, a)
        do throws(Status) {
            try table.close(UInt32(truncatingIfNeeded: a[3]))
        } catch {
            return 1
        }
        return 0
    }
}
