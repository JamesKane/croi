import CKernel

/// A kernel stack: CROI_KERNEL_STACK_SIZE bytes of fresh RAM in the kernel
/// address space, aligned to twice its size, with unmapped guard pages on
/// both sides (see stack.h for why the alignment matters). Overflowing it
/// faults on the guard page and is reported as a stack overflow.
///
/// Owns its memory: dropping the value unmaps and frees the stack, so it
/// must outlive any CPU running on it.
struct KernelStack: ~Copyable {
    static var size: UInt64 { UInt64(CROI_KERNEL_STACK_SIZE) }

    /// Lowest address of the stack.
    let base: UInt64
    /// Initial stack pointer (stacks grow down).
    var top: UInt64 { base + Self.size }

    init() throws(VmError) {
        base = try kernelAspace.allocate(pages: Int(Self.size / KernelLayout.pageSize), alignment: 2 * Self.size)
    }

    func contains(_ address: UInt64) -> Bool { address >= base && address < top }

    /// Gives up ownership without freeing: for stacks that live as long as
    /// the kernel (the boot thread's, per-CPU exception stacks).
    @export(interface)
    consuming func keepForever() -> StackRange {
        let range = StackRange(base: base, top: top)
        discard self
        return range
    }

    deinit {
        do throws(VmError) {
            try kernelAspace.free(base)
        } catch {
            panic("KernelStack: freeing an unknown stack")
        }
    }
}

/// The bounds of a stack nobody frees (see `KernelStack.keepForever`).
struct StackRange {
    var base: UInt64 = 0
    var top: UInt64 = 0

    func contains(_ address: UInt64) -> Bool { address >= base && address < top }
}
