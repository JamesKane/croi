cmake_minimum_required(VERSION 3.29)

if(NOT CMAKE_TOOLCHAIN_FILE)
  message(FATAL_ERROR "Configure with a preset, e.g. `cmake --preset amd64`")
endif()

project(croi LANGUAGES C ASM Swift)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

find_package(Python3 3.10 REQUIRED COMPONENTS Interpreter)

set(CROI_EDK2_DIR /usr/share/edk2 CACHE PATH "edk2 firmware images for QEMU")
set(CROI_ELF2EFI ${Python3_EXECUTABLE} -I ${CMAKE_SOURCE_DIR}/tools/elf2efi.py)
set(CROI_QEMU ${CMAKE_SOURCE_DIR}/tools/qemu.sh)

# Common ld.lld flags: static PIE, nothing implicit, unused sections dropped.
set(CROI_LINK_FLAGS
  -static -pie --no-dynamic-linker -ztext -znoexecstack
  -zmax-page-size=4096 -zseparate-loadable-segments
  --gc-sections --orphan-handling=error --build-id=sha1)

include(cmake/CroiImage.cmake)

add_subdirectory(lib/rt)
add_subdirectory(kernel)
add_subdirectory(boot)

# EFI system partition layout, served to QEMU as a virtual FAT drive.
set(CROI_ESP_DIR ${CMAKE_BINARY_DIR}/esp)
add_custom_target(esp ALL
  COMMAND ${CMAKE_COMMAND} -E make_directory ${CROI_ESP_DIR}/EFI/BOOT ${CROI_ESP_DIR}/croi
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          $<TARGET_PROPERTY:loader-efi,CROI_EFI_FILE> ${CROI_ESP_DIR}/EFI/BOOT/${CROI_EFI_BOOT_NAME}
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          $<TARGET_FILE:kernel> ${CROI_ESP_DIR}/croi/kernel.elf
  DEPENDS loader-efi kernel
  COMMENT "Assembling EFI system partition")

add_custom_target(run
  COMMAND ${CROI_QEMU} ${CROI_ARCH} ${CROI_ESP_DIR} ${CMAKE_BINARY_DIR}/qemu ${CROI_EDK2_DIR}
  DEPENDS esp USES_TERMINAL)

enable_testing()
add_test(NAME boot-smoke
  COMMAND ${CROI_QEMU} --test ${CROI_ARCH} ${CROI_ESP_DIR} ${CMAKE_BINARY_DIR}/qemu ${CROI_EDK2_DIR})
set_tests_properties(boot-smoke PROPERTIES
  TIMEOUT 120
  PASS_REGULAR_EXPRESSION "croi loader \\(${CROI_ARCH}\\)")
