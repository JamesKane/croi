// Whether timing means anything here (benchmarks, bin/m2's budgets): true
// on hardware or under KVM, false under QEMU's TCG, the same rule as the
// kernel's trace self-test (TraceSelfTest.enforcesCost). C because CPUID
// is an instruction Swift can't issue.

#include <croi/runtime.h>

bool croi_timing_is_real(void) {
#if defined(__x86_64__)
  uint32_t a, b, c, d;
  __asm__ volatile("cpuid" : "=a"(a), "=b"(b), "=c"(c), "=d"(d) : "a"(0x40000000), "c"(0));
  // "TCGTCGTCGTCG" in EBX, ECX, EDX.
  return !(b == 0x54474354 && c == 0x43544743 && d == 0x47435447);
#else
  return false;  // only QEMU's TCG runs these today
#endif
}
