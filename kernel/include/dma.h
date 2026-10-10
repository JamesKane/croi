// DMA (K9e): IOMMUs, bus transaction initiators (BTIs) and pinned memory
// tokens (PMTs), the ABI shared by the kernel and user space
// (user/include/croi/syscall.h includes it). Zircon's calls and values
// (zircon/syscalls/iommu.h, types.h, object.h), plus croi's BTI properties.
//
// iommu_create(IOMMU system resource, type, desc, desc_size): only the
// stub IOMMU so far (type STUB, a one-byte descriptor): its BTIs have no
// translation, and bti_pin returns physical addresses. Creating such a
// BTI is a trust decision, so the kernel writes a debuglog record naming
// the process and BTI id. VT-d, AMD-Vi, SMMUv3 and the RISC-V IOMMU come
// after M3 (NOT_SUPPORTED).
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
#include <stdint.h>

enum : uint32_t {
  // iommu_create types.
  CROI_IOMMU_TYPE_STUB = 0,
  CROI_IOMMU_TYPE_INTEL = 1,     // NOT_SUPPORTED yet
  CROI_IOMMU_TYPE_ARM_SMMU = 2,  // NOT_SUPPORTED yet
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
