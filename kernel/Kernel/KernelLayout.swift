/// Fixed regions of the kernel's virtual address space. The low half is
/// left empty for user address spaces.
enum KernelLayout {
    #if arch(x86_64) || arch(arm64)
    /// All RAM (and device registers the kernel uses) is mapped at
    /// `physmapBase + physical address`. Start of the 48-bit high half.
    static var physmapBase: UInt64 { 0xFFFF_8000_0000_0000 }
    static var physmapSize: UInt64 { 64 << 40 }
    #elseif arch(riscv64)
    /// Start of the Sv39 high half.
    static var physmapBase: UInt64 { 0xFFFF_FFC0_0000_0000 }
    static var physmapSize: UInt64 { 128 << 30 }
    #endif

    static var pageSize: UInt64 { 0x1000 }

    /// The physmap address of physical address `phys`.
    static func physmap(_ phys: UInt64) -> UInt64 { physmapBase + phys }
}
