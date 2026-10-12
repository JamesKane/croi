// Memory accounts (K15a; Todhchai ext 6, its F-109 budgets): croi's, Zircon
// has none. One budget per process covering CPU and GPU memory: anonymous
// VMOs charge pages as they commit, contiguous and device-local VMOs their
// whole size up front (never evicted). A commit past the limit fails: a
// syscall gets NO_MEMORY, a page fault is a fatal page fault (the
// process's exception). Kernel memory (handles, channels, stacks) and page
// tables aren't charged; pager VMOs aren't in v1 (the file service's page
// cache will charge the service).
//
// Syscalls (numbers in user/include/croi/syscall.h):
//   account_create(resource, limit, warning_percent | critical_percent << 32,
//                  uint32_t *out)                                          240
//     the MEMORY system resource (base 17) or root; a percent of 0 turns
//     that level off; a level is entered at its threshold and left below
//     80% of it.
//   account_set_limit(account, limit)                                      241
//     WRITE; never below what is charged (BAD_STATE).
//   account_bind_pressure_port(account, port, key)                         242
//     WRITE, port WRITE: a CROI_PKT_TYPE_MEMORY_PRESSURE packet at every
//     level change (coalesced while unread): payload[0] the limit, [1] the
//     bytes charged, [2] changes since last read, [3] the level.
//   process_set_account(process, account)                                  243
//     process WRITE and account CHARGE, before the process starts
//     (BAD_STATE after). A new process charges its creator's account
//     unless this replaces it; a process with none is unaccounted.
//
// What a process creates charges its account: vmo_create, vmo_create_child
// snapshots, vmo_create_contiguous. CROI_VMO_CHARGE_TO charges another
// account instead (a handle with CHARGE: a client's, sent to the service
// allocating for it): vmo_create's fourth argument, vmo_create_child's
// sixth (a physical or contiguous SLICE is then charged its whole size and
// never evicted: device-local memory), and for vmo_create_contiguous the
// account handle in bits 63:32 of the alignment argument (no option bit).
// A VMO keeps the account it was charged to wherever its handles go.
// Launchers pass a process its own account (INSPECT, WRITE) as
// CROI_PA_MEMORY_ACCOUNT (processargs.h) so it can bind its port.

#pragma once
#include <stdint.h>

enum : uint32_t {
  CROI_OBJ_TYPE_MEMORY_ACCOUNT = 49,   // croi's
  CROI_RIGHT_CHARGE = 1u << 25,        // croi's: VMOs may be charged to it
  CROI_VMO_CHARGE_TO = 1u << 30,       // vmo_create / vmo_create_child option
  CROI_INFO_MEMORY_ACCOUNT = 0x10003,  // croi_info_memory_account_t (INSPECT)
  CROI_PKT_TYPE_MEMORY_PRESSURE = 0x81,
};

enum : uint32_t {
  CROI_MEMORY_LEVEL_NORMAL = 0,
  CROI_MEMORY_LEVEL_WARNING = 1,
  CROI_MEMORY_LEVEL_CRITICAL = 2,
};

typedef struct {
  uint64_t limit;
  uint64_t charged;
  uint64_t warning_bytes;   // 0: no warning level
  uint64_t critical_bytes;  // 0: no critical level
  uint32_t level;           // CROI_MEMORY_LEVEL_*
  uint32_t padding;
  uint64_t pressure_events; // entries into pressure from normal
} croi_info_memory_account_t;
