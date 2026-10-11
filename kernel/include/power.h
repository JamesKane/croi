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
