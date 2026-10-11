import CHandoff
import CKernel
import Fmt

/// The kernel's CPRNG (K11b; Zircon's cprng_draw / cprng_add_entropy):
/// ChaCha20 keystream from a 256-bit key, with fast key erasure: every
/// draw ends by replacing the key with fresh keystream, so a later
/// compromise of the state can't reveal what was drawn before. Seeded
/// at boot from the firmware's EFI_RNG_PROTOCOL (the handoff), the CPU's
/// RNG instruction (amd64 RDSEED/RDRAND, arm64 RNDR) and counter jitter,
/// each folded into the key through a ChaCha block; user space can add
/// more (`addEntropy`). rv64's Zkr seed CSR isn't used: S-mode reads trap
/// unless M-mode opened it, which S-mode can't check.
///
/// Draws are at most 256 bytes (Zircon's ZX_CPRNG_DRAW_MAX_LEN).
enum Random {
    static var maxDraw: Int { 256 }

    nonisolated(unsafe) private static var key = InlineArray<8, UInt32>(repeating: 0)
    nonisolated(unsafe) private static var counter: UInt64 = 0
    private static let lock = SpinLock()
    /// What seeded it, for the boot line.
    nonisolated(unsafe) private(set) static var sources: UInt32 = 0
    static var fromFirmware: UInt32 { 1 }
    static var fromInstruction: UInt32 { 2 }

    /// Seeds from the handoff (whose copy is then cleared), the CPU and
    /// counter jitter, and says which on `console`.
    static func seed(_ handoff: inout croi_handoff_t, _ console: Uart) {
        var words = InlineArray<8, UInt32>(repeating: 0)
        if handoff.entropy_size >= 32 {
            let e = handoff.entropy
            var four = InlineArray<4, UInt64>(repeating: 0)
            four[0] = e.0; four[1] = e.1; four[2] = e.2; four[3] = e.3
            for i in 0..<4 {
                words[2 * i] = UInt32(truncatingIfNeeded: four[i])
                words[2 * i + 1] = UInt32(truncatingIfNeeded: four[i] >> 32)
            }
            handoff.entropy = (0, 0, 0, 0)
            mix(words)
            sources |= fromFirmware
        }
        var got = 0
        for i in 0..<8 {
            var value: UInt64 = 0
            guard unsafe arch_hw_random(&value) != 0 else { break }
            words[i] = UInt32(truncatingIfNeeded: value) ^ UInt32(truncatingIfNeeded: value >> 32)
            got += 1
        }
        if got == 8 {
            mix(words)
            sources |= fromInstruction
        }
        // Counter jitter: weak alone, never harmful mixed in.
        for round in 0..<4 {
            for i in 0..<8 {
                var spin: UInt64 = 0
                for _ in 0..<(97 &* (i + round + 1)) { spin &+= arch_counter_read() }
                words[i] = UInt32(truncatingIfNeeded: arch_counter_read() ^ spin)
            }
            mix(words)
        }
        console.write("  random: ChaCha20, seeded from ")
        if sources & fromFirmware != 0 { console.write("EFI_RNG_PROTOCOL, ") }
        if sources & fromInstruction != 0 {
            #if arch(x86_64)
            console.write("RDSEED/RDRAND, ")
            #else
            console.write("RNDR, ")
            #endif
        }
        console.write(sources == 0 ? "counter jitter only (WARNING: weak; give QEMU a virtio-rng device)\n"
                                   : "counter jitter\n")
    }

    /// The syscalls (Zircon's): at most `maxDraw` bytes either way, else
    /// INVALID_ARGS; a bad user buffer is INVALID_ARGS too.
    static func call(_ number: UInt64, _ a: InlineArray<6, UInt64>) -> Int64 {
        guard a[1] <= UInt64(maxDraw) else { return Int64(Status.invalidArgs.rawValue) }
        let count = Int(a[1])
        var buffer = InlineArray<256, UInt8>(repeating: 0)
        var span = buffer.mutableSpan
        if number == 181 {
            draw(&buffer, count: count)
            span = buffer.mutableSpan
            let copied = span.withUnsafeMutableBytes { unsafe UserCopy.to(a[0], UnsafeRawPointer($0.baseAddress!), UInt64(count)) }
            for i in 0..<count { buffer[i] = 0 }
            return copied == 0 ? 0 : Int64(Status.invalidArgs.rawValue)
        }
        let copied = span.withUnsafeMutableBytes { unsafe UserCopy.from($0.baseAddress!, a[0], UInt64(count)) }
        guard copied == 0 else { return Int64(Status.invalidArgs.rawValue) }
        addEntropy(buffer.span.extracting(0..<count))
        for i in 0..<count { buffer[i] = 0 }
        return 0
    }

    /// Fills `buffer` (at most `maxDraw` bytes) with keystream, then
    /// replaces the key.
    static func draw(_ buffer: inout InlineArray<256, UInt8>, count: Int) {
        lock.withLock {
            var block = InlineArray<16, UInt32>(repeating: 0)
            var done = 0
            while done < count {
                chacha(&block)
                for i in 0..<min(64, count - done) {
                    buffer[done + i] = UInt8(truncatingIfNeeded: block[i / 4] >> (UInt32(i % 4) * 8))
                }
                done += 64
            }
            rekey(&block)
        }
    }

    /// One random word (kernel use: ASLR).
    static func word() -> UInt64 {
        var buffer = InlineArray<256, UInt8>(repeating: 0)
        draw(&buffer, count: 8)
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(buffer[i]) << UInt64(8 * i) }
        return value
    }

    /// cprng_add_entropy: up to 256 bytes folded into the key.
    static func addEntropy(_ bytes: Span<UInt8>) {
        var words = InlineArray<8, UInt32>(repeating: 0)
        var at = 0
        while at < bytes.count {
            for i in 0..<min(32, bytes.count - at) {
                words[i / 4] ^= UInt32(bytes[at + i]) << (UInt32(i % 4) * 8)
            }
            lock.withLock { mix(words) }
            at += 32
        }
    }

    /// Known answer (boot self-test): ChaCha20 with an all-zero key and
    /// nonce, block 0 (RFC 8439 appendix A.1, test vector 1). Runs before
    /// seeding, with the zero key it starts from.
    static func selfTest() -> Bool {
        let saved = (key, counter)
        for i in 0..<8 { key[i] = 0 }
        counter = 0
        var block = InlineArray<16, UInt32>(repeating: 0)
        chacha(&block)
        (key, counter) = saved
        // 76 b8 e0 ad a0 f1 3d 90 40 5d 6a e5 53 86 bd 28 ...
        return block[0] == 0xADE0_B876 && block[1] == 0x903D_F1A0 && block[2] == 0xE56A_5D40
            && block[3] == 0x28BD_8653
    }

    /// key ^= words, then a block of keystream becomes the key.
    private static func mix(_ words: InlineArray<8, UInt32>) {
        for i in 0..<8 { key[i] ^= words[i] }
        var block = InlineArray<16, UInt32>(repeating: 0)
        chacha(&block)
        rekey(&block)
    }

    /// The next block's first 32 bytes become the key; the block is wiped.
    private static func rekey(_ block: inout InlineArray<16, UInt32>) {
        chacha(&block)
        for i in 0..<8 { key[i] = block[i] }
        for i in 0..<16 { block[i] = 0 }
    }

    /// ChaCha20's block function (RFC 8439) for `key` and `counter`
    /// (64-bit, nonce zero), which it advances.
    private static func chacha(_ out: inout InlineArray<16, UInt32>) {
        var x = InlineArray<16, UInt32>(repeating: 0)
        x[0] = 0x6170_7865; x[1] = 0x3320_646E; x[2] = 0x7962_2D32; x[3] = 0x6B20_6574
        for i in 0..<8 { x[4 + i] = key[i] }
        x[12] = UInt32(truncatingIfNeeded: counter)
        x[13] = UInt32(truncatingIfNeeded: counter >> 32)
        counter &+= 1
        var s = x
        func quarter(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            s[a] &+= s[b]; s[d] ^= s[a]; s[d] = s[d] << 16 | s[d] >> 16
            s[c] &+= s[d]; s[b] ^= s[c]; s[b] = s[b] << 12 | s[b] >> 20
            s[a] &+= s[b]; s[d] ^= s[a]; s[d] = s[d] << 8 | s[d] >> 24
            s[c] &+= s[d]; s[b] ^= s[c]; s[b] = s[b] << 7 | s[b] >> 25
        }
        for _ in 0..<10 {
            quarter(0, 4, 8, 12); quarter(1, 5, 9, 13); quarter(2, 6, 10, 14); quarter(3, 7, 11, 15)
            quarter(0, 5, 10, 15); quarter(1, 6, 11, 12); quarter(2, 7, 8, 13); quarter(3, 4, 9, 14)
        }
        for i in 0..<16 { out[i] = s[i] &+ x[i] }
    }
}
