import CroiRuntime

/// userboot (K8b; Zircon's userboot): the first user process. The kernel
/// starts it in the root job with the root job, the root resource, bootfs
/// as a VMO, the boot data (firmware items, zbi.h), a debuglog as stdout
/// and the kernel command line as its environment. It finds the program
/// `userboot.next=` names in bootfs (default bin/launcher), loads its ELF
/// into a new process (read-only segments mapped straight from the bootfs
/// VMO, writable ones copied, PT_GNU_RELRO then read only, a stack from
/// PT_GNU_STACK), hands it
/// everything userboot was given in a processargs message, starts it and
/// reports when it exits; with `userboot.shutdown=` it then powers the
/// machine off or resets it.
@main
struct Userboot {
    struct Failure: Error {
        let what: StaticString
        let status: Int64
    }

    static var defaultNext: StaticString { "bin/launcher" }
    static var defaultStackSize: UInt64 { 256 * 1024 }
    static var pageSize: UInt64 { 4096 }

    static func main() {
        do throws(Failure) {
            try run()
        } catch {
            say("userboot: ")
            say(error.what)
            print(" failed: \(error.status)")
            croi_exit(1)
        }
        croi_exit(0)
    }

    static func run() throws(Failure) {
        let job = croi_take_startup_handle(croi_pa_hnd(UInt32(CROI_PA_JOB_DEFAULT), 0))
        let resource = croi_take_startup_handle(croi_pa_hnd(UInt32(CROI_PA_RESOURCE), 0))
        let bootfs = croi_take_startup_handle(croi_pa_hnd(UInt32(CROI_PA_VMO_BOOTFS), 0))
        guard job != 0, resource != 0, bootfs != 0 else { throw Failure(what: "taking startup handles", status: -11) }
        let next = option("userboot.next=") ?? bytes(defaultNext)
        // userboot.shutdown= (Power.swift) needs the root resource and the
        // boot data after they have gone to the program.
        let shutdown = option("userboot.shutdown=")
        var keptResource: UInt32 = 0
        var keptBootData: UInt32 = 0
        let sameRights: UInt64 = 1 << 31
        if shutdown != nil {
            try call("keeping the root resource", sys(CROI_SYS_HANDLE_DUPLICATE, UInt64(resource), sameRights,
                                                      address(&keptResource)))
        }

        var size: UInt64 = 0
        try call("sizing bootfs", sys(CROI_SYS_VMO_GET_SIZE, UInt64(bootfs), address(&size)))
        var bootfsBase: UInt64 = 0
        try call("mapping bootfs", sys(CROI_SYS_VMAR_MAP,
                                       UInt64(croi_vmar_root_self()) | UInt64(CROI_VM_PERM_READ) << 32, 0,
                                       UInt64(bootfs), 0, size, address(&bootfsBase)))
        let image = unsafe RawSpan(_unsafeStart: UnsafeRawPointer(bitPattern: UInt(bootfsBase))!, byteCount: Int(size))
        let file: Bootfs.File
        do throws(Bootfs.Error) {
            file = try Bootfs.find(next.span, in: image)
        } catch {
            say("userboot: ")
            write(next)
            say(error == .notFound ? " is not in bootfs\n" : ": bootfs is malformed\n")
            throw Failure(what: "finding the next program", status: -25)  // NOT_FOUND
        }
        let elf: ElfImage
        do throws(ElfImage.Error) {
            elf = try ElfImage(parsing: image.extracting(Int(file.offset)..<Int(file.offset + file.length)))
        } catch {
            say("userboot: ")
            write(next)
            say(": ")
            say(error.reason)
            say("\n")
            throw Failure(what: "reading its ELF", status: -10)
        }

        var process: UInt32 = 0
        var vmar: UInt32 = 0
        // Spawn to main (Todhchai's 200 µs budget) starts here; the program
        // gets the time as croi.spawn_ns= in its environment.
        let spawned = UInt64(bitPattern: sys(UInt64(CROI_SYS_CLOCK_MONOTONIC)))
        try call("creating its process", next.span.withUnsafeBytes { name in
            sys(CROI_SYS_PROCESS_CREATE, UInt64(job), UInt64(UInt(bitPattern: name.baseAddress)), UInt64(name.count), 0,
                address(&process), address(&vmar))
        })
        var region = croi_info_vmar_t()
        try call("reading its VMAR", sys(CROI_SYS_OBJECT_GET_INFO, UInt64(vmar), UInt64(CROI_INFO_VMAR), address(&region),
                                         UInt64(MemoryLayout<croi_info_vmar_t>.size)))
        // A static PIE (K11b) goes in a child VMAR at a random place in the
        // lower half of the root; an ET_EXEC where it was linked.
        var target = (vmar: vmar, base: region.base)
        var delta: UInt64 = 0
        if elf.kind == .pie {
            target = try randomPlace(in: vmar, region, size: elf.size)
            delta = target.base &- elf.base
        }
        let fileBytes = image.extracting(Int(file.offset)..<Int(file.offset + file.length))
        for i in 0..<elf.segmentCount {
            try load(elf.segments[i], of: elf, file: file, fileBytes: fileBytes, bootfs: bootfs,
                     bootfsBase: bootfsBase, vmar: target.vmar, vmarBase: target.base, delta: delta)
        }
        if let relro = elf.relro {  // relocated: read only from here on
            try call("protecting its RELRO", sys(CROI_SYS_VMAR_PROTECT,
                                                 UInt64(target.vmar) | UInt64(CROI_VM_PERM_READ) << 32,
                                                 relro.start &+ delta, relro.end - relro.start))
        }
        if target.vmar != vmar { _ = sys(CROI_SYS_HANDLE_CLOSE, UInt64(target.vmar)) }  // the region stays
        let stackSize = ((elf.stackSize ?? defaultStackSize) + pageSize - 1) & ~(pageSize - 1)
        var stack: UInt32 = 0
        var stackBase: UInt64 = 0
        try call("making its stack", sys(CROI_SYS_VMO_CREATE, stackSize, 0, address(&stack)))
        try call("mapping its stack", sys(CROI_SYS_VMAR_MAP,
                                          UInt64(vmar) | UInt64(CROI_VM_PERM_READ | CROI_VM_PERM_WRITE) << 32, 0,
                                          UInt64(stack), 0, stackSize, address(&stackBase)))
        _ = sys(CROI_SYS_HANDLE_CLOSE, UInt64(stack))

        var thread: UInt32 = 0
        try call("creating its thread", next.span.withUnsafeBytes { name in
            sys(CROI_SYS_THREAD_CREATE, UInt64(process), UInt64(UInt(bitPattern: name.baseAddress)),
                UInt64(name.count), 0, address(&thread))
        })

        // Everything userboot was given goes on, plus the new process's own
        // handles and a debuglog for its stdout.
        var processCopy: UInt32 = 0
        var threadCopy: UInt32 = 0
        var log: UInt32 = 0
        try call("duplicating handles", sys(CROI_SYS_HANDLE_DUPLICATE, UInt64(process), sameRights, address(&processCopy)))
        try call("duplicating handles", sys(CROI_SYS_HANDLE_DUPLICATE, UInt64(thread), sameRights, address(&threadCopy)))
        try call("creating its stdout", sys(CROI_SYS_DEBUGLOG_CREATE, 0, 0, address(&log)))
        var handles: [UInt32] = [processCopy, threadCopy, vmar, job, resource, bootfs, log]
        var infos: [UInt32] = [
            croi_pa_hnd(UInt32(CROI_PA_PROC_SELF), 0), croi_pa_hnd(UInt32(CROI_PA_THREAD_SELF), 0),
            croi_pa_hnd(UInt32(CROI_PA_VMAR_ROOT), 0), croi_pa_hnd(UInt32(CROI_PA_JOB_DEFAULT), 0),
            croi_pa_hnd(UInt32(CROI_PA_RESOURCE), 0), croi_pa_hnd(UInt32(CROI_PA_VMO_BOOTFS), 0),
            croi_pa_hnd(UInt32(CROI_PA_FD), 1),
        ]
        // The boot data and each kind's ranged root that the kernel gave
        // (by arch).
        for type in [CROI_PA_VMO_BOOTDATA, CROI_PA_MMIO_RESOURCE, CROI_PA_IRQ_RESOURCE, CROI_PA_IOPORT_RESOURCE, CROI_PA_SMC_RESOURCE,
                     CROI_PA_SYSTEM_RESOURCE] {
            let info = croi_pa_hnd(UInt32(type), 0)
            let ranged = croi_take_startup_handle(info)
            if ranged != 0 {
                if type == CROI_PA_VMO_BOOTDATA, shutdown != nil {
                    try call("keeping the boot data", sys(CROI_SYS_HANDLE_DUPLICATE, UInt64(ranged), sameRights,
                                                          address(&keptBootData)))
                }
                handles.append(ranged)
                infos.append(info)
            }
        }
        let message = processArgs(infos: infos, name: next, spawned: spawned)
        var ours: UInt32 = 0
        var theirs: UInt32 = 0
        try call("creating its bootstrap channel", sys(CROI_SYS_CHANNEL_CREATE, 0, address(&ours), address(&theirs)))
        try call("writing its bootstrap message", message.span.withUnsafeBytes { bytes in
            handles.span.withUnsafeBytes { values in
                sys(CROI_SYS_CHANNEL_WRITE, UInt64(ours), 0, UInt64(UInt(bitPattern: bytes.baseAddress)),
                    UInt64(bytes.count), UInt64(UInt(bitPattern: values.baseAddress)), UInt64(handles.count))
            }
        })
        _ = sys(CROI_SYS_HANDLE_CLOSE, UInt64(ours))
        try call("starting it", sys(CROI_SYS_PROCESS_START, UInt64(process), UInt64(thread), elf.entry &+ delta,
                                    stackBase + stackSize, UInt64(theirs), 0))
        say("userboot: started ")
        write(next)
        say("\n")

        var observed: UInt32 = 0
        try call("waiting for it", sys(CROI_SYS_OBJECT_WAIT_ONE, UInt64(process), UInt64(CROI_SIGNAL_TASK_TERMINATED),
                                       .max, address(&observed)))
        var info = croi_process_info_t()
        try call("reading its exit code", sys(CROI_SYS_PROCESS_INFO, UInt64(process), address(&info)))
        say("userboot: ")
        write(next)
        print(" exited with \(info.return_code)")
        if let shutdown { try Power.act(shutdown, resource: keptResource, bootData: keptBootData) }
    }

    /// A child VMAR of `size` bytes at a random page in the lower half of
    /// the root VMAR (ASLR, from cprng_draw), retried where it collides.
    static func randomPlace(in root: UInt32, _ region: croi_info_vmar_t, size: UInt64) throws(Failure)
        -> (vmar: UInt32, base: UInt64) {
        // Room for it in the lower half, else the subtraction (review fix:
        // it wrapped) and a modulus by zero pages.
        guard size < region.len / 2, (region.len / 2 - size) / pageSize > 0 else {
            throw Failure(what: "placing it", status: -14)  // OUT_OF_RANGE
        }
        let pages = (region.len / 2 - size) / pageSize
        let canMap = UInt32(CROI_VM_CAN_MAP_READ | CROI_VM_CAN_MAP_WRITE | CROI_VM_CAN_MAP_EXECUTE | CROI_VM_SPECIFIC)
        for _ in 0..<16 {
            var random: UInt64 = 0
            try call("drawing a base", sys(UInt64(CROI_SYS_CPRNG_DRAW), address(&random), 8))
            var child: UInt32 = 0
            var base: UInt64 = 0
            let status = sys(CROI_SYS_VMAR_ALLOCATE, UInt64(root) | UInt64(canMap) << 32, (random % pages) * pageSize,
                             size, address(&child), address(&base))
            if status == 0 { return (child, base) }
            guard status == -26 else { throw Failure(what: "placing it", status: status) }  // ALREADY_EXISTS: again
        }
        throw Failure(what: "placing it", status: -4)
    }

    /// Maps one PT_LOAD segment of the program at `file` in bootfs, at its
    /// address plus `delta`: one that is all file (read-only code and data)
    /// straight from the bootfs VMO's pages; anything else as a K11a child
    /// of the file's range (pages copied at first touch, the part past the
    /// file's bytes zeroed), with the static PIE's relocations written in.
    static func load(_ segment: ElfImage.Segment, of elf: ElfImage, file: Bootfs.File, fileBytes: RawSpan,
                     bootfs: UInt32, bootfsBase: UInt64, vmar: UInt32, vmarBase: UInt64,
                     delta: UInt64) throws(Failure) {
        let size = (segment.memsz + pageSize - 1) & ~(pageSize - 1)
        guard size > 0 else { return }
        let runAddress = segment.vaddr &+ delta
        guard runAddress >= vmarBase else { throw Failure(what: "placing a segment", status: -10) }
        var options = UInt32(CROI_VM_SPECIFIC)
        if segment.readable { options |= UInt32(CROI_VM_PERM_READ) }
        if segment.writable { options |= UInt32(CROI_VM_PERM_WRITE) }
        if segment.executable { options |= UInt32(CROI_VM_PERM_EXECUTE) }
        // K14r: a program built with BTI landing pads runs on guarded pages.
        if segment.executable, elf.branchTargets { options |= UInt32(CROI_VM_PERM_GUARDED) }
        var relocations = 0
        do throws(ElfImage.Error) {
            try elf.forEachRelocation(in: fileBytes) { (target, _) throws(ElfImage.Error) in
                if target >= segment.vaddr, target - segment.vaddr < size { relocations += 1 }
            }
        } catch {
            throw Failure(what: "reading its relocations", status: -10)
        }
        var mapped: UInt64 = 0
        let fileOffset = file.offset + segment.offset
        if !segment.writable, segment.filesz == segment.memsz, relocations == 0 {
            try call("mapping a segment", sys(CROI_SYS_VMAR_MAP, UInt64(vmar) | UInt64(options) << 32,
                                              runAddress - vmarBase, UInt64(bootfs), fileOffset, size, address(&mapped)))
            return
        }
        var vmo: UInt32 = 0
        if fileOffset % pageSize == 0 {
            try call("making a segment", sys(UInt64(CROI_SYS_VMO_CREATE_CHILD), UInt64(bootfs),
                                             UInt64(CROI_VMO_CHILD_SNAPSHOT_AT_LEAST_ON_WRITE), fileOffset, size,
                                             address(&vmo)))
            if segment.filesz < size {
                try call("zeroing a segment's tail", sys(UInt64(CROI_SYS_VMO_OP_RANGE), UInt64(vmo),
                                                          UInt64(CROI_VMO_OP_ZERO), segment.filesz,
                                                          size - segment.filesz, 0, 0))
            }
        } else {
            try call("making a segment", sys(CROI_SYS_VMO_CREATE, size, 0, address(&vmo)))
            try call("copying a segment", sys(CROI_SYS_VMO_WRITE, UInt64(vmo), bootfsBase + fileOffset, 0,
                                              segment.filesz))
        }
        defer { _ = sys(CROI_SYS_HANDLE_CLOSE, UInt64(vmo)) }  // the mapping keeps it
        if relocations > 0 {
            var failed: Int64 = 0
            do throws(ElfImage.Error) {
                try elf.forEachRelocation(in: fileBytes) { (target, addend) throws(ElfImage.Error) in
                    guard target >= segment.vaddr, target - segment.vaddr < size else { return }
                    var value = delta &+ addend
                    let status = sys(CROI_SYS_VMO_WRITE, UInt64(vmo), address(&value), target - segment.vaddr, 8)
                    if status != 0 { failed = status }
                }
            } catch {
                throw Failure(what: "reading its relocations", status: -10)
            }
            try call("relocating a segment", failed)
        }
        try call("mapping a segment", sys(CROI_SYS_VMAR_MAP, UInt64(vmar) | UInt64(options) << 32,
                                          runAddress - vmarBase, UInt64(vmo), 0, size, address(&mapped)))
    }

    /// The processargs message (processargs.h): header, handle infos,
    /// argv[0] (the program's bootfs name), then userboot's environment.
    static func processArgs(infos: [UInt32], name: [UInt8], spawned: UInt64) -> [UInt8] {
        let header = MemoryLayout<croi_proc_args_t>.size
        var environment: [UInt8] = []
        for i in 0..<croi_environ_count() {
            guard let entry = unsafe croi_environ(i) else { continue }
            let length = unsafe strlen(entry)
            for j in 0..<length { environment.append(unsafe UInt8(bitPattern: entry[j])) }
            environment.append(0)
        }
        environment.append(contentsOf: bytes("croi.spawn_ns="))
        environment.append(contentsOf: decimal(spawned))
        environment.append(0)
        var args = croi_proc_args_t()
        args.protocol = UInt32(CROI_PROCARGS_PROTOCOL)
        args.version = UInt32(CROI_PROCARGS_VERSION)
        args.handle_info_off = UInt32(header)
        args.args_off = UInt32(header + 4 * infos.count)
        args.args_num = 1
        args.environ_off = args.args_off + UInt32(name.count + 1)
        args.environ_num = UInt32(croi_environ_count()) + 1
        var message: [UInt8] = []
        withUnsafeBytes(of: &args) { raw in
            for i in 0..<raw.count { message.append(unsafe raw[i]) }
        }
        for info in infos {
            for shift in stride(from: 0, to: 32, by: 8) { message.append(UInt8(truncatingIfNeeded: info >> UInt32(shift))) }
        }
        message.append(contentsOf: name)
        message.append(0)
        message.append(contentsOf: environment)
        return message
    }

    /// `value` in decimal ASCII.
    static func decimal(_ value: UInt64) -> [UInt8] {
        var digits: [UInt8] = []
        var v = value
        repeat {
            digits.append(UInt8(ascii: "0") + UInt8(v % 10))
            v /= 10
        } while v != 0
        return digits.reversed()
    }

    /// The rest of the environment string that starts with `prefix`.
    static func option(_ prefix: StaticString) -> [UInt8]? {
        let wanted = bytes(prefix)
        for i in 0..<croi_environ_count() {
            guard let entry = unsafe croi_environ(i) else { continue }
            let length = unsafe strlen(entry)
            guard length >= wanted.count else { continue }
            var same = true
            for j in 0..<wanted.count where unsafe UInt8(bitPattern: entry[j]) != wanted[j] { same = false }
            guard same else { continue }
            var value: [UInt8] = []
            for j in wanted.count..<length { value.append(unsafe UInt8(bitPattern: entry[j])) }
            return value
        }
        return nil
    }

    static func bytes(_ text: StaticString) -> [UInt8] {
        var result: [UInt8] = []
        for i in 0..<text.utf8CodeUnitCount { result.append(unsafe text.utf8Start[i]) }
        return result
    }

    static func say(_ text: StaticString) {
        unsafe croi_write(UnsafeRawPointer(text.utf8Start).assumingMemoryBound(to: CChar.self), text.utf8CodeUnitCount)
    }

    static func write(_ text: [UInt8]) {
        text.span.withUnsafeBytes { bytes in
            unsafe croi_write(bytes.baseAddress?.assumingMemoryBound(to: CChar.self), bytes.count)
        }
    }

    static func call(_ what: StaticString, _ status: Int64) throws(Failure) {
        guard status == 0 else { throw Failure(what: what, status: status) }
    }

    static func sys(_ number: UInt64, _ a0: UInt64 = 0, _ a1: UInt64 = 0, _ a2: UInt64 = 0, _ a3: UInt64 = 0,
                    _ a4: UInt64 = 0, _ a5: UInt64 = 0) -> Int64 {
        croi_syscall6(number, a0, a1, a2, a3, a4, a5)
    }

    static func address<T>(_ value: inout T) -> UInt64 {
        withUnsafeMutablePointer(to: &value) { UInt64(UInt(bitPattern: $0)) }
    }
}
