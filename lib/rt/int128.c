// 128-bit division helpers clang and swiftc emit calls to (normally from
// compiler-rt, which croi doesn't link). Swift's dividingFullWidth lowers
// to __udivti3. Shift-and-subtract only, so these can never be compiled
// back into calls to themselves; they are not on hot paths.

typedef unsigned __int128 u128;

static u128 divide(u128 n, u128 d, u128 *remainder) {
  if (d == 0) __builtin_trap();
  u128 quotient = 0;
  u128 rest = 0;
  for (int bit = 127; bit >= 0; bit--) {
    rest = (rest << 1) | ((n >> bit) & 1);
    if (rest >= d) {
      rest -= d;
      quotient |= (u128)1 << bit;
    }
  }
  if (remainder) *remainder = rest;
  return quotient;
}

[[gnu::visibility("default")]] u128 __udivti3(u128 n, u128 d) {
  return divide(n, d, nullptr);
}

[[gnu::visibility("default")]] u128 __umodti3(u128 n, u128 d) {
  u128 rest;
  divide(n, d, &rest);
  return rest;
}
