import CKernel
import Fmt
import PageTables

/// DMA objects (K9e; Zircon's IommuDispatcher, BusTransactionInitiator-
/// Dispatcher and PinnedMemoryTokenDispatcher over its stub IOMMU, values
/// and semantics in include/dma.h).
///
/// An IOMMU object (type 23) is the stub (no translation: device
/// addresses are physical), a VT-d unit (K12a, Iommu/IntelIommu.swift) or
/// an AMD-Vi one (K12b, Iommu/AmdIommu.swift).
/// A BTI (24) carries croi's DMA properties (address width, window, memory
/// type) and counts its live PMTs; it owns the quarantine list. On VT-d it
/// holds its IOMMU and a domain: the device's own I/O address space, which
/// maps only what it pins. A PMT (26) holds a reference to its VMO and,
/// while live, one to its BTI; once quarantined the BTI holds a reference
/// to it instead. All PMT state changes happen under the BTI's lock.
struct IommuObject: ~Copyable {
    var header = ObjectHeader(type: .iommu)
    /// The unit (VtdUnit or AmdviUnit record), 0 for the stub.
    var unit: UInt64 = 0
    var kind: UInt8 = 0  // IommuKind's raw value

    /// ZX_DEFAULT_IOMMU_RIGHTS.
    static var defaultRights: Rights { Rights.basic.subtracting(.wait) }
}

struct BtiObject: ~Copyable {
    var header = ObjectHeader(type: .bti)
    var name = ObjectName(repeating: 0)
    let btiId: UInt64
    /// Behind an IOMMU: its object (a reference) and the device's domain
    /// (an IoDomain).
    var iommu: UInt64 = 0
    var domain: UInt64 = 0
    var properties = croi_bti_properties_t(address_bits: 64, memory_type: UInt32(CROI_BTI_MEMORY_COHERENT),
                                           window_base: 0, window_size: 0)
    var livePins: UInt64 = 0
    /// Quarantined PMTs (PmtObject.next links them), each holding a
    /// reference the list owns.
    var quarantine: UInt64 = 0
    var quarantined: UInt64 = 0

    /// ZX_DEFAULT_BTI_RIGHTS.
    static var defaultRights: Rights {
        Rights.basic.subtracting(.wait).union(.read | .write | .getProperty | .setProperty | .map)
    }
}

struct PmtObject: ~Copyable {
    enum State { case live, unpinned, quarantined }

    var header = ObjectHeader(type: .pmt)
    let bti: ObjectPointer
    let vmo: VmoPointer
    let offset: UInt64
    let size: UInt64
    /// Behind an IOMMU: the I/O virtual address of the range's first byte (0: stub).
    var iova: UInt64 = 0
    var state = State.live
    var next: UInt64 = 0

    /// ZX_DEFAULT_PMT_RIGHTS: it can't be duplicated or sent.
    static var defaultRights: Rights { .inspect }
}

@safe struct BtiPointer {
    let object: ObjectPointer

    var pointee: BtiObject {
        unsafeAddress { unsafe UnsafePointer<BtiObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<BtiObject>(bitPattern: UInt(object.address))! }
    }
}

@safe struct PmtPointer {
    let object: ObjectPointer

    var pointee: PmtObject {
        unsafeAddress { unsafe UnsafePointer<PmtObject>(bitPattern: UInt(object.address))! }
        nonmutating unsafeMutableAddress { unsafe UnsafeMutablePointer<PmtObject>(bitPattern: UInt(object.address))! }
    }
}

enum Dma {
    // MARK: IOMMUs and BTIs

    /// iommu_create (the caller checked the IOMMU resource and copied the
    /// descriptor in).
    static func createIommu(type: UInt32, descriptor: RawSpan) throws(Status) -> ObjectPointer {
        var unit: UInt64 = 0
        var kind: UInt8 = 0
        switch type {
        case UInt32(CROI_IOMMU_TYPE_STUB):
            guard descriptor.byteCount == 1 else { throw .invalidArgs }  // zx_iommu_desc_stub_t
        case UInt32(CROI_IOMMU_TYPE_INTEL):
            #if arch(x86_64)
            unit = try Vtd.create(descriptor)
            kind = IommuKind.vtd.rawValue
            #else
            throw .notSupported
            #endif
        case UInt32(CROI_IOMMU_TYPE_AMD):
            #if arch(x86_64)
            unit = try Amdvi.create(descriptor)
            kind = IommuKind.amd.rawValue
            #else
            throw .notSupported
            #endif
        case UInt32(CROI_IOMMU_TYPE_RISCV):
            #if arch(riscv64)
            unit = try RiscvIommus.create(descriptor)
            kind = IommuKind.riscv.rawValue
            #else
            throw .notSupported
            #endif
        case UInt32(CROI_IOMMU_TYPE_ARM_SMMU):
            #if arch(arm64)
            if descriptor.byteCount == 8, Iort.smmuV2(unsafe descriptor.unsafeLoadUnaligned(as: UInt64.self)) != nil {
                unit = try SmmuV2.create(descriptor)
                kind = IommuKind.smmuV2.rawValue
            } else {
                unit = try SmmuV3.create(descriptor)
                kind = IommuKind.smmu.rawValue
            }
            #else
            throw .notSupported
            #endif
        default:
            throw .invalidArgs
        }
        guard let object = Objects.allocate(IommuObject(unit: unit, kind: kind)) else {
            #if arch(x86_64) || arch(arm64) || arch(riscv64)
            if unit != 0 { Iommus.unbind(IommuKind(rawValue: kind)!, unit: unit) }
            #endif
            throw .noMemory
        }
        return object
    }

    static func destroyIommu(_ object: ObjectPointer) {
        #if arch(x86_64) || arch(arm64) || arch(riscv64)
        let iommu = unsafe UnsafePointer<IommuObject>(bitPattern: UInt(object.address))!
        if unsafe iommu.pointee.unit != 0 {
            unsafe Iommus.unbind(IommuKind(rawValue: iommu.pointee.kind)!, unit: iommu.pointee.unit)
        }
        #endif
        Objects.free(object, as: IommuObject.self)
    }

    /// bti_create: behind an IOMMU, claims device `id` (bus/device/function)
    /// with a domain of its own; on the stub, a BTI with no translation,
    /// which the debuglog records as a trust decision.
    static func createBti(_ iommu: ObjectPointer, id: UInt64) throws(Status) -> ObjectPointer {
        let record = unsafe UnsafePointer<IommuObject>(bitPattern: UInt(iommu.address))!
        let unit = unsafe record.pointee.unit
        #if arch(x86_64) || arch(arm64) || arch(riscv64)
        if unit != 0 {
            let kind = unsafe IommuKind(rawValue: record.pointee.kind)!
            let domain = try Iommus.attach(kind, unit: unit, id: id)
            var bti = BtiObject(btiId: id)
            bti.iommu = iommu.address
            bti.domain = domain.address
            bti.properties.address_bits = UInt32(domain.pointee.inputBits)
            guard let object = Objects.allocate(bti) else {
                Iommus.detach(domain)
                throw .noMemory
            }
            iommu.retain()
            return object
        }
        #endif
        guard let object = Objects.allocate(BtiObject(btiId: id)) else { throw .noMemory }
        let (pid, _) = DebugLogs.writerKoids()
        KernelLog.write(UInt8(CROI_LOG_WARNING)) { out in
            out.write("bti: no-IOMMU BTI ")
            out.write(hex: id)
            out.write(" for process ")
            out.write(decimal: pid)
            out.write(": its DMA reaches physical memory")
        }
        return object
    }

    static func destroyBti(_ object: ObjectPointer) {
        let bti = BtiPointer(object: object)
        #if arch(x86_64) || arch(arm64) || arch(riscv64)
        if bti.pointee.domain != 0 {
            // The device is blocked first, so quarantined pages are safe
            // to give back: nothing can reach them any more.
            Iommus.detach(IoDomainPointer(address: bti.pointee.domain))
            var list = bti.pointee.quarantine
            while list != 0 {
                let pmt = ObjectPointer(address: list)
                let p = PmtPointer(object: pmt)
                list = p.pointee.next
                p.pointee.state = .unpinned
                release(p, domain: 0)
                pmt.release()
            }
            ObjectPointer(address: bti.pointee.iommu).release()
            Objects.free(object, as: BtiObject.self)
            return
        }
        #endif
        if bti.pointee.quarantined > 0 {
            // Nobody can release them now; the device may still be writing.
            // Leave them pinned for good (Zircon's orphaned BTI).
            KernelLog.write(UInt8(CROI_LOG_WARNING)) { out in
                out.write("bti: BTI ")
                out.write(hex: bti.pointee.btiId)
                out.write(" went with ")
                out.write(decimal: bti.pointee.quarantined)
                out.write(" quarantined PMTs: their pages stay pinned")
            }
        }
        Objects.free(object, as: BtiObject.self)
    }

    static func info(_ object: ObjectPointer) -> croi_info_bti_t {
        let bti = BtiPointer(object: object)
        return object.header.lock.withLock {
            croi_info_bti_t(minimum_contiguity: KernelLayout.pageSize,
                            aspace_size: bti.pointee.domain == 0 ? .max : 1 << UInt64(bti.pointee.properties.address_bits),
                            pmo_count: bti.pointee.livePins, quarantine_count: bti.pointee.quarantined)
        }
    }

    static func properties(_ object: ObjectPointer) -> croi_bti_properties_t {
        object.header.lock.withLock { BtiPointer(object: object).pointee.properties }
    }

    /// bti_set_properties: only narrows; the memory type changes only
    /// while nothing is pinned or quarantined.
    static func setProperties(_ object: ObjectPointer, _ wanted: croi_bti_properties_t) throws(Status) {
        let bti = BtiPointer(object: object)
        guard wanted.address_bits >= 12, wanted.address_bits <= 64,
              wanted.memory_type <= UInt32(CROI_BTI_MEMORY_NONCOHERENT),
              !wanted.window_base.addingReportingOverflow(wanted.window_size).overflow else { throw .invalidArgs }
        try object.header.lock.withLock { () throws(Status) in
            let current = bti.pointee.properties
            let (base, end) = window(current)
            let (newBase, newEnd) = window(wanted)
            guard wanted.address_bits <= current.address_bits, newBase >= base, newEnd <= end else {
                throw .accessDenied  // a widening
            }
            if wanted.memory_type != current.memory_type {
                guard bti.pointee.livePins == 0, bti.pointee.quarantined == 0 else { throw .badState }
            }
            bti.pointee.properties = wanted
        }
    }

    /// The device addresses [base, end) the properties allow.
    private static func window(_ p: croi_bti_properties_t) -> (UInt64, UInt64) {
        let reach: UInt64 = p.address_bits >= 64 ? .max : (1 << UInt64(p.address_bits))
        guard p.window_size != 0 else { return (0, reach) }
        return (p.window_base, min(p.window_base + p.window_size, reach))
    }

    // MARK: Contiguous VMOs

    /// vmo_create_contiguous(bti, ...): inside the BTI's window and width,
    /// with its memory type.
    static func createContiguous(_ object: ObjectPointer, size: UInt64, alignLog2: Int,
                                 account: MemoryAccountPointer? = nil) throws(Status) -> Vmo {
        let p = properties(object)
        // Behind an IOMMU the window constrains I/O addresses, not where
        // the pages are.
        let (base, end) = BtiPointer(object: object).pointee.domain == 0 ? window(p) : (0, .max)
        let cache: CachePolicy = p.memory_type == UInt32(CROI_BTI_MEMORY_NONCOHERENT) ? .uncached : .cached
        do throws(VmError) {
            return try Vmo(contiguous: size, alignLog2: alignLog2, cache: cache, floor: base, limit: end, account: account)
        } catch {
            throw error == .outOfMemory ? .noMemory : .invalidArgs
        }
    }

    // MARK: Pinning

    /// bti_pin: pins the range and makes a live PMT. The caller writes the
    /// addresses (`address(of:)`) and unpins if that fails.
    static func pin(_ object: ObjectPointer, vmo: VmoPointer, offset: UInt64, size: UInt64,
                    writable: Bool) throws(Status) -> ObjectPointer {
        let bti = BtiPointer(object: object)
        guard size > 0 else { throw .invalidArgs }
        // Before paging in (review fix: ensureRange's loop trapped on a
        // range wrapping past 2^64).
        guard !offset.addingReportingOverflow(size).overflow, offset + size <= vmo.pointee.size else {
            throw .outOfRange
        }
        try Pagers.ensureRange(vmo, offset, size)
        do throws(VmError) {
            try Vmo.withBorrowed(vmo) { (v: borrowing Vmo) throws(VmError) in try v.pin(offset: offset, size: size) }
        } catch {
            throw error.status
        }
        func unpinVmo() {
            try? Vmo.withBorrowed(vmo) { (v: borrowing Vmo) throws(VmError) in v.unpin(offset: offset, size: size) }
        }
        let (base, end) = window(properties(object))
        var iova: UInt64 = 0
        #if arch(x86_64) || arch(arm64) || arch(riscv64)
        if bti.pointee.domain != 0 {
            // I/O addresses from the window, each page mapped for the device.
            let domain = IoDomainPointer(address: bti.pointee.domain)
            do throws(Status) {
                iova = try IoDomains.reserve(domain, size: size, low: base, high: end)
            } catch {
                unpinVmo()
                throw error == .noMemory ? .outOfRange : error
            }
            var at: UInt64 = 0
            while at < size {
                do throws(Status) {
                    guard let phys = vmo.lookup(at: offset + at) else { throw .badState }
                    try IoDomains.map(domain, iova: iova + at, phys: phys, write: writable,
                                      cached: properties(object).memory_type != UInt32(CROI_BTI_MEMORY_NONCOHERENT))
                } catch {
                    IoDomains.unmap(domain, iova: iova, size: at)
                    IoDomains.release(domain, iova: iova)
                    unpinVmo()
                    throw error
                }
                at += KernelLayout.pageSize
            }
        }
        #endif
        // Without an IOMMU: every page inside the BTI's reach (device
        // address = physical).
        var at = offset
        while iova == 0, at < offset + size {
            guard let phys = vmo.lookup(at: at), phys >= base, phys + KernelLayout.pageSize <= end else {
                unpinVmo()
                throw .outOfRange
            }
            at += KernelLayout.pageSize
        }
        vmo.retain()
        object.retain()
        var record = PmtObject(bti: object, vmo: vmo, offset: offset, size: size)
        record.iova = iova
        guard let pmt = Objects.allocate(record) else {
            object.release()
            vmo.release()
            #if arch(x86_64) || arch(arm64) || arch(riscv64)
            if iova != 0 {
                let domain = IoDomainPointer(address: bti.pointee.domain)
                IoDomains.unmap(domain, iova: iova, size: size)
                IoDomains.release(domain, iova: iova)
            }
            #endif
            unpinVmo()
            throw .noMemory
        }
        object.header.lock.withLock { bti.pointee.livePins += 1 }
        return pmt
    }

    /// The device address of byte `offset` of a live PMT's range.
    static func address(_ pmt: ObjectPointer, at offset: UInt64) -> UInt64 {
        let p = PmtPointer(object: pmt)
        if p.pointee.iova != 0 { return p.pointee.iova + offset }
        return p.pointee.vmo.lookup(at: p.pointee.offset + offset) ?? 0
    }

    /// pmt_unpin (and failure paths of bti_pin): the pages go back to the
    /// VMO's control; the PMT drops its BTI. Its handle is closed after.
    static func unpin(_ pmt: ObjectPointer) throws(Status) {
        let p = PmtPointer(object: pmt)
        let bti = p.pointee.bti
        try bti.header.lock.withLock { () throws(Status) in
            guard p.pointee.state == .live else { throw .badState }
            p.pointee.state = .unpinned
            BtiPointer(object: bti).pointee.livePins -= 1
        }
        release(p, domain: BtiPointer(object: bti).pointee.domain)
        bti.release()
    }

    /// A PMT's handle was closed: if it is still pinned, the BTI takes it
    /// into quarantine (the device may still be using the pages).
    static func handleClosed(_ pmt: ObjectPointer) {
        let p = PmtPointer(object: pmt)
        let bti = p.pointee.bti
        let quarantined = bti.header.lock.withLock { () -> Bool in
            guard p.pointee.state == .live else { return false }
            let b = BtiPointer(object: bti)
            p.pointee.state = .quarantined
            p.pointee.next = b.pointee.quarantine
            b.pointee.quarantine = pmt.address
            b.pointee.quarantined += 1
            b.pointee.livePins -= 1
            pmt.retain()  // the list's
            return true
        }
        if quarantined { bti.release() }  // the PMT's own: the BTI now holds it
    }

    /// bti_release_quarantine: unpins and frees every quarantined PMT.
    static func releaseQuarantine(_ object: ObjectPointer) {
        let bti = BtiPointer(object: object)
        var list = object.header.lock.withLock { () -> UInt64 in
            let head = bti.pointee.quarantine
            bti.pointee.quarantine = 0
            bti.pointee.quarantined = 0
            return head
        }
        while list != 0 {
            let pmt = ObjectPointer(address: list)
            let p = PmtPointer(object: pmt)
            list = p.pointee.next
            p.pointee.state = .unpinned
            release(p, domain: bti.pointee.domain)
            pmt.release()  // the list's
        }
    }

    /// Unpins the VMO range and drops the PMT's reference to the VMO. On
    /// an IOMMU the device loses the pages first (unmapped, IOTLB invalidated);
    /// `domain` 0 when there is none or it is gone (the device blocked).
    private static func release(_ p: PmtPointer, domain: UInt64) {
        #if arch(x86_64) || arch(arm64) || arch(riscv64)
        if domain != 0, p.pointee.iova != 0 {
            IoDomains.unmap(IoDomainPointer(address: domain), iova: p.pointee.iova, size: p.pointee.size)
            IoDomains.release(IoDomainPointer(address: domain), iova: p.pointee.iova)
        }
        #endif
        let vmo = p.pointee.vmo
        let (offset, size) = (p.pointee.offset, p.pointee.size)
        try? Vmo.withBorrowed(vmo) { (v: borrowing Vmo) throws(VmError) in v.unpin(offset: offset, size: size) }
        vmo.release()
    }

    static func destroyPmt(_ object: ObjectPointer) {
        // Live PMTs are quarantined when their handle closes, so only
        // unpinned ones get here.
        guard PmtPointer(object: object).pointee.state == .unpinned else { panic("pmt: destroyed while pinned") }
        Objects.free(object, as: PmtObject.self)
    }
}
