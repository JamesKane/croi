add_library(kernel-swift OBJECT
  Kernel/Acpi/AcpiTables.swift
  Kernel/Acpi/Madt.swift
  Kernel/Acpi/Pptt.swift
  Kernel/Acpi/Rhct.swift
  Kernel/BootAllocator.swift
  Kernel/BootOptions.swift
  Kernel/Exceptions.swift
  Kernel/Framebuffer.swift
  Kernel/Heap.swift
  Kernel/Irq/Interrupts.swift
  Kernel/Irq/Ipi.swift
  Kernel/KernelLayout.swift
  Kernel/KernelPageTables.swift
  Kernel/KernelStack.swift
  Kernel/Main.swift
  Kernel/Panic.swift
  Kernel/Pmm.swift
  Kernel/Ref.swift
  Kernel/Smp.swift
  Kernel/User/Syscalls.swift
  Kernel/User/UserSelfTest.swift
  Kernel/User/SyscallSelfTest.swift
  Kernel/Object/Status.swift
  Kernel/Object/KernelObject.swift
  Kernel/Object/Wait.swift
  Kernel/Object/HandleTable.swift
  Kernel/Object/Port.swift
  Kernel/Object/VmoObject.swift
  Kernel/Object/ObjectSelfTest.swift
  Kernel/Object/PortSelfTest.swift
  Kernel/Object/ResourceSelfTest.swift
  Kernel/Time/Clock.swift
  Kernel/Time/Timers.swift
  Kernel/Time/Watchdog.swift
  Kernel/Sched/Profile.swift
  Kernel/Sched/ExtendedState.swift
  Kernel/Sched/ExtendedStateSelfTest.swift
  Kernel/Sched/Thread.swift
  Kernel/Sched/Scheduler.swift
  Kernel/Sched/SchedulerSelfTest.swift
  Kernel/Sched/MutexSelfTest.swift
  Kernel/Sched/DeadlineSelfTest.swift
  Kernel/SpinLock.swift
  Kernel/Trace/Trace.swift
  Kernel/Trace/TraceSelfTest.swift
  Kernel/Uart.swift
  Kernel/Vm/ArchAspace.swift
  Kernel/Vm/KernelAspace.swift
  Kernel/Vm/UserAspace.swift
  Kernel/Vm/Vmo.swift
  Kernel/Vm/PageList.swift
  Kernel/Vm/MemoryAccount.swift
  Kernel/Vm/Jit.swift
  Kernel/Vm/ContiguousPool.swift
  Kernel/Vm/AspaceSelfTest.swift
  Kernel/Vm/VmoSelfTest.swift
  Kernel/Vm/RegionSelfTest.swift
  Kernel/Vm/PhysicalSelfTest.swift
  Kernel/Vm/AccountSelfTest.swift
  Kernel/Vm/JitSelfTest.swift)
set_target_properties(kernel-swift PROPERTIES Swift_MODULE_NAME Kernel)
target_include_directories(kernel-swift PRIVATE include)
target_link_libraries(kernel-swift PRIVATE croi-fmt croi-handoff croi-pagetables)

add_executable(kernel
  arch/${CROI_ARCH}/start.S
  arch/${CROI_ARCH}/cpu.S
  arch/${CROI_ARCH}/exceptions.S
  arch/${CROI_ARCH}/smp.S
  arch/${CROI_ARCH}/thread.S
  arch/${CROI_ARCH}/usercopy.S
  arch/${CROI_ARCH}/usertest.S
  userprogram.S
  trace.c)
target_include_directories(kernel PRIVATE include)
target_link_libraries(kernel PRIVATE kernel-swift croi-rt)
set_target_properties(kernel PROPERTIES OUTPUT_NAME kernel.elf)
croi_image(kernel ENTRY _start BASE ${CROI_KERNEL_BASE})

# The kernel is ownership-only: refuse images that pull in Swift's
# refcounting runtime (see cmake/CheckNoArc.cmake).
add_custom_command(TARGET kernel POST_BUILD
  COMMAND ${CMAKE_COMMAND} -DNM=${CROI_TOOLCHAIN_DIR}/usr/bin/llvm-nm -DIMAGE=$<TARGET_FILE:kernel>
          -P ${PROJECT_SOURCE_DIR}/cmake/CheckNoArc.cmake
  COMMENT "Checking kernel is free of Swift refcounting")

# The K6b self-test's user program: C built with user-mode flags (no
# kernel code model, red zone allowed) into a flat binary at its fixed
# user address, then included in the kernel image (userprogram.S).
if(CROI_ARCH STREQUAL amd64)
  set(_user_flags -mgeneral-regs-only)
elseif(CROI_ARCH STREQUAL arm64)
  set(_user_flags -mgeneral-regs-only)
else()
  set(_user_flags -march=rv64imac -mabi=lp64 -mcmodel=medany)
endif()
set(_user_dir ${PROJECT_SOURCE_DIR}/user)
set(_user_elf ${CMAKE_CURRENT_BINARY_DIR}/usertest.elf)
set(_user_bin ${CMAKE_CURRENT_BINARY_DIR}/usertest.bin)
add_custom_command(OUTPUT ${_user_bin}
  COMMAND ${CMAKE_C_COMPILER} --target=${CROI_CLANG_TRIPLE} ${_user_flags} -std=c23 -O2 -ffreestanding
          -fno-pic -fno-pie -fno-stack-protector -fno-builtin -nostdlib -static -fuse-ld=lld
          -Wl,--no-pie -Wl,-T,${_user_dir}/test/user.ld -I${_user_dir}/include
          ${_user_dir}/test/usertest.c -o ${_user_elf}
  COMMAND ${CMAKE_OBJCOPY} -O binary ${_user_elf} ${_user_bin}
  DEPENDS ${_user_dir}/test/usertest.c ${_user_dir}/test/user.ld ${_user_dir}/include/croi/syscall.h
  COMMENT "Building the user test program")
set_source_files_properties(userprogram.S PROPERTIES
  OBJECT_DEPENDS ${_user_bin}
  COMPILE_DEFINITIONS "CROI_USER_PROGRAM=\"${_user_bin}\"")
