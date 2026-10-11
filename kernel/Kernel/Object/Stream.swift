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
/// blocking Mutex of its own, and every size-changing write (any stream)
/// under one global Mutex (Zircon's per-VMO StreamSizeManager serializes
/// these; one lock is simpler and enough). A faulting user buffer ends a
/// transfer short; with nothing moved it is NOT_FOUND (Zircon's).
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
    static let sizeLock = Mutex()
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

    static func streamSize(_ vmo: VmoPointer) -> UInt64 {
        vmo.pointee.lock.withLock { vmo.pointee.streamSize ?? vmo.pointee.size }
    }

    /// vmo_set_stream_size: OUT_OF_RANGE past the VMO; the bytes from the
    /// smaller of the old and new sizes to the VMO's end read as zero.
    static func setStreamSize(_ vmo: VmoPointer, _ size: UInt64) throws(Status) {
        guard case .anonymous = vmo.pointee.kind else { throw .notSupported }
        guard size <= vmo.pointee.size else { throw .outOfRange }
        sizeLock.lock()
        defer { sizeLock.unlock() }
        let old = streamSize(vmo)
        let from = min(old, size)
        try zero(vmo, from, vmo.pointee.size - from)
        vmo.pointee.lock.withLock { vmo.pointee.streamSize = size }
    }

    private static func zero(_ vmo: VmoPointer, _ offset: UInt64, _ length: UInt64) throws(Status) {
        guard length > 0 else { return }
        if vmo.pointee.pager != nil || vmo.pointee.readsFromPager {  // zeroed in place: the pages first
            var at = offset & ~(KernelLayout.pageSize - 1)
            while at < offset + length {
                try Pagers.ensureWritable(vmo, at, ahead: offset + length - at)
                at += KernelLayout.pageSize
            }
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
    private static func transfer(_ vmo: VmoPointer, _ offset: UInt64, _ limit: UInt64, _ vector: UInt64,
                                 _ count: UInt64, toUser: Bool) throws(Status) -> (moved: UInt64, faulted: Bool) {
        var moved: UInt64 = 0
        var zeros = InlineArray<256, UInt8>(repeating: 0)
        for i in 0..<count where moved < limit {
            let (buffer, length) = try iovec(vector, i)
            var done: UInt64 = 0
            while done < length, moved < limit {
                let at = offset + moved
                let within = at % KernelLayout.pageSize
                let chunk = min(length - done, limit - moved, KernelLayout.pageSize - within)
                if toUser {
                    try Pagers.ensure(vmo, at, readAhead: limit - moved)
                } else {
                    try Pagers.ensureWritable(vmo, at, ahead: limit - moved)
                }
                var failed: Int32
                if toUser {
                    if let phys = vmo.content(at: at) {
                        failed = unsafe UserCopy.to(buffer + done, UnsafeRawPointer(bitPattern: UInt(KernelLayout.physmap(phys) + within))!, chunk)
                    } else {  // never written: zeros, nothing committed
                        failed = 0
                        var left = chunk
                        var span = zeros.mutableSpan
                        while left > 0, failed == 0 {
                            let piece = min(left, 256)
                            failed = span.withUnsafeMutableBytes {
                                unsafe UserCopy.to(buffer + done + (chunk - left), UnsafeRawPointer($0.baseAddress!), piece)
                            }
                            left -= piece
                        }
                    }
                } else {
                    guard let phys = vmo.commit(at: at) else { throw .noMemory }
                    failed = unsafe UserCopy.from(UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(phys) + within))!,
                                                  buffer + done, chunk)
                }
                guard failed == 0 else { return (moved, true) }
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
        sizeLock.lock()
        defer { sizeLock.unlock() }
        let size = streamSize(vmo)
        let offset = append ? size : requested
        let (sum, overflow) = offset.addingReportingOverflow(total)
        guard !overflow else { throw append ? .outOfRange : .fileBig }
        guard offset < vmo.pointee.size else { throw .outOfRange }
        let end = min(sum, vmo.pointee.size)
        if offset > size { try zero(vmo, size, offset - size) }
        let (moved, faulted) = try transfer(vmo, offset, end - offset, vector, count, toUser: false)
        if offset + moved > size { vmo.pointee.lock.withLock { vmo.pointee.streamSize = offset + moved } }
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
