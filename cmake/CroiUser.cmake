# User-mode binaries (K6c's kernel/user split): built with the user flag
# set (CROI_USER_CFLAGS from cmake/arch), not the kernel's, by the same
# clang, into flat binaries the kernel includes (.incbin). K8's loader will
# take ELF files instead.
#
#   croi_user_binary(<out.bin> SOURCES ... LINKER_SCRIPT <ld> [PIC] [INCLUDES ...])
function(croi_user_binary output)
  cmake_parse_arguments(U "PIC" "LINKER_SCRIPT" "SOURCES;INCLUDES" ${ARGN})
  get_filename_component(_name ${output} NAME_WE)
  set(_elf ${CMAKE_CURRENT_BINARY_DIR}/${_name}.elf)
  set(_code -fno-pic -fno-pie -Wl,--no-pie)
  if(U_PIC)
    # Position independent without relocations: PIE code, hidden symbols,
    # linked statically at 0 (everything is PC-relative).
    set(_code -fPIE -fvisibility=hidden -Wl,--no-pie)
  endif()
  set(_includes -I${PROJECT_SOURCE_DIR}/user/include)
  foreach(_i ${U_INCLUDES})
    list(APPEND _includes -I${_i})
  endforeach()
  add_custom_command(OUTPUT ${output}
    COMMAND ${CMAKE_C_COMPILER} --target=${CROI_CLANG_TRIPLE} ${CROI_USER_CFLAGS} -std=c23 -O2 -fno-omit-frame-pointer -ffreestanding
            -fno-stack-protector -fno-builtin -nostdlib -static -fuse-ld=lld ${_code}
            -Wl,-T,${U_LINKER_SCRIPT} ${_includes} ${U_SOURCES} -o ${_elf}
    COMMAND ${CMAKE_OBJCOPY} -O binary ${_elf} ${output}
    DEPENDS ${U_SOURCES} ${U_LINKER_SCRIPT}
    COMMENT "Building user binary ${_name}")
endfunction()
