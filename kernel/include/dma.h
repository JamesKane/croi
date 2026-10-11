// DMA (K9e): IOMMUs, bus transaction initiators (BTIs) and pinned memory
// tokens (PMTs), the ABI shared by the kernel and user space
// (user/include/croi/syscall.h includes it). Zircon's calls and values
// (zircon/syscalls/iommu.h, types.h, object.h), plus croi's BTI properties.
//
// iommu_create(IOMMU system resource, type, desc, desc_size):
// - STUB (a one-byte descriptor): its BTIs have no translation, and
//   bti_pin returns physical addresses. Creating such a BTI is a trust
//   decision, so the kernel writes a debuglog record naming the process
//   and BTI id.
// - INTEL (K12a, VT-d): zx_iommu_desc_intel_t for one remapping unit
//   (DMAR DRHD), its device scopes and its reserved memory (RMRRs), as
//   user space reads them from ACPI's DMAR; register_base must be a DRHD
//   the kernel's own DMAR lists (NOT_FOUND), one object per unit
//   (ALREADY_BOUND). Creating it turns translation on with every device
//   behind the unit in pass-through, so drivers still on stub BTIs keep
//   working; bti_create(iommu, 0, bdf) claims a device (bus << 8 | device
//   << 3 | function, in the unit's scope, else OUT_OF_RANGE): it gets a
//   domain of its own, bti_pin returns I/O virtual addresses from the
//   BTI's window and only pinned pages are reachable. When the last
//   reference to the BTI goes, the device is blocked (no DMA at all), not
//   returned to pass-through. Faults are logged. Scopes: endpoints one hop
//   from the host bridge; bridge and deeper scopes are NOT_SUPPORTED yet.
// - AMD (K12b, croi's type: Zircon has no AMD driver): croi_iommu_desc_amd_t
//   for one IOMMU (an IVRS IVHD's register base, NOT_FOUND otherwise) and
//   its unity ranges (IVMD: firmware's DMA, identity mapped for the
//   devices they name). The unit covers its whole segment but itself; BTIs
//   as INTEL's (bti_create's id is the device id, bus << 8 | device << 3 |
//   function). Faults go to the event log (an MSI the kernel programs into
//   the IOMMU's PCI function) and are logged.
// - ARM_SMMU (arm64): Zircon's zx_iommu_desc_arm_smmu_t (the register
//   base alone), an IORT SMMU node's (NOT_FOUND otherwise).
//   - SMMUv3 (K12c): bti_create's id is the PCI requester id, which the
//     IORT maps to the device's stream id (OUT_OF_RANGE if it doesn't
//     reach this SMMU). A unit firmware left enabled is firmware's:
//     BAD_STATE. Faults go to the event queue and are logged.
//   - SMMUv1/v2 (K12d, MMU-500): firmware owns it and a hypervisor may
//     police it (the Q8B's), so the kernel only uses free stream match
//     entries and banks. bti_create's id is stream match pairs, Zircon's
//     value | mask << 16 (15 bits each) and croi's second pair in bits
//     32-62 with bit 63 set; they must be the pairs the platform expects
//     (on the Q8B, Linux's devicetree's: the hypervisor resets the SoC on
//     others). Pairs overlapping a valid entry: ALREADY_BOUND; none free:
//     NO_RESOURCES. A unit firmware left disabled: NOT_SUPPORTED.
// - RISCV (K12e, rv64, croi's type): { uint64_t register_base }, an ACPI
//   RIMT IOMMU node's base (a PCIe-based IOMMU's: its BAR 0); NOT_FOUND
//   otherwise, BAD_STATE if firmware left it translating. bti_create's id
//   is the PCI requester id, which the RIMT maps to a device id. Faults
//   are read from its fault queue and logged.
//
// bti_pin(bti | options << 32, vmo | addrs_count << 32, offset, size,
// addrs, pmt out) pins [offset, offset+size) (page aligned) of the VMO and
// writes its device addresses: one per page, one for the whole range with
// CONTIGUOUS (a contiguous VMO), or one per minimum_contiguity with
// COMPRESS. The pages stay committed and in place until pmt_unpin.
// Closing a PMT handle without unpinning quarantines its pages (the
// device may still be writing them) until bti_release_quarantine; a BTI
// whose last reference goes with pages quarantined leaves them pinned for
// good. The PMT handle has INSPECT only (it can't be duplicated or sent).
//
// BTI properties (croi's, Todhchai requirement 14): the device's DMA
// address width, the window of device addresses it may use, and its
// memory type. bti_set_properties can only narrow them (a driver can't
// widen what devmgr gave it); the memory type changes only while nothing
// is pinned. bti_pin refuses pages outside them (OUT_OF_RANGE), and
// vmo_create_contiguous(bti, ...) allocates inside them, with the BTI's
// memory type as the VMO's cache policy (non-coherent devices get
// uncached memory; never device memory). With no IOMMU, device addresses
// are physical addresses, so the window is a physical range check.
#pragma once
#include <stdbool.h>
#include <stdint.h>

enum : uint32_t {
  // iommu_create types.
  CROI_IOMMU_TYPE_STUB = 0,
  CROI_IOMMU_TYPE_INTEL = 1,     // VT-d (K12a)
  CROI_IOMMU_TYPE_ARM_SMMU = 2,  // NOT_SUPPORTED yet
  CROI_IOMMU_TYPE_AMD = 0x10000, // AMD-Vi (K12b), croi's
  CROI_IOMMU_TYPE_RISCV = 0x10001,  // the RISC-V IOMMU (K12e), croi's
  CROI_IOMMU_MAX_DESC_LEN = 4096,

  // bti_pin options.
  CROI_BTI_PERM_READ = 1u << 0,
  CROI_BTI_PERM_WRITE = 1u << 1,
  CROI_BTI_PERM_EXECUTE = 1u << 2,
  CROI_BTI_COMPRESS = 1u << 3,
  CROI_BTI_CONTIGUOUS = 1u << 4,

  // croi_bti_properties_t.memory_type.
  CROI_BTI_MEMORY_COHERENT = 0,     // Normal write-back (the default)
  CROI_BTI_MEMORY_NONCOHERENT = 1,  // Normal non-cacheable

  // object_get_info topics on a BTI.
  CROI_INFO_BTI = 20,                   // croi_info_bti_t (Zircon's)
  CROI_INFO_BTI_PROPERTIES = 0x10000,   // croi_bti_properties_t (croi's)
};

// zx_info_bti_t.
typedef struct {
  uint64_t minimum_contiguity;  // bti_pin's runs are at least this long
  uint64_t aspace_size;         // bytes of device address space
  uint64_t pmo_count;           // live PMTs
  uint64_t quarantine_count;    // quarantined PMTs
} croi_info_bti_t;

// A BTI's DMA properties (bti_set_properties, CROI_INFO_BTI_PROPERTIES).
typedef struct {
  uint32_t address_bits;  // device addresses are below 2^address_bits (64: any)
  uint32_t memory_type;   // CROI_BTI_MEMORY_*
  uint64_t window_base;   // device addresses are in [window_base,
  uint64_t window_size;   //   window_base + window_size); size 0: none set
} croi_bti_properties_t;

static_assert(sizeof(croi_info_bti_t) == 32);
static_assert(sizeof(croi_bti_properties_t) == 24);

// Zircon's zx_iommu_desc_intel_t and its parts (zircon/syscalls/iommu.h).
enum : uint8_t {
  CROI_IOMMU_INTEL_SCOPE_ENDPOINT = 0,
  CROI_IOMMU_INTEL_SCOPE_BRIDGE = 1,  // NOT_SUPPORTED yet
};

typedef struct {
  uint8_t type;
  uint8_t start_bus;    // the first bus the host bridge decodes
  uint8_t num_hops;     // bridges plus the device (1: a device on start_bus)
  uint8_t dev_func[5];  // device << 3 | function, per hop
} croi_iommu_desc_intel_scope_t;

typedef struct {
  uint64_t base_addr;
  uint64_t len;
  uint8_t scope_bytes;  // croi_iommu_desc_intel_scope_t bytes that follow
  uint8_t _reserved[7];
} croi_iommu_desc_intel_reserved_memory_t;

typedef struct {
  uint64_t register_base;  // physical
  uint16_t pci_segment;
  bool whole_segment;      // scopes are the devices NOT behind it
  uint8_t scope_bytes;
  uint16_t reserved_memory_bytes;
  uint8_t _reserved[2];
  // croi_iommu_desc_intel_scope_t scopes[]; then the reserved memory.
} croi_iommu_desc_intel_t;

static_assert(sizeof(croi_iommu_desc_intel_scope_t) == 8);
static_assert(sizeof(croi_iommu_desc_intel_reserved_memory_t) == 24);
static_assert(sizeof(croi_iommu_desc_intel_t) == 16);

// croi's AMD-Vi descriptor (CROI_IOMMU_TYPE_AMD).
typedef struct {
  uint64_t base_addr;
  uint64_t len;
  uint16_t first_device;  // device ids (bus << 8 | device << 3 | function)
  uint16_t last_device;   // the range is inclusive
  uint8_t _reserved[4];
} croi_iommu_desc_amd_unity_t;

typedef struct {
  uint64_t register_base;  // physical: an IVHD's IOMMU base address
  uint16_t pci_segment;
  uint16_t unity_bytes;    // croi_iommu_desc_amd_unity_t bytes that follow
  uint8_t _reserved[4];
} croi_iommu_desc_amd_t;

static_assert(sizeof(croi_iommu_desc_amd_unity_t) == 24);
static_assert(sizeof(croi_iommu_desc_amd_t) == 16);
