/// Status codes, rights, signals and object types, with Zircon's values
/// (zircon/errors.h, rights.h, types.h), since croi keeps its ABI.
enum Status: Int32, Error, Equatable {
    case internalError = -1
    case notSupported = -2
    case noResources = -3
    case noMemory = -4
    case invalidArgs = -10
    case badHandle = -11
    case wrongType = -12
    case outOfRange = -14
    case bufferTooSmall = -15
    case badState = -20
    case timedOut = -21
    case shouldWait = -22
    case canceled = -23
    case peerClosed = -24
    case notFound = -25
    case alreadyExists = -26
    case alreadyBound = -27
    case accessDenied = -30
}

struct Rights: OptionSet, Equatable {
    let rawValue: UInt32
    static var duplicate: Rights { Rights(rawValue: 1 << 0) }
    static var transfer: Rights { Rights(rawValue: 1 << 1) }
    static var read: Rights { Rights(rawValue: 1 << 2) }
    static var write: Rights { Rights(rawValue: 1 << 3) }
    static var execute: Rights { Rights(rawValue: 1 << 4) }
    static var map: Rights { Rights(rawValue: 1 << 5) }
    static var getProperty: Rights { Rights(rawValue: 1 << 6) }
    static var setProperty: Rights { Rights(rawValue: 1 << 7) }
    static var enumerate: Rights { Rights(rawValue: 1 << 8) }
    static var destroy: Rights { Rights(rawValue: 1 << 9) }
    static var getPolicy: Rights { Rights(rawValue: 1 << 10) }
    static var setPolicy: Rights { Rights(rawValue: 1 << 11) }
    static var signal: Rights { Rights(rawValue: 1 << 12) }
    static var signalPeer: Rights { Rights(rawValue: 1 << 13) }
    static var wait: Rights { Rights(rawValue: 1 << 14) }
    static var inspect: Rights { Rights(rawValue: 1 << 15) }
    static var manageJob: Rights { Rights(rawValue: 1 << 16) }
    static var manageProcess: Rights { Rights(rawValue: 1 << 17) }
    static var manageThread: Rights { Rights(rawValue: 1 << 18) }
    static var manageVmo: Rights { Rights(rawValue: 1 << 24) }
    /// duplicate/replace: keep the source handle's rights.
    static var sameRights: Rights { Rights(rawValue: 1 << 31) }

    static var basic: Rights { [.transfer, .duplicate, .wait, .inspect] }
}

/// Signal bits (zx_signals_t).
enum Signals {
    static var none: UInt32 { 0 }
    /// Event: signaled. (Bit 3, __ZX_OBJECT_SIGNALED.)
    static var signaled: UInt32 { 1 << 3 }
    /// Process/thread/job terminated (ZX_TASK_TERMINATED, signal 3).
    static var taskTerminated: UInt32 { 1 << 3 }
    /// Thread running (ZX_THREAD_RUNNING, signal 4).
    static var threadRunning: UInt32 { 1 << 4 }
    /// Job: no child jobs (signal 4) / no child processes (signal 5).
    static var jobNoJobs: UInt32 { 1 << 4 }
    static var jobNoProcesses: UInt32 { 1 << 5 }
    /// A wait was canceled because its handle was closed.
    static var handleClosed: UInt32 { 1 << 23 }
    /// ZX_USER_SIGNAL_0...7.
    static var user: UInt32 { 0xFF00_0000 }
}

/// zx_obj_type_t.
enum ObjectType: UInt32 {
    case none = 0
    case process = 1
    case thread = 2
    case vmo = 3
    case channel = 4
    case event = 5
    case port = 6
    case resource = 15
    case eventpair = 16
    case job = 17
    case vmar = 18
    case timer = 22
    case exception = 29
}
