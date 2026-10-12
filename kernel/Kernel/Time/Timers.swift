import CKernel
import Synchronization

/// A timer: fire `callback(argument, context)` somewhere in [deadline,
/// latest] (monotonic ns; latest = deadline + slack). The fields are the
/// queue's while it is armed.
///
/// Kernel code that keeps a fixed number of timers takes one of its CPU's
/// slots (`Timers.arm(deadline:...)`, an id back). Anything whose count
/// user space decides (thread timeouts, timer objects, timelines) owns its
/// node, embedded in its record as Zircon's Timer is, and arms that
/// (`Timers.arm(_:deadline:...)`), which never fails. An owned node must
/// stay put, and alive, while armed.
struct TimerNode {
    var deadline: UInt64 = 0
    var latest: UInt64 = 0
    var callback: Timers.Callback?
    var argument: UInt64 = 0
    var context: UInt64 = 0
    /// A slot's id while armed (0 for a free slot and for owned nodes).
    fileprivate(set) var id: UInt32 = 0
    /// The CPU whose queue holds it, or -1. Written under that queue's lock.
    fileprivate(set) var cpu: Int32 = -1
    /// Links in the queue (node addresses, 0 for none).
    fileprivate var next: UInt64 = 0
    fileprivate var previous: UInt64 = 0
}

@safe struct TimerNodePointer: Equatable {
    let address: UInt64

    /// `node` stays where it is while armed (a field of a heap record,
    /// reached through its addressor).
    @unsafe init(_ node: UnsafeMutablePointer<TimerNode>) {
        address = UInt64(UInt(bitPattern: node))
    }

    fileprivate init(address: UInt64) {
        self.address = address
    }

    var pointee: TimerNode {
        unsafeAddress { unsafe UnsafePointer<TimerNode>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<TimerNode>(bitPattern: UInt(address))! }
    }
}

/// A CPU's pending timers, in a list by `latest` (earliest first, FIFO
/// among equals), under `lock`: its own CPU arms, fires and cancels with
/// interrupts masked; another CPU may cancel an owned node (`cancel(_:on:)`).
/// The hardware fields are the owning CPU's alone.
struct TimerQueue: ~Copyable {
    /// Slot timers' nodes. First: slot i is at the queue's address + i strides.
    var slots = InlineArray<32, TimerNode>(repeating: TimerNode())
    var head: UInt64 = 0
    var count = 0
    /// The largest slack (latest - deadline) among timers armed since the
    /// queue was last empty: a timer due by `now` has `latest` no later
    /// than now + maxSlack, which bounds the interrupt's walk.
    var maxSlack: UInt64 = 0
    var nextId: UInt32 = 1
    /// What the hardware is armed for (monotonic ns), or .max; never later
    /// than the earliest pending `latest` (it may be earlier: see
    /// `Timers.program`).
    var programmed: UInt64 = .max
    var interrupts: UInt64 = 0
    /// The hardware's own target (monotonic ns, `programmed` plus the
    /// lead) and when it was set: what an early interrupt is measured by.
    var hardwareTarget: UInt64 = 0
    var hardwareArmedAt: UInt64 = 0
    /// 1 while held (interrupts masked). A leaf: callbacks run without it.
    let lock = Atomic<UInt32>(0)

    init() {}
}

@safe struct TimerQueuePointer {
    let address: UInt64

    var pointee: TimerQueue {
        unsafeAddress { unsafe UnsafePointer<TimerQueue>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<TimerQueue>(bitPattern: UInt(address))! }
    }
}

/// Tickless per-CPU one-shot timers (roadmap K2b). The hardware is armed
/// only for the earliest `latest` among pending timers; when it fires,
/// every timer whose deadline has passed runs. Timers whose windows
/// overlap therefore coalesce into one interrupt; zero slack is exact.
/// Each CPU's queue is a list by `latest` (the head arms the hardware), so
/// it holds any number (K14b; it was a 32-slot array, and a 33rd thread
/// blocking with a deadline on one CPU panicked).
///
/// amd64: local APIC TSC-deadline mode (one-shot mode as the fallback).
/// arm64: the EL1 virtual timer (its PPI from the GTDT). rv64: SBI
/// set_timer. A timer runs on the CPU that armed it, in interrupt context.
enum Timers {
    /// Called with the two values given to `arm`.
    typealias Callback = @convention(c) (UInt64, UInt64) -> Void

    #if arch(x86_64)
    static var vector: UInt32 { 0xF1 }
    nonisolated(unsafe) private(set) static var deadlineMode = false
    /// CPUID 6 EAX[2]: the local APIC timer keeps running in deep C-states.
    /// Without it, deep idle will need an always-on wake timer (roadmap KP).
    nonisolated(unsafe) private(set) static var alwaysRunning = false
    #elseif arch(arm64)
    nonisolated(unsafe) private(set) static var intid: UInt64 = 27
    #endif

    /// Global setup (boot CPU, after Clock).
    static func initialize(_ acpi: AcpiTables) {
        #if arch(x86_64)
        deadlineMode = cpuid(1)[2] & (1 << 24) != 0  // ECX: TSC-deadline
        leadEnabled = cpuid(1)[2] & (1 << 31) != 0 && !BootOptions.has("croi.timer_lead=off")  // a hypervisor
        alwaysRunning = cpuid(6)[0] & (1 << 2) != 0  // EAX: ARAT
        #elseif arch(arm64)
        if let gtdt = acpi.table("GTDT") {
            let gsiv = acpi.withTable(gtdt) { (table: RawSpan) -> UInt32 in
                table.byteCount >= 68 ? table.load(fromByteOffset: 64, as: UInt32.self) : 0
            }
            if gsiv != 0 { intid = UInt64(gsiv) }  // virtual EL1 timer
        }
        #endif
        initializeThisCpu()
    }

    #if arch(x86_64)
    private static func cpuid(_ leaf: UInt32) -> InlineArray<4, UInt32> {
        var regs = InlineArray<4, UInt32>(repeating: 0)
        var span = regs.mutableSpan
        span.withUnsafeMutableBufferPointer { unsafe arch_cpuid(leaf, 0, $0.baseAddress!) }
        return regs
    }
    #endif

    /// This CPU's timer hardware: routed to its interrupt, disarmed.
    static func initializeThisCpu() {
        #if arch(x86_64)
        if deadlineMode {
            LocalApic.write(LocalApic.lvtTimer, vector | (2 << 17))  // TSC-deadline mode
            arch_wrmsr(0x6E0, 0)
        } else {
            LocalApic.write(LocalApic.timerDivide, 0x3)
            LocalApic.write(LocalApic.lvtTimer, vector)  // one-shot
            LocalApic.write(LocalApic.timerInitial, 0)
        }
        #elseif arch(arm64)
        arch_timer_disarm()
        GicV3.enablePrivate(intid)
        #elseif arch(riscv64)
        disarmHardware()
        arch_rv_sie_set(1 << 5)  // STIE
        #endif
    }

    /// Arms one of this CPU's slots. Returns its id (for `cancel`), or nil
    /// if every slot is taken (kernel code with a fixed number of timers;
    /// anything else owns its node).
    @discardableResult
    static func arm(
        deadline: UInt64, slack: UInt64 = 0, _ callback: Callback, _ argument: UInt64, context: UInt64 = 0
    ) -> UInt32? {
        let saved = arch_interrupts_save()
        defer { arch_interrupts_restore(saved) }
        let queue = self.queue
        for i in 0..<32 where queue.pointee.slots[i].id == 0 {
            let id = queue.pointee.nextId
            queue.pointee.nextId = id == .max ? 1 : id + 1
            let node = TimerNodePointer(address: queue.address + UInt64(i * MemoryLayout<TimerNode>.stride))
            node.pointee.id = id
            insert(node, deadline: deadline, slack: slack, callback, argument, context)
            return id
        }
        return nil
    }

    /// Arms an owned node on this CPU (it must not be armed already).
    static func arm(
        _ node: TimerNodePointer, deadline: UInt64, slack: UInt64 = 0, _ callback: Callback, _ argument: UInt64,
        context: UInt64 = 0
    ) {
        let saved = arch_interrupts_save()
        defer { arch_interrupts_restore(saved) }
        guard node.pointee.cpu < 0 else { panic("timers: node armed twice") }
        insert(node, deadline: deadline, slack: slack, callback, argument, context)
    }

    /// Cancels slot timer `id` on this CPU. False if it already fired (or
    /// never was).
    @discardableResult
    static func cancel(_ id: UInt32) -> Bool {
        guard id != 0 else { return false }
        let saved = arch_interrupts_save()
        defer { arch_interrupts_restore(saved) }
        let queue = self.queue
        for i in 0..<32 where queue.pointee.slots[i].id == id {
            let node = TimerNodePointer(address: queue.address + UInt64(i * MemoryLayout<TimerNode>.stride))
            lock(queue)
            unlink(node, queue)
            unlock(queue)
            return true
        }
        return false
    }

    /// Cancels an owned node armed on `cpu` (any CPU may ask). False if it
    /// isn't armed there: it fired, and on another CPU its callback may
    /// still be running (on this one, with interrupts masked, it has
    /// finished). The hardware stays armed: an early interrupt finds
    /// nothing due and re-arms for what is left (`program`).
    @discardableResult
    static func cancel(_ node: TimerNodePointer, on cpu: Int) -> Bool {
        let saved = arch_interrupts_save()
        defer { arch_interrupts_restore(saved) }
        let queue = self.queue(of: cpu)
        lock(queue)
        defer { unlock(queue) }
        guard node.pointee.cpu == Int32(cpu) else { return false }
        unlink(node, queue)
        return true
    }

    /// Links `node` into this CPU's queue (interrupts masked).
    private static func insert(
        _ node: TimerNodePointer, deadline: UInt64, slack: UInt64, _ callback: Callback, _ argument: UInt64,
        _ context: UInt64
    ) {
        let queue = self.queue
        let latest = deadline.addingReportingOverflow(slack).overflow ? .max : deadline + slack
        node.pointee.deadline = deadline
        node.pointee.latest = latest
        node.pointee.callback = callback
        node.pointee.argument = argument
        node.pointee.context = context
        lock(queue)
        var previous: UInt64 = 0
        var cursor = queue.pointee.head
        while cursor != 0, TimerNodePointer(address: cursor).pointee.latest <= latest {
            previous = cursor
            cursor = TimerNodePointer(address: cursor).pointee.next
        }
        node.pointee.previous = previous
        node.pointee.next = cursor
        if cursor != 0 { TimerNodePointer(address: cursor).pointee.previous = node.address }
        if previous != 0 {
            TimerNodePointer(address: previous).pointee.next = node.address
        } else {
            queue.pointee.head = node.address
        }
        node.pointee.cpu = Int32(Cpu.current)
        queue.pointee.count += 1
        queue.pointee.maxSlack = max(queue.pointee.maxSlack, latest - deadline)
        unlock(queue)
        // The hardware is never armed later than any other pending
        // timer's `latest`, so only this one can make it sooner (the
        // scheduler arms and cancels at every switch).
        if latest < queue.pointee.programmed {
            queue.pointee.programmed = latest
            armHardware(atNanoseconds: latest)
        }
    }

    /// Takes `node` out of `queue` (its lock held).
    private static func unlink(_ node: TimerNodePointer, _ queue: TimerQueuePointer) {
        let next = node.pointee.next, previous = node.pointee.previous
        if next != 0 { TimerNodePointer(address: next).pointee.previous = previous }
        if previous != 0 {
            TimerNodePointer(address: previous).pointee.next = next
        } else {
            queue.pointee.head = next
        }
        node.pointee.next = 0
        node.pointee.previous = 0
        node.pointee.id = 0
        node.pointee.cpu = -1
        queue.pointee.count -= 1
        if queue.pointee.count == 0 { queue.pointee.maxSlack = 0 }
    }

    private static func lock(_ queue: TimerQueuePointer) {
        while !queue.pointee.lock.compareExchange(expected: 0, desired: 1, ordering: .acquiring).exchanged {
            while queue.pointee.lock.load(ordering: .relaxed) != 0 { arch_spin_pause() }
        }
    }

    private static func unlock(_ queue: TimerQueuePointer) {
        queue.pointee.lock.store(0, ordering: .releasing)
    }

    /// The earliest pending `latest`, or .max.
    private static func earliestLatest(_ queue: TimerQueuePointer) -> UInt64 {
        let head = queue.pointee.head
        return head == 0 ? .max : TimerNodePointer(address: head).pointee.latest
    }

    /// Before this CPU idles (polls or halts; interrupts masked): the hardware
    /// armed for the earliest timer still pending, or not at all. `cancel`
    /// leaves it armed for speed, which on an idle CPU is a wakeup for
    /// nothing (K10f: an idle machine takes none).
    /// This CPU's earliest pending `latest` (.max: none): how long an idle
    /// CPU will sleep at most (K15c's governor).
    static func nextLatest() -> UInt64 {
        let queue = self.queue
        lock(queue)
        let earliest = earliestLatest(queue)
        unlock(queue)
        return earliest
    }

    static func settle() {
        let queue = self.queue
        lock(queue)
        let earliest = earliestLatest(queue)
        unlock(queue)
        guard earliest > queue.pointee.programmed else { return }
        queue.pointee.programmed = earliest
        if earliest == .max { disarmHardware() } else { armHardware(atNanoseconds: earliest) }
    }

    /// How early timer hardware fires, in parts per million of the
    /// distance it was armed for (KVM's TSC deadline: ~28, the host clock
    /// against our TSC); long deadlines are armed that much later. Seeded
    /// once from the measured skew (amd64 under a hypervisor), raised by
    /// any interrupt that still comes early. Shared: the skew is the
    /// host's. Racy updates are fine (a few ppm either way).
    nonisolated(unsafe) static var leadPpm: UInt64 = 0
    /// When the skew was last measured (ns since entry): it is measured
    /// again, over a longer baseline, once that has doubled.
    nonisolated(unsafe) private static var skewMeasuredAt: UInt64 = 0

    /// The farthest the hardware is ever armed (2^40 ns, ~18 minutes).
    static var maxDistance: UInt64 { 1 << 40 }

    /// The most a timer interrupt waits for a deadline it came before.
    static var earlyTolerance: UInt64 { 1_000_000 }

    /// Under a hypervisor (K14n, amd64; `croi.timer_lead=off`): a timer
    /// interrupt reaches a halted vCPU ~10-20 us after the hardware fires
    /// (KVM here), so the hardware is armed that much earlier and the
    /// interrupt waits out the rest (timers still never run early).
    /// `wakeDelay` is a running average (1/8) of how late interrupts came
    /// after the time the hardware was armed for, outliers clamped;
    /// `wakeLead` follows it, capped. Shared; racy updates are fine.
    nonisolated(unsafe) private static var leadEnabled = false
    nonisolated(unsafe) private(set) static var wakeLead: UInt64 = 0
    nonisolated(unsafe) private static var wakeDelay: UInt64 = 0
    static var maxWakeLead: UInt64 { 50_000 }

    /// The timer interrupt (interrupts masked).
    static func handleInterrupt() {
        let queue = self.queue
        queue.pointee.interrupts += 1
        queue.pointee.programmed = .max
        var now = Clock.now()
        if leadEnabled, queue.pointee.hardwareTarget != 0, now > queue.pointee.hardwareTarget {
            let delay = min(now - queue.pointee.hardwareTarget, 2 * maxWakeLead)
            wakeDelay = wakeDelay - wakeDelay / 8 + delay / 8
            wakeLead = min(wakeDelay, maxWakeLead)
        }
        // An interrupt before the hardware's own target teaches the lead:
        // in ppm of the distance it was armed for (ten ms or more, and
        // under 1%, so a stale or odd reading can't teach nonsense).
        let target = queue.pointee.hardwareTarget, armedAt = queue.pointee.hardwareArmedAt
        if target > now, target > armedAt, target - armedAt >= 10_000_000 {
            let early = target - now, distance = target - armedAt
            if early < distance / 100 {
                let ppm = early * 1_000_000 / distance + 1
                leadPpm = min(leadPpm + ppm, 2_000)
            }
        }
        // Early by a little (KVM's TSC deadline came ~240 us early for a
        // timer 10 s out, ~24 ppm): wait for the earliest instead of
        // re-arming for it, which was a second wakeup (K10f). Timers
        // never run early.
        lock(queue)
        let earliest = earliestDeadline(queue)
        unlock(queue)
        if earliest > now, earliest - now <= earlyTolerance {
            while now < earliest {
                arch_spin_pause()
                now = Clock.now()
            }
        }
        // Every timer due by `now`, one at a time: a callback may arm and
        // cancel, so the walk starts over after each.
        while true {
            lock(queue)
            guard let node = firstDue(queue, now) else {
                unlock(queue)
                break
            }
            let entry = node.pointee
            unlink(node, queue)  // first: the callback may re-arm it
            unlock(queue)
            // Not a field of the node from here on: its owner may free it
            // as soon as the callback has run.
            if let callback = entry.callback { callback(entry.argument, entry.context) }
            unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!.pointee.stats.timerCallbacks += 1
        }
        program()
        // Nothing left: the arm64 virtual timer and the SBI timer stay
        // pending until told otherwise. An x86 TSC deadline or one-shot APIC
        // timer that fired is spent already (a write was a VM exit, ~4 us
        // under KVM, K14n); one left armed for a cancelled timer is settled
        // on idle entry.
        #if !arch(x86_64)
        if queue.pointee.programmed == .max { disarmHardware() }
        #endif
    }

    /// The first timer due by `now` (lock held). One is due only if its
    /// `latest` is at most now + maxSlack, so the walk stops there.
    private static func firstDue(_ queue: TimerQueuePointer, _ now: UInt64) -> TimerNodePointer? {
        let slack = queue.pointee.maxSlack
        let horizon = now &+ slack < now ? UInt64.max : now + slack
        var cursor = queue.pointee.head
        while cursor != 0 {
            let node = TimerNodePointer(address: cursor)
            guard node.pointee.latest <= horizon else { return nil }
            if node.pointee.deadline <= now { return node }
            cursor = node.pointee.next
        }
        return nil
    }

    /// The earliest pending deadline, or .max (lock held): no timer whose
    /// `latest` is past it + maxSlack can beat it.
    private static func earliestDeadline(_ queue: TimerQueuePointer) -> UInt64 {
        let slack = queue.pointee.maxSlack
        var earliest = UInt64.max
        var cursor = queue.pointee.head
        while cursor != 0 {
            let node = TimerNodePointer(address: cursor)
            let bound = earliest &+ slack < earliest ? UInt64.max : earliest + slack
            guard node.pointee.latest <= bound else { break }
            earliest = min(earliest, node.pointee.deadline)
            cursor = node.pointee.next
        }
        return earliest
    }

    /// Diagnostics: another CPU's queue (read racily): the deadline of
    /// slot timer `id` if pending, what the hardware is armed for, pending
    /// count and interrupts taken.
    static func inspect(cpu: Int, id: UInt32) -> (deadline: UInt64?, programmed: UInt64, pending: Int, interrupts: UInt64) {
        let queue = self.queue(of: cpu)
        var deadline: UInt64? = nil
        for i in 0..<32 where id != 0 && queue.pointee.slots[i].id == id {
            deadline = queue.pointee.slots[i].deadline
        }
        return (deadline, queue.pointee.programmed, queue.pointee.count, queue.pointee.interrupts)
    }

    /// Diagnostics: an owned node's deadline if it is armed (racy).
    static func pendingDeadline(_ node: TimerNodePointer) -> UInt64? {
        node.pointee.cpu >= 0 ? node.pointee.deadline : nil
    }

    /// When this CPU's hardware was last armed to fire (ns; the time
    /// self-test's check of `maxDistance`).
    static var hardwareTarget: UInt64 { queue.pointee.hardwareTarget }

    /// Timer interrupts this CPU has taken.
    static var interruptCount: UInt64 { queue.pointee.interrupts }

    // MARK: Hardware

    private static var queue: TimerQueuePointer {
        let record = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!
        return unsafe TimerQueuePointer(address: record.pointee.timerQueue)
    }

    private static func queue(of cpu: Int) -> TimerQueuePointer {
        let record = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(Smp.records[cpu]))!
        return unsafe TimerQueuePointer(address: record.pointee.timerQueue)
    }

    /// After an interrupt: arms the hardware for the earliest `latest` left.
    /// `arm` and `cancel` don't come here: a cancel leaves the hardware
    /// armed (an early interrupt finds nothing due and re-arms for what is
    /// left), and `arm` writes it only for a sooner timer. Writing the
    /// hardware on every arm and cancel cost two VM exits per context
    /// switch under KVM (the scheduler re-arms its slice timer at each
    /// one); now it is at most one interrupt per slice.
    private static func program() {
        let queue = self.queue
        lock(queue)
        let earliest = earliestLatest(queue)
        unlock(queue)
        guard earliest < queue.pointee.programmed else { return }
        queue.pointee.programmed = earliest
        armHardware(atNanoseconds: earliest)
    }

    private static func armHardware(atNanoseconds requested: UInt64) {
        let now = arch_counter_read()
        // Later by the learned lead (K10f: a 60 s sleep came ~1.4 ms early
        // under KVM, past what an interrupt waits out, and re-arming was a
        // second wakeup). At worst a long timer runs a few ppm late.
        let queue = self.queue
        let nowNs = Clock.nanoseconds(counter: now)
        let distance = requested > nowNs ? requested - nowNs : 0
        #if arch(x86_64)
        // A long deadline is when the skew matters: measure it (an HPET
        // read, a VM exit) when the baseline has doubled since last time.
        if distance >= 1_000_000_000, nowNs >= 200_000_000, nowNs >= 2 * skewMeasuredAt {
            skewMeasuredAt = nowNs
            if let ppm = X86TimeSources.skewPpm(), ppm > 0, ppm < 1_000 {
                leadPpm = max(leadPpm, UInt64(ppm) + 5)  // +5: a short baseline's error
            }
        }
        #endif
        let lead = leadPpm
        let extra = min(distance, 1 << 40) * lead / 1_000_000
        // Never further out than `maxDistance`: KVM converts a TSC deadline
        // to host ns as delta * 10^6 / tsc_khz in 64 bits, which wraps past
        // ~6000 s at 3 GHz and fired at once; the handler found nothing due
        // and re-armed the same far deadline, an interrupt storm (a futex
        // wait 146 years out took a contended lock from 0.3 ms to 5.6 s,
        // Todhchai's pthread test). Reaching the cap, the interrupt finds
        // nothing due and arms for what is left: one wakeup per cap.
        var ns = min(requested &+ extra < requested ? .max : requested + extra, nowNs + Self.maxDistance)
        // Under a hypervisor, early by the learned delivery delay (never
        // before now; the interrupt waits for the deadline).
        if leadEnabled { ns = max(nowNs, ns - min(wakeLead, ns > nowNs ? ns - nowNs : 0)) }
        queue.pointee.hardwareTarget = ns
        queue.pointee.hardwareArmedAt = nowNs
        let counter = max(Clock.counter(atNanoseconds: ns), now + 1)
        #if arch(x86_64)
        if deadlineMode {
            arch_wrmsr(0x6E0, counter)
        } else {
            // TSC ticks to APIC timer ticks, saturating at the 32-bit counter.
            // From the same `now`: a second counter read could already be
            // past `counter`, and the wrapped difference saturated the
            // count (QEMU TCG: a due timer fired 68.7 s late).
            let product = (counter - now).multipliedFullWidth(by: X86TimeSources.apicTimerFrequency)
            let apicTicks = product.high >= Clock.frequency
                ? UInt64(UInt32.max) : Clock.frequency.dividingFullWidth(product).quotient
            LocalApic.write(LocalApic.timerInitial, UInt32(max(1, min(apicTicks, UInt64(UInt32.max)))))
        }
        #elseif arch(arm64)
        arch_timer_arm(counter)
        #elseif arch(riscv64)
        _ = arch_sbi_call(0x5449_4D45, 0, counter, 0, 0)  // TIME: set_timer
        #endif
    }

    private static func disarmHardware() {
        #if arch(x86_64)
        if deadlineMode {
            arch_wrmsr(0x6E0, 0)
        } else {
            LocalApic.write(LocalApic.timerInitial, 0)
        }
        #elseif arch(arm64)
        arch_timer_disarm()
        #elseif arch(riscv64)
        _ = arch_sbi_call(0x5449_4D45, 0, .max, 0, 0)
        #endif
    }
}

