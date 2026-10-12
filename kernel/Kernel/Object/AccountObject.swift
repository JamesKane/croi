import CKernel

/// A memory account as a kernel object (K15a; Todhchai ext 6, F-109;
/// include/account.h): user space's handle to a `MemoryAccountRecord`.
/// Created under the MEMORY system resource; a process charges the one
/// it was given (its creator's unless process_set_account replaced it).
struct AccountObject: ~Copyable {
    var header = ObjectHeader(type: .memoryAccount)
    /// A reference (VMOs charged to the account hold their own).
    let account: MemoryAccountPointer

    static var defaultRights: Rights { Rights.basic.union(.write | .charge) }
}

@safe struct MemoryAccountObjectPointer {
    let object: ObjectPointer

    var pointee: AccountObject {
        unsafeAddress { unsafe UnsafePointer<AccountObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<AccountObject>(bitPattern: UInt(object.address))! }
    }
}

enum Accounts {
    /// account_create: `limit` bytes, warning and critical levels in
    /// percent of it (0: off; each at most 100).
    static func create(limit: UInt64, warning: UInt64, critical: UInt64) throws(Status) -> ObjectPointer {
        guard warning <= 100, critical <= 100 else { throw .invalidArgs }
        let owner = MemoryAccount(limit: limit, pressurePercent: warning, criticalPercent: critical)
        let record = owner.record
        record.retain()  // the object's; the owner's goes with it
        _ = consume owner
        guard let object = Objects.allocate(AccountObject(account: record)) else {
            record.release()
            throw .noMemory
        }
        return object
    }

    static func destroy(_ object: ObjectPointer) {
        MemoryAccountObjectPointer(object: object).pointee.account.release()
        Objects.free(object, as: AccountObject.self)
    }

    /// The account behind handle `handle` (needing `rights`), retained.
    static func account(_ table: borrowing HandleTable, _ handle: UInt32, rights: Rights) throws(Status)
        -> MemoryAccountPointer {
        let ref = try table.get(handle, type: .memoryAccount, rights: rights)
        let account = MemoryAccountObjectPointer(object: ref.object).pointee.account
        account.retain()
        return account
    }

    /// The calling thread's process's account, not retained (nil: a kernel
    /// thread, or an unaccounted process). Set only before the process
    /// started, so a running process reads it without a lock.
    static func current() -> MemoryAccountPointer? {
        let me = Scheduler.current
        guard me.pointee.object != 0 else { return nil }
        let process = ThreadObjectPointer(object: ObjectPointer(address: me.pointee.object)).pointee.process
        return ProcessPointer(object: process).pointee.account
    }

    /// What a VMO the caller creates charges: the account behind
    /// CROI_VMO_CHARGE_TO's handle (CHARGE), else its process's. Retained
    /// for the caller to release when the VMO has taken its own reference.
    static func forNewVmo(_ table: borrowing HandleTable, chargeTo handle: UInt32?) throws(Status) -> MemoryAccountPointer? {
        if let handle { return try account(table, handle, rights: .charge) }
        guard let own = current() else { return nil }
        own.retain()
        return own
    }

    static func info(_ object: ObjectPointer) -> croi_info_memory_account_t {
        let s = MemoryAccountObjectPointer(object: object).pointee.account.snapshot()
        return croi_info_memory_account_t(limit: s.limit, charged: s.charged, warning_bytes: s.warning,
                                          critical_bytes: s.critical, level: s.level, padding: 0,
                                          pressure_events: UInt64(s.events))
    }
}

extension Syscalls {
    /// Syscalls 240-243 (account.h).
    static func accountCall(_ number: UInt64, _ a: InlineArray<6, UInt64>, _ table: borrowing HandleTable) throws(Status) {
        let handle = UInt32(truncatingIfNeeded: a[0])
        switch number {
        case 240:  // account_create(resource, limit, warning | critical << 32, out)
            try check(a[3], 4)
            try Resources.check(table, handle, system: UInt64(CROI_RSRC_SYSTEM_MEMORY_BASE))
            let object = try Accounts.create(limit: a[1], warning: a[2] & 0xFFFF_FFFF, critical: a[2] >> 32)
            try put(try table.add(object, rights: AccountObject.defaultRights), a[3])
        case 241:  // account_set_limit(account, limit)
            let ref = try table.get(handle, type: .memoryAccount, rights: .write)
            try MemoryAccountObjectPointer(object: ref.object).pointee.account.setLimit(a[1])
        case 242:  // account_bind_pressure_port(account, port, key)
            let ref = try table.get(handle, type: .memoryAccount, rights: .write)
            let port = try table.get(UInt32(truncatingIfNeeded: a[1]), type: .port, rights: .write)
            let account = MemoryAccountObjectPointer(object: ref.object).pointee.account
            let source = try PacketSourcePointer.make(port: port, key: a[2], type: PortPacket.memoryPressure)
            let old = account.pointee.lock.withLock { () -> UInt64 in
                let old = account.pointee.pressureSource
                account.pointee.pressureSource = source.address
                return old
            }
            if old != 0 { PacketSourcePointer(address: old).retire() }
        case 243:  // process_set_account(process, account): before it starts
            let process = try table.get(handle, type: .process, rights: .write)
            let account = try Accounts.account(table, UInt32(truncatingIfNeeded: a[1]), rights: .charge)
            let p = ProcessPointer(object: process.object)
            let old = process.object.header.lock.withLock { () -> (MemoryAccountPointer?, Bool) in
                guard p.pointee.state == .initial else { return (nil, false) }
                let old = p.pointee.account
                p.pointee.account = account
                return (old, true)
            }
            guard old.1 else {
                account.release()
                throw .badState
            }
            old.0?.release()
        default:
            throw .notSupported
        }
    }
}
