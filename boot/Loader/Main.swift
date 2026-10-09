import CEFI
import CLoader

private var archName: StaticString {
    #if arch(x86_64)
    "amd64"
    #elseif arch(arm64)
    "arm64"
    #elseif arch(riscv64)
    "rv64"
    #else
    #error("unsupported architecture")
    #endif
}

/// Loader body, declared in loader.h and called from `efi_main` (entry.c).
@c @implementation
func croi_loader_main(
    _ image: EFI_HANDLE?,
    _ systemTable: UnsafeMutablePointer<EFI_SYSTEM_TABLE>
) -> EFI_STATUS {
    let console = unsafe Console(systemTable.pointee.ConOut)
    console.write("croi loader (")
    console.write(archName)
    console.write(")\n")

    // Nothing to load yet: power off so automated runs terminate.
    unsafe croi_efi_shutdown(systemTable.pointee.RuntimeServices)
}
