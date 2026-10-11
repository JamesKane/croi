// Interrupt objects (K9c): the ABI shared by the kernel and user space
// (user/include/croi/syscall.h includes it). Zircon's values
// (zircon/types.h, syscalls/port.h), plus croi's affinity call.
//
// An interrupt's number is its GSI on amd64 (IOAPIC pins; with REMAP_IRQ,
// an ISA IRQ the MADT's overrides map), its INTID on arm64 (GICv3 SPIs,
// 32 and up) and its GSI on rv64 (PLIC sources). interrupt_create needs an
// IRQ resource covering it (virtual interrupts need none).
//
// interrupt_set_affinity(interrupt, cpu mask) routes it to one CPU of the
// mask (the lowest-numbered one taking interrupts); until it is called,
// to the boot CPU. Statuses: INVALID_ARGS (no CPU of the mask takes
// interrupts), NOT_SUPPORTED (virtual, plain MSI, or a CPU the controller
// can't target), CANCELED (destroyed), ACCESS_DENIED (no WRITE right).
//
// MSI (K9d, Zircon's calls): msi_allocate(MSI system resource, count: a
// power of two up to 32) gives an allocation (object type 32) of
// contiguous vectors on the boot CPU; object_get_info(CROI_INFO_MSI) says
// what the device must write. msi_create(allocation, options, id, vmo,
// offset) makes interrupt object `id` of it: with CROI_MSI_MODE_MSI_X,
// `vmo` holds the MSI-X table at `offset` and the kernel programs and
// masks entry `id` (and moves it to another CPU on set_affinity);
// without, `vmo` is the function's config space with the MSI capability
// at `offset`, which the driver programs from the info (the kernel only
// masks through per-vector masking if the capability has it). The VMO
// must be physical and uncached. amd64 only so far (arm64 needs the ITS,
// rv64 the IMSIC): NOT_SUPPORTED elsewhere.
#pragma once
#include <stdint.h>

enum : uint32_t {
  // interrupt_create options.
  CROI_INTERRUPT_REMAP_IRQ = 0x1,
  CROI_INTERRUPT_MODE_DEFAULT = 0u << 1,  // what firmware says (amd64: MADT overrides,
                                          // else ISA edge-high, PCI level-low)
  CROI_INTERRUPT_MODE_EDGE_LOW = 1u << 1,
  CROI_INTERRUPT_MODE_EDGE_HIGH = 2u << 1,
  CROI_INTERRUPT_MODE_LEVEL_LOW = 3u << 1,
  CROI_INTERRUPT_MODE_LEVEL_HIGH = 4u << 1,
  CROI_INTERRUPT_MODE_EDGE_BOTH = 5u << 1,  // NOT_SUPPORTED
  CROI_INTERRUPT_MODE_MASK = 0xe,
  CROI_INTERRUPT_VIRTUAL = 0x10,
  CROI_INTERRUPT_TIMESTAMP_MONO = 1u << 6,  // accepted: croi's boot time is monotonic time

  // interrupt_bind options.
  CROI_INTERRUPT_BIND = 0,
  CROI_INTERRUPT_UNBIND = 1,

  // port_create option: the port may be bound to interrupts.
  CROI_PORT_BIND_TO_INTERRUPT = 1,

  // Port packet type: payload[0] is the timestamp (ns).
  CROI_PKT_TYPE_INTERRUPT = 7,

  // A virtual interrupt's signal while neither triggered nor awaiting ack.
  CROI_VIRTUAL_INTERRUPT_UNTRIGGERED = 1u << 4,

  // msi_create options.
  CROI_MSI_MODE_MSI_X = 1,

  // object_get_info topic on an MSI allocation.
  CROI_INFO_MSI = 28,
};

// zx_info_msi_t.
typedef struct {
  // The device writes target_data + n for id n to target_addr. With
  // interrupt remapping (amd64 VT-d, K12f) the address is in the
  // remappable format (bit 4) naming the kernel's entry for id 0 and the
  // data is 0; else the compatibility format with the vector as data.
  uint64_t target_addr;      // the address the device writes
  uint32_t target_data;      // the data for id 0; id n writes target_data + n
  uint32_t base_irq_id;      // the first vector
  uint32_t num_irq;
  uint32_t interrupt_count;  // ids with an interrupt object
} croi_info_msi_t;

static_assert(sizeof(croi_info_msi_t) == 24);
