import CKernel
import Synchronization

/// Tick sampling (roadmap "Trace", K6): while CROI_TRACE_SAMPLE is on,
/// every CPU running a thread takes a sample each period, written as a
/// SAMPLE record and frame-pointer FRAMES records (trace.h). A CPU arms its
/// sampling timer only while it runs something: the tick that finds it idle
/// lapses, and the next switch to a thread re-arms it, so idle CPUs stay
/// tickless.
///
/// Stacks are walked through frame pointers (kernel and user code keep
/// them): kernel frames only within the interrupted stack, user frames by
/// the fault-safe copy, which in interrupt context never pages memory in.
enum Sampler {
    static var maxHz: UInt64 { 10_000 }
    static let armFailures = Atomic<UInt64>(0)
    static let lapses = Atomic<UInt64>(0)
    private static let period = Atomic<UInt64>(0)
    /// Bumped by every start and stop: older timers lapse when they fire.
    private static let generation = Atomic<UInt64>(0)

    static func start(hz: UInt64) {
        period.store(1_000_000_000 / min(max(hz, 1), maxHz), ordering: .relaxed)
        generation.add(1, ordering: .releasing)
        armHere(0)
        Ipi.callOthers(armHere, 0)
    }

    static func stop() {
        period.store(0, ordering: .relaxed)
        generation.add(1, ordering: .releasing)
    }

    /// The scheduler switched this CPU to `next` (its lock held).
    @inline(__always)
    static func switched(to next: ThreadPointer) {
        if croi_trace_categories() & CROI_TRACE_SAMPLE != 0, !next.pointee.isIdle { arm() }
    }

    private static let armHere: Ipi.Function = { _ in
        if !Scheduler.current.pointee.isIdle { arm() }
    }

    /// Arms this CPU's sampling timer unless it has one for this generation.
    private static func arm() {
        let percpu = unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!
        let current = generation.load(ordering: .acquiring)
        let interval = period.load(ordering: .relaxed)
        guard interval != 0, unsafe percpu.pointee.samplerArmed != current else { return }
        if let id = Timers.arm(deadline: Clock.now() + interval, slack: interval / 8, tick, current) {
            unsafe percpu.pointee.samplerArmed = current
            unsafe percpu.pointee.samplerTimer = id
        } else {
            armFailures.add(1, ordering: .relaxed)
        }
    }

    private static let tick: Timers.Callback = { armedGeneration, _ in
        let percpu = unsafe UnsafeMutablePointer<PerCpu>(bitPattern: UInt(arch_percpu()))!
        guard unsafe percpu.pointee.samplerArmed == armedGeneration else { return }
        unsafe percpu.pointee.samplerArmed = 0
        guard armedGeneration == generation.load(ordering: .acquiring),
              croi_trace_categories() & CROI_TRACE_SAMPLE != 0 else { return }
        let thread = Scheduler.current
        guard !thread.pointee.isIdle, unsafe percpu.pointee.interruptFrame != 0 else {  // lapses
            lapses.add(1, ordering: .relaxed)
            return
        }
        unsafe sample(UnsafePointer(bitPattern: UInt(percpu.pointee.interruptFrame))!, thread, source: 0)
        arm()
    }

    /// Writes one sample of the interrupted context `frame` (this CPU, in
    /// interrupt context).
    static func sample(_ frame: UnsafePointer<arch_exception_frame_t>, _ thread: ThreadPointer, source: UInt64) {
        let f = unsafe frame.pointee
        var frames = InlineArray<16, UInt64>(repeating: 0)
        var count = 0
        let pc: UInt64
        if ExceptionFrame.fromUser(f) {
            pc = ExceptionFrame.programCounter(f)
            walkUser(ExceptionFrame.framePointer(f), &frames, &count)
        } else {
            pc = encodeKernel(ExceptionFrame.programCounter(f))
            walkKernel(ExceptionFrame.framePointer(f), stack: ExceptionFrame.stackPointer(f), &frames, &count)
            // A user thread in a syscall: its user context is the frame at
            // the top of its kernel stack.
            if thread.pointee.aspace != nil, count < frames.count {
                let top = thread.pointee.stack.top
                let user = unsafe UnsafePointer<arch_exception_frame_t>(
                    bitPattern: UInt(top) - UInt(MemoryLayout<arch_exception_frame_t>.stride))!
                if unsafe ExceptionFrame.fromUser(user.pointee) {
                    frames[count] = unsafe ExceptionFrame.programCounter(user.pointee)
                    count += 1
                    unsafe walkUser(ExceptionFrame.framePointer(user.pointee), &frames, &count)
                }
            }
        }
        Trace.write(CROI_TRACE_SAMPLE, UInt16(CROI_TK_SAMPLE), pc, UInt64(count) << 8 | source)
        var i = 0
        while i < count {
            Trace.write(CROI_TRACE_SAMPLE, UInt16(CROI_TK_FRAMES), frames[i], i + 1 < count ? frames[i + 1] : 0)
            i += 2
        }
    }

    private static func encodeKernel(_ address: UInt64) -> UInt64 {
        (address &- kernel_image_start()) | CROI_SAMPLE_KERNEL
    }

    /// Frame records: amd64 and arm64 keep (caller's frame, return address)
    /// at the frame pointer; rv64 just below it.
    private static var recordOffset: Int64 {
        #if arch(riscv64)
        -16
        #else
        0
        #endif
    }

    /// Kernel frames: only within the 16 KiB stack `stack` points into (by
    /// the stack geometry, stack.h), each frame above the last.
    private static func walkKernel(_ start: UInt64, stack: UInt64, _ frames: inout InlineArray<16, UInt64>,
                                   _ count: inout Int) {
        let size = UInt64(CROI_KERNEL_STACK_SIZE)
        let base = stack & ~(2 * size - 1)
        var fp = start
        while count < frames.count, fp & 7 == 0 {
            let record = UInt64(bitPattern: Int64(bitPattern: fp) + recordOffset)
            guard record >= base, record + 16 <= base + size, fp >= stack else { break }
            let words = unsafe UnsafePointer<UInt64>(bitPattern: UInt(record))!
            let (previous, ret) = unsafe (words[0], words[1])
            guard ret != 0 else { break }
            frames[count] = encodeKernel(ret)
            count += 1
            guard previous > fp else { break }
            fp = previous
        }
    }

    /// User frames, through the fault-safe copy.
    private static func walkUser(_ start: UInt64, _ frames: inout InlineArray<16, UInt64>, _ count: inout Int) {
        var fp = start
        while count < frames.count, fp != 0, fp & 7 == 0 {
            var words: (UInt64, UInt64) = (0, 0)
            let record = UInt64(bitPattern: Int64(bitPattern: fp) + recordOffset)
            let copied = withUnsafeMutableBytes(of: &words) { unsafe UserCopy.from($0.baseAddress!, record, 16) }
            guard copied == 0, words.1 != 0 else { break }
            frames[count] = words.1
            count += 1
            guard words.0 > fp else { break }
            fp = words.0
        }
    }
}
