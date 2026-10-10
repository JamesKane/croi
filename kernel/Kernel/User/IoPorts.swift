import CKernel
import Synchronization

/// amd64 I/O port access for user space (K9a; Zircon's ioports_request
/// and ioports_release with an IOPORT resource). Each process that asks
/// gets an 8 KiB permission bitmap (one bit per port, 0 = allowed) on its
/// address space; every CPU's TSS carries a bitmap that denies all, into
/// which a switch to a user thread copies its process's (or the deny-all
/// one) when it differs from what is loaded. Bitmaps have ids that are
/// never reused, so a freed one is never mistaken for a new one; a change
/// to a bitmap is pushed by IPI to the CPUs that have it loaded, so a
/// release takes effect everywhere before the call returns.
enum IoPorts {
    static var portCount: UInt64 { 0x1_0000 }
    private static var bitmapBytes: Int { 8192 }
    private static let nextId = Atomic<UInt64>(1)
    /// Per CPU: the id of the bitmap in its TSS (0: deny all).
    nonisolated(unsafe) private static var loaded = InlineArray<64, UInt64>(repeating: 0)

    /// ioports_request (`allow`) / ioports_release for the calling
    /// thread's process.
    static func change(_ table: borrowing HandleTable, resource: UInt32, base: UInt64, count: UInt64,
                       allow: Bool) throws(Status) {
        #if arch(x86_64)
        try Resources.validate(table, resource, kind: UInt32(CROI_RSRC_KIND_IOPORT), base: base, size: count)
        guard count > 0, base < portCount, count <= portCount - base else { throw .invalidArgs }
        guard let aspace = Scheduler.current.pointee.aspace else { throw .badState }
        try aspace.pointee.lock.withLock { () throws(Status) in
            if aspace.pointee.ioBitmap == 0 {
                guard allow else { return }  // nothing was allowed
                guard let raw = unsafe heap.allocate(size: bitmapBytes, alignment: 16) else { throw .noMemory }
                unsafe raw.initializeMemory(as: UInt8.self, repeating: 0xFF, count: bitmapBytes)
                aspace.pointee.ioBitmap = UInt64(UInt(bitPattern: raw))
                aspace.pointee.ioBitmapId = nextId.add(1, ordering: .relaxed).oldValue
            }
            let bits = unsafe UnsafeMutablePointer<UInt8>(bitPattern: UInt(aspace.pointee.ioBitmap))!
            for port in base..<(base + count) {
                let mask = UInt8(1 << (port & 7))
                if allow { unsafe bits[Int(port >> 3)] &= ~mask } else { unsafe bits[Int(port >> 3)] |= mask }
            }
        }
        // Every CPU running it reloads, this one included.
        reload(aspace.address)
        _ = Ipi.callOthers({ address in IoPorts.reload(address) }, aspace.address)
        #else
        throw .notSupported
        #endif
    }

    /// At a switch to a user thread in `aspace` (scheduler lock held).
    static func switched(to aspace: UserAspacePointer, _ me: Int) {
        #if arch(x86_64)
        let id = aspace.pointee.ioBitmapId
        guard id != loaded[me] else { return }
        load(id == 0 ? 0 : aspace.pointee.ioBitmap, me)
        loaded[me] = id
        #endif
    }

    /// IPI (and the caller's CPU): reload `aspace`'s bitmap where it is
    /// loaded or where a thread of its process runs now (the caller holds
    /// a reference meanwhile).
    private static func reload(_ address: UInt64) {
        #if arch(x86_64)
        let saved = arch_interrupts_save()
        defer { arch_interrupts_restore(saved) }
        let aspace = UserAspacePointer(address: address)
        let me = Int(Cpu.current)
        let id = aspace.pointee.ioBitmapId
        guard id != 0, loaded[me] == id || Scheduler.current.pointee.aspace == aspace else { return }
        load(aspace.pointee.ioBitmap, me)
        loaded[me] = id
        #endif
    }

    /// Copies `bitmap` (0: deny all) into this CPU's TSS.
    private static func load(_ bitmap: UInt64, _ me: Int) {
        #if arch(x86_64)
        let percpu = unsafe UnsafePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!
        guard unsafe percpu.pointee.arch.tss != 0 else { return }
        let target = unsafe UnsafeMutableRawPointer(bitPattern: UInt(percpu.pointee.arch.tss + 104))!
        if bitmap == 0 {
            unsafe target.initializeMemory(as: UInt8.self, repeating: 0xFF, count: bitmapBytes)
        } else {
            unsafe target.copyMemory(from: UnsafeRawPointer(bitPattern: UInt(bitmap))!, byteCount: bitmapBytes)
        }
        #endif
    }
}
