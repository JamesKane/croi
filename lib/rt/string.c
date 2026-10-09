// Memory primitives that clang and swiftc emit calls to. These are C because
// they must exist before any Swift runs and must never be lowered back into
// calls to themselves; LLVM's loop-idiom pass skips functions with these names.
//
// Simple byte loops for now; per-arch fast paths can come later.

#include <stddef.h>

[[gnu::visibility("default")]] void *memcpy(void *restrict dst, const void *restrict src, size_t n) {
  unsigned char *d = dst;
  const unsigned char *s = src;
  while (n--) *d++ = *s++;
  return dst;
}

[[gnu::visibility("default")]] void *memmove(void *dst, const void *src, size_t n) {
  unsigned char *d = dst;
  const unsigned char *s = src;
  if (d < s) {
    while (n--) *d++ = *s++;
  } else {
    d += n;
    s += n;
    while (n--) *--d = *--s;
  }
  return dst;
}

[[gnu::visibility("default")]] void *memset(void *dst, int c, size_t n) {
  unsigned char *d = dst;
  while (n--) *d++ = (unsigned char)c;
  return dst;
}

[[gnu::visibility("default")]] int memcmp(const void *a, const void *b, size_t n) {
  const unsigned char *x = a, *y = b;
  for (; n; n--, x++, y++) {
    if (*x != *y) return *x - *y;
  }
  return 0;
}
