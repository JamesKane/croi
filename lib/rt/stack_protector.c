// Stack protector hooks referenced by -fstack-protector-strong (C) and by
// swiftc's default stack protection. The guard is a fixed value until there
// is an entropy source to seed it from.

#include <stdint.h>

[[gnu::visibility("default")]] uintptr_t __stack_chk_guard = (uintptr_t)0x595e9fbd94fda766ull;

[[noreturn, gnu::visibility("default")]] void __stack_chk_fail(void) {
  __builtin_trap();
}
