import Synchronization

/// Shared ownership of a kernel object, without ARC (Zircon's fbl::RefPtr).
///
/// The kernel can't use Swift classes: Embedded Swift treats higher-half
/// objects as immortal (see CLAUDE.md). `Ref` is the explicit replacement.
/// The value lives in one heap allocation followed by an atomic count. A
/// `Ref` is `~Copyable`, so every new owner is a visible `share()`.
/// Dropping or consuming the last `Ref` deinitializes the value and frees
/// the memory.
///
/// Shared values are read through `value`. State that changes while shared
/// needs its own synchronization (atomics, locks), as in Zircon.
@safe struct Ref<T: ~Copyable>: ~Copyable {
    /// Allocation layout: `T` at offset 0, then `Atomic<Int>` at `countOffset`.
    private let storage: UnsafeMutableRawPointer

    private static var countOffset: Int {
        let alignment = MemoryLayout<Atomic<Int>>.alignment
        return (MemoryLayout<T>.size + alignment - 1) & ~(alignment - 1)
    }

    /// Moves `value` into a new heap allocation with one owner. Panics if
    /// the heap is exhausted.
    init(_ value: consuming T) {
        let size = Self.countOffset + MemoryLayout<Atomic<Int>>.size
        let alignment = max(MemoryLayout<T>.alignment, MemoryLayout<Atomic<Int>>.alignment, 16)
        guard let raw = unsafe heap.allocate(size: size, alignment: alignment) else {
            panic("Ref: out of memory")
        }
        unsafe raw.bindMemory(to: T.self, capacity: 1).initialize(to: value)
        unsafe (raw + Self.countOffset).bindMemory(to: Atomic<Int>.self, capacity: 1).initialize(to: Atomic(1))
        unsafe storage = raw
    }

    private init(sharing storage: UnsafeMutableRawPointer) {
        unsafe self.storage = storage
    }

    private var valuePointer: UnsafeMutablePointer<T> {
        unsafe storage.assumingMemoryBound(to: T.self)
    }

    private var count: UnsafeMutablePointer<Atomic<Int>> {
        unsafe (storage + Self.countOffset).assumingMemoryBound(to: Atomic<Int>.self)
    }

    /// Another owner of the same value.
    func share() -> Ref<T> {
        let owners = unsafe count.pointee.add(1, ordering: .relaxed).newValue
        guard owners > 1 else { panic("Ref: count overflow or use after free") }
        return unsafe Ref(sharing: storage)
    }

    /// Number of owners right now (racy if other CPUs hold Refs).
    var ownerCount: Int {
        unsafe count.pointee.load(ordering: .relaxed)
    }

    /// Borrows the shared value. A `_read` coroutine rather than
    /// `unsafeAddress` (which makes the Ref unconsumable after a read in
    /// 6.4.0); becomes `yielding borrow` once SE-0474 is non-experimental.
    var value: T {
        _read { yield unsafe valuePointer.pointee }
    }

    deinit {
        // Release ordering publishes this owner's writes; the final owner
        // acquires them before tearing the value down.
        let remaining = unsafe count.pointee.subtract(1, ordering: .acquiringAndReleasing).newValue
        if remaining == 0 {
            unsafe valuePointer.deinitialize(count: 1)
            unsafe count.deinitialize(count: 1)
            unsafe heap.free(storage)
        } else if remaining < 0 {
            panic("Ref: released too many times")
        }
    }
}
