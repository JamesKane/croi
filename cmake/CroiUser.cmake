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

# User programs (K8a): ELF executables linked at 0x1000000 with the user
# runtime (user/lib/runtime: entry and processargs, stdout over debuglog,
# the heap; lib/rt's mem*, stack guard and 128-bit division), from C
# and/or Embedded Swift sources. The kernel loads them (ProgramLoader),
# userboot from bootfs (K8b).
set(CROI_USER_COMMON_CFLAGS --target=${CROI_CLANG_TRIPLE} ${CROI_USER_CFLAGS} -std=c23 -O2 -ffreestanding
    -fno-omit-frame-pointer -ffunction-sections -fdata-sections -fno-pic -fno-pie
    -I${PROJECT_SOURCE_DIR}/user/include -I${PROJECT_SOURCE_DIR}/kernel/include)

# croi_user_runtime(): builds ${CROI_USER_RUNTIME} once per tree.
function(croi_user_runtime)
  set(_dir ${CMAKE_BINARY_DIR}/user-runtime)
  set(_sources
    ${PROJECT_SOURCE_DIR}/user/lib/runtime/start.c
    ${PROJECT_SOURCE_DIR}/user/lib/runtime/stdout.c
    ${PROJECT_SOURCE_DIR}/user/lib/runtime/malloc.c
    ${PROJECT_SOURCE_DIR}/user/lib/runtime/timing.c
    ${PROJECT_SOURCE_DIR}/lib/rt/string.c
    ${PROJECT_SOURCE_DIR}/lib/rt/int128.c
    ${PROJECT_SOURCE_DIR}/lib/rt/stack_protector.c)
  set(_objects)
  set(_commands)
  foreach(_source ${_sources})
    get_filename_component(_name ${_source} NAME_WE)
    set(_object ${_dir}/${_name}.o)
    set(_protect -fstack-protector-strong)
    if(_name STREQUAL stack_protector)
      set(_protect -fno-stack-protector)
    endif()
    list(APPEND _commands COMMAND ${CMAKE_C_COMPILER} ${CROI_USER_COMMON_CFLAGS} ${_protect} -c ${_source} -o ${_object})
    list(APPEND _objects ${_object})
  endforeach()
  set(CROI_USER_RUNTIME ${_dir}/libcroi-runtime.a PARENT_SCOPE)
  add_custom_command(OUTPUT ${_dir}/libcroi-runtime.a
    COMMAND ${CMAKE_COMMAND} -E make_directory ${_dir}
    ${_commands}
    COMMAND ${CMAKE_COMMAND} -E rm -f ${_dir}/libcroi-runtime.a
    COMMAND ${CMAKE_AR} rcs ${_dir}/libcroi-runtime.a ${_objects}
    DEPENDS ${_sources} ${PROJECT_SOURCE_DIR}/user/include/croi/runtime.h
            ${PROJECT_SOURCE_DIR}/user/include/croi/syscall.h
    COMMENT "Building the user runtime")
endfunction()

#   croi_user_program(<out.elf> [SOURCES <c>...] [SWIFT <swift>...] [STACK <bytes>])
function(croi_user_program output)
  cmake_parse_arguments(U "" "STACK" "SOURCES;SWIFT" ${ARGN})
  if(NOT U_STACK)
    set(U_STACK 262144)
  endif()
  get_filename_component(_name ${output} NAME_WE)
  set(_dir ${CMAKE_CURRENT_BINARY_DIR}/${_name}.dir)
  set(_objects)
  set(_commands)
  foreach(_source ${U_SOURCES})
    get_filename_component(_base ${_source} NAME_WE)
    list(APPEND _commands COMMAND ${CMAKE_C_COMPILER} ${CROI_USER_COMMON_CFLAGS} -fstack-protector-strong
                                  -c ${_source} -o ${_dir}/${_base}.o)
    list(APPEND _objects ${_dir}/${_base}.o)
  endforeach()
  if(U_SWIFT)
    # The user-mode flags (not the kernel's -mno-sse and friends); C
    # declarations come from user/include/module.modulemap (CroiRuntime).
    set(_xcc)
    foreach(_f ${CROI_USER_CFLAGS} -std=c23 -fno-omit-frame-pointer -I${PROJECT_SOURCE_DIR}/user/include
               -I${PROJECT_SOURCE_DIR}/kernel/include)
      list(APPEND _xcc -Xcc ${_f})
    endforeach()
    list(APPEND _commands COMMAND ${CMAKE_Swift_COMPILER} -target ${CROI_SWIFT_TRIPLE}
         -enable-experimental-feature Embedded -enable-experimental-feature Lifetimes
         -parse-as-library -strict-memory-safety -Werror StrictMemorySafety -wmo -Osize
         -Xfrontend -function-sections -module-name ${_name} ${_xcc}
         -c ${U_SWIFT} -o ${_dir}/${_name}-swift.o)
    list(APPEND _objects ${_dir}/${_name}-swift.o)
  endif()
  add_custom_command(OUTPUT ${output}
    COMMAND ${CMAKE_COMMAND} -E make_directory ${_dir}
    ${_commands}
    COMMAND ${CMAKE_LINKER} -static -e _start --image-base=0x1000000 -zseparate-loadable-segments
            -zmax-page-size=4096 -znoexecstack -zstack-size=${U_STACK} --gc-sections --build-id=sha1
            ${_objects} ${CROI_USER_RUNTIME} -o ${output}
    DEPENDS ${U_SOURCES} ${U_SWIFT} ${CROI_USER_RUNTIME} ${PROJECT_SOURCE_DIR}/user/include/module.modulemap
    COMMENT "Building user program ${_name}")
endfunction()
