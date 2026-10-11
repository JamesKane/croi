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
    /// (Zircon's RoundSize: OUT_OF_RANGE if that overflows).
    static func create(size: UInt64) throws(Status) -> ObjectPointer {
        let pageMask = KernelLayout.pageSize - 1
        guard size <= UInt64.max - pageMask else { throw .outOfRange }
        let vmo: Vmo
        do throws(VmError) {
            vmo = try Vmo(anonymous: (size + pageMask) & ~pageMask)
        } catch {
            throw error == .invalidArgument ? .invalidArgs : .noMemory
        }
        return try wrap(vmo.record)
    }

    /// The syscall.
    static func createChildCall(_ a: InlineArray<6, UInt64>, _ table: borrowing HandleTable) throws(Status) {
        try Syscalls.check(a[4], MemoryLayout<UInt32>.size)
        let (child, rights) = try createChild(table, UInt32(truncatingIfNeeded: a[0]),
                                              options: UInt32(truncatingIfNeeded: a[1]), offset: a[2], size: a[3])
        try Syscalls.put(try table.add(child, rights: rights), a[4])
    }

    /// vmo_create_child (K11a). SNAPSHOT_AT_LEAST_ON_WRITE of an anonymous
    /// VMO (a child too), optionally NO_WRITE; Zircon's rights: the
    /// parent handle's (DUPLICATE and READ required) plus GET/SET_PROPERTY,
    /// then a snapshot gains WRITE and loses EXECUTE unless NO_WRITE takes
    /// WRITE away instead (how a loader keeps code executable). SLICE
    /// (K13a, physical and contiguous parents; NO_WRITE the only other
    /// option): the parent handle's rights plus GET/SET_PROPERTY, less
    /// WRITE with NO_WRITE. Not yet (NOT_SUPPORTED): SNAPSHOT (isolated from
    /// the parent's later writes), REFERENCE, SNAPSHOT_MODIFIED, RESIZABLE,
    /// slices of anonymous VMOs.
    static func createChild(_ table: borrowing HandleTable, _ handle: UInt32, options: UInt32, offset: UInt64,
                            size: UInt64) throws(Status) -> (ObjectPointer, Rights) {
        let snapshotAtLeastOnWrite = UInt32(CROI_VMO_CHILD_SNAPSHOT_AT_LEAST_ON_WRITE)
        let noWrite = UInt32(CROI_VMO_CHILD_NO_WRITE)
        let known = UInt32(CROI_VMO_CHILD_SNAPSHOT) | UInt32(CROI_VMO_CHILD_RESIZABLE) | UInt32(CROI_VMO_CHILD_SLICE)
            | snapshotAtLeastOnWrite | noWrite | UInt32(CROI_VMO_CHILD_REFERENCE) | UInt32(CROI_VMO_CHILD_SNAPSHOT_MODIFIED)
        guard options & ~known == 0 else { throw .invalidArgs }
        if options & noWrite != 0, options & UInt32(CROI_VMO_CHILD_RESIZABLE) != 0 { throw .invalidArgs }
        let kind = options & ~noWrite
        guard kind != 0 else { throw .invalidArgs }
        let slice = UInt32(CROI_VMO_CHILD_SLICE)
        if kind & slice != 0, kind != slice { throw .invalidArgs }  // nothing else goes with SLICE
        guard kind == snapshotAtLeastOnWrite || kind == slice else { throw .notSupported }
        let pageMask = KernelLayout.pageSize - 1
        guard size <= UInt64.max - pageMask else { throw .outOfRange }
        let ref = try table.get(handle, type: .vmo, rights: .duplicate | .read)
        var rights = try table.rights(of: handle)
        let parent = VmoPointer(address: UnsafeVmoObject(ref.object).vmo)
        let child: Vmo
        do throws(VmError) {
            child = kind == slice
                ? try Vmo(sliceOf: parent, offset: offset, size: (size + pageMask) & ~pageMask)
                : try Vmo(childOf: parent, offset: offset, size: (size + pageMask) & ~pageMask)
        } catch {
            throw error == .outOfMemory ? .noMemory : error.status
        }
        rights.insert(.getProperty)
        rights.insert(.setProperty)
        if kind == slice {
            if options & noWrite != 0 { rights.remove(.write) }
        } else if options & noWrite != 0 {
            rights.remove(.write)
        } else {
            rights.remove(.execute)
            rights.insert(.write)
        }
        return (try wrap(child.record), rights)
    }

    /// The VMO behind `handle`, checked for mapping with `rights`: the map
    /// right, plus read, write and execute rights for each access asked
    /// for (Zircon's rule). A reference the caller releases.
    static func forMapping(_ table: borrowing HandleTable, _ handle: UInt32, _ rights: VmRights) throws(Status) -> VmoPointer {
        var needed: Rights = .map
        if rights.contains(.read) { needed.insert(.read) }
        if rights.contains(.write) { needed.insert(.write) }
        if rights.contains(.execute) { needed.insert(.execute) }
        let ref = try table.get(handle, type: .vmo, rights: needed)
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
