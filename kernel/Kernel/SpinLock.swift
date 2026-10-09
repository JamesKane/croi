import CKernel
import Synchronization

/// This CPU's number. Always 0 until per-CPU data exists (SMP bring-up).
enum Cpu {
    static var current: UInt32 { 0 }
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
    func acquire() -> InterruptState {
        let me = Cpu.current + 1
        let saved = InterruptState(raw: arch_interrupts_save())
        while true {
            if holder.compareExchange(expected: 0, desired: me, ordering: .acquiring).exchanged {
                return saved
            }
            if holder.load(ordering: .relaxed) == me {
                panic("spinlock: recursive acquire")
            }
            while holder.load(ordering: .relaxed) != 0 {
                arch_spin_pause()
            }
        }
    }

    /// Releases the lock and restores the interrupt state from `acquire`.
    func release(_ saved: InterruptState) {
        guard holder.load(ordering: .relaxed) == Cpu.current + 1 else {
            panic("spinlock: released by a CPU that doesn't hold it")
        }
        holder.store(0, ordering: .releasing)
        arch_interrupts_restore(saved.raw)
    }

    var isHeldByCurrentCpu: Bool {
        holder.load(ordering: .relaxed) == Cpu.current + 1
    }
}
