import CHandoff
import CKernel
import Fmt
import PageTables
import Synchronization

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
    guard handoff.magic == CROI_HANDOFF_MAGIC else { arch_halt() }  // nothing in it can be trusted
    guard handoff.version == CROI_HANDOFF_VERSION, handoff.size == UInt32(MemoryLayout<croi_handoff_t>.size),
          handoff.kernel_virt == kernel_image_start()
    else {
        // The magic matched, so the UART description (unchanged since v1) is
        // probably usable: say why before stopping.
        let console = unsafe Uart(handoff.uart)
        console.write("croi kernel: handoff mismatch: version ")
        console.write(decimal: UInt64(handoff.version))
        console.write(" (want ")
        console.write(decimal: UInt64(CROI_HANDOFF_VERSION))
        console.write("), size ")
        console.write(decimal: UInt64(handoff.size))
        console.write(" (want ")
        console.write(decimal: UInt64(MemoryLayout<croi_handoff_t>.size))
        console.write("), image ")
        console.write(hex: handoff.kernel_virt)
        console.write("\n")
        arch_halt()
    }

    bootHandoff = handoff
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
    BootOptions.capture(handoff)  // before the handoff memory is reclaimed
    console.write("  boot:   cmdline \"")
    BootOptions.write(to: console)
    console.write("\", bootfs ")
    console.write(decimal: handoff.bootfs_size)
    console.write(" bytes at ")
    console.write(hex: handoff.bootfs)
    console.write("\n")

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

    heapSelfTest()
    swiftAllocationSelfTest()
    refSelfTest()
    spinLockSelfTest()
    console.write("  heap:   slabs + large pages; UniqueBox, UniqueArray and Ref allocate and free\n")
    console.write("  locks:  spinlocks mask interrupts, nest, release on throw; pmm and heap locked\n")

    // Leave the boot stack (in .bss, unguarded) for a guarded KernelStack.
    kernelAspace.adopt(rootLow: tables.rootLow, rootHigh: tables.rootHigh)
    do throws(VmError) {
        bootThreadStack = try KernelStack().keepForever()
    } catch {
        panic("no memory for the boot thread's stack")
    }
    arch_continue_on_stack(bootThreadStack.top)
}

/// A copy of the loader's handoff (the original is reclaimed by the PMM).
nonisolated(unsafe) var bootHandoff = croi_handoff_t()

/// The boot thread's stack once the VM is up. Lives forever.
nonisolated(unsafe) var bootThreadStack = StackRange()

/// The rest of boot, on `bootThreadStack`. Declared in kernel.h; entered
/// from arch_continue_on_stack.
@c @implementation
func kernel_main_continue() -> Never {
    guard let console = panicConsole else { arch_halt() }
    let acpi = AcpiTables(rsdp: bootHandoff.acpi_rsdp)
    #if arch(riscv64)
    // Memory-type bits in page tables, before mapping anything uncached.
    if let acpi, RiscvIsa.everyHartHas("svpbmt", acpi) {
        PageTableFormat.svpbmt = true
    }
    console.write("  isa:    ")
    if let acpi { RiscvIsa.writeBootIsa(acpi, to: console) }
    console.write(PageTableFormat.svpbmt ? " (Svpbmt in use)\n" : " (no Svpbmt: PMAs decide memory types)\n")
    #endif
    vmSelfTest()
    console.write("  vm:     kernel aspace at ")
    console.write(hex: KernelLayout.dynamicBase)
    console.write("; guards, protect, large-page split, table reclaim\n")

    framebufferSelfTest(console)

    kernelStackSelfTest()
    console.write("  stacks: boot thread on a guarded stack at ")
    console.write(hex: bootThreadStack.base)
    console.write("\n")

    // CPUs: this one's PerCpu record, then everyone else in the MADT.
    #if arch(riscv64)
    let bootHardwareId = bootHandoff.boot_hart_id
    #else
    let bootHardwareId = arch_cpu_hardware_id()
    #endif
    var bootAcpiUid: UInt32 = 0
    if let acpi {
        Madt.forEachCpu(acpi) { cpu in
            if cpu.hardwareId == bootHardwareId { bootAcpiUid = cpu.acpiUid }
        }
    }
    Smp.initializeBootCpu(hardwareId: bootHardwareId, acpiUid: bootAcpiUid, stack: bootThreadStack)
    guard Cpu.current == 0 else { panic("per-CPU register does not identify the boot CPU") }
    CpuTopologies.recordThisCpuCoreType()
    CpuStacks.installThisCpu()
    if let acpi {
        // Interrupt controllers before anyone else starts.
        guard Interrupts.initializeBootCpu(acpi) else { panic("no usable interrupt controller") }
        guard Clock.initialize(acpi) else { panic("no usable clock") }  // interrupts still masked
        Timers.initialize(acpi)
        unsafe UnsafePointer<PerCpu>(bitPattern: UInt(Smp.records[0]))!.pointee.interruptsReady
            .store(true, ordering: .releasing)
        arch_interrupts_enable()
        console.write("  irq:    ")
        console.write(Interrupts.summary)
        console.write(" ")
        console.write(hex: Interrupts.detail)
        console.write("\n")

        let kernelDelta = bootHandoff.kernel_virt &- bootHandoff.kernel_phys
        let (found, online) = Smp.startSecondaryCpus(acpi, bootHardwareId: bootHardwareId, kernelDelta: kernelDelta)
        console.write("  cpus:   ")
        console.write(decimal: UInt64(online))
        console.write(" of ")
        console.write(decimal: UInt64(found))
        console.write(" online (boot cpu ")
        console.write(hex: bootHardwareId)
        console.write(")\n")
        guard SmpSelfTest.run() else { panic("smp self-test: identity or lock contention") }
        console.write("  smp:    per-CPU identity ok; ")
        console.write(decimal: UInt64(online * SmpSelfTest.iterations))
        console.write(" contended lock increments, none lost\n")
        ipiSelfTest(expecting: online - 1, console)
        timeSelfTest(others: online - 1, console)
        cpuStacksSelfTest(console)
        ppttSelfTest()
        watchdogSelfTest()
        #if arch(arm64)
        sErrorSelfTest()
        #endif
        console.write("  wdog:   ")
        if BootOptions.has("croi.watchdog=off") {
            console.write("off (croi.watchdog=off)\n")
        } else if Watchdog.start(acpi) {
            console.write("SBSA generic watchdog on, 30 s timeout, refreshed every 5 s\n")
        } else {
            console.write("none in the GTDT\n")
        }
        console.write("  topo:   ")
        if CpuTopologies.placeAll(acpi) {
            console.write(decimal: UInt64(CpuTopologies.distinct { $0.package }))
            console.write(" package(s), ")
            console.write(decimal: UInt64(CpuTopologies.distinct { $0.core }))
            console.write(" core(s), ")
            console.write(decimal: UInt64(CpuTopologies.distinct { $0.lastLevelCache }))
            console.write(" LLC domain(s), ")
        } else {
            console.write("no PPTT; ")
        }
        console.write(decimal: UInt64(CpuTopologies.distinct { $0.coreType }))
        console.write(" core type(s)\n")

        // From here on the boot code is the "bootstrap" thread.
        unsafe Scheduler.initializeBootCpu(stack: UnsafePointer<PerCpu>(bitPattern: UInt(Smp.records[0]))!.pointee.stack)
        SelfTestDeadman.arm()
        SchedulerSelfTest.run(console)
        MutexSelfTest.run(console)
        DeadlineSelfTest.run(console)
        SelfTestDeadman.done.store(true, ordering: .relaxed)
    } else {
        console.write("  cpus:   no ACPI tables; boot cpu only\n")
    }

    // Exception round trip: take a breakpoint and resume after it.
    arch_breakpoint()
    guard breakpointsHandled == 1 else { panic("breakpoint did not round-trip") }
    console.write("  traps:  vectors installed, breakpoint resumed\n")

    console.write("  irq:    ")
    console.write(decimal: UInt64(Interrupts.unexpectedCount))
    console.write(" unexpected interrupts\n")
    console.write("croi kernel: boot complete, idling\n")
    if Scheduler.readyCpuCount > 0 {
        Scheduler.exit(0)  // CPU 0 goes on with its idle thread
    }
    arch_idle()
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

/// Exercises the heap directly: every size class, large sizes, large
/// alignments; checks alignment, independence of allocations, and that
/// everything (including emptied slabs) is returned.
private func heapSelfTest() {
    guard MemoryLayout<Page>.stride == 32 else { panic("Page record is not 32 bytes") }
    let bytesBefore = heap.bytesInUse
    let pagesBefore = pmm.freePages

    // (size, alignment) cases: classes, class edges, large, aligned.
    var cases = InlineArray<12, (size: Int, alignment: Int)>(repeating: (0, 16))
    cases[0] = (1, 16); cases[1] = (16, 16); cases[2] = (17, 16); cases[3] = (48, 16)
    cases[4] = (100, 16); cases[5] = (2048, 16); cases[6] = (2049, 16); cases[7] = (10_000, 16)
    cases[8] = (48, 64); cases[9] = (100, 4096); cases[10] = (5000, 0x1_0000); cases[11] = (0, 16)

    var pointers = InlineArray<12, UInt>(repeating: 0)
    for i in 0..<cases.count {
        guard let p = unsafe heap.allocate(size: cases[i].size, alignment: cases[i].alignment) else {
            panic("heap self-test: allocation failed")
        }
        let address = UInt(bitPattern: p)
        guard address % UInt(cases[i].alignment) == 0 else { panic("heap self-test: misaligned") }
        unsafe p.initializeMemory(as: UInt8.self, repeating: UInt8(i), count: max(cases[i].size, 1))
        pointers[i] = address
    }
    // No allocation overwrote another.
    for i in 0..<cases.count {
        let p = unsafe UnsafeRawPointer(bitPattern: pointers[i])!
        for b in 0..<max(cases[i].size, 1) where unsafe p.load(fromByteOffset: b, as: UInt8.self) != UInt8(i) {
            panic("heap self-test: allocations overlap")
        }
    }
    for i in 0..<cases.count {
        unsafe heap.free(UnsafeMutableRawPointer(bitPattern: pointers[i])!)
    }
    guard heap.bytesInUse == bytesBefore, pmm.freePages == pagesBefore else {
        panic("heap self-test: memory not returned")
    }
}

/// Ownership-based allocation (no refcounting) must allocate on the heap
/// and give everything back when values are consumed or go out of scope.
/// Refcounted storage (classes, Array, String, Dictionary) does not work in
/// the kernel: see "Embedded Swift and the higher half" in CLAUDE.md.
private func swiftAllocationSelfTest() {
    let bytesBefore = heap.bytesInUse
    do {
        var box = UniqueBox(41)
        box.value += 1
        var numbers = UniqueArray<Int>(capacity: 8)
        for i in 0..<1000 {
            numbers.append(i)
        }
        var sum = 0
        for i in 0..<numbers.count {
            sum += numbers[i]
        }
        guard box.value == 42, numbers.count == 1000, sum == 499_500 else {
            panic("Swift allocation self-test: wrong values")
        }
        guard heap.bytesInUse > bytesBefore else { panic("Swift allocation self-test: nothing allocated") }
    }
    guard heap.bytesInUse == bytesBefore else { panic("Swift allocation self-test: leak") }
}

/// A value whose destruction the Ref self-test can observe.
private struct RefProbe: ~Copyable {
    let id: Int
    deinit { refProbesDestroyed += 1 }
}
nonisolated(unsafe) private var refProbesDestroyed = 0

/// Ref<T>: sharing counts owners, the value outlives all but the last
/// owner, and the last drop destroys it and returns its memory.
private func refSelfTest() {
    let bytesBefore = heap.bytesInUse
    let first = Ref(RefProbe(id: 7))
    let second = first.share()
    let owners = first.ownerCount
    let id = second.value.id
    guard owners == 2, id == 7 else { panic("Ref self-test: sharing") }

    drop(first)
    let ownersAfter = second.ownerCount
    let idAfter = second.value.id
    let destroyedEarly = refProbesDestroyed
    guard destroyedEarly == 0, ownersAfter == 1, idAfter == 7 else {
        panic("Ref self-test: value died with a remaining owner")
    }

    drop(second)
    let destroyed = refProbesDestroyed
    guard destroyed == 1, heap.bytesInUse == bytesBefore else {
        panic("Ref self-test: last owner did not free the value")
    }
}

private func drop<T: ~Copyable>(_ value: consuming T) {}

private enum SpinLockProbe: Error { case thrown }

/// SpinLock: held state, interrupt masking and restore, nesting of
/// distinct locks, and release when the body throws.
private func spinLockSelfTest() {
    let lock = SpinLock()
    let other = SpinLock()
    let interruptsBefore = arch_interrupts_enabled()
    var steps = 0
    lock.withLock {
        guard lock.isHeldByCurrentCpu, !arch_interrupts_enabled() else {
            panic("spinlock self-test: not held, or interrupts not masked")
        }
        other.withLock {
            guard other.isHeldByCurrentCpu else { panic("spinlock self-test: nested lock not held") }
            steps += 1
        }
        guard !other.isHeldByCurrentCpu, lock.isHeldByCurrentCpu else {
            panic("spinlock self-test: nested release")
        }
        steps += 1
    }
    do throws(SpinLockProbe) {
        try lock.withLock { () throws(SpinLockProbe) in throw .thrown }
    } catch {
        steps += 1
    }
    guard steps == 3, !lock.isHeldByCurrentCpu, arch_interrupts_enabled() == interruptsBefore else {
        panic("spinlock self-test: release or interrupt restore")
    }
    guard !heapLock.isHeldByCurrentCpu, !pmmLock.isHeldByCurrentCpu else {
        panic("spinlock self-test: pmm or heap lock left held")
    }
}

/// Kernel address space: guarded allocations, attributes, protect, a large
/// page split by a partial unmap, and full reclamation (pages, tables and
/// regions) when everything is freed.
private func vmSelfTest() {
    do throws(VmError) {
        try vmSelfTestBody()
    } catch {
        panic("vm self-test: unexpected VmError")
    }
}

private func vmSelfTestBody() throws(VmError) {
    let page = KernelLayout.pageSize
    let freeBefore = pmm.freePages
    let regionsBefore = kernelAspace.regionCount
    let data = MapAttributes(writable: true, global: true)

    // Guarded allocations.
    let a = try kernelAspace.allocate(pages: 4)
    let b = try kernelAspace.allocate(pages: 2)
    guard b >= a + 4 * page + KernelAspace.guardSize else { panic("vm self-test: no guard gap") }
    guard kernelAspace.query(a - page) == nil, kernelAspace.query(a + 4 * page) == nil else {
        panic("vm self-test: guard page mapped")
    }
    for (base, count) in [(a, UInt64(4)), (b, UInt64(2))] as InlineArray<2, (UInt64, UInt64)> {
        for i in 0..<count {
            let virt = base + i * page
            guard let t = kernelAspace.query(virt), t.attributes == data, t.pageSize == page else {
                panic("vm self-test: allocation not mapped as expected")
            }
            unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(virt))!.pointee = virt ^ 0xC401
            let viaPhysmap = unsafe UnsafePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(t.physical)))!.pointee
            guard viaPhysmap == virt ^ 0xC401 else { panic("vm self-test: mapping points at the wrong page") }
        }
    }

    // Protect.
    try kernelAspace.withArch { (arch) throws(VmError) in
        try arch.protect(virt: a, size: page, MapAttributes(global: true))
    }
    guard kernelAspace.query(a)?.attributes.writable == false else { panic("vm self-test: protect") }
    try kernelAspace.withArch { (arch) throws(VmError) in try arch.protect(virt: a, size: page, data) }

    // A 2 MiB block, then a 4 KiB hole punched in it.
    let block: UInt64 = 2 << 20
    guard let run = pmm.allocateContiguous(block / page, alignLog2: 21) else { panic("vm self-test: no 2 MiB run") }
    let window = try kernelAspace.reserve(size: block, alignment: block)
    try kernelAspace.withArch { (arch) throws(VmError) in try arch.map(virt: window, phys: run, size: block, data) }
    guard kernelAspace.query(window)?.pageSize == block else { panic("vm self-test: no large page") }
    try kernelAspace.withArch { (arch) throws(VmError) in try arch.unmap(virt: window + 7 * page, size: page) }
    guard kernelAspace.query(window + 7 * page) == nil,
          let after = kernelAspace.query(window + 8 * page), after.physical == run + 8 * page, after.pageSize == page,
          kernelAspace.query(window)?.physical == run
    else { panic("vm self-test: large page split") }
    try kernelAspace.free(window)
    pmm.free(run, count: block / page)

    try kernelAspace.free(a)
    try kernelAspace.free(b)
    guard kernelAspace.regionCount == regionsBefore, pmm.freePages == freeBefore else {
        panic("vm self-test: pages, tables or regions not reclaimed")
    }
}

/// We are running on the boot thread's KernelStack; a second stack gets the
/// alignment exception entry relies on, guard pages on both sides, and is
/// fully reclaimed when dropped.
private func kernelStackSelfTest() {
    var marker: UInt8 = 0
    let sp = withUnsafeMutablePointer(to: &marker) { UInt64(UInt(bitPattern: $0)) }
    guard bootThreadStack.contains(sp) else { panic("stack self-test: not running on the boot thread stack") }

    let freeBefore = pmm.freePages
    do throws(VmError) {
        let stack = try KernelStack()
        guard stack.base % (2 * KernelStack.size) == 0 else { panic("stack self-test: misaligned stack") }
        guard kernelAspace.query(stack.base - KernelLayout.pageSize) == nil,
              kernelAspace.query(stack.top) == nil,
              kernelAspace.query(stack.base) != nil, kernelAspace.query(stack.top - 1) != nil
        else { panic("stack self-test: guard pages") }
    } catch {
        panic("stack self-test: allocation failed")
    }
    guard pmm.freePages == freeBefore else { panic("stack self-test: stack not reclaimed") }
}

/// Maps the GOP framebuffer write-combining and draws a pattern the boot
/// test checks with a QEMU screendump: background (16, 48, 96), and a
/// (240, 192, 32) block at (16, 16) sized 64x32.
private func framebufferSelfTest(_ console: Uart) {
    let framebuffer: Framebuffer?
    do throws(VmError) {
        framebuffer = try Framebuffer(bootHandoff.framebuffer)
    } catch {
        panic("framebuffer: can't map it")
    }
    guard let framebuffer else {
        console.write("  fb:     none\n")
        return
    }
    #if arch(riscv64)
    let expected: CachePolicy = PageTableFormat.svpbmt ? .writeCombining : .cached  // else the PMAs decide
    #else
    let expected = CachePolicy.writeCombining
    #endif
    guard kernelAspace.query(framebuffer.pixels)?.attributes.cache == expected else {
        panic("framebuffer: not mapped write-combining")
    }
    #if arch(x86_64)
    guard arch_rdmsr(0x277) == 0x0007_0106_0007_0106 else { panic("framebuffer: PAT has no WC entry") }
    #endif
    // Never cached: the loader typed it CROI_MEM_FRAMEBUFFER, so it is in no
    // PMM arena and not in the (cached) physmap, even when it is RAM (ramfb).
    let fbPhys = bootHandoff.framebuffer.base
    guard pmm.state(of: fbPhys) == nil, kernelAspace.query(KernelLayout.physmap(fbPhys)) == nil else {
        panic("framebuffer: also reachable as cached RAM")
    }
    let background = framebuffer.pixel(red: 16, green: 48, blue: 96)
    let block = framebuffer.pixel(red: 240, green: 192, blue: 32)
    framebuffer.fill(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height, background)
    framebuffer.fill(x: 16, y: 16, width: 64, height: 32, block)
    guard framebuffer.read(x: 40, y: 30) == block, framebuffer.read(x: 0, y: 0) == background else {
        panic("framebuffer: pixels did not stick")
    }
    console.write("  fb:     ")
    console.write(decimal: UInt64(framebuffer.width))
    console.write("x")
    console.write(decimal: UInt64(framebuffer.height))
    console.write(", format ")
    console.write(decimal: UInt64(bootHandoff.framebuffer.format))
    console.write(", mapped write-combining at ")
    console.write(hex: framebuffer.pixels)
    console.write("\n")
}

/// Probes run on other CPUs by the IPI self-test (C function pointers:
/// they can't capture, so results go through these globals).
private enum IpiProbe {
    static let count = Atomic<Int>(0)
    nonisolated(unsafe) static var seen = InlineArray<64, UInt64>(repeating: 0)

    static let increment: Ipi.Function = { _ in
        count.add(1, ordering: .relaxed)
    }
    static let read: Ipi.Function = { address in
        seen[Int(Cpu.current)] = unsafe UnsafePointer<UInt64>(bitPattern: UInt(address))!.pointee
    }
}

/// Cross-CPU calls reach every other CPU exactly once, and TLB shootdown
/// makes a remapped kernel page visible everywhere: every CPU reads it
/// (caching the translation), the page is remapped to other memory, and
/// every CPU must then see the new contents.
private func ipiSelfTest(expecting others: Int, _ console: Uart) {
    for i in 1..<Smp.count {  // wait for every secondary to take IPIs
        var ready = false
        for _ in 0..<200_000_000 where !ready {
            ready = Ipi.isReady(i)
            arch_spin_pause()
        }
        guard ready else { panic("ipi self-test: a CPU never enabled interrupts") }
    }
    guard Ipi.callOthers(IpiProbe.increment, 0) == others,
          IpiProbe.count.load(ordering: .relaxed) == others
    else { panic("ipi self-test: call did not reach every CPU once") }

    let page = KernelLayout.pageSize
    guard let first = pmm.allocatePage(), let second = pmm.allocatePage() else { panic("ipi self-test: no pages") }
    unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(first)))!.pointee = 0xAAAA
    unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(second)))!.pointee = 0xBBBB
    let data = MapAttributes(writable: true, global: true)
    do throws(VmError) {
        let window = try kernelAspace.reserve(size: page, alignment: page)
        try kernelAspace.withArch { (arch) throws(VmError) in try arch.map(virt: window, phys: first, size: page, data) }
        Ipi.callOthers(IpiProbe.read, window)
        for cpu in 1..<Smp.count where IpiProbe.seen[cpu] != 0xAAAA {
            panic("ipi self-test: first mapping not seen")
        }
        try kernelAspace.withArch { (arch) throws(VmError) in
            try arch.unmap(virt: window, size: page)
            try arch.map(virt: window, phys: second, size: page, data)
        }
        Ipi.callOthers(IpiProbe.read, window)
        for cpu in 1..<Smp.count where IpiProbe.seen[cpu] != 0xBBBB {
            panic("ipi self-test: stale translation after shootdown")
        }
        try kernelAspace.free(window)
    } catch {
        panic("ipi self-test: VmError")
    }
    pmm.free(first)
    pmm.free(second)
    console.write("  ipi:    sync calls reach ")
    console.write(decimal: UInt64(others))
    console.write(" CPUs; remapped page seen everywhere after shootdown\n")
}

/// Results reported by timer callbacks (C function pointers: no captures).
private enum TimerProbe {
    nonisolated(unsafe) static var firedAt = InlineArray<3, UInt64>(repeating: 0)
    nonisolated(unsafe) static var firedInInterrupt = InlineArray<3, UInt64>(repeating: 0)
    static let cpusFired = Atomic<Int>(0)

    static let record: Timers.Callback = { probe, _ in
        firedAt[Int(probe)] = Clock.now()
        firedInInterrupt[Int(probe)] = Timers.interruptCount
    }
    static let countCpu: Timers.Callback = { _, _ in
        cpusFired.add(1, ordering: .relaxed)
    }
    static let armOnThisCpu: Ipi.Function = { _ in
        Timers.arm(deadline: Clock.now() + 3_000_000, countCpu, 0)
    }
}

/// The clock never goes backwards; timers fire no earlier than their
/// deadline, overlapping windows coalesce into one interrupt, cancelled
/// timers don't fire, and every CPU's timer hardware works.
private func timeSelfTest(others: Int, _ console: Uart) {
    var last = Clock.now()
    for _ in 0..<10_000 {
        let now = Clock.now()
        guard now >= last else { panic("clock self-test: went backwards") }
        last = now
    }

    let ms: UInt64 = 1_000_000
    let start = Clock.now()
    // A may fire anywhere in [2 ms, 12 ms], B exactly at 5 ms: one interrupt.
    guard Timers.arm(deadline: start + 2 * ms, slack: 10 * ms, TimerProbe.record, 0) != nil,
          Timers.arm(deadline: start + 5 * ms, TimerProbe.record, 1) != nil,
          let cancelled = Timers.arm(deadline: start + 20 * ms, TimerProbe.record, 2),
          Timers.cancel(cancelled)
    else { panic("timer self-test: arm/cancel") }

    while Clock.now() < start + 40 * ms {
        arch_spin_pause()
    }
    let a = TimerProbe.firedAt[0], b = TimerProbe.firedAt[1]
    guard a >= start + 2 * ms, b >= start + 5 * ms else { panic("timer self-test: early or missing") }
    guard TimerProbe.firedInInterrupt[0] == TimerProbe.firedInInterrupt[1] else {
        panic("timer self-test: overlapping windows did not coalesce")
    }
    guard TimerProbe.firedAt[2] == 0 else { panic("timer self-test: cancelled timer fired") }

    Ipi.callOthers(TimerProbe.armOnThisCpu, 0)
    let deadline = Clock.now() + 1_000 * ms
    while TimerProbe.cpusFired.load(ordering: .relaxed) < others, Clock.now() < deadline {
        arch_spin_pause()
    }
    guard TimerProbe.cpusFired.load(ordering: .relaxed) == others else {
        panic("timer self-test: a CPU's timer never fired")
    }

    console.write("  time:   ")
    console.write(decimal: Clock.frequency / 1_000_000)
    console.write(" MHz counter (")
    console.write(Clock.source)
    console.write("); timers coalesce, exact one ")
    console.write(decimal: (b - (start + 5 * ms)) / 1000)
    console.write(" us late; ")
    console.write(decimal: UInt64(others))
    console.write(" other CPUs' timers fire")
    #if arch(x86_64)
    console.write(Timers.alwaysRunning ? "; ARAT\n" : "; no ARAT (APIC timer stops in deep C-states)\n")
    #else
    console.write("\n")
    #endif
}

/// What each CPU reports about its exception stack.
private enum StackProbe {
    nonisolated(unsafe) static var field = InlineArray<64, UInt64>(repeating: 0)
    nonisolated(unsafe) static var raw = InlineArray<64, UInt64>(repeating: 0)
    nonisolated(unsafe) static var loaded = InlineArray<64, UInt64>(repeating: 0)

    static let report: Ipi.Function = { _ in recordThisCpu() }

    static func recordThisCpu() {
        let cpu = Int(Cpu.current)
        field[cpu] = CpuStacks.thisCpu
        // What the exception entry reads: offset 0 of the PerCpu record.
        raw[cpu] = unsafe UnsafePointer<UInt64>(bitPattern: UInt(arch_percpu()))!.pointee
        #if arch(x86_64)
        loaded[cpu] = arch_ist1_top()
        #else
        loaded[cpu] = raw[cpu]
        #endif
    }
}

/// Every CPU has its own exception stack, where the entry code (and on
/// amd64 the loaded TSS) will find it.
private func cpuStacksSelfTest(_ console: Uart) {
    StackProbe.recordThisCpu()
    Ipi.callOthers(StackProbe.report, 0)
    for cpu in 0..<Smp.count {
        let top = StackProbe.field[cpu]
        guard top != 0, StackProbe.raw[cpu] == top, StackProbe.loaded[cpu] == top else {
            panic("cpu stacks: exception stack not where the entry code looks")
        }
        for other in 0..<cpu where StackProbe.field[other] == top {
            panic("cpu stacks: two CPUs share an exception stack")
        }
    }
    console.write("  stacks: every CPU has its own guarded ")
    #if arch(x86_64)
    console.write("IST1 stack in its own TSS\n")
    #else
    console.write("emergency stack\n")
    #endif
}

/// The PPTT walk against a hand-built table (QEMU's PPTTs have no cache
/// nodes): one package, two cores, each with a private L1 whose next level
/// is a shared L2. Both cores must land in the package, on their own core,
/// with the L2 as their last-level cache.
private func ppttSelfTest() {
    var t = InlineArray<176, UInt8>(repeating: 0)
    let package = 36, l2 = 56, l1a = 80, core0 = 104, core1 = 128, l1b = 152
    // Processor nodes: type 0, flags @4, parent @8, ACPI ID @12, resources @16/@20.
    // Cache nodes: type 1, next level @8.
    pptt(&t, package, type: 0, length: 20); put32(&t, package + 4, 1)  // physical package
    pptt(&t, l2, type: 1, length: 24)
    pptt(&t, l1a, type: 1, length: 24); put32(&t, l1a + 8, UInt32(l2))
    pptt(&t, l1b, type: 1, length: 24); put32(&t, l1b + 8, UInt32(l2))
    for (core, uid, l1) in [(core0, UInt32(0), l1a), (core1, 1, l1b)] as InlineArray<2, (Int, UInt32, Int)> {
        pptt(&t, core, type: 0, length: 24)
        put32(&t, core + 4, 0b1010)  // ACPI ID valid, leaf
        put32(&t, core + 8, UInt32(package))
        put32(&t, core + 12, uid)
        put32(&t, core + 16, 1)
        put32(&t, core + 20, UInt32(l1))
    }

    for (uid, core) in [(UInt32(0), core0), (1, core1)] as InlineArray<2, (UInt32, Int)> {
        var topology = CpuTopology()
        topology.acpiUid = uid
        let placed = Pptt.place(&topology, in: t.span.bytes)
        guard placed, topology.package == UInt32(package), topology.core == UInt32(core),
              topology.lastLevelCache == UInt32(l2), !topology.isThread
        else { panic("pptt self-test: wrong placement") }
    }
}

private func pptt(_ t: inout InlineArray<176, UInt8>, _ at: Int, type: UInt8, length: UInt8) {
    t[at] = type
    t[at + 1] = length
}

private func put32(_ t: inout InlineArray<176, UInt8>, _ at: Int, _ value: UInt32) {
    for i in 0..<4 { t[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
}

/// The SBSA watchdog: GTDT parsing on a hand-built table, and the register
/// programming on two RAM pages standing in for its frames (QEMU's virt
/// machine has no watchdog).
private func watchdogSelfTest() {
    var t = InlineArray<124, UInt8>(repeating: 0)
    put32(&t, 88, 1)                  // platform timer count
    put32(&t, 92, 96)                 // platform timer offset
    t[96] = 1                         // SBSA generic watchdog
    t[97] = 28                        // length
    put32(&t, 100, 0x2A44_0000)       // refresh frame
    put32(&t, 108, 0x2A45_0000)       // control frame
    put32(&t, 116, 48)                // GSIV
    guard SbsaWatchdog.find(in: t.span.bytes)
            == SbsaWatchdog.Description(refreshFrame: 0x2A44_0000, controlFrame: 0x2A45_0000, interrupt: 48)
    else { panic("watchdog self-test: GTDT parse") }

    for method in [.refreshFrame, .offsetRegister] as InlineArray<2, SbsaWatchdog.RefreshMethod> {
        let control: UInt64, refresh: UInt64
        do throws(VmError) {
            control = try kernelAspace.allocate(pages: 1)
            refresh = try kernelAspace.allocate(pages: 1)
        } catch {
            panic("watchdog self-test: no memory")
        }
        let wcs = unsafe UnsafeMutablePointer<UInt32>(bitPattern: UInt(control))!
        let worLow = unsafe UnsafeMutablePointer<UInt32>(bitPattern: UInt(control + 0x8))!
        let worHigh = unsafe UnsafeMutablePointer<UInt32>(bitPattern: UInt(control + 0xC))!
        let wrr = unsafe UnsafeMutablePointer<UInt32>(bitPattern: UInt(refresh))!
        unsafe wrr.pointee = 0xFFFF_FFFF

        var watchdog = SbsaWatchdog(control: control, refresh: refresh, method: method)
        watchdog.enable(timeoutTicks: 0x3_0000_0002)  // offset = half
        guard unsafe wcs.pointee == 1, unsafe worLow.pointee == 0x8000_0001, unsafe worHigh.pointee == 1 else {
            panic("watchdog self-test: enable")
        }
        unsafe worLow.pointee = 0
        watchdog.kick()
        switch method {
        case .refreshFrame:
            guard unsafe wrr.pointee == 0, unsafe worLow.pointee == 0 else { panic("watchdog self-test: refresh frame") }
        case .offsetRegister:
            guard unsafe wrr.pointee == 0xFFFF_FFFF, unsafe worLow.pointee == 0x8000_0001 else {
                panic("watchdog self-test: refresh by offset")
            }
        }
        try? kernelAspace.free(control)
        try? kernelAspace.free(refresh)
    }
}

private func put32(_ t: inout InlineArray<124, UInt8>, _ at: Int, _ value: UInt32) {
    for i in 0..<4 { t[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
}

#if arch(arm64)
/// The SError classifier on synthetic syndromes (QEMU can't inject them).
private func sErrorSelfTest() {
    let serror: UInt64 = 0x2F << 26 | 1 << 25 | 0x11  // EC, IL, DFSC = asynchronous SError
    let cases = [
        (serror | 0b110 << 10, SErrorPolicy.Kind.corrected),
        (serror | 0b011 << 10, .recoverable),
        (serror | 0b010 << 10, .restartable),
        (serror | 0b001 << 10, .unrecoverable),
        (serror | 0b000 << 10, .uncontainable),
        (serror | 1 << 24, .unclassified),           // implementation-defined syndrome
        (0x25 << 26 | 1 << 25, .unclassified),       // a data abort, not an SError
    ] as InlineArray<7, (UInt64, SErrorPolicy.Kind)>
    for i in 0..<cases.count where SErrorPolicy.classify(esr: cases[i].0) != cases[i].1 {
        panic("serror self-test: misclassified")
    }
}
#endif
