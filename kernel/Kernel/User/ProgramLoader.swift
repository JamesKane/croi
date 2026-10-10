import CKernel
import Elf
import Fmt

/// Starting a user program from an ELF image the kernel holds (K8a): the
/// boot self-test's programs now, userboot (in the kernel image) in K8b.
/// Zircon's kernel does the same for userboot only; everything later is
/// loaded by user space.
///
/// The program gets a new process in `job`: each PT_LOAD segment copied
/// into a VMO of its own and mapped with the segment's permissions, a
/// stack (PT_GNU_STACK's size, else 256 KiB) placed first fit, and a
/// bootstrap channel whose first message is Zircon's processargs
/// (processargs.h): its own process, thread and root VMAR, then the
/// caller's handles, the program name as argv[0] and the environment.
enum ProgramLoader {
    static var defaultStackSize: UInt64 { 256 * 1024 }

    /// A handle for the bootstrap message: `object` is retained for it.
    struct StartupHandle {
        let object: ObjectPointer
        let rights: Rights
        /// croi_pa_hnd(type, argument).
        let info: UInt32
    }

    /// Loads and starts `image` (an ET_EXEC): returns the process (a
    /// reference for the caller).
    static func start(_ image: RawSpan, name: StaticString, job: ObjectPointer, handles: Span<StartupHandle>,
                      environment: Span<UInt8>) throws(Status) -> ObjectPointer {
        let elf: ElfImage
        do throws(ElfImage.Error) {
            elf = try ElfImage(parsing: image)
        } catch {
            if let console = panicConsole {
                console.write("  loader: ")
                console.write(name)
                console.write(": ")
                console.write(error.reason)
                console.write("\n")
            }
            throw .invalidArgs
        }
        guard elf.kind == .executable else { throw .notSupported }
        let created = try Processes.create(job: job)
        let process = created.process
        let vmar = created.vmar
        defer { vmar.release() }
        do throws(Status) {
            let record = VmarPointer(object: vmar).info.aspace
            for i in 0..<elf.segmentCount {
                try load(elf.segments[i], from: image, into: record)
            }
            let stackSize = ((elf.stackSize ?? defaultStackSize) + KernelLayout.pageSize - 1) & ~(KernelLayout.pageSize - 1)
            let stack = try vmStatus { () throws(VmError) -> Vmo in try Vmo(anonymous: stackSize) }
            let stackBase = try vmStatus { () throws(VmError) -> UInt64 in
                try UserAspace.withView(record) { (aspace: borrowing UserAspace) throws(VmError) -> UInt64 in
                    try aspace.map(stack, size: stackSize, rights: [.read, .write])
                }
            }
            let thread = try Processes.createThread(process: process)
            defer { thread.release() }
            let bootstrap = try bootstrapChannel(name: name, process: process, thread: thread, vmar: vmar,
                                                 handles: handles, environment: environment)
            try Processes.start(thread: thread, pc: elf.entry, sp: stackBase + stackSize, arg0: UInt64(bootstrap),
                                arg1: 0, first: true)
        } catch {
            process.release()  // no thread ran: the last reference tears it down
            throw error
        }
        return process
    }

    private static func load(_ segment: ElfImage.Segment, from image: RawSpan,
                             into record: UserAspacePointer) throws(Status) {
        let size = (segment.memsz + KernelLayout.pageSize - 1) & ~(KernelLayout.pageSize - 1)
        guard size > 0 else { return }
        let vmo = try vmStatus { () throws(VmError) -> Vmo in try Vmo(anonymous: size) }
        if segment.filesz > 0 {
            image.withUnsafeBytes { bytes in
                vmo.writeBytes(at: 0, from: UInt64(UInt(bitPattern: bytes.baseAddress!)) + segment.offset,
                               count: segment.filesz)
            }
        }
        var rights = VmRights()
        if segment.readable { rights.insert(.read) }
        if segment.writable { rights.insert(.write) }
        if segment.executable { rights.insert(.execute) }
        _ = try vmStatus { () throws(VmError) -> UInt64 in
            try UserAspace.withView(record) { (aspace: borrowing UserAspace) throws(VmError) -> UInt64 in
                try aspace.map(vmo, size: size, at: segment.vaddr, rights: rights)
            }
        }
    }

    /// The bootstrap channel: writes the processargs message into one end
    /// and returns the other's handle in the process.
    private static func bootstrapChannel(name: StaticString, process: ObjectPointer, thread: ObjectPointer,
                                         vmar: ObjectPointer, handles: Span<StartupHandle>,
                                         environment: Span<UInt8>) throws(Status) -> UInt32 {
        var strings = 0
        for i in environment.indices where environment[i] == 0 { strings += 1 }
        let header = MemoryLayout<croi_proc_args_t>.size
        let count = 3 + handles.count
        let nameLength = name.utf8CodeUnitCount + 1
        let argsOffset = header + 4 * count
        let environOffset = argsOffset + nameLength
        let size = environOffset + environment.count
        guard count <= Int(CROI_CHANNEL_MAX_HANDLES), size <= Int(CROI_CHANNEL_MAX_BYTES) else {
            throw .outOfRange
        }
        guard let message = MessagePointer.allocate(bytes: UInt32(size), handles: UInt32(count)) else {
            throw .noMemory
        }
        let bytes = unsafe UnsafeMutableRawPointer(bitPattern: UInt(message.data))!
        unsafe bytes.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        var args = croi_proc_args_t()
        args.protocol = UInt32(CROI_PROCARGS_PROTOCOL)
        args.version = UInt32(CROI_PROCARGS_VERSION)
        args.handle_info_off = UInt32(header)
        args.args_off = UInt32(argsOffset)
        args.args_num = 1
        args.environ_off = UInt32(environOffset)
        args.environ_num = UInt32(strings)
        unsafe bytes.storeBytes(of: args, as: croi_proc_args_t.self)
        func add(_ i: Int, _ object: ObjectPointer, _ rights: Rights, _ info: UInt32) {
            object.retain()
            message.setHandle(i, object: object.address, rights: rights)
            unsafe bytes.storeBytes(of: info, toByteOffset: header + 4 * i, as: UInt32.self)
        }
        add(0, process, ProcessObject.defaultRights, croi_pa_hnd(UInt32(CROI_PA_PROC_SELF), 0))
        add(1, thread, ThreadObject.defaultRights, croi_pa_hnd(UInt32(CROI_PA_THREAD_SELF), 0))
        add(2, vmar, VmarObject.defaultRights, croi_pa_hnd(UInt32(CROI_PA_VMAR_ROOT), 0))
        for i in handles.indices {
            add(3 + i, handles[i].object, handles[i].rights, handles[i].info)
        }
        unsafe (bytes + argsOffset).copyMemory(from: name.utf8Start, byteCount: nameLength - 1)
        environment.withUnsafeBytes { source in
            unsafe (bytes + environOffset).copyMemory(from: source.baseAddress!, byteCount: source.count)
        }

        let (ours, theirs) = try Channels.create()
        defer {
            ours.release()
            theirs.release()
        }
        try Channels.write(ours, message)  // consumes the message
        return try Processes.addHandle(theirs, rights: ChannelObject.defaultRights, to: process)
    }
}
