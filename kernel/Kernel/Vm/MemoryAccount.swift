import CKernel
import Synchronization

/// A combined CPU+GPU memory budget (Todhchai ext 6, F-109): what the VMOs
/// charged to it may hold. Anonymous VMOs charge pages as they commit;
/// contiguous and device-local (VRAM, BAR, pinned) VMOs charge their whole
/// size up front and are never paged or evicted. Two pressure levels,
/// warning and critical (percent of the limit; 0: none), Fuchsia's: a
/// level is entered at its threshold and left below 80% of it. Entering
/// pressure from normal calls `pressureHook`; every level change fires the
/// bound port's packet (payload[0] limit, [1] charged, [2] events, [3]
/// the level: 0 normal, 1 warning, 2 critical). K15a: user space reaches
/// it as an account object (AccountObject.swift), each process charges one.
struct MemoryAccountRecord: ~Copyable {
    var limit: UInt64
    let warningPercent: UInt64
    let criticalPercent: UInt64
    let lock = SpinLock()
    var charged: UInt64 = 0
    /// 0 normal, 1 warning, 2 critical.
    var level: UInt32 = 0
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

    /// A level's threshold in bytes (0: that level is off).
    private func threshold(_ level: UInt32) -> UInt64 {
        let percent = level == 2 ? pointee.criticalPercent : pointee.warningPercent
        guard percent != 0 else { return 0 }
        // limit x percent / 100 exactly (dividing first lost up to 99%
        // of 100 bytes), without overflow for huge limits.
        return UInt64(100).dividingFullWidth(pointee.limit.multipliedFullWidth(by: percent)).quotient
    }

    /// The level `charged` reaches going up.
    private func risen(_ charged: UInt64) -> UInt32 {
        if threshold(2) != 0, charged >= threshold(2) { return 2 }
        if threshold(1) != 0, charged >= threshold(1) { return 1 }
        return 0
    }

    /// The level after `charged` changed (lock held): up at a threshold,
    /// down below 80% of the current level's.
    private func settledLocked() -> UInt32 {
        var level = max(pointee.level, risen(pointee.charged))
        while level > 0, pointee.charged < threshold(level) / 10 * 8 { level -= 1 }
        return max(level, risen(pointee.charged))
    }

    /// Applies a level change found under the lock: the hook (entering
    /// pressure) and the packet, outside it.
    private func report(from old: UInt32, to new: UInt32, charged: UInt64, limit: UInt64, hook: Timers.Callback?,
                        argument: UInt64, source: UInt64) {
        guard new != old else { return }
        if old == 0, let hook { hook(argument, charged) }
        if source != 0 {
            PacketSourcePointer(address: source).fire(value: charged, word0: limit, word3: UInt64(new))
        }
    }

    /// Charges `bytes`; false (nothing charged) if it would exceed the limit.
    func charge(_ bytes: UInt64) -> Bool {
        var old: UInt32 = 0, new: UInt32 = 0, now: UInt64 = 0, limit: UInt64 = 0
        var hook: Timers.Callback? = nil, argument: UInt64 = 0, source: UInt64 = 0
        let ok = pointee.lock.withLock { () -> Bool in
            guard pointee.charged + bytes <= pointee.limit else { return false }
            pointee.charged += bytes
            (old, now, limit) = (pointee.level, pointee.charged, pointee.limit)
            new = settledLocked()
            if new != old {
                pointee.level = new
                if old == 0 { pointee.pressureEvents += 1 }
                (hook, argument, source) = (pointee.pressureHook, pointee.hookArgument, pointee.pressureSource)
            }
            return true
        }
        report(from: old, to: new, charged: now, limit: limit, hook: hook, argument: argument, source: source)
        return ok
    }

    func uncharge(_ bytes: UInt64) {
        var old: UInt32 = 0, new: UInt32 = 0, now: UInt64 = 0, limit: UInt64 = 0, source: UInt64 = 0
        pointee.lock.withLock {
            guard pointee.charged >= bytes else { panic("account: uncharged more than charged") }
            pointee.charged -= bytes
            (old, now, limit) = (pointee.level, pointee.charged, pointee.limit)
            new = settledLocked()
            if new != old {
                pointee.level = new
                source = pointee.pressureSource
            }
        }
        report(from: old, to: new, charged: now, limit: limit, hook: nil, argument: 0, source: source)
    }

    /// account_set_limit: never below what is charged (BAD_STATE: a budget
    /// shrinks only after its holder has seen the pressure that frees the
    /// memory); the levels follow at once.
    func setLimit(_ newLimit: UInt64) throws(Status) {
        var old: UInt32 = 0, new: UInt32 = 0, now: UInt64 = 0
        var hook: Timers.Callback? = nil, argument: UInt64 = 0, source: UInt64 = 0
        try pointee.lock.withLock { () throws(Status) in
            guard newLimit >= pointee.charged else { throw .badState }
            pointee.limit = newLimit
            (old, now) = (pointee.level, pointee.charged)
            new = settledLocked()
            if new != old {
                pointee.level = new
                if old == 0 { pointee.pressureEvents += 1 }
                (hook, argument, source) = (pointee.pressureHook, pointee.hookArgument, pointee.pressureSource)
            }
        }
        report(from: old, to: new, charged: now, limit: newLimit, hook: hook, argument: argument, source: source)
    }

    /// The account's state, for CROI_INFO_MEMORY_ACCOUNT.
    func snapshot() -> (limit: UInt64, charged: UInt64, warning: UInt64, critical: UInt64, level: UInt32, events: Int) {
        pointee.lock.withLock {
            (pointee.limit, pointee.charged, threshold(1), threshold(2), pointee.level, pointee.pressureEvents)
        }
    }
}

/// The owner of a memory account. VMOs charged to it hold references, so
/// it lives until the last of them is gone.
struct MemoryAccount: ~Copyable {
    let record: MemoryAccountPointer

    /// `limit` bytes; pressure at `pressurePercent` of it, re-armed below
    /// 80% of that; critical at `criticalPercent` (0: none).
    init(limit: UInt64, pressurePercent: UInt64 = 90, criticalPercent: UInt64 = 0) {
        guard let raw = unsafe heap.allocate(size: MemoryLayout<MemoryAccountRecord>.size,
                                             alignment: max(16, MemoryLayout<MemoryAccountRecord>.alignment)) else {
            panic("account: out of memory")
        }
        unsafe raw.bindMemory(to: MemoryAccountRecord.self, capacity: 1)
            .initialize(to: MemoryAccountRecord(limit: limit, warningPercent: pressurePercent,
                                                criticalPercent: criticalPercent))
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
