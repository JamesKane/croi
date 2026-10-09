// UEFI image entry point. Firmware calls it with the platform's UEFI calling
// convention (Microsoft x64 on amd64), which Swift cannot declare, so this
// shim forwards to the Swift loader with the C ABI.

#include "loader.h"

[[gnu::visibility("default")]] EFI_STATUS EFIAPI efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *system_table) {
  return croi_loader_main(image, system_table);
}
