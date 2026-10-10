// stdout for croi user programs (K8a): line-buffered into debuglog records,
// or debug_write when no debuglog was handed over. C because putchar is
// the C symbol the Embedded Swift runtime prints through.

#include <croi/runtime.h>

static uint32_t log_handle;
static char line[CROI_LOG_RECORD_DATA_MAX];
static size_t used;
static volatile int busy;

void croi_runtime_stdout(uint32_t log) { log_handle = log; }

static void lock(void) {
  while (__atomic_exchange_n(&busy, 1, __ATOMIC_ACQUIRE)) {}
}

static void unlock(void) { __atomic_store_n(&busy, 0, __ATOMIC_RELEASE); }

static void flush_locked(void) {
  if (used == 0) return;
  if (log_handle != 0) {
    croi_syscall(CROI_SYS_DEBUGLOG_WRITE, log_handle, 0, (uint64_t)line, used, 0);
  } else {
    croi_syscall(CROI_SYS_DEBUG_WRITE, (uint64_t)line, used, 0, 0, 0);
  }
  used = 0;
}

static void put_locked(char c) {
  if (c == '\n') {
    flush_locked();
    return;
  }
  line[used++] = c;
  if (used == sizeof line) flush_locked();
}

void croi_write(const char *text, size_t length) {
  lock();
  for (size_t i = 0; i < length; i++) put_locked(text[i]);
  unlock();
}

void croi_flush(void) {
  lock();
  flush_locked();
  unlock();
}

int putchar(int c) {
  lock();
  put_locked((char)c);
  unlock();
  return c & 0xFF;
}

size_t strlen(const char *text) {
  size_t n = 0;
  while (text[n] != 0) n++;
  return n;
}
