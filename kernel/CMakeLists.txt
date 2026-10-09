add_library(kernel-swift OBJECT
  Kernel/BootAllocator.swift
  Kernel/Exceptions.swift
  Kernel/Heap.swift
  Kernel/KernelLayout.swift
  Kernel/KernelPageTables.swift
  Kernel/Main.swift
  Kernel/Panic.swift
  Kernel/Pmm.swift
  Kernel/Ref.swift
  Kernel/Uart.swift)
set_target_properties(kernel-swift PROPERTIES Swift_MODULE_NAME Kernel)
target_include_directories(kernel-swift PRIVATE include)
target_link_libraries(kernel-swift PRIVATE croi-fmt croi-handoff croi-pagetables)

add_executable(kernel arch/${CROI_ARCH}/start.S arch/${CROI_ARCH}/exceptions.S)
target_link_libraries(kernel PRIVATE kernel-swift croi-rt)
set_target_properties(kernel PROPERTIES OUTPUT_NAME kernel.elf)
croi_image(kernel ENTRY _start BASE ${CROI_KERNEL_BASE})

# The kernel is ownership-only: refuse images that pull in Swift's
# refcounting runtime (see cmake/CheckNoArc.cmake).
add_custom_command(TARGET kernel POST_BUILD
  COMMAND ${CMAKE_COMMAND} -DNM=${CROI_TOOLCHAIN_DIR}/usr/bin/llvm-nm -DIMAGE=$<TARGET_FILE:kernel>
          -P ${PROJECT_SOURCE_DIR}/cmake/CheckNoArc.cmake
  COMMENT "Checking kernel is free of Swift refcounting")
