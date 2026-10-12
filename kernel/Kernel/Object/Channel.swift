import CKernel
import Synchronization

/// Channels and eventpairs (K7b; Zircon's ChannelDispatcher and
/// EventPairDispatcher).
///
/// A channel is two endpoint objects sharing one lock (`PeerShared`),
/// each with a FIFO of messages its holder reads. A message owns its bytes
/// and a reference to each object whose handle travelled in it. Closing an
/// endpoint (its last reference) unlinks it from its peer, raises
/// PEER_CLOSED there, ends calls waiting on replies from it, and frees its
/// unread messages (outside the lock: they may hold the other endpoint).
///
/// `channel_call` (ext 2, IPC deadline donation): the caller registers a
/// call record (txid assigned by the kernel, high bit set) and blocks on
/// its wait queue. The thread that reads the call becomes that queue's
/// owner, so the caller's profile is lent to it (a deadline caller's
/// deadline: K3b inheritance) until its reply, matched by txid, wakes the
/// caller. Lock order: channel pair -> object -> scheduler.

// MARK: Shared state

/// The lock and identity two peers share (heap; freed with the second).
struct PeerShared: ~Copyable {
    let lock = SpinLock()
    let references = Atomic<Int>(2)
    /// The channel's id: the smaller endpoint koid (both ends know it).
    var id: UInt64 = 0
}

@safe struct PeerSharedPointer {
    let address: UInt64

    var pointee: PeerShared {
        unsafeAddress { unsafe UnsafePointer<PeerShared>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<PeerShared>(bitPattern: UInt(address))! }
    }

    static func allocate() -> PeerSharedPointer? {
        guard let raw = unsafe heap.allocate(size: MemoryLayout<PeerShared>.size, alignment: 16) else { return nil }
        unsafe raw.bindMemory(to: PeerShared.self, capacity: 1).initialize(to: PeerShared())
        return PeerSharedPointer(address: UInt64(UInt(bitPattern: raw)))
    }

    func release() {
        guard pointee.references.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 else { return }
        let raw = unsafe UnsafeMutablePointer<PeerShared>(bitPattern: UInt(address))!
        unsafe raw.deinitialize(count: 1)
        unsafe heap.free(UnsafeMutableRawPointer(raw))
    }
}

// MARK: Messages

/// A message's header; its bytes follow (rounded to 16), then its handles
/// (object address, rights), in one heap allocation.
struct MessageHeader {
    var next: UInt64 = 0
    var bytes: UInt32
    var handles: UInt32
    var txid: UInt32
    /// The call it carries (a reference), or 0.
    var call: UInt64 = 0
    var flow: UInt64 = 0
}

@safe struct MessagePointer: Equatable {
    let address: UInt64

    var pointee: MessageHeader {
        unsafeAddress { unsafe UnsafePointer<MessageHeader>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<MessageHeader>(bitPattern: UInt(address))! }
    }

    private static var headerSize: Int { (MemoryLayout<MessageHeader>.size + 15) & ~15 }
    private static func bytesSize(_ count: UInt32) -> Int { (Int(count) + 15) & ~15 }

    /// A message with room for `bytes` and `handles` (handles zeroed).
    static func allocate(bytes: UInt32, handles: UInt32) -> MessagePointer? {
        let size = headerSize + bytesSize(bytes) + Int(handles) * 16
        guard let raw = unsafe heap.allocate(size: size, alignment: 16) else { return nil }
        unsafe raw.bindMemory(to: MessageHeader.self, capacity: 1)
            .initialize(to: MessageHeader(bytes: bytes, handles: handles, txid: 0))
        let message = MessagePointer(address: UInt64(UInt(bitPattern: raw)))
        for i in 0..<Int(handles) { message.setHandle(i, object: 0, rights: Rights(rawValue: 0)) }
        return message
    }

    /// Where its bytes are.
    var data: UInt64 { address + UInt64(Self.headerSize) }

    func handle(_ i: Int) -> (object: UInt64, rights: Rights) {
        let at = unsafe UnsafePointer<UInt64>(bitPattern: UInt(handleSlot(i)))!
        return unsafe (at[0], Rights(rawValue: UInt32(truncatingIfNeeded: at[1])))
    }

    /// Puts a handle in slot `i` (an object counts it as one in flight:
    /// ZX_INFO_HANDLE_COUNT), or clears it (0: the caller uncounts what it
    /// took out).
    func setHandle(_ i: Int, object: UInt64, rights: Rights) {
        if object != 0 { ObjectPointer(address: object).header.handleCount.add(1, ordering: .relaxed) }
        let at = unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(handleSlot(i)))!
        unsafe at[0] = object
        unsafe at[1] = UInt64(rights.rawValue)
    }

    private func handleSlot(_ i: Int) -> UInt64 {
        data + UInt64(Self.bytesSize(pointee.bytes)) + UInt64(i) * 16
    }

    /// Frees it, dropping the objects it still holds and its call.
    func free() {
        for i in 0..<Int(pointee.handles) {
            let object = handle(i).object
            if object != 0 {
                ObjectPointer(address: object).handleGone()
                ObjectPointer(address: object).release()
            }
        }
        if pointee.call != 0 { CallRecordPointer(address: pointee.call).release() }
        unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(address))!)
    }
}

// MARK: Calls

struct CallRecord: ~Copyable {
    enum State { case pending, replied, peerClosed, abandoned }

    /// The caller waits here (an owned queue while a server holds the
    /// call). First, so the record's address is the queue's: no separate
    /// allocation per call.
    var waiters = QueueHead()
    var txid: UInt32
    var state = State.pending
    var reply: UInt64 = 0
    var flow: UInt64
    /// The caller's trace id (DONATE records name it).
    let callerTraceId: UInt32
    let references = Atomic<Int>(1)
}

@safe struct CallRecordPointer {
    let address: UInt64

    var pointee: CallRecord {
        unsafeAddress { unsafe UnsafePointer<CallRecord>(bitPattern: UInt(address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<CallRecord>(bitPattern: UInt(address))! }
    }

    static func allocate(txid: UInt32, flow: UInt64) -> CallRecordPointer? {
        guard let raw = unsafe heap.allocate(size: MemoryLayout<CallRecord>.size, alignment: 16) else { return nil }
        let caller = Scheduler.current.pointee.traceId
        unsafe raw.bindMemory(to: CallRecord.self, capacity: 1)
            .initialize(to: CallRecord(txid: txid, flow: flow, callerTraceId: caller))
        return CallRecordPointer(address: UInt64(UInt(bitPattern: raw)))
    }

    /// The caller's wait queue, inside the record.
    var queue: QueuePointer { QueuePointer(address: address) }

    func retain() { pointee.references.add(1, ordering: .relaxed) }

    func release() {
        guard pointee.references.subtract(1, ordering: .acquiringAndReleasing).newValue == 0 else { return }
        if pointee.reply != 0 { MessagePointer(address: pointee.reply).free() }
        let raw = unsafe UnsafeMutablePointer<CallRecord>(bitPattern: UInt(address))!
        unsafe raw.deinitialize(count: 1)
        unsafe heap.free(UnsafeMutableRawPointer(raw))
    }
}

// MARK: Endpoints

struct ChannelObject: ~Copyable {
    var header = ObjectHeader(type: .channel)
    let shared: PeerSharedPointer
    /// The other endpoint (not retained), 0 once it closed.
    var peer: UInt64 = 0
    var peerKoid: UInt64 = 0
    var head: UInt64 = 0
    var tail: UInt64 = 0
    var queued = 0
    /// Calls made through this endpoint, waiting for replies.
    var calls = UniqueArray<UInt64>()
    var nextTxid: UInt32 = 0

    /// ZX_DEFAULT_CHANNEL_RIGHTS: no DUPLICATE (an endpoint has one reader).
    static var defaultRights: Rights { Rights.basic.subtracting(.duplicate).union(.read | .write | .signal | .signalPeer) }
}

@safe struct ChannelPointer {
    let object: ObjectPointer

    var pointee: ChannelObject {
        unsafeAddress { unsafe UnsafePointer<ChannelObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<ChannelObject>(bitPattern: UInt(object.address))! }
    }
}

struct EventPairObject: ~Copyable {
    var header = ObjectHeader(type: .eventpair)
    let shared: PeerSharedPointer
    var peer: UInt64 = 0
    var peerKoid: UInt64 = 0

    static var defaultRights: Rights { .basic | .signal | .signalPeer }
}

@safe struct EventPairPointer {
    let object: ObjectPointer

    var pointee: EventPairObject {
        unsafeAddress { unsafe UnsafePointer<EventPairObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<EventPairObject>(bitPattern: UInt(object.address))! }
    }
}

enum Channels {
    // MARK: Creation and closing

    static func create() throws(Status) -> (ObjectPointer, ObjectPointer) {
        guard let shared = PeerSharedPointer.allocate() else { throw .noMemory }
        guard let a = Objects.allocate(ChannelObject(shared: shared)) else {
            shared.release()
            shared.release()
            throw .noMemory
        }
        guard let b = Objects.allocate(ChannelObject(shared: shared)) else {
            a.release()
            shared.release()
            throw .noMemory
        }
        let ca = ChannelPointer(object: a), cb = ChannelPointer(object: b)
        ca.pointee.peer = b.address
        cb.pointee.peer = a.address
        ca.pointee.peerKoid = b.header.koid
        cb.pointee.peerKoid = a.header.koid
        shared.pointee.id = min(a.header.koid, b.header.koid)
        a.updateSignals(clear: 0, set: CROI_SIGNAL_WRITABLE)
        b.updateSignals(clear: 0, set: CROI_SIGNAL_WRITABLE)
        return (a, b)
    }

    /// The endpoint's record is going (Objects.destroy).
    static func destroy(_ object: ObjectPointer) {
        let me = ChannelPointer(object: object)
        let shared = me.pointee.shared
        var peer: ObjectPointer? = nil
        var orphaned = UniqueArray<UInt64>()  // callers on the peer waiting for our replies
        var unread: UInt64 = 0
        shared.pointee.lock.withLock {
            if me.pointee.peer != 0 {
                let other = ObjectPointer(address: me.pointee.peer)
                let them = ChannelPointer(object: other)
                them.pointee.peer = 0
                for i in 0..<them.pointee.calls.count {
                    let call = CallRecordPointer(address: them.pointee.calls[i])
                    if call.pointee.state == .pending {
                        call.pointee.state = .peerClosed
                        call.retain()
                        orphaned.append(call.address)
                    }
                }
                if other.tryRetain() { peer = other }
            }
            me.pointee.peer = 0
            unread = me.pointee.head
            me.pointee.head = 0
            me.pointee.tail = 0
        }
        if let peer {
            peer.updateSignals(clear: CROI_SIGNAL_WRITABLE, set: CROI_SIGNAL_PEER_CLOSED)
            peer.release()
        }
        for i in 0..<orphaned.count { finishCall(CallRecordPointer(address: orphaned[i])) }
        var cursor = unread
        while cursor != 0 {
            let message = MessagePointer(address: cursor)
            cursor = message.pointee.next
            message.free()
        }
        shared.release()
        Objects.free(object, as: ChannelObject.self)
    }

    /// Wakes a call's caller (its state already decided) and ends any
    /// donation to whoever received it. Drops the reference passed in.
    private static func finishCall(_ call: CallRecordPointer) {
        Scheduler.locked {
            Scheduler.setOwner(call.queue, nil)
            Scheduler.wakeAll(call.queue)
        }
        call.release()
    }

    // MARK: Writing and reading

    /// The channel's id and a message's flow (ipc.h).
    static func channelId(_ object: ObjectPointer) -> UInt64 { ChannelPointer(object: object).pointee.shared.pointee.id }

    /// Delivers `message` to the peer of `object`: as the reply to a call
    /// waiting there with its txid, or into the peer's queue. Consumes the
    /// message, even on failure (PEER_CLOSED).
    /// Zircon's limit on a channel's queue: a write past it raises a
    /// CHANNEL_FULL_WRITE policy exception on the writer (the message is
    /// still queued). Review fix: queues had no bound.
    static let maxPending = 3500

    /// Queues `message` on the peer, or hands it to a pending call whose
    /// txid it carries (`matchingCalls`; a call's own request never is a
    /// reply: review fix, both ends' first txids are the same). True when
    /// the peer's queue is now past `maxPending`.
    @discardableResult
    static func write(_ object: ObjectPointer, _ message: MessagePointer, matchingCalls: Bool = true) throws(Status)
        -> Bool {
        let me = ChannelPointer(object: object)
        let shared = me.pointee.shared
        message.pointee.flow = croi_flow_id(shared.pointee.id, message.pointee.txid)
        Trace.event(CROI_TRACE_IPC, UInt16(CROI_TK_CHANNEL_WRITE), message.pointee.flow,
                    UInt64(message.pointee.bytes) | UInt64(message.pointee.handles) << 32)
        var peer: ObjectPointer? = nil
        var replied: CallRecordPointer? = nil
        var becameReadable = false
        var full = false
        let delivered = shared.pointee.lock.withLock { () -> Bool in
            guard me.pointee.peer != 0 else { return false }
            let other = ObjectPointer(address: me.pointee.peer)
            let them = ChannelPointer(object: other)
            if matchingCalls, message.pointee.txid != 0 {
                for i in 0..<them.pointee.calls.count {
                    let call = CallRecordPointer(address: them.pointee.calls[i])
                    if call.pointee.txid == message.pointee.txid, call.pointee.state == .pending {
                        call.pointee.state = .replied
                        call.pointee.reply = message.address
                        call.retain()
                        replied = call
                        return true
                    }
                }
            }
            if them.pointee.tail != 0 {
                MessagePointer(address: them.pointee.tail).pointee.next = message.address
            } else {
                them.pointee.head = message.address
                becameReadable = true
            }
            them.pointee.tail = message.address
            them.pointee.queued += 1
            full = them.pointee.queued > maxPending
            if becameReadable, other.tryRetain() { peer = other }
            return true
        }
        guard delivered else {
            message.free()
            throw .peerClosed
        }
        if let replied { finishCall(replied) }
        if let peer {
            peer.updateSignals(clear: 0, set: CROI_SIGNAL_READABLE)
            peer.release()
        }
        return full
    }

    /// The next message's size, without taking it: nil if there is none
    /// (with why: SHOULD_WAIT or PEER_CLOSED).
    static func peek(_ object: ObjectPointer) throws(Status) -> (bytes: UInt32, handles: UInt32) {
        let me = ChannelPointer(object: object)
        return try me.pointee.shared.pointee.lock.withLock { () throws(Status) -> (UInt32, UInt32) in
            guard me.pointee.head != 0 else { throw me.pointee.peer == 0 ? .peerClosed : .shouldWait }
            let first = MessagePointer(address: me.pointee.head)
            return (first.pointee.bytes, first.pointee.handles)
        }
    }

    /// Takes the next message if it fits `limit` (the sizes the reader
    /// checked its buffers for), else nil: another reader took the one it
    /// peeked (review fix: it then copied a bigger message into the
    /// smaller buffers). A call becomes owned by the reading thread
    /// (donation) until its reply.
    static func read(_ object: ObjectPointer, ifFits limit: (bytes: UInt32, handles: UInt32)) throws(Status)
        -> MessagePointer? {
        try take(object) { bytes, handles in bytes <= limit.bytes && handles <= limit.handles }
    }

    /// The next message if it doesn't fit `capacity` (MAY_DISCARD), else nil.
    static func discard(_ object: ObjectPointer, ifLargerThan capacity: (bytes: UInt32, handles: UInt32)) -> MessagePointer? {
        (try? take(object) { bytes, handles in bytes > capacity.bytes || handles > capacity.handles }) ?? nil
    }

    private static func take(_ object: ObjectPointer, _ accept: (UInt32, UInt32) -> Bool) throws(Status)
        -> MessagePointer? {
        let me = ChannelPointer(object: object)
        let taken = try me.pointee.shared.pointee.lock.withLock { () throws(Status) -> MessagePointer? in
            guard me.pointee.head != 0 else { throw me.pointee.peer == 0 ? .peerClosed : .shouldWait }
            let first = MessagePointer(address: me.pointee.head)
            guard accept(first.pointee.bytes, first.pointee.handles) else { return nil }
            me.pointee.head = first.pointee.next
            if me.pointee.head == 0 { me.pointee.tail = 0 }
            me.pointee.queued -= 1
            first.pointee.next = 0
            return first
        }
        guard let message = taken else { return nil }
        if me.pointee.head == 0 { object.updateSignals(clear: CROI_SIGNAL_READABLE, set: 0) }
        Trace.event(CROI_TRACE_IPC, UInt16(CROI_TK_CHANNEL_READ), message.pointee.flow,
                    UInt64(message.pointee.bytes) | UInt64(message.pointee.handles) << 32)
        if message.pointee.call != 0 {
            let call = CallRecordPointer(address: message.pointee.call)
            Scheduler.locked {
                guard call.pointee.state == .pending else { return }
                // The caller may not have blocked yet: it lends once it does.
                if Scheduler.setOwner(call.queue, Scheduler.current) {
                    Trace.event(CROI_TRACE_IPC, UInt16(CROI_TK_DONATE), call.pointee.flow,
                                UInt64(call.pointee.callerTraceId))
                }
            }
        }
        // A reader only needed the record to donate; replies match by txid.
        if message.pointee.call != 0 {
            CallRecordPointer(address: message.pointee.call).release()
            message.pointee.call = 0
        }
        // The queue may have refilled between the unlock and the signal.
        let refilled = me.pointee.shared.pointee.lock.withLock { me.pointee.head != 0 }
        if refilled { object.updateSignals(clear: 0, set: CROI_SIGNAL_READABLE) }
        return message
    }

    /// channel_call: writes `message` as a call (its first four bytes get
    /// a kernel txid) and waits until `deadline` for the reply.
    static func call(_ object: ObjectPointer, _ message: MessagePointer, deadline: UInt64) throws(Status) -> MessagePointer {
        let me = ChannelPointer(object: object)
        let shared = me.pointee.shared
        guard message.pointee.bytes >= 4 else {
            message.free()
            throw .invalidArgs
        }
        guard let call = CallRecordPointer.allocate(txid: 0, flow: 0) else {
            message.free()
            throw .noMemory
        }
        // Its txid and its place among the pending calls in one locked step.
        let txid = shared.pointee.lock.withLock { () -> UInt32 in
            me.pointee.nextTxid = (me.pointee.nextTxid + 1) & 0x7FFF_FFFF
            let txid = me.pointee.nextTxid | 0x8000_0000
            call.pointee.txid = txid
            call.pointee.flow = croi_flow_id(shared.pointee.id, txid)
            me.pointee.calls.append(call.address)
            return txid
        }
        unsafe UnsafeMutablePointer<UInt32>(bitPattern: UInt(message.data))!.pointee = txid
        message.pointee.txid = txid
        call.retain()  // the message's
        message.pointee.call = call.address
        var failure: Status? = nil
        do throws(Status) {
            // A request never matches a pending call (Zircon writes it with
            // write_self_locked).
            if try write(object, message, matchingCalls: false) {
                Policy.limitException(UInt32(CROI_EXCP_POLICY_CODE_CHANNEL_FULL_WRITE))
            }
        } catch {
            failure = error
        }
        var interrupted = false
        var timedOut = false
        if failure == nil {
            Scheduler.locked {
                while call.pointee.state == .pending {
                    let result = Scheduler.block(on: call.queue, deadline: deadline, interruptible: true)
                    if result == .interrupted {
                        interrupted = true
                        return
                    }
                    if result == .timedOut, call.pointee.state == .pending {
                        timedOut = true
                        return
                    }
                }
            }
        }
        // Done waiting: unregister, end any donation, take the reply.
        let outcome = shared.pointee.lock.withLock { () -> CallRecord.State in
            for i in 0..<me.pointee.calls.count where me.pointee.calls[i] == call.address {
                _ = me.pointee.calls.remove(at: i)
                break
            }
            if call.pointee.state == .pending { call.pointee.state = .abandoned }
            return call.pointee.state
        }
        _ = Scheduler.locked { Scheduler.setOwner(call.queue, nil) }
        var reply: MessagePointer? = nil
        if outcome == .replied {
            reply = MessagePointer(address: call.pointee.reply)
            call.pointee.reply = 0
        }
        call.release()
        if let failure { throw failure }
        if let reply { return reply }
        if interrupted { throw .canceled }
        if timedOut { throw .timedOut }
        throw .peerClosed
    }

    // MARK: Eventpairs

    static func createEventPair() throws(Status) -> (ObjectPointer, ObjectPointer) {
        guard let shared = PeerSharedPointer.allocate() else { throw .noMemory }
        guard let a = Objects.allocate(EventPairObject(shared: shared)) else {
            shared.release()
            shared.release()
            throw .noMemory
        }
        guard let b = Objects.allocate(EventPairObject(shared: shared)) else {
            a.release()
            shared.release()
            throw .noMemory
        }
        EventPairPointer(object: a).pointee.peer = b.address
        EventPairPointer(object: b).pointee.peer = a.address
        EventPairPointer(object: a).pointee.peerKoid = b.header.koid
        EventPairPointer(object: b).pointee.peerKoid = a.header.koid
        shared.pointee.id = min(a.header.koid, b.header.koid)
        return (a, b)
    }

    static func destroyEventPair(_ object: ObjectPointer) {
        let me = EventPairPointer(object: object)
        let shared = me.pointee.shared
        var peer: ObjectPointer? = nil
        shared.pointee.lock.withLock {
            if me.pointee.peer != 0 {
                let other = ObjectPointer(address: me.pointee.peer)
                EventPairPointer(object: other).pointee.peer = 0
                if other.tryRetain() { peer = other }
            }
            me.pointee.peer = 0
        }
        if let peer {
            peer.updateSignals(clear: 0, set: CROI_SIGNAL_PEER_CLOSED)
            peer.release()
        }
        shared.release()
        Objects.free(object, as: EventPairObject.self)
    }

    /// object_signal_peer: user signals (and SIGNALED on eventpairs) on
    /// the other end.
    static func signalPeer(_ object: ObjectPointer, clear: UInt32, set: UInt32) throws(Status) {
        let allowed = Signals.user | (object.header.type == .eventpair ? Signals.signaled : 0)
        guard (clear | set) & ~allowed == 0 else { throw .invalidArgs }
        if object.header.type == .socket { return try Sockets.signalPeer(object, clear: clear, set: set) }
        let shared: PeerSharedPointer
        switch object.header.type {
        case .channel: shared = ChannelPointer(object: object).pointee.shared
        case .eventpair: shared = EventPairPointer(object: object).pointee.shared
        case .fifo: shared = FifoPointer(object: object).pointee.shared
        default: throw .wrongType
        }
        let peer = shared.pointee.lock.withLock { () -> ObjectPointer? in
            let address = object.header.type == .channel ? ChannelPointer(object: object).pointee.peer
                : object.header.type == .fifo ? FifoPointer(object: object).pointee.peer
                : EventPairPointer(object: object).pointee.peer
            guard address != 0 else { return nil }
            let other = ObjectPointer(address: address)
            return other.tryRetain() ? other : nil
        }
        guard let peer else { throw .peerClosed }
        peer.updateSignals(clear: clear, set: set)
        peer.release()
    }

    /// The koid of the object's peer (channels, eventpairs), else 0.
    static func relatedKoid(_ object: ObjectPointer) -> UInt64 {
        switch object.header.type {
        case .channel: ChannelPointer(object: object).pointee.peerKoid
        case .eventpair: EventPairPointer(object: object).pointee.peerKoid
        case .fifo: FifoPointer(object: object).pointee.peerKoid
        case .socket: Sockets.relatedKoid(object)
        default: 0
        }
    }
}
