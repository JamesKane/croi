import CKernel

/// Clock objects (K13f): syscalls 216-219, Zircon's checks in Zircon's
/// order (the pinned tree's clock.rs). vmar_map_clock is 77 (TaskSyscalls).
extension Syscalls {
    static func clockCall(_ number: UInt64, _ a: InlineArray<6, UInt64>, _ table: borrowing HandleTable) throws(Status) {
        let handle = UInt32(truncatingIfNeeded: a[0])
        let version = a[1] >> Clocks.versionShift
        switch number {
        case 216:  // clock_create(options, args, out)
            let createVersion = a[0] >> Clocks.versionShift
            var backstop: Int64 = 0
            switch createVersion {
            case 0:
                guard a[1] == 0 else { throw .invalidArgs }
            case 1:
                var args = croi_clock_create_args_v1_t()
                let failed = withUnsafeMutableBytes(of: &args) { unsafe UserCopy.from($0.baseAddress!, a[1], 8) }
                guard failed == 0 else { throw .invalidArgs }
                backstop = args.backstop_time
            default:
                throw .invalidArgs
            }
            try check(a[2], 4)
            let (clock, rights) = try Clocks.create(options: a[0] & Clocks.optionsMask, backstop: backstop)
            let out: UInt32
            do throws(Status) {
                out = try table.add(clock, rights: rights)
            } catch {
                clock.release()
                throw error
            }
            try put(out, a[2])
        case 217:  // clock_read(clock, int64_t *now)
            let clock = try table.get(handle, type: .clock, rights: .read)
            try check(a[1], 8)
            try put(Clocks.read(clock.object), a[1])
        case 218:  // clock_get_details(clock, options = ARGS_VERSION(1), croi_clock_details_v1_t *)
            guard a[1] == 1 << Clocks.versionShift, a[2] != 0 else { throw .invalidArgs }
            let clock = try table.get(handle, type: .clock, rights: .read)
            try check(a[2], MemoryLayout<croi_clock_details_v1_t>.size)
            try put(Clocks.details(clock.object), a[2])
        case 219:  // clock_update(clock, options, args)
            guard a[2] != 0 else { throw .invalidArgs }
            var update = Clocks.Update(flags: a[1] & Clocks.optionsMask, version: version, rate: 0, value: 0, reference: 0,
                                       errorBound: 0)
            switch version {
            case 1:
                var args = croi_clock_update_args_v1_t()
                let failed = withUnsafeMutableBytes(of: &args) { unsafe UserCopy.from($0.baseAddress!, a[2], UInt64($0.count)) }
                guard failed == 0 else { throw .invalidArgs }
                (update.rate, update.value, update.errorBound) = (args.rate_adjust, args.value, args.error_bound)
            case 2:
                var args = croi_clock_update_args_v2_t()
                let failed = withUnsafeMutableBytes(of: &args) { unsafe UserCopy.from($0.baseAddress!, a[2], UInt64($0.count)) }
                guard failed == 0 else { throw .invalidArgs }
                (update.rate, update.value, update.reference, update.errorBound) =
                    (args.rate_adjust, args.synthetic_value, args.reference_value, args.error_bound)
            default:
                throw .invalidArgs
            }
            guard update.flags != 0, update.flags & ~UInt64(0xF) == 0 else { throw .invalidArgs }
            if update.flags & UInt64(CROI_CLOCK_UPDATE_OPTION_RATE_ADJUST_VALID) != 0 {
                guard update.rate >= CROI_CLOCK_UPDATE_MIN_RATE_ADJUST, update.rate <= CROI_CLOCK_UPDATE_MAX_RATE_ADJUST else {
                    throw .invalidArgs
                }
            }
            let clock = try table.get(handle, type: .clock, rights: .write)
            try Clocks.update(clock.object, update)
        default:
            throw .notSupported
        }
    }
}
