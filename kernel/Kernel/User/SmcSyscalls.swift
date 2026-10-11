import CKernel

/// smc_call (K13i; syscall 234; Zircon's zx_smc_call, resource.h): an
/// SMCCC call to firmware through the FADT's PSCI conduit (SMC, or HVC
/// where firmware runs at EL2: Zircon always uses SMC). The SMC resource
/// must cover the function ID (croi's scoping; Zircon's covers the 6-bit
/// service call number). Yielding calls (bit 31 clear) with
/// `croi.smccc_qcom=on` follow Qualcomm's resume protocol, one at a time
/// (Zircon's arm64_smccc_qcom): while x0 says INTERRUPTED (1), call again
/// with function ID 1 and x6 the session id it returned.
extension Syscalls {
    static let smcLock = Mutex()

    static func smcCall(_ a: InlineArray<6, UInt64>, _ table: borrowing HandleTable) throws(Status) {
        guard a[1] != 0, a[2] != 0 else { throw .invalidArgs }
        var params = croi_smc_parameters_t()
        let copied = withUnsafeMutableBytes(of: &params) { unsafe UserCopy.from($0.baseAddress!, a[1], UInt64($0.count)) }
        guard copied == 0 else { throw .invalidArgs }
        try Resources.validate(table, UInt32(truncatingIfNeeded: a[0]), kind: UInt32(CROI_RSRC_KIND_SMC),
                               base: UInt64(params.func_id), size: 1)
        #if arch(arm64)
        let hvc: UInt64 = Power.psci.useHvc ? 1 : 0
        var result = croi_smc_result_t()
        let fast = params.func_id & (1 << 31) != 0
        if !fast, BootOptions.has("croi.smccc_qcom=on") {
            smcLock.lock()
            unsafe arch_smccc_call(&params, &result, hvc)
            while result.arg0 == 1 {  // INTERRUPTED: resume the session
                var resume = params
                resume.func_id = 1
                resume.arg6 = result.arg6
                unsafe arch_smccc_call(&resume, &result, hvc)
            }
            smcLock.unlock()
        } else {
            unsafe arch_smccc_call(&params, &result, hvc)
        }
        try check(a[2], MemoryLayout<croi_smc_result_t>.size)
        try put(result, a[2])
        #else
        throw .notSupported
        #endif
    }
}
