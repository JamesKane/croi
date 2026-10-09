import CKernel
import Synchronization

/// A combined CPU+GPU memory budget (Todhchai ext 6, F-109): what the VMOs
/// charged to it may hold. Anonymous VMOs charge pages as they commit;
/// contiguous and device-local (VRAM, BAR, pinned) VMOs charge their whole
/// size up front and are never paged or evicted. Crossing the pressure
/// level calls `pressureHook` once, until usage falls well below it again;
/// K5's ports turn that into the pressure packet. K7 gives each process
/// one; until then it is a kernel object.
struct MemoryAccountRecord: ~Copyable {
    let limit: UInt64
    /// Bytes at which pressure is signalled, and below which it re-arms.
    let pressureLevel: UInt64
    let relief: UInt64
    let lock = SpinLock()
    var charged: UInt64 = 0
    var underPressure = false
    var pressureHook: Timers.Callback?
    var hookArgument: UInt64 = 0
    var pressureEvents = 0
    /// Ext 6: a port reporting pressure (a PacketSource), or 0.
    var pressureSource: UInt64 = 0
    let references = Atomic<Int>(1)
}

@safe struct MemoryAccountPointer: Equatable {
    let address: UInt64

    var pointee: MemoryAccountRecord {
        unsafeAddress { unsafe UnsafePointer<MemoryAccountRecord>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<MemoryAccountRecord>(bitPattern: UInt(address))! }
    }

    func retain() { pointee.references.add(1, ordering: .relaxed) }

    func release() {
        guard pointee.references.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 else { return }
        guard pointee.charged == 0 else { panic("account: freed with memory charged") }
        if pointee.pressureSource != 0 { PacketSourcePointer(address: pointee.pressureSource).retire() }
        let raw = unsafe UnsafeMutablePointer<MemoryAccountRecord>(bitPattern: UInt(address))!
        unsafe raw.deinitialize(count: 1)
        unsafe heap.free(UnsafeMutableRawPointer(raw))
    }

    /// Charges `bytes`; false (nothing charged) if it would exceed the limit.
    func charge(_ bytes: UInt64) -> Bool {
        var hook: Timers.Callback? = nil
        var argument: UInt64 = 0, now: UInt64 = 0, source: UInt64 = 0
        let ok = pointee.lock.withLock { () -> Bool in
            guard pointee.charged + bytes <= pointee.limit else { return false }
            pointee.charged += bytes
            now = pointee.charged
            if !pointee.underPressure, now >= pointee.pressureLevel {
                pointee.underPressure = true
                pointee.pressureEvents += 1
                hook = pointee.pressureHook
                argument = pointee.hookArgument
                source = pointee.pressureSource
            }
            return true
        }
        if let hook { hook(argument, now) }  // outside the lock
        if source != 0 { PacketSourcePointer(address: source).fire(value: now) }
        return ok
    }

    func uncharge(_ bytes: UInt64) {
        pointee.lock.withLock {
            guard pointee.charged >= bytes else { panic("account: uncharged more than charged") }
            pointee.charged -= bytes
            if pointee.underPressure, pointee.charged < pointee.relief { pointee.underPressure = false }
        }
    }
}

/// The owner of a memory account. VMOs charged to it hold references, so
/// it lives until the last of them is gone.
struct MemoryAccount: ~Copyable {
    let record: MemoryAccountPointer

    /// `limit` bytes; pressure at `pressurePercent` of it, re-armed below
    /// 80% of that.
    init(limit: UInt64, pressurePercent: UInt64 = 90) {
        guard let raw = unsafe heap.allocate(size: MemoryLayout<MemoryAccountRecord>.size,
                                             alignment: max(16, MemoryLayout<MemoryAccountRecord>.alignment)) else {
            panic("account: out of memory")
        }
        let level = limit / 100 * pressurePercent
        unsafe raw.bindMemory(to: MemoryAccountRecord.self, capacity: 1)
            .initialize(to: MemoryAccountRecord(limit: limit, pressureLevel: level, relief: level / 10 * 8))
        record = MemoryAccountPointer(address: UInt64(UInt(bitPattern: raw)))
    }

    var charged: UInt64 { record.pointee.lock.withLock { record.pointee.charged } }
    var pressureEvents: Int { record.pointee.lock.withLock { record.pointee.pressureEvents } }

    /// Ext 6: reports pressure to `port` (memoryPressure packets with `key`,
    /// payload[1] the bytes charged).
    func bindPressurePort(_ port: borrowing ObjectRef, key: UInt64) throws(Status) {
        let source = try PacketSourcePointer.make(port: port, key: key, type: PortPacket.memoryPressure)
        let old = record.pointee.lock.withLock { () -> UInt64 in
            let old = record.pointee.pressureSource
            record.pointee.pressureSource = source.address
            return old
        }
        if old != 0 { PacketSourcePointer(address: old).retire() }
    }

    func setPressureHook(_ hook: Timers.Callback?, _ argument: UInt64) {
        record.pointee.lock.withLock {
            record.pointee.pressureHook = hook
            record.pointee.hookArgument = argument
        }
    }

    deinit {
        record.release()
    }
}
