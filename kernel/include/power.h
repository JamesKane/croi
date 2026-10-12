// Power control (K10e): the ABI shared by the kernel and user space
// (user/include/croi/syscall.h includes it). Zircon's system_powerctl
// (zircon/syscalls/system.h): commands, and zx_system_powerctl_arg_t's
// layout, under the power system resource (CROI_RSRC_SYSTEM_POWER_BASE)
// or the root resource.
//
// SHUTDOWN and REBOOT stop every other CPU, wait (up to 100 ms) for the
// debuglog to reach the console, and turn the machine off or reset it;
// they return only on failure. arm64: PSCI SYSTEM_OFF / SYSTEM_RESET.
// rv64: SBI SRST (cold reboot). amd64 reboots through the FADT's reset
// register (then port 0xCF9, then the 8042); it shuts down only with
// ACPI_TRANSITION_S_STATE to S5, whose sleep-type values come from the
// DSDT's \_S5 object, which only user space's AML interpreter can read
// (SHUTDOWN is NOT_SUPPORTED there). Other S-states (suspend) and the CPU
// hotplug, power-limit and bootloader/recovery commands are NOT_SUPPORTED.
#pragma once
#include <stdint.h>

enum : uint32_t {
  CROI_SYSTEM_POWERCTL_ENABLE_ALL_CPUS = 1,
  CROI_SYSTEM_POWERCTL_DISABLE_ALL_CPUS_BUT_PRIMARY = 2,
  CROI_SYSTEM_POWERCTL_ACPI_TRANSITION_S_STATE = 3,  // amd64; arg.acpi_transition_s_state
  CROI_SYSTEM_POWERCTL_X86_SET_PKG_PL1 = 4,
  CROI_SYSTEM_POWERCTL_REBOOT = 5,
  CROI_SYSTEM_POWERCTL_REBOOT_BOOTLOADER = 6,
  CROI_SYSTEM_POWERCTL_REBOOT_RECOVERY = 7,
  CROI_SYSTEM_POWERCTL_SHUTDOWN = 8,
  CROI_SYSTEM_POWERCTL_ACK_KERNEL_INITIATED_REBOOT = 9,
};

// zx_system_powerctl_arg_t: 12 bytes, 4-aligned.
typedef struct {
  union {
    struct {
      uint8_t target_s_state;  // 5 (soft off) is the only one croi enters
      uint8_t sleep_type_a;    // \_S5's first value: PM1a's SLP_TYP (0-7)
      uint8_t sleep_type_b;    // its second: PM1b's
    } acpi_transition_s_state;
    struct {
      uint32_t power_limit;
      uint32_t time_window;
      uint8_t clamp;
      uint8_t enable;
    } x86_power_limit;
  };
} croi_system_powerctl_arg_t;

// Idle states (K15c; Todhchai ext 11, its item 11: deadline-aware idle).
// croi's: the power service, holding the POWER system resource (base 5)
// or root, installs each CPU's table from what devmgr evaluated (_CST,
// _LPI): cpu_set_idle_states(resource, cpu, const croi_idle_state_t *,
// count) = syscall 245, at most CROI_IDLE_STATES_MAX states, exit latency
// non-decreasing (INVALID_ARGS); a method the CPU lacks NOT_SUPPORTED;
// count 0 back to halt only. A new table replaces the old at once.
// At each idle the kernel enters the deepest state whose target residency
// fits before the CPU's next timer and whose exit latency fits its
// wake-latency bound (the tightest admitted deadline on it, or of an
// interrupt routed to it with a deadline profile); deterministic, no
// prediction. States flagged TIMER_STOPS or CONTEXT_LOST are kept but not
// entered yet (no wake timer, no resume path): `skipped` counts them.
enum : uint32_t {
  CROI_IDLE_METHOD_HALT = 0,   // hlt / wfi with its own latency figures
  CROI_IDLE_METHOD_MWAIT = 1,  // amd64: param = the MWAIT hint (_CST FFixedHW)
  CROI_IDLE_METHOD_PSCI = 2,   // arm64: param = CPU_SUSPEND's power_state (_LPI)
  CROI_IDLE_FLAG_TIMER_STOPS = 1u << 0,
  CROI_IDLE_FLAG_CONTEXT_LOST = 1u << 1,
  CROI_IDLE_STATES_MAX = 8,
  CROI_IDLE_STATE_DEFAULT = 0xFFFFFFFFu,  // stats: the plain halt
  CROI_INFO_CPU_IDLE_STATES = 0x10005,    // croi_idle_state_stats_t[] (INFO resource or root)
};

typedef struct {
  uint64_t exit_latency_ns;
  uint64_t target_residency_ns;
  uint64_t param;
  uint32_t method;  // CROI_IDLE_METHOD_*
  uint32_t flags;   // CROI_IDLE_FLAG_*
} croi_idle_state_t;

typedef struct {
  uint32_t cpu;
  uint32_t state;         // the table index, or CROI_IDLE_STATE_DEFAULT
  uint64_t entries;
  uint64_t residency_ns;
  uint64_t demoted;       // idles that left this state for a shallower one: its exit latency was over the bound
  uint64_t skipped;       // idles it fitted but couldn't be entered (its flags)
} croi_idle_state_stats_t;
