import CKernel
import Synchronization

/// Per-thread W^X for JIT reservations (ext 7, F-218; the K4c decision).
///
/// - `protectionKeys` (amd64 PKU): a JIT reservation gets a protection key
///   and its pages are mapped read/write/execute with that key. Every
///   thread starts with writes to all keys disabled (its PKRU), so the
///   pages are read/execute to it; a thread opens writes to one key for
///   itself only (`Scheduler.setJitWritable`; in user space a WRPKRU, no
///   syscall). PKU gates data access, not fetch: other threads keep the
///   region read/execute while one writes.
/// - `views` (no keys: arm64 without POE, which neither target board has;
///   rv64; older x86): no page is ever writable and executable. A JIT maps
///   two views of one VMO into its reservation, read/write and
///   read/execute, at different addresses.
///
/// Everywhere else W^X holds absolutely: no mapping is both writable and
/// executable.
enum Jit {
    enum Mechanism { case protectionKeys, views }

    nonisolated(unsafe) private(set) static var mechanism = Mechanism.views
    /// Keys 1-15 in use (key 0 is everything else's).
    nonisolated(unsafe) private static var keys: UInt16 = 1
    private static let lock = SpinLock()

    /// A user thread's PKRU at start: writes disabled for keys 1-15.
    static var defaultUserPkru: UInt32 {
        var value: UInt32 = 0
        for key in 1..<16 { value |= 1 << UInt32(2 * key + 1) }  // WD
        return value
    }

    /// Picks the mechanism; with PKU, enables it on every CPU.
    static func initialize() {
        #if arch(x86_64)
        if arch_pku_enable() != 0 {
            Ipi.callOthers(enableHere, 0)
            mechanism = .protectionKeys
        }
        #endif
    }

    #if arch(x86_64)
    private static let enableHere: Ipi.Function = { _ in
        _ = arch_pku_enable()
    }
    #endif

    static var poePresent: Bool {
        #if arch(arm64)
        arch_has_poe() != 0
        #else
        false
        #endif
    }

    /// A protection key for a JIT reservation (nil: none left).
    static func allocateKey() -> UInt8? {
        lock.withLock { () -> UInt8? in
            for key in 1..<16 where keys & (1 << UInt16(key)) == 0 {
                keys |= 1 << UInt16(key)
                return UInt8(key)
            }
            return nil
        }
    }

    static func freeKey(_ key: UInt8) {
        guard key != 0 else { return }
        lock.withLock { keys &= ~(1 << UInt16(key)) }
    }

    /// Whether `rights` may be mapped in a region with JIT key `key`.
    static func allows(_ rights: VmRights, key: UInt8) -> Bool {
        !(rights.contains(.write) && rights.contains(.execute)) || (mechanism == .protectionKeys && key != 0)
    }
}
