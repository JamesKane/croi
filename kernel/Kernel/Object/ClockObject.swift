import CKernel
import Synchronization

/// Clock objects (K13f; Zircon's ClockDispatcher, type 30): an affine
/// function of the reference timeline (monotonic ns: croi's reference
/// "ticks" are nanoseconds, clock.h), started and steered by clock_update
/// (value, rate in ppm, error bound) under Zircon's rules: MONOTONIC never
/// goes back, CONTINUOUS never jumps once started, nothing goes below the
/// backstop; before its first update it reads its backstop. Kept in the
/// object as croi_clock_page_t (Zircon's mapped layout) under the object
/// lock; a MAPPABLE clock also publishes it to a one-page read-only VMO
/// under the page's seqlock (`seq_lock`; generation = seq / 2).
/// ZX_CLOCK_UPDATED is pulsed at every update, STARTED set at the first.
struct ClockObject: ~Copyable {
    var header = ObjectHeader(type: .clock)
    var name = ObjectName(repeating: 0)
    var state: croi_clock_page_t
    /// MAPPABLE: the page's VMO (a reference) and its physmap address.
    let page: VmoPointer?
    let pageAddress: UInt64

    /// ZX_DEFAULT_CLOCK_RIGHTS (MAP added for a MAPPABLE clock).
    static var defaultRights: Rights { .basic | .read | .write | .getProperty | .setProperty | .signal }
}

@safe struct ClockPointer {
    let object: ObjectPointer

    var pointee: ClockObject {
        unsafeAddress { unsafe UnsafePointer<ClockObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<ClockObject>(bitPattern: UInt(object.address))! }
    }

    var started: Bool { pointee.state.reference_to_synthetic.rate.synthetic_ticks != 0 }
}

enum Clocks {
    static var versionShift: UInt64 { UInt64(CROI_CLOCK_ARGS_VERSION_SHIFT) }
    static var optionsMask: UInt64 { (1 << versionShift) - 1 }
    static var started: UInt32 { UInt32(CROI_CLOCK_STARTED) }
    static var updated: UInt32 { UInt32(CROI_CLOCK_UPDATED) }

    /// clock_create (the args read): Zircon's checks after the version's.
    static func create(options: UInt64, backstop: Int64) throws(Status) -> (ObjectPointer, Rights) {
        guard options & ~UInt64(CROI_CLOCK_OPTS_ALL) == 0 else { throw .invalidArgs }
        let monotonic = options & UInt64(CROI_CLOCK_OPT_MONOTONIC) != 0
        guard monotonic || options & UInt64(CROI_CLOCK_OPT_CONTINUOUS) == 0 else { throw .invalidArgs }
        let autoStart = options & UInt64(CROI_CLOCK_OPT_AUTO_START) != 0
        let now = Int64(bitPattern: Clock.now())
        guard backstop >= 0, !autoStart || backstop <= now else { throw .invalidArgs }
        var page: VmoPointer? = nil
        var pageAddress: UInt64 = 0
        if options & UInt64(CROI_CLOCK_OPT_MAPPABLE) != 0 {
            let vmo: Vmo
            do throws(VmError) {
                vmo = try Vmo(contiguous: KernelLayout.pageSize)
            } catch {
                throw .noMemory
            }
            vmo.record.pointee.sharedReadOnly = true  // user mappings: read only
            guard let phys = vmo.record.lookup(at: 0) else { panic("clock: page not committed") }
            pageAddress = KernelLayout.physmap(phys)
            page = vmo.keep()
        }
        var state = croi_clock_page_t()
        state.options = options
        state.backstop_time = backstop
        state.error_bound = CROI_CLOCK_UNKNOWN_ERROR
        if autoStart {
            let identity = croi_clock_transformation_t(reference_offset: 0, synthetic_offset: 0,
                                                       rate: croi_clock_rate_t(synthetic_ticks: 1, reference_ticks: 1))
            state.reference_ticks_to_synthetic = identity
            state.reference_to_synthetic = identity
            state.last_value_update_ticks = now
            state.last_rate_adjust_update_ticks = now
        } else {
            let still = croi_clock_transformation_t(reference_offset: 0, synthetic_offset: backstop,
                                                    rate: croi_clock_rate_t(synthetic_ticks: 0, reference_ticks: 1))
            state.reference_ticks_to_synthetic = still
            state.reference_to_synthetic = still
        }
        guard let object = Objects.allocate(ClockObject(state: state, page: page, pageAddress: pageAddress)) else {
            page?.release()
            throw .noMemory
        }
        object.header.lock.withLock { publishLocked(ClockPointer(object: object)) }
        if autoStart { object.header.signals = started }
        var rights = ClockObject.defaultRights
        if page != nil { rights.insert(.map) }
        return (object, rights)
    }

    static func destroy(_ object: ObjectPointer) {
        ClockPointer(object: object).pointee.page?.release()
        Objects.free(object, as: ClockObject.self)
    }

    // MARK: Reading

    /// b_off + floor((r - a_off) * num / den), saturating (Zircon's affine
    /// apply_saturating).
    static func apply(_ t: croi_clock_transformation_t, _ reference: Int64) -> Int64 {
        let num = UInt64(t.rate.synthetic_ticks), den = UInt64(t.rate.reference_ticks)
        guard den != 0, num != 0 else { return t.synthetic_offset }
        let negative = reference < t.reference_offset
        let magnitude = negative ? UInt64(bitPattern: t.reference_offset &- reference)
                                 : UInt64(bitPattern: reference &- t.reference_offset)
        let product = magnitude.multipliedFullWidth(by: num)
        let saturated = negative ? Int64.min : Int64.max
        guard product.high < den else { return saturated }
        let (quotient, remainder) = den.dividingFullWidth(product)
        if negative {
            let q = quotient &+ (remainder != 0 ? 1 : 0)  // floor
            guard q <= UInt64(Int64.max) + 1 else { return Int64.min }
            let (value, overflow) = t.synthetic_offset.subtractingReportingOverflow(Int64(bitPattern: q))
            return overflow ? Int64.min : value
        }
        guard quotient <= UInt64(Int64.max) else { return Int64.max }
        let (value, overflow) = t.synthetic_offset.addingReportingOverflow(Int64(quotient))
        return overflow ? Int64.max : value
    }

    static func read(_ object: ObjectPointer) -> Int64 {
        let clock = ClockPointer(object: object)
        return object.header.lock.withLock {
            apply(clock.pointee.state.reference_ticks_to_synthetic, Int64(bitPattern: Clock.now()))
        }
    }

    static func details(_ object: ObjectPointer) -> croi_clock_details_v1_t {
        let clock = ClockPointer(object: object)
        return object.header.lock.withLock { () -> croi_clock_details_v1_t in
            let s = clock.pointee.state
            var d = croi_clock_details_v1_t()
            d.options = s.options
            d.backstop_time = s.backstop_time
            d.reference_ticks_to_synthetic = s.reference_ticks_to_synthetic
            d.reference_to_synthetic = s.reference_to_synthetic
            d.error_bound = s.error_bound
            d.query_ticks = Int64(bitPattern: Clock.now())
            d.last_value_update_ticks = s.last_value_update_ticks
            d.last_rate_adjust_update_ticks = s.last_rate_adjust_update_ticks
            d.last_error_bounds_update_ticks = s.last_error_bounds_update_ticks
            d.generation_counter = s.seq_lock >> 1
            return d
        }
    }

    // MARK: Updating

    struct Update {
        var flags: UInt64
        var version: UInt64
        var rate: Int32
        var value: Int64
        var reference: Int64
        var errorBound: UInt64
    }

    /// clock_update after the argument checks and the handle's.
    static func update(_ object: ObjectPointer, _ u: Update) throws(Status) {
        let setValue = u.flags & UInt64(CROI_CLOCK_UPDATE_OPTION_VALUE_VALID) != 0
        let setRate = u.flags & UInt64(CROI_CLOCK_UPDATE_OPTION_RATE_ADJUST_VALID) != 0
        let setBound = u.flags & UInt64(CROI_CLOCK_UPDATE_OPTION_ERROR_BOUND_VALID) != 0
        let hasReference = u.flags & UInt64(CROI_CLOCK_UPDATE_OPTION_REFERENCE_VALUE_VALID) != 0
        if u.version == 1, hasReference { throw .invalidArgs }
        if u.version == 2, hasReference, !setValue, !setRate { throw .invalidArgs }
        let clock = ClockPointer(object: object)
        let options = clock.pointee.state.options
        let monotonic = options & UInt64(CROI_CLOCK_OPT_MONOTONIC) != 0
        let continuous = options & UInt64(CROI_CLOCK_OPT_CONTINUOUS) != 0
        let firstStart = try object.header.lock.withLock { () throws(Status) -> Bool in
            let wasStarted = clock.started
            guard wasStarted || setValue else { throw .badState }
            if setValue, continuous, wasStarted { throw .invalidArgs }
            if u.version == 2, wasStarted, monotonic {
                if setValue, !hasReference { throw .invalidArgs }
                if setValue || hasReference, setRate { throw .invalidArgs }
            }
            let now = Int64(bitPattern: Clock.now())
            var s = clock.pointee.state
            let skip = !setValue && (!setRate || (!hasReference && u.rate == s.cur_ppm_adj))
            if !skip {
                let referenceTime = hasReference ? u.reference : now
                let target = setValue ? u.value : apply(s.reference_to_synthetic, referenceTime)
                var rate = croi_clock_rate_t(synthetic_ticks: 1, reference_ticks: 1)
                if setRate {
                    rate = croi_clock_rate_t(synthetic_ticks: UInt32(Int64(1_000_000) + Int64(u.rate)), reference_ticks: 1_000_000)
                } else if wasStarted {
                    rate = s.reference_to_synthetic.rate
                }
                let next = croi_clock_transformation_t(reference_offset: referenceTime, synthetic_offset: target, rate: rate)
                let before = apply(s.reference_to_synthetic, now), after = apply(next, now)
                if monotonic, after < before { throw .invalidArgs }
                if after < s.backstop_time { throw .invalidArgs }
                s.reference_to_synthetic = next
                s.reference_ticks_to_synthetic = next  // croi: ticks are ns
            }
            if setValue { s.last_value_update_ticks = now }
            if setRate || !wasStarted {
                s.last_rate_adjust_update_ticks = now
                s.cur_ppm_adj = setRate ? u.rate : 0
            }
            if setBound {
                s.error_bound = u.errorBound
                s.last_error_bounds_update_ticks = now
            }
            s.seq_lock = clock.pointee.state.seq_lock
            clock.pointee.state = s
            publishLocked(clock)
            return !wasStarted
        }
        object.updateSignals(clear: 0, set: firstStart ? started | updated : updated)
        object.updateSignals(clear: updated, set: 0)  // a pulse (Zircon's strobe)
    }

    /// The generation moves on (seq += 2) and a mapped page gets the new
    /// state: seq odd, the fields, seq even. Object lock held.
    private static func publishLocked(_ clock: ClockPointer) {
        let seq = clock.pointee.state.seq_lock
        clock.pointee.state.seq_lock = seq &+ 2
        guard clock.pointee.pageAddress != 0 else { return }
        let page = unsafe UnsafeMutablePointer<croi_clock_page_t>(bitPattern: UInt(clock.pointee.pageAddress))!
        unsafe page.pointee.seq_lock = seq &+ 1  // odd: a write in progress
        atomicMemoryFence(ordering: .sequentiallyConsistent)
        var copy = clock.pointee.state
        copy.seq_lock = seq &+ 1
        unsafe page.pointee = copy
        atomicMemoryFence(ordering: .sequentiallyConsistent)
        unsafe page.pointee.seq_lock = seq &+ 2
    }
}
