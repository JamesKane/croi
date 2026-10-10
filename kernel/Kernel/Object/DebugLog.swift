import CKernel
import Fmt
import Synchronization

/// The debuglog (K8a; Zircon's dlog and LogDispatcher): one system-wide
/// ring of records (croi_log_record_t, log.h), each a fixed 256-byte slot,
/// so the oldest are overwritten when it is full. Writers are user
/// processes (`debuglog_write`) and the kernel; readers are log objects
/// created READABLE, each with its own position, starting at the oldest
/// record still held. A dumper thread copies every record to the console
/// (`[sssss.mmm] pid:tid> text`), so writers never wait for the UART.
///
/// Lock order: debuglog -> object -> scheduler (readers' READABLE signal
/// changes under the debuglog lock; nothing takes it under those).
enum DebugLog {
    static var slots: UInt64 { 512 }
    static var slotSize: Int { Int(CROI_LOG_RECORD_MAX) }
    static var headerSize: Int { MemoryLayout<croi_log_record_t>.size }

    nonisolated(unsafe) private static var ring: UInt64 = 0
    /// The next record's sequence number; records [next - slots, next)
    /// are held. Written under the lock, read by the dumper without it.
    private static let next = Atomic<UInt64>(0)
    /// Readers (log objects), linked through `LogObject.nextReader`.
    nonisolated(unsafe) private static var readers: UInt64 = 0
    nonisolated(unsafe) private static var dumperQueue = QueuePointer(address: 0)
    nonisolated(unsafe) private static var dumped: UInt64 = 0

    static func initialize() {
        guard let raw = unsafe heap.allocate(size: Int(slots) * slotSize, alignment: Int(KernelLayout.pageSize)) else {
            panic("debuglog: out of memory")
        }
        ring = UInt64(UInt(bitPattern: raw))
        dumperQueue = QueuePointer.allocate()
        do throws(VmError) {
            let dumper = try Scheduler.spawn("dlog-dumper", dump, 0)
            _ = consume dumper  // detached
        } catch {
            panic("debuglog: no dumper thread")
        }
    }

    /// The oldest record still held.
    private static func oldest(_ next: UInt64) -> UInt64 { next > slots ? next - slots : 0 }

    private static func slot(_ sequence: UInt64) -> UInt64 {
        ring + (sequence % slots) * UInt64(slotSize)
    }

    /// Appends a record of `text` (truncated to CROI_LOG_RECORD_DATA_MAX
    /// bytes), from process `pid` / thread `tid` (0 for the kernel).
    static func write(severity: UInt8, flags: UInt8, _ text: Span<UInt8>, pid: UInt64, tid: UInt64) {
        let length = min(text.count, Int(CROI_LOG_RECORD_DATA_MAX))
        let now = Int64(bitPattern: Clock.now())
        debugLogLock.withLock {
            let sequence = next.load(ordering: .relaxed)
            let at = slot(sequence)
            var header = croi_log_record_t()
            header.sequence = sequence
            header.datalen = UInt16(length)
            header.severity = severity
            header.flags = flags
            header.timestamp = now
            header.pid = pid
            header.tid = tid
            unsafe UnsafeMutablePointer<croi_log_record_t>(bitPattern: UInt(at))!.pointee = header
            text.withUnsafeBytes { bytes in
                unsafe UnsafeMutableRawPointer(bitPattern: UInt(at) + UInt(headerSize))!
                    .copyMemory(from: bytes.baseAddress!, byteCount: length)
            }
            next.store(sequence + 1, ordering: .releasing)
            // Readers that were caught up have something now.
            var reader = readers
            while reader != 0 {
                let log = LogObjectPointer(object: ObjectPointer(address: reader))
                if log.pointee.position == sequence {
                    log.object.updateSignals(clear: 0, set: CROI_SIGNAL_READABLE)
                }
                reader = log.pointee.nextReader
            }
        }
        Scheduler.locked { _ = Scheduler.wakeAll(dumperQueue) }
    }

    /// Copies the reader's next record into `buffer` (whole, or as much as
    /// fits) and returns the record's size: SHOULD_WAIT when it has read
    /// everything. Skips records overwritten before it read them.
    static func read(_ log: LogObjectPointer, into buffer: inout InlineArray<256, UInt8>) throws(Status) -> Int {
        try debugLogLock.withLock { () throws(Status) -> Int in
            let end = next.load(ordering: .relaxed)
            log.pointee.position = max(log.pointee.position, oldest(end))
            guard log.pointee.position < end else {
                log.object.updateSignals(clear: CROI_SIGNAL_READABLE, set: 0)
                throw .shouldWait
            }
            let at = slot(log.pointee.position)
            let size = headerSize + Int(unsafe UnsafePointer<croi_log_record_t>(bitPattern: UInt(at))!.pointee.datalen)
            var span = buffer.mutableSpan
            span.withUnsafeMutableBytes { bytes in
                unsafe bytes.baseAddress!.copyMemory(from: UnsafeRawPointer(bitPattern: UInt(at))!, byteCount: size)
            }
            log.pointee.position += 1
            if log.pointee.position == end { log.object.updateSignals(clear: CROI_SIGNAL_READABLE, set: 0) }
            return size
        }
    }

    /// A new reader: starts at the oldest record, READABLE if there is one.
    static func addReader(_ log: LogObjectPointer) {
        debugLogLock.withLock {
            let end = next.load(ordering: .relaxed)
            log.pointee.position = oldest(end)
            log.pointee.nextReader = readers
            readers = log.object.address
            if log.pointee.position < end { log.object.updateSignals(clear: 0, set: CROI_SIGNAL_READABLE) }
        }
    }

    static func removeReader(_ log: LogObjectPointer) {
        debugLogLock.withLock {
            if readers == log.object.address {
                readers = log.pointee.nextReader
                return
            }
            var reader = readers
            while reader != 0 {
                let previous = LogObjectPointer(object: ObjectPointer(address: reader))
                if previous.pointee.nextReader == log.object.address {
                    previous.pointee.nextReader = log.pointee.nextReader
                    return
                }
                reader = previous.pointee.nextReader
            }
        }
    }

    /// The dumper thread: prints each record once, in order.
    private static let dump: Thread.Entry = { _ in
        var line = InlineArray<320, UInt8>(repeating: 0)
        while true {
            Scheduler.locked {
                while next.load(ordering: .acquiring) == dumped {
                    _ = Scheduler.block(on: dumperQueue, deadline: .max)
                }
            }
            var length = 0
            var dropped: UInt64 = 0
            debugLogLock.withLock {
                let end = next.load(ordering: .relaxed)
                if dumped < oldest(end) {
                    dropped = oldest(end) - dumped
                    dumped = oldest(end)
                }
                length = format(slot(dumped), into: &line)
                dumped += 1
            }
            guard let console = panicConsole else { continue }
            if dropped != 0 {
                console.write("[dlog: ")
                console.write(decimal: dropped)
                console.write(" records dropped]\n")
            }
            console.writeLines(utf8: line.span.extracting(0..<length), patience: 50_000_000)
        }
    }

    /// `[sssss.mmm] ppppp:ttttt> text\n`, as Zircon's dumper prints it.
    private static func format(_ at: UInt64, into line: inout InlineArray<320, UInt8>) -> Int {
        let record = unsafe UnsafePointer<croi_log_record_t>(bitPattern: UInt(at))!.pointee
        var n = 0
        func put(_ byte: UInt8) {
            line[n] = byte
            n += 1
        }
        func put(_ value: UInt64, width: Int) {
            var digits = InlineArray<20, UInt8>(repeating: UInt8(ascii: "0"))
            var v = value
            var count = 0
            repeat {
                digits[19 - count] = UInt8(ascii: "0") + UInt8(truncatingIfNeeded: v % 10)
                v /= 10
                count += 1
            } while v != 0
            for i in (20 - max(count, width))..<20 { put(digits[i]) }
        }
        let ms = UInt64(max(record.timestamp, 0)) / 1_000_000
        put(UInt8(ascii: "["))
        put(ms / 1000, width: 5)
        put(UInt8(ascii: "."))
        put(ms % 1000, width: 3)
        put(UInt8(ascii: "]"))
        put(UInt8(ascii: " "))
        put(record.pid, width: 5)
        put(UInt8(ascii: ":"))
        put(record.tid, width: 5)
        put(UInt8(ascii: ">"))
        put(UInt8(ascii: " "))
        let text = unsafe UnsafePointer<UInt8>(bitPattern: UInt(at) + UInt(headerSize))!
        var length = Int(record.datalen)
        while length > 0, unsafe text[length - 1] == UInt8(ascii: "\n") { length -= 1 }
        for i in 0..<length { put(unsafe text[i]) }
        put(UInt8(ascii: "\n"))
        return n
    }
}

let debugLogLock = SpinLock()

/// A debuglog handle's object (Zircon's LogDispatcher, type 12): any can
/// write; one created READABLE (with the debuglog resource) also reads,
/// from its own position.
struct LogObject: ~Copyable {
    var header = ObjectHeader(type: .log)
    let readable: Bool
    /// Readers: the next sequence number to return (debuglog lock).
    var position: UInt64 = 0
    var nextReader: UInt64 = 0

    static var readRights: Rights { [.basic, .read, .write, .signal] }
    static var writeRights: Rights { [.basic, .write, .signal] }
}

@safe struct LogObjectPointer {
    let object: ObjectPointer

    var pointee: LogObject {
        unsafeAddress { unsafe UnsafePointer<LogObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<LogObject>(bitPattern: UInt(object.address))! }
    }
}

/// debuglog_create / write / read (syscalls 110-112).
enum DebugLogs {
    static func create(readable: Bool) throws(Status) -> (ObjectPointer, Rights) {
        guard let object = Objects.allocate(LogObject(readable: readable)) else { throw .noMemory }
        if readable { DebugLog.addReader(LogObjectPointer(object: object)) }
        return (object, readable ? LogObject.readRights : LogObject.writeRights)
    }

    static func destroy(_ object: ObjectPointer) {
        let log = LogObjectPointer(object: object)
        if log.pointee.readable { DebugLog.removeReader(log) }
        Objects.free(object, as: LogObject.self)
    }

    /// The calling thread's process and thread koids (0 for kernel threads).
    static func writerKoids() -> (pid: UInt64, tid: UInt64) {
        let thread = Scheduler.current.pointee.object
        guard thread != 0 else { return (0, 0) }
        let object = ThreadObjectPointer(object: ObjectPointer(address: thread))
        return (object.pointee.process.header.koid, object.object.header.koid)
    }

    static func call(_ number: UInt64, _ a: InlineArray<6, UInt64>, _ table: borrowing HandleTable) throws(Status) -> Int64 {
        let handle = UInt32(truncatingIfNeeded: a[0])
        let options = UInt32(truncatingIfNeeded: a[1])
        switch number {
        case 110:  // debuglog_create(resource, options, out)
            // Write-only logs need no resource (Zircon lets a dynamic linker
            // log before it has one); readers need the debuglog resource.
            guard options & ~UInt32(CROI_LOG_FLAG_READABLE) == 0 else { throw .invalidArgs }
            if handle != 0 {
                try Resources.check(table, handle, system: UInt64(CROI_RSRC_SYSTEM_DEBUGLOG_BASE))
            } else if options != 0 {
                throw .badHandle
            }
            try Syscalls.check(a[2], MemoryLayout<UInt32>.size)
            let (object, rights) = try create(readable: options != 0)
            try Syscalls.put(try table.add(object, rights: rights), a[2])
        case 111:  // debuglog_write(log, options, buffer, length)
            guard options & ~UInt32(CROI_LOG_FLAGS_MASK) == 0 else { throw .invalidArgs }
            _ = try table.get(handle, type: .log, rights: .write)
            let length = min(a[3], UInt64(CROI_LOG_RECORD_DATA_MAX))
            var buffer = InlineArray<216, UInt8>(repeating: 0)
            var span = buffer.mutableSpan
            let copied = span.withUnsafeMutableBytes { unsafe UserCopy.from($0.baseAddress!, a[2], length) }
            guard copied == 0 else { throw .invalidArgs }
            let (pid, tid) = writerKoids()
            DebugLog.write(severity: UInt8(CROI_LOG_INFO), flags: UInt8(truncatingIfNeeded: options),
                           buffer.span.extracting(0..<Int(length)), pid: pid, tid: tid)
        case 112:  // debuglog_read(log, options, buffer, length) -> record size
            guard options == 0 else { throw .invalidArgs }
            let ref = try table.get(handle, type: .log, rights: .read)
            let log = LogObjectPointer(object: ref.object)
            guard log.pointee.readable else { throw .badState }
            try Syscalls.check(a[2], Int(min(a[3], UInt64(CROI_LOG_RECORD_MAX))))
            var record = InlineArray<256, UInt8>(repeating: 0)
            let size = try DebugLog.read(log, into: &record)
            let copy = min(UInt64(size), a[3])
            let copied = record.span.withUnsafeBytes { unsafe UserCopy.to(a[2], $0.baseAddress!, copy) }
            guard copied == 0 else { throw .invalidArgs }
            return Int64(copy)
        default:
            throw .notSupported
        }
        return 0
    }
}
