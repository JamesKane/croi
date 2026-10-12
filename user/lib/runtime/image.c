// The program's own ELF image as loaded: where its PT_GNU_RELRO pages are
// and whether the loader made them read only. C because the ELF header's
// address is a linker-defined symbol (__ehdr_start), which Embedded Swift
// can't name.

#include <croi/runtime.h>

// lld: the ELF header, mapped with the first PT_LOAD (file offset 0).
extern const char __ehdr_start[] __attribute__((visibility("hidden")));

enum : uint32_t { PT_LOAD = 1, PT_GNU_RELRO = 0x6474E552 };

static uint64_t load_u64(const uint8_t *p) {
  uint64_t v;
  memcpy(&v, p, 8);
  return v;
}

static uint32_t load_u32(const uint8_t *p) {
  uint32_t v;
  memcpy(&v, p, 4);
  return v;
}

bool croi_relro(uint64_t *start, uint64_t *end) {
  const uint8_t *header = (const uint8_t *)__ehdr_start;
  uint64_t phoff = load_u64(header + 32);
  uint16_t phentsize, phnum;
  memcpy(&phentsize, header + 54, 2);
  memcpy(&phnum, header + 56, 2);
  // The load bias: where the header is less the link address of the
  // segment that starts at file offset 0 (0 for an ET_EXEC).
  uint64_t bias = 0, vaddr = 0, memsz = 0;
  bool based = false, found = false;
  for (uint16_t i = 0; i < phnum; i++) {
    const uint8_t *ph = header + phoff + (uint64_t)i * phentsize;
    uint32_t type = load_u32(ph);
    if (type == PT_LOAD && load_u64(ph + 8) == 0 && !based) {
      bias = (uint64_t)header - load_u64(ph + 16);
      based = true;
    }
    if (type == PT_GNU_RELRO) {
      vaddr = load_u64(ph + 16);
      memsz = load_u64(ph + 40);
      found = true;
    }
  }
  if (!based || !found) return false;
  uint64_t page = 4096;
  *start = (bias + vaddr) & ~(page - 1);
  *end = (bias + vaddr + memsz) & ~(page - 1);
  return *end > *start;
}

int croi_relro_read_only(void) {
  uint64_t start, end;
  if (!croi_relro(&start, &end) || croi_process_self() == 0) return -1;
  static croi_info_maps_t maps[64];
  uint64_t actual = 0, avail = 0;
  if (croi_syscall6(CROI_SYS_OBJECT_GET_INFO, croi_process_self(), CROI_INFO_PROCESS_MAPS, (uint64_t)maps,
                    sizeof maps, (uint64_t)&actual, (uint64_t)&avail) != 0)
    return -1;
  // Every RELRO page in a mapping without WRITE, all of them covered.
  uint64_t covered = 0;
  for (uint64_t i = 0; i < actual; i++) {
    if (maps[i].type != CROI_INFO_MAPS_TYPE_MAPPING) continue;
    uint64_t lo = maps[i].base, hi = maps[i].base + maps[i].size;
    if (hi <= start || lo >= end) continue;
    if (maps[i].u.mapping.mmu_flags & CROI_VM_PERM_WRITE) return 0;
    covered += (hi < end ? hi : end) - (lo > start ? lo : start);
  }
  return covered == end - start ? 1 : 0;
}
