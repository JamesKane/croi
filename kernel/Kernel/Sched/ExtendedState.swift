import CKernel
import Fmt
import Synchronization

/// What one CPU offers in extended (FP/SIMD/vector) register state.
struct ExtendedStateFacts: Equatable {
    #if arch(x86_64)
    /// XSAVE present; the XCR0 feature bits it supports; XFD (lazy AMX).
    var xsave = false
    var features: UInt64 = 0
    var xfd = false
    /// XSAVEOPT: skips components in their initial state (or unchanged).
    var xsaveopt = false
    #elseif arch(arm64)
    var fp = false
    /// Vector lengths in bytes (0: no SVE / SME); SME2's ZT0.
    var sveLength: UInt64 = 0
    var smeLength: UInt64 = 0
    var zt0 = false
    #elseif arch(riscv64)
    var doubleFloat = false
    var singleFloat = false
    /// V extension register length in bytes (0: none).
    var vlenb: UInt64 = 0
    #endif

    /// What every CPU in `self` and `other` offers: user threads migrate,
    /// so their state must fit wherever they run.
    func common(_ other: ExtendedStateFacts) -> ExtendedStateFacts {
        var result = self
        #if arch(x86_64)
        result.xsave = xsave && other.xsave
        result.features = features & other.features
        result.xfd = xfd && other.xfd
        result.xsaveopt = xsaveopt && other.xsaveopt
        #elseif arch(arm64)
        result.fp = fp && other.fp
        result.sveLength = min(sveLength, other.sveLength)
        result.smeLength = min(smeLength, other.smeLength)
        result.zt0 = zt0 && other.zt0
        #elseif arch(riscv64)
        result.doubleFloat = doubleFloat && other.doubleFloat
        result.singleFloat = singleFloat && other.singleFloat
        result.vlenb = min(vlenb, other.vlenb)
        #endif
        return result
    }
}

/// Per-thread extended register state (roadmap K3d), sized at boot.
///
/// User threads (K6) get an area of `eagerSize` bytes, saved and restored
/// at every switch of a user thread, plus `lazySize` more allocated on
/// first use: AMX tile data behind XFD on amd64, SME's ZA and streaming
/// state on arm64. Kernel threads never use FP/SIMD and get none. The
/// save/restore code comes with user mode (K6), where it can be tested.
///
/// The layout must fit every CPU (a user thread can run on any it may use),
/// so features are what all CPUs share and vector lengths the smallest
/// any CPU offers; on arm64 each CPU's ZCR_EL1/SMCR_EL1 is then set to it.
enum ExtendedState {
    nonisolated(unsafe) private(set) static var facts = ExtendedStateFacts()
    nonisolated(unsafe) private(set) static var eagerSize = 0
    nonisolated(unsafe) private(set) static var lazySize = 0
    nonisolated(unsafe) private(set) static var uniform = true
    static var alignment: Int { 64 }  // XSAVE needs 64; the rest less
    static let liveAreas = Atomic<Int>(0)

    nonisolated(unsafe) private static var perCpu = InlineArray<64, ExtendedStateFacts>(repeating: ExtendedStateFacts())

    /// Measures every CPU (an IPI call to each), keeps what they share, and
    /// sizes the areas. After SMP bring-up.
    static func initialize(_ acpi: AcpiTables?) {
        #if arch(riscv64)
        if let acpi {
            riscv = ExtendedStateFacts(doubleFloat: RiscvIsa.everyHartHasBase(UInt8(ascii: "d"), acpi),
                                       singleFloat: RiscvIsa.everyHartHasBase(UInt8(ascii: "f"), acpi),
                                       vlenb: 0)
            hasVector = RiscvIsa.everyHartHasBase(UInt8(ascii: "v"), acpi)
        }
        #endif
        measureThisCpu(0)
        Ipi.callOthers(measureThisCpu, 0)
        var shared = perCpu[0]
        for cpu in 1..<Smp.count {
            if perCpu[cpu] != perCpu[0] { uniform = false }
            shared = shared.common(perCpu[cpu])
        }
        facts = shared
        (eagerSize, lazySize) = sizes(shared)
        #if arch(arm64)
        settle(0)
        Ipi.callOthers(settle, 0)
        #endif
        // K6d: user threads' state is saved and restored at switches.
        #if arch(x86_64)
        // XCR0: what all CPUs share, less PKRU (the scheduler switches it)
        // and AMX tiles (lazy XFD support isn't built yet).
        let excluded: UInt64 = 1 << 9 | 1 << 17 | 1 << 18
        croi_xstate_config = shared.xsave ? shared.features & ~excluded : 0
        // User code mostly leaves AVX/AVX-512 in their initial state: plain
        // XSAVE still wrote all ~2.5 KiB of it at every switch.
        croi_xstate_saveopt = shared.xsave && shared.xsaveopt ? 1 : 0
        #elseif arch(arm64)
        croi_xstate_config = shared.sveLength
        #elseif arch(riscv64)
        croi_xstate_config = shared.vlenb
        #endif
        arch_xstate_enable()
        Ipi.callOthers(enableHere, 0)
    }

    private static let enableHere: Ipi.Function = { _ in
        arch_xstate_enable()
    }

    #if arch(riscv64)
    nonisolated(unsafe) private static var riscv = ExtendedStateFacts()
    nonisolated(unsafe) private static var hasVector = false
    #endif

    private static let measureThisCpu: Ipi.Function = { _ in
        perCpu[Int(Cpu.current)] = measure()
    }

    /// This CPU's facts.
    static func measure() -> ExtendedStateFacts {
        var facts = ExtendedStateFacts()
        #if arch(x86_64)
        let leaf1 = cpuid(1, 0)
        facts.xsave = leaf1[2] & (1 << 26) != 0
        if facts.xsave {
            let leaf = cpuid(0xD, 0)
            facts.features = UInt64(leaf[3]) << 32 | UInt64(leaf[0])
            let sub1 = cpuid(0xD, 1)[0]
            facts.xfd = sub1 & (1 << 4) != 0
            facts.xsaveopt = sub1 & 1 != 0
        }
        #elseif arch(arm64)
        let pfr0 = arch_arm64_id_register(UInt32(CROI_ID_AA64PFR0))
        let pfr1 = arch_arm64_id_register(UInt32(CROI_ID_AA64PFR1))
        facts.fp = (pfr0 >> 16) & 0xF != 0xF
        if (pfr0 >> 32) & 0xF != 0 { facts.sveLength = arch_sve_vector_length(15) }
        if (pfr1 >> 24) & 0xF != 0 {
            facts.smeLength = arch_sme_vector_length(15)
            facts.zt0 = (arch_arm64_id_register(UInt32(CROI_ID_AA64SMFR0)) >> 56) & 0xF != 0
        }
        #elseif arch(riscv64)
        facts = riscv
        if hasVector { facts.vlenb = arch_rv_vlenb() }
        #endif
        return facts
    }

    #if arch(arm64)
    /// Sets this CPU's SVE/SME vector length to the shared one.
    private static let settle: Ipi.Function = { _ in
        if facts.sveLength > 0 { _ = arch_sve_vector_length(facts.sveLength / 16 - 1) }
        if facts.smeLength > 0 { _ = arch_sme_vector_length(facts.smeLength / 16 - 1) }
    }
    #endif

    /// Eager and lazy sizes (bytes) for these facts.
    static func sizes(_ facts: ExtendedStateFacts) -> (Int, Int) {
        #if arch(x86_64)
        guard facts.xsave else { return (512, 0) }  // FXSAVE
        let tileData: UInt64 = 1 << 18
        let eagerFeatures = facts.xfd ? facts.features & ~tileData : facts.features
        let eager = xsaveSize(eagerFeatures)
        return (eager, xsaveSize(facts.features) - eager)
        #elseif arch(arm64)
        guard facts.fp else { return (0, 0) }
        var eager = 32 * 16 + 16  // V0-V31, FPSR, FPCR
        if facts.sveLength > 0 {
            let vl = Int(facts.sveLength)
            eager = 32 * vl + 17 * (vl / 8) + 16  // Z0-Z31, P0-P15 + FFR, FPSR/FPCR
        }
        var lazy = 0
        if facts.smeLength > 0 {
            let svl = Int(facts.smeLength)
            lazy = svl * svl + 32 * svl + 17 * (svl / 8) + (facts.zt0 ? 64 : 0)  // ZA, streaming Z/P, ZT0
        }
        return (eager, lazy)
        #elseif arch(riscv64)
        var eager = facts.doubleFloat ? 32 * 8 + 8 : facts.singleFloat ? 32 * 4 + 8 : 0  // f0-f31, fcsr
        if facts.vlenb > 0 { eager += 32 * Int(facts.vlenb) + 32 }  // v0-v31, vstart/vl/vtype/vcsr
        return (eager, 0)
        #else
        return (0, 0)
        #endif
    }

    #if arch(x86_64)
    /// The standard-format XSAVE area for `features`: the end of the last
    /// component (CPUID 0xD sub-leaf i: size, offset), at least the legacy
    /// area and header.
    private static func xsaveSize(_ features: UInt64) -> Int {
        var size = 576
        for i in 2..<63 where features & (1 << UInt64(i)) != 0 {
            let leaf = cpuid(0xD, UInt32(i))
            size = max(size, Int(leaf[1]) + Int(leaf[0]))
        }
        return size
    }

    private static func cpuid(_ leaf: UInt32, _ subleaf: UInt32) -> InlineArray<4, UInt32> {
        var regs = InlineArray<4, UInt32>(repeating: 0)
        var span = regs.mutableSpan
        span.withUnsafeMutableBufferPointer { unsafe arch_cpuid(leaf, subleaf, $0.baseAddress!) }
        return regs
    }
    #endif

    // MARK: Areas

    /// A zeroed area of `eagerSize` bytes for a user thread, or 0 if there
    /// is no state to keep.
    static func allocate() -> UInt64 {
        guard eagerSize > 0 else { return 0 }
        guard let raw = unsafe heap.allocate(size: eagerSize, alignment: alignment) else {
            panic("xstate: out of memory for a thread's register state")
        }
        unsafe raw.initializeMemory(as: UInt8.self, repeating: 0, count: eagerSize)
        #if arch(x86_64)
        // The legacy area's control words at their reset values (XRSTOR
        // takes MXCSR from memory even for an initial SSE state).
        unsafe raw.storeBytes(of: UInt16(0x37F), toByteOffset: 0, as: UInt16.self)    // FCW
        unsafe raw.storeBytes(of: UInt32(0x1F80), toByteOffset: 24, as: UInt32.self)  // MXCSR
        #endif
        liveAreas.add(1, ordering: .relaxed)
        return UInt64(UInt(bitPattern: raw))
    }

    static func free(_ area: UInt64) {
        guard area != 0 else { return }
        unsafe heap.free(UnsafeMutableRawPointer(bitPattern: UInt(area))!)
        liveAreas.subtract(1, ordering: .relaxed)
    }

    /// One line for the boot log.
    static func describe(to out: some TextOutput) {
        #if arch(x86_64)
        if facts.xsave {
            out.write("XSAVE")
            let names: InlineArray<6, (UInt64, StaticString)> = [
                (1 << 2, " AVX"), (1 << 5, " AVX-512"), (1 << 9, " PKRU"), (1 << 11, " CET"),
                (1 << 17 | 1 << 18, facts.xfd ? " AMX (lazy, XFD)" : " AMX"), (1 << 19, " APX"),
            ]
            for i in 0..<names.count where facts.features & names[i].0 == names[i].0 { out.write(names[i].1) }
        } else {
            out.write("FXSAVE")
        }
        #elseif arch(arm64)
        out.write(facts.fp ? "FP/SIMD" : "no FP")
        if facts.sveLength > 0 {
            out.write(", SVE ")
            out.write(decimal: facts.sveLength * 8)
            out.write("-bit")
        }
        if facts.smeLength > 0 {
            out.write(", SME ")
            out.write(decimal: facts.smeLength * 8)
            out.write("-bit (lazy)")
            if facts.zt0 { out.write(" + ZT0") }
        }
        #elseif arch(riscv64)
        out.write(facts.doubleFloat ? "D" : facts.singleFloat ? "F" : "no FP")
        if facts.vlenb > 0 {
            out.write(", V ")
            out.write(decimal: facts.vlenb * 8)
            out.write("-bit")
        } else {
            out.write(", no V")
        }
        #endif
    }
}
