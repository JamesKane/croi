import CKernel

/// Profile objects (K8c; Zircon's ProfileDispatcher, type 25): how user
/// space asks for scheduling. A profile is a priority (a fair weight) or
/// deadline parameters, and optionally a CPU mask; `object_set_profile`
/// applies it to a thread. A deadline profile is admitted per thread when
/// applied (ext 4: refused with a reason, which Zircon doesn't have), and
/// the admitted context belongs to that thread.
///
/// Not yet: per-job real-time accounts (admission uses none), applying to
/// a thread before it starts (BAD_STATE), NO_INHERIT, memory priority.
struct ProfileObject: ~Copyable {
    var header = ObjectHeader(type: .profile)
    let flags: UInt32
    let priority: Int
    let params: DeadlineParams
    /// 0: no mask.
    let cpuMask: UInt64

    /// Zircon's ZX_DEFAULT_PROFILE_RIGHTS: basic less WAIT, plus APPLY_PROFILE.
    static var defaultRights: Rights { .transfer | .duplicate | .inspect | .applyProfile }
}

@safe struct ProfileObjectPointer {
    let object: ObjectPointer

    var pointee: ProfileObject {
        unsafeAddress { unsafe UnsafePointer<ProfileObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<ProfileObject>(bitPattern: UInt(object.address))! }
    }
}

enum Profiles {
    /// profile_create(resource, options, info, out) and
    /// object_set_profile(thread, profile, options, uint32_t *refusal).
    static func call(_ number: UInt64, _ a: InlineArray<6, UInt64>, _ table: borrowing HandleTable) throws(Status) {
        switch number {
        case 120:
            try Resources.check(table, UInt32(truncatingIfNeeded: a[0]), system: UInt64(CROI_RSRC_SYSTEM_PROFILE_BASE))
            guard a[1] == 0 else { throw .invalidArgs }
            var info = croi_profile_info_t()
            let copied = withUnsafeMutableBytes(of: &info) { raw in
                unsafe UserCopy.from(raw.baseAddress!, a[2], UInt64(raw.count))
            }
            guard copied == 0 else { throw .invalidArgs }
            try Syscalls.check(a[3], MemoryLayout<UInt32>.size)
            let object = try create(info)
            try Syscalls.put(try table.add(object, rights: ProfileObject.defaultRights), a[3])
        case 121:  // object_set_profile(target, profile, options, refusal, timeline)
            guard a[2] & ~UInt64(CROI_PROFILE_ALIGN_TIMELINE | CROI_PROFILE_HANDOFF) == 0 else { throw .invalidArgs }
            if a[3] != 0 { try Syscalls.check(a[3], MemoryLayout<UInt32>.size) }
            let profile = try table.get(UInt32(truncatingIfNeeded: a[1]), type: .profile, rights: .applyProfile)
            let target = UInt32(truncatingIfNeeded: a[0])
            let type = try table.get(target).type
            if type == .interrupt || type == .counter || type == .timeline {
                // K10c, ext 5: the event lends this deadline to the threads
                // it wakes directly; K14e: an interrupt hands them an
                // admitted context instead.
                let event = try table.get(target, rights: .write)
                if a[2] == UInt64(CROI_PROFILE_HANDOFF), type == .interrupt {
                    var refusal: UInt32 = UInt32(CROI_ADMISSION_ACCEPTED)
                    defer { if a[3] != 0 { try? Syscalls.put(refusal, a[3]) } }
                    let context = try admit(ProfileObjectPointer(object: profile.object), reservation: 0, refusal: &refusal)
                    InterruptObjects.setContext(event.object, context, lend: nil)
                    return
                }
                guard a[2] == 0 else { throw .invalidArgs }
                try lend(ProfileObjectPointer(object: profile.object), from: event.object)
                return
            }
            let thread = try table.get(target, type: .thread, rights: .manageThread)
            var refusal: UInt32 = UInt32(CROI_ADMISSION_ACCEPTED)
            defer { if a[3] != 0 { try? Syscalls.put(refusal, a[3]) } }
            try apply(ProfileObjectPointer(object: profile.object), to: thread.object, refusal: &refusal)
            if a[2] & UInt64(CROI_PROFILE_ALIGN_TIMELINE) != 0 {
                let timeline = try table.get(UInt32(truncatingIfNeeded: a[4]), type: .timeline, rights: .read)
                try align(thread.object, to: timeline.object)
            }
        case 122:  // thread_bind_overrun_port(thread or interrupt, port, key), K10d; interrupts K14e
            if try table.get(UInt32(truncatingIfNeeded: a[0])).type == .interrupt {
                let interrupt = try table.get(UInt32(truncatingIfNeeded: a[0]), rights: .write)
                let port = try table.get(UInt32(truncatingIfNeeded: a[1]), type: .port, rights: .write)
                let source = try PacketSourcePointer.make(port: port, key: a[2], type: PortPacket.budgetOverrun)
                guard let old = InterruptObjects.bindOverrunSource(interrupt.object, source.address) else {
                    source.retire()
                    throw .badState
                }
                if old != 0 { PacketSourcePointer(address: old).retire() }
                return
            }
            let thread = try table.get(UInt32(truncatingIfNeeded: a[0]), type: .thread, rights: .manageThread)
            let port = try table.get(UInt32(truncatingIfNeeded: a[1]), type: .port, rights: .write)
            guard let target = Processes.pinnedThread(thread.object) else { throw .badState }
            defer { Scheduler.unpin(target) }
            let source = try PacketSourcePointer.make(port: port, key: a[2], type: PortPacket.budgetOverrun)
            guard let old = Scheduler.bindOverrunSource(target, source.address) else {
                source.retire()
                throw .badState
            }
            if old != 0 { PacketSourcePointer(address: old).retire() }
        default:
            throw .notSupported
        }
    }

    static func create(_ info: croi_profile_info_t) throws(Status) -> ObjectPointer {
        let known = UInt32(CROI_PROFILE_INFO_FLAG_PRIORITY | CROI_PROFILE_INFO_FLAG_CPU_MASK
                           | CROI_PROFILE_INFO_FLAG_DEADLINE)
        guard info.flags & ~known == 0 else { throw .notSupported }
        let hasPriority = info.flags & UInt32(CROI_PROFILE_INFO_FLAG_PRIORITY) != 0
        let hasDeadline = info.flags & UInt32(CROI_PROFILE_INFO_FLAG_DEADLINE) != 0
        let hasMask = info.flags & UInt32(CROI_PROFILE_INFO_FLAG_CPU_MASK) != 0
        guard info.flags != 0, !(hasPriority && hasDeadline) else { throw .invalidArgs }
        var priority = 0
        if hasPriority {
            guard (0...Thread.maxPriority).contains(Int(info.priority)) else { throw .invalidArgs }
            priority = Int(info.priority)
        }
        var params = DeadlineParams(capacity: 0, deadline: 0, period: 1)
        if hasDeadline {
            let d = info.deadline_params
            guard d.capacity > 0, d.relative_deadline > 0, d.period > 0 else { throw .invalidArgs }
            params = DeadlineParams(capacity: UInt64(d.capacity), deadline: UInt64(d.relative_deadline),
                                    period: UInt64(d.period))
            guard params.isValid else { throw .invalidArgs }
        }
        var mask: UInt64 = 0
        if hasMask {
            // Up to 64 CPUs: the mask's later words name none that exist.
            mask = info.cpu_mask.0
            guard mask != 0 else { throw .invalidArgs }
        }
        guard let object = Objects.allocate(ProfileObject(flags: info.flags, priority: priority, params: params,
                                                          cpuMask: mask)) else { throw .noMemory }
        return object
    }

    /// Ext 5: `event` (an interrupt, counter or timeline) lends `profile`,
    /// which must be a deadline one, to the threads it wakes.
    static func lend(_ profile: ProfileObjectPointer, from event: ObjectPointer) throws(Status) {
        guard profile.pointee.flags & UInt32(CROI_PROFILE_INFO_FLAG_DEADLINE) != 0 else { throw .invalidArgs }
        let lent = Profile.deadline(profile.pointee.params)
        if event.header.type == .interrupt {
            InterruptObjects.setContext(event, nil, lend: lent)  // a handed-off context goes
            return
        }
        event.header.lock.withLock {
            switch event.header.type {
            case .interrupt: InterruptPointer(object: event).pointee.lend = lent
            case .counter: CounterPointer(object: event).pointee.lend = lent
            default: TimelinePointer(object: event).pointee.lend = lent
            }
        }
    }

    /// Ext 10: the thread's deadline periods start on `timeline`'s vblanks.
    /// BAD_STATE if the profile just applied gave it no deadline context.
    static func align(_ thread: ObjectPointer, to timeline: ObjectPointer) throws(Status) {
        guard let target = Processes.pinnedThread(thread) else { throw .badState }
        defer { Scheduler.unpin(target) }
        timeline.retain()  // the context's
        let (aligned, old) = Scheduler.align(target,
                                             page: TimelinePointer(object: timeline).pointee.pageAddress,
                                             timeline: timeline.address)
        if old != 0 { ObjectPointer(address: old).release() }
        guard aligned else {
            timeline.release()
            throw .badState
        }
    }

    /// Admits a deadline profile as a context (its CPU mask, if any):
    /// INVALID_ARGS for a profile that isn't a deadline one or bad
    /// parameters, NO_RESOURCES with `refusal` set when refused (ext 4).
    static func admit(_ profile: ProfileObjectPointer, reservation: UInt32, refusal: inout UInt32) throws(Status) -> SchedContext {
        guard profile.pointee.flags & UInt32(CROI_PROFILE_INFO_FLAG_DEADLINE) != 0 else { throw .invalidArgs }
        let mask: UInt64 = profile.pointee.cpuMask != 0 ? profile.pointee.cpuMask : .max
        do throws(AdmissionRefusal) {
            return try SchedContext(deadline: profile.pointee.params, affinity: mask, reservation: reservation)
        } catch {
            switch error {
            case .invalidParameters: throw .invalidArgs
            case .noEligibleCpu: refusal = UInt32(CROI_ADMISSION_NO_ELIGIBLE_CPU)
            case .cpuOverloaded(let cpu): refusal = UInt32(cpu) << 8 | UInt32(CROI_ADMISSION_CPU_OVERLOADED)
            case .accountExhausted: refusal = UInt32(CROI_ADMISSION_ACCOUNT_EXHAUSTED)
            }
            throw .noResources
        }
    }

    /// Applies `profile` to the thread object `thread` (running).
    static func apply(_ profile: ProfileObjectPointer, to thread: ObjectPointer, refusal: inout UInt32) throws(Status) {
        guard let scheduled = Processes.pinnedThread(thread) else { throw .badState }  // not started, or gone
        defer { Scheduler.unpin(scheduled) }
        let flags = profile.pointee.flags
        let mask: UInt64? = profile.pointee.cpuMask != 0 ? profile.pointee.cpuMask : nil
        if flags & UInt32(CROI_PROFILE_INFO_FLAG_DEADLINE) != 0 {
            let context = try admit(profile, reservation: Scheduler.reservation(of: scheduled), refusal: &refusal)
            Scheduler.applyProfile(scheduled, weight: nil, context: context, affinity: mask)
        } else if flags & UInt32(CROI_PROFILE_INFO_FLAG_PRIORITY) != 0 {
            Scheduler.applyProfile(scheduled, weight: Profile.weight(priority: profile.pointee.priority), context: nil,
                                   affinity: mask)
        } else {
            Scheduler.applyProfile(scheduled, weight: nil, context: nil, affinity: mask)
        }
    }
}
