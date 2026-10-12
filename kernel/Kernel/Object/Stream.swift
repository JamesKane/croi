import CKernel
import Synchronization

/// Streams (K13c; Zircon's StreamDispatcher, type 31): a seek position and
/// a mode (READ, WRITE, APPEND) over an anonymous VMO, read and written
/// with iovecs. Reads stop at the VMO's stream size; writes extend it (the
/// gap before them zero-filled first), up to the VMO's size: a write at or
/// past that is OUT_OF_RANGE, one reaching it is cut short. Appends write
/// at the stream size. The stream size lives on the VMO (`streamSize`,
/// the VMO's size until set), shared by every stream over it, with
/// vmo_get/set_stream_size and ZX_PROP_VMO_CONTENT_SIZE.
///
/// Copies may fault and page in, so a stream's seek is kept under a
/// blocking Mutex of its own, and every size-changing write under its
/// VMO's size lock (`withSizeLock`, Zircon's per-VMO StreamSizeManager;
/// vmo_set_size takes it too). It was one global Mutex: a write waiting for
/// one file's pager stalled every other stream's size change (review 2).
/// A faulting user buffer ends a transfer short; with nothing moved it is
/// NOT_FOUND (Zircon's).
///
/// Not yet: resizable VMOs (croi has none; writes never grow the VMO, as
/// in the pinned tree), streams over pager-backed VMOs.
struct StreamObject: ~Copyable {
    var header = ObjectHeader(type: .stream)
    let vmo: VmoPointer
    var mode: UInt32
    var seek: UInt64
    let seekLock = Mutex()

    /// ZX_DEFAULT_STREAM_RIGHTS (READ and WRITE added by mode).
    static var defaultRights: Rights { .basic | .getProperty | .setProperty | .signal }
}

@safe struct StreamPointer {
    let object: ObjectPointer

    var pointee: StreamObject {
        unsafeAddress { unsafe UnsafePointer<StreamObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<StreamObject>(bitPattern: UInt(object.address))! }
    }
}

enum Streams {
    /// Runs `body` holding `vmo`'s size lock (its size owner's: a reference
    /// shares its root's). The queue is made on first use (NO_MEMORY if it
    /// can't be) and lives as long as the VMO record; the caller's
    /// reference keeps that alive.
    static func withSizeLock<R>(_ vmo: VmoPointer, _ body: () throws(Status) -> R) throws(Status) -> R {
        let vmo = vmo.sizeOwner
        var queue = vmo.pointee.lock.withLock { vmo.pointee.sizeQueue }
        if queue == 0 {
            guard let made = QueuePointer.tryAllocate() else { throw .noMemory }
            queue = vmo.pointee.lock.withLock { () -> UInt64 in
                if vmo.pointee.sizeQueue == 0 { vmo.pointee.sizeQueue = made.address }
                return vmo.pointee.sizeQueue
            }
            if queue != made.address { made.deallocate() }  // another thread's won
        }
        let lock = QueuePointer(address: queue)
        Scheduler.lockMutex(lock)
        defer { Scheduler.unlockMutex(lock) }
        return try body()
    }

    static var modeRead: UInt32 { UInt32(CROI_STREAM_MODE_READ) }
    static var modeWrite: UInt32 { UInt32(CROI_STREAM_MODE_WRITE) }
    static var modeAppend: UInt32 { UInt32(CROI_STREAM_MODE_APPEND) }

    /// stream_create (the VMO's rights checked): a reference to the VMO.
    static func create(options: UInt32, vmo: VmoPointer, seek: UInt64) throws(Status) -> ObjectPointer {
        guard case .anonymous = vmo.pointee.kind else { throw .wrongType }
        vmo.retain()
        guard let object = Objects.allocate(StreamObject(vmo: vmo, mode: options, seek: seek)) else {
            vmo.release()
            throw .noMemory
        }
        return object
    }

    static func destroy(_ object: ObjectPointer) {
        StreamPointer(object: object).pointee.vmo.release()
        Objects.free(object, as: StreamObject.self)
    }

    // MARK: Stream size

    /// K14g: a reference shares its root's sizes (Zircon: its stream size
    /// manager); a slice of an anonymous VMO has its own, over its root's
    /// pages (`transfer` and `zero` go there).
    static func streamSize(_ vmo: VmoPointer) -> UInt64 {
        let vmo = vmo.sizeOwner
        return vmo.pointee.lock.withLock { vmo.pointee.streamSize ?? vmo.pointee.size }
    }

    /// vmo_set_stream_size: OUT_OF_RANGE past the VMO; the bytes from the
    /// smaller of the old and new sizes to the VMO's end read as zero.
    static func setStreamSize(_ vmo: VmoPointer, _ size: UInt64) throws(Status) {
        let vmo = vmo.sizeOwner
        guard case .anonymous = vmo.pointee.kind else { throw .notSupported }
        try withSizeLock(vmo) { () throws(Status) in try setStreamSizeLocked(vmo, size) }
    }

    /// Size lock held, so vmo_set_size can't move the VMO's end between the
    /// check and the zeroing (review 2: the check was outside every lock).
    private static func setStreamSizeLocked(_ vmo: VmoPointer, _ size: UInt64) throws(Status) {
        guard size <= vmo.pointee.lock.withLock({ vmo.pointee.size }) else { throw .outOfRange }
        let old = streamSize(vmo)
        let from = min(old, size)
        // Zircon's: zeroed up to the new size's page end (a pager VMO's
        // pages requested and dirtied), and past it only what is committed
        // ("untracked": the rest of an UNBOUNDED VMO, K14i, is no loop).
        let aligned = (size + KernelLayout.pageSize - 1) & ~(KernelLayout.pageSize - 1)
        if aligned > from { try zero(vmo, from, aligned - from) }
        let rest = max(aligned, from)
        let (pages, _) = vmo.target
        if rest < vmo.pointee.size {
            if pages.pointee.pager == nil, !pages.pointee.readsFromPager, pages.pointee.parent == nil, !pages.pointee.clone {
                try zero(vmo, rest, vmo.pointee.size - rest)  // absent reads zero: decommitted, sparsely
            } else if let source = pages.pointee.pager, !source.pointee.trapDirty, pages == vmo {
                Pagers.zeroPages(pages, rest, vmo.pointee.size, .untracked)  // K14k: Zircon's untracked zeros
            } else {
                try? Vmo.withBorrowed(vmo) { (v: borrowing Vmo) throws(VmError) in v.zeroOwn(rest, vmo.pointee.size) }
            }
        }
        vmo.pointee.lock.withLock { vmo.pointee.streamSize = size }
    }

    private static func zero(_ holder: VmoPointer, _ offset: UInt64, _ length: UInt64) throws(Status) {
        guard length > 0 else { return }
        let (vmo, shift) = holder.target
        let offset = offset + shift
        if vmo.pointee.pager != nil || vmo.pointee.readsFromPager {  // the pages written in place first
            try Pagers.ensureWritableForZero(vmo, offset, length)
        }
        do throws(VmError) {
            try Vmo.withBorrowed(vmo) { (v: borrowing Vmo) throws(VmError) in try v.zero(offset: offset, size: length) }
        } catch {
            throw error.status
        }
    }

    // MARK: Transfers

    /// The iovecs' total capacity (INVALID_ARGS on overflow).
    static func capacity(_ vector: UInt64, _ count: UInt64) throws(Status) -> UInt64 {
        var total: UInt64 = 0
        for i in 0..<count {
            let (_, length) = try iovec(vector, i)
            let (sum, overflow) = total.addingReportingOverflow(length)
            guard !overflow else { throw .invalidArgs }
            total = sum
        }
        return total
    }

    private static func iovec(_ vector: UInt64, _ i: UInt64) throws(Status) -> (UInt64, UInt64) {
        var entry = InlineArray<2, UInt64>(repeating: 0)
        var span = entry.mutableSpan
        let failed = span.withUnsafeMutableBytes { unsafe UserCopy.from($0.baseAddress!, vector + i * 16, 16) }
        guard failed == 0 else { throw .invalidArgs }
        return (entry[0], entry[1])
    }

    /// Moves up to `limit` bytes between the VMO at `offset` and the
    /// iovecs in order; stops at the first fault. The bytes moved.
    private static func transfer(_ holder: VmoPointer, _ offset: UInt64, _ limit: UInt64, _ vector: UInt64,
                                 _ count: UInt64, toUser: Bool) throws(Status) -> (moved: UInt64, faulted: Bool) {
        let (vmo, shift) = holder.target
        let offset = offset + shift
        var moved: UInt64 = 0, faults = 0
        var zeros = InlineArray<256, UInt8>(repeating: 0)
        for i in 0..<count where moved < limit {
            let (buffer, length) = try iovec(vector, i)
            var done: UInt64 = 0
            while done < length, moved < limit {
                let at = offset + moved
                let chunk = min(length - done, limit - moved, KernelLayout.pageSize - at % KernelLayout.pageSize)
                if toUser {
                    try Pagers.ensure(vmo, at, readAhead: limit - moved)
                } else {
                    try Pagers.ensureWritable(vmo, at, ahead: limit - moved)
                }
                // Copied under the page's owner's lock (K14h, VmoUserCopy).
                switch toUser ? VmoUserCopy.read(vmo, at, to: buffer + done, chunk)
                              : VmoUserCopy.write(vmo, at, from: buffer + done, chunk) {
                case .copied:
                    faults = 0
                case .absent where toUser:  // never written: zeros, nothing committed
                    var failed: Int32 = 0
                    var left = chunk
                    var span = zeros.mutableSpan
                    while left > 0, failed == 0 {
                        let piece = min(left, 256)
                        failed = span.withUnsafeMutableBytes {
                            unsafe UserCopy.to(buffer + done + (chunk - left), UnsafeRawPointer($0.baseAddress!), piece)
                        }
                        left -= piece
                    }
                    guard failed == 0 else { return (moved, true) }
                case .absent:
                    try VmoUserCopy.commit(vmo, at)
                    continue
                case .faulted:
                    faults += 1
                    guard faults < VmoUserCopy.attempts, VmoUserCopy.pageIn(buffer + done, chunk, write: toUser) else {
                        return (moved, true)
                    }
                    continue
                }
                done += chunk
                moved += chunk
            }
        }
        return (moved, false)
    }

    /// readv_at: up to the stream size. EOF (offset at or past it) is 0.
    static func read(_ object: ObjectPointer, at offset: UInt64, _ vector: UInt64, _ count: UInt64) throws(Status) -> UInt64 {
        let me = StreamPointer(object: object)
        let total = try capacity(vector, count)
        guard total > 0 else { return 0 }
        let size = streamSize(me.pointee.vmo)
        let end = min(offset.addingReportingOverflow(total).overflow ? .max : offset + total, size)
        guard end > offset else { return 0 }
        let (moved, faulted) = try transfer(me.pointee.vmo, offset, end - offset, vector, count, toUser: true)
        if moved == 0, faulted { throw .notFound }
        return moved
    }

    /// writev_at (or, `append`, at the stream size): the gap past the
    /// stream size zero-filled, the stream size grown by what landed.
    /// Returns (offset written at, bytes written).
    static func write(_ object: ObjectPointer, at requested: UInt64, append: Bool, _ vector: UInt64,
                      _ count: UInt64) throws(Status) -> (UInt64, UInt64) {
        let me = StreamPointer(object: object)
        let vmo = me.pointee.vmo
        let total = try capacity(vector, count)
        guard total > 0 else { return (requested, 0) }
        return try withSizeLock(vmo) { () throws(Status) -> (UInt64, UInt64) in
            try writeLocked(vmo, at: requested, append: append, total, vector, count)
        }
    }

    private static func writeLocked(_ vmo: VmoPointer, at requested: UInt64, append: Bool, _ total: UInt64,
                                    _ vector: UInt64, _ count: UInt64) throws(Status) -> (UInt64, UInt64) {
        let owner = vmo.sizeOwner
        let limit = owner.pointee.lock.withLock { owner.pointee.size }
        let size = streamSize(vmo)
        let offset = append ? size : requested
        let (sum, overflow) = offset.addingReportingOverflow(total)
        guard !overflow else { throw append ? .outOfRange : .fileBig }
        guard offset < limit else { throw .outOfRange }
        let end = min(sum, limit)
        if offset > size { try zero(vmo, size, offset - size) }
        let (moved, faulted) = try transfer(vmo, offset, end - offset, vector, count, toUser: false)
        if offset + moved > size {
            owner.pointee.lock.withLock { owner.pointee.streamSize = offset + moved }
        }
        if moved == 0, faulted { throw .notFound }
        return (offset, moved)
    }

    /// stream_seek.
    static func seek(_ object: ObjectPointer, whence: UInt32, _ offset: Int64) throws(Status) -> UInt64 {
        let me = StreamPointer(object: object)
        me.pointee.seekLock.lock()
        defer { me.pointee.seekLock.unlock() }
        let base: UInt64
        switch whence {
        case UInt32(CROI_STREAM_SEEK_ORIGIN_START):
            guard offset >= 0 else { throw .invalidArgs }
            base = 0
        case UInt32(CROI_STREAM_SEEK_ORIGIN_CURRENT): base = me.pointee.seek
        case UInt32(CROI_STREAM_SEEK_ORIGIN_END): base = streamSize(me.pointee.vmo)
        default: throw .invalidArgs
        }
        let result: UInt64
        if offset >= 0 {
            let (sum, overflow) = base.addingReportingOverflow(UInt64(offset))
            guard !overflow else { throw .invalidArgs }
            result = sum
        } else {
            guard UInt64(-(offset + 1)) + 1 <= base else { throw .invalidArgs }
            result = base - (UInt64(-(offset + 1)) + 1)
        }
        me.pointee.seek = result
        return result
    }

    /// readv / writev: at the seek position, which moves by what went.
    static func readAtSeek(_ object: ObjectPointer, _ vector: UInt64, _ count: UInt64) throws(Status) -> UInt64 {
        let me = StreamPointer(object: object)
        me.pointee.seekLock.lock()
        defer { me.pointee.seekLock.unlock() }
        let moved = try read(object, at: me.pointee.seek, vector, count)
        me.pointee.seek += moved
        return moved
    }

    static func writeAtSeek(_ object: ObjectPointer, append: Bool, _ vector: UInt64, _ count: UInt64) throws(Status) -> UInt64 {
        let me = StreamPointer(object: object)
        me.pointee.seekLock.lock()
        defer { me.pointee.seekLock.unlock() }
        let (offset, moved) = try write(object, at: me.pointee.seek, append: append || me.pointee.mode & modeAppend != 0,
                                        vector, count)
        me.pointee.seek = offset + moved
        return moved
    }

    static func info(_ object: ObjectPointer) -> croi_info_stream_t {
        let me = StreamPointer(object: object)
        me.pointee.seekLock.lock()
        defer { me.pointee.seekLock.unlock() }
        var info = croi_info_stream_t()
        info.options = me.pointee.mode
        info.seek = me.pointee.seek
        info.content_size = streamSize(me.pointee.vmo)
        return info
    }

    static func setAppend(_ object: ObjectPointer, _ on: Bool) {
        let me = StreamPointer(object: object)
        me.pointee.seekLock.withLock {
            me.pointee.mode = on ? me.pointee.mode | modeAppend : me.pointee.mode & ~modeAppend
        }
    }
}
