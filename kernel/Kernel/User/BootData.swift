import CHandoff
import CKernel

/// Firmware data for user space (K9b): one ZBI container (include/zbi.h)
/// of ACPI_RSDP, SMBIOS, FRAMEBUFFER and MEM_CONFIG items, built from the
/// loader's handoff and handed to userboot as a read-only VMO
/// (CROI_PA_VMO_BOOTDATA), the way Zircon's userboot gets its ZBI.
///
/// The container is written into boot allocator pages before the PMM
/// takes over (the memory map lives in handoff memory, which is reclaimed
/// right after), and those pages are adopted into a VMO once the heap
/// exists.
enum BootData {
    nonisolated(unsafe) private static var phys: UInt64 = 0
    nonisolated(unsafe) private static var size: UInt64 = 0
    nonisolated(unsafe) private(set) static var length: UInt64 = 0
    /// The VMO object, made by `makeObject` and kept forever.
    nonisolated(unsafe) private(set) static var object = ObjectPointer(address: 0)

    /// Read only: user space can't change what firmware said.
    static var rights: Rights { .basic | .read | .map | .getProperty }

    private static let header = MemoryLayout<croi_zbi_header_t>.size
    private static let range = MemoryLayout<croi_zbi_mem_range_t>.size

    /// Builds the container in fresh boot allocator pages. Call before the
    /// PMM takes over (they are then wired until `makeObject` adopts them).
    static func build(_ handoff: croi_handoff_t, _ boot: inout BootAllocator) {
        let ranges = unsafe memConfig(boot, into: nil)
        var bytes = header + header + 8                                    // container, RSDP
        if handoff.smbios != 0 { bytes += header + 8 }
        if pixelFormat(handoff.framebuffer) != UInt32(CROI_ZBI_PIXEL_FORMAT_NONE) {
            bytes += header + MemoryLayout<croi_zbi_swfb_t>.size
        }
        bytes += header + ranges * range
        let page = KernelLayout.pageSize
        let pages = (UInt64(bytes) + page - 1) / page
        guard let base = boot.allocate(pages: pages) else { panic("boot data: no memory") }
        let start = unsafe UnsafeMutableRawPointer(bitPattern: UInt(base + boot.accessOffset))!

        var at = header
        func item(_ type: UInt32, _ length: Int) -> UnsafeMutableRawPointer {
            unsafe start.storeBytes(of: itemHeader(type, length), toByteOffset: at, as: croi_zbi_header_t.self)
            let payload = unsafe start + at + header
            at += header + ((length + 7) & ~7)
            return unsafe payload
        }
        unsafe item(UInt32(CROI_ZBI_TYPE_ACPI_RSDP), 8).storeBytes(of: handoff.acpi_rsdp, as: UInt64.self)
        if handoff.smbios != 0 {
            unsafe item(UInt32(CROI_ZBI_TYPE_SMBIOS), 8).storeBytes(of: handoff.smbios, as: UInt64.self)
        }
        let format = pixelFormat(handoff.framebuffer)
        if format != UInt32(CROI_ZBI_PIXEL_FORMAT_NONE) {
            let fb = handoff.framebuffer
            let swfb = croi_zbi_swfb_t(base: fb.base, width: fb.width, height: fb.height, stride: fb.stride,
                                       format: format)
            unsafe item(UInt32(CROI_ZBI_TYPE_FRAMEBUFFER), MemoryLayout<croi_zbi_swfb_t>.size)
                .storeBytes(of: swfb, as: croi_zbi_swfb_t.self)
        }
        let table = unsafe item(UInt32(CROI_ZBI_TYPE_MEM_CONFIG), ranges * range)
        _ = unsafe memConfig(boot, into: table.bindMemory(to: croi_zbi_mem_range_t.self, capacity: ranges))

        var container = itemHeader(UInt32(CROI_ZBI_TYPE_CONTAINER), at - header)
        container.extra = UInt32(CROI_ZBI_CONTAINER_MAGIC)
        unsafe start.storeBytes(of: container, as: croi_zbi_header_t.self)
        phys = base
        size = pages * page
        length = UInt64(at)
    }

    /// Adopts the container's pages into a VMO object (once the heap and
    /// objects exist).
    static func makeObject() {
        do throws(Status) {
            let vmo: Vmo
            do throws(VmError) {
                vmo = try Vmo(adopting: phys, size: size)
            } catch {
                panic("boot data: its pages aren't wired")
            }
            object = try VmoObject.wrap(vmo.record)
        } catch {
            panic("boot data: no memory for the VMO object")
        }
    }

    private static func itemHeader(_ type: UInt32, _ length: Int) -> croi_zbi_header_t {
        croi_zbi_header_t(type: type, length: UInt32(length), extra: 0, flags: UInt32(CROI_ZBI_FLAGS_VERSION),
                          reserved0: 0, reserved1: 0, magic: UInt32(CROI_ZBI_ITEM_MAGIC),
                          crc32: UInt32(CROI_ZBI_ITEM_NO_CRC32))
    }

    /// Zircon's pixel format for the GOP framebuffer, NONE if croi can't
    /// name it (or there is none).
    private static func pixelFormat(_ fb: croi_framebuffer_t) -> UInt32 {
        switch fb.format {
        case CROI_PIXEL_BGRX8888:
            return UInt32(CROI_ZBI_PIXEL_FORMAT_RGB_X888)
        case CROI_PIXEL_RGBX8888:
            return UInt32(CROI_ZBI_PIXEL_FORMAT_BGR_888_X)
        case CROI_PIXEL_BITMASK where fb.red_mask == 0xFF_0000 && fb.green_mask == 0xFF00 && fb.blue_mask == 0xFF:
            return UInt32(CROI_ZBI_PIXEL_FORMAT_RGB_X888)
        case CROI_PIXEL_BITMASK where fb.red_mask == 0xFF && fb.green_mask == 0xFF00 && fb.blue_mask == 0xFF_0000:
            return UInt32(CROI_ZBI_PIXEL_FORMAT_BGR_888_X)
        default:
            return UInt32(CROI_ZBI_PIXEL_FORMAT_NONE)
        }
    }

    /// The memory map as MEM_CONFIG ranges, adjacent ones of one type
    /// merged; writes them to `table` if given. Returns the count.
    private static func memConfig(_ boot: borrowing BootAllocator, into table: UnsafeMutablePointer<croi_zbi_mem_range_t>?) -> Int {
        var count = 0
        var last = croi_zbi_mem_range_t()
        for i in 0..<boot.rangeCount {
            let r = boot.range(i)
            guard r.size > 0 else { continue }
            let type: UInt32
            switch r.type {
            case CROI_MEM_FREE, CROI_MEM_KERNEL, CROI_MEM_HANDOFF, CROI_MEM_BOOTFS:
                type = UInt32(CROI_ZBI_MEM_TYPE_RAM)
            case CROI_MEM_MMIO, CROI_MEM_FRAMEBUFFER:
                type = UInt32(CROI_ZBI_MEM_TYPE_PERIPHERAL)
            default:
                type = UInt32(CROI_ZBI_MEM_TYPE_RESERVED)
            }
            if count > 0, last.type == type, last.paddr + last.length == r.base {
                last.length += r.size
            } else {
                count += 1
                last = croi_zbi_mem_range_t(paddr: r.base, length: r.size, type: type, reserved: 0)
            }
            if let table = unsafe table { unsafe table[count - 1] = last }
        }
        return count
    }
}
