# UEFI loader: linked as an ELF static PIE at 0x1000, then converted to PE32+.

add_library(loader-swift OBJECT
  Loader/Acpi.swift
  Loader/Console.swift
  Loader/Firmware.swift
  Loader/KernelElf.swift
  Loader/KernelFile.swift
  Loader/LoaderError.swift
  Loader/Main.swift
  Loader/MemoryMap.swift
  Loader/PageTables.swift
  Loader/Physical.swift)
set_target_properties(loader-swift PROPERTIES Swift_MODULE_NAME Loader)
target_include_directories(loader-swift PRIVATE include)
target_link_libraries(loader-swift PRIVATE croi-fmt croi-handoff)

add_executable(loader entry.c arch/${CROI_ARCH}/enter.S)
target_include_directories(loader PRIVATE include)
target_link_libraries(loader PRIVATE loader-swift croi-rt)
set_target_properties(loader PROPERTIES OUTPUT_NAME loader.elf)
croi_image(loader ENTRY efi_main BASE 0x1000)

set(_efi ${CMAKE_CURRENT_BINARY_DIR}/loader.efi)
add_custom_command(OUTPUT ${_efi}
  COMMAND ${CROI_ELF2EFI} $<TARGET_FILE:loader> ${_efi}
  DEPENDS loader ${PROJECT_SOURCE_DIR}/tools/elf2efi.py
  COMMENT "Converting loader to PE32+")
add_custom_target(loader-efi ALL DEPENDS ${_efi})
set_target_properties(loader-efi PROPERTIES CROI_EFI_FILE ${_efi})
