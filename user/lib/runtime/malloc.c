// The heap for croi user programs (K8a): posix_memalign/malloc/free, the
// symbols the Embedded Swift runtime allocates through. C because those
// are C symbols the runtime needs before any Swift runs. Requests up to
// 2 KiB come from power-of-two size classes carved from 64 KiB VMO chunks
// mapped into the root VMAR; larger ones get a mapping of their own. Every
// block has a 16-byte header just before it. One lock, no per-thread
// caches: a test runtime, until Todhchai's libsys.

#include <croi/runtime.h>

enum {
  HEADER = 16,
  MIN_SHIFT = 4,      // 16 bytes
  MAX_SHIFT = 11,     // 2 KiB
  CLASSES = MAX_SHIFT - MIN_SHIFT + 1,
  CHUNK = 64 * 1024,
  PAGE = 4096,
  LARGE = 0xFF,
};

typedef struct {
  uint32_t class_index;  // LARGE: a mapping of its own
  uint32_t back;         // bytes from the block's start to the header
  uint64_t mapped;       // LARGE: the mapping's size
} header_t;

typedef struct free_block {
  struct free_block *next;
} free_block_t;

static free_block_t *free_lists[CLASSES];
static char *chunk_next;
static char *chunk_end;
static volatile int busy;

static void lock(void) {
  while (__atomic_exchange_n(&busy, 1, __ATOMIC_ACQUIRE)) {}
}

static void unlock(void) { __atomic_store_n(&busy, 0, __ATOMIC_RELEASE); }

// Fresh zeroed pages mapped read/write, or 0.
static char *map(size_t size) {
  uint32_t vmar = croi_vmar_root_self();
  if (vmar == 0) return 0;
  uint32_t vmo = 0;
  if (croi_syscall(CROI_SYS_VMO_CREATE, size, 0, (uint64_t)&vmo, 0, 0) != 0) return 0;
  uint64_t address = 0;
  int64_t status = croi_syscall6(CROI_SYS_VMAR_MAP,
                                 vmar | (uint64_t)(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) << 32, 0, vmo, 0, size,
                                 (uint64_t)&address);
  croi_syscall(CROI_SYS_HANDLE_CLOSE, vmo, 0, 0, 0, 0);  // the mapping keeps it
  return status == 0 ? (char *)address : 0;
}

static unsigned class_for(size_t size) {
  unsigned shift = MIN_SHIFT;
  while (((size_t)1 << shift) < size) shift++;
  return shift - MIN_SHIFT;
}

// A block of the class's size (header included), or 0.
static char *take(unsigned index) {
  size_t size = (size_t)1 << (index + MIN_SHIFT);
  if (free_lists[index] != 0) {
    free_block_t *block = free_lists[index];
    free_lists[index] = block->next;
    return (char *)block;
  }
  if ((size_t)(chunk_end - chunk_next) < size) {
    char *chunk = map(CHUNK);
    if (chunk == 0) return 0;
    chunk_next = chunk;
    chunk_end = chunk + CHUNK;
  }
  char *block = chunk_next;
  chunk_next += size;
  return block;
}

int posix_memalign(void **pointer, size_t alignment, size_t size) {
  if (alignment < HEADER) alignment = HEADER;
  if ((alignment & (alignment - 1)) != 0 || alignment > PAGE) return 22;  // EINVAL
  if (size == 0) size = 1;
  size_t needed = size + HEADER + (alignment - HEADER);
  if (needed < size) return 12;  // ENOMEM
  char *block;
  header_t header = {0};
  if (needed <= ((size_t)1 << MAX_SHIFT)) {
    header.class_index = class_for(needed);
    lock();
    block = take(header.class_index);
    unlock();
  } else {
    header.class_index = LARGE;
    header.mapped = (needed + PAGE - 1) & ~(size_t)(PAGE - 1);
    block = map(header.mapped);
  }
  if (block == 0) return 12;
  uintptr_t user = ((uintptr_t)block + HEADER + alignment - 1) & ~(uintptr_t)(alignment - 1);
  header.back = (uint32_t)(user - HEADER - (uintptr_t)block);
  memcpy((char *)user - HEADER, &header, sizeof header);
  *pointer = (void *)user;
  return 0;
}

void *malloc(size_t size) {
  void *pointer = 0;
  return posix_memalign(&pointer, HEADER, size) == 0 ? pointer : 0;
}

void free(void *pointer) {
  if (pointer == 0) return;
  header_t header;
  memcpy(&header, (char *)pointer - HEADER, sizeof header);
  char *block = (char *)pointer - HEADER - header.back;
  if (header.class_index == LARGE) {
    croi_syscall(CROI_SYS_VMAR_UNMAP, croi_vmar_root_self(), (uint64_t)block, header.mapped, 0, 0);
    return;
  }
  if (header.class_index >= CLASSES) __builtin_trap();  // not ours
  lock();
  free_block_t *node = (free_block_t *)block;
  node->next = free_lists[header.class_index];
  free_lists[header.class_index] = node;
  unlock();
}
