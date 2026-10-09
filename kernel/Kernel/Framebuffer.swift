import CHandoff
import PageTables

/// The boot framebuffer from GOP, mapped write-combining in the kernel
/// address space. 32-bit pixels in any of the handoff's formats.
struct Framebuffer {
    let info: croi_framebuffer_t
    /// Virtual address of pixel (0, 0).
    let pixels: UInt64

    /// Maps the handoff's framebuffer, or nil if there is none.
    init?(_ info: croi_framebuffer_t) throws(VmError) {
        guard info.format != CROI_PIXEL_NONE, info.base != 0 else { return nil }
        let page = KernelLayout.pageSize
        let first = info.base & ~(page - 1)
        let size = (info.base + info.size + page - 1) & ~(page - 1) - first
        let window = try kernelAspace.mapPhysical(first, size: size,
                                                  MapAttributes(writable: true, cache: .writeCombining, global: true))
        self.info = info
        pixels = window + (info.base - first)
    }

    var width: Int { Int(info.width) }
    var height: Int { Int(info.height) }

    /// A 24-bit RGB color in this framebuffer's pixel format.
    func pixel(red: UInt8, green: UInt8, blue: UInt8) -> UInt32 {
        switch info.format {
        case CROI_PIXEL_RGBX8888:
            return UInt32(red) | UInt32(green) << 8 | UInt32(blue) << 16
        case CROI_PIXEL_BGRX8888:
            return UInt32(blue) | UInt32(green) << 8 | UInt32(red) << 16
        default:
            return place(red, info.red_mask) | place(green, info.green_mask) | place(blue, info.blue_mask)
        }
    }

    /// Fills a rectangle, clipped to the screen.
    func fill(x: Int, y: Int, width: Int, height: Int, _ value: UInt32) {
        let x0 = max(x, 0), y0 = max(y, 0)
        let x1 = min(x + width, self.width), y1 = min(y + height, self.height)
        guard x0 < x1, y0 < y1 else { return }
        for row in y0..<y1 {
            let line = unsafe UnsafeMutablePointer<UInt32>(
                bitPattern: UInt(pixels + UInt64(row) * UInt64(info.stride) * 4))!
            for column in x0..<x1 {
                unsafe line[column] = value
            }
        }
    }

    /// Reads a pixel back (slow on write-combining memory; for tests).
    func read(x: Int, y: Int) -> UInt32 {
        unsafe UnsafePointer<UInt32>(bitPattern: UInt(pixels + (UInt64(y) * UInt64(info.stride) + UInt64(x)) * 4))!.pointee
    }

    /// Scales an 8-bit component into a channel mask.
    private func place(_ value: UInt8, _ mask: UInt32) -> UInt32 {
        guard mask != 0 else { return 0 }
        let shift = mask.trailingZeroBitCount
        let bits = (~(mask >> shift)).trailingZeroBitCount  // width of the contiguous mask
        let scaled = bits >= 8 ? UInt32(value) << (bits - 8) : UInt32(value) >> (8 - bits)
        return (scaled << shift) & mask
    }
}
