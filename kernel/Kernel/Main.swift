import CHandoff
import CKernel
import Fmt
import PageTables

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
          handoff.size == UInt32(MemoryLayout<croi_handoff_t>.size),
          handoff.kernel_virt == kernel_image_start()
    else { arch_halt() }

    var console = unsafe Uart(handoff.uart)
    panicConsole = console
    arch_init_exceptions()
    console.write("croi kernel (")
    console.write(archName)
    console.write(")\n")
    console.write("  image:  ")
    console.write(hex: handoff.kernel_phys)
    console.write(" -> ")
    console.write(hex: handoff.kernel_virt)
    #if arch(arm64)
    console.write("\n  EL:     ")
    console.write(decimal: arch_current_el())
    #endif
    console.write("\n  ACPI:   RSDP at ")
    console.write(hex: handoff.acpi_rsdp)
    console.write("\n")

    // Move off the loader's page tables onto our own.
    let tables: KernelPageTables
    do throws(MapError) {
        tables = try buildKernelPageTables(handoff, allocator: BootAllocator(handoff))
    } catch {
        console.write("croi kernel: building page tables failed: ")
        report(error, to: console)
        arch_halt()
    }
    arch_load_page_tables(tables.rootLow, tables.rootHigh)
    var allocator = tables.memory
    allocator.useKernelMappings()
    console = unsafe Uart(handoff.uart.inPhysmap)
    panicConsole = console

    console.write("  paging: kernel page tables, ")
    console.write(decimal: allocator.pagesAllocated)
    console.write(" pages; physmap at ")
    console.write(hex: KernelLayout.physmapBase)
    console.write("\n")

    // The handoff is now only reachable through the physmap.
    let viaPhysmap = unsafe UnsafePointer<croi_handoff_t>(
        bitPattern: UInt(KernelLayout.physmap(handoffAddress)))!.pointee
    guard viaPhysmap.magic == CROI_HANDOFF_MAGIC else {
        console.write("croi kernel: physmap does not show the handoff\n")
        arch_halt()
    }
    reportMemory(allocator, to: console)

    // The PMM takes over all RAM; then the loader's handoff data and boot
    // page tables are released. `handoff` (a copy) stays usable.
    do throws(Pmm.InitError) {
        try pmm.initialize(from: &allocator)
    } catch {
        panic(error == .tooManyArenas ? "pmm: too many arenas" : "pmm: no memory for page arrays")
    }
    pmmSelfTest()
    let reclaimed = pmm.endHandoff(allocator)
    console.write("  pmm:    ")
    console.write(decimal: (pmm.totalPages * KernelLayout.pageSize) >> 20)
    console.write(" MiB in ")
    console.write(decimal: UInt64(pmm.arenaCount))
    console.write(" arenas, ")
    console.write(decimal: (pmm.freePages * KernelLayout.pageSize) >> 20)
    console.write(" MiB free (")
    console.write(decimal: reclaimed)
    console.write(" handoff pages reclaimed)\n")

    // Exception round trip: take a breakpoint and resume after it.
    arch_breakpoint()
    guard breakpointsHandled == 1 else { panic("breakpoint did not round-trip") }
    console.write("  traps:  vectors installed, breakpoint resumed\n")

    console.write("croi kernel: halting\n")
    arch_halt()
}

private func report(_ error: MapError, to console: some TextOutput) {
    switch error {
    case .unaligned(let virt):
        console.write("unaligned mapping at ")
        console.write(hex: virt)
    case .overlap(let virt):
        console.write("overlapping mapping at ")
        console.write(hex: virt)
    case .outOfMemory:
        console.write("out of memory")
    }
    console.write("\n")
}

/// Summarizes the loader's memory map.
private func reportMemory(_ allocator: BootAllocator, to console: some TextOutput) {
    var free: UInt64 = 0
    var reclaimable: UInt64 = 0
    for i in 0..<allocator.rangeCount {
        let range = allocator.range(i)
        switch range.type {
        case CROI_MEM_FREE: free += range.size
        case CROI_MEM_ACPI_RECLAIM, CROI_MEM_HANDOFF: reclaimable += range.size
        default: ()
        }
    }
    console.write("  memory: ")
    console.write(decimal: UInt64(allocator.rangeCount))
    console.write(" ranges, ")
    console.write(decimal: free >> 20)
    console.write(" MiB free, ")
    console.write(decimal: reclaimable >> 10)
    console.write(" KiB reclaimable\n")
}

/// Allocates, touches and frees pages through every PMM entry point, and
/// checks the books balance.
private func pmmSelfTest() {
    let before = pmm.freePages
    guard let a = pmm.allocatePage(), let b = pmm.allocatePage(), a != b,
          pmm.state(of: a) == .alloc, pmm.state(of: b) == .alloc
    else { panic("pmm self-test: single page allocation") }

    let runPages: UInt64 = 16
    guard let run = pmm.allocateContiguous(runPages, alignLog2: 16), run % 0x1_0000 == 0 else {
        panic("pmm self-test: contiguous allocation")
    }
    for i in 0..<runPages {
        let phys = run + i * KernelLayout.pageSize
        guard pmm.state(of: phys) == .alloc else { panic("pmm self-test: contiguous page state") }
        // The page must be reachable and writable through the physmap.
        let word = unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(phys)))!
        unsafe word.pointee = phys ^ 0x5A5A_5A5A
        guard unsafe word.pointee == phys ^ 0x5A5A_5A5A else { panic("pmm self-test: physmap write") }
    }
    guard pmm.freePages == before - 2 - runPages else { panic("pmm self-test: free count") }

    pmm.free(a)
    pmm.free(b)
    pmm.free(run, count: runPages)
    guard pmm.freePages == before, pmm.state(of: a) == .free else { panic("pmm self-test: free") }
}
