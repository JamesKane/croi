import CKernel
import Synchronization

/// The start of every kernel object (Zircon's Dispatcher): its type, koid,
/// signal state and observers, and a reference count held by handles and by
/// kernel code using it. Each object type's record has this as its first
/// field, so an `ObjectPointer` reaches both.
///
/// Objects aren't built on `Ref<T>`: `Ref` lends its value only through a
/// read borrow, which suits immutable values; objects change under their
/// own lock, like VMOs and address spaces, which use the same pattern.
struct ObjectHeader: ~Copyable {
    let type: ObjectType
    let koid: UInt64
    let lock = SpinLock()
    var signals: UInt32 = 0
    /// Waits registered on it (intrusive list).
    var observers: ObserverPointer?
    let references = Atomic<Int>(1)

    init(type: ObjectType) {
        self.type = type
        self.koid = Objects.nextKoid()
    }
}

@safe struct ObjectPointer: Equatable {
    let address: UInt64

    var header: ObjectHeader {
        unsafeAddress { unsafe UnsafePointer<ObjectHeader>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<ObjectHeader>(bitPattern: UInt(address))! }
    }

    func retain() {
        guard header.references.add(1, ordering: .relaxed).newValue > 1 else { panic("object: retained after release") }
    }

    /// Drops a reference; the last destroys the object (by type).
    func release() {
        guard header.references.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 else { return }
        guard header.observers == nil else { panic("object: destroyed with waits registered") }
        Objects.destroy(self)
    }

    /// Clears then sets signal bits and runs the observers the new state
    /// satisfies. Lock order: object -> scheduler -> port packets.
    func updateSignals(clear: UInt32, set: UInt32) {
        header.lock.withLock {
            header.signals = (header.signals & ~clear) | set
            Observers.notify(self)
        }
    }

    var signals: UInt32 { header.lock.withLock { header.signals } }
}

/// A reference held by kernel code (from `HandleTable.get`): released when
/// dropped.
struct ObjectRef: ~Copyable {
    let object: ObjectPointer

    var type: ObjectType { object.header.type }
    var koid: UInt64 { object.header.koid }

    deinit {
        object.release()
    }
}

enum Objects {
    static let live = Atomic<Int>(0)
    /// Zircon starts koids above the reserved low values.
    private static let koids = Atomic<UInt64>(1023)

    static func nextKoid() -> UInt64 { koids.add(1, ordering: .relaxed).newValue }

    /// A new object record holding `value` (whose first field is the
    /// header), with one reference.
    static func allocate<T: ~Copyable>(_ value: consuming T) -> ObjectPointer? {
        guard let raw = unsafe heap.allocate(size: MemoryLayout<T>.size,
                                             alignment: max(16, MemoryLayout<T>.alignment)) else { return nil }
        unsafe raw.bindMemory(to: T.self, capacity: 1).initialize(to: value)
        live.add(1, ordering: .relaxed)
        return ObjectPointer(address: UInt64(UInt(bitPattern: raw)))
    }

    static func destroy(_ object: ObjectPointer) {
        switch object.header.type {
        case .event: free(object, as: EventObject.self)
        case .port: Ports.destroy(object)
        case .vmo:
            VmoPointer(address: UnsafeVmoObject(object).vmo).release()
            free(object, as: VmoObject.self)
        case .resource: free(object, as: ResourceObject.self)
        case .job: Processes.destroyJob(object)
        case .process: Processes.destroyProcess(object)
        case .thread: Processes.destroyThread(object)
        case .vmar: Processes.destroyVmar(object)
        case .none: panic("object: destroying an untyped object")
        }
        live.subtract(1, ordering: .relaxed)
    }

    static func free<T: ~Copyable>(_ object: ObjectPointer, as type: T.Type) {
        let raw = unsafe UnsafeMutablePointer<T>(bitPattern: UInt(object.address))!
        unsafe raw.deinitialize(count: 1)
        unsafe heap.free(UnsafeMutableRawPointer(raw))
    }
}

// MARK: Events

/// An event (Zircon's EventDispatcher): signals only, SIGNALED and the user
/// bits settable through `object_signal`.
struct EventObject: ~Copyable {
    var header = ObjectHeader(type: .event)

    static var defaultRights: Rights { [.basic, .signal] }

    static func create() throws(Status) -> ObjectPointer {
        guard let object = Objects.allocate(EventObject()) else { throw .noMemory }
        return object
    }
}

/// `object_signal`: which bits an object's holder may change.
enum ObjectSignal {
    static func signal(_ object: borrowing ObjectRef, clear: UInt32, set: UInt32) throws(Status) {
        let allowed: UInt32
        switch object.type {
        case .event: allowed = Signals.signaled | Signals.user
        default: allowed = Signals.user
        }
        guard (clear | set) & ~allowed == 0 else { throw .invalidArgs }
        object.object.updateSignals(clear: clear, set: set)
    }
}

