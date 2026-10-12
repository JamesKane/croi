import _Volatile
import CKernel
import PageTables

/// An MSI allocation (K9d; Zircon's MsiAllocation behind an MsiDispatcher,
/// type 32): `count` contiguous vectors on one CPU, aligned to `count` as
/// multi-message MSI needs, and which ids of it have interrupt objects.
/// amd64 (local APIC vectors), arm64 (LPIs through the GICv3 ITS, K12h)
/// and rv64 (identities of AIA's IMSICs, K12i).
struct MsiObject: ~Copyable {
    var header = ObjectHeader(type: .msi)
    let cpu: Int
    let base: UInt32
    let count: UInt32
    /// Ids with an interrupt object (header lock).
    var idsInUse: UInt32 = 0

    /// ZX_DEFAULT_MSI_RIGHTS.
    static var defaultRights: Rights { .basic }
}

@safe struct MsiPointer {
    let object: ObjectPointer

    var pointee: MsiObject {
        unsafeAddress { unsafe UnsafePointer<MsiObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<MsiObject>(bitPattern: UInt(object.address))! }
    }
}

enum Msis {
    /// msi_allocate (the caller checked the MSI system resource).
    static func allocate(count: UInt32) throws(Status) -> ObjectPointer {
        #if arch(x86_64) || arch(arm64) || arch(riscv64)
        guard count > 0, count <= 32, count & (count - 1) == 0 else { throw .invalidArgs }
        #if arch(arm64)
        guard Its.ready else { throw .notSupported }  // no ITS: no MSIs
        #elseif arch(riscv64)
        guard Aia.active else { throw .notSupported }  // the PLIC: no MSIs
        #endif
        guard let base = DeviceIrqs.allocateMsi(cpu: 0, count: count) else { throw .noResources }
        guard let object = Objects.allocate(MsiObject(cpu: 0, base: base, count: count)) else {
            DeviceIrqs.freeMsi(cpu: 0, vector: base, count: count)
            throw .noMemory
        }
        return object
        #else
        throw .notSupported
        #endif
    }

    static func destroy(_ object: ObjectPointer) {
        #if arch(x86_64) || arch(arm64) || arch(riscv64)
        let msi = MsiPointer(object: object)
        DeviceIrqs.freeMsi(cpu: msi.pointee.cpu, vector: msi.pointee.base, count: msi.pointee.count)
        #endif
        Objects.free(object, as: MsiObject.self)
    }

    /// ZX_INFO_MSI.
    static func info(_ object: ObjectPointer) -> croi_info_msi_t {
        let msi = MsiPointer(object: object)
        var info = croi_info_msi_t()
        #if arch(x86_64) || arch(arm64) || arch(riscv64)
        if let (address, data) = DeviceIrqs.msiMessage(cpu: msi.pointee.cpu, vector: msi.pointee.base) {
            info.target_addr = address
            info.target_data = data
        }
        #endif
        info.base_irq_id = msi.pointee.base
        info.num_irq = msi.pointee.count
        info.interrupt_count = UInt32(object.header.lock.withLock { msi.pointee.idsInUse.nonzeroBitCount })
        return info
    }

    fileprivate static func reserve(_ object: ObjectPointer, id: UInt32) throws(Status) {
        let msi = MsiPointer(object: object)
        try object.header.lock.withLock { () throws(Status) in
            guard id < msi.pointee.count else { throw .invalidArgs }
            guard msi.pointee.idsInUse & (1 << id) == 0 else { throw .alreadyBound }
            msi.pointee.idsInUse |= 1 << id
        }
    }

    fileprivate static func release(_ object: ObjectPointer, id: UInt32) {
        let msi = MsiPointer(object: object)
        object.header.lock.withLock { msi.pointee.idsInUse &= ~(1 << id) }
    }
}

/// One MSI interrupt object's hardware side: its allocation (a reference),
/// id, where it is delivered, and the kernel's mapping of its MSI-X table
/// entry or MSI capability.
struct MsiState {
    let allocation: ObjectPointer
    let id: UInt32
    let msix: Bool
    /// The kernel mapping (shared with the driver: not the kernel's own
    /// MMIO) and the registers in it.
    let window: UInt64
    let registers: UInt64
    /// MSI: per-vector masking, and where its mask bits are.
    let maskBits: UInt64
    var cpu: Int
    var vector: UInt32
    /// Allocated by a move to another CPU (else part of the allocation).
    var ownVector = false
    /// arm64: the device's ITS DeviceID (the event is mapped for it).
    var deviceId: UInt32 = 0
    /// arm64: MAPTI done, so destroy DISCARDs (review fix: a failed create
    /// discarded an event never mapped, a command error that may stall
    /// the ITS queue).
    var itsMapped = false
}

@safe struct MsiStatePointer {
    let address: UInt64

    var pointee: MsiState {
        unsafeAddress { unsafe UnsafePointer<MsiState>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<MsiState>(bitPattern: UInt(address))! }
    }
}

enum MsiInterrupts {
    /// MSI-X table entry registers (32-bit accesses only, PCI 6.8.2).
    private static var entrySize: UInt64 { 16 }
    private static var msiCapabilityId: UInt8 { 0x05 }

    /// msi_create: interrupt object `id` of `allocation`, delivered through
    /// the MSI-X table at `offset` in `vmo` or the MSI capability there.
    static func create(_ allocation: ObjectPointer, options: UInt32, id: UInt32, vmo: VmoPointer,
                       offset: UInt64) throws(Status) -> ObjectPointer {
        #if arch(x86_64) || arch(arm64) || arch(riscv64)
        let msix = options & UInt32(CROI_MSI_MODE_MSI_X) != 0
        guard options & ~UInt32(CROI_MSI_MODE_MSI_X) == 0 else { throw .invalidArgs }
        guard case .physical(let base) = vmo.pointee.kind, vmo.pointee.cache == .device,
              offset < vmo.pointee.size else { throw .invalidArgs }
        let msi = MsiPointer(object: allocation)
        guard id < msi.pointee.count else { throw .invalidArgs }
        let span = msix ? (UInt64(id) + 1) * entrySize : 24
        guard !offset.addingReportingOverflow(span).overflow, offset + span <= vmo.pointee.size else {
            throw .invalidArgs
        }
        try Msis.reserve(allocation, id: id)

        // Map the page(s) holding the entry or capability.
        let first = msix ? offset + UInt64(id) * entrySize : offset
        let length: UInt64 = msix ? entrySize : 24
        let page = KernelLayout.pageSize
        let mapBase = (base + first) & ~(page - 1)
        let mapSize = (base + first + length + page - 1) & ~(page - 1) - mapBase
        let window: UInt64
        do throws(VmError) {
            window = try kernelAspace.mapPhysical(mapBase, size: mapSize,
                                                  MapAttributes(writable: true, cache: .device, global: true),
                                                  shared: true)
        } catch {
            Msis.release(allocation, id: id)
            throw .noMemory
        }
        let registers = window + (base + first - mapBase)
        var maskBits: UInt64 = 0
        if !msix {
            guard read8(registers) == msiCapabilityId else {
                try? kernelAspace.free(window)
                Msis.release(allocation, id: id)
                throw .invalidArgs
            }
            let control = read16(registers + 2)
            if control & (1 << 8) != 0 {                                  // per-vector masking
                maskBits = registers + (control & (1 << 7) != 0 ? 0x10 : 0x0C)  // 64-bit : 32-bit
            }
        }

        let object: ObjectPointer
        do throws(Status) {
            object = try InterruptObjects.makeForMsi()
        } catch {
            try? kernelAspace.free(window)
            Msis.release(allocation, id: id)
            throw error
        }
        guard let raw = unsafe heap.allocate(size: MemoryLayout<MsiState>.size) else {
            try? kernelAspace.free(window)
            Msis.release(allocation, id: id)
            object.release()
            throw .noMemory
        }
        allocation.retain()
        unsafe raw.bindMemory(to: MsiState.self, capacity: 1).initialize(to: MsiState(
            allocation: allocation, id: id, msix: msix, window: window, registers: registers, maskBits: maskBits,
            cpu: msi.pointee.cpu, vector: msi.pointee.base + id))
        let state = MsiStatePointer(address: UInt64(UInt(bitPattern: raw)))
        InterruptPointer(object: object).pointee.msi = state.address
        #if arch(arm64)
        // The ITS maps the event for the device that will write it: the
        // function whose capability this is, or whose MSI-X table (K12h).
        let requester = msix ? Pci.msixOwner(base + offset) : Mcfg.requesterId(base + first)
        guard let requester, let device = Iort.itsDeviceId(requester) else {
            object.release()  // its MSI state goes with it
            throw .notSupported
        }
        state.pointee.deviceId = device
        do throws(Status) {
            try Its.map(deviceId: device, lpi: state.pointee.vector, cpu: state.pointee.cpu)
            state.pointee.itsMapped = true
        } catch {
            object.release()
            throw error
        }
        #endif

        // With interrupt remapping, the entry the message names (a plain
        // MSI's capability tells which function it is; an MSI-X table
        // doesn't). MSI-X: masked, pointed at the vector. Then deliverable.
        DeviceIrqs.prepareMsi(cpu: state.pointee.cpu, vector: state.pointee.vector,
                              source: msix ? nil : Mcfg.requesterId(base + first))
        if msix {
            setMasked(state, true)
            program(state)
        }
        DeviceIrqs.setMsiHandler(cpu: state.pointee.cpu, vector: state.pointee.vector, object.address)
        setMasked(state, false)
        return object
        #else
        throw .notSupported
        #endif
    }

    /// Masks or unmasks it at the device: the MSI-X entry's vector control,
    /// or the capability's mask bit (no-op without per-vector masking).
    static func setMasked(_ state: MsiStatePointer, _ masked: Bool) {
        if state.pointee.msix {
            let control = state.pointee.registers + 12
            write32(control, masked ? read32(control) | 1 : read32(control) & ~1)
        } else if state.pointee.maskBits != 0 {
            // The mask register is shared by the allocation's ids.
            state.pointee.allocation.header.lock.withLock {
                let bits = state.pointee.maskBits, bit: UInt32 = 1 << state.pointee.id
                write32(bits, masked ? read32(bits) | bit : read32(bits) & ~bit)
            }
        }
    }

    /// Writes the MSI-X entry's address and data for its CPU and vector.
    private static func program(_ state: MsiStatePointer) {
        #if arch(x86_64) || arch(arm64) || arch(riscv64)
        guard let (address, data) = DeviceIrqs.msiMessage(cpu: state.pointee.cpu, vector: state.pointee.vector) else {
            return
        }
        write32(state.pointee.registers, UInt32(truncatingIfNeeded: address))
        write32(state.pointee.registers + 4, UInt32(truncatingIfNeeded: address >> 32))
        write32(state.pointee.registers + 8, data)
        #endif
    }

    /// interrupt_set_affinity for an MSI-X vector: a vector on `cpu`, the
    /// entry rewritten under its mask, then the old vector given up. Plain
    /// MSI: NOT_SUPPORTED (the driver programmed the capability). Object
    /// lock held.
    static func retarget(_ state: MsiStatePointer, _ object: ObjectPointer, cpu: Int, masked: Bool) throws(Status) {
        #if arch(x86_64) || arch(arm64) || arch(riscv64)
        guard state.pointee.msix else { throw .notSupported }
        guard cpu != state.pointee.cpu else { return }
        #if arch(arm64)
        // The ITS moves the event's collection; the device's message stays.
        Its.move(deviceId: state.pointee.deviceId, lpi: state.pointee.vector, to: cpu)
        state.pointee.cpu = cpu
        #elseif arch(riscv64)
        // The same identity, sent to the other hart's file: only the
        // address changes, under the entry's mask.
        guard DeviceIrqs.msiMessage(cpu: cpu, vector: state.pointee.vector) != nil else { throw .notSupported }
        setMasked(state, true)
        state.pointee.cpu = cpu
        program(state)
        if !masked { setMasked(state, false) }
        #else
        guard DeviceIrqs.msiMessage(cpu: cpu, vector: DeviceIrqs.msiFirstVector) != nil else { throw .notSupported }
        guard let vector = DeviceIrqs.allocateMsi(cpu: cpu, count: 1) else { throw .noResources }
        DeviceIrqs.prepareMsi(cpu: cpu, vector: vector, source: nil)
        DeviceIrqs.setMsiHandler(cpu: cpu, vector: vector, object.address)
        setMasked(state, true)
        let (oldCpu, oldVector, oldOwn) = (state.pointee.cpu, state.pointee.vector, state.pointee.ownVector)
        state.pointee.cpu = cpu
        state.pointee.vector = vector
        state.pointee.ownVector = true
        program(state)
        if !masked { setMasked(state, false) }
        DeviceIrqs.setMsiHandler(cpu: oldCpu, vector: oldVector, 0)
        DeviceIrqs.releaseMsi(cpu: oldCpu, vector: oldVector)
        if oldOwn { DeviceIrqs.freeMsi(cpu: oldCpu, vector: oldVector, count: 1) }
        #endif
        #else
        throw .notSupported
        #endif
    }

    /// Destroyed: masked, and no handler runs for it once this returns.
    static func detach(_ state: MsiStatePointer) {
        setMasked(state, true)
        #if arch(x86_64) || arch(arm64) || arch(riscv64)
        DeviceIrqs.setMsiHandler(cpu: state.pointee.cpu, vector: state.pointee.vector, 0)
        DeviceIrqs.releaseMsi(cpu: state.pointee.cpu, vector: state.pointee.vector)
        #if arch(arm64)
        if state.pointee.itsMapped {
            Its.unmap(deviceId: state.pointee.deviceId, lpi: state.pointee.vector, cpu: state.pointee.cpu)
        }
        #endif
        #endif
    }

    /// The object's last reference went: the MSI-X entry cleared, the
    /// mapping, vector and id given back.
    static func free(_ state: MsiStatePointer) {
        if state.pointee.msix {
            write32(state.pointee.registers, 0)
            write32(state.pointee.registers + 4, 0)
            write32(state.pointee.registers + 8, 0)
        }
        try? kernelAspace.free(state.pointee.window)
        #if arch(x86_64) || arch(arm64) || arch(riscv64)
        if state.pointee.ownVector { DeviceIrqs.freeMsi(cpu: state.pointee.cpu, vector: state.pointee.vector, count: 1) }
        #endif
        Msis.release(state.pointee.allocation, id: state.pointee.id)
        state.pointee.allocation.release()
        unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(state.address))!)
    }

    private static func read8(_ address: UInt64) -> UInt8 {
        unsafe VolatileMappedRegister<UInt8>(unsafeBitPattern: UInt(address)).load()
    }
    private static func read16(_ address: UInt64) -> UInt16 {
        unsafe VolatileMappedRegister<UInt16>(unsafeBitPattern: UInt(address)).load()
    }
    private static func read32(_ address: UInt64) -> UInt32 {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(address)).load()
    }
    private static func write32(_ address: UInt64, _ value: UInt32) {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(address)).store(value)
    }
}
