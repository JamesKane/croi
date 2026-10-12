import CKernel

/// A kernel thread's record. It lives in one heap allocation at a fixed
/// address, because run and wait queues link threads through it. After
/// creation every field is protected by the scheduler lock.
struct Thread: ~Copyable {
    enum State { case ready, running, blocked, dead }
    enum WaitResult { case woken, timedOut, interrupted }
    /// A thread's code. Its return value is the exit code `join` returns.
    typealias Entry = @convention(c) (UInt64) -> Int

    /// The stack pointer while switched out. arch_context_switch stores
    /// it through the record's address, so it must stay first.
    var savedSp: UInt64 = 0
    var state = State.ready
    let name: StaticString
    let stack: StackRange
    /// Spawned threads own their stack; adopted boot contexts don't.
    let ownsStack: Bool
    let entry: Entry?
    let argument: UInt64
    let isIdle: Bool
    /// The scheduling context it runs on, if bound to one; otherwise a
    /// fair weight of its own (`baseWeight`, from a priority).
    var context: SchedContextPointer?
    /// A deadline context a profile object made for it (K8c): it owns it,
    /// and it goes when the thread is freed or another profile replaces it.
    var profileContext: SchedContextPointer? = nil
    /// The CPU reservation tag of its job (K10d, ext 8), or 0: it runs only
    /// on CPUs reserved for that tag (a context's own tag wins).
    var reservation: UInt32 = 0
    var baseWeight: UInt64
    /// Its base profile plus what it inherits from waiters on the owned
    /// wait queues it holds (`ownedQueues`), transitively.
    var effective: Profile
    var ownedQueues: QueuePointer?
    /// Ordering key in whatever queue it is on (smaller first): virtual
    /// runtime (fair run queue), absolute deadline (deadline run queue),
    /// next period start (throttled), `Profile.waitKey` (wait queues).
    var queueKey: UInt64 = 0
    var runQueue = RunQueue.none
    /// When it last started running, for charging the time it used.
    var runStart: UInt64 = 0
    /// When it last became ready (diagnostics: Scheduler.dump).
    var readySince: UInt64 = 0
    // Fair: virtual runtime, and how far ahead of its CPU's minimum it was
    // when it left (carried to wherever it runs next).
    var vruntime: UInt64 = 0
    var lag: Int64 = 0
    // Deadline (CBS): the current period, and the budget left in it in
    // capacity-scaled ns.
    var periodStart: UInt64 = 0
    var absoluteDeadline: UInt64 = 0
    var remaining: Int64 = 0
    /// It gave up the rest of its budget (yield): no overrun.
    var budgetYielded = false
    /// CPUs it may run on, one bit each.
    var affinity: UInt64
    /// The CPU it last ran or is queued on.
    var cpu: Int
    /// Link in a run queue or wait queue.
    var next: ThreadPointer?
    /// What it is blocked on, and how the block ended. A timeout timer
    /// carries the generation it was armed for; stale ones are ignored.
    var waitQueue: QueuePointer?
    var waitResult = WaitResult.woken
    var waitGeneration: UInt64 = 0
    /// The timeout's timer (owned), armed on `timeoutCpu` for
    /// `timeoutDeadline` while `timeoutArmed`.
    var timeoutNode = TimerNode()
    var timeoutArmed = false
    var timeoutCpu = 0
    var timeoutDeadline: UInt64 = 0
    /// CPUs where a timeout's callback may still be running (it fired as
    /// the thread cancelled it): waited out by IPI once the scheduler lock
    /// is dropped, so no callback touches the thread after it is freed.
    var timeoutStragglers: UInt64 = 0
    var exitCode = 0
    /// Dead and switched off its stack: safe to free.
    var switchedOut = false
    var detached = false
    /// The user address space it runs in, or nil (kernel threads).
    var aspace: UserAspacePointer?
    /// The handle table its syscalls use (a HandleTable's address; K7's
    /// process owns it), or 0.
    var handleTable: UInt64 = 0
    /// amd64 PKRU for JIT write gating (Jit.swift): 0 for kernel threads.
    var pkru: UInt32 = 0
    /// User thread-local storage registers (user threads only): amd64
    /// FS_BASE and the user GS base, set only through object_set_property
    /// (user code can't write them: CR4.FSGSBASE stays off), so these are
    /// the truth; arm64 TPIDR_EL0 (`tls`), which user code writes itself,
    /// so it is saved at each switch out. rv64's tp is a general register,
    /// in the exception frame.
    var tls: UInt64 = 0
    var gs: UInt64 = 0
    /// Its extended register state area (ExtendedState), or 0: kernel
    /// threads never use FP/SIMD.
    var extendedState: UInt64 = 0
    /// Per-thread PMU counters (Pmu.ThreadCounters on the heap), or 0.
    var pmu: UInt64 = 0
    /// A deadline profile lent by the event that woke it (K10c, ext 5: an
    /// interrupt, counter or timeline carrying a profile), until it next
    /// blocks.
    var lent: Profile? = nil
    /// Ext 5 (K14e): running on an event's scheduling context, which is
    /// `context` meanwhile; its own context and own budget state, put back
    /// when it blocks, runs out of the borrowed budget, exits, or the
    /// context is withdrawn.
    var borrowing = false
    var homeContext: SchedContextPointer? = nil
    var homePeriodStart: UInt64 = 0
    var homeDeadline: UInt64 = 0
    var homeRemaining: Int64 = 0
    /// Its WaitState, kept for its next wait (a thread is in one wait at a
    /// time), or 0 until it first waits.
    var waitState: UInt64 = 0
    /// The thread object it runs (K7: a reference it holds), or 0.
    var object: UInt64 = 0
    /// Killed (task_kill): it exits on its way back to user mode, and its
    /// interruptible waits end at once. Blocked in one now.
    var killPending = false
    /// K13g: a suspension waits for it on its way to user mode; the
    /// syscall it is in may be restarted (a wait woken for a suspension
    /// then sets `suspendRetry`, and the syscall is made again later).
    var suspendPending = false
    /// K13g part 3: its single-step and hardware breakpoint state (a heap
    /// DebugState, from the first write), or 0.
    var debugState: UInt64 = 0
    var restartable = false
    /// K14m: the mapping the last out-pointer check found writable
    /// ([coverStart, coverEnd) of its address space at coverGeneration):
    /// a check inside it skips the address space's lock while the
    /// mappings are unchanged (`Syscalls.check`).
    var coverStart: UInt64 = 0
    var coverEnd: UInt64 = 0
    var coverGeneration: UInt64 = 0
    var suspendRetry = false
    var interruptible = false
    /// The futex record it waits on (moved by requeue), or 0.
    var futex: UInt64 = 0
    /// Review fix: code holding this record's address past its thread
    /// object's lock (a futex owner, a profile target) pins it
    /// (`Scheduler.pin`); the reaper leaves a pinned zombie to the last
    /// `unpin` (`reapPending`). Under the scheduler lock.
    var pins = 0
    var reapPending = false
    /// Set by `dropOwnership` on its way out: it may own nothing again.
    var exiting = false
    /// Its kernel stack top holds its user registers from here on (set as
    /// it first enters user mode). Before, a thread parked suspended in
    /// `UserTraps.enter` has only live kernel frames there (review fix:
    /// thread_read/write_state read and wrote them).
    var enteredUser = false
    /// Its name in trace records: task << 12 | thread; kernel threads are
    /// task 0, idle threads 0.
    var traceId: UInt32 = 0
    /// Link in the list of every thread (`Scheduler.dump`).
    var allNext: ThreadPointer?
    /// CPUs it has run on, one bit each (tests, observability).
    var cpusSeen: UInt64 = 0
    /// K13e: time run and time spent ready but waiting for a CPU
    /// (TASK_RUNTIME, THREAD_STATS); runtime grows at each `charge`.
    var totalRuntime: UInt64 = 0
    var queueTime: UInt64 = 0
    var switchesIn: UInt64 = 0

    enum RunQueue { case none, fair, deadline, throttled }

    static var defaultPriority: Int { 16 }
    static var maxPriority: Int { 31 }

    init(name: StaticString, stack: StackRange, ownsStack: Bool, entry: Entry?, argument: UInt64,
         isIdle: Bool, priority: Int, affinity: UInt64, cpu: Int) {
        self.baseWeight = isIdle ? 0 : Profile.weight(priority: priority)
        self.effective = .fair(weight: baseWeight)
        self.name = name
        self.stack = stack
        self.ownsStack = ownsStack
        self.entry = entry
        self.argument = argument
        self.isIdle = isIdle
        self.affinity = affinity
        self.cpu = cpu
    }
}

/// The address of a Thread record. Copyable, so queues can link through
/// it; the scheduler lock is what makes using it safe.
@safe struct ThreadPointer: Equatable {
    let address: UInt64

    var pointee: Thread {
        unsafeAddress { unsafe UnsafePointer<Thread>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<Thread>(bitPattern: UInt(address))! }
    }

    /// The timeout's node, in the record.
    var timeoutNode: TimerNodePointer {
        withUnsafeMutablePointer(to: &pointee.timeoutNode) { unsafe TimerNodePointer($0) }
    }
}

/// An intrusive queue of threads, linked through `Thread.next`, in
/// increasing `Thread.queueKey` and FIFO among equals. Scheduler lock.
///
/// A queue with an `owner` is an owned wait queue (Zircon's
/// OwnedWaitQueue): its waiters lend their priority to the owner, and on
/// through whatever the owner is blocked on.
struct QueueHead {
    private(set) var head: ThreadPointer?
    private var tail: ThreadPointer?
    private(set) var count = 0
    var owner: ThreadPointer?
    /// Link in the owner's `ownedQueues`.
    var nextOwned: QueuePointer?

    var isEmpty: Bool { head == nil }

    mutating func push(_ thread: ThreadPointer) {
        thread.pointee.next = nil
        let key = thread.pointee.queueKey
        guard let first = head, first.pointee.queueKey <= key else {
            thread.pointee.next = head
            head = thread
            if tail == nil { tail = thread }
            count += 1
            return
        }
        var after = first
        while let next = after.pointee.next, next.pointee.queueKey <= key {
            after = next
        }
        thread.pointee.next = after.pointee.next
        after.pointee.next = thread
        if tail == after { tail = thread }
        count += 1
    }

    mutating func pop() -> ThreadPointer? {
        guard let first = head else { return nil }
        head = first.pointee.next
        if head == nil { tail = nil }
        first.pointee.next = nil
        count -= 1
        return first
    }

    /// Removes `thread` if it is queued here.
    @discardableResult
    mutating func remove(_ thread: ThreadPointer) -> Bool {
        var previous: ThreadPointer? = nil
        var cursor = head
        while let current = cursor {
            if current == thread {
                if let previous { previous.pointee.next = current.pointee.next } else { head = current.pointee.next }
                if tail == current { tail = previous }
                current.pointee.next = nil
                count -= 1
                return true
            }
            previous = current
            cursor = current.pointee.next
        }
        return false
    }
}

/// A QueueHead at a fixed address (heap or thread record), so a timed-out
/// thread can be taken off the queue it waits on.
@safe struct QueuePointer: Equatable {
    let address: UInt64

    var pointee: QueueHead {
        unsafeAddress { unsafe UnsafePointer<QueueHead>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<QueueHead>(bitPattern: UInt(address))! }
    }

    /// A new empty queue on the heap.
    static func allocate() -> QueuePointer {
        guard let raw = unsafe heap.allocate(size: MemoryLayout<QueueHead>.size) else {
            panic("sched: out of memory for a wait queue")
        }
        unsafe raw.bindMemory(to: QueueHead.self, capacity: 1).initialize(to: QueueHead())
        return QueuePointer(address: UInt64(UInt(bitPattern: raw)))
    }

    func deallocate() {
        unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(address))!)
    }

    /// `allocate`, nil when the heap is out (for queues made on demand in a
    /// syscall, which then fails NO_MEMORY).
    static func tryAllocate() -> QueuePointer? {
        guard let raw = unsafe heap.allocate(size: MemoryLayout<QueueHead>.size) else { return nil }
        unsafe raw.bindMemory(to: QueueHead.self, capacity: 1).initialize(to: QueueHead())
        return QueuePointer(address: UInt64(UInt(bitPattern: raw)))
    }
}

/// The owner of a spawned thread. `join` waits for it to exit and frees
/// it; dropping the handle detaches it (it is freed after it exits).
struct ThreadHandle: ~Copyable {
    let thread: ThreadPointer

    /// Waits for the thread to exit, frees it, and returns its exit code.
    @export(interface)
    consuming func join() -> Int {
        let thread = self.thread
        discard self
        return Scheduler.join(thread)
    }

    deinit {
        Scheduler.detach(thread)
    }
}

/// A new thread's first Swift code (thread.h), entered from the switch
/// that first picked it, with the scheduler lock held.
@c @implementation
func kernel_thread_main(_ thread: UInt64) -> Never {
    Scheduler.finishSwitch()
    Scheduler.lock.unlockMasked()
    arch_interrupts_enable()
    let thread = ThreadPointer(address: thread)
    let code = thread.pointee.entry!(thread.pointee.argument)
    Scheduler.exit(code)
}

/// A kernel mutex with priority inheritance (Zircon's kernel Mutex): a
/// blocking lock whose waiters lend their priority to the holder. Unlock
/// hands the lock straight to the highest-priority waiter, so nothing can
/// barge in ahead of it. Recursion and deadlock cycles panic. Not for
/// interrupt context.
struct Mutex: ~Copyable {
    let queue = QueuePointer.allocate()

    init() {}

    func lock() { Scheduler.lockMutex(queue) }
    func unlock() { Scheduler.unlockMutex(queue) }

    func withLock<R>(_ body: () -> R) -> R {
        lock()
        defer { unlock() }
        return body()
    }

    /// The holder, if any (racy unless the caller is it).
    var owner: ThreadPointer? { Scheduler.locked { queue.pointee.owner } }
    var waiters: Int { Scheduler.locked { queue.pointee.count } }

    deinit {
        Scheduler.locked {
            guard queue.pointee.owner == nil, queue.pointee.isEmpty else { panic("mutex: destroyed while held") }
        }
        queue.deallocate()
    }
}
