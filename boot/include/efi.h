// Minimal UEFI definitions for the croi loader (UEFI 2.10 layouts).
//
// Only what the loader uses is typed; other table slots are placeholders
// that keep the layout correct. Swift cannot call through EFIAPI (Microsoft
// x64 ABI) function pointers on amd64, so every firmware call goes through a
// static inline croi_efi_* wrapper below; clang emits those into the Swift
// object with the right calling convention.

#pragma once

#include <stddef.h>
#include <stdint.h>

#if defined(__x86_64__)
#define EFIAPI __attribute__((ms_abi))
#else
#define EFIAPI
#endif

typedef uintptr_t UINTN;
typedef UINTN EFI_STATUS;
typedef void *EFI_HANDLE;
typedef uint16_t CHAR16;
typedef uint8_t BOOLEAN;

#define EFI_SUCCESS ((EFI_STATUS)0)
#define EFI_ERROR_BIT ((EFI_STATUS)1 << (sizeof(EFI_STATUS) * 8 - 1))

typedef struct {
  uint64_t Signature;
  uint32_t Revision;
  uint32_t HeaderSize;
  uint32_t CRC32;
  uint32_t Reserved;
} EFI_TABLE_HEADER;

typedef struct EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL;
struct EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL {
  EFI_STATUS (EFIAPI *Reset)(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *self, BOOLEAN extended);
  EFI_STATUS (EFIAPI *OutputString)(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *self, CHAR16 *string);
  void *TestString;
  void *QueryMode;
  void *SetMode;
  void *SetAttribute;
  void *ClearScreen;
  void *SetCursorPosition;
  void *EnableCursor;
  void *Mode;
};

typedef enum {
  EfiResetCold,
  EfiResetWarm,
  EfiResetShutdown,
  EfiResetPlatformSpecific,
} EFI_RESET_TYPE;

typedef struct {
  EFI_TABLE_HEADER Hdr;
  void *GetTime;
  void *SetTime;
  void *GetWakeupTime;
  void *SetWakeupTime;
  void *SetVirtualAddressMap;
  void *ConvertPointer;
  void *GetVariable;
  void *GetNextVariableName;
  void *SetVariable;
  void *GetNextHighMonotonicCount;
  void (EFIAPI *ResetSystem)(EFI_RESET_TYPE type, EFI_STATUS status, UINTN data_size, void *data);
  void *UpdateCapsule;
  void *QueryCapsuleCapabilities;
  void *QueryVariableInfo;
} EFI_RUNTIME_SERVICES;

typedef struct EFI_BOOT_SERVICES EFI_BOOT_SERVICES;
typedef struct EFI_CONFIGURATION_TABLE EFI_CONFIGURATION_TABLE;

typedef struct {
  EFI_TABLE_HEADER Hdr;
  CHAR16 *FirmwareVendor;
  uint32_t FirmwareRevision;
  EFI_HANDLE ConsoleInHandle;
  void *ConIn;
  EFI_HANDLE ConsoleOutHandle;
  EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *ConOut;
  EFI_HANDLE StandardErrorHandle;
  EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *StdErr;
  EFI_RUNTIME_SERVICES *RuntimeServices;
  EFI_BOOT_SERVICES *BootServices;
  UINTN NumberOfTableEntries;
  EFI_CONFIGURATION_TABLE *ConfigurationTable;
} EFI_SYSTEM_TABLE;

static inline EFI_STATUS croi_efi_output_string(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *out, CHAR16 *s) {
  return out->OutputString(out, s);
}

[[noreturn]] static inline void croi_efi_shutdown(EFI_RUNTIME_SERVICES *rt) {
  rt->ResetSystem(EfiResetShutdown, EFI_SUCCESS, 0, nullptr);
  __builtin_unreachable();
}
