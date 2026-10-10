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
// interrupts), NOT_SUPPORTED (virtual, or a CPU the controller can't
// target), CANCELED (destroyed), ACCESS_DENIED (no WRITE right).
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
};
