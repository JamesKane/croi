add_library(kernel-swift OBJECT Kernel/Main.swift)
set_target_properties(kernel-swift PROPERTIES Swift_MODULE_NAME Kernel)
target_include_directories(kernel-swift PRIVATE include)

add_executable(kernel arch/${CROI_ARCH}/start.S)
target_link_libraries(kernel PRIVATE kernel-swift croi-rt)
set_target_properties(kernel PROPERTIES OUTPUT_NAME kernel.elf)
croi_image(kernel ENTRY _start BASE ${CROI_KERNEL_BASE})
