import CEFI
import CHandoff
import CLoader
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

/// Loader body, declared in loader.h and called from `efi_main` (entry.c).
/// Only returns if loading fails; the firmware then moves on.
@c @implementation
func croi_loader_main(
    _ image: EFI_HANDLE?,
    _ systemTable: UnsafeMutablePointer<EFI_SYSTEM_TABLE>
) -> EFI_STATUS {
    let console = unsafe Console(systemTable.pointee.ConOut)
    console.write("croi loader (")
    console.write(archName)
    console.write(")\n")
    do {
        try unsafe bootKernel(image: image, systemTable: systemTable, console: console)
    } catch {
        error.report(to: console)
    }
    return EFI_LOAD_ERROR
}

/// Loads the kernel, prepares the handoff, exits boot services and jumps.
@unsafe private func bootKernel(
    image: EFI_HANDLE?, systemTable: UnsafeMutablePointer<EFI_SYSTEM_TABLE>, console: Console
) throws(LoaderError) -> Never {
    let boot = unsafe BootServices(systemTable.pointee.BootServices)
    boot.disableWatchdog()

    let unsupported = croi_arch_unsupported()
    guard unsupported == 0 else { throw .unsupported("CPU state left by firmware", unsupported) }

    // Kernel image, loaded at its link address.
    let volume = try unsafe BootVolume(image: image, boot: boot)
    guard let file = try unsafe volume.readIntoPool("\\croi\\kernel.elf") else {
        throw .kernel("\\croi\\kernel.elf not found")
    }
    let (elf, kernelPhys) = try unsafe withPhysical(UInt64(UInt(bitPattern: file.buffer)), size: file.size) {
        (bytes: RawSpan) throws(LoaderError) -> (KernelElf, UInt64) in
        let elf = try KernelElf(parsing: bytes)
        let phys = try boot.allocatePages(elf.size / pageSize, type: CroiMemoryType.kernel)
        try unsafe withPhysicalMutable(phys, size: Int(elf.size)) { (dest: inout MutableRawSpan) throws(LoaderError) in
            try elf.load(from: bytes, into: &dest, runningAt: elf.base)
        }
        return (elf, phys)
    }
    unsafe boot.freePool(file.buffer)
    console.write("kernel: ")
    console.write(decimal: elf.size / 1024)
    console.write(" KiB at ")
    console.write(hex: kernelPhys)
    console.write(", entry ")
    console.write(hex: elf.entry)
    console.write("\n")

    // Optional: the boot filesystem image and the kernel command line.
    let bootfs = try volume.readIntoPages("\\croi\\bootfs.img", type: CroiMemoryType.bootfs)
    let cmdline = try unsafe volume.readIntoPool("\\croi\\cmdline")
    // Close the volume now. Its deinit calls firmware, and bootKernel never
    // returns, so left alone it could run after ExitBootServices.
    _ = consume volume
    console.write("bootfs: ")
    console.write(decimal: UInt64(bootfs?.size ?? 0))
    console.write(" bytes, cmdline: ")
    console.write(decimal: UInt64(unsafe cmdline?.size ?? 0))
    console.write(" bytes\n")

    // ACPI and the console UART: SPCR, then DBG2 (then COM1 on PCs).
    // `loader.console=dbg2` on the command line tries DBG2 first.
    let acpi = unsafe Acpi(systemTable: systemTable)
    let preferDbg2 = unsafe cmdline.map { unsafe commandLine($0.buffer, $0.size, has: "loader.console=dbg2") } ?? false
    var uart = croi_uart_t()
    var uartSource: StaticString = "none"
    for useDbg2 in preferDbg2 ? [true, false] as InlineArray<2, Bool> : [false, true] where uart.kind == CROI_UART_NONE {
        if useDbg2, let dbg2 = acpi?.dbg2Console() {
            uart = dbg2
            uartSource = "DBG2"
        } else if !useDbg2, let spcr = acpi?.spcrConsole() {
            uart = spcr
            uartSource = "SPCR"
        }
    }
    #if arch(x86_64)
    if uart.kind == CROI_UART_NONE {  // PCs without SPCR or DBG2: assume COM1.
        uart.kind = CROI_UART_NS16550_PIO
        uart.base = 0x3F8
        uartSource = "COM1 default"
    }
    #endif
    console.write("acpi: RSDP ")
    console.write(hex: acpi?.rsdp ?? 0)
    console.write(", uart kind ")
    console.write(decimal: UInt64(uart.kind))
    console.write(" at ")
    console.write(hex: uart.base)
    console.write(" (")
    console.write(uartSource)
    console.write(")\n")

    // The GOP framebuffer, if there is a linear one.
    let framebuffer = unsafe findFramebuffer(boot)
    console.write("framebuffer: ")
    console.write(decimal: UInt64(framebuffer.width))
    console.write("x")
    console.write(decimal: UInt64(framebuffer.height))
    console.write(" at ")
    console.write(hex: framebuffer.base)
    console.write("\n")

    // RISC-V S-mode can't read its own hart ID; firmware knows it.
    var bootHartId: UInt64 = 0
    #if arch(riscv64)
    let riscvBoot = try unsafe boot.locateProtocol(.riscvBoot, as: RISCV_EFI_BOOT_PROTOCOL.self)
    var hartId: UInt = 0
    let hartStatus = unsafe croi_efi_boot_hart_id(riscvBoot, &hartId)
    guard hartStatus == EFI_SUCCESS else { throw .firmware("GetBootHartId", hartStatus) }
    bootHartId = UInt64(hartId)
    #endif

    // Handoff block, range table (sized for the largest possible map, plus
    // two for the framebuffer overlay) and the command line.
    var map = try MemoryMap(boot: boot)
    let rangeCapacity = map.maxCount + 2
    let rangesOffset = MemoryLayout<croi_handoff_t>.size
    let cmdlineOffset = rangesOffset + rangeCapacity * MemoryLayout<croi_mem_range_t>.size
    let cmdlineSize = unsafe cmdline?.size ?? 0
    let handoffBytes = UInt64(cmdlineOffset + cmdlineSize)
    let handoffPhys = try boot.allocatePages(roundUp(handoffBytes, to: pageSize) / pageSize, type: CroiMemoryType.handoff)
    let rangesPhys = handoffPhys + UInt64(rangesOffset)
    let cmdlinePhys = handoffPhys + UInt64(cmdlineOffset)
    if let cmdline = unsafe cmdline {
        unsafe UnsafeMutableRawPointer(bitPattern: UInt(cmdlinePhys))!
            .copyMemory(from: cmdline.buffer, byteCount: cmdline.size)
        unsafe boot.freePool(cmdline.buffer)
    }

    // Boot page tables. Mapping all RAM up front covers everything allocated
    // later too, since allocations only change the type of RAM ranges.
    var tables: BootPageTables
    do throws(MapError) {
        tables = try BootPageTables(memory: FirmwarePages(boot: boot))
    } catch {
        throw LoaderError(error)
    }
    try map.refresh(boot: boot)
    var runStart: UInt64 = 0
    var runEnd: UInt64 = 0
    try map.forEach { (type: UInt32, base: UInt64, size: UInt64) throws(LoaderError) in
        guard MemoryMap.isRam(type), base < PageTableFormat.identityLimit else { return }
        let end = min(base + size, PageTableFormat.identityLimit)
        if base == runEnd {
            runEnd = end
            return
        }
        if runEnd > runStart {
            try mapping(&tables, virt: runStart, phys: runStart, size: runEnd - runStart, .identityRam)
        }
        runStart = base
        runEnd = end
    }
    if runEnd > runStart {
        try mapping(&tables, virt: runStart, phys: runStart, size: runEnd - runStart, .identityRam)
    }
    for i in 0..<elf.segmentCount {
        let segment = elf.segments[i]
        try mapping(&tables, 
            virt: segment.vaddr, phys: kernelPhys + (segment.vaddr - elf.base),
            size: roundUp(segment.memsz, to: pageSize),
            MapAttributes(writable: segment.writable, executable: segment.executable, global: true))
    }
    if uart.kind == CROI_UART_NS16550_MMIO || uart.kind == CROI_UART_PL011 {
        let page = uart.base & ~(pageSize - 1)
        try mapping(&tables, virt: page, phys: page, size: pageSize, .identityDevice)
    }

    // Point of no return. Only the console write and the final map refresh
    // may still fail; after ExitBootServices nothing can be reported.
    console.write("croi loader: starting kernel\n")
    try map.refresh(boot: boot)
    var status = unsafe boot.exitBootServices(image: image, key: map.key)
    if status == EFI_INVALID_PARAMETER {  // the map changed under us; retry once
        try map.refresh(boot: boot)
        status = unsafe boot.exitBootServices(image: image, key: map.key)
    }
    guard status == EFI_SUCCESS else { throw .firmware("ExitBootServices", status) }

    let ranges = unsafe UnsafeMutablePointer<croi_mem_range_t>(bitPattern: UInt(rangesPhys))!
    var rangeCount = unsafe buildRangeTable(from: map, into: ranges, capacity: rangeCapacity)
    if framebuffer.format != CROI_PIXEL_NONE {
        // Never cached, never allocated: whatever memory it sits in.
        let base = framebuffer.base & ~(pageSize - 1)
        unsafe rangeCount = overlayRange(ranges, count: rangeCount, capacity: rangeCapacity, base: base,
                                         size: roundUp(framebuffer.base + framebuffer.size, to: pageSize) - base,
                                         type: CROI_MEM_FRAMEBUFFER)
    }
    let handoff = unsafe UnsafeMutablePointer<croi_handoff_t>(bitPattern: UInt(handoffPhys))!
    unsafe handoff.pointee = croi_handoff_t(
        magic: CROI_HANDOFF_MAGIC,
        version: CROI_HANDOFF_VERSION,
        size: UInt32(MemoryLayout<croi_handoff_t>.size),
        kernel_phys: kernelPhys,
        kernel_virt: elf.base,
        kernel_size: elf.size,
        acpi_rsdp: acpi?.rsdp ?? 0,
        efi_system_table: UInt64(UInt(bitPattern: systemTable)),
        memory_map: rangesPhys,
        memory_map_count: UInt64(rangeCount),
        uart: uart,
        boot_hart_id: bootHartId,
        bootfs: bootfs?.phys ?? 0,
        bootfs_size: UInt64(bootfs?.size ?? 0),
        cmdline: cmdlineSize > 0 ? cmdlinePhys : 0,
        cmdline_size: UInt64(cmdlineSize),
        framebuffer: framebuffer)

    // Everything the kernel reads early must be visible with the MMU off.
    for i in 0..<rangeCount {
        let range = unsafe ranges[i]
        if range.type == CROI_MEM_KERNEL || range.type == CROI_MEM_HANDOFF {
            croi_arch_clean_dcache(range.base, range.size)
        }
    }
    croi_arch_enter_kernel(tables.rootLow, tables.rootHigh, elf.entry, handoffPhys)
}

/// Adds a boot mapping, reporting failure as a LoaderError.
private func mapping(
    _ tables: inout BootPageTables, virt: UInt64, phys: UInt64, size: UInt64, _ attributes: MapAttributes
) throws(LoaderError) {
    do throws(MapError) {
        try tables.map(virt: virt, phys: phys, size: size, attributes)
    } catch {
        throw LoaderError(error)
    }
}

/// The GOP's current mode as a croi framebuffer; format CROI_PIXEL_NONE if
/// there's no GOP or it has no linear framebuffer (Blt only).
@unsafe private func findFramebuffer(_ boot: BootServices) -> croi_framebuffer_t {
    var framebuffer = croi_framebuffer_t()
    guard let gop = try? unsafe boot.locateProtocol(.graphicsOutput, as: EFI_GRAPHICS_OUTPUT_PROTOCOL.self),
          let mode = unsafe gop.pointee.Mode, let info = unsafe mode.pointee.Info
    else { return framebuffer }
    let format: UInt32 = switch unsafe info.pointee.PixelFormat {
    case PixelRedGreenBlueReserved8BitPerColor: CROI_PIXEL_RGBX8888
    case PixelBlueGreenRedReserved8BitPerColor: CROI_PIXEL_BGRX8888
    case PixelBitMask: CROI_PIXEL_BITMASK
    default: CROI_PIXEL_NONE
    }
    guard format != CROI_PIXEL_NONE, unsafe mode.pointee.FrameBufferBase != 0 else { return framebuffer }
    unsafe framebuffer.base = mode.pointee.FrameBufferBase
    unsafe framebuffer.size = UInt64(mode.pointee.FrameBufferSize)
    unsafe framebuffer.width = info.pointee.HorizontalResolution
    unsafe framebuffer.height = info.pointee.VerticalResolution
    unsafe framebuffer.stride = info.pointee.PixelsPerScanLine
    framebuffer.format = format
    let masks = unsafe info.pointee.PixelInformation
    framebuffer.red_mask = masks.RedMask
    framebuffer.green_mask = masks.GreenMask
    framebuffer.blue_mask = masks.BlueMask
    framebuffer.reserved_mask = masks.ReservedMask
    return framebuffer
}

/// Whether the command line (ASCII, space separated) contains `word`.
@unsafe private func commandLine(_ buffer: UnsafeMutableRawPointer, _ size: Int, has word: StaticString) -> Bool {
    let text = unsafe UnsafeRawPointer(buffer).assumingMemoryBound(to: UInt8.self)
    let wanted = unsafe word.utf8Start
    let length = word.utf8CodeUnitCount
    var start = 0
    while start < size {
        var end = start
        while end < size, unsafe text[end] != UInt8(ascii: " "), unsafe text[end] != UInt8(ascii: "\n") { end += 1 }
        if end - start == length {
            var same = true
            for i in 0..<length where unsafe text[start + i] != wanted[i] { same = false }
            if same { return true }
        }
        start = end + 1
    }
    return false
}
