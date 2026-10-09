import CKernel
import PageTables

/// A VMO behind a handle (Zircon's VmObjectDispatcher): holds a reference
/// to the VMO.
struct VmoObject: ~Copyable {
    var header = ObjectHeader(type: .vmo)
    let vmo: UInt64

    /// ZX_DEFAULT_VMO_RIGHTS.
    static var defaultRights: Rights {
        [.basic, .read, .write, .map, .getProperty, .setProperty, .signal]
    }

    /// A handle-able object for `vmo` (takes a reference of its own).
    static func wrap(_ vmo: VmoPointer) throws(Status) -> ObjectPointer {
        vmo.retain()
        guard let object = Objects.allocate(VmoObject(vmo: vmo.address)) else {
            vmo.release()
            throw .noMemory
        }
        return object
    }

    /// vmo_create: anonymous memory.
    static func create(size: UInt64) throws(Status) -> ObjectPointer {
        let vmo: Vmo
        do throws(VmError) {
            vmo = try Vmo(anonymous: size)
        } catch {
            throw error == .invalidArgument ? .invalidArgs : .noMemory
        }
        return try wrap(vmo.record)
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

/// A resource (Zircon's ResourceDispatcher): the authority for privileged
/// operations. croi has the root resource and system resources minted from
/// it; the tracing one gates `trace_configure` (Todhchai's trace right,
/// Zircon's ZX_RSRC_SYSTEM_TRACING). MMIO, IRQ and the rest come with
/// drivers (after M2).
struct ResourceObject: ~Copyable {
    enum Kind: Equatable {
        case root
        case system(base: UInt64)
    }

    var header = ObjectHeader(type: .resource)
    let kind: Kind

    static var tracingBase: UInt64 { 6 }  // ZX_RSRC_SYSTEM_TRACING_BASE
    static var defaultRights: Rights { [.basic] }
}

enum Resources {
    /// The root resource, made at boot (userboot gets a handle in K8).
    nonisolated(unsafe) private(set) static var root = ObjectPointer(address: 0)

    static func initialize() {
        guard let object = Objects.allocate(ResourceObject(kind: .root)) else { panic("resource: out of memory") }
        root = object
    }

    static func kind(_ object: ObjectPointer) -> ResourceObject.Kind {
        unsafe UnsafePointer<ResourceObject>(bitPattern: UInt(object.address))!.pointee.kind
    }

    /// resource_create: only the root resource mints others.
    static func create(_ table: borrowing HandleTable, parent: UInt32, kind: ResourceObject.Kind) throws(Status) -> UInt32 {
        let parentRef = try table.get(parent, type: .resource)
        guard Resources.kind(parentRef.object) == .root else { throw .accessDenied }
        guard let object = Objects.allocate(ResourceObject(kind: kind)) else { throw .noMemory }
        return try table.add(object, rights: ResourceObject.defaultRights)
    }

    /// Whether `handle` is the root resource or the system resource `base`.
    static func check(_ table: borrowing HandleTable, _ handle: UInt32, system base: UInt64) throws(Status) {
        let ref = try table.get(handle, type: .resource)
        switch kind(ref.object) {
        case .root: return
        case .system(let b) where b == base: return
        default: throw .accessDenied
        }
    }
}

/// trace_configure (NeoVectra ADR-0049's call, gated as Zircon gates
/// ktrace): start, stop, rewind, mark, and the rings as read-only VMOs.
enum TraceControl {
    static func start(_ table: borrowing HandleTable, _ resource: UInt32, categories: UInt32, pages: Int,
                      mode: UInt32) throws(Status) {
        try Resources.check(table, resource, system: ResourceObject.tracingBase)
        guard pages > 0, pages <= 4096, mode == UInt32(CROI_TRACE_ONESHOT) || mode == UInt32(CROI_TRACE_CIRCULAR) else {
            throw .invalidArgs
        }
        do throws(VmError) {
            try Trace.start(categories: categories, pages: pages, mode: mode)
        } catch {
            throw .noMemory
        }
    }

    static func stop(_ table: borrowing HandleTable, _ resource: UInt32) throws(Status) {
        try Resources.check(table, resource, system: ResourceObject.tracingBase)
        Trace.stop()
    }

    /// Stops, and empties the rings.
    static func rewind(_ table: borrowing HandleTable, _ resource: UInt32) throws(Status) {
        try Resources.check(table, resource, system: ResourceObject.tracingBase)
        Trace.rewind()
    }

    /// A mark: 16 bytes of the caller's (kind CROI_TK_MARK). User space's
    /// own trace rings (Todhchai) use kinds 0x4000-0x7fff instead.
    static func mark(_ table: borrowing HandleTable, _ resource: UInt32, _ a: UInt64, _ b: UInt64) throws(Status) {
        try Resources.check(table, resource, system: ResourceObject.tracingBase)
        Trace.event(CROI_TRACE_MARK, UInt16(CROI_TK_MARK), a, b)
    }

    /// One handle per CPU's ring: read and map, never write.
    static func rings(_ table: borrowing HandleTable, _ resource: UInt32) throws(Status) -> UniqueArray<UInt32> {
        try Resources.check(table, resource, system: ResourceObject.tracingBase)
        var handles = UniqueArray<UInt32>()
        for cpu in 0..<Smp.count {
            guard let vmo = Trace.ringVmo(cpu) else { throw .badState }
            handles.append(try table.add(try VmoObject.wrap(vmo), rights: [.basic, .read, .map, .getProperty]))
        }
        return handles
    }
}
