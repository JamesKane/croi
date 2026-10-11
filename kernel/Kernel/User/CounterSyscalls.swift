import CKernel

/// Counter syscalls (K10a; numbers in user/include/croi/syscall.h, values
/// in counter.h): Zircon's counter_create, add, read and write with its
/// rights, plus croi's counter_wait and counter_wait_async.
extension Syscalls {
    static func counterCall(_ number: UInt64, _ a: InlineArray<6, UInt64>,
                            _ table: borrowing HandleTable) throws(Status) {
        let handle = UInt32(truncatingIfNeeded: a[0])
        switch number {
        case 160:  // counter_create(options, out)
            guard a[0] == 0 else { throw .invalidArgs }
            try check(a[1], MemoryLayout<UInt32>.size)
            try addAndPut(try Counters.create(), rights: CounterObject.defaultRights, a[1], table)
        case 161:  // counter_add(counter, amount): READ and WRITE (the result reveals the value)
            try Counters.add(try table.get(handle, type: .counter, rights: .read | .write).object,
                             Int64(bitPattern: a[1]))
        case 162:  // counter_read(counter or timeline, value out)
            guard a[1] != 0 else { throw .invalidArgs }
            try check(a[1], MemoryLayout<Int64>.size)
            try put(Counters.read(try Counters.waitable(table, handle, rights: .read).object), a[1])
        case 163:  // counter_write(counter, value)
            Counters.write(try table.get(handle, type: .counter, rights: .write).object, Int64(bitPattern: a[1]))
        case 164:  // counter_wait(counter, value, deadline)
            try Counters.wait(table, handle, target: Int64(bitPattern: a[1]), deadline: a[2])
        case 165:  // counter_wait_async(counter, port, key, value)
            try Counters.waitAsync(table, handle, port: UInt32(truncatingIfNeeded: a[1]), key: a[2],
                                   target: Int64(bitPattern: a[3]))
        case 170:  // timeline_create(display resource, options, period_ns, out)
            try check(a[3], MemoryLayout<UInt32>.size)
            try Resources.check(table, handle, system: UInt64(CROI_RSRC_SYSTEM_DISPLAY_BASE))
            try addAndPut(try Timelines.create(options: UInt32(truncatingIfNeeded: a[1]), period: a[2]),
                          rights: TimelineObject.defaultRights, a[3], table)
        case 171:  // timeline_advance(timeline, timestamp)
            try Timelines.advance(try table.get(handle, type: .timeline, rights: .write).object, timestamp: a[1])
        case 172:  // timeline_set_period(timeline, period_ns)
            try Timelines.setPeriod(try table.get(handle, type: .timeline, rights: .write).object, a[1])
        case 173:  // timeline_get_page(timeline, vmo out)
            try check(a[1], MemoryLayout<UInt32>.size)
            let timeline = try table.get(handle, type: .timeline, rights: .read)
            try addAndPut(try Timelines.pageVmo(timeline.object), rights: Timelines.pageRights, a[1], table)
        default:
            throw .notSupported
        }
    }
}
