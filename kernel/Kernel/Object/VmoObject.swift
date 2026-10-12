import Synchronization
import CKernel
import PageTables

/// A VMO behind a handle (Zircon's VmObjectDispatcher): holds a reference
/// to the VMO.
struct VmoObject: ~Copyable {
    var header = ObjectHeader(type: .vmo)
    let vmo: UInt64

    /// ZX_DEFAULT_VMO_RIGHTS.
    static var defaultRights: Rights {
        (.basic | .read | .write | .map | .getProperty | .setProperty | .signal)
    }

    /// vmo_create_physical's: Zircon's are the default VMO rights
    /// (VmObjectDispatcher::Create; WAIT included, so a driver can wait for
    /// ZERO_CHILDREN, K13a; no EXECUTE). K9a's list lacked WAIT, INSPECT and
    /// SIGNAL and had EXECUTE.
    static var physicalRights: Rights { defaultRights }

    /// A handle-able object for `vmo` (takes a reference of its own). The
    /// VMO's ZERO_CHILDREN is the object's (K13a).
    static func wrap(_ vmo: VmoPointer) throws(Status) -> ObjectPointer {
        vmo.retain()
        guard let object = Objects.allocate(VmoObject(vmo: vmo.address)) else {
            vmo.release()
            throw .noMemory
        }
        let none = vmo.pointee.lock.withLock { () -> Bool in
            if vmo.pointee.object == 0 { vmo.pointee.object = object.address }
            if vmo.pointee.koid == 0 { vmo.pointee.koid = object.header.koid }
            return vmo.pointee.children == 0
        }
        if none { object.header.signals = UInt32(CROI_VMO_ZERO_CHILDREN) }
        return object
    }

    /// vmo_create: anonymous memory, the size rounded up to a page
    /// (Zircon's RoundSize: OUT_OF_RANGE if that overflows, or passes
    /// `Vmos.maxSize`); an unaligned size is the content size. RESIZABLE
    /// (K13h): vmo_set_size may change it, and its handle gets RESIZE.
    /// DISCARDABLE (K14a, with or without RESIZABLE): reclaimable while
    /// unlocked (Reclaim). UNBOUNDED (K14i; with RESIZABLE INVALID_ARGS,
    /// first): the VMO is `Vmos.maxSize` and `size` is its content size.
    /// Zircon's order (parse_create_syscall_flags): RESIZABLE with
    /// UNBOUNDED, the size, then unknown options.
    /// K15a: `account` (not consumed) is charged as its pages commit.
    static func create(size: UInt64, options: UInt64 = 0, account: MemoryAccountPointer? = nil) throws(Status)
        -> (ObjectPointer, Rights) {
        let resizable = UInt64(CROI_VMO_CREATE_RESIZABLE), unbounded = UInt64(CROI_VMO_CREATE_UNBOUNDED)
        let discardable: UInt64 = 1 << 2
        let vmoSize = try Vmos.createSize(size, unbounded: options & unbounded != 0, resizable: options & resizable != 0)
        guard options & ~(resizable | unbounded | discardable) == 0 else { throw .invalidArgs }
        let vmo: Vmo
        do throws(VmError) {
            vmo = try Vmo(anonymous: vmoSize, account: account)
        } catch {
            throw error == .invalidArgument ? .invalidArgs : .noMemory
        }
        vmo.record.pointee.resizable = options & resizable != 0
        if size != vmoSize { vmo.record.pointee.streamSize = size }
        if options & discardable != 0 {
            vmo.record.pointee.discardable = true
            Reclaim.register(vmo.record)
        }
        return (try wrap(vmo.record), options & resizable != 0 ? defaultRights | .resize : defaultRights)
    }

    /// vmo_set_size (K13h), Zircon's order: WRITE; RESIZE if resizable;
    /// UNAVAILABLE for physical and contiguous VMOs; OUT_OF_RANGE if the
    /// rounding overflows; UNAVAILABLE if not resizable; BAD_STATE for
    /// pinned pages cut off. The content size becomes `size` exactly and
    /// the last page's tail past it reads zero.
    static func setSize(_ table: borrowing HandleTable, _ handle: UInt32, _ size: UInt64) throws(Status) {
        var have = Rights()
        let ref = try table.get(handle, type: .vmo, rights: .write, have: &have)
        let holder = VmoPointer(address: UnsafeVmoObject(ref.object).vmo)
        if holder.pointee.resizable, !have.contains(.resize) { throw .accessDenied }
        let vmo = holder.sizeOwner  // K14g: a reference resizes its root (Zircon's pass-through)
        guard case .anonymous = vmo.pointee.kind else { throw .unavailable }
        let pageMask = KernelLayout.pageSize - 1
        // Zircon's MAX_SIZE (review fix: only the rounding was checked).
        guard size <= Vmos.maxSize else { throw .outOfRange }
        guard vmo.pointee.resizable else { throw .unavailable }
        let rounded = (size + pageMask) & ~pageMask
        // Under the VMO's size lock, so a stream write or set_stream_size
        // never sees the end move under it (Zircon's StreamSizeManager).
        try Streams.withSizeLock(vmo) { () throws(Status) in
            do throws(VmError) {
                try Vmo.withBorrowed(vmo) { (v: borrowing Vmo) throws(VmError) in try v.resize(rounded) }
            } catch {
                throw error == .pinned ? .badState : error.status
            }
            vmo.pointee.lock.withLock { vmo.pointee.streamSize = size }
            if size < rounded {
                try? Pagers.ensureWritableRange(vmo, rounded - KernelLayout.pageSize, KernelLayout.pageSize)
                try? Vmo.withBorrowed(vmo) { (v: borrowing Vmo) throws(VmError) in try v.zero(offset: size, size: rounded - size) }
            }
        }
    }

    /// The syscall.
    static func createChildCall(_ a: InlineArray<6, UInt64>, _ table: borrowing HandleTable) throws(Status) {
        try Syscalls.check(a[4], MemoryLayout<UInt32>.size)
        // K15a: CROI_VMO_CHARGE_TO's account in the sixth argument.
        let chargeTo = UInt32(truncatingIfNeeded: a[1]) & UInt32(CROI_VMO_CHARGE_TO) != 0
        let explicit = chargeTo ? try Accounts.account(table, UInt32(truncatingIfNeeded: a[5]), rights: .charge) : nil
        defer { explicit?.release() }
        let (child, rights) = try createChild(table, UInt32(truncatingIfNeeded: a[0]),
                                              options: UInt32(truncatingIfNeeded: a[1]) & ~UInt32(CROI_VMO_CHARGE_TO),
                                              offset: a[2], size: a[3], chargeTo: explicit)
        try Syscalls.put(try table.add(child, rights: rights), a[4])
    }

    /// vmo_create_child, in Zircon's order (sys_vmo_create_child,
    /// create_child_internal). The size rounds up to a page (OUT_OF_RANGE
    /// on overflow); NO_WRITE with RESIZABLE INVALID_ARGS; the handle needs
    /// DUPLICATE and READ, and RESIZE too for a resizable REFERENCE;
    /// discardable VMOs NOT_SUPPORTED. Then by kind: SLICE (alone, else
    /// INVALID_ARGS; K13a physical and contiguous, K14g anonymous), REFERENCE
    /// (with RESIZABLE only; offset and size 0, K14g), or one snapshot kind
    /// (SNAPSHOT, then AT_LEAST_ON_WRITE, then MODIFIED; RESIZABLE allowed;
    /// none, or anything left over, INVALID_ARGS; K11a, K14g: `Vmo.snapshot`).
    /// Rights: the parent handle's less RESIZE, plus RESIZE for RESIZABLE,
    /// plus GET/SET_PROPERTY; NO_WRITE removes WRITE, else a snapshot gains
    /// WRITE and loses EXECUTE (how a loader keeps code executable).
    /// K15a: snapshots charge `chargeTo` or else the caller's process's
    /// account; a physical SLICE charges `chargeTo` in full (device-local);
    /// a REFERENCE, owning no pages, takes none.
    static func createChild(_ table: borrowing HandleTable, _ handle: UInt32, options: UInt32, offset: UInt64,
                            size: UInt64, chargeTo: MemoryAccountPointer? = nil) throws(Status) -> (ObjectPointer, Rights) {
        let noWrite = UInt32(CROI_VMO_CHILD_NO_WRITE), resizableChild = UInt32(CROI_VMO_CHILD_RESIZABLE)
        let slice = UInt32(CROI_VMO_CHILD_SLICE), reference = UInt32(CROI_VMO_CHILD_REFERENCE)
        let full = UInt32(CROI_VMO_CHILD_SNAPSHOT), onWrite = UInt32(CROI_VMO_CHILD_SNAPSHOT_AT_LEAST_ON_WRITE)
        let modified = UInt32(CROI_VMO_CHILD_SNAPSHOT_MODIFIED)
        let pageMask = KernelLayout.pageSize - 1
        guard size <= UInt64.max - pageMask else { throw .outOfRange }
        let rounded = (size + pageMask) & ~pageMask
        if options & noWrite != 0, options & resizableChild != 0 { throw .invalidArgs }
        var kind = options & ~noWrite
        let passThrough = kind & resizableChild != 0 && kind & reference != 0
        var rights = Rights()
        let ref = try table.get(handle, type: .vmo, rights: passThrough ? .duplicate | .read | .resize : .duplicate | .read,
                                have: &rights)
        let parent = VmoPointer(address: UnsafeVmoObject(ref.object).vmo)
        guard !parent.pointee.discardable else { throw .notSupported }  // K14a, Zircon's
        var snapshot = false
        let child: Vmo
        do throws(VmError) {
            if kind & slice != 0 {
                guard kind == slice else { throw .invalidArgument }
                child = try Vmo(sliceOf: parent, offset: offset, size: rounded, account: chargeTo)
            } else if kind & reference != 0 {
                kind &= ~reference
                let resizable = kind & resizableChild != 0
                kind &= ~resizableChild
                guard kind == 0, chargeTo == nil else { throw .invalidArgument }
                if case .physical = parent.pointee.kind { throw .notSupported }  // Zircon's VmObject default
                guard offset == 0, size == 0 else { throw .invalidArgument }
                child = try Vmo(referenceOf: parent, resizable: resizable)
            } else {
                let type: Vmo.Snapshot
                if kind & full != 0 {
                    kind &= ~full
                    type = .full
                } else if kind & onWrite != 0 {
                    kind &= ~onWrite
                    type = .atLeastOnWrite
                } else if kind & modified != 0 {
                    kind &= ~modified
                    type = .modified
                } else {
                    throw .invalidArgument
                }
                kind &= ~resizableChild
                guard kind == 0 else { throw .invalidArgument }
                snapshot = true
                child = try Vmo.snapshot(of: parent, type, offset: offset, size: rounded,
                                         account: chargeTo ?? Accounts.current())
                if options & resizableChild != 0 { child.record.pointee.resizable = true }
            }
        } catch {
            throw error == .outOfMemory ? .noMemory : error.status
        }
        // A slice's or snapshot's content size is its own; a reference's is
        // its root's.
        if options & reference == 0, size & pageMask != 0 { child.record.pointee.streamSize = size }
        rights.remove(.resize)
        if options & resizableChild != 0 { rights.insert(.resize) }
        rights.insert(.getProperty)
        rights.insert(.setProperty)
        if options & noWrite != 0 {
            rights.remove(.write)
        } else if snapshot {
            rights.remove(.execute)
            rights.insert(.write)
        }
        return (try wrap(child.record), rights)
    }

    /// The VMO behind `handle`, checked for mapping with `rights`: the map
    /// right, plus read, write and execute rights for each access asked
    /// for (Zircon's rule). A reference the caller releases.
    static func forMapping(_ table: borrowing HandleTable, _ handle: UInt32, _ rights: VmRights) throws(Status) -> VmoPointer {
        var have = Rights()
        return try forMapping(table, handle, rights, have: &have)
    }

    /// `forMapping`, with the handle's rights from the same lookup.
    static func forMapping(_ table: borrowing HandleTable, _ handle: UInt32, _ rights: VmRights,
                           have: inout Rights) throws(Status) -> VmoPointer {
        var needed: Rights = .map
        if rights.contains(.read) { needed.insert(.read) }
        if rights.contains(.write) { needed.insert(.write) }
        if rights.contains(.execute) { needed.insert(.execute) }
        let ref = try table.get(handle, type: .vmo, rights: needed, have: &have)
        let vmo = VmoPointer(address: UnsafeVmoObject(ref.object).vmo)
        vmo.retain()
        return vmo
    }
}

extension VmoObject {
    /// `forMapping`, checked and released at once (rights test only).
    static func forMappingReleasing(_ table: borrowing HandleTable, _ handle: UInt32, _ rights: VmRights) {
        do throws(Status) {
            try forMapping(table, handle, rights).release()
        } catch {
            panic("vmo object: mapping rights refused")
        }
    }
}

/// Reads a VmoObject's fields through its object pointer.
@safe struct UnsafeVmoObject {
    let object: ObjectPointer

    init(_ object: ObjectPointer) { self.object = object }

    var vmo: UInt64 { unsafe UnsafePointer<VmoObject>(bitPattern: UInt(object.address))!.pointee.vmo }
}

/// trace_configure (NeoVectra ADR-0049's call, gated as Zircon gates
/// ktrace): start, stop, rewind, mark, and the rings as read-only VMOs.
enum TraceControl {
    static func start(_ table: borrowing HandleTable, _ resource: UInt32, categories: UInt32, pages: Int,
                      mode: UInt32, sampleHz: UInt64) throws(Status) {
        try Resources.check(table, resource, system: UInt64(CROI_RSRC_SYSTEM_TRACING_BASE))
        guard pages > 0, pages <= 4096, mode == UInt32(CROI_TRACE_ONESHOT) || mode == UInt32(CROI_TRACE_CIRCULAR),
              sampleHz <= Sampler.maxHz else {
            throw .invalidArgs
        }
        do throws(VmError) {
            try Trace.start(categories: categories, pages: pages, mode: mode,
                            sampleHz: sampleHz == 0 ? UInt64(CROI_SAMPLE_DEFAULT_HZ) : sampleHz)
        } catch {
            throw .noMemory
        }
    }

    static func stop(_ table: borrowing HandleTable, _ resource: UInt32) throws(Status) {
        try Resources.check(table, resource, system: UInt64(CROI_RSRC_SYSTEM_TRACING_BASE))
        Trace.stop()
    }

    /// Stops, and empties the rings.
    static func rewind(_ table: borrowing HandleTable, _ resource: UInt32) throws(Status) {
        try Resources.check(table, resource, system: UInt64(CROI_RSRC_SYSTEM_TRACING_BASE))
        Trace.rewind()
    }

    /// A mark: 16 bytes of the caller's (kind CROI_TK_MARK). User space's
    /// own trace rings (Todhchai) use kinds 0x4000-0x7fff instead.
    static func mark(_ table: borrowing HandleTable, _ resource: UInt32, _ a: UInt64, _ b: UInt64) throws(Status) {
        try Resources.check(table, resource, system: UInt64(CROI_RSRC_SYSTEM_TRACING_BASE))
        Trace.event(CROI_TRACE_MARK, UInt16(CROI_TK_MARK), a, b)
    }

    /// One handle per CPU's ring: read and map, never write.
    static func rings(_ table: borrowing HandleTable, _ resource: UInt32) throws(Status) -> UniqueArray<UInt32> {
        try Resources.check(table, resource, system: UInt64(CROI_RSRC_SYSTEM_TRACING_BASE))
        var handles = UniqueArray<UInt32>()
        for cpu in 0..<Smp.count {
            guard let vmo = Trace.ringVmo(cpu) else { throw .badState }
            handles.append(try table.add(try VmoObject.wrap(vmo), rights: .basic | .read | .map | .getProperty))
        }
        return handles
    }
}
