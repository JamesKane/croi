// C-visible entry points of the Swift loader. Implemented in Swift with
// `@c @implementation`, so the compiler checks both sides agree.

#pragma once

#include "efi.h"

// Loader body (Loader/Main.swift), called by efi_main in entry.c.
EFI_STATUS croi_loader_main(EFI_HANDLE _Nullable image, EFI_SYSTEM_TABLE *_Nonnull system_table);
