import CHandoff
import CKernel
import Fmt
/// Fixed regions of the kernel's virtual address space. The low half is
/// left empty for user address spaces.
enum KernelLayout {
    #if arch(x86_64) || arch(arm64)
    /// All RAM (and device registers the kernel uses) is mapped at
    /// `physmapBase + physical address`. Start of the 48-bit high half.
    static var physmapBase: UInt64 { 0xFFFF_8000_0000_0000 }
    static var physmapSize: UInt64 { 64 << 40 }
    /// Dynamic kernel mappings (KernelAspace): right after the physmap.
    static var dynamicBase: UInt64 { 0xFFFF_C000_0000_0000 }
    static var dynamicSize: UInt64 { 32 << 40 }
    #elseif arch(riscv64)
    /// Start of the Sv39 high half.
    static var physmapBase: UInt64 { 0xFFFF_FFC0_0000_0000 }
    static var physmapSize: UInt64 { 128 << 30 }
    static var dynamicBase: UInt64 { 0xFFFF_FFE0_0000_0000 }
    static var dynamicSize: UInt64 { 64 << 30 }
    #endif
    // The kernel image sits above both: at a random CROI_KASLR_ALIGN-aligned
    // base in the KASLR window (handoff.h), which ends at its link address
    // (CROI_KERNEL_BASE), or at the link address with croi.kaslr=off.

    static var pageSize: UInt64 { 0x1000 }

    /// The image's link address: where the KASLR window ends.
    static var linkBase: UInt64 { CROI_KASLR_BASE + CROI_KASLR_SIZE }

    /// Whether the image runs at a randomized base (in the window,
    /// aligned, wholly inside).
    static var randomized: Bool {
        let start = kernel_image_start(), end = kernel_image_end()
        return start >= CROI_KASLR_BASE && end <= linkBase && start % CROI_KASLR_ALIGN == 0
    }

    /// Writes `kaslr: image <start>-<end>, link <link address>` (or that it
    /// is off): kernel addresses in a log map back to the ELF's by
    /// subtracting start and adding the link address (tools/qemu.sh does,
    /// for its backtraces).
    static func describeImage(to console: borrowing Uart) {
        guard randomized else {
            console.write("kaslr: off, image at its link address ")
            console.write(hex: kernel_image_start())
            return
        }
        console.write("kaslr: image ")
        console.write(hex: kernel_image_start())
        console.write("-")
        console.write(hex: kernel_image_end())
        console.write(", link ")
        console.write(hex: linkBase)
    }

    /// The physmap address of physical address `phys`.
    static func physmap(_ phys: UInt64) -> UInt64 { physmapBase + phys }
}
