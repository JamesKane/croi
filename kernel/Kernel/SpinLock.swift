import CKernel
import Synchronization

/// This CPU's number, from its PerCpu record (0 before the boot CPU's
/// record is installed).
enum Cpu {
    static var current: UInt32 {
        let record = arch_percpu()
        guard record != 0 else { return 0 }
        return unsafe UnsafePointer<PerCpu>(bitPattern: UInt(record))!.pointee.number
    }
}

/// Interrupt state saved by `SpinLock.acquire`, restored by `release`.
struct InterruptState {
    fileprivate let raw: UInt64
}

/// A spinlock that also masks interrupts on this CPU while held (Zircon's
/// SpinLock taken with IrqSave), so interrupt handlers may take the same
/// lock without deadlocking against the code they interrupted.
///
/// Test-and-test-and-set. The lock word holds the holder's CPU number + 1,
/// which catches recursive acquisition (a guaranteed deadlock) and release
/// by a CPU that doesn't hold it; both panic.
///
/// Lock order (take left before right): vm -> heap -> pmm.
struct SpinLock: ~Copyable {
    /// 0 when free, else holder CPU + 1.
    private let holder = Atomic<UInt32>(0)

    init() {}

    /// Runs `body` with the lock held and interrupts masked.
    func withLock<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
        let saved = acquire()
        do {
            let result = try body()
            release(saved)
            return result
        } catch {
            release(saved)
            throw error
        }
    }

    /// Masks interrupts and spins until the lock is ours. Prefer `withLock`.
    ///
    /// While waiting, the caller's own interrupt state is back in force, so a
    /// CPU spinning here from an interrupts-on context still answers IPIs:
    /// the holder may be waiting on it (TLB shootdown under `vmLock`).
    func acquire() -> InterruptState {
        let saved = InterruptState(raw: arch_interrupts_save())
        while true {
            // Read with interrupts masked: a thread waiting below with them
            // on can be preempted and moved to another CPU.
            let me = Cpu.current + 1
            if holder.compareExchange(expected: 0, desired: me, ordering: .acquiring).exchanged {
                Self.counted(+1)
                return saved
            }
            if holder.load(ordering: .relaxed) == me {
                panic("spinlock: recursive acquire")
            }
            arch_interrupts_restore(saved.raw)
            while holder.load(ordering: .relaxed) != 0 {
                Self.checkHolder(holder.load(ordering: .relaxed))
                arch_spin_pause()
            }
            _ = arch_interrupts_save()
        }
    }

    /// The CPU holding it, or -1 (racy: lockup reports).
    var holderCpu: Int { Int(holder.load(ordering: .relaxed)) - 1 }

    /// Releases the lock and restores the interrupt state from `acquire`.
    func release(_ saved: InterruptState) {
        guard holder.load(ordering: .relaxed) == Cpu.current + 1 else {
            panic("spinlock: released by a CPU that doesn't hold it")
        }
        Self.counted(-1)
        holder.store(0, ordering: .releasing)
        arch_interrupts_restore(saved.raw)
    }

    /// This CPU's count of held SpinLocks (before PerCpu exists: none).
    private static func counted(_ delta: Int32) {
        guard let percpu = unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(arch_percpu())) else { return }
        unsafe percpu.pointee.spinLocksHeld = UInt32(bitPattern: Int32(bitPattern: percpu.pointee.spinLocksHeld) + delta)
    }

    /// Locks without touching interrupts: the caller has masked them and
    /// restores them itself. For the scheduler, whose lock is handed across
    /// context switches (the thread that resumes releases it).
    func lockMasked() {
        // Masked by the caller, or the thread could move between reading its
        // CPU and taking the lock, and take it in another CPU's name.
        guard !arch_interrupts_enabled() else { panic("spinlock: lockMasked with interrupts on") }
        let me = Cpu.current + 1
        while !holder.compareExchange(expected: 0, desired: me, ordering: .acquiring).exchanged {
            if holder.load(ordering: .relaxed) == me {
                panic("spinlock: recursive acquire")
            }
            while holder.load(ordering: .relaxed) != 0 {
                Self.checkHolder(holder.load(ordering: .relaxed))
                arch_spin_pause()
            }
        }
    }

    /// A holder no CPU can be is a lock in freed memory (the heap poisons
    /// with 0xA5) or a corrupt one: report it rather than spin forever
    /// (a job kill locked a freed thread object that way).
    private static func checkHolder(_ value: UInt32) {
        if value > UInt32(Smp.maxCpus) { panic("spinlock: holder isn't a CPU (freed or corrupt lock)") }
    }

    /// One attempt at `lockMasked`.
    func tryLockMasked() -> Bool {
        holder.compareExchange(expected: 0, desired: Cpu.current + 1, ordering: .acquiring).exchanged
    }

    var holderForDebugging: UInt32 { holder.load(ordering: .relaxed) }

    func unlockMasked() {
        guard holder.load(ordering: .relaxed) == Cpu.current + 1 else {
            panic("spinlock: released by a CPU that doesn't hold it")
        }
        holder.store(0, ordering: .releasing)
    }

    var isHeldByCurrentCpu: Bool {
        holder.load(ordering: .relaxed) == Cpu.current + 1
    }
}
