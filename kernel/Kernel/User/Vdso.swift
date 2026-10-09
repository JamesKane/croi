import CKernel
import PageTables
import Synchronization

/// The shared read-only pages (roadmap "Shared read-only pages", ext 9):
/// the time page (Clock), topology and power. Each starts with a seqlock
/// sequence; the kernel writes under `lock`, odd while writing.
enum SharedPages {
    nonisolated(unsafe) private(set) static var topologyPage: UInt64 = 0
    nonisolated(unsafe) private(set) static var powerPage: UInt64 = 0
    private static let lock = SpinLock()

    /// After topology and capacities are known (scheduler start).
    static func initialize() {
        guard let topology = pmm.allocatePage(.wired), let power = pmm.allocatePage(.wired) else {
            panic("shared pages: out of memory")
        }
        for page in [topology, power] as InlineArray<2, UInt64> {
            unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(page)))!
                .initializeMemory(as: UInt8.self, repeating: 0, count: Int(KernelLayout.pageSize))
        }
        topologyPage = topology
        powerPage = power
        write {
            unsafe topologyPointer.pointee.version = UInt32(CROI_TOPOLOGY_PAGE_VERSION)
            unsafe topologyPointer.pointee.cpu_count = UInt32(Smp.count)
            unsafe powerPointer.pointee.version = UInt32(CROI_POWER_PAGE_VERSION)
            unsafe powerPointer.pointee.cpu_count = UInt32(Smp.count)
        }
        for cpu in 0..<Smp.count { publish(cpu: cpu) }
    }

    /// Republishes a CPU's topology entry and power hints (the scheduler
    /// calls this when capacity or hints change).
    static func publish(cpu: Int) {
        guard topologyPage != 0, cpu < Int(CROI_SHARED_MAX_CPUS) else { return }
        let placement = CpuTopologies.topology(cpu)
        let capacity = Scheduler.capacity(cpu: cpu)
        let hints = Scheduler.powerHints(cpu: cpu)
        write {
            // Both arrays start right after sequence, version and cpu_count.
            let topology = croi_topology_cpu_t(core_type: placement.coreType, capacity: UInt32(capacity),
                                               package: placement.package, core: placement.core,
                                               thread: placement.isThread ? 1 : 0, last_level_cache: placement.lastLevelCache)
            unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(topologyPage)))!
                .storeBytes(of: topology, toByteOffset: 16 + cpu * MemoryLayout<croi_topology_cpu_t>.stride,
                            as: croi_topology_cpu_t.self)
            let power = croi_power_cpu_t(wake_latency_ns: hints.wakeLatency, frequency_floor: hints.frequencyFloor)
            unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(powerPage)))!
                .storeBytes(of: power, toByteOffset: 16 + cpu * MemoryLayout<croi_power_cpu_t>.stride,
                            as: croi_power_cpu_t.self)
        }
    }

    /// Self-test only: writes an equal pair under the seqlock.
    static func writeTestPair(_ value: UInt64) {
        write {
            unsafe powerPointer.pointee.test_a = value
            unsafe powerPointer.pointee.test_b = value
        }
    }

    /// One seqlocked update of the topology and power pages.
    private static func write(_ body: () -> Void) {
        lock.withLock {
            bump()
            atomicMemoryFence(ordering: .releasing)
            body()
            atomicMemoryFence(ordering: .releasing)
            bump()
        }
    }

    private static func bump() {
        unsafe topologyPointer.pointee.sequence &+= 1
        unsafe powerPointer.pointee.sequence &+= 1
    }

    private static var topologyPointer: UnsafeMutablePointer<croi_topology_page_t> {
        unsafe UnsafeMutablePointer<croi_topology_page_t>(bitPattern: UInt(KernelLayout.physmap(topologyPage)))!
    }

    private static var powerPointer: UnsafeMutablePointer<croi_power_page_t> {
        unsafe UnsafeMutablePointer<croi_power_page_t>(bitPattern: UInt(KernelLayout.physmap(powerPage)))!
    }
}

/// The vDSO (K6c): its code, as a VMO, and the shared pages, mapped
/// together into a user address space. K7's process creation maps it into
/// every process; K8's loader may move to its ELF symbols.
enum Vdso {
    nonisolated(unsafe) private static var code: UInt64 = 0
    nonisolated(unsafe) private(set) static var codeSize: UInt64 = 0
    nonisolated(unsafe) private static var pages = InlineArray<3, UInt64>(repeating: 0)

    static func initialize() {
        let header = unsafe UnsafePointer<croi_vdso_header_t>(bitPattern: UInt(croi_vdso_address()))!.pointee
        guard header.magic == UInt32(CROI_VDSO_MAGIC), UInt64(header.code_size) >= croi_vdso_size(),
              UInt64(header.code_size) % KernelLayout.pageSize == 0 else { panic("vdso: bad image") }
        codeSize = UInt64(header.code_size)
        do throws(VmError) {
            let vmo = try Vmo(anonymous: codeSize)
            vmo.writeBytes(at: 0, from: croi_vdso_address(), count: croi_vdso_size())
            code = vmo.keep().address
            let shared = [Clock.timePage, SharedPages.topologyPage, SharedPages.powerPage] as InlineArray<3, UInt64>
            for i in 0..<3 { pages[i] = try Vmo(sharedKernelPage: shared[i]).keep().address }
        } catch {
            panic("vdso: out of memory")
        }
    }

    /// Maps the vDSO (read/execute) and its pages (read only) into
    /// `aspace`, in a region of their own. Returns the vDSO's base.
    static func map(into aspace: borrowing UserAspace) throws(VmError) -> UInt64 {
        let page = KernelLayout.pageSize
        let region = try aspace.allocateRegion(size: codeSize + 3 * page)
        let size = codeSize
        _ = try Vmo.withBorrowed(VmoPointer(address: code)) { (vmo: borrowing Vmo) throws(VmError) -> UInt64 in
            try aspace.map(vmo, size: size, at: region.base, in: region.id, rights: [.read, .execute])
        }
        for i in 0..<3 {
            let at = region.base + size + UInt64(i) * page
            _ = try Vmo.withBorrowed(VmoPointer(address: pages[i])) { (vmo: borrowing Vmo) throws(VmError) -> UInt64 in
                try aspace.map(vmo, size: page, at: at, in: region.id, rights: [.read])
            }
        }
        return region.base
    }
}
