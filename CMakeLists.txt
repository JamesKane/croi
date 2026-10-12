cmake_minimum_required(VERSION 3.29)

if(NOT CMAKE_TOOLCHAIN_FILE)
  message(FATAL_ERROR "Configure with a preset, e.g. `cmake --preset amd64`")
endif()

project(croi LANGUAGES C ASM Swift)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

find_package(Python3 3.10 REQUIRED COMPONENTS Interpreter)

set(CROI_EDK2_DIR /usr/share/edk2 CACHE PATH "edk2 firmware images for QEMU")
set(CROI_CMDLINE "croi.test=1" CACHE STRING "Kernel command line written to the ESP (\\croi\\cmdline)")
set(CROI_USERBOOT_NEXT "bin/m2" CACHE STRING "The bootfs program userboot starts (userboot.next=)")
set(CROI_USERBOOT_SHUTDOWN "poweroff" CACHE STRING
    "What userboot does once that program exits (userboot.shutdown=: poweroff, reboot, or empty to idle)")
if(CROI_USERBOOT_SHUTDOWN)
  set(_shutdown " userboot.shutdown=${CROI_USERBOOT_SHUTDOWN}")
endif()
set(CROI_ELF2EFI ${Python3_EXECUTABLE} -I ${CMAKE_SOURCE_DIR}/tools/elf2efi.py)
set(CROI_QEMU ${CMAKE_SOURCE_DIR}/tools/qemu.sh)

# Common ld.lld flags: static PIE, nothing implicit, unused sections dropped.
set(CROI_LINK_FLAGS
  -static -pie --no-dynamic-linker -ztext -znoexecstack
  -zmax-page-size=4096 -zseparate-loadable-segments
  --gc-sections --orphan-handling=error --build-id=sha1)

include(cmake/CroiImage.cmake)

add_subdirectory(lib/rt)
add_subdirectory(lib/handoff)
add_subdirectory(lib/fmt)
add_subdirectory(lib/pagetables)
add_subdirectory(lib/elf)
add_subdirectory(kernel)
add_subdirectory(boot)

# EFI system partition layout, served to QEMU as a virtual FAT drive.
set(CROI_ESP_DIR ${CMAKE_BINARY_DIR}/esp)
file(CONFIGURE OUTPUT ${CMAKE_BINARY_DIR}/cmdline
     CONTENT "${CROI_CMDLINE} userboot.next=${CROI_USERBOOT_NEXT}${_shutdown}\n")
add_custom_target(esp ALL
  COMMAND ${CMAKE_COMMAND} -E make_directory ${CROI_ESP_DIR}/EFI/BOOT ${CROI_ESP_DIR}/croi
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          $<TARGET_PROPERTY:loader-efi,CROI_EFI_FILE> ${CROI_ESP_DIR}/EFI/BOOT/${CROI_EFI_BOOT_NAME}
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          $<TARGET_FILE:kernel> ${CROI_ESP_DIR}/croi/kernel.elf
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          ${CMAKE_BINARY_DIR}/cmdline ${CMAKE_BINARY_DIR}/bootfs.img ${CROI_ESP_DIR}/croi/
  DEPENDS loader-efi kernel bootfs
  COMMENT "Assembling EFI system partition")

add_custom_target(run
  COMMAND ${CROI_QEMU} ${CROI_ARCH} ${CROI_ESP_DIR} ${CMAKE_BINARY_DIR}/qemu ${CROI_EDK2_DIR}
  DEPENDS esp USES_TERMINAL)

enable_testing()
# Boot tests wait for userboot to report that the program it started from
# bootfs exited cleanly (userboot starts after the kernel's self-tests and
# "boot complete"); with userboot.shutdown= (K10e) QEMU must then exit by
# itself (--exits), except where the run is inspected at that point.
set(CROI_BOOT_DONE "userboot: ${CROI_USERBOOT_NEXT} exited with 0")
if(CROI_USERBOOT_SHUTDOWN)
  set(CROI_EXITS --exits)
endif()
# Boots through the loader into the kernel, which reports and idles; then
# checks the pattern the kernel drew on the framebuffer.
set(_fb_dump ${CMAKE_BINARY_DIR}/qemu/framebuffer.ppm)
add_test(NAME boot-smoke
  COMMAND ${CROI_QEMU} --test "${CROI_BOOT_DONE}" --screendump ${_fb_dump}
          ${CROI_ARCH} ${CROI_ESP_DIR} ${CMAKE_BINARY_DIR}/qemu ${CROI_EDK2_DIR})
set_tests_properties(boot-smoke PROPERTIES TIMEOUT 120 FIXTURES_SETUP framebuffer)
add_test(NAME framebuffer-pixels
  COMMAND ${Python3_EXECUTABLE} -I ${CMAKE_SOURCE_DIR}/tools/check-pixels.py ${_fb_dump}
          0,0,16,48,96 40,30,240,192,32 100,100,16,48,96)
set_tests_properties(framebuffer-pixels PROPERTIES FIXTURES_REQUIRED framebuffer)

if(CROI_ARCH STREQUAL amd64)
  # No TSC-deadline mode: timers fall back to local APIC one-shot mode.
  add_test(NAME boot-smoke-apic-oneshot
    COMMAND ${CROI_QEMU} --test "${CROI_BOOT_DONE}" ${CROI_EXITS}
            ${CROI_ARCH} ${CROI_ESP_DIR} ${CMAKE_BINARY_DIR}/qemu ${CROI_EDK2_DIR}
            -cpu max,-tsc-deadline)
  set_tests_properties(boot-smoke-apic-oneshot PROPERTIES TIMEOUT 120)

  # AMD-Vi instead of VT-d (QEMU takes one IOMMU at a time): the IOMMU
  # self-test's line, which a skipped test wouldn't print (K12b).
  add_test(NAME boot-amd-iommu
    COMMAND ${CROI_QEMU} --iommu amd --test "iommu:  AMD-Vi:"
            ${CROI_ARCH} ${CROI_ESP_DIR} ${CMAKE_BINARY_DIR}/qemu-amd-iommu ${CROI_EDK2_DIR})
  set_tests_properties(boot-amd-iommu PROPERTIES TIMEOUT 120)
  # AMD-Vi with XT (K12g): 128-bit interrupt remapping entries, x2APIC
  # destinations (boot-amd-iommu has the 32-bit ones).
  add_test(NAME boot-amd-iommu-xt
    COMMAND ${CROI_QEMU} --iommu amd-xt --test "iommu:  AMD-Vi:"
            ${CROI_ARCH} ${CROI_ESP_DIR} ${CMAKE_BINARY_DIR}/qemu-amd-iommu-xt ${CROI_EDK2_DIR})
  set_tests_properties(boot-amd-iommu-xt PROPERTIES TIMEOUT 120)
endif()

if(CROI_ARCH STREQUAL rv64)
  # A hart without Svpbmt: memory types fall back to the platform's PMAs.
  add_test(NAME boot-smoke-no-svpbmt
    COMMAND ${CROI_QEMU} --test "${CROI_BOOT_DONE}" ${CROI_EXITS}
            ${CROI_ARCH} ${CROI_ESP_DIR} ${CMAKE_BINARY_DIR}/qemu ${CROI_EDK2_DIR}
            -cpu rv64)
  set_tests_properties(boot-smoke-no-svpbmt PROPERTIES TIMEOUT 120)
endif()

if(CROI_ARCH STREQUAL amd64 AND EXISTS /dev/kvm)
  # Under KVM timing is real: the trace self-test enforces its probe-cost
  # budget, as Todhchai's M2 budgets will be measured.
  add_test(NAME boot-smoke-kvm
    COMMAND ${CROI_QEMU} --test "${CROI_BOOT_DONE}" ${CROI_EXITS}
            ${CROI_ARCH} ${CROI_ESP_DIR} ${CMAKE_BINARY_DIR}/qemu ${CROI_EDK2_DIR}
            -accel kvm -cpu host)
  set_tests_properties(boot-smoke-kvm PROPERTIES TIMEOUT 120)
endif()

# Self-tests off, as Todhchai boots (K9f): user space must still come up.
set(_esp_lean ${CMAKE_BINARY_DIR}/esp-lean)
file(CONFIGURE OUTPUT ${CMAKE_BINARY_DIR}/cmdline-lean
     CONTENT "${CROI_CMDLINE} userboot.next=${CROI_USERBOOT_NEXT}${_shutdown} croi.selftest=off\n")
add_custom_target(esp-lean ALL
  COMMAND ${CMAKE_COMMAND} -E copy_directory ${CROI_ESP_DIR} ${_esp_lean}
  COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_BINARY_DIR}/cmdline-lean ${_esp_lean}/croi/cmdline
  DEPENDS esp)
add_test(NAME boot-lean
  COMMAND ${CROI_QEMU} --test "${CROI_BOOT_DONE}" ${CROI_EXITS}
          ${CROI_ARCH} ${_esp_lean} ${CMAKE_BINARY_DIR}/qemu-lean ${CROI_EDK2_DIR})
set_tests_properties(boot-lean PROPERTIES TIMEOUT 120)

if(CROI_ARCH STREQUAL arm64 OR CROI_ARCH STREQUAL rv64)
  # Guest time from instruction counts (QEMU -icount; sleep=off skips idle
  # time), so a loaded host can't stretch it: m2's timed paths run in a
  # time that doesn't depend on the machine. The RTCs follow guest time.
  # Not amd64 (QEMU 10.2 aborts: "Bad icount read" during interrupt
  # controller and clock setup), and not the full boots: icount runs the
  # CPUs in turn, a steady steal the deadline self-tests can't absorb.
  add_test(NAME boot-lean-icount
    COMMAND ${CROI_QEMU} --test "${CROI_BOOT_DONE}" ${CROI_EXITS}
            ${CROI_ARCH} ${_esp_lean} ${CMAKE_BINARY_DIR}/qemu-lean-icount ${CROI_EDK2_DIR}
            -icount shift=auto,sleep=off -rtc clock=vm)
  set_tests_properties(boot-lean-icount PROPERTIES TIMEOUT 120)
endif()

# Todhchai's --next test programs (sys-test, pthread-test, tls-test,
# services-test) from its newest bootfs, on this tree's loader and kernel,
# booted as td boot boots them (tools/todhchai-check.py): its td ci builds
# croi only from commits, and a root-filter change broke sys-test once with
# every test here passing. Skipped (77) where no Todhchai tree has a bootfs.
add_test(NAME todhchai-check
  COMMAND ${Python3_EXECUTABLE} -I ${CMAKE_SOURCE_DIR}/tools/todhchai-check.py ${CROI_ARCH}
          --build ${CMAKE_BINARY_DIR})
set_tests_properties(todhchai-check PROPERTIES TIMEOUT 600 SKIP_RETURN_CODE 77 LABELS todhchai)

# Reboot (K10e): the machine resets; -no-reboot makes QEMU exit on it.
set(_esp_reboot ${CMAKE_BINARY_DIR}/esp-reboot)
file(CONFIGURE OUTPUT ${CMAKE_BINARY_DIR}/cmdline-reboot
     CONTENT "${CROI_CMDLINE} userboot.next=${CROI_USERBOOT_NEXT} userboot.shutdown=reboot croi.selftest=off\n")
add_custom_target(esp-reboot ALL
  COMMAND ${CMAKE_COMMAND} -E copy_directory ${CROI_ESP_DIR} ${_esp_reboot}
  COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_BINARY_DIR}/cmdline-reboot ${_esp_reboot}/croi/cmdline
  DEPENDS esp)
add_test(NAME boot-reboot
  COMMAND ${CROI_QEMU} --test "croi kernel: rebooting" --exits
          ${CROI_ARCH} ${_esp_reboot} ${CMAKE_BINARY_DIR}/qemu-reboot ${CROI_EDK2_DIR})
set_tests_properties(boot-reboot PROPERTIES TIMEOUT 120)

# Out of memory (K14a): watermarks above all of RAM, so the watchdog finds
# the boot out of memory at once, evicts what it can, signals OOM and
# reboots (Zircon's default) after the timeout; -no-reboot exits QEMU.
set(_esp_oom ${CMAKE_BINARY_DIR}/esp-oom)
file(CONFIGURE OUTPUT ${CMAKE_BINARY_DIR}/cmdline-oom
     CONTENT "${CROI_CMDLINE} userboot.next=${CROI_USERBOOT_NEXT} croi.selftest=off croi.oom.outofmemory_mb=4000 croi.oom.critical_mb=4100 croi.oom.warning_mb=4200 croi.oom.reboot_timeout_ms=200\n")
add_custom_target(esp-oom ALL
  COMMAND ${CMAKE_COMMAND} -E copy_directory ${CROI_ESP_DIR} ${_esp_oom}
  COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_BINARY_DIR}/cmdline-oom ${_esp_oom}/croi/cmdline
  DEPENDS esp)
add_test(NAME boot-oom
  COMMAND ${CROI_QEMU} --test "out of memory; rebooting in 200 ms" --exits
          ${CROI_ARCH} ${_esp_oom} ${CMAKE_BINARY_DIR}/qemu-oom ${CROI_EDK2_DIR})
set_tests_properties(boot-oom PROPERTIES TIMEOUT 120)

if(CROI_ARCH STREQUAL amd64)
  # Interrupt remapping off (K12f): TCG boots remap every interrupt, so
  # this keeps the compatibility-format MSI and IOAPIC paths covered.
  set(_esp_intremap ${CMAKE_BINARY_DIR}/esp-intremap-off)
  file(CONFIGURE OUTPUT ${CMAKE_BINARY_DIR}/cmdline-intremap-off
       CONTENT "${CROI_CMDLINE} userboot.next=${CROI_USERBOOT_NEXT}${_shutdown} croi.intremap=off\n")
  add_custom_target(esp-intremap-off ALL
    COMMAND ${CMAKE_COMMAND} -E copy_directory ${CROI_ESP_DIR} ${_esp_intremap}
    COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_BINARY_DIR}/cmdline-intremap-off ${_esp_intremap}/croi/cmdline
    DEPENDS esp)
  add_test(NAME boot-intremap-off
    COMMAND ${CROI_QEMU} --test "${CROI_BOOT_DONE}" ${CROI_EXITS}
            ${CROI_ARCH} ${_esp_intremap} ${CMAKE_BINARY_DIR}/qemu-intremap-off ${CROI_EDK2_DIR})
  set_tests_properties(boot-intremap-off PROPERTIES TIMEOUT 180)
endif()

if(CROI_ARCH STREQUAL rv64)
  # The RISC-V IOMMU without MSI_FLAT: base device contexts in a 2-level
  # directory (the default boot has extended ones in 3 levels; K12e), and
  # with AIA, a claimed device's MSIs through identity-mapped interrupt
  # files alone (no MSI page table; K12j).
  add_test(NAME boot-riscv-iommu-base
    COMMAND ${CROI_QEMU} --iommu base --aia --test "iommu:  RISC-V IOMMU:"
            ${CROI_ARCH} ${CROI_ESP_DIR} ${CMAKE_BINARY_DIR}/qemu-riscv-iommu ${CROI_EDK2_DIR})
  set_tests_properties(boot-riscv-iommu-base PROPERTIES TIMEOUT 180)
  # AIA (K12i): the APLIC and IMSICs instead of the PLIC; the whole boot
  # test, wired interrupts through the APLIC and MSIs through the IMSICs.
  add_test(NAME boot-aia
    COMMAND ${CROI_QEMU} --aia --test "${CROI_BOOT_DONE}" ${CROI_EXITS}
            ${CROI_ARCH} ${CROI_ESP_DIR} ${CMAKE_BINARY_DIR}/qemu-aia ${CROI_EDK2_DIR})
  set_tests_properties(boot-aia PROPERTIES TIMEOUT 240)
endif()

if(CROI_ARCH STREQUAL arm64)
  # The DBG2 console path (QEMU's SPCR can't be turned off): an ESP whose
  # command line makes the loader try DBG2 first.
  set(_esp_dbg2 ${CMAKE_BINARY_DIR}/esp-dbg2)
  add_custom_target(esp-dbg2 ALL
    COMMAND ${CMAKE_COMMAND} -E copy_directory ${CROI_ESP_DIR} ${_esp_dbg2}
    COMMAND ${CMAKE_COMMAND} -E echo "loader.console=dbg2" > ${_esp_dbg2}/croi/cmdline
    DEPENDS esp)
  add_test(NAME boot-dbg2-console
    COMMAND ${CROI_QEMU} --test "at 0x9000000 (DBG2)"
            ${CROI_ARCH} ${_esp_dbg2} ${CMAKE_BINARY_DIR}/qemu ${CROI_EDK2_DIR})
  set_tests_properties(boot-dbg2-console PROPERTIES TIMEOUT 120)

  # Firmware at EL2 with a GICv3: the loader must drop to EL1.
  add_test(NAME boot-smoke-el2
    COMMAND ${CROI_QEMU} --test "${CROI_BOOT_DONE}" ${CROI_EXITS}
            ${CROI_ARCH} ${CROI_ESP_DIR} ${CMAKE_BINARY_DIR}/qemu-el2 ${CROI_EDK2_DIR}
            -machine virtualization=on,gic-version=3)
  set_tests_properties(boot-smoke-el2 PROPERTIES TIMEOUT 120)
endif()
