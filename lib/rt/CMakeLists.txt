# Freestanding runtime the compilers expect to exist: mem* and the stack
# protector hooks. Linked into both the loader and the kernel.
add_library(croi-rt STATIC string.c stack_protector.c)
set_source_files_properties(stack_protector.c PROPERTIES COMPILE_OPTIONS -fno-stack-protector)
