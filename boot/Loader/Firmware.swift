import CEFI

/// Memory types the loader allocates with, from the OS-defined range
/// (0x80000000+), so they can be told apart in the final memory map.
enum CroiMemoryType {
    /// The kernel image.
    static let kernel: EFI_MEMORY_TYPE = 0x8000_0001
    /// Handoff block, memory range table, boot page tables.
    static let handoff: EFI_MEMORY_TYPE = 0x8000_0002
}

let pageSize: UInt64 = 0x1000

extension EFI_GUID {
    static var loadedImage: EFI_GUID {
        EFI_GUID(Data1: 0x5B1B_31A1, Data2: 0x9562, Data3: 0x11D2,
                 Data4: (0x8E, 0x3F, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B))
    }
    static var simpleFileSystem: EFI_GUID {
        EFI_GUID(Data1: 0x964E_5B22, Data2: 0x6459, Data3: 0x11D2,
                 Data4: (0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B))
    }
    static var acpi20Table: EFI_GUID {
        EFI_GUID(Data1: 0x8868_E871, Data2: 0xE4F1, Data3: 0x11D3,
                 Data4: (0xBC, 0x22, 0x00, 0x80, 0xC7, 0x3C, 0x88, 0x81))
    }

    func matches(_ other: EFI_GUID) -> Bool {
        unsafe Data1 == other.Data1 && Data2 == other.Data2 && Data3 == other.Data3
            && unsafeBitCast(Data4, to: UInt64.self) == unsafeBitCast(other.Data4, to: UInt64.self)
    }
}

/// The UEFI boot services the loader uses. Invalid after ExitBootServices.
@safe struct BootServices {
    private let bs: UnsafeMutablePointer<EFI_BOOT_SERVICES>

    @unsafe init(_ bs: UnsafeMutablePointer<EFI_BOOT_SERVICES>) {
        unsafe self.bs = bs
    }

    /// Allocates zeroed, page-aligned physical memory.
    func allocatePages(_ count: UInt64, type: EFI_MEMORY_TYPE) throws(LoaderError) -> UInt64 {
        var address: EFI_PHYSICAL_ADDRESS = 0
        let status = unsafe croi_efi_allocate_pages(bs, type, UInt(count), &address)
        guard status == EFI_SUCCESS else { throw .firmware("AllocatePages", status) }
        unsafe UnsafeMutableRawPointer(bitPattern: UInt(address))!
            .initializeMemory(as: UInt8.self, repeating: 0, count: Int(count * pageSize))
        return address
    }

    /// Allocates loader-private pool memory (not passed to the kernel).
    func allocatePool(_ size: Int) throws(LoaderError) -> UnsafeMutableRawPointer {
        var buffer: UnsafeMutableRawPointer? = nil
        let status = unsafe croi_efi_allocate_pool(bs, UInt(size), &buffer)
        guard status == EFI_SUCCESS, let buffer = unsafe buffer else {
            throw .firmware("AllocatePool", status)
        }
        return unsafe buffer
    }

    @unsafe func freePool(_ buffer: UnsafeMutableRawPointer) {
        _ = unsafe croi_efi_free_pool(bs, buffer)
    }

    /// Boot applications get a 5-minute watchdog by default.
    func disableWatchdog() {
        _ = unsafe croi_efi_disable_watchdog(bs)
    }

    func handleProtocol<T>(
        _ guid: EFI_GUID, on handle: EFI_HANDLE, as _: T.Type
    ) throws(LoaderError) -> UnsafeMutablePointer<T> {
        var guid = guid
        var interface: UnsafeMutableRawPointer? = nil
        let status = unsafe croi_efi_handle_protocol(bs, handle, &guid, &interface)
        guard status == EFI_SUCCESS, let interface = unsafe interface else {
            throw .firmware("HandleProtocol", status)
        }
        return unsafe interface.assumingMemoryBound(to: T.self)
    }

    /// Fills `buffer` with the memory map. On success returns the map size
    /// and key; on EFI_BUFFER_TOO_SMALL `size` holds the size needed.
    @unsafe func getMemoryMap(
        _ buffer: UnsafeMutableRawPointer?, size: inout UInt, key: inout UInt, descriptorSize: inout UInt
    ) -> EFI_STATUS {
        unsafe croi_efi_get_memory_map(bs, &size, buffer, &key, &descriptorSize)
    }

    func exitBootServices(image: EFI_HANDLE?, key: UInt) -> EFI_STATUS {
        unsafe croi_efi_exit_boot_services(bs, image, key)
    }
}
