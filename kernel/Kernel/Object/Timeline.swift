import CKernel
import Synchronization

/// A display timeline (K10b, Todhchai ext 1; croi's object, type 48): a
/// vblank count that display drivers advance at each vblank's hardware
/// timestamp, or, synthesized (no vblank interrupt: the GOP framebuffer),
/// a function of the time the kernel keeps. Waiting is a counter's
/// (Counters.wait / waitAsync on value observers); a page published as a
/// read-only VMO tells clients the vblank times without a syscall.
///
/// A synthetic timeline has no periodic tick: when a value wait is
/// registered, `watchLocked` arms one kernel timer for the earliest vblank
/// any waiter needs, and each firing re-arms for the next, so with nothing
/// waiting the timeline costs nothing (K10f). The armed timer (its own
/// node, so arming never fails) holds a reference; a superseded one is
/// cancelled, and a generation number makes one already firing harmless.
struct TimelineObject: ~Copyable {
    var header = ObjectHeader(type: .timeline)
    let synthetic: Bool
    var period: UInt64
    /// The count at `baseTime`: a driven timeline's last vblank, a
    /// synthetic one's last re-basing (creation, a period change).
    var baseCount: Int64 = 0
    var baseTime: UInt64
    /// The page's VMO (a reference) and its kernel address (physmap).
    let page: VmoPointer
    let pageAddress: UInt64
    var generation: UInt64 = 0
    /// The vblank the armed timer is for (0: none armed), and its CPU.
    var armedFor: UInt64 = 0
    var armedCpu = 0
    var timer = TimerNode()
    /// K10c: a deadline profile lent to the threads its waits wake.
    var lend: Profile? = nil

    /// BASIC | READ | WRITE | SIGNAL (WRITE drives it; clients get READ).
    static var defaultRights: Rights { Rights.basic.union(.read | .write | .signal) }
}

@safe struct TimelinePointer {
    let object: ObjectPointer

    var timer: TimerNodePointer {
        withUnsafeMutablePointer(to: &pointee.timer) { unsafe TimerNodePointer($0) }
    }

    var pointee: TimelineObject {
        unsafeAddress { unsafe UnsafePointer<TimelineObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress {
            unsafe UnsafeMutablePointer<TimelineObject>(bitPattern: UInt(object.address))!
        }
    }
}

enum Timelines {
    /// Below this a period is a mistake (10 kHz).
    static var minimumPeriod: UInt64 { 100_000 }

    static func create(options: UInt32, period: UInt64) throws(Status) -> ObjectPointer {
        guard options & ~UInt32(CROI_TIMELINE_SYNTHETIC) == 0, period >= minimumPeriod else { throw .invalidArgs }
        let vmo: Vmo
        do throws(VmError) {
            vmo = try Vmo(contiguous: KernelLayout.pageSize)
        } catch {
            throw .noMemory
        }
        vmo.record.pointee.sharedReadOnly = true  // user mappings: read only
        guard let phys = vmo.record.lookup(at: 0) else { panic("timeline: page not committed") }
        let page = vmo.keep()
        guard let object = Objects.allocate(TimelineObject(
            synthetic: options & UInt32(CROI_TIMELINE_SYNTHETIC) != 0, period: period, baseTime: Clock.now(),
            page: page, pageAddress: KernelLayout.physmap(phys))) else {
            page.release()
            throw .noMemory
        }
        object.header.lock.withLock { writePage(TimelinePointer(object: object)) }
        return object
    }

    static func destroy(_ object: ObjectPointer) {
        TimelinePointer(object: object).pointee.page.release()
        Objects.free(object, as: TimelineObject.self)
    }

    /// The vblank count now (object lock held).
    static func valueLocked(_ object: ObjectPointer) -> Int64 {
        let t = TimelinePointer(object: object)
        guard t.pointee.synthetic else { return t.pointee.baseCount }
        let now = Clock.now()
        guard now > t.pointee.baseTime else { return t.pointee.baseCount }
        return t.pointee.baseCount + Int64((now - t.pointee.baseTime) / t.pointee.period)
    }

    /// When vblank `count` happens (synthetic), or is predicted to.
    private static func time(of count: Int64, _ t: TimelinePointer) -> UInt64 {
        let ahead = count - t.pointee.baseCount
        return ahead <= 0 ? t.pointee.baseTime : t.pointee.baseTime + UInt64(ahead) * t.pointee.period
    }

    /// timeline_advance: a driven timeline's vblank at `timestamp`.
    static func advance(_ object: ObjectPointer, timestamp: UInt64) throws(Status) {
        let t = TimelinePointer(object: object)
        try object.header.lock.withLock { () throws(Status) in
            guard !t.pointee.synthetic else { throw .badState }
            t.pointee.baseCount += 1
            t.pointee.baseTime = timestamp
            writePage(t)
            Observers.notify(object)
        }
    }

    /// timeline_set_period: a new rate from now on; the count carries on.
    static func setPeriod(_ object: ObjectPointer, _ period: UInt64) throws(Status) {
        guard period >= minimumPeriod else { throw .invalidArgs }
        let t = TimelinePointer(object: object)
        object.header.lock.withLock {
            if t.pointee.synthetic {
                let now = valueLocked(object)
                t.pointee.baseTime = time(of: now, t)  // the current vblank
                t.pointee.baseCount = now
            }
            t.pointee.period = period
            writePage(t)
            if t.pointee.synthetic {
                disarmLocked(t)  // re-armed on the new grid
                watchLocked(object)
            }
        }
    }

    /// timeline_get_page: a read-only handle to the page's VMO.
    static func pageVmo(_ object: ObjectPointer) throws(Status) -> ObjectPointer {
        try VmoObject.wrap(TimelinePointer(object: object).pointee.page)
    }

    static var pageRights: Rights { .basic | .read | .map | .getProperty }

    /// A value wait was registered: a synthetic timeline makes sure a timer
    /// is armed for the earliest vblank any waiter needs. Object lock held.
    static func watchLocked(_ object: ObjectPointer) {
        let t = TimelinePointer(object: object)
        guard t.pointee.synthetic else { return }
        let now = valueLocked(object)
        var earliest = Int64.max
        var due = false
        var cursor = object.header.observers
        while let observer = cursor {
            if observer.pointee.byValue {
                if observer.pointee.atValue > now {
                    earliest = min(earliest, observer.pointee.atValue)
                } else {
                    due = true
                }
            }
            cursor = observer.pointee.next
        }
        // The value is the clock's: a vblank can pass between a waiter's
        // check and this, leaving it waiting for a value already reached
        // with no tick armed (m2 hung so on a slow rv64 under load).
        if due { Observers.notify(object) }
        guard earliest != .max else { return }
        let deadline = time(of: earliest, t)
        guard t.pointee.armedFor == 0 || deadline < t.pointee.armedFor else { return }
        disarmLocked(t)  // an earlier one supersedes the armed one
        object.retain()  // the timer's
        Timers.arm(t.timer, deadline: deadline, slack: 0, fired, object.address, context: t.pointee.generation)
        t.pointee.armedFor = deadline
        t.pointee.armedCpu = Int(Cpu.current)
    }

    /// Cancels the armed timer, if any (object lock held). One already
    /// firing finds a new generation and drops its own reference.
    private static func disarmLocked(_ t: TimelinePointer) {
        t.pointee.generation += 1
        guard t.pointee.armedFor != 0 else { return }
        t.pointee.armedFor = 0
        if Timers.cancel(t.timer, on: t.pointee.armedCpu) { t.object.release() }  // not the last: the caller has one
    }

    /// A synthetic vblank someone waits for: wake who it satisfies, arm the
    /// next one anyone waits for.
    private static let fired: Timers.Callback = { address, generation in
        let object = ObjectPointer(address: address)
        let t = TimelinePointer(object: object)
        object.header.lock.withLock {
            guard t.pointee.generation == generation else { return }  // superseded
            t.pointee.armedFor = 0
            Observers.notify(object)
            watchLocked(object)
        }
        object.release()
    }

    /// Seqlocked page update (object lock held).
    private static func writePage(_ t: TimelinePointer) {
        let page = unsafe UnsafeMutablePointer<croi_timeline_page_t>(bitPattern: UInt(t.pointee.pageAddress))!
        unsafe page.pointee.sequence &+= 1
        atomicMemoryFence(ordering: .sequentiallyConsistent)
        unsafe page.pointee.version = UInt32(CROI_TIMELINE_PAGE_VERSION)
        unsafe page.pointee.flags = t.pointee.synthetic ? UInt32(CROI_TIMELINE_PAGE_SYNTHESIZED) : 0
        unsafe page.pointee.period_ns = t.pointee.period
        unsafe page.pointee.base_count = t.pointee.baseCount
        unsafe page.pointee.base_time_ns = t.pointee.baseTime
        atomicMemoryFence(ordering: .sequentiallyConsistent)
        unsafe page.pointee.sequence &+= 1
    }
}
