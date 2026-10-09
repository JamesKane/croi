import CKernel
import Synchronization

/// A process's handles (Zircon's handle table; processes come in K7):
/// slots of (object, rights). A handle value names a slot and its
/// generation, so a stale value is caught after the slot is reused: bits
/// 31:10 slot + 1, 9:2 generation, 1:0 set (Zircon's fixed bits).
struct HandleTableRecord: ~Copyable {
    struct Slot {
        var object: UInt64 = 0
        var rights = Rights(rawValue: 0)
        var generation: UInt32 = 0
    }

    let lock = SpinLock()
    var slots = UniqueArray<Slot>()
    var count = 0
}

@safe struct HandleTablePointer {
    let address: UInt64

    var pointee: HandleTableRecord {
        unsafeAddress { unsafe UnsafePointer<HandleTableRecord>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<HandleTableRecord>(bitPattern: UInt(address))! }
    }
}

struct HandleTable: ~Copyable {
    private let table: HandleTablePointer

    static var maxHandles: Int { 1 << 20 }

    init() {
        guard let raw = unsafe heap.allocate(size: MemoryLayout<HandleTableRecord>.size,
                                             alignment: max(16, MemoryLayout<HandleTableRecord>.alignment)) else {
            panic("handles: out of memory")
        }
        unsafe raw.bindMemory(to: HandleTableRecord.self, capacity: 1).initialize(to: HandleTableRecord())
        table = HandleTablePointer(address: UInt64(UInt(bitPattern: raw)))
    }

    /// A non-owning view of a table that someone else owns and keeps alive
    /// (threads of one process share its table; K7). `forget()` it.
    static func borrowing(address: UInt64) -> HandleTable {
        HandleTable(view: HandleTablePointer(address: address))
    }

    private init(view: HandleTablePointer) {
        table = view
    }

    /// Ends a borrowed view without closing anything.
    @export(interface)
    consuming func forget() {
        discard self
    }

    /// Runs `body` with a borrowed view of the table at `address`.
    static func withBorrowed<R>(_ address: UInt64, _ body: (borrowing HandleTable) throws(Status) -> R) throws(Status) -> R {
        let table = borrowing(address: address)
        let result: R
        do throws(Status) {
            result = try body(table)
        } catch {
            table.forget()
            throw error
        }
        table.forget()
        return result
    }

    /// Identifies the table to observers (for cancellation on close).
    var address: UInt64 { table.address }

    var count: Int { table.pointee.lock.withLock { table.pointee.count } }

    /// Adds a handle owning one reference to `object` (the caller's).
    func add(_ object: ObjectPointer, rights: Rights) throws(Status) -> UInt32 {
        try table.pointee.lock.withLock { () throws(Status) -> UInt32 in
            var index = -1
            for i in 0..<table.pointee.slots.count where table.pointee.slots[i].object == 0 {
                index = i
                break
            }
            if index < 0 {
                guard table.pointee.slots.count < Self.maxHandles else { throw .noResources }
                table.pointee.slots.append(HandleTableRecord.Slot())
                index = table.pointee.slots.count - 1
            }
            table.pointee.slots[index].object = object.address
            table.pointee.slots[index].rights = rights
            table.pointee.count += 1
            return Self.value(index, table.pointee.slots[index].generation)
        }
    }

    /// A reference to the object behind `handle`, if it has `rights` (and,
    /// with `type`, is of that type). Zircon's order of errors: bad handle,
    /// wrong type, access denied.
    func get(_ handle: UInt32, type: ObjectType? = nil, rights: Rights = []) throws(Status) -> ObjectRef {
        let object = try table.pointee.lock.withLock { () throws(Status) -> ObjectPointer in
            let index = try slot(handle)
            let entry = table.pointee.slots[index]
            let object = ObjectPointer(address: entry.object)
            if let type, object.header.type != type { throw .wrongType }
            guard entry.rights.isSuperset(of: rights) else { throw .accessDenied }
            object.retain()
            return object
        }
        return ObjectRef(object: object)
    }

    func rights(of handle: UInt32) throws(Status) -> Rights {
        try table.pointee.lock.withLock { () throws(Status) -> Rights in
            table.pointee.slots[try slot(handle)].rights
        }
    }

    /// Closes `handle`; waits through it are canceled.
    func close(_ handle: UInt32) throws(Status) {
        let object = try table.pointee.lock.withLock { () throws(Status) -> ObjectPointer in
            let index = try slot(handle)
            let object = ObjectPointer(address: table.pointee.slots[index].object)
            table.pointee.slots[index].object = 0
            table.pointee.slots[index].generation = (table.pointee.slots[index].generation + 1) & 0xFF
            table.pointee.count -= 1
            return object
        }
        Observers.handleClosed(object, table: table.address, handle: handle)
        object.release()
    }

    /// A second handle to the same object with `rights` (a subset of the
    /// original's, or sameRights). Needs the duplicate right.
    func duplicate(_ handle: UInt32, rights: Rights) throws(Status) -> UInt32 {
        let ref = try get(handle, rights: .duplicate)
        let have = try self.rights(of: handle)
        let wanted = rights.contains(.sameRights) ? have : rights
        guard have.isSuperset(of: wanted) else { throw .invalidArgs }
        ref.object.retain()
        do throws(Status) {
            return try add(ref.object, rights: wanted)
        } catch {
            ref.object.release()
            throw error
        }
    }

    /// Replaces `handle` with a new one with `rights` (a subset); the old
    /// handle is gone even if this fails.
    func replace(_ handle: UInt32, rights: Rights) throws(Status) -> UInt32 {
        let have = try self.rights(of: handle)
        let wanted = rights.contains(.sameRights) ? have : rights
        let ref = try get(handle)
        try close(handle)
        guard have.isSuperset(of: wanted) else { throw .invalidArgs }
        ref.object.retain()
        do throws(Status) {
            return try add(ref.object, rights: wanted)
        } catch {
            ref.object.release()
            throw error
        }
    }

    private func slot(_ handle: UInt32) throws(Status) -> Int {
        guard handle & 3 == 3 else { throw .badHandle }
        let index = Int(handle >> 10) - 1
        guard index >= 0, index < table.pointee.slots.count,
              table.pointee.slots[index].object != 0,
              table.pointee.slots[index].generation == (handle >> 2) & 0xFF else { throw .badHandle }
        return index
    }

    private static func value(_ index: Int, _ generation: UInt32) -> UInt32 {
        UInt32(index + 1) << 10 | (generation & 0xFF) << 2 | 3
    }

    deinit {
        var handles = UniqueArray<UInt32>()
        table.pointee.lock.withLock {
            for i in 0..<table.pointee.slots.count where table.pointee.slots[i].object != 0 {
                handles.append(Self.value(i, table.pointee.slots[i].generation))
            }
        }
        for i in 0..<handles.count { try? close(handles[i]) }
        let raw = unsafe UnsafeMutablePointer<HandleTableRecord>(bitPattern: UInt(table.address))!
        unsafe raw.deinitialize(count: 1)
        unsafe heap.free(UnsafeMutableRawPointer(raw))
    }
}
