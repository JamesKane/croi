# Freestanding runtime the compilers expect to exist: mem*, 128-bit division and the stack
# protector hooks. Linked into both the loader and the kernel.
add_library(croi-rt STATIC string.c stack_protector.c int128.c)
set_source_files_properties(stack_protector.c PROPERTIES COMPILE_OPTIONS -fno-stack-protector)
# K14q: landing pads in case anything branches here indirectly in the
# kernel's guarded text (hint-space: NOPs in the loader and without BTI).
if(CROI_ARCH STREQUAL "arm64")
  target_compile_options(croi-rt PRIVATE -mbranch-protection=bti)
endif()
