import CKernel

/// A kernel thread's record. It lives in one heap allocation at a fixed
/// address, because run and wait queues link threads through it. After
/// creation every field is protected by the scheduler lock.
struct Thread: ~Copyable {
    enum State { case ready, running, blocked, dead }
    enum WaitResult { case woken, timedOut }
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
    /// The armed timeout, if any. Timers belong to the CPU that armed them,
    /// so one on another CPU is cancelled by IPI once the scheduler lock is
    /// dropped; until then it waits in `staleTimers` (cpu << 32 | id).
    var timeoutTimer: UInt32 = 0
    var timeoutCpu = 0
    var timeoutDeadline: UInt64 = 0
    var staleTimers = InlineArray<4, UInt64>(repeating: 0)
    var staleTimerCount = 0
    var exitCode = 0
    /// Dead and switched off its stack: safe to free.
    var switchedOut = false
    var detached = false
    /// Its extended register state area (ExtendedState), or 0: kernel
    /// threads never use FP/SIMD.
    var extendedState: UInt64 = 0
    /// Its name in trace records: task << 12 | thread; kernel threads are
    /// task 0, idle threads 0.
    var traceId: UInt32 = 0
    /// Link in the list of every thread (`Scheduler.dump`).
    var allNext: ThreadPointer?
    /// CPUs it has run on, one bit each (tests, observability).
    var cpusSeen: UInt64 = 0
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
