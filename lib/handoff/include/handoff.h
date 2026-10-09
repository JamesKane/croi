// Boot handoff from the croi loader to the kernel (version 1).
//
// The loader fills one croi_handoff_t and passes its physical address to the
// kernel entry point. All addresses here are physical. On entry the boot
// page tables identity-map all RAM and the UART, so the kernel can read the
// handoff directly; it must copy anything it needs before replacing them.
//
// C because the layout is an ABI between two separately built images.

#pragma once

#include <stdint.h>

// Enum constants rather than macros so Swift imports them.
enum : uint64_t { CROI_HANDOFF_MAGIC = 0x31464f444e414843 };  // "CHANDOF1"
enum : uint32_t { CROI_HANDOFF_VERSION = 1 };

// Physical memory range types.
enum : uint32_t {
  CROI_MEM_FREE = 1,          // usable RAM
  CROI_MEM_RESERVED,          // never touch
  CROI_MEM_ACPI_RECLAIM,      // ACPI tables; usable once parsed
  CROI_MEM_ACPI_NVS,          // firmware-owned, preserve
  CROI_MEM_FIRMWARE_RUNTIME,  // UEFI runtime services code/data, preserve
  CROI_MEM_MMIO,              // device memory described by firmware
  CROI_MEM_PERSISTENT,        // NVDIMM-style persistent memory
  CROI_MEM_UNUSABLE,          // RAM with errors
  CROI_MEM_KERNEL,            // the kernel image
  CROI_MEM_HANDOFF,           // this handoff and the boot page tables;
                              // usable once the kernel is done with them
};

typedef struct {
  uint64_t base;
  uint64_t size;
  uint32_t type;   // CROI_MEM_*
  uint32_t reserved;
} croi_mem_range_t;

// Early console UART.
enum : uint32_t {
  CROI_UART_NONE = 0,
  CROI_UART_NS16550_PIO,   // x86 I/O ports; base is the port number
  CROI_UART_NS16550_MMIO,  // registers at base + (index << reg_shift)
  CROI_UART_PL011,         // Arm PL011 / SBSA generic UART
};

typedef struct {
  uint32_t kind;          // CROI_UART_*
  uint32_t reg_shift;     // NS16550_MMIO register stride, log2 bytes
  uint32_t access_width;  // MMIO access size in bytes (1 or 4)
  uint32_t reserved;
  uint64_t base;
} croi_uart_t;

typedef struct {
  uint64_t magic;    // CROI_HANDOFF_MAGIC
  uint32_t version;  // CROI_HANDOFF_VERSION
  uint32_t size;     // sizeof(croi_handoff_t)

  uint64_t kernel_phys;  // physical base of the loaded kernel image
  uint64_t kernel_virt;  // virtual address the image is mapped at
  uint64_t kernel_size;  // bytes, page multiple

  uint64_t acpi_rsdp;         // ACPI 2.0+ RSDP, 0 if none
  uint64_t efi_system_table;  // for runtime services, 0 if none

  uint64_t memory_map;        // croi_mem_range_t[memory_map_count],
  uint64_t memory_map_count;  // sorted by base, adjacent same-type merged

  croi_uart_t uart;
} croi_handoff_t;

static_assert(sizeof(croi_mem_range_t) == 24);
static_assert(sizeof(croi_uart_t) == 24);
static_assert(sizeof(croi_handoff_t) == 96);
