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

    heapSelfTest()
    swiftAllocationSelfTest()
    refSelfTest()
    spinLockSelfTest()
    kernelAspace.adopt(rootLow: tables.rootLow, rootHigh: tables.rootHigh)
    vmSelfTest()
    console.write("  heap:   slabs + large pages; UniqueBox, UniqueArray and Ref allocate and free\n")
    console.write("  locks:  spinlocks mask interrupts, nest, release on throw; pmm and heap locked\n")
    console.write("  vm:     kernel aspace at ")
    console.write(hex: KernelLayout.dynamicBase)
    console.write("; guards, protect, large-page split, table reclaim\n")

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
