import CHandoff
import CKernel
import Fmt

/// Starting user space (K8b, Zircon's userboot): the kernel's last act at
/// boot. userboot (user/userboot, an ELF in the kernel image) is loaded by
/// `ProgramLoader` into a process in the root job, with what it needs to
/// start everything else: the root job, the root resource, bootfs as a VMO
/// (the loader's CROI_MEM_BOOTFS pages, adopted), the boot data (firmware
/// items, `BootData`), a debuglog as stdout, and the kernel command line's
/// words as its environment. userboot finds
/// `userboot.next=` in bootfs and starts it.
enum Userboot {
    static func start(_ console: Uart) {
        // Kernel entry to user space (monotonic time starts at entry):
        // Todhchai's console budget, 100 ms, holds with self-tests off.
        let now = Clock.now()
        console.write("  boot:   userboot starting ")
        console.write(decimal: now / 1_000_000)
        console.write(" ms after kernel entry\n")
        if SelfTests.enabled {
            Budgets.report(console, "boot.userboot_start_selftests", now)
        } else {
            Budgets.report(console, "boot.userboot_start", now, target: 100_000_000)
        }
        guard bootHandoff.bootfs != 0, bootHandoff.bootfs_size != 0 else {
            console.write("  userboot: no bootfs, not starting user space\n")
            return
        }
        let page = KernelLayout.pageSize
        let size = (bootHandoff.bootfs_size + page - 1) & ~(page - 1)
        let bootfs: Vmo
        do throws(VmError) {
            bootfs = try Vmo(adopting: bootHandoff.bootfs, size: size)
        } catch {
            panic("userboot: bootfs isn't wired RAM the PMM knows")
        }
        // The loader's pages past the image's end are whatever was there.
        let tail = bootHandoff.bootfs_size % page
        if tail != 0, let phys = bootfs.record.lookup(at: size - page) {
            unsafe UnsafeMutableRawPointer(bitPattern: UInt(KernelLayout.physmap(phys) + tail))!
                .initializeMemory(as: UInt8.self, repeating: 0, count: Int(page - tail))
        }
        do throws(Status) {
            let bootfsObject = try VmoObject.wrap(bootfs.record)
            defer { bootfsObject.release() }
            let (stdout, stdoutRights) = try DebugLogs.create(readable: false)
            defer { stdout.release() }
            var handles = InlineArray<10, ProgramLoader.StartupHandle>(repeating: ProgramLoader.StartupHandle(
                object: Processes.rootJob, rights: JobObject.defaultRights,
                info: croi_pa_hnd(UInt32(CROI_PA_JOB_DEFAULT), 0)))
            handles[1] = ProgramLoader.StartupHandle(object: Resources.root, rights: ResourceObject.defaultRights,
                                                     info: croi_pa_hnd(UInt32(CROI_PA_RESOURCE), 0))
            handles[2] = ProgramLoader.StartupHandle(object: bootfsObject,
                                                     rights: VmoObject.defaultRights.union(.execute),
                                                     info: croi_pa_hnd(UInt32(CROI_PA_VMO_BOOTFS), 0))
            handles[3] = ProgramLoader.StartupHandle(object: stdout, rights: stdoutRights,
                                                     info: croi_pa_hnd(UInt32(CROI_PA_FD), 1))
            handles[4] = ProgramLoader.StartupHandle(object: BootData.object, rights: BootData.rights,
                                                     info: croi_pa_hnd(UInt32(CROI_PA_VMO_BOOTDATA), 0))
            // Each kind's ranged root, as Zircon's userboot gets them.
            var count = 5
            let kinds: InlineArray<5, (UInt32, UInt32)> = [
                (UInt32(CROI_RSRC_KIND_MMIO), UInt32(CROI_PA_MMIO_RESOURCE)),
                (UInt32(CROI_RSRC_KIND_IRQ), UInt32(CROI_PA_IRQ_RESOURCE)),
                (UInt32(CROI_RSRC_KIND_IOPORT), UInt32(CROI_PA_IOPORT_RESOURCE)),
                (UInt32(CROI_RSRC_KIND_SMC), UInt32(CROI_PA_SMC_RESOURCE)),
                (UInt32(CROI_RSRC_KIND_SYSTEM), UInt32(CROI_PA_SYSTEM_RESOURCE)),
            ]
            for i in 0..<5 where Resources.rangedRoots[Int(kinds[i].0)] != 0 {
                handles[count] = ProgramLoader.StartupHandle(object: ObjectPointer(address: Resources.rangedRoots[Int(kinds[i].0)]),
                                                             rights: ResourceObject.defaultRights,
                                                             info: croi_pa_hnd(kinds[i].1, 0))
                count += 1
            }
            let image = unsafe RawSpan(_unsafeStart: UnsafeRawPointer(bitPattern: UInt(croi_userboot_address()))!,
                                       byteCount: Int(croi_userboot_size()))
            let process = try BootOptions.withEnvironment { (environment: Span<UInt8>) throws(Status) -> ObjectPointer in
                try ProgramLoader.start(image, name: "userboot", job: Processes.rootJob, handles: handles.span.extracting(0..<count),
                                        environment: environment)
            }
            process.release()  // it runs on its own
        } catch {
            console.write("  userboot: failed to start (status -")
            console.write(decimal: UInt64(-Int64(error.rawValue)))
            console.write(")\n")
            panic("userboot: not started")
        }
        console.write("  userboot: started, bootfs ")
        console.write(decimal: size / 1024)
        console.write(" KiB\n")
    }
}
