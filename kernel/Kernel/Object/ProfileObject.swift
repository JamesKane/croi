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
    static var defaultRights: Rights { [.transfer, .duplicate, .inspect, .applyProfile] }
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
        case 121:
            guard a[2] == 0 else { throw .invalidArgs }
            if a[3] != 0 { try Syscalls.check(a[3], MemoryLayout<UInt32>.size) }
            let profile = try table.get(UInt32(truncatingIfNeeded: a[1]), type: .profile, rights: .applyProfile)
            let thread = try table.get(UInt32(truncatingIfNeeded: a[0]), type: .thread, rights: .manageThread)
            var refusal: UInt32 = UInt32(CROI_ADMISSION_ACCEPTED)
            defer { if a[3] != 0 { try? Syscalls.put(refusal, a[3]) } }
            try apply(ProfileObjectPointer(object: profile.object), to: thread.object, refusal: &refusal)
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

    /// Applies `profile` to the thread object `thread` (running).
    static func apply(_ profile: ProfileObjectPointer, to thread: ObjectPointer, refusal: inout UInt32) throws(Status) {
        let address = thread.header.lock.withLock { ThreadObjectPointer(object: thread).pointee.thread }
        guard address != 0 else { throw .badState }  // not started, or gone
        let scheduled = ThreadPointer(address: address)
        let flags = profile.pointee.flags
        let mask: UInt64? = profile.pointee.cpuMask != 0 ? profile.pointee.cpuMask : nil
        if flags & UInt32(CROI_PROFILE_INFO_FLAG_DEADLINE) != 0 {
            let context: SchedContext
            do throws(AdmissionRefusal) {
                context = try SchedContext(deadline: profile.pointee.params, affinity: mask ?? .max)
            } catch {
                switch error {
                case .invalidParameters: throw .invalidArgs
                case .noEligibleCpu: refusal = UInt32(CROI_ADMISSION_NO_ELIGIBLE_CPU)
                case .cpuOverloaded(let cpu): refusal = UInt32(cpu) << 8 | UInt32(CROI_ADMISSION_CPU_OVERLOADED)
                case .accountExhausted: refusal = UInt32(CROI_ADMISSION_ACCOUNT_EXHAUSTED)
                }
                throw .noResources
            }
            Scheduler.applyProfile(scheduled, weight: nil, context: context, affinity: mask)
        } else if flags & UInt32(CROI_PROFILE_INFO_FLAG_PRIORITY) != 0 {
            Scheduler.applyProfile(scheduled, weight: Profile.weight(priority: profile.pointee.priority), context: nil,
                                   affinity: mask)
        } else {
            Scheduler.applyProfile(scheduled, weight: nil, context: nil, affinity: mask)
        }
    }
}
