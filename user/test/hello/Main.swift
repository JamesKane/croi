import CroiRuntime

/// bin/hello (K8b): the program the boot test's command line names as
/// userboot.next. Checks it got what userboot hands on (its own process,
/// thread and root VMAR, the root job, the root resource, bootfs, stdout,
/// the kernel command line) and exits 0 if so; userboot reports the code.
@main
struct Hello {
    static func main() {
        print("hello: started from bootfs by userboot")
        var missing = 0
        let wanted: [UInt32] = [
            croi_pa_hnd(UInt32(CROI_PA_THREAD_SELF), 0), croi_pa_hnd(UInt32(CROI_PA_JOB_DEFAULT), 0),
            croi_pa_hnd(UInt32(CROI_PA_RESOURCE), 0), croi_pa_hnd(UInt32(CROI_PA_VMO_BOOTFS), 0),
        ]
        for info in wanted where croi_take_startup_handle(info) == 0 { missing += 1 }
        if croi_process_self() == 0 || croi_vmar_root_self() == 0 { missing += 1 }
        // Bytes, not String ==: that needs Unicode normalization tables.
        let next: StaticString = "userboot.next=bin/hello"
        var sawNext = false
        for i in 0..<croi_environ_count() {
            guard let entry = unsafe croi_environ(i), unsafe strlen(entry) == next.utf8CodeUnitCount else { continue }
            var same = true
            for j in 0..<next.utf8CodeUnitCount where unsafe UInt8(bitPattern: entry[j]) != next.utf8Start[j] {
                same = false
            }
            if same { sawNext = true }
        }
        print("hello: \(missing) startup handles missing, command line \(sawNext ? "seen" : "missing")")
        croi_exit(missing == 0 && sawNext ? 0 : 1)
    }
}
