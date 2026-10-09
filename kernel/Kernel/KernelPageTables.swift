import CHandoff
import CKernel
import PageTables

typealias KernelPageTables = PageTableBuilder<BootAllocator>

/// Builds the kernel's own address space (see KernelLayout):
///   - the physmap: every RAM range at physmapBase + phys, RW, never executable;
///   - the kernel image at its link address, text RX / rodata R / data RW;
///   - the UART registers in the physmap, as device memory.
/// Nothing in the low half: the loader's identity map is not carried over.
func buildKernelPageTables(
    _ handoff: croi_handoff_t, allocator: BootAllocator
) throws(MapError) -> KernelPageTables {
    var tables = try KernelPageTables(memory: allocator)
    let physmap = MapAttributes(writable: true, global: true)

    // Coalesce adjacent RAM ranges so large pages can be used across them.
    var runStart: UInt64 = 0
    var runEnd: UInt64 = 0
    for i in 0..<allocator.rangeCount {
        let r = allocator.range(i)
        guard isRam(r.type), r.base < KernelLayout.physmapSize else { continue }
        let end = min(r.base + r.size, KernelLayout.physmapSize)
        if r.base == runEnd {
            runEnd = end
            continue
        }
        if runEnd > runStart {
            try tables.map(virt: KernelLayout.physmap(runStart), phys: runStart, size: runEnd - runStart, physmap)
        }
        runStart = r.base
        runEnd = end
    }
    if runEnd > runStart {
        try tables.map(virt: KernelLayout.physmap(runStart), phys: runStart, size: runEnd - runStart, physmap)
    }

    // The kernel image, segment by segment.
    func mapImage(_ start: UInt64, _ end: UInt64, _ attributes: MapAttributes) throws(MapError) {
        let size = (end - start + KernelLayout.pageSize - 1) & ~(KernelLayout.pageSize - 1)
        try tables.map(virt: start, phys: handoff.kernel_phys + (start - handoff.kernel_virt), size: size, attributes)
    }
    try mapImage(kernel_image_start(), kernel_text_end(), MapAttributes(executable: true, global: true))
    try mapImage(kernel_rodata_start(), kernel_rodata_end(), MapAttributes(global: true))
    try mapImage(kernel_data_start(), kernel_image_end(), MapAttributes(writable: true, global: true))

    if handoff.uart.kind == CROI_UART_NS16550_MMIO || handoff.uart.kind == CROI_UART_PL011 {
        let page = handoff.uart.base & ~(KernelLayout.pageSize - 1)
        try tables.map(virt: KernelLayout.physmap(page), phys: page, size: KernelLayout.pageSize,
                       MapAttributes(writable: true, device: true, global: true))
    }
    return tables
}

/// RAM the physmap covers: anything the kernel may read or reuse.
private func isRam(_ type: UInt32) -> Bool {
    switch type {
    case CROI_MEM_FREE, CROI_MEM_KERNEL, CROI_MEM_HANDOFF, CROI_MEM_ACPI_RECLAIM,
         CROI_MEM_ACPI_NVS, CROI_MEM_FIRMWARE_RUNTIME, CROI_MEM_PERSISTENT:
        return true
    default:
        return false
    }
}
