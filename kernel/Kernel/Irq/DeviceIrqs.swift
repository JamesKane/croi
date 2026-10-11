import Synchronization
import CKernel

/// Device interrupts for interrupt objects (K9c): one handler per number
/// (amd64 GSI, arm64 INTID, rv64 GSI), routed to one CPU and masked while
/// nobody handles it. The per-arch controller code is in Interrupts.swift.
///
/// `tableLock` guards the handler table and is held while a handler runs,
/// so once `unregister` returns, no handler for that number is running.
/// `controllerLock` serializes controller programming. Lock order: table
/// -> object -> controller.
enum DeviceIrqs {
    private static let tableLock = SpinLock()
    private static let controllerLock = SpinLock()
    /// Interrupt objects by number (0: none), and the CPU that last took
    /// each number (for the boot test and dumps). Heap, sized at boot.
    nonisolated(unsafe) private static var handlers: UnsafeMutablePointer<UInt64>? = nil
    nonisolated(unsafe) private static var lastCpus: UnsafeMutablePointer<UInt8>? = nil

    /// Numbers are below this.
    static var limit: UInt32 {
        #if arch(x86_64)
        IoApic.gsiLimit
        #elseif arch(arm64)
        1020
        #elseif arch(riscv64)
        Plic.gsiBase + Plic.count
        #endif
    }

    /// Allocates the tables (after the controllers are found).
    static func initialize() {
        let count = Int(limit)
        guard let raw = unsafe heap.allocate(size: count * 9) else { panic("irq: no memory for the handler table") }
        unsafe raw.initializeMemory(as: UInt8.self, repeating: 0, count: count * 9)
        unsafe handlers = raw.bindMemory(to: UInt64.self, capacity: count)
        unsafe lastCpus = (raw + count * 8).bindMemory(to: UInt8.self, capacity: count)
        #if arch(x86_64)
        let msiBytes = maxCpus * 8 + maxCpus * Int(msiVectorCount) * 8
        guard let msi = unsafe heap.allocate(size: msiBytes) else { panic("irq: no memory for the MSI tables") }
        unsafe msi.initializeMemory(as: UInt8.self, repeating: 0, count: msiBytes)
        unsafe msiInUse = msi.bindMemory(to: UInt64.self, capacity: maxCpus)
        unsafe msiHandlers = (msi + maxCpus * 8).bindMemory(to: UInt64.self, capacity: maxCpus * Int(msiVectorCount))
        #endif
    }

    /// A number a driver may have: the controller has it and the kernel
    /// doesn't use it.
    static func isValid(_ number: UInt32) -> Bool {
        guard number < limit else { return false }
        #if arch(x86_64)
        return IoApic.isValid(number)
        #elseif arch(arm64)
        return GicV3.isValidSpi(number)
        #elseif arch(riscv64)
        return Plic.isValid(number)
        #endif
    }

    /// An ISA IRQ's number (amd64: through the MADT's overrides).
    static func remapIsa(_ irq: UInt32) -> UInt32 {
        #if arch(x86_64)
        return IoApic.remapIsa(irq)
        #else
        return irq
        #endif
    }

    /// The trigger mode and polarity firmware set up for `number`.
    static func defaultMode(_ number: UInt32) -> (level: Bool, activeLow: Bool) {
        #if arch(x86_64)
        return IoApic.defaultMode(number)
        #elseif arch(arm64)
        return (GicV3.spiIsLevel(number), false)
        #elseif arch(riscv64)
        return (true, false)
        #endif
    }

    /// Installs `object` as `number`'s handler (ALREADY_BOUND if it has one).
    static func register(_ number: UInt32, _ object: ObjectPointer) throws(Status) {
        try tableLock.withLock { () throws(Status) in
            guard let handlers = unsafe handlers else { throw .notSupported }
            guard unsafe handlers[Int(number)] == 0 else { throw .alreadyBound }
            unsafe handlers[Int(number)] = object.address
        }
    }

    /// Removes `number`'s handler; none of its runs is still going on.
    static func unregister(_ number: UInt32) {
        tableLock.withLock {
            guard let handlers = unsafe handlers else { return }
            unsafe handlers[Int(number)] = 0
        }
    }

    /// Programs `number` (masked) with a mode, routed to `cpu`.
    /// NOT_SUPPORTED: a polarity the controller lacks, or a CPU it can't
    /// target.
    static func configure(_ number: UInt32, level: Bool, activeLow: Bool, cpu: Int) throws(Status) {
        let target = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(Smp.records[cpu]))!.pointee.hardwareId
        try controllerLock.withLock { () throws(Status) in
            #if arch(x86_64)
            guard target <= 0xFF else { throw .notSupported }  // 8-bit destinations without remapping
            IoApic.program(number, level: level, activeLow: activeLow, apicId: target)
            #elseif arch(arm64)
            guard !activeLow else { throw .notSupported }  // the GIC takes active-high and rising edges only
            GicV3.programSpi(number, level: level, affinity: target)
            #elseif arch(riscv64)
            guard !activeLow else { throw .notSupported }  // PLIC gateways: active high
            guard Plic.route(number, hart: target) else { throw .notSupported }
            #endif
        }
    }

    static func mask(_ number: UInt32) { setMasked(number, true) }
    static func unmask(_ number: UInt32) { setMasked(number, false) }

    private static func setMasked(_ number: UInt32, _ masked: Bool) {
        controllerLock.withLock {
            #if arch(x86_64)
            IoApic.setMasked(number, masked)
            #elseif arch(arm64)
            GicV3.setSpiMasked(number, masked)
            #elseif arch(riscv64)
            Plic.setMasked(number, masked)
            #endif
        }
    }

    /// Runs `number`'s handler (interrupt context, before the controller's
    /// end of interrupt). A number nobody handles is masked.
    static func dispatch(_ number: UInt32) {
        guard number < limit else { return }
        tableLock.withLock {
            guard let handlers = unsafe handlers, let lastCpus = unsafe lastCpus else { return }
            unsafe lastCpus[Int(number)] = UInt8(truncatingIfNeeded: Cpu.current)
            let object = unsafe handlers[Int(number)]
            if object != 0 {
                InterruptObjects.fire(ObjectPointer(address: object))
            } else {
                mask(number)
            }
        }
    }

    // MARK: MSI (K9d)

    #if arch(x86_64)
    /// Each CPU's MSI vectors: 0xB0..<0xF0 (the fixed ones are 0xF0 up).
    static var msiFirstVector: UInt32 { 0xB0 }
    static var msiVectorCount: UInt32 { 64 }
    private static var maxCpus: Int { 64 }
    /// Per CPU: a bit per vector in use; handlers by cpu * 64 + vector.
    nonisolated(unsafe) private static var msiInUse: UnsafeMutablePointer<UInt64>? = nil
    nonisolated(unsafe) private static var msiHandlers: UnsafeMutablePointer<UInt64>? = nil

    /// `count` (a power of two) contiguous vectors on `cpu`, aligned to
    /// `count` as multi-message MSI needs; the first, or nil.
    static func allocateMsi(cpu: Int, count: UInt32) -> UInt32? {
        tableLock.withLock { () -> UInt32? in
            guard let inUse = unsafe msiInUse, cpu < maxCpus else { return nil }
            let mask: UInt64 = count >= 64 ? ~0 : (1 << UInt64(count)) - 1
            var first: UInt32 = 0
            while first + count <= msiVectorCount {
                if unsafe inUse[cpu] & (mask << UInt64(first)) == 0 {
                    unsafe inUse[cpu] |= mask << UInt64(first)
                    return msiFirstVector + first
                }
                first += count
            }
            return nil
        }
    }

    static func freeMsi(cpu: Int, vector: UInt32, count: UInt32) {
        tableLock.withLock {
            guard let inUse = unsafe msiInUse else { return }
            let mask: UInt64 = count >= 64 ? ~0 : (1 << UInt64(count)) - 1
            unsafe inUse[cpu] &= ~(mask << UInt64(vector - msiFirstVector))
        }
    }

    /// What a device writes to deliver `vector` to `cpu`: the local APIC
    /// message address (physical destination) and data (fixed, edge).
    /// Nil for an APIC ID MSI can't name without interrupt remapping.
    static func msiMessage(cpu: Int, vector: UInt32) -> (address: UInt64, data: UInt32)? {
        let apicId = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(Smp.records[cpu]))!.pointee.hardwareId
        guard apicId <= 0xFF else { return nil }
        return (0xFEE0_0000 | apicId << 12, vector)
    }

    /// Installs `object` for `vector` on `cpu` (0 removes it). Once it
    /// returns, no run of the previous handler is still going on.
    static func setMsiHandler(cpu: Int, vector: UInt32, _ object: UInt64) {
        tableLock.withLock {
            guard let handlers = unsafe msiHandlers else { return }
            unsafe handlers[cpu * Int(msiVectorCount) + Int(vector - msiFirstVector)] = object
        }
    }

    /// A kernel-owned MSI's handler (the IOMMU's fault event): a C-convention
    /// function and its argument.
    typealias KernelMsiHandler = @convention(c) (UInt64) -> Void

    /// Kernel handlers by (CPU, vector): written once, before the device
    /// can send the MSI, never removed, read without `tableLock` (their
    /// owners allocate vectors under their own locks).
    nonisolated(unsafe) private static var kernelMsis = InlineArray<8, (cpu: Int, vector: UInt32, handler: KernelMsiHandler?, argument: UInt64)>(
        repeating: (0, 0, nil, 0))
    private static let kernelMsiCount = Atomic<Int>(0)

    /// Installs a kernel handler for `vector` on `cpu` (from allocateMsi).
    static func setKernelMsiHandler(cpu: Int, vector: UInt32, _ handler: KernelMsiHandler, _ argument: UInt64) {
        let index = kernelMsiCount.load(ordering: .relaxed)
        guard index < kernelMsis.count else { panic("irq: too many kernel MSIs") }
        kernelMsis[index] = (cpu, vector, handler, argument)
        kernelMsiCount.store(index + 1, ordering: .releasing)
    }

    /// An MSI arrived on this CPU (interrupt context, before EOI).
    static func dispatchMsi(_ vector: UInt32) {
        let cpu = Int(Cpu.current)
        for i in 0..<kernelMsiCount.load(ordering: .acquiring) where kernelMsis[i].cpu == cpu && kernelMsis[i].vector == vector {
            kernelMsis[i].handler?(kernelMsis[i].argument)
            return
        }
        tableLock.withLock {
            guard let handlers = unsafe msiHandlers else { return }
            let object = unsafe handlers[Int(Cpu.current) * Int(msiVectorCount) + Int(vector - msiFirstVector)]
            if object != 0 { InterruptObjects.fire(ObjectPointer(address: object)) }
        }
    }
    #endif

    /// The CPU that last took `number` (boot test).
    static func lastCpu(_ number: UInt32) -> Int {
        tableLock.withLock {
            guard number < limit, let lastCpus = unsafe lastCpus else { return -1 }
            return Int(unsafe lastCpus[Int(number)])
        }
    }
}
