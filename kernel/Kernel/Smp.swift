import CHandoff
import CKernel
import Synchronization

/// One per CPU, heap-allocated at boot and never freed. A CPU finds its
/// own through the per-CPU register (arch_set_percpu / arch_percpu).
struct PerCpu: ~Copyable {
    /// Read by assembly at fixed offsets (stack.h): must stay first.
    var arch = croi_percpu_arch_t()
    /// Dense kernel CPU number; the boot CPU is 0.
    let number: UInt32
    /// Local APIC ID (amd64), MPIDR affinity (arm64), hart ID (rv64).
    let hardwareId: UInt64
    let stack: StackRange
    let online = Atomic<Bool>(false)
    /// Boot self-test results reported by this CPU (SelfTest bits).
    let checkedIn = Atomic<UInt32>(0)
    /// Pending IPI kinds (Ipi mailbox bits).
    let ipiPending = Atomic<UInt32>(0)
    /// This CPU's interrupt controller is set up: it can take IPIs.
    let interruptsReady = Atomic<Bool>(false)
    /// This CPU's TimerQueue (heap; only this CPU touches it).
    let timerQueue: UInt64
    /// Placement (filled from the PPTT by the boot CPU; coreType by itself).
    var topology = CpuTopology()
    /// This CPU's trace ring (Trace), or 0, and whether it is mid-record.
    var traceRing: UInt64 = 0
    /// The running thread's trace id (kept by the scheduler at each switch).
    var traceThread: UInt32 = 0
    let traceWriting = Atomic<Bool>(false)

    init(number: UInt32, hardwareId: UInt64, acpiUid: UInt32, stack: StackRange, timerQueue: UInt64) {
        self.number = number
        self.hardwareId = hardwareId
        self.stack = stack
        self.timerQueue = timerQueue
        topology.acpiUid = acpiUid
    }
}

/// CPU bring-up: the boot CPU's record, then every other enabled CPU in the
/// MADT, each on its own guarded KernelStack.
enum Smp {
    static var maxCpus: Int { 64 }

    /// Physmap/heap addresses of every PerCpu, indexed by CPU number.
    nonisolated(unsafe) private(set) static var records = InlineArray<64, UInt64>(repeating: 0)
    nonisolated(unsafe) private(set) static var count = 0

    /// Installs CPU 0's record. `stack` is the stack it now runs on.
    static func initializeBootCpu(hardwareId: UInt64, acpiUid: UInt32, stack: StackRange) {
        let record = makeRecord(hardwareId: hardwareId, acpiUid: acpiUid, stack: stack)
        unsafe UnsafePointer<PerCpu>(bitPattern: UInt(record))!.pointee.online.store(true, ordering: .releasing)
        arch_set_percpu(record)
    }

    /// Starts every other enabled CPU the MADT lists. Returns how many the
    /// MADT describes (enabled) and how many came online.
    static func startSecondaryCpus(_ acpi: AcpiTables, bootHardwareId: UInt64, kernelDelta: UInt64)
        -> (found: Int, online: Int)
    {
        let conduit = PsciConduit(acpi)
        var found = 0
        var online = 1  // this CPU
        Madt.forEachCpu(acpi) { cpu in
            guard cpu.enabled else { return }
            found += 1
            guard cpu.hardwareId != bootHardwareId, count < maxCpus else { return }
            if start(cpu, kernelDelta: kernelDelta, conduit: conduit) {
                online += 1
            }
        }
        return (found, online)
    }

    private static func start(_ cpu: CpuDescriptor, kernelDelta: UInt64, conduit: PsciConduit) -> Bool {
        let stack: StackRange
        do throws(VmError) {
            stack = try KernelStack().keepForever()
        } catch {
            return false
        }
        let record = makeRecord(hardwareId: cpu.hardwareId, acpiUid: cpu.acpiUid, stack: stack)

        // The startup block is read by physical address with the MMU off.
        guard let raw = unsafe heap.allocate(size: Int(CROI_AP_SIZE), alignment: 64) else { return false }
        let block = unsafe raw.bindMemory(to: croi_ap_startup_t.self, capacity: 1)
        unsafe block.initialize(to: croi_ap_startup_t())
        unsafe block.pointee.stack = stack.top
        unsafe block.pointee.percpu = record
        unsafe block.pointee.delta = kernelDelta
        unsafe arch_ap_capture_mmu(block)
        let blockVirt = UInt64(UInt(bitPattern: raw))
        arch_clean_dcache(blockVirt, UInt64(CROI_AP_SIZE))
        let blockPhys = blockVirt - KernelLayout.physmapBase
        #if arch(x86_64)
        X86ApStartup.block = UInt64(UInt(bitPattern: raw))
        #endif
        let entryPhys = arch_ap_entry_address() - kernelDelta

        guard startCpu(cpu.hardwareId, entry: entryPhys, context: blockPhys, conduit: conduit) else {
            return false
        }
        let percpu = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(record))!
        for _ in 0..<50_000_000 {
            if unsafe percpu.pointee.online.load(ordering: .acquiring) {
                return true
            }
            arch_spin_pause()
        }
        return false
    }

    /// Asks firmware to start `hardwareId` at physical `entry`.
    private static func startCpu(_ hardwareId: UInt64, entry: UInt64, context: UInt64, conduit: PsciConduit) -> Bool {
        #if arch(riscv64)
        let hsm: UInt64 = 0x48_534D  // "HSM"
        return arch_sbi_call(hsm, 0, hardwareId, entry, context) == 0  // hart_start
        #elseif arch(arm64)
        guard conduit.available else { return false }
        let cpuOn: UInt64 = 0xC400_0003  // CPU_ON, SMC64 calling convention
        return arch_psci_call(cpuOn, hardwareId, entry, context, conduit.useHvc ? 1 : 0) == 0
        #elseif arch(x86_64)
        return X86ApStartup.start(apicId: hardwareId, context: context)
        #endif
    }

    private static func makeRecord(hardwareId: UInt64, acpiUid: UInt32, stack: StackRange) -> UInt64 {
        guard let raw = unsafe heap.allocate(size: MemoryLayout<PerCpu>.size, alignment: 64) else {
            panic("smp: out of memory for a PerCpu record")
        }
        guard let queueRaw = unsafe heap.allocate(size: MemoryLayout<TimerQueue>.size, alignment: 16) else {
            panic("smp: out of memory for a timer queue")
        }
        unsafe queueRaw.bindMemory(to: TimerQueue.self, capacity: 1).initialize(to: TimerQueue())
        let record = unsafe raw.bindMemory(to: PerCpu.self, capacity: 1)
        unsafe record.initialize(to: PerCpu(number: UInt32(count), hardwareId: hardwareId, acpiUid: acpiUid,
                                            stack: stack, timerQueue: UInt64(UInt(bitPattern: queueRaw))))
        let address = UInt64(UInt(bitPattern: raw))
        records[count] = address
        count += 1
        return address
    }
}

/// How to reach PSCI on arm64 (FADT ARM boot architecture flags).
struct PsciConduit {
    var available = false
    var useHvc = false

    init(_ acpi: AcpiTables) {
        #if arch(arm64)
        guard let fadt = acpi.table("FACP") else { return }
        acpi.withTable(fadt) { (table: RawSpan) in
            guard table.byteCount >= 131 else { return }
            let flags = table.load(fromByteOffset: 129, as: UInt16.self)
            available = flags & 1 != 0  // PSCI_COMPLIANT
            useHvc = flags & 2 != 0     // PSCI_USE_HVC
        }
        #endif
    }
}

/// A secondary CPU's first Swift code (smp.h), on its own stack with its
/// per-CPU register set. There is nothing to run yet: check in, take part
/// in the boot self-test, and idle.
@c @implementation
func kernel_ap_main(_ percpu: UInt64) -> Never {
    arch_ap_init_exceptions()
    let record = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(percpu))!
    unsafe record.pointee.online.store(true, ordering: .releasing)

    var results: UInt32 = 0
    #if arch(riscv64)
    let hardwareOk = true  // S-mode can't read its own hart ID
    #else
    let hardwareOk = unsafe arch_cpu_hardware_id() == record.pointee.hardwareId
    #endif
    if unsafe Cpu.current == record.pointee.number && hardwareOk {
        results |= SmpSelfTest.identity
    }
    SmpSelfTest.contend()
    results |= SmpSelfTest.contended
    unsafe record.pointee.checkedIn.store(results, ordering: .releasing)

    CpuTopologies.recordThisCpuCoreType()
    // The local interrupt controller first: mapping the stacks below can
    // trigger a TLB shootdown, which sends IPIs through it.
    Interrupts.initializeThisCpu()
    CpuStacks.installThisCpu()
    Timers.initializeThisCpu()
    unsafe record.pointee.interruptsReady.store(true, ordering: .releasing)
    unsafe Scheduler.becomeIdle(stack: record.pointee.stack)
}

/// Cross-CPU boot self-test: per-CPU identity, and a counter incremented
/// under one SpinLock by every CPU at once.
///
/// The increment is a deliberately non-atomic load + store (relaxed
/// atomics, so the compiler can't fold the loop): it only adds up if the
/// lock provides mutual exclusion. CPUs wait at `go` so they all contend
/// together.
enum SmpSelfTest {
    static var identity: UInt32 { 1 }
    static var contended: UInt32 { 2 }
    static var iterations: Int { 100_000 }

    static let lock = SpinLock()
    static let counter = Atomic<Int>(0)
    static let go = Atomic<Bool>(false)

    static func contend() {
        while !go.load(ordering: .acquiring) {
            arch_spin_pause()
        }
        for _ in 0..<iterations {
            lock.withLock {
                counter.store(counter.load(ordering: .relaxed) + 1, ordering: .relaxed)
            }
        }
    }

    /// Releases every CPU into the test, runs the boot CPU's share, then
    /// checks every online CPU's results.
    static func run() -> Bool {
        go.store(true, ordering: .releasing)
        contend()
        var online = 0
        for i in 1..<Smp.count {
            let record = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(Smp.records[i]))!
            guard unsafe record.pointee.online.load(ordering: .acquiring) else { continue }
            online += 1
            var results: UInt32 = 0
            for _ in 0..<200_000_000 {
                results = unsafe record.pointee.checkedIn.load(ordering: .acquiring)
                if results & contended != 0 { break }
                arch_spin_pause()
            }
            guard results == identity | contended else { return false }
        }
        return lock.withLock { counter.load(ordering: .relaxed) } == (online + 1) * iterations
    }
}

#if arch(x86_64)
import PageTables

/// INIT-SIPI-SIPI through the local APIC. One CPU at a time: they share the
/// trampoline page and its bootstrap page tables.
enum X86ApStartup {
    /// The startup block for the CPU being started (heap, virtual).
    nonisolated(unsafe) static var block: UInt64 = 0

    static func start(apicId: UInt64, context: UInt64) -> Bool {
        let trampoline = pmm.lowTrampolinePage
        guard trampoline != 0, block != 0 else { return false }

        // Bootstrap PML4 below 4 GiB (CR3 is loaded in 32-bit mode): the
        // trampoline page 1:1 plus the kernel half, shared with the kernel's.
        guard let pml4 = pmm.allocatePage(.mmu), pml4 < 1 << 32 else { return false }
        let pml4Entries = unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(pml4)))!
        let kernelRoot = unsafe UnsafeMutablePointer<croi_ap_startup_t>(bitPattern: UInt(block))!.pointee.root
        let kernelEntries = unsafe UnsafePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(kernelRoot)))!
        for i in 0..<512 {
            unsafe pml4Entries[i] = i >= 256 ? kernelEntries[i] : 0
        }
        let bootstrap = ArchAspace(rootLow: pml4, rootHigh: pml4)
        defer {
            try? bootstrap.unmap(virt: trampoline, size: KernelLayout.pageSize)
            pmm.free(pml4)
        }
        do throws(VmError) {
            try bootstrap.map(virt: trampoline, phys: trampoline, size: KernelLayout.pageSize,
                              MapAttributes(writable: true, executable: true))
        } catch {
            return false
        }

        let blockPointer = unsafe UnsafePointer<croi_ap_startup_t>(bitPattern: UInt(block))!
        unsafe arch_ap_prepare_trampoline(UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(trampoline)))!,
                                          trampoline, pml4, blockPointer)

        let vector = trampoline >> 12
        guard sendIpi(apicId, 0x4500) else { return false }                  // INIT, assert
        Clock.delay(nanoseconds: 10_000_000)                                  // 10 ms
        for _ in 0..<2 {
            guard sendIpi(apicId, 0x4600 | vector) else { return false }     // STARTUP
            Clock.delay(nanoseconds: 200_000)                                 // 200 us
        }
        // Wait here, while the bootstrap tables still exist.
        let percpu = unsafe blockPointer.pointee.percpu
        for _ in 0..<50_000_000 {
            if unsafe UnsafePointer<PerCpu>(bitPattern: UInt(percpu))!.pointee.online.load(ordering: .acquiring) {
                return true
            }
            arch_spin_pause()
        }
        return false
    }

    private static func sendIpi(_ apicId: UInt64, _ command: UInt64) -> Bool {
        LocalApic.sendCommand(apicId: apicId, command)
    }
}

#endif

/// This CPU's own stacks for faults that can't use the current one: amd64
/// IST1 (NMI, #DF, #MC) in its own TSS and GDT, arm64/rv64 the emergency
/// stack the exception entry switches to on overflow. Guarded, permanent.
enum CpuStacks {
    static func installThisCpu() {
        let stack: StackRange
        do throws(VmError) {
            stack = try KernelStack().keepForever()
        } catch {
            panic("cpu: no memory for an exception stack")
        }
        let record = unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!
        unsafe record.pointee.arch.emergency_stack_top = stack.top
        // Every CPU the same way (they are alike: a mixed system would turn
        // it off for all).
        croi_user_protection = arch_user_protection_enable() != 0 ? 1 : 0
        arch_user_counter_enable()
        #if arch(x86_64)
        // GDT (8 entries) and TSS (104 bytes), never freed.
        guard let gdt = unsafe heap.allocate(size: 64, alignment: 16),
              let tss = unsafe heap.allocate(size: 104, alignment: 16)
        else { panic("cpu: no memory for GDT/TSS") }
        unsafe arch_install_cpu_descriptors(gdt, tss, stack.top)
        unsafe record.pointee.arch.tss = UInt64(UInt(bitPattern: tss))
        arch_syscall_init()
        #endif
    }

    /// The stack installed for this CPU (0 before `installThisCpu`).
    static var thisCpu: UInt64 {
        unsafe UnsafePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!.pointee.arch.emergency_stack_top
    }
}

/// CPU placement from the PPTT, plus each CPU's own core type.
enum CpuTopologies {
    /// Fills every record's placement. False if there is no PPTT.
    static func placeAll(_ acpi: AcpiTables) -> Bool {
        var placed = false
        for i in 0..<Smp.count {
            let record = unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(Smp.records[i]))!
            if unsafe Pptt.place(&record.pointee.topology, acpi) { placed = true }
        }
        return placed
    }

    /// Runs on each CPU (it must read its own ID registers).
    static func recordThisCpuCoreType() {
        let record = unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!
        unsafe record.pointee.topology.coreType = arch_cpu_core_type()
    }

    /// How many distinct values `key` takes across all CPUs.
    static func distinct(_ key: (CpuTopology) -> UInt32) -> Int {
        var count = 0
        for i in 0..<Smp.count {
            let value = key(topology(i))
            var seen = false
            for j in 0..<i where key(topology(j)) == value { seen = true }
            if !seen { count += 1 }
        }
        return count
    }

    static func topology(_ cpu: Int) -> CpuTopology {
        unsafe UnsafePointer<PerCpu>(bitPattern: UInt(Smp.records[cpu]))!.pointee.topology
    }
}
