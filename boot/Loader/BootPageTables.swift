import PageTables

/// The boot page tables the kernel starts on: all RAM identity mapped, the
/// UART mapped as device memory, and the kernel image at its link address.
typealias BootPageTables = PageTableBuilder<FirmwarePages>

/// Table pages from firmware (CroiMemoryType.handoff), allocated in
/// batches, reached through UEFI's identity map.
struct FirmwarePages: PageTableMemory {
    private let boot: BootServices
    private var next: UInt64 = 0
    private var end: UInt64 = 0

    init(boot: BootServices) {
        self.boot = boot
    }

    mutating func allocateTable() -> UInt64? {
        if next == end {
            let batch: UInt64 = 32
            guard let pages = try? boot.allocatePages(batch, type: CroiMemoryType.handoff) else { return nil }
            next = pages
            end = pages + batch * pageSize
        }
        defer { next += pageSize }
        return next
    }

    func tableAddress(_ phys: UInt64) -> UInt { UInt(phys) }
}

extension MapAttributes {
    /// The temporary RAM identity map: RWX so the loader keeps running
    /// across the switch. The kernel replaces it.
    static var identityRam: MapAttributes { MapAttributes(writable: true, executable: true) }
    static var identityDevice: MapAttributes { MapAttributes(writable: true, device: true) }
}

extension LoaderError {
    init(_ error: MapError) {
        switch error {
        case .unaligned(let virt): self = .unsupported("unaligned boot mapping", virt)
        case .overlap(let virt): self = .unsupported("overlapping boot mapping", virt)
        case .outOfMemory: self = .unsupported("out of memory for boot page tables", 0)
        }
    }
}
