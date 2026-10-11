import CKernel

/// ZX_PROP_NAME (K13e): the 32-byte names of processes, threads, jobs,
/// BTIs and VMOs (Zircon's fbl::Name: at most 31 bytes, NUL terminated,
/// zero filled); resources' names read only. Kept in each object's record
/// under its lock (a VMO's in its VmoRecord, under the VMO lock). Other
/// types: WRONG_TYPE; a dead thread: BAD_STATE (Zircon's).
typealias ObjectName = InlineArray<32, UInt8>

enum Names {
    static var maxLength: Int { 32 }

    /// A name from user memory: min(size, 31) bytes, cut at the first NUL.
    static func fromUser(_ address: UInt64, _ size: UInt64) throws(Status) -> ObjectName {
        var name = ObjectName(repeating: 0)
        let length = min(size, UInt64(maxLength - 1))
        if length > 0 {
            var span = name.mutableSpan
            let copied = span.withUnsafeMutableBytes { raw in unsafe UserCopy.from(raw.baseAddress!, address, length) }
            guard copied == 0 else { throw .invalidArgs }
        }
        return normalized(name)
    }

    /// Zero after the first NUL; the last byte always NUL.
    static func normalized(_ name: ObjectName) -> ObjectName {
        var out = ObjectName(repeating: 0)
        for i in 0..<(maxLength - 1) {
            guard name[i] != 0 else { break }
            out[i] = name[i]
        }
        return out
    }

    static func get(_ object: ObjectPointer) throws(Status) -> ObjectName {
        switch object.header.type {
        case .process:
            return object.header.lock.withLock { ProcessPointer(object: object).pointee.name }
        case .job:
            return object.header.lock.withLock { JobPointer(object: object).pointee.name }
        case .bti:
            return object.header.lock.withLock { BtiPointer(object: object).pointee.name }
        case .thread:
            return try object.header.lock.withLock { () throws(Status) -> ObjectName in
                guard ThreadObjectPointer(object: object).pointee.state != .dead else { throw .badState }
                return ThreadObjectPointer(object: object).pointee.name
            }
        case .vmo:
            let vmo = VmoPointer(address: UnsafeVmoObject(object).vmo)
            return vmo.pointee.lock.withLock { vmo.pointee.name }
        case .resource:
            let resource = unsafe Resources.pointer(object)
            return normalized(unsafe resource.pointee.name)  // fixed at creation
        default:
            throw .wrongType
        }
    }

    static func set(_ object: ObjectPointer, _ name: ObjectName) throws(Status) {
        switch object.header.type {
        case .process:
            object.header.lock.withLock { ProcessPointer(object: object).pointee.name = name }
        case .job:
            object.header.lock.withLock { JobPointer(object: object).pointee.name = name }
        case .bti:
            object.header.lock.withLock { BtiPointer(object: object).pointee.name = name }
        case .thread:
            try object.header.lock.withLock { () throws(Status) in
                guard ThreadObjectPointer(object: object).pointee.state != .dead else { throw .badState }
                ThreadObjectPointer(object: object).pointee.name = name
            }
        case .vmo:
            let vmo = VmoPointer(address: UnsafeVmoObject(object).vmo)
            vmo.pointee.lock.withLock { vmo.pointee.name = name }
        default:
            throw .wrongType
        }
    }
}
