import CKernel

/// First Swift code in the kernel. Declared in kernel.h; called from the
/// arch start code with a valid stack and nothing else set up.
@c @implementation
func kernel_main(_ handoff: UnsafeRawPointer?) -> Never {
    arch_halt()
}
