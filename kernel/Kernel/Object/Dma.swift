import CKernel
import Fmt
import PageTables

/// DMA objects (K9e; Zircon's IommuDispatcher, BusTransactionInitiator-
/// Dispatcher and PinnedMemoryTokenDispatcher over its stub IOMMU, values
/// and semantics in include/dma.h).
///
/// An IOMMU object (type 23) is only the stub so far: no translation, so
/// device addresses are physical. A BTI (24) carries croi's DMA properties
/// (address width, window, memory type) and counts its live PMTs; it owns
/// the quarantine list. A PMT (26) holds a reference to its VMO and, while
/// live, one to its BTI; once quarantined the BTI holds a reference to it
/// instead. All PMT state changes happen under the BTI's lock.
struct IommuObject: ~Copyable {
    var header = ObjectHeader(type: .iommu)

    /// ZX_DEFAULT_IOMMU_RIGHTS.
    static var defaultRights: Rights { Rights.basic.subtracting(.wait) }
}

struct BtiObject: ~Copyable {
    var header = ObjectHeader(type: .bti)
    let btiId: UInt64
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

    /// iommu_create (the caller checked the IOMMU resource).
    static func createIommu(type: UInt32, descriptorSize: UInt64) throws(Status) -> ObjectPointer {
        guard descriptorSize <= UInt64(CROI_IOMMU_MAX_DESC_LEN) else { throw .invalidArgs }
        switch type {
        case UInt32(CROI_IOMMU_TYPE_STUB):
            guard descriptorSize == 1 else { throw .invalidArgs }  // zx_iommu_desc_stub_t
        case UInt32(CROI_IOMMU_TYPE_INTEL), UInt32(CROI_IOMMU_TYPE_ARM_SMMU):
            throw .notSupported
        default:
            throw .invalidArgs
        }
        guard let object = Objects.allocate(IommuObject()) else { throw .noMemory }
        return object
    }

    /// bti_create on the stub IOMMU: a BTI with no translation, which the
    /// debuglog records as a trust decision.
    static func createBti(id: UInt64) throws(Status) -> ObjectPointer {
        guard let object = Objects.allocate(BtiObject(btiId: id)) else { throw .noMemory }
        let (pid, _) = DebugLogs.writerKoids()
        log(UInt8(CROI_LOG_WARNING)) { out in
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
        if bti.pointee.quarantined > 0 {
            // Nobody can release them now; the device may still be writing.
            // Leave them pinned for good (Zircon's orphaned BTI).
            log(UInt8(CROI_LOG_WARNING)) { out in
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
            croi_info_bti_t(minimum_contiguity: KernelLayout.pageSize, aspace_size: .max,
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
    static func createContiguous(_ object: ObjectPointer, size: UInt64, alignLog2: Int) throws(Status) -> Vmo {
        let p = properties(object)
        let (base, end) = window(p)
        let cache: CachePolicy = p.memory_type == UInt32(CROI_BTI_MEMORY_NONCOHERENT) ? .uncached : .cached
        do throws(VmError) {
            return try Vmo(contiguous: size, alignLog2: alignLog2, cache: cache, floor: base, limit: end)
        } catch {
            throw error == .outOfMemory ? .noMemory : .invalidArgs
        }
    }

    // MARK: Pinning

    /// bti_pin: pins the range and makes a live PMT. The caller writes the
    /// addresses (`address(of:)`) and unpins if that fails.
    static func pin(_ object: ObjectPointer, vmo: VmoPointer, offset: UInt64, size: UInt64) throws(Status) -> ObjectPointer {
        let bti = BtiPointer(object: object)
        guard size > 0 else { throw .invalidArgs }
        do throws(VmError) {
            try Vmo.withBorrowed(vmo) { (v: borrowing Vmo) throws(VmError) in try v.pin(offset: offset, size: size) }
        } catch {
            throw error.status
        }
        func unpinVmo() {
            try? Vmo.withBorrowed(vmo) { (v: borrowing Vmo) throws(VmError) in v.unpin(offset: offset, size: size) }
        }
        // Every page inside the BTI's reach (device address = physical).
        let (base, end) = window(properties(object))
        var at = offset
        while at < offset + size {
            guard let phys = vmo.lookup(at: at), phys >= base, phys + KernelLayout.pageSize <= end else {
                unpinVmo()
                throw .outOfRange
            }
            at += KernelLayout.pageSize
        }
        vmo.retain()
        object.retain()
        guard let pmt = Objects.allocate(PmtObject(bti: object, vmo: vmo, offset: offset, size: size)) else {
            object.release()
            vmo.release()
            unpinVmo()
            throw .noMemory
        }
        object.header.lock.withLock { bti.pointee.livePins += 1 }
        return pmt
    }

    /// The device address of byte `offset` of a live PMT's range.
    static func address(_ pmt: ObjectPointer, at offset: UInt64) -> UInt64 {
        let p = PmtPointer(object: pmt)
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
        release(p)
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
            release(p)
            pmt.release()  // the list's
        }
    }

    /// Unpins the VMO range and drops the PMT's reference to the VMO.
    private static func release(_ p: PmtPointer) {
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

    // MARK: Logging

    /// A kernel debuglog record built with TextOutput calls (one line, up
    /// to 128 bytes).
    private static func log(_ severity: UInt8, _ body: (LineBuffer) -> Void) {
        guard let raw = unsafe heap.allocate(size: 136) else { return }
        let line = unsafe LineBuffer(raw)
        body(line)
        unsafe DebugLog.write(severity: severity, flags: 0,
                              Span(_unsafeStart: raw.assumingMemoryBound(to: UInt8.self) + 8,
                                   count: raw.load(as: Int.self)),
                              pid: 0, tid: 0)
        unsafe heap.free(raw)
    }
}

/// A 128-byte line in heap memory: a count word, then the bytes.
@safe private struct LineBuffer: TextOutput {
    let raw: UnsafeMutableRawPointer

    @unsafe init(_ raw: UnsafeMutableRawPointer) {
        unsafe self.raw = raw
        unsafe raw.storeBytes(of: 0, as: Int.self)
    }

    func write(utf8: Span<UInt8>) {
        var count = unsafe raw.load(as: Int.self)
        for i in 0..<utf8.count where count < 128 {
            unsafe raw.storeBytes(of: utf8[i], toByteOffset: 8 + count, as: UInt8.self)
            count += 1
        }
        unsafe raw.storeBytes(of: count, as: Int.self)
    }
}
