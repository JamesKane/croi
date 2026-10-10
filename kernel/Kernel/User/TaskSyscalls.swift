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
            guard a[3] == 0 else { throw .invalidArgs }
            try checkName(a[1], a[2])
            try check(a[4], 4)
            try check(a[5], 4)
            let job = try table.get(handle, type: .job, rights: .manageProcess)
            let created = try Processes.create(job: job.object)
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
        case 68:  // process_info(process, out croi_process_info_t)
            try check(a[1], MemoryLayout<croi_process_info_t>.size)
            let process = try table.get(handle, type: .process, rights: .inspect)
            let info = Processes.info(process: process.object)
            var flags: UInt32 = 0
            if info.started { flags |= UInt32(CROI_PROCESS_INFO_STARTED) }
            if info.exited { flags |= UInt32(CROI_PROCESS_INFO_EXITED) }
            try put(croi_process_info_t(return_code: info.returnCode, flags: flags, reserved: 0), a[1])
        case 70: try vmarAllocate(table, a)
        case 71: try vmarMap(table, a)
        case 72:  // vmar_unmap(vmar, addr, len)
            let vmar = try table.get(handle, type: .vmar)
            let v = VmarPointer(object: vmar.object).info
            guard inside(a[1], a[2], v.base, v.size) else { throw .invalidArgs }
            try vm { () throws(VmError) in
                try UserAspace.withView(v.aspace) { (aspace: borrowing UserAspace) throws(VmError) in
                    try aspace.unmap(a[1], size: a[2])
                }
            }
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
        guard options & ~canMap == 0, a[1] == 0 else { throw .invalidArgs }
        try check(a[3], 4)
        try check(a[4], 8)
        let parent = try table.get(UInt32(truncatingIfNeeded: a[0]), type: .vmar)
        let parentRights = try table.rights(of: UInt32(truncatingIfNeeded: a[0]))
        var rights: Rights = [.transfer, .inspect, .destroy]
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
                try aspace.allocateRegion(size: a[2], in: v.region)
            }
        }
        let child = try Processes.makeVmar(v.aspace, region: region.id, base: region.base, size: region.size)
        try put(try table.add(child, rights: rights), a[3])
        try put(region.base, a[4])
    }

    /// vmar_map(vmar | options << 32, vmar_offset, vmo, vmo_offset, len, out_addr).
    private static func vmarMap(_ table: borrowing HandleTable, _ a: InlineArray<6, UInt64>) throws(Status) {
        let options = UInt32(truncatingIfNeeded: a[0] >> 32)
        let perms = UInt32(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE | CROI_VM_PERM_EXECUTE)
        guard options & ~(perms | UInt32(CROI_VM_SPECIFIC)) == 0 else { throw .invalidArgs }
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
        let vmo = try VmoObject.forMapping(table, UInt32(truncatingIfNeeded: a[2]), rights)
        defer { vmo.release() }
        let mapped = try vm { () throws(VmError) -> UInt64 in
            try Vmo.withBorrowed(vmo) { (borrowed: borrowing Vmo) throws(VmError) -> UInt64 in
                try UserAspace.withView(v.aspace) { (aspace: borrowing UserAspace) throws(VmError) -> UInt64 in
                    try aspace.map(borrowed, offset: a[3], size: a[4], at: at, in: v.region, rights: rights)
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
        let rights = try table.rights(of: value)
        guard rights.contains(.transfer) else { throw .accessDenied }
        let object = try table.get(value)
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

    private static func vm<R>(_ body: () throws(VmError) -> R) throws(Status) -> R {
        try vmStatus(body)
    }
}
