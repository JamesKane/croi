import CHandoff
import CKernel
import Fmt

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

/// First Swift code in the kernel. Declared in kernel.h; called from the
/// arch start code on the boot stack, still on the loader's page tables.
@c @implementation
func kernel_main(_ handoffAddress: UInt64) -> Never {
    // The boot page tables identity map RAM, so the handoff is readable at
    // its physical address. Nothing to report to if it's bad: just stop.
    guard handoffAddress != 0 else { arch_halt() }
    let handoff = unsafe UnsafePointer<croi_handoff_t>(bitPattern: UInt(handoffAddress))!.pointee
    guard handoff.magic == CROI_HANDOFF_MAGIC, handoff.version == CROI_HANDOFF_VERSION,
          handoff.size == UInt32(MemoryLayout<croi_handoff_t>.size)
    else { arch_halt() }

    let console = unsafe Uart(handoff.uart)
    console.write("croi kernel (")
    console.write(archName)
    console.write(")\n")
    console.write("  image:  ")
    console.write(hex: handoff.kernel_phys)
    console.write(" -> ")
    console.write(hex: handoff.kernel_virt)
    console.write("\n  ACPI:   RSDP at ")
    console.write(hex: handoff.acpi_rsdp)
    console.write("\n")
    unsafe reportMemory(handoff, to: console)
    console.write("croi kernel: halting\n")
    arch_halt()
}

/// Summarizes the loader's memory map.
@unsafe private func reportMemory(_ handoff: croi_handoff_t, to console: Uart) {
    let ranges = unsafe UnsafePointer<croi_mem_range_t>(bitPattern: UInt(handoff.memory_map))!
    var free: UInt64 = 0
    var reclaimable: UInt64 = 0
    for i in 0..<Int(handoff.memory_map_count) {
        let range = unsafe ranges[i]
        switch range.type {
        case CROI_MEM_FREE: free += range.size
        case CROI_MEM_ACPI_RECLAIM, CROI_MEM_HANDOFF: reclaimable += range.size
        default: ()
        }
    }
    console.write("  memory: ")
    console.write(decimal: handoff.memory_map_count)
    console.write(" ranges, ")
    console.write(decimal: free >> 20)
    console.write(" MiB free, ")
    console.write(decimal: reclaimable >> 10)
    console.write(" KiB reclaimable\n")
}
