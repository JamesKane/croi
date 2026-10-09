import _Volatile
import CHandoff
import CKernel
import Fmt

/// Polled early-console UART, as described by the loader (from ACPI SPCR).
/// Assumes firmware already configured line settings. Writes `\n` as `\r\n`.
@safe struct Uart: TextOutput {
    private let config: croi_uart_t

    /// The UART's registers must be mapped (identity, device memory) for as
    /// long as this value is used.
    @unsafe init(_ config: croi_uart_t) {
        self.config = config
    }

    func write(utf8: Span<UInt8>) {
        for i in utf8.indices {
            if utf8[i] == UInt8(ascii: "\n") {
                put(UInt8(ascii: "\r"))
            }
            put(utf8[i])
        }
    }

    private func put(_ byte: UInt8) {
        switch config.kind {
        case CROI_UART_NS16550_PIO, CROI_UART_NS16550_MMIO:
            // Wait for LSR.THRE, then write THR.
            while ns16550Read(register: 5) & 0x20 == 0 {}
            ns16550Write(register: 0, byte)
        case CROI_UART_PL011:
            // Wait while FR.TXFF, then write DR.
            while unsafe mmio32(0x18).load() & 0x20 != 0 {}
            unsafe mmio32(0x00).store(UInt32(byte))
        default:
            break
        }
    }

    private func ns16550Read(register: UInt64) -> UInt8 {
        #if arch(x86_64)
        if config.kind == CROI_UART_NS16550_PIO {
            return arch_inb(UInt16(truncatingIfNeeded: config.base + register))
        }
        #endif
        let offset = register << config.reg_shift
        return config.access_width == 4
            ? UInt8(truncatingIfNeeded: unsafe mmio32(offset).load())
            : unsafe VolatileMappedRegister<UInt8>(unsafeBitPattern: UInt(config.base + offset)).load()
    }

    private func ns16550Write(register: UInt64, _ value: UInt8) {
        #if arch(x86_64)
        if config.kind == CROI_UART_NS16550_PIO {
            arch_outb(UInt16(truncatingIfNeeded: config.base + register), value)
            return
        }
        #endif
        let offset = register << config.reg_shift
        if config.access_width == 4 {
            unsafe mmio32(offset).store(UInt32(value))
        } else {
            unsafe VolatileMappedRegister<UInt8>(unsafeBitPattern: UInt(config.base + offset)).store(value)
        }
    }

    @unsafe private func mmio32(_ offset: UInt64) -> VolatileMappedRegister<UInt32> {
        unsafe VolatileMappedRegister<UInt32>(unsafeBitPattern: UInt(config.base + offset))
    }
}

extension croi_uart_t {
    /// The same UART, addressed through the physmap (MMIO kinds only).
    var inPhysmap: croi_uart_t {
        var uart = self
        if kind == CROI_UART_NS16550_MMIO || kind == CROI_UART_PL011 {
            uart.base = KernelLayout.physmap(base)
        }
        return uart
    }
}
