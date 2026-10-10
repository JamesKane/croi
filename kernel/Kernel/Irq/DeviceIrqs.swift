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

    /// The CPU that last took `number` (boot test).
    static func lastCpu(_ number: UInt32) -> Int {
        tableLock.withLock {
            guard number < limit, let lastCpus = unsafe lastCpus else { return -1 }
            return Int(unsafe lastCpus[Int(number)])
        }
    }
}
