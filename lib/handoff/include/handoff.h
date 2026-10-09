// Boot handoff from the croi loader to the kernel (version 3).
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
enum : uint32_t { CROI_HANDOFF_VERSION = 3 };

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
  CROI_MEM_BOOTFS,            // the boot filesystem image, until userboot is done with it
  CROI_MEM_FRAMEBUFFER,       // the boot framebuffer: never cached, never allocated
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

// Boot framebuffer pixel formats (from UEFI GOP).
enum : uint32_t {
  CROI_PIXEL_NONE = 0,  // no linear framebuffer
  CROI_PIXEL_RGBX8888,  // byte 0 red, 1 green, 2 blue, 3 unused
  CROI_PIXEL_BGRX8888,  // byte 0 blue, 1 green, 2 red, 3 unused
  CROI_PIXEL_BITMASK,   // 32-bit pixels described by the masks
};

typedef struct {
  uint64_t base;    // physical
  uint64_t size;    // bytes
  uint32_t width;   // pixels
  uint32_t height;
  uint32_t stride;  // pixels per scan line
  uint32_t format;  // CROI_PIXEL_*
  uint32_t red_mask, green_mask, blue_mask, reserved_mask;  // CROI_PIXEL_BITMASK
} croi_framebuffer_t;

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

  // The boot CPU's hardware ID where the kernel can't read it itself:
  // the RISC-V hart ID (from RISCV_EFI_BOOT_PROTOCOL). 0 elsewhere.
  uint64_t boot_hart_id;

  // \croi\bootfs.img, in CROI_MEM_BOOTFS pages; 0/0 if absent.
  uint64_t bootfs;
  uint64_t bootfs_size;

  // \croi\cmdline (ASCII, not NUL-terminated), in handoff memory: copy it
  // before the handoff is reclaimed. 0/0 if absent.
  uint64_t cmdline;
  uint64_t cmdline_size;

  croi_framebuffer_t framebuffer;  // format CROI_PIXEL_NONE if there is none
} croi_handoff_t;

static_assert(sizeof(croi_mem_range_t) == 24);
static_assert(sizeof(croi_uart_t) == 24);
static_assert(sizeof(croi_framebuffer_t) == 48);
static_assert(sizeof(croi_handoff_t) == 184);
