// The debuglog (K8a): the ABI shared by the kernel and user space
// (user/include/croi/syscall.h includes it). Zircon's layouts and values
// (zircon/syscalls/log.h).
#pragma once
#include <stdint.h>
#include "resource.h"  // CROI_RSRC_SYSTEM_DEBUGLOG_BASE gates readable debuglogs

enum : uint32_t {
  CROI_LOG_RECORD_MAX = 256,      // a whole record, header included
  CROI_LOG_RECORD_DATA_MAX = 216, // CROI_LOG_RECORD_MAX less the header
  // debuglog_create options.
  CROI_LOG_FLAG_READABLE = 0x40000000,
  // debuglog_write options (stored in the record's flags).
  CROI_LOG_LOCAL = 0x10,
  CROI_LOG_FLAGS_MASK = 0x10,
  // Severities.
  CROI_LOG_TRACE = 0x10,
  CROI_LOG_DEBUG = 0x20,
  CROI_LOG_INFO = 0x30,
  CROI_LOG_WARNING = 0x40,
  CROI_LOG_ERROR = 0x50,
  CROI_LOG_FATAL = 0x60,
};

// zx_log_record_t: what debuglog_read copies out (header, then datalen
// bytes of text, no terminator).
typedef struct {
  uint64_t sequence;   // one more than the record before it
  uint8_t padding1[4];
  uint16_t datalen;
  uint8_t severity;
  uint8_t flags;
  int64_t timestamp;   // monotonic ns
  uint64_t pid;        // the writer's process koid (0: the kernel)
  uint64_t tid;        // and thread koid
} croi_log_record_t;

static_assert(sizeof(croi_log_record_t) + CROI_LOG_RECORD_DATA_MAX == CROI_LOG_RECORD_MAX);

// object_get_info(log, CROI_INFO_DEBUGLOG) (croi's, K10d; any log handle):
// how far the console dumper has got, for writers that pace themselves to
// it (a trace export through the debuglog). Records are numbered from 0
// in write order; `printed` counts those the dumper has finished with
// (printed, or overwritten before it got to them).
enum : uint32_t {
  CROI_INFO_DEBUGLOG = 0x10002,
};

typedef struct {
  uint64_t written;  // records written so far (the next record's number)
  uint64_t printed;
} croi_info_debuglog_t;

static_assert(sizeof(croi_info_debuglog_t) == 16);
