set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CROI_SWIFT_TRIPLE x86_64-unknown-none-elf)
set(CROI_CLANG_TRIPLE x86_64-unknown-none-elf)
# No red zone (interrupts land on the current stack); no SIMD/FP state in the
# kernel. Swift's shims need `long double`, so Swift can only drop SSE/MMX:
# floating point in Swift kernel code would silently use x87. Don't.
set(CROI_ARCH_CFLAGS -mno-red-zone -mgeneral-regs-only)
set(CROI_ARCH_SWIFT_CFLAGS -mno-red-zone -mno-sse -mno-mmx)
# User mode (K6c split): x86-64 baseline with SSE (user FP/SIMD state is
# saved since K6d).
set(CROI_USER_CFLAGS)
set(CROI_EFI_BOOT_NAME BOOTX64.EFI)
# Link address of the kernel image (a PIE; the loader may relocate it).
set(CROI_KERNEL_BASE 0xffffffff80000000)
