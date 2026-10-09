# Cross toolchain for croi: Embedded Swift 6.4 plus the clang/lld bundled
# with it. One build tree per architecture; CROI_ARCH picks which.
#
#   cmake --preset amd64        (see CMakePresets.json)
#
# CMake re-reads this file for every try_compile, so the cache variables we
# depend on are forwarded via CMAKE_TRY_COMPILE_PLATFORM_VARIABLES.

set(CROI_ARCH "" CACHE STRING "Target architecture: amd64, arm64 or rv64")
set(CROI_TOOLCHAIN_DIR "" CACHE PATH "Swift 6.4 toolchain root (contains usr/bin/swiftc)")
list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES CROI_ARCH CROI_TOOLCHAIN_DIR)

if(NOT CROI_ARCH MATCHES "^(amd64|arm64|rv64)$")
  message(FATAL_ERROR "CROI_ARCH must be amd64, arm64 or rv64 (got '${CROI_ARCH}')")
endif()

# Find the toolchain pinned by .swift-version via swiftly, unless given.
if(NOT CROI_TOOLCHAIN_DIR)
  execute_process(
    COMMAND swiftly use --print-location
    WORKING_DIRECTORY "${CMAKE_CURRENT_LIST_DIR}/.."
    OUTPUT_VARIABLE _croi_tc OUTPUT_STRIP_TRAILING_WHITESPACE
    RESULT_VARIABLE _croi_rc)
  if(NOT _croi_rc EQUAL 0 OR NOT EXISTS "${_croi_tc}/usr/bin/swiftc")
    message(FATAL_ERROR "Could not locate the Swift toolchain via swiftly; set CROI_TOOLCHAIN_DIR")
  endif()
  set(CROI_TOOLCHAIN_DIR "${_croi_tc}" CACHE PATH "" FORCE)
endif()
set(_bin "${CROI_TOOLCHAIN_DIR}/usr/bin")

set(CMAKE_SYSTEM_NAME Generic)
include("${CMAKE_CURRENT_LIST_DIR}/arch/${CROI_ARCH}.cmake")

set(CMAKE_C_COMPILER     "${_bin}/clang")
set(CMAKE_ASM_COMPILER   "${_bin}/clang")
set(CMAKE_Swift_COMPILER "${_bin}/swiftc")
set(CMAKE_LINKER         "${_bin}/ld.lld")
set(CMAKE_AR             "${_bin}/llvm-ar")
set(CMAKE_RANLIB         "${_bin}/llvm-ranlib")
set(CMAKE_OBJCOPY        "${_bin}/llvm-objcopy")
set(CMAKE_C_COMPILER_TARGET     "${CROI_CLANG_TRIPLE}")
set(CMAKE_ASM_COMPILER_TARGET   "${CROI_CLANG_TRIPLE}")
set(CMAKE_Swift_COMPILER_TARGET "${CROI_SWIFT_TRIPLE}")

# Nothing here can produce a hosted executable.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# Code generation shared by C, assembly and (via -Xcc) Swift: kernel-safe
# register usage, position independence, dead-code-strippable sections.
set(_cg -fPIE -fvisibility=hidden -ffunction-sections -fdata-sections
        -fno-omit-frame-pointer -fstack-protector-strong)
if(NOT DEFINED CROI_ARCH_SWIFT_CFLAGS)
  set(CROI_ARCH_SWIFT_CFLAGS ${CROI_ARCH_CFLAGS})
endif()
list(JOIN CROI_ARCH_CFLAGS " " _arch_str)
list(JOIN _cg " " _cg_str)
set(_cg_str "${_arch_str} ${_cg_str}")

set(CMAKE_C_FLAGS_INIT   "-std=c23 -ffreestanding -Wall -Wextra ${_cg_str}")
set(CMAKE_ASM_FLAGS_INIT "${_cg_str}")

# Swift 6.4: strict memory safety is enforced (every unsafe construct needs
# an explicit `unsafe`); Lifetimes enables Span-returning APIs; the
# PerformanceHints group flags hidden allocation and dynamic dispatch.
set(_swift -enable-experimental-feature Embedded -enable-experimental-feature Lifetimes
           -parse-as-library -strict-memory-safety -Werror StrictMemorySafety
           -Werror EmbeddedRestrictions -Wwarning PerformanceHints
           -enforce-exclusivity=unchecked -Xfrontend -function-sections -Xcc -std=c23)
foreach(_f IN LISTS CROI_ARCH_SWIFT_CFLAGS _cg)
  list(APPEND _swift -Xcc ${_f})
endforeach()
list(JOIN _swift " " CMAKE_Swift_FLAGS_INIT)
set(CMAKE_Swift_FLAGS_DEBUG_INIT "-Onone -g")
set(CMAKE_Swift_FLAGS_RELEASE_INIT "-Osize")
set(CMAKE_Swift_FLAGS_RELWITHDEBINFO_INIT "-Osize -g")

# Embedded Swift requires whole-module compilation.
set(CMAKE_Swift_COMPILATION_MODE wholemodule)

# Every image is linked by ld.lld directly with its own linker script.
set(CMAKE_C_LINK_EXECUTABLE "<CMAKE_LINKER> <LINK_FLAGS> <OBJECTS> -o <TARGET> <LINK_LIBRARIES>")
