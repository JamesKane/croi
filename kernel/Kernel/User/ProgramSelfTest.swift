import CKernel
import Fmt

/// Boot self-test (K8a): the Embedded Swift test program (user/test/swift)
/// started from its ELF by `ProgramLoader`, with a debuglog as stdout and
/// an environment in its bootstrap message, and the root resource (it
/// creates a readable debuglog itself). It must exit 0x600D, and the
/// records it wrote must read back through a READABLE debuglog, in order,
/// tagged with its process koid. Afterwards nothing it made is left.
enum ProgramSelfTest {
    static func run(_ console: Uart) {
        let before = ProcessSelfTest.Counts()
        let (reader, _) = created { () throws(Status) in try DebugLogs.create(readable: true) }
        drain(reader)  // whatever earlier writers left
        let (stdout, stdoutRights) = created { () throws(Status) in try DebugLogs.create(readable: false) }
        var handles = InlineArray<2, ProgramLoader.StartupHandle>(repeating: ProgramLoader.StartupHandle(
            object: stdout, rights: stdoutRights, info: croi_pa_hnd(UInt32(CROI_PA_FD), 1)))
        handles[1] = ProgramLoader.StartupHandle(object: Resources.root, rights: ResourceObject.defaultRights,
                                                 info: croi_pa_hnd(UInt32(CROI_PA_RESOURCE), 0))
        let environment: StaticString = "croi.test=1\0swift.greeting=dia duit\0"
        let image = unsafe RawSpan(_unsafeStart: UnsafeRawPointer(bitPattern: UInt(croi_swift_test_address()))!,
                                   byteCount: Int(croi_swift_test_size()))
        let process: ObjectPointer
        do throws(Status) {
            process = try ProgramLoader.start(
                image, name: "swifttest", job: Processes.rootJob, handles: handles.span,
                environment: unsafe Span(_unsafeStart: environment.utf8Start, count: environment.utf8CodeUnitCount))
        } catch {
            panic("program self-test: loading the Swift program")
        }
        let firstBase = ProgramLoader.lastBase
        stdout.release()
        let giveUp = Clock.now() + 30_000_000_000
        while !Processes.info(process: process).exited {
            guard Clock.now() < giveUp else { panic("program self-test: the Swift program never ended") }
            Scheduler.sleep(until: Clock.now() + 2_000_000)
        }
        let code = Processes.info(process: process).returnCode
        let koid = process.header.koid
        process.release()
        guard code == 0x600D else {
            console.write("  swift:  exit code ")
            console.write(hex: UInt64(bitPattern: code))
            console.write("\n")
            panic("program self-test: the Swift program failed")
        }

        // Its stdout, as records tagged with its koid.
        let expected: InlineArray<5, StaticString> = [
            "swift: hello from user mode",
            "swift: 1000 squares, sum 332833500",
            "swift: env croi.test=1",
            "swift: env swift.greeting=dia duit",
            "swift: round trip",  // through a log it created and read back itself
        ]
        var matched = 0
        var record = InlineArray<256, UInt8>(repeating: 0)
        while true {
            let size: Int
            do throws(Status) {
                size = try DebugLog.read(LogObjectPointer(object: reader), into: &record)
            } catch {
                break
            }
            let header = unsafe record.span.bytes.unsafeLoadUnaligned(as: croi_log_record_t.self)
            guard header.pid == koid else { continue }
            guard matched < expected.count,
                  same(record.span.extracting(DebugLog.headerSize..<size), expected[matched]) else {
                console.write("  swift:  unexpected record: ")
                console.write(utf8: record.span.extracting(DebugLog.headerSize..<size))
                console.write("\n")
                panic("program self-test: the Swift program's output")
            }
            matched += 1
        }
        guard matched == expected.count else { panic("program self-test: records missing") }
        reader.release()

        // A static PIE (K11b) lands somewhere new each time: a second run.
        let (stdout2, stdout2Rights) = created { () throws(Status) in try DebugLogs.create(readable: false) }
        handles[0] = ProgramLoader.StartupHandle(object: stdout2, rights: stdout2Rights,
                                                 info: croi_pa_hnd(UInt32(CROI_PA_FD), 1))
        let second: ObjectPointer
        do throws(Status) {
            second = try ProgramLoader.start(
                image, name: "swifttest", job: Processes.rootJob, handles: handles.span,
                environment: unsafe Span(_unsafeStart: environment.utf8Start, count: environment.utf8CodeUnitCount))
        } catch {
            panic("program self-test: loading the Swift program again")
        }
        let secondBase = ProgramLoader.lastBase
        stdout2.release()
        let giveUp2 = Clock.now() + 30_000_000_000
        while !Processes.info(process: second).exited {
            guard Clock.now() < giveUp2 else { panic("program self-test: the second run never ended") }
            Scheduler.sleep(until: Clock.now() + 2_000_000)
        }
        let secondCode = Processes.info(process: second).returnCode
        second.release()
        guard secondCode == 0x600D, firstBase != secondBase, firstBase != 0, secondBase != 0,
              firstBase % KernelLayout.pageSize == 0, secondBase % KernelLayout.pageSize == 0 else {
            console.write("  swift:  PIE bases ")
            console.write(hex: firstBase)
            console.write(", ")
            console.write(hex: secondBase)
            console.write("\n")
            panic("program self-test: a static PIE's random base")
        }
        // The same program as an ET_EXEC whose dynamic section has no
        // relocations (linked --export-dynamic): where it was linked.
        let (stdout3, stdout3Rights) = created { () throws(Status) in try DebugLogs.create(readable: false) }
        handles[0] = ProgramLoader.StartupHandle(object: stdout3, rights: stdout3Rights,
                                                 info: croi_pa_hnd(UInt32(CROI_PA_FD), 1))
        let executable = unsafe RawSpan(_unsafeStart: UnsafeRawPointer(bitPattern: UInt(croi_swift_test_exec_address()))!,
                                        byteCount: Int(croi_swift_test_exec_size()))
        let third: ObjectPointer
        do throws(Status) {
            third = try ProgramLoader.start(
                executable, name: "swifttest-exec", job: Processes.rootJob, handles: handles.span,
                environment: unsafe Span(_unsafeStart: environment.utf8Start, count: environment.utf8CodeUnitCount))
        } catch {
            panic("program self-test: loading an executable with a dynamic section")
        }
        stdout3.release()
        let giveUp3 = Clock.now() + 30_000_000_000
        while !Processes.info(process: third).exited {
            guard Clock.now() < giveUp3 else { panic("program self-test: the third run never ended") }
            Scheduler.sleep(until: Clock.now() + 2_000_000)
        }
        let thirdCode = Processes.info(process: third).returnCode
        third.release()
        guard thirdCode == 0x600D else { panic("program self-test: the executable with a dynamic section failed") }
        before.expectUnchanged(console)
        console.write("  swift:  Embedded Swift static PIE at random bases (")
        console.write(hex: firstBase)
        console.write(", ")
        console.write(hex: secondBase)
        console.write("): processargs (handles, environment), ")
        console.write("heap over its VMAR, stdout as ")
        console.write(decimal: UInt64(matched))
        console.write(" debuglog records, debuglog create/read/wait from user mode; an ET_EXEC with a dynamic section")
        console.write(" and no relocations; RELRO read only; all torn down\n")
    }

    private static func created(_ body: () throws(Status) -> (ObjectPointer, Rights)) -> (ObjectPointer, Rights) {
        do throws(Status) {
            return try body()
        } catch {
            panic("program self-test: creating a debuglog")
        }
    }

    /// Reads everything a reader has.
    private static func drain(_ reader: ObjectPointer) {
        var record = InlineArray<256, UInt8>(repeating: 0)
        while (try? DebugLog.read(LogObjectPointer(object: reader), into: &record)) != nil {}
    }

    private static func same(_ bytes: Span<UInt8>, _ text: StaticString) -> Bool {
        guard bytes.count == text.utf8CodeUnitCount else { return false }
        for i in bytes.indices where unsafe bytes[i] != text.utf8Start[i] { return false }
        return true
    }
}
