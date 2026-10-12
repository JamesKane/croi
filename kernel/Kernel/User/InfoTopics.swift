import CKernel
import PageTables

/// K13e part 2: the task and VMO info topics (Zircon's numbers, layouts
/// and rights; task.h, vmo.h). object_get_info's fifth and sixth
/// arguments are Zircon's actual and avail (optional): fixed-size topics
/// write 1 and 1 (actual 0 when the buffer is short, then
/// BUFFER_TOO_SMALL); list topics fill what fits and give the total, never
/// BUFFER_TOO_SMALL. Snapshots: things may change as they are read.
extension Syscalls {
    /// Handles `a[1]` if it is one of these topics; false if it isn't.
    static func taskInfo(_ a: InlineArray<6, UInt64>, _ table: borrowing HandleTable) throws(Status) -> Bool {
        let handle = UInt32(truncatingIfNeeded: a[0])
        guard a[1] >> 32 == 0 else { return false }
        let topic = UInt32(a[1]), version = topic >> 28
        switch topic & 0x0FFF_FFFF {  // the topic; versions differ in bits 31:28
        case 3 where version == 1:  // CROI_INFO_PROCESS
            let ref = try table.get(handle, type: .process, rights: .inspect)
            try single(processInfo(ref.object), MemoryLayout<croi_info_process_t>.size, a)
        case UInt32(CROI_INFO_THREAD) where version == 0:
            let ref = try table.get(handle, type: .thread, rights: .inspect)
            try single(threadInfo(ref.object), MemoryLayout<croi_info_thread_t>.size, a)
        case UInt32(CROI_INFO_THREAD_EXCEPTION_REPORT_V1) where version <= 1:  // K13g
            let ref = try table.get(handle, type: .thread, rights: .inspect)
            let report = try ref.object.header.lock.withLock { () throws(Status) -> croi_exception_report_t in
                let t = ThreadObjectPointer(object: ref.object)
                guard t.pointee.inException else { throw .badState }
                return t.pointee.exceptionReport
            }
            try single(report, MemoryLayout<croi_exception_report_t>.size, a)
        case UInt32(CROI_INFO_THREAD_STATS) where version == 0:
            let ref = try table.get(handle, type: .thread, rights: .inspect)
            try single(try threadStats(ref.object), MemoryLayout<croi_info_thread_stats_t>.size, a)
        case 30 where version <= 1:  // CROI_INFO_TASK_RUNTIME(_V1)
            let ref = try table.get(handle, rights: .inspect)
            let (cpu, queue) = try runtime(ref.object)
            let info = croi_info_task_runtime_t(cpu_time: Int64(bitPattern: cpu), queue_time: Int64(bitPattern: queue),
                                                page_fault_time: 0, lock_contention_time: 0)
            try single(info, a[1] == UInt64(CROI_INFO_TASK_RUNTIME_V1) ? 16 : MemoryLayout<croi_info_task_runtime_t>.size, a)
        case UInt32(CROI_INFO_JOB) where version == 0:
            let ref = try table.get(handle, type: .job, rights: .inspect)
            let job = JobPointer(object: ref.object)
            let (code, dead, debugged) = ref.object.header.lock.withLock {
                (job.pointee.returnCode, job.pointee.dead, Exceptions.debuggerAttachedLocked(ref.object))
            }
            try single(croi_info_job_t(return_code: code, exited: dead ? 1 : 0, kill_on_oom: 0, debugger_attached: debugged ? 1 : 0,
                                       padding: (0, 0, 0, 0, 0)), MemoryLayout<croi_info_job_t>.size, a)
        case UInt32(CROI_INFO_JOB_CHILDREN) where version == 0, UInt32(CROI_INFO_JOB_PROCESSES) where version == 0:
            let ref = try table.get(handle, type: .job, rights: .enumerate)
            let wanted: ObjectType = a[1] == UInt64(CROI_INFO_JOB_CHILDREN) ? .job : .process
            var koids = UniqueArray<UInt64>()
            ref.object.header.lock.withLock {
                let job = JobPointer(object: ref.object)
                for i in 0..<job.pointee.children.count {
                    let child = ObjectPointer(address: job.pointee.children[i])
                    if child.header.type == wanted { koids.append(child.header.koid) }
                }
            }
            try list(koids.count, 8, a) { (i, address) throws(Status) in try put(koids[i], address) }
        case UInt32(CROI_INFO_PROCESS_THREADS) where version == 0:
            let ref = try table.get(handle, type: .process, rights: .enumerate)
            var koids = UniqueArray<UInt64>()
            ref.object.header.lock.withLock {
                let process = ProcessPointer(object: ref.object)
                for i in 0..<process.pointee.threads.count {
                    koids.append(ObjectPointer(address: process.pointee.threads[i]).header.koid)
                }
            }
            try list(koids.count, 8, a) { (i, address) throws(Status) in try put(koids[i], address) }
        case UInt32(CROI_INFO_VMO_V1):
            let size: Int
            switch a[1] {
            case UInt64(CROI_INFO_VMO): size = MemoryLayout<croi_info_vmo_t>.size
            case UInt64(CROI_INFO_VMO_V3): size = 128
            case UInt64(CROI_INFO_VMO_V2): size = 120
            case UInt64(CROI_INFO_VMO_V1): size = 104
            default: return false
            }
            var rights = Rights()
            let ref = try table.get(handle, type: .vmo, have: &rights)  // no rights needed (Zircon's)
            let vmo = VmoPointer(address: UnsafeVmoObject(ref.object).vmo)
            try single(vmoInfo(vmo, via: UInt32(CROI_INFO_VMO_VIA_HANDLE), rights: rights.rawValue), size, a)
        case UInt32(CROI_INFO_PROCESS_VMOS_V1):
            let size: Int
            switch a[1] {
            case UInt64(CROI_INFO_PROCESS_VMOS): size = MemoryLayout<croi_info_vmo_t>.size
            case UInt64(CROI_INFO_PROCESS_VMOS_V3): size = 128
            case UInt64(CROI_INFO_PROCESS_VMOS_V2): size = 120
            case UInt64(CROI_INFO_PROCESS_VMOS_V1): size = 104
            default: return false
            }
            let ref = try table.get(handle, type: .process, rights: .inspect)
            var entries = try processVmos(ref.object)
            try list(entries.count, size, a) { (i, address) throws(Status) in try putPrefix(entries[i], size, address) }
            entries.removeAll()
        case UInt32(CROI_INFO_PROCESS_MAPS_V1):
            let size: Int
            switch a[1] {
            case UInt64(CROI_INFO_PROCESS_MAPS): size = MemoryLayout<croi_info_maps_t>.size
            case UInt64(CROI_INFO_PROCESS_MAPS_V2): size = 104
            case UInt64(CROI_INFO_PROCESS_MAPS_V1): size = 96
            default: return false
            }
            let ref = try table.get(handle, type: .process, rights: .inspect)
            let maps = try processMaps(ref.object, v1: size == 96, v2: size == 104)
            try list(maps.count, size, a) { (i, address) throws(Status) in
                var entry = maps[i]
                let failed = withUnsafeBytes(of: &entry) { unsafe UserCopy.to(address, $0.baseAddress!, UInt64(size)) }
                guard failed == 0 else { throw .invalidArgs }
            }
        case UInt32(CROI_INFO_CLOCK_MAPPED_SIZE) where version == 0:  // K13f
            let ref = try table.get(handle, type: .clock)
            guard ClockPointer(object: ref.object).pointee.page != nil else { throw .invalidArgs }
            try single(KernelLayout.pageSize, 8, a)
        case UInt32(CROI_INFO_HANDLE_TABLE) where version == 0:
            let ref = try table.get(handle, type: .process, rights: .inspect | .manageProcess | .manageThread)
            let process = ProcessPointer(object: ref.object)
            var entries = UniqueArray<HandleTable.Entry>()
            ref.object.header.lock.withLock {
                if let address = process.pointee.handles?.address { HandleTable.snapshot(address: address, into: &entries) }
            }
            defer { for i in 0..<entries.count { ObjectPointer(address: entries[i].object).release() } }
            var infos = UniqueArray<croi_info_handle_extended_t>()
            for i in 0..<entries.count {
                let object = ObjectPointer(address: entries[i].object)
                infos.append(croi_info_handle_extended_t(
                    type: object.header.type.rawValue, handle_value: entries[i].value, rights: entries[i].rights.rawValue,
                    reserved: 0, koid: object.header.koid, related_koid: Channels.relatedKoid(object), peer_owner_koid: 0))
            }
            try list(infos.count, MemoryLayout<croi_info_handle_extended_t>.size, a) { (i, address) throws(Status) in
                try put(infos[i], address)
            }
            _ = entries.count
        default:
            return false
        }
        return true
    }

    // MARK: Writing

    private static func counts(_ actual: UInt64, _ avail: UInt64, _ a: InlineArray<6, UInt64>) throws(Status) {
        if a[4] != 0 { try put(actual, a[4]) }
        if a[5] != 0 { try put(avail, a[5]) }
    }

    /// A fixed-size record (its first `size` bytes).
    private static func single<T: BitwiseCopyable>(_ value: T, _ size: Int, _ a: InlineArray<6, UInt64>) throws(Status) {
        guard a[3] >= UInt64(size) else {
            try counts(0, 1, a)
            throw .bufferTooSmall
        }
        try putPrefix(value, size, a[2])
        try counts(1, 1, a)
    }

    /// `count` records of `size` bytes: as many as fit.
    private static func list(_ count: Int, _ size: Int, _ a: InlineArray<6, UInt64>,
                             _ write: (Int, UInt64) throws(Status) -> Void) throws(Status) {
        let room = Int(min(a[3] / UInt64(size), UInt64(count)))
        for i in 0..<room { try write(i, a[2] + UInt64(i * size)) }
        try counts(UInt64(room), UInt64(count), a)
    }

    // MARK: Tasks

    private static func processInfo(_ object: ObjectPointer) -> croi_info_process_t {
        let process = ProcessPointer(object: object)
        return object.header.lock.withLock { () -> croi_info_process_t in
            var flags: UInt32 = 0
            switch process.pointee.state {
            case .initial: break
            case .running: flags = UInt32(CROI_INFO_PROCESS_FLAG_STARTED)
            case .dying, .dead: flags = UInt32(CROI_INFO_PROCESS_FLAG_STARTED) | UInt32(CROI_INFO_PROCESS_FLAG_EXITED)
            }
            if Exceptions.debuggerAttachedLocked(object) { flags |= UInt32(CROI_INFO_PROCESS_FLAG_DEBUGGER_ATTACHED) }
            return croi_info_process_t(return_code: process.pointee.returnCode,
                                       start_time: Int64(bitPattern: process.pointee.startTime), flags: flags,
                                       padding: (0, 0, 0, 0))
        }
    }

    private static func threadInfo(_ object: ObjectPointer) -> croi_info_thread_t {
        let thread = ThreadObjectPointer(object: object)
        return object.header.lock.withLock { () -> croi_info_thread_t in
            var info = croi_info_thread_t()
            info.wait_exception_channel_type = thread.pointee.exceptionChannelType
            switch thread.pointee.state {
            case .initial:
                info.state = UInt32(CROI_THREAD_STATE_NEW)
            case .dead:
                info.state = UInt32(CROI_THREAD_STATE_DEAD)
            case .running:
                guard thread.pointee.thread != 0 else {
                    info.state = UInt32(CROI_THREAD_STATE_NEW)  // started, not yet scheduled
                    return info
                }
                let scheduled = ThreadPointer(address: thread.pointee.thread)
                let (blocked, affinity) = Scheduler.locked { (scheduled.pointee.state == .blocked, scheduled.pointee.affinity) }
                info.cpu_affinity_mask.0 = affinity
                if thread.pointee.killed {
                    info.state = UInt32(CROI_THREAD_STATE_DYING)
                } else if thread.pointee.suspended {
                    info.state = UInt32(CROI_THREAD_STATE_SUSPENDED)
                } else if thread.pointee.exceptionFrame != 0 {
                    info.state = UInt32(CROI_THREAD_STATE_BLOCKED_EXCEPTION)
                } else if blocked {
                    info.state = blockedState(scheduled)
                } else {
                    info.state = UInt32(CROI_THREAD_STATE_RUNNING)
                }
            }
            return info
        }
    }

    /// Why a blocked user thread waits, from the syscall it is in (a page
    /// fault waits for a pager). Racy: a snapshot.
    private static func blockedState(_ thread: ThreadPointer) -> UInt32 {
        guard thread.pointee.enteredUser else { return UInt32(CROI_THREAD_STATE_BLOCKED) }  // parked before its first entry
        let user = unsafe UserTraps.userFrame(of: thread)
        guard unsafe ExceptionFrame.isSyscall(user.pointee) else { return UInt32(CROI_THREAD_STATE_BLOCKED_PAGER) }
        switch unsafe ExceptionFrame.syscallNumber(user.pointee) {
        case 4: return UInt32(CROI_THREAD_STATE_BLOCKED_SLEEPING)
        case 90...94: return UInt32(CROI_THREAD_STATE_BLOCKED_FUTEX)
        case 33: return UInt32(CROI_THREAD_STATE_BLOCKED_PORT)
        case 83, 215: return UInt32(CROI_THREAD_STATE_BLOCKED_CHANNEL)
        case 210: return UInt32(CROI_THREAD_STATE_BLOCKED_WAIT_MANY)
        case 143: return UInt32(CROI_THREAD_STATE_BLOCKED_INTERRUPT)
        case 41, 42, 45, 195...198: return UInt32(CROI_THREAD_STATE_BLOCKED_PAGER)
        default: return UInt32(CROI_THREAD_STATE_BLOCKED_WAIT_ONE)  // object, counter and other waits
        }
    }

    private static func threadStats(_ object: ObjectPointer) throws(Status) -> croi_info_thread_stats_t {
        let thread = ThreadObjectPointer(object: object)
        return try object.header.lock.withLock { () throws(Status) -> croi_info_thread_stats_t in
            guard thread.pointee.state != .dead else { throw .badState }  // Zircon's
            guard thread.pointee.thread != 0 else {
                return croi_info_thread_stats_t(total_runtime: 0, last_scheduled_cpu: UInt32(CROI_INFO_INVALID_CPU),
                                                padding: (0, 0, 0, 0))
            }
            let scheduled = ThreadPointer(address: thread.pointee.thread)
            let (cpu, _) = Scheduler.runtime(scheduled)
            let last = Scheduler.locked { scheduled.pointee.cpusSeen == 0 ? UInt32(CROI_INFO_INVALID_CPU) : UInt32(scheduled.pointee.cpu) }
            return croi_info_thread_stats_t(total_runtime: Int64(bitPattern: cpu), last_scheduled_cpu: last,
                                            padding: (0, 0, 0, 0))
        }
    }

    /// TASK_RUNTIME: a thread's own; a process's threads', dead and alive;
    /// a job's processes' and jobs', recursively.
    private static func runtime(_ object: ObjectPointer) throws(Status) -> (UInt64, UInt64) {
        switch object.header.type {
        case .thread:
            let thread = ThreadObjectPointer(object: object)
            return object.header.lock.withLock { () -> (UInt64, UInt64) in
                if thread.pointee.thread != 0 { return Scheduler.runtime(ThreadPointer(address: thread.pointee.thread)) }
                return (thread.pointee.finalCpuTime, thread.pointee.finalQueueTime)
            }
        case .process:
            let process = ProcessPointer(object: object)
            var threads = UniqueArray<UInt64>()
            var total = object.header.lock.withLock { () -> (UInt64, UInt64) in
                for i in 0..<process.pointee.threads.count {
                    let t = ObjectPointer(address: process.pointee.threads[i])
                    if t.tryRetain() { threads.append(t.address) }
                }
                return (process.pointee.deadCpu, process.pointee.deadQueue)
            }
            for i in 0..<threads.count {
                let t = ObjectPointer(address: threads[i])
                let live = t.header.lock.withLock { () -> (UInt64, UInt64)? in
                    let p = ThreadObjectPointer(object: t).pointee.thread
                    return p == 0 ? nil : Scheduler.runtime(ThreadPointer(address: p))
                }
                if let live { total = (total.0 &+ live.0, total.1 &+ live.1) }  // dead ones are in deadCpu
                t.release()
            }
            return total
        case .job:
            let job = JobPointer(object: object)
            var children = UniqueArray<UInt64>()
            var total = object.header.lock.withLock { () -> (UInt64, UInt64) in
                for i in 0..<job.pointee.children.count {
                    let c = ObjectPointer(address: job.pointee.children[i])
                    if c.tryRetain() { children.append(c.address) }
                }
                return (job.pointee.deadCpu, job.pointee.deadQueue)
            }
            for i in 0..<children.count {
                let child = ObjectPointer(address: children[i])
                if let more = try? runtime(child) { total = (total.0 &+ more.0, total.1 &+ more.1) }
                child.release()
            }
            return total
        default:
            throw .wrongType
        }
    }

    // MARK: VMOs and address spaces

    static func vmoInfo(_ vmo: VmoPointer, via: UInt32, rights: UInt32) -> croi_info_vmo_t {
        var info = croi_info_vmo_t()
        // K14g: an alias has nothing attributed (its pages are its root's,
        // Zircon's rule); a reference's size and pager are its root's.
        let alias = vmo.pointee.isAlias
        let (committed, spaces) = alias ? (0, 0) : vmo.attribution(offset: 0, size: vmo.pointee.size)
        let root = vmo.target.vmo
        let size = vmo.sizeOwner.pointee.size
        vmo.pointee.lock.withLock {
            info.koid = vmo.pointee.koid
            let name = vmo.pointee.name
            withUnsafeMutableBytes(of: &info.name) { bytes in
                for i in 0..<32 { unsafe bytes[i] = name[i] }
            }
            info.size_bytes = size
            info.parent_koid = (vmo.pointee.owner ?? vmo.pointee.parent).map { $0.pointee.koid } ?? 0
            info.num_children = UInt64(vmo.pointee.children)
            info.num_mappings = UInt64(vmo.pointee.mappers.count)
            var flags = via
            switch vmo.pointee.kind {
            case .anonymous:
                flags |= UInt32(CROI_INFO_VMO_TYPE_PAGED)
                if vmo.pointee.resizable { flags |= UInt32(CROI_INFO_VMO_RESIZABLE) }
                if root.pointee.pager != nil { flags |= UInt32(CROI_INFO_VMO_PAGER_BACKED) }
                if vmo.pointee.discardable { flags |= UInt32(CROI_INFO_VMO_DISCARDABLE) }
                if vmo.pointee.clone { flags |= UInt32(CROI_INFO_VMO_IS_COW_CLONE) }
            case .contiguous:
                flags |= UInt32(CROI_INFO_VMO_TYPE_PAGED) | UInt32(CROI_INFO_VMO_CONTIGUOUS)
            case .physical:
                break
            }
            info.flags = flags
            info.committed_change_events = vmo.pointee.reclamationEvents  // K14a
            info.handle_rights = rights
            switch vmo.pointee.cache {
            case .cached: info.cache_policy = UInt32(CROI_CACHE_POLICY_CACHED)
            case .uncached: info.cache_policy = UInt32(CROI_CACHE_POLICY_UNCACHED)
            case .device: info.cache_policy = UInt32(CROI_CACHE_POLICY_UNCACHED_DEVICE)
            case .writeCombining: info.cache_policy = UInt32(CROI_CACHE_POLICY_WRITE_COMBINING)
            }
        }
        info.share_count = spaces
        info.committed_bytes = committed
        info.populated_bytes = committed
        if spaces <= 1 {
            info.committed_private_bytes = committed
            info.populated_private_bytes = committed
        }
        info.committed_scaled_bytes = committed / max(spaces, 1)
        info.populated_scaled_bytes = info.committed_scaled_bytes
        return info
    }

    /// PROCESS_VMOS: its VMO handles, then every mapping (BAD_STATE unless
    /// it is running, Zircon's).
    private static func processVmos(_ object: ObjectPointer) throws(Status) -> UniqueArray<croi_info_vmo_t> {
        let process = ProcessPointer(object: object)
        var handles = UniqueArray<HandleTable.Entry>()
        try object.header.lock.withLock { () throws(Status) in
            guard process.pointee.state == .running else { throw .badState }
            if let address = process.pointee.handles?.address { HandleTable.snapshot(address: address, into: &handles) }
        }
        var infos = UniqueArray<croi_info_vmo_t>()
        for i in 0..<handles.count {
            let entry = ObjectPointer(address: handles[i].object)
            if entry.header.type == ObjectType.vmo {
                infos.append(vmoInfo(VmoPointer(address: UnsafeVmoObject(entry).vmo),
                                     via: UInt32(CROI_INFO_VMO_VIA_HANDLE), rights: handles[i].rights.rawValue))
            }
            entry.release()
        }
        handles.removeAll()
        let record = process.pointee.aspaceRecord
        var vmos = UniqueArray<UInt64>()
        record.pointee.lock.withLock {
            guard !record.pointee.dead else { return }
            for i in 0..<record.pointee.mappings.count {
                let vmo = record.pointee.mappings[i].holder  // K14g: the VMO mapped, an alias too
                vmo.retain()
                vmos.append(vmo.address)
            }
        }
        for i in 0..<vmos.count {
            let vmo = VmoPointer(address: vmos[i])
            infos.append(vmoInfo(vmo, via: UInt32(CROI_INFO_VMO_VIA_MAPPING), rights: 0))
            vmo.release()
        }
        return infos
    }

    /// PROCESS_MAPS: the address space (depth 0), then its regions and
    /// mappings depth first in address order. The V1/V2 mapping layouts
    /// (32 and 40 bytes) differ from today's after vmo_offset.
    private static func processMaps(_ object: ObjectPointer, v1: Bool, v2: Bool) throws(Status) -> UniqueArray<croi_info_maps_t> {
        let record = ProcessPointer(object: object).pointee.aspaceRecord
        let koid = object.header.koid
        var out = UniqueArray<croi_info_maps_t>()
        try record.pointee.lock.withLock { () throws(Status) in
            guard !record.pointee.dead else { throw .badState }
            var aspace = croi_info_maps_t()
            setName(&aspace, "proc:", number: koid)
            aspace.base = UserLayout.base
            aspace.size = UserLayout.top - UserLayout.base
            aspace.type = UInt32(CROI_INFO_MAPS_TYPE_ASPACE)
            out.append(aspace)
            emit(region: UserAspace.root, base: UserLayout.base, size: UserLayout.top - UserLayout.base, depth: 1,
                 record, &out, v1: v1, v2: v2)
        }
        return out
    }

    /// A region and, under it, its sub-regions and mappings by address.
    /// Aspace lock held.
    private static func emit(region id: UInt32, base: UInt64, size: UInt64, depth: UInt64, _ record: UserAspacePointer,
                             _ out: inout UniqueArray<croi_info_maps_t>, v1: Bool, v2: Bool) {
        var vmar = croi_info_maps_t()
        setName(&vmar, id == UserAspace.root ? "root" : "useralloc", number: nil)
        vmar.base = base
        vmar.size = size
        vmar.depth = depth
        vmar.type = UInt32(CROI_INFO_MAPS_TYPE_VMAR)
        out.append(vmar)
        var r = 0, m = 0
        let regions = record.pointee.regions.count, mappings = record.pointee.mappings.count
        while true {
            while r < regions, record.pointee.regions[r].parent != id || record.pointee.regions[r].id == id { r += 1 }
            while m < mappings, record.pointee.mappings[m].region != id { m += 1 }
            let haveRegion = r < regions, haveMapping = m < mappings
            guard haveRegion || haveMapping else { return }
            if haveRegion, !haveMapping || record.pointee.regions[r].base < record.pointee.mappings[m].base {
                let child = record.pointee.regions[r]
                emit(region: child.id, base: child.base, size: child.size, depth: depth + 1, record, &out, v1: v1, v2: v2)
                r += 1
            } else {
                out.append(mappingEntry(record.pointee.mappings[m], depth: depth + 1, v1: v1, v2: v2))
                m += 1
            }
        }
    }

    private static func mappingEntry(_ mapping: Mapping, depth: UInt64, v1: Bool, v2: Bool) -> croi_info_maps_t {
        var entry = croi_info_maps_t()
        let name = mapping.holder.pointee.lock.withLock { mapping.holder.pointee.name }
        withUnsafeMutableBytes(of: &entry.name) { bytes in
            for i in 0..<32 { unsafe bytes[i] = name[i] }
        }
        entry.base = mapping.base
        entry.size = mapping.size
        entry.depth = depth
        entry.type = UInt32(CROI_INFO_MAPS_TYPE_MAPPING)
        var flags: UInt32 = 0
        if mapping.rights.contains(.read) { flags |= UInt32(CROI_VM_PERM_READ) }
        if mapping.rights.contains(.write) { flags |= UInt32(CROI_VM_PERM_WRITE) }
        if mapping.rights.contains(.execute) { flags |= UInt32(CROI_VM_PERM_EXECUTE) }
        if mapping.rights.contains(.guarded) { flags |= UInt32(CROI_VM_PERM_GUARDED) }
        // An alias (K14g) has nothing attributed: its pages are its root's.
        let (committed, spaces) = mapping.holder == mapping.vmo
            ? mapping.vmo.attribution(offset: mapping.offset, size: mapping.size) : (0, 1)
        var m = croi_info_maps_mapping_t()
        m.mmu_flags = flags
        m.vmo_koid = mapping.holder.pointee.koid
        m.vmo_offset = mapping.holderOffset
        if v1 {
            m.committed_bytes = committed / KernelLayout.pageSize  // V1: committed_pages
        } else if v2 {
            m.committed_bytes = committed / KernelLayout.pageSize  // V2: committed_pages, populated_pages
            m.populated_bytes = committed / KernelLayout.pageSize
        } else {
            m.committed_bytes = committed
            m.populated_bytes = committed
            if spaces <= 1 {
                m.committed_private_bytes = committed
                m.populated_private_bytes = committed
            }
            m.committed_scaled_bytes = committed / max(spaces, 1)
            m.populated_scaled_bytes = m.committed_scaled_bytes
        }
        unsafe entry.u.mapping = m  // a C union
        return entry
    }

    private static func setName(_ entry: inout croi_info_maps_t, _ text: StaticString, number: UInt64?) {
        withUnsafeMutableBytes(of: &entry.name) { bytes in
            var at = 0
            for i in 0..<text.utf8CodeUnitCount where at < 31 {
                unsafe bytes[at] = text.utf8Start[i]
                at += 1
            }
            if let number {
                var digits = InlineArray<20, UInt8>(repeating: 0)
                var n = number, count = 0
                repeat {
                    digits[count] = UInt8(48 + n % 10)
                    n /= 10
                    count += 1
                } while n > 0
                while count > 0, at < 31 {
                    count -= 1
                    unsafe bytes[at] = digits[count]
                    at += 1
                }
            }
        }
    }
}
