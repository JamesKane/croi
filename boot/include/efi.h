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
typedef uint64_t EFI_PHYSICAL_ADDRESS;
typedef uint32_t EFI_MEMORY_TYPE;

// Enum constants rather than macros so Swift imports them (as EFI_STATUS).
enum : EFI_STATUS {
  EFI_SUCCESS = 0,
  EFI_ERROR_BIT = (EFI_STATUS)1 << (sizeof(EFI_STATUS) * 8 - 1),
  EFI_LOAD_ERROR = EFI_ERROR_BIT | 1,
  EFI_INVALID_PARAMETER = EFI_ERROR_BIT | 2,
  EFI_BUFFER_TOO_SMALL = EFI_ERROR_BIT | 5,
};

typedef struct {
  uint32_t Data1;
  uint16_t Data2;
  uint16_t Data3;
  uint8_t Data4[8];
} EFI_GUID;

typedef struct {
  uint64_t Signature;
  uint32_t Revision;
  uint32_t HeaderSize;
  uint32_t CRC32;
  uint32_t Reserved;
} EFI_TABLE_HEADER;

// --- Console ---------------------------------------------------------------

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

// --- Memory ----------------------------------------------------------------

typedef enum {
  AllocateAnyPages,
  AllocateMaxAddress,
  AllocateAddress,
} EFI_ALLOCATE_TYPE;

enum : EFI_MEMORY_TYPE {
  EfiReservedMemoryType,
  EfiLoaderCode,
  EfiLoaderData,
  EfiBootServicesCode,
  EfiBootServicesData,
  EfiRuntimeServicesCode,
  EfiRuntimeServicesData,
  EfiConventionalMemory,
  EfiUnusableMemory,
  EfiACPIReclaimMemory,
  EfiACPIMemoryNVS,
  EfiMemoryMappedIO,
  EfiMemoryMappedIOPortSpace,
  EfiPalCode,
  EfiPersistentMemory,
  EfiUnacceptedMemoryType,
};

typedef struct {
  uint32_t Type;
  uint32_t Pad;
  EFI_PHYSICAL_ADDRESS PhysicalStart;
  uint64_t VirtualStart;
  uint64_t NumberOfPages;
  uint64_t Attribute;
} EFI_MEMORY_DESCRIPTOR;

// --- Boot and runtime services ----------------------------------------------

typedef struct {
  EFI_TABLE_HEADER Hdr;
  void *RaiseTPL;
  void *RestoreTPL;
  EFI_STATUS (EFIAPI *AllocatePages)(EFI_ALLOCATE_TYPE type, EFI_MEMORY_TYPE memory_type, UINTN pages,
                                     EFI_PHYSICAL_ADDRESS *memory);
  EFI_STATUS (EFIAPI *FreePages)(EFI_PHYSICAL_ADDRESS memory, UINTN pages);
  EFI_STATUS (EFIAPI *GetMemoryMap)(UINTN *map_size, EFI_MEMORY_DESCRIPTOR *map, UINTN *map_key,
                                    UINTN *descriptor_size, uint32_t *descriptor_version);
  EFI_STATUS (EFIAPI *AllocatePool)(EFI_MEMORY_TYPE type, UINTN size, void **buffer);
  EFI_STATUS (EFIAPI *FreePool)(void *buffer);
  void *CreateEvent;
  void *SetTimer;
  void *WaitForEvent;
  void *SignalEvent;
  void *CloseEvent;
  void *CheckEvent;
  void *InstallProtocolInterface;
  void *ReinstallProtocolInterface;
  void *UninstallProtocolInterface;
  EFI_STATUS (EFIAPI *HandleProtocol)(EFI_HANDLE handle, const EFI_GUID *protocol, void **interface);
  void *Reserved;
  void *RegisterProtocolNotify;
  void *LocateHandle;
  void *LocateDevicePath;
  void *InstallConfigurationTable;
  void *LoadImage;
  void *StartImage;
  void *Exit;
  void *UnloadImage;
  EFI_STATUS (EFIAPI *ExitBootServices)(EFI_HANDLE image, UINTN map_key);
  void *GetNextMonotonicCount;
  void *Stall;
  EFI_STATUS (EFIAPI *SetWatchdogTimer)(UINTN timeout, uint64_t code, UINTN data_size, CHAR16 *data);
  void *ConnectController;
  void *DisconnectController;
  void *OpenProtocol;
  void *CloseProtocol;
  void *OpenProtocolInformation;
  void *ProtocolsPerHandle;
  void *LocateHandleBuffer;
  void *LocateProtocol;
  void *InstallMultipleProtocolInterfaces;
  void *UninstallMultipleProtocolInterfaces;
  void *CalculateCrc32;
  void *CopyMem;
  void *SetMem;
  void *CreateEventEx;
} EFI_BOOT_SERVICES;

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

typedef struct {
  EFI_GUID VendorGuid;
  void *VendorTable;
} EFI_CONFIGURATION_TABLE;

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

// --- Protocols -------------------------------------------------------------

// 5B1B31A1-9562-11D2-8E3F-00A0C969723B
typedef struct {
  uint32_t Revision;
  EFI_HANDLE ParentHandle;
  EFI_SYSTEM_TABLE *SystemTable;
  EFI_HANDLE DeviceHandle;
  void *FilePath;
  void *Reserved;
  uint32_t LoadOptionsSize;
  void *LoadOptions;
  void *ImageBase;
  uint64_t ImageSize;
  EFI_MEMORY_TYPE ImageCodeType;
  EFI_MEMORY_TYPE ImageDataType;
  void *Unload;
} EFI_LOADED_IMAGE_PROTOCOL;

typedef struct EFI_FILE_PROTOCOL EFI_FILE_PROTOCOL;
struct EFI_FILE_PROTOCOL {
  uint64_t Revision;
  EFI_STATUS (EFIAPI *Open)(EFI_FILE_PROTOCOL *self, EFI_FILE_PROTOCOL **new_handle, CHAR16 *name,
                            uint64_t mode, uint64_t attributes);
  EFI_STATUS (EFIAPI *Close)(EFI_FILE_PROTOCOL *self);
  void *Delete;
  EFI_STATUS (EFIAPI *Read)(EFI_FILE_PROTOCOL *self, UINTN *size, void *buffer);
  void *Write;
  EFI_STATUS (EFIAPI *GetPosition)(EFI_FILE_PROTOCOL *self, uint64_t *position);
  EFI_STATUS (EFIAPI *SetPosition)(EFI_FILE_PROTOCOL *self, uint64_t position);
  void *GetInfo;
  void *SetInfo;
  void *Flush;
};

#define EFI_FILE_MODE_READ UINT64_C(1)

// 964E5B22-6459-11D2-8E39-00A0C969723B
typedef struct EFI_SIMPLE_FILE_SYSTEM_PROTOCOL EFI_SIMPLE_FILE_SYSTEM_PROTOCOL;
struct EFI_SIMPLE_FILE_SYSTEM_PROTOCOL {
  uint64_t Revision;
  EFI_STATUS (EFIAPI *OpenVolume)(EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *self, EFI_FILE_PROTOCOL **root);
};

// --- Calling-convention wrappers --------------------------------------------

static inline EFI_STATUS croi_efi_output_string(EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *out, CHAR16 *s) {
  return out->OutputString(out, s);
}

[[noreturn]] static inline void croi_efi_shutdown(EFI_RUNTIME_SERVICES *rt) {
  rt->ResetSystem(EfiResetShutdown, EFI_SUCCESS, 0, nullptr);
  __builtin_unreachable();
}

static inline EFI_STATUS croi_efi_allocate_pages(EFI_BOOT_SERVICES *bs, EFI_MEMORY_TYPE type, UINTN pages,
                                                 EFI_PHYSICAL_ADDRESS *memory) {
  return bs->AllocatePages(AllocateAnyPages, type, pages, memory);
}

static inline EFI_STATUS croi_efi_allocate_pool(EFI_BOOT_SERVICES *bs, UINTN size, void **buffer) {
  return bs->AllocatePool(EfiLoaderData, size, buffer);
}

static inline EFI_STATUS croi_efi_free_pool(EFI_BOOT_SERVICES *bs, void *buffer) {
  return bs->FreePool(buffer);
}

static inline EFI_STATUS croi_efi_get_memory_map(EFI_BOOT_SERVICES *bs, UINTN *map_size, void *map,
                                                 UINTN *map_key, UINTN *descriptor_size) {
  uint32_t version;
  return bs->GetMemoryMap(map_size, map, map_key, descriptor_size, &version);
}

static inline EFI_STATUS croi_efi_exit_boot_services(EFI_BOOT_SERVICES *bs, EFI_HANDLE image, UINTN map_key) {
  return bs->ExitBootServices(image, map_key);
}

static inline EFI_STATUS croi_efi_disable_watchdog(EFI_BOOT_SERVICES *bs) {
  return bs->SetWatchdogTimer(0, 0, 0, nullptr);
}

static inline EFI_STATUS croi_efi_handle_protocol(EFI_BOOT_SERVICES *bs, EFI_HANDLE handle,
                                                  const EFI_GUID *protocol, void **interface) {
  return bs->HandleProtocol(handle, protocol, interface);
}

static inline EFI_STATUS croi_efi_open_volume(EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *fs, EFI_FILE_PROTOCOL **root) {
  return fs->OpenVolume(fs, root);
}

static inline EFI_STATUS croi_efi_file_open(EFI_FILE_PROTOCOL *dir, EFI_FILE_PROTOCOL **file, CHAR16 *name) {
  return dir->Open(dir, file, name, EFI_FILE_MODE_READ, 0);
}

static inline EFI_STATUS croi_efi_file_close(EFI_FILE_PROTOCOL *file) {
  return file->Close(file);
}

static inline EFI_STATUS croi_efi_file_read(EFI_FILE_PROTOCOL *file, UINTN *size, void *buffer) {
  return file->Read(file, size, buffer);
}

static inline EFI_STATUS croi_efi_file_size(EFI_FILE_PROTOCOL *file, uint64_t *size) {
  EFI_STATUS status = file->SetPosition(file, UINT64_MAX);  // seek to end
  if (status == EFI_SUCCESS) status = file->GetPosition(file, size);
  if (status == EFI_SUCCESS) status = file->SetPosition(file, 0);
  return status;
}
