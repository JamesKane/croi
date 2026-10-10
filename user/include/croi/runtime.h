// The croi user runtime (user/lib/runtime): what every user program, C or
// Embedded Swift, links against until Todhchai's libsys takes over for its
// tier 0 services. `_start` reads the bootstrap message (processargs.h),
// keeps its handles, and calls `main(argc, argv)`; returning from main
// exits the process. stdout (putchar, croi_write) goes to the debuglog
// handed over as fd 1, else to debug_write.

#pragma once

#include <stddef.h>
#include <stdint.h>

#include "syscall.h"
#include "processargs.h"

// Takes the startup handle with this info word (croi_pa_hnd(type, arg)):
// 0 if there was none or it was already taken.
uint32_t croi_take_startup_handle(uint32_t info);

// Handles the runtime keeps (0 if not handed over).
uint32_t croi_process_self(void);
uint32_t croi_vmar_root_self(void);

// The vDSO's base address (the third start argument).
uint64_t croi_vdso_base(void);

// The environment strings from the bootstrap message.
int croi_environ_count(void);
const char *croi_environ(int index);

// Writes to stdout (one debuglog record per line).
void croi_write(const char *text, size_t length);
void croi_flush(void);

// Whether timings are real (hardware or KVM), not QEMU TCG's.
bool croi_timing_is_real(void);

// Ends the process (flushing stdout).
[[noreturn]] void croi_exit(int64_t code);

// The C library floor the compilers and the Embedded Swift runtime call.
int putchar(int c);
int posix_memalign(void **pointer, size_t alignment, size_t size);
void *malloc(size_t size);
void free(void *pointer);
void *memset(void *destination, int value, size_t count);
void *memcpy(void *restrict destination, const void *restrict source, size_t count);
void *memmove(void *destination, const void *source, size_t count);
int memcmp(const void *a, const void *b, size_t count);
size_t strlen(const char *text);
