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
    ${PROJECT_SOURCE_DIR}/user/lib/runtime/image.c
    ${PROJECT_SOURCE_DIR}/lib/rt/string.c
    ${PROJECT_SOURCE_DIR}/lib/rt/int128.c
    ${PROJECT_SOURCE_DIR}/lib/rt/stack_protector.c)
  # Two flavors: fixed-address (ET_EXEC programs) and -fPIE (static PIEs,
  # K11b), libcroi-runtime.a and libcroi-runtime-pie.a.
  foreach(_flavor "" "-pie")
    set(_objects)
    set(_commands)
    set(_code)
    if(_flavor STREQUAL "-pie")
      set(_code -fPIE)
    endif()
    foreach(_source ${_sources})
      get_filename_component(_name ${_source} NAME_WE)
      set(_object ${_dir}/${_name}${_flavor}.o)
      set(_protect -fstack-protector-strong)
      if(_name STREQUAL stack_protector)
        set(_protect -fno-stack-protector)
      endif()
      list(APPEND _commands COMMAND ${CMAKE_C_COMPILER} ${CROI_USER_COMMON_CFLAGS} ${_code} ${_protect}
                                    -c ${_source} -o ${_object})
      list(APPEND _objects ${_object})
    endforeach()
    add_custom_command(OUTPUT ${_dir}/libcroi-runtime${_flavor}.a
      COMMAND ${CMAKE_COMMAND} -E make_directory ${_dir}
      ${_commands}
      COMMAND ${CMAKE_COMMAND} -E rm -f ${_dir}/libcroi-runtime${_flavor}.a
      COMMAND ${CMAKE_AR} rcs ${_dir}/libcroi-runtime${_flavor}.a ${_objects}
      DEPENDS ${_sources} ${PROJECT_SOURCE_DIR}/user/include/croi/runtime.h
              ${PROJECT_SOURCE_DIR}/user/include/croi/syscall.h
      COMMENT "Building the user runtime${_flavor}")
  endforeach()
  set(CROI_USER_RUNTIME ${_dir}/libcroi-runtime.a PARENT_SCOPE)
  set(CROI_USER_RUNTIME_PIE ${_dir}/libcroi-runtime-pie.a PARENT_SCOPE)
endfunction()

#   croi_user_program(<out.elf> [PIE] [EXPORT_DYNAMIC] [SOURCES <c>...] [SWIFT <swift>...] [STACK <bytes>])
function(croi_user_program output)
  cmake_parse_arguments(U "PIE;EXPORT_DYNAMIC" "STACK" "SOURCES;SWIFT" ${ARGN})
  # PIE: a static PIE (K11b), linked at 0, loaded at a random base by
  # croi's loaders, which apply its R_*_RELATIVE relocations.
  set(_cpie)
  set(_link -static --image-base=0x1000000)
  set(_runtime ${CROI_USER_RUNTIME})
  if(U_PIE)
    set(_cpie -fPIE)
    set(_link -static -pie --no-dynamic-linker -ztext)
    set(_runtime ${CROI_USER_RUNTIME_PIE})
  endif()
  if(NOT U_STACK)
    set(U_STACK 262144)
  endif()
  get_filename_component(_name ${output} NAME_WE)
  set(_dir ${CMAKE_CURRENT_BINARY_DIR}/${_name}.dir)
  # EXPORT_DYNAMIC: a dynamic section with no relocations (a program that
  # hosts dlopen'd libraries); the loaders take it as a symbol table.
  # (lld makes a dynamic section for a non-PIC executable only when a
  # shared object is linked: an empty one, --as-needed, so no DT_NEEDED.)
  set(_dynamic_commands)
  set(_dynamic_inputs)
  if(U_EXPORT_DYNAMIC)
    set(_link --image-base=0x1000000 --export-dynamic --no-dynamic-linker)
    set(_dynamic_commands
        COMMAND ${CMAKE_C_COMPILER} --target=${CROI_CLANG_TRIPLE} -c -x c /dev/null -o ${_dir}/empty.o
        COMMAND ${CMAKE_LINKER} -shared -soname=libempty.so ${_dir}/empty.o -o ${_dir}/libempty.so)
    set(_dynamic_inputs --as-needed ${_dir}/libempty.so)
  endif()
  set(_objects)
  set(_commands)
  foreach(_source ${U_SOURCES})
    get_filename_component(_base ${_source} NAME_WE)
    list(APPEND _commands COMMAND ${CMAKE_C_COMPILER} ${CROI_USER_COMMON_CFLAGS} ${_cpie} -fstack-protector-strong
                                  -c ${_source} -o ${_dir}/${_base}.o)
    list(APPEND _objects ${_dir}/${_base}.o)
  endforeach()
  if(U_SWIFT)
    # The user-mode flags (not the kernel's -mno-sse and friends); C
    # declarations come from user/include/module.modulemap (CroiRuntime).
    set(_xcc)
    foreach(_f ${CROI_USER_CFLAGS} ${_cpie} -std=c23 -fno-omit-frame-pointer -I${PROJECT_SOURCE_DIR}/user/include
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
    ${_dynamic_commands}
    COMMAND ${CMAKE_LINKER} ${_link} -e _start -zseparate-loadable-segments
            -zmax-page-size=4096 -znoexecstack -zstack-size=${U_STACK} --gc-sections --build-id=sha1
            ${_objects} ${_runtime} ${_dynamic_inputs} -o ${output}
    DEPENDS ${U_SOURCES} ${U_SWIFT} ${_runtime} ${PROJECT_SOURCE_DIR}/user/include/module.modulemap
    COMMENT "Building user program ${_name}")
endfunction()
