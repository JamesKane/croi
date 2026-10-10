// Boot data items (K9b; Zircon's ZBI format, lib/zbi-format): the ABI
// shared by the kernel and user space. croi boots without a ZBI, but tells
// user space about firmware the way Zircon does: userboot gets a read-only
// VMO (CROI_PA_VMO_BOOTDATA) holding one ZBI container, built by the kernel
// from the loader's handoff. Layouts and values are Zircon's.
//
// The VMO starts with a container header (type CONTAINER, length = the
// bytes of items after it, extra = CROI_ZBI_CONTAINER_MAGIC). Each item is
// a header followed by `length` payload bytes, padded with zeros to
// CROI_ZBI_ALIGNMENT; the next header follows the padding. Every header
// has CROI_ZBI_FLAGS_VERSION set, magic CROI_ZBI_ITEM_MAGIC, and crc32
// CROI_ZBI_ITEM_NO_CRC32 (croi never sets CROI_ZBI_FLAGS_CRC32). The VMO's
// size is rounded up to a page: read the container's length, not the size.
//
// Items croi writes, in this order, each at most once:
//   ACPI_RSDP    uint64_t: physical address of the ACPI 2.0+ RSDP.
//   SMBIOS       uint64_t: physical address of the SMBIOS entry point
//                ("_SM3_" or "_SM_"); absent when firmware has none.
//   FRAMEBUFFER  croi_zbi_swfb_t; absent with no linear GOP framebuffer.
//   MEM_CONFIG   croi_zbi_mem_range_t[length / 24], sorted by paddr,
//                adjacent ranges of one type merged. RAM is RAM the kernel
//                owns; PERIPHERAL is device memory and the framebuffer;
//                RESERVED is everything else firmware described (ACPI
//                tables and NVS, UEFI runtime, reserved, persistent,
//                unusable). Holes are absent.
//
// The ACPI tables, SMBIOS and other firmware ranges are read through a
// physical VMO (vmo_create_physical) under an MMIO resource that covers
// them. Such VMOs are always cached (the kernel maps that memory cached),
// and vmo_set_cache_policy refuses anything else with ACCESS_DENIED.
#pragma once
#include <stdint.h>

enum : uint32_t {
  CROI_ZBI_ALIGNMENT = 8,

  // zbi_header_t.type
  CROI_ZBI_TYPE_CONTAINER = 0x544f4f42,    // "BOOT"
  CROI_ZBI_TYPE_MEM_CONFIG = 0x434d454d,   // "MEMC"
  CROI_ZBI_TYPE_ACPI_RSDP = 0x50445352,    // "RSDP"
  CROI_ZBI_TYPE_SMBIOS = 0x49424d53,       // "SMBI"
  CROI_ZBI_TYPE_FRAMEBUFFER = 0x42465753,  // "SWFB"

  CROI_ZBI_CONTAINER_MAGIC = 0x868cf7e6,  // the container header's extra
  CROI_ZBI_ITEM_MAGIC = 0xb5781729,       // every header's magic
  CROI_ZBI_FLAGS_VERSION = 1u << 16,      // must be set
  CROI_ZBI_FLAGS_CRC32 = 1u << 17,        // crc32 is valid (croi: never)
  CROI_ZBI_ITEM_NO_CRC32 = 0x4a87e8d6,    // crc32 without FLAGS_CRC32

  // croi_zbi_mem_range_t.type
  CROI_ZBI_MEM_TYPE_RAM = 1,
  CROI_ZBI_MEM_TYPE_PERIPHERAL = 2,
  CROI_ZBI_MEM_TYPE_RESERVED = 3,

  // croi_zbi_swfb_t.format (Zircon's zbi_pixel_format_t: bits 23:16 are
  // the bytes per pixel). croi's framebuffers are 32-bit, so one of:
  CROI_ZBI_PIXEL_FORMAT_NONE = 0,
  CROI_ZBI_PIXEL_FORMAT_RGB_X888 = 0x00040005,   // 32-bit word 0x00RRGGBB: byte 0 blue
  CROI_ZBI_PIXEL_FORMAT_BGR_888_X = 0x0004000b,  // byte 0 red, 1 green, 2 blue, 3 unused
};

// zbi_header_t.
typedef struct {
  uint32_t type;
  uint32_t length;  // payload bytes after this header, not counting padding
  uint32_t extra;
  uint32_t flags;
  uint32_t reserved0;
  uint32_t reserved1;
  uint32_t magic;
  uint32_t crc32;
} croi_zbi_header_t;

// zbi_mem_range_t.
typedef struct {
  uint64_t paddr;
  uint64_t length;
  uint32_t type;  // CROI_ZBI_MEM_TYPE_*
  uint32_t reserved;
} croi_zbi_mem_range_t;

// zbi_swfb_t. The framebuffer is stride * height * 4 bytes at base (a
// physical address, not necessarily page aligned).
typedef struct {
  uint64_t base;
  uint32_t width;   // pixels
  uint32_t height;
  uint32_t stride;  // pixels per scan line
  uint32_t format;  // CROI_ZBI_PIXEL_FORMAT_*
} croi_zbi_swfb_t;

static_assert(sizeof(croi_zbi_header_t) == 32);
static_assert(sizeof(croi_zbi_mem_range_t) == 24);
static_assert(sizeof(croi_zbi_swfb_t) == 24);
