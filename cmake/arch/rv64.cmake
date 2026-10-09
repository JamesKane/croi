set(CMAKE_SYSTEM_PROCESSOR riscv64)
set(CROI_SWIFT_TRIPLE riscv64-none-none-eabi)
set(CROI_CLANG_TRIPLE riscv64-unknown-none-elf)
# RVA20-ish integer baseline; soft-float ABI so the kernel never touches FP state.
set(CROI_ARCH_CFLAGS -march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany)
# User mode (K6c split): integer only until K6d (then rv64gcv, lp64d).
set(CROI_USER_CFLAGS -march=rv64imac -mabi=lp64 -mcmodel=medany)
set(CROI_EFI_BOOT_NAME BOOTRISCV64.EFI)
# Link address of the kernel image (a PIE; the loader may relocate it).
set(CROI_KERNEL_BASE 0xffffffff80000000)
