add_library(kernel-swift OBJECT
  Kernel/Acpi/AcpiTables.swift
  Kernel/Acpi/Madt.swift
  Kernel/Acpi/Pptt.swift
  Kernel/Acpi/Rhct.swift
  Kernel/Acpi/Mcfg.swift
  Kernel/BootAllocator.swift
  Kernel/BootOptions.swift
  Kernel/Exceptions.swift
  Kernel/Framebuffer.swift
  Kernel/Heap.swift
  Kernel/Irq/Interrupts.swift
  Kernel/Irq/Ipi.swift
  Kernel/Irq/DeviceIrqs.swift
  Kernel/Irq/Its.swift
  Kernel/Irq/Aia.swift
  Kernel/KernelLayout.swift
  Kernel/KernelPageTables.swift
  Kernel/KernelStack.swift
  Kernel/Main.swift
  Kernel/Panic.swift
  Kernel/Power.swift
  Kernel/Random.swift
  Kernel/Pmm.swift
  Kernel/Ref.swift
  Kernel/Smp.swift
  Kernel/User/Syscalls.swift
  Kernel/User/TaskSyscalls.swift
  Kernel/User/IpcSyscalls.swift
  Kernel/User/SocketSyscalls.swift
  Kernel/User/StreamSyscalls.swift
  Kernel/User/PagerSyscalls.swift
  Kernel/User/InfoTopics.swift
  Kernel/User/ClockSyscalls.swift
  Kernel/User/DebugSyscalls.swift
  Kernel/User/SmcSyscalls.swift
  Kernel/User/DriverSyscalls.swift
  Kernel/User/DmaSyscalls.swift
  Kernel/User/CounterSyscalls.swift
  Kernel/User/IoPorts.swift
  Kernel/User/SyncSyscalls.swift
  Kernel/User/ExceptionSyscalls.swift
  Kernel/User/Vdso.swift
  Kernel/User/ProgramLoader.swift
  Kernel/User/ProgramSelfTest.swift
  Kernel/User/Userboot.swift
  Kernel/User/BootData.swift
  Kernel/User/VdsoSelfTest.swift
  Kernel/User/FpSelfTest.swift
  Kernel/User/UserSelfTest.swift
  Kernel/User/SyscallSelfTest.swift
  Kernel/Object/Status.swift
  Kernel/Object/KernelObject.swift
  Kernel/Object/Wait.swift
  Kernel/Object/HandleTable.swift
  Kernel/Object/Port.swift
  Kernel/Object/Process.swift
  Kernel/Object/Channel.swift
  Kernel/Object/Fifo.swift
  Kernel/Object/Socket.swift
  Kernel/Object/Stream.swift
  Kernel/Object/Pager.swift
  Kernel/Object/Names.swift
  Kernel/Object/ClockObject.swift
  Kernel/Object/Debug.swift
  Kernel/Object/HardwareDebug.swift
  Kernel/Object/Futex.swift
  Kernel/Object/TimerObject.swift
  Kernel/Object/Exception.swift
  Kernel/Object/DebugLog.swift
  Kernel/Object/ProfileObject.swift
  Kernel/Object/Resource.swift
  Kernel/Object/InterruptObject.swift
  Kernel/Object/MsiObject.swift
  Kernel/Object/Dma.swift
  Kernel/Iommu/IoDomain.swift
  Kernel/Iommu/IntelIommu.swift
  Kernel/Iommu/InterruptRemapping.swift
  Kernel/Iommu/AmdIommu.swift
  Kernel/Iommu/SmmuV3.swift
  Kernel/Iommu/SmmuV2.swift
  Kernel/Iommu/SmmuV2SelfTest.swift
  Kernel/Iommu/RiscvIommu.swift
  Kernel/Object/KernelMemory.swift
  Kernel/Object/Counter.swift
  Kernel/Object/AccountObject.swift
  Kernel/Object/Timeline.swift
  Kernel/Object/ProcessSelfTest.swift
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
  Kernel/Sched/Idle.swift
  Kernel/Sched/SchedulerSelfTest.swift
  Kernel/Sched/MutexSelfTest.swift
  Kernel/Sched/DeadlineSelfTest.swift
  Kernel/SpinLock.swift
  Kernel/Trace/Trace.swift
  Kernel/Trace/Budgets.swift
  Kernel/Trace/Sampler.swift
  Kernel/Trace/Pmu.swift
  Kernel/Trace/PmuSelfTest.swift
  Kernel/Trace/SamplerSelfTest.swift
  Kernel/Trace/TraceSelfTest.swift
  Kernel/Uart.swift
  Kernel/Vm/ArchAspace.swift
  Kernel/Vm/KernelAspace.swift
  Kernel/Vm/UserAspace.swift
  Kernel/Vm/Vmo.swift
  Kernel/Vm/PageList.swift
  Kernel/Vm/Reclaim.swift
  Kernel/Vm/Loans.swift
  Kernel/Vm/MemoryAccount.swift
  Kernel/Vm/Jit.swift
  Kernel/Vm/ContiguousPool.swift
  Kernel/Vm/AspaceSelfTest.swift
  Kernel/Vm/VmoSelfTest.swift
  Kernel/Vm/RegionSelfTest.swift
  Kernel/Vm/ShootdownSelfTest.swift
  Kernel/Vm/PhysicalSelfTest.swift
  Kernel/Vm/AccountSelfTest.swift
  Kernel/Vm/JitSelfTest.swift)
set_target_properties(kernel-swift PROPERTIES Swift_MODULE_NAME Kernel)
target_include_directories(kernel-swift PRIVATE include)
target_link_libraries(kernel-swift PRIVATE croi-fmt croi-handoff croi-pagetables croi-elf)

# Flag types are BitFlags, never OptionSet (cmake/CheckNoOptionSet.cmake).
get_target_property(_kernel_sources kernel-swift SOURCES)
list(TRANSFORM _kernel_sources PREPEND ${CMAKE_CURRENT_SOURCE_DIR}/)
add_custom_command(OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/no-optionset.stamp
  COMMAND ${CMAKE_COMMAND} "-DSOURCES=${_kernel_sources}" -DSTAMP=${CMAKE_CURRENT_BINARY_DIR}/no-optionset.stamp
          -P ${PROJECT_SOURCE_DIR}/cmake/CheckNoOptionSet.cmake
  DEPENDS ${_kernel_sources} ${PROJECT_SOURCE_DIR}/cmake/CheckNoOptionSet.cmake
  COMMENT "Checking the kernel declares no OptionSet"
  VERBATIM)
add_custom_target(kernel-no-optionset DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/no-optionset.stamp)
add_dependencies(kernel-swift kernel-no-optionset)

# K14p/K14q: arm64 return addresses signed (pac-ret) and landing pads for
# indirect branches (bti). Hint-space instructions, NOPs where the CPU
# lacks the feature or it is off.
if(CROI_ARCH STREQUAL "arm64")
  target_compile_options(kernel-swift PRIVATE "SHELL:-Xcc -mbranch-protection=pac-ret+bti")
endif()

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
if(CROI_ARCH STREQUAL "arm64")
  target_compile_options(kernel PRIVATE $<$<COMPILE_LANGUAGE:C>:-mbranch-protection=pac-ret+bti>)
endif()
target_link_libraries(kernel PRIVATE kernel-swift croi-rt)
set_target_properties(kernel PROPERTIES OUTPUT_NAME kernel.elf)
croi_image(kernel ENTRY _start BASE ${CROI_KERNEL_BASE})

# The kernel is ownership-only: refuse images that pull in Swift's
# refcounting runtime (see cmake/CheckNoArc.cmake).
add_custom_command(TARGET kernel POST_BUILD
  COMMAND ${CMAKE_COMMAND} -DNM=${CROI_TOOLCHAIN_DIR}/usr/bin/llvm-nm -DIMAGE=$<TARGET_FILE:kernel>
          -P ${PROJECT_SOURCE_DIR}/cmake/CheckNoArc.cmake
  COMMENT "Checking kernel is free of Swift refcounting")

# User binaries the kernel carries (cmake/CroiUser.cmake): the self-test
# program and the vDSO.
include(${PROJECT_SOURCE_DIR}/cmake/CroiUser.cmake)
set(_user_dir ${PROJECT_SOURCE_DIR}/user)
set(_user_bin ${CMAKE_CURRENT_BINARY_DIR}/usertest.bin)
croi_user_binary(${_user_bin}
  SOURCES ${_user_dir}/test/usertest.c
  LINKER_SCRIPT ${_user_dir}/test/user.ld
  INCLUDES ${CMAKE_CURRENT_SOURCE_DIR}/include)
set(_vdso_bin ${CMAKE_CURRENT_BINARY_DIR}/vdso.bin)
croi_user_binary(${_vdso_bin} PIC
  SOURCES ${_user_dir}/vdso/header.S ${_user_dir}/vdso/vdso.c
  LINKER_SCRIPT ${_user_dir}/vdso/vdso.ld
  INCLUDES ${CMAKE_CURRENT_SOURCE_DIR}/include)
croi_user_runtime()
set(_swift_test ${CMAKE_CURRENT_BINARY_DIR}/swifttest.elf)
croi_user_program(${_swift_test} PIE SWIFT ${_user_dir}/test/swift/Main.swift)
# The same as a fixed-address program with a dynamic section and no
# relocations (Todhchai's dlopen hosts, linked --export-dynamic).
set(_swift_test_exec ${CMAKE_CURRENT_BINARY_DIR}/swifttestexec.elf)
croi_user_program(${_swift_test_exec} EXPORT_DYNAMIC SWIFT ${_user_dir}/test/swift/Main.swift)
# userboot (K8b), carried in the kernel image like Zircon's; it shares
# lib/elf's sources with the kernel and loader.
set(_userboot ${CMAKE_CURRENT_BINARY_DIR}/userboot.elf)
croi_user_program(${_userboot} PIE
  SWIFT ${_user_dir}/userboot/Main.swift ${_user_dir}/userboot/Bootfs.swift
        ${_user_dir}/userboot/Power.swift
        ${PROJECT_SOURCE_DIR}/lib/elf/Elf/ElfImage.swift)
set_source_files_properties(userprogram.S PROPERTIES
  OBJECT_DEPENDS "${_user_bin};${_vdso_bin};${_swift_test};${_swift_test_exec};${_userboot}"
  COMPILE_DEFINITIONS "CROI_USER_PROGRAM=\"${_user_bin}\";CROI_VDSO=\"${_vdso_bin}\";CROI_SWIFT_TEST=\"${_swift_test}\";CROI_SWIFT_TEST_EXEC=\"${_swift_test_exec}\";CROI_USERBOOT=\"${_userboot}\"")

# bootfs (K8b): the programs userboot can start, in Zircon's bootfs format
# (tools/mkbootfs.py), served on the ESP as \croi\bootfs.img.
set(_m2 ${CMAKE_CURRENT_BINARY_DIR}/m2.elf)
croi_user_program(${_m2} PIE SWIFT ${_user_dir}/m2/Main.swift ${_user_dir}/m2/Sys.swift ${_user_dir}/m2/Bench.swift)
set(CROI_BOOTFS_IMAGE ${CMAKE_BINARY_DIR}/bootfs.img PARENT_SCOPE)
add_custom_command(OUTPUT ${CMAKE_BINARY_DIR}/bootfs.img
  COMMAND ${Python3_EXECUTABLE} -I ${PROJECT_SOURCE_DIR}/tools/mkbootfs.py ${CMAKE_BINARY_DIR}/bootfs.img
          bin/m2=${_m2}
  DEPENDS ${_m2} ${PROJECT_SOURCE_DIR}/tools/mkbootfs.py
  COMMENT "Building bootfs")
add_custom_target(bootfs DEPENDS ${CMAKE_BINARY_DIR}/bootfs.img)
