import CKernel
import Fmt
import PageTables
import Synchronization

/// Boot self-test for user address spaces (K4a): isolation between
/// address spaces at the same user address across switches and CPUs, the
/// shared kernel half, large pages, and teardown (tables and ASIDs come
/// back). Panics on failure.
enum AspaceSelfTest {
    static var at: UInt64 { 0x40_0000 }
    static var rounds: Int { 200 }
    nonisolated(unsafe) static var aspaces = InlineArray<2, UInt64>(repeating: 0)
    nonisolated(unsafe) static var lateKernelPage: UInt64 = 0

    static func run(_ console: Uart) {
        let freeBefore = pmm.freePages
        let liveBefore = UserAspaces.live.load(ordering: .relaxed)
        let pageA = page(), pageB = page()
        let cpu = Smp.count - 1
        do throws(VmError) {
            let a = try UserAspace(), b = try UserAspace()
            let rw = MapAttributes(writable: true)
            try a.map(virt: at, phys: pageA, size: KernelLayout.pageSize, rw)
            try b.map(virt: at, phys: pageB, size: KernelLayout.pageSize, rw)
            aspaces[0] = a.record.address
            aspaces[1] = b.record.address
            // A kernel mapping made after both address spaces exist.
            lateKernelPage = try kernelAspace.allocate(pages: 1)

            // Same CPU, then A on two CPUs at once while B runs too.
            let threads = [(cpu, 0), (cpu, 1), (max(0, cpu - 1), 0)] as InlineArray<3, (Int, UInt64)>
            var handles = UniqueArray<ThreadHandle>(capacity: 3)
            for i in 0..<threads.count { handles.append(spawn(threads[i].0, threads[i].1)) }
            while let handle = handles.popLast() {
                guard handle.join() == 0 else { panic("aspace self-test: address spaces not isolated") }
            }
            guard unsafe UnsafePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(pageA)))!.pointee >> 32 == 0xA,
                  unsafe UnsafePointer<UInt64>(bitPattern: UInt(KernelLayout.physmap(pageB)))!.pointee >> 32 == 0xB else {
                panic("aspace self-test: writes didn't reach the mapped pages")
            }

            // A 2 MiB-aligned physical range maps with one large page.
            if let big = pmm.allocateContiguous(512, alignLog2: 21) {
                try a.map(virt: 0x4000_0000, phys: big, size: 2 << 20, rw)
                guard a.query(0x4000_1234)?.pageSize == 2 << 20 else { panic("aspace self-test: no large page") }
                guard a.query(0x4000_1234)?.attributes.user == true else { panic("aspace self-test: not user") }
                try a.unmap(virt: 0x4000_0000, size: 2 << 20)
                pmm.free(big, count: 512)
            }
            try a.unmap(virt: at, size: KernelLayout.pageSize)
            guard a.query(at) == nil, b.query(at) != nil else { panic("aspace self-test: unmap leaked across spaces") }
            try kernelAspace.free(lateKernelPage)
        } catch {
            panic("aspace self-test: out of memory")
        }
        pmm.free(pageA)
        pmm.free(pageB)

        // ASIDs are recycled: more address spaces than there are ASIDs.
        for _ in 0..<300 {
            do throws(VmError) {
                _ = try UserAspace()
            } catch {
                panic("aspace self-test: out of memory")
            }
        }
        guard UserAspaces.live.load(ordering: .relaxed) == liveBefore, pmm.freePages == freeBefore else {
            panic("aspace self-test: tables or pages leaked")
        }
        console.write("  aspace: isolated across switches and CPUs, kernel half shared, 2 MiB pages, ")
        if Asids.count > 0 {
            console.write(decimal: UInt64(Asids.count))
            console.write(" ASIDs recycled")
        } else {
            console.write("no ASIDs (tables reloaded per switch)")
        }
        console.write(", teardown frees every table\n")
    }

    /// Joins address space `argument` (0: A, 1: B) and, between yields,
    /// writes its tag at `at` and checks it reads back; also uses a kernel
    /// page mapped after the address space was made.
    private static let worker: Thread.Entry = { which in
        Scheduler.setAspace(UserAspacePointer(address: aspaces[Int(which)]))
        let tag = (which == 0 ? 0xA : 0xB) << 32 as UInt64
        let word = unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(at))!
        let late = unsafe UnsafeMutablePointer<UInt64>(bitPattern: UInt(lateKernelPage))!
        var result = 0
        for i in 0..<UInt64(rounds) {
            arch_user_access_begin()
            unsafe word.pointee = tag | i
            arch_user_access_end()
            unsafe late.pointee = i
            Scheduler.yield()
            arch_user_access_begin()
            let seen = unsafe word.pointee
            arch_user_access_end()
            if seen >> 32 != tag >> 32 { result = 1 }
        }
        Scheduler.setAspace(nil)
        return result
    }

    private static func page() -> UInt64 {
        guard let phys = pmm.allocatePage() else { panic("aspace self-test: out of memory") }
        unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(phys)))!
            .initializeMemory(as: UInt8.self, repeating: 0, count: Int(KernelLayout.pageSize))
        return phys
    }

    private static func spawn(_ cpu: Int, _ which: UInt64) -> ThreadHandle {
        do throws(VmError) {
            return try Scheduler.spawn("aspace", cpu: cpu, worker, which)
        } catch {
            panic("aspace self-test: spawn failed")
        }
    }
}
