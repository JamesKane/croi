set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CROI_SWIFT_TRIPLE aarch64-none-none-elf)
set(CROI_CLANG_TRIPLE aarch64-unknown-none-elf)
# No FP/SIMD register use in the kernel.
set(CROI_ARCH_CFLAGS -mgeneral-regs-only)
set(CROI_EFI_BOOT_NAME BOOTAA64.EFI)
# Link address of the kernel image (a PIE; the loader may relocate it).
set(CROI_KERNEL_BASE 0xffffffff80000000)
