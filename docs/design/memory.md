# Memory: PMM, heap, VM, VMOs

Physical and virtual memory, address spaces, every VMO kind, pagers, reclamation and accounting. Part of croi's design notes (index in CLAUDE.md).

## Physical memory

Physical memory (`Kernel/Pmm.swift`, global `pmm`, after Zircon's
PmmNode): arenas over contiguous RAM the kernel owns (free, kernel,
handoff, bootfs; ACPI reclaim, firmware runtime/NVS get none), each with
a `Page` array (32 B/page) carved by the boot allocator. Pages start `.wired`;
free RAM the boot allocator never handed out (it records exact spans) goes
on a doubly linked free list. amd64 keeps the first MiB wired for SMP
trampolines. `allocatePage`, `allocateContiguous(count, alignLog2:)`,
`free` (panics on double free), `endHandoff()` (frees the loader's handoff
data and boot page tables; nothing may read the handoff afterwards).
Guarded by `pmmLock`. ACPI reclaim is never the PMM's: user space reads
the tables there for good (K9b). Boot runs a PMM self-test.

## Kernel heap

Kernel heap (`Kernel/Heap.swift`, global `heap`): PMM pages (state `.heap`)
through the physmap, like Zircon's. Requests up to 2 KiB use one-page slabs
in 13 size classes (per-slab free lists; empty slabs go back to the PMM);
larger or >2 KiB-aligned requests get contiguous PMM pages. Bookkeeping is
in the `Page` records (no headers). `free` validates, catches double frees
and poisons. `posix_memalign`/`malloc`/`free` are `@c @implementation`
(the Swift runtime allocates through them). Guarded by `heapLock`.

## Virtual memory

Virtual memory (`Kernel/Vm/`, after Zircon's VmAspace/ArchVmAspace):
- `ArchAspace`: map / unmap / protect / query on live page tables. Tables
  from the PMM (`.mmu`) via the physmap; partly covered large pages are
  split; emptied tables go back to the PMM (never roots). Each change is
  followed by `arch_tlb_invalidate_page` (amd64/rv64 local only until SMP
  shootdowns; arm64 broadcast). arm64 uses break-before-make when block
  size or memory type changes, so never split the physmap (the tables are
  reached through it).
- `KernelAspace` (global `kernelAspace`, `vmLock`): region allocator over
  KernelLayout's dynamic range (first fit, sorted `UniqueArray`, guard page
  on both sides of every region). `allocate(pages:)` (fresh zeroed PMM
  pages, RW+NX), `mapPhysical` (e.g. MMIO), `reserve` (address space only;
  map via `withArch`), `free`. Not yet: VMOs/VMARs/user aspaces; kernel
  top-level entries are created on demand, so on amd64/rv64 they must be
  pre-populated before user address spaces copy the kernel half.

## User address spaces and VMOs (K4a)

User address spaces and VMOs (K4a, Kernel/Vm/):
- `UserAspace` (~Copyable owner of a heap `UserAspaceRecord`): lower-half
  tables (UserLayout: 2 MiB up to the half's top less 1 GiB) sharing the
  kernel half. amd64/rv64 copy the kernel root's upper 256 slots, which
  `populateKernelHalf` fills once at boot and `pinsTopLevel` keeps forever;
  arm64 uses TTBR0. ASIDs (arm64 8-bit, rv64 probed, amd64 none: CR3
  reload) are recycled with a flush. Threads carry `aspace`; switchAway
  loads the next thread's tables (kernel threads: the kernel's only).
  `MapAttributes.user` marks EL0/U pages (never global, never kernel-exec).
- `Vmo` (anonymous: zero pages committed on first touch; physical;
  contiguous) with a refcount held by the handle and every mapping;
  pages are PageState `.vmo`. Mappings (`Mapping`, rights read/write/
  execute) are kept sorted in the aspace; anonymous ones fault in,
  physical/contiguous ones map at once with large pages where aligned.
- Faults: only instructions in the `.croi_fixups` table (usercopy.h,
  `arch_user_load_u64`/`arch_user_store_u64`: arm64 ldtr/sttr, rv64 with
  SUM) may fault user memory in from the kernel; unresolvable faults
  resume at their recovery point with -1. The handler runs with the
  faulting context's interrupt state, so a CPU waiting for the aspace
  lock still answers the holder's TLB shootdown (it deadlocked masked).
  `vm` trace category: fault (resolved or refused) and commit records.
- Review round 1, part 2 (VM): `ArchAspace.unmap` chains emptied tables
  through their first entry (a page address, never present) and frees
  them after `flushOthers`; a failed eager map in `insert` unmaps what it
  mapped; `process_read_memory` retains the VMO under the aspace lock and
  `privatize` returns its child retained.
- Review round 1, part 4 (entry/exit): `Processes.start` refuses entry
  points at or above `UserLayout.top` (UserTraps.enter kills as a
  backstop); amd64 GDT 0x18 (USER_CS32, only STAR's sysret base) is not
  present, CSTAR is `syscall_compat_refused` (sysretl with -2, no stack
  or GS), SYSENTER MSRs are 0; `isr_common` executes clac (with SMAP)
  before anything; rv64 trap entry clears SUM after saving sstatus;
  `setAspace` loads the thread's TLS (FS/GS, TPIDR_EL0); register and
  debug-state access go through `Exceptions.withStopped` (under the
  thread object's lock); arm64 SError/FIQ from EL0 take the SError policy
  (contained or restartable ones become the process's exception).
- Review round 1, part 3: Zircon's resource limits raise POLICY_ERROR
  with the code as synth_code (`Policy.limitException`, task.h
  CROI_EXCP_POLICY_CODE_*): a channel write leaving more than
  `Channels.maxPending` (3500) queued (the message still goes),
  port_queue past `Ports.maxUserPackets` (4096 user packets, then
  SHOULD_WAIT), a port's `maxObservers`th (50000) async wait (still
  registered). Unhandled, the process dies. `HandleTable.get(have:)`
  returns a handle's rights from the same lookup as its object.
- Mapping ceilings (review round 1): each `Mapping` keeps `ceiling`, the
  rights it may ever have (vmar_map: the VMO handle's read/write/execute;
  kernel mappings: what they were mapped with; a `sharedReadOnly` VMO:
  read), and `protect` refuses more with ACCESS_DENIED (`VmError.
  accessDenied`). Before, a root-VMAR handle could protect the shared
  vDSO writable. Mode 17's checks 686-687 (686 failed without it).
- Regions (K4b): each aspace keeps `regions` (sub-regions, sorted, with a
  parent; region 0 is the root) and non-overlapping `mappings`. A
  reservation's range is held for views: `mapView`/`unmapView` replace
  views under the aspace lock, so faults (which take the lock) see the old
  view or the new one, never a hole (ext 7). `unmap(range)` trims and
  splits mappings; `protect` splits at the edges. VMOs list the aspaces
  mapping them (`mappers`); `decommit` takes pages out of the VMO, then
  unmaps them from each aspace (held by a reference, skipped if `dead`),
  then frees them, so the aspace -> vmo lock order holds.
- Physical (K4b, K9b): `PhysicalMap` keeps the memory-map ranges that
  are RAM (and persistent/unusable memory); physical VMOs over them are
  refused (`.denied`). Firmware memory the physmap maps cached (ACPI
  reclaim and NVS, UEFI runtime) is allowed but only whole, and such a
  VMO is always cached (`cachedFirmware`; `setCachePolicy` refuses
  anything else), so no mapping disagrees with the physmap.
  Contiguous VMOs take an address `limit` and come from `ContiguousPool`
  first (`croi.contiguous_pool=<MiB>`, default 8, below 4 GiB if it can).
  `cacheOp` (include/cache.h: clflush, dc cvac/ivac/civac, Zicbom cbo.*
  when the RHCT lists it) and `setCachePolicy` (unmapped VMOs only).
- Accounts (ext 6): `MemoryAccount` limit + pressure level; anonymous VMOs
  charge per committed page, contiguous (pinned) and `deviceLocal` VMOs in
  full and are `neverEvict`; over-budget commits fail; the pressure hook
  fires once per crossing and re-arms below 80% of the level.
- Anonymous pages live in a sparse 512-way radix `PageList`.
- W^X and JIT (K4c, Vm/Jit.swift): no mapping is writable and executable
  (map, mapView and protect refuse it), except in a JIT reservation
  (`allocateRegion(reservation: true, jit: true)`) on hardware with
  protection keys: amd64 PKU (CR4.PKE on every CPU), where the
  reservation gets a key (1-15, `MapAttributes.protectionKey`, PTE bits
  62:59), its pages map RWX, and each thread's PKRU (`Thread.pkru`,
  loaded at switch; user threads start with writes to keys 1-15
  disabled) gates writes per thread (`Scheduler.setJitWritable`; WRPKRU
  in user space). A PKU fault (error code bit 5) is refused outright.
  Without keys (arm64: POE is Armv9.4 and neither target board has it;
  rv64) a JIT maps two views of one VMO, RW and RX. Swift note: a failed
  `guard` may end the lifetime of `~Copyable` values early (their deinit
  runs before the else branch), so join threads before judging them.
- Lock order: aspace -> vmo -> account -> heap -> pmm (and vm for the
  kernel aspace).

## Reservations, atomic views and the JIT (K15b)

Reservations, atomic views and the JIT, K15b (ext 7, F-218; task.h
CROI_VM_RESERVATION/JIT, vmar_map_view 244, CROI_INFO_VMAR_JIT 0x10004;
agreed with Todhchai 2026-10-12):
- vmar_allocate's RESERVATION makes a child VMAR that holds its range for
  views: vmar_map and sub-VMARs refused there; vmar_map_view installs a
  view, atomically replacing what was there (K4b's `mapView`, with the VMO
  handle's rights as the protect ceiling); vmar_unmap, vmar_protect and
  vmar_op_range work on views; an unviewed page faults (guards by
  omission). JIT implies RESERVATION and takes a protection key on amd64
  with PKU: keys are per address space (`UserAspaceRecord.jitKeys`, 1-15;
  K4c had 15 system-wide), and with none left the reservation is quietly
  views-only (Todhchai's choice; the info says which). Executable views
  need a VMO handle with EXECUTE (VMEX).
- Only RWX views carry the key: RW and RX views are key 0, so dual views
  work in a keyed reservation too (they faulted: threads start with
  keyed writes disabled).
- Threads open a key's writes themselves (WRPKRU; they start with keys
  1-15 write-disabled); the scheduler reads the outgoing user thread's
  PKRU back at every switch (it only loaded the stored one, so a user
  WRPKRU was lost and the per-CPU cache could skip the next load).
- Mode 17's `jit_views` (checks 722-728; 726 needs PKU, which TCG -cpu
  max has, and fails without the switch-out PKRU save).

## Memory accounts (K15a)

Memory accounts, K15a (Kernel/Object/AccountObject.swift,
Vm/MemoryAccount.swift, include/account.h, syscalls 240-243; Todhchai ext 6,
its F-109; agreed with Todhchai 2026-10-12; croi's, Zircon has none):
- An account object (type 49; BASIC, WRITE and croi's CHARGE right, 1 <<
  25) over a `MemoryAccountRecord`: a limit, warning and critical levels
  (percent of it; entered at the threshold, left below 80% of it), one
  coalescing pressure packet (type 0x81: payload[0] limit, [1] charged,
  [2] changes, [3] level) on every level change. account_create needs the
  MEMORY system resource (base 17) or root; account_set_limit never goes
  below what is charged (BAD_STATE); CROI_INFO_MEMORY_ACCOUNT (0x10003).
- A process charges its `ProcessObject.account`: its creator's at
  process_create (`Accounts.current()`), replaced by process_set_account
  (process WRITE, account CHARGE) only before it starts. Charged: the
  VMOs it creates (vmo_create, snapshot children, vmo_create_contiguous);
  CROI_VMO_CHARGE_TO (1 << 30) names another account (CHARGE): vmo_create's
  fourth argument, vmo_create_child's sixth (a physical SLICE then charges
  its whole size, never evicted: device-local), vmo_create_contiguous's
  alignment argument bits 63:32. A VMO keeps its account wherever its
  handles go. Not charged: physical VMOs, aliases, pager VMOs (v1),
  kernel memory and page tables. Launchers pass a process its own account
  as CROI_PA_MEMORY_ACCOUNT (0x41).
- Charge follows `committedPages` everywhere pages enter or leave an
  anonymous VMO: commit, decommit, `take`, resize, snapshot copies (charged
  per page as they copy in), discard and eviction, release. Over the
  limit a commit fails: NO_MEMORY from syscalls, a fatal page fault from a
  fault.
- Mode 17's `memory_accounts` (checks 713-721; child submode 12; 717
  and 721 fail without the before-start rule and snapshot charging).

## VMO children (K11a)

VMO children, K11a (Vmo.swift `init(childOf:)`, VmoObject
`createChild`, vmo.h CROI_VMO_CHILD_*, syscall 48):
- `vmo_create_child(vmo, options, offset, size, out)`: SNAPSHOT_AT_LEAST_
  ON_WRITE of an anonymous VMO (a child too), optionally NO_WRITE. The
  child is an anonymous VMO with `parent`/`parentOffset` (a reference):
  an uncommitted page reads as the parent's (`content(at:)`, recursive;
  zero past the parent's end), and its first touch, read or write,
  copies it in (`commit`; Zircon's "at least on write" allows it, so no
  hidden nodes). Lock order child -> parent. Decommit on a child is
  NOT_SUPPORTED (its page would read as the parent's again); ZERO
  writes zeros into a copy. Rights as Zircon: the parent handle's (needs
  DUPLICATE and READ) plus GET/SET_PROPERTY; WRITE added and EXECUTE
  removed unless NO_WRITE removes WRITE. (SLICE came in K13a,
  CHILD_RESIZABLE in K13h, the other kinds in K14g.) Mode 17 checks it
  (`vmo_children`).

## The other child kinds (K14g)

The other child kinds, K14g (Vmo.swift `Vmo.snapshot`, `init(sliceOf:)`,
`init(referenceOf:)`; VmoObject `createChild` in Zircon's order):
- Snapshots (`Vmo.Snapshot`): SNAPSHOT copies every page its parent shows
  in range at creation (`copyContent`, level by level up the chain, each
  under its lock), so nothing reads through (no hidden nodes; see
  docs/zircon-divergences.md). SNAPSHOT_MODIFIED is that too, except
  under a pager: of the pager VMO it is at least on write; of a child, the
  child's own pages are copied and the rest read through to the child's
  parent up to `parentLimit`. Zircon's refusals: physical NOT_SUPPORTED,
  contiguous INVALID_ARGS, uncached BAD_STATE, SNAPSHOT under a pager
  NOT_SUPPORTED, any clone of an anonymous VMO through a slice
  NOT_SUPPORTED or with pinned pages BAD_STATE (at least on write too:
  Zircon's is bidirectional there). `VmoRecord.clone` marks every
  snapshot child (IS_COW_CLONE; DECOMMIT NOT_SUPPORTED).
- Aliases (`VmoRecord.isAlias`): a SLICE of an anonymous VMO (wholly
  inside; not of a resizable one) or a REFERENCE (offset and size 0; not
  of a slice or contiguous VMO; RESIZABLE only of a resizable VMO and with
  RESIZE on the parent handle). No pages of their own: `parent` is the
  root, `target` gives (root, offset). Syscalls resolve them (vmo_read/
  write, op_range, bti_pin, streams), and `Mapping` keeps the root and
  root offset in `vmo`/`offset` with the mapped VMO in `holder` (the
  mapping's reference; koid and name in the info topics), so faults,
  `unmapEverywhere` and reclaim work on the root unchanged. A reference's
  size and stream size are its root's (`sizeOwner`): vmo_set_size through
  one resizes the root; a slice has its own stream size over the root's
  pages. Aliases have nothing attributed (Zircon's rule). The root's
  `aliases` count freezes its cache policy.
- `VmoRecord.owner`: the VMO a child was created from when that isn't its
  `parent` (an alias of an alias, a full snapshot, a modified snapshot
  reading through to its grandparent); its ZERO_CHILDREN and ZX_INFO_VMO
  parent_koid follow `owner`, else `parent`. A slice of a slice (K13a's
  physical ones too) is now its slice's child.
- `withContent(at:)` copies a parent's page under that parent's lock
  (a child's first touch did it after dropping the lock, so a concurrent
  decommit could hand it a freed, reused page).
- Mode 17's `child_kinds` (checks 650-660).

## VMO slices, ZERO_CHILDREN and handle counts (K13a)

VMO slices, ZERO_CHILDREN and handle counts, K13a (Vmo.swift `init(sliceOf:)`,
`childAdded`/`childGone`; VmoObject; agreed with Todhchai for the GPU
driver host's BAR windows):
- `vmo_create_child` SLICE (alone or with NO_WRITE; anything else with it
  INVALID_ARGS) of a physical or contiguous VMO: a VMO of the same kind
  over [offset, offset+size) of its pages (page aligned, wholly inside,
  else INVALID_ARGS), with its cache policy and memory flags, `slice`
  set (a contiguous slice frees nothing); a slice of a slice is one of
  the root. Rights: the parent handle's plus GET/SET_PROPERTY, less WRITE
  with NO_WRITE. Anonymous parents: K14g's aliases.
- Every VMO record counts its live children (K11a's snapshots too) and
  knows its object (`VmoRecord.object`, cleared by the object's destroy).
  ZERO_CHILDREN (signal bit 3) is set at wrap, cleared by `childAdded`,
  set again by `childGone` (the child record's last reference: its last
  handle and last mapping); both update the signal under the object's
  lock and recheck the count there (Zircon's double check). Lock order
  object -> vmo there.
- A VMO with children, or a slice, can't change its cache policy
  (`VmError.badState`, BAD_STATE).
- `ObjectHeader.handleCount`: +1 in `HandleTable.add` and in
  `MessagePointer.setHandle` (a handle in flight), -1 in close/take, at
  channel_read's install and in a message's `free`. object_get_info
  CROI_INFO_HANDLE_COUNT (19, Zircon's), INSPECT.
- vmo_create_physical's rights are now Zircon's (the default VMO rights:
  WAIT, INSPECT and SIGNAL, no EXECUTE).
- Mode 17's `vmo_slices`: on segment 0's ECAM, refusals, reads through a
  slice and a slice of it, cache policies frozen, rights, the count
  through a channel round trip, ZERO_CHILDREN after the last unmap.

## Resizable VMOs (K13h)

Resizable VMOs, K13h (Vmo.swift `resize`, VmoObject `create`/`setSize`,
PageList `grow`, syscall 233; vmo.h, task.h):
- vmo_create's options (it ignored them): RESIZABLE (1 << 1); UNBOUNDED
  NOT_SUPPORTED (with RESIZABLE INVALID_ARGS, first), DISCARDABLE (K14a),
  others INVALID_ARGS; an unaligned size is the content
  size. RESIZE (1 << 22) only on a resizable VMO's handles; snapshot
  children are resizable with CHILD_RESIZABLE (RESIZE then, never the
  parent's); pager_create_vmo takes RESIZABLE. ZX_INFO_VMO's RESIZABLE.
- vmo_set_size (233) in Zircon's order: WRITE; RESIZE if resizable
  (ACCESS_DENIED); physical/contiguous UNAVAILABLE; rounding overflow
  OUT_OF_RANGE; not resizable UNAVAILABLE; pinned pages cut off BAD_STATE.
  `VmoRecord.size` changes under the VMO lock: a shrink frees the pages
  past it (unmapped everywhere first) and wakes pager waiters there
  (`Pagers.cut`); a grow deepens the page lists (`PageList.grow`: a new
  root over the old). The content size becomes the exact size and the last
  page's tail past it reads zero.
- Past the end: `commit`/`lookup` refuse it under the lock, so faults fail
  (fatal page fault), vmo_read/write are OUT_OF_RANGE (also when shrunk
  meanwhile). An anonymous VMO may be mapped past its end (Zircon's: it
  may grow); vmar_map takes REQUIRE_NON_RESIZABLE (NOT_SUPPORTED on a
  resizable VMO) and ALLOW_FAULTS (accepted).
- A pager VMO's grown space is a dirty zero interval (K14k's
  `ZeroInterval`): zeros owed to nobody, reported with IS_ZERO, handed
  back to the pager by WRITEBACK_BEGIN then END.
- Differences: a snapshot child of a parent that shrinks reads zeros past
  the cut only while the parent is that small (Zircon clamps it for good);
  streams still never grow their VMO (the pinned tree's either).
- Mode 17's `resizing`.

## UNBOUNDED VMOs (K14i)

UNBOUNDED VMOs, K14i (`Vmos.maxSize`, `Vmos.createSize`; Zircon's
parse_create_syscall_flags): vmo_create and pager_create_vmo with
UNBOUNDED make a VMO of 0xFFFF_FFFF_FFFF_0000 bytes (Zircon's MAX_SIZE:
every page round-up below it stays in range) whose content size is the
size given (OUT_OF_RANGE past MAX_SIZE; RESIZABLE with it INVALID_ARGS);
bounded sizes past MAX_SIZE are OUT_OF_RANGE too. Range operations cost
what is present, not the range: `PageList.next(from:before:)` skips empty
subtrees, used by decommit (`takePresent`), `zero` (a plain VMO's middle
decommitted, the ends zeroed in place) and `zeroOwn`, cache ops and
instruction sync (`forEachPage`), resize, pager detach, writeback
(`forEachStateLocked`), dirty ranges, and ALWAYS_NEED's swaps back.
vmo_set_stream_size zeroes up to the new size's page end and, past it,
only what is committed (Zircon's untracked zeroing, without zero
markers; K14k: a pager VMO's become an untracked zero interval). Still
per page: COMMIT, PREFETCH, ALWAYS_NEED's paging in, ZERO under
TRAP_DIRTY. Mode 17's `unbounded` (checks 663-668).

## Copies between user memory and VMO pages (K14h)

Copies between user memory and VMO pages, K14h (Vm/Vmo.swift
`VmoUserCopy`; vmo_read/write, streams, process_read/write_memory): a
page is read or written only under the lock of the VMO that has it
(`withContent`, `ownLocked`), so a decommit, eviction, swap or shrink
can't free it mid-copy (they used to look it up, drop the lock and copy:
a freed page reused by another VMO leaked its bytes). The copy runs
under that spinlock without paging in (`UserCopy.toNoPageIn` /
`fromNoPageIn`, PerCpu.noPageIn); a chunk that faults is paged in with
no lock held (`pageIn`: `UserAspaces.handleFault` per page) and retried,
up to `attempts` times. `.absent` commits (`VmoUserCopy.commit`) or
waits for the next `Pagers.ensure*`. Mode 17's `copy_race` (661-662:
writer, polluter and reader threads) failed 3 of 3 KVM boots with the
copy outside the lock.

## The user pager (K13d)

The user pager, K13d (Kernel/Object/Pager.swift, User/PagerSyscalls.swift,
syscalls 202-208; vmo.h; Todhchai's page cache and mmap for Taisce):
- Zircon's pager (type 28; INSPECT, TRANSFER, ATTACH_VMO 1 << 23,
  MANAGE_VMO; NEW_PAGER policy 14, pager_create_vmo checks NEW_VMO):
  pager_create, pager_create_vmo(pager, options, port, key, size), with
  the size rounded to pages and an unaligned one as the stream size;
  RESIZABLE / UNBOUNDED NOT_SUPPORTED (no resizable VMOs).
  pager_detach_vmo, pager_supply_pages (pages moved from an anonymous aux
  VMO with no parent, `Vmo.take`; aux gaps supplied as zeros; pages the
  VMO has kept), pager_op_range FAIL (IO, IO_DATA_INTEGRITY, BAD_STATE,
  NO_SPACE, BUFFER_TOO_SMALL, sign-extended). Pager checks in the pinned
  tree's order (pager.rs); the koid check is INVALID_ARGS.
- A pager VMO is anonymous with `VmoRecord.pager` (a `PagerSource`: port,
  key, outstanding ranges, waiters); its snapshot children have
  `readsFromPager`. `commit(at:)` never zero-fills a page a pager owes;
  `VmoPointer.pagerGap(at:)` finds the pager VMO and offset a read would
  wait for, and `Pagers.ensure(vmo, offset, readAhead:)` requests (one
  READ packet, type 9, per new range: from the page up to the read-ahead,
  cut at a present page or the next outstanding range, at most 256 pages)
  and waits (interruptible; 300 s, Zircon's overtime: TIMED_OUT). Callers:
  the fault handler (retains the mapping's VMO and waits outside the
  aspace lock, then retries; a fault taken with interrupts masked doesn't
  wait), vmo_read/write (the rest of the copy as read-ahead), streams,
  vmo_op_range COMMIT/PREFETCH/ZERO, bti_pin. ZERO on a pager VMO makes
  a zero interval of its whole pages (K14k; TRAP_DIRTY VMOs zero in
  place); DECOMMIT is NOT_SUPPORTED.
- FAIL: waiters whose page is in the range get the status (vmo_read
  returns it; a fault is refused: exception); others on an overlapping
  request ask again. Detach (pager_detach_vmo, or the VMO's last
  reference): waiters wake to BAD_STATE, clean pages are dropped (dirty,
  awaiting-clean and pinned ones stay for writeback), one COMPLETE
  packet. The pager's last handle detaches its VMOs without COMPLETE.
- Dirty tracking (part 2): `VmoRecord.states` (a PageList: PageDirt
  dirty 1, awaiting clean 2, absent clean) and `modified`. A pager VMO's
  clean pages are mapped read only even through writable mappings (the
  fault path, and `UserAspace.protect`, which never grants write to a
  pager VMO's present pages), so the first write faults into
  `Pagers.prepareWrite`: the page becomes dirty, after a DIRTY request
  (type 9, command 2) the pager answers with op DIRTY if the VMO has
  TRAP_DIRTY; the fault then makes the entry writable. Kernel writes
  (vmo_write, streams, ZERO) go through `ensureWritable`. op DIRTY
  (TRAP_DIRTY only, else NOT_SUPPORTED; a page not supplied NOT_FOUND),
  WRITEBACK_BEGIN (dirty -> awaiting clean, unmapped everywhere:
  `VmoPointer.unmapEverywhere`, so a write meanwhile dirties again; dirty
  zero intervals too, and with IS_ZERO only those, K14k), WRITEBACK_END
  (awaiting -> clean; zero intervals awaiting clean go). pager_query_dirty_ranges (207: pager | vmo << 32, offset,
  length, buffer, buffer_size, size_t out[2] = actual, avail; ranges of
  pages not clean, options 0) and pager_query_vmo_stats (208; MODIFIED,
  RESET_VMO_STATS).
- Differences from Zircon: a packet per request (Zircon: one in flight
  per VMO), none withdrawn when a request resolves before it is read; the
  source holds its port.
- (Eviction of clean pages and the hints came in K14a, resizable pager
  VMOs in K13h, unbounded ones in K14i, zero intervals in K14k.)
- Mode 17's `pager`: a pager thread serving a fault, a two-page vmo_read
  (one request), a FAIL, a snapshot child reading through; writes through
  a mapping and vmo_write, dirty ranges, stats, a writeback with a write
  during it, detach dropping clean pages; a TRAP_DIRTY VMO's DIRTY
  requests from vmo_write and a write fault.

## Zero intervals (K14k)

Zero intervals, K14k (Pager.swift `ZeroInterval`, `VmoRecord.zeros`;
Zircon's): a pager VMO keeps sorted, disjoint ranges of absent pages that
read as zeros the pager is never asked for, each dirty, awaiting clean or
untracked (`zeroStateLocked` binary-searches; `carveZerosLocked`,
`addZerosLocked` merging neighbours, `changeZerosLocked`). Made by ZERO
(`Pagers.zeroPages`: whole pages dropped, pinned ones zeroed in place and
dirty instead, waiting readers let go; `ensureWritableForZero` makes only
the partial ends present), a grow (dirty) and a stream size cut past its
page end (untracked). Reads copy zeros and commit nothing
(`readsAsZero`, `VmoUserCopy.zeros`); a write, fault or `prepareWrite`
commits a zeroed, dirty page and splits the interval; supply skips them;
read-ahead requests stop at one. query_dirty_ranges reports dirty and
awaiting ones with IS_ZERO; WRITEBACK_BEGIN makes dirty ones awaiting
clean (with IS_ZERO it leaves pages alone: Zircon's race), END removes
the awaiting ones (the pager supplies the range again). Under TRAP_DIRTY
ZERO still zeroes page by page (the pager would have to approve the
dirtying first). Mode 17's `zero_intervals` (checks 669-675).

## Reclamation (K14a)

Reclamation, K14a (Kernel/Vm/Reclaim.swift, vmo.h, syscall 235; Zircon's
PageQueues + Evictor + MemoryWatchdog without the page queues):
- Reclaimable VMOs (pager VMOs from creation, DISCARDABLE ones) are on one
  list (`Reclaim.register`, links in VmoRecord, unlinked by the last
  release; `tryRetain` to walk it). Each page record has `reclaimAge`
  (aging passes since its last access, up to 7) and `reclaimFlags`
  (ALWAYS_NEED, DONT_NEED), reset at allocation.
- Accesses make a page newest (`Reclaim.touch`): `commit(at:)` and
  `lookup(at:)` of a reclaimable VMO (under its lock, so a reader that
  just looked a page up keeps it), the fault path, and accessed bits,
  harvested from every mapping before each aging pass and eviction
  (`ArchAspace.harvestAccessed` clears them, local invalidate, then
  `flushAccessed`). arm64 has no hardware AF management (TCR.HA off) and
  rv64 may be Svade: an access then faults on a present PTE, and
  handleFault's present branch sets the bit (`markAccessed`); without it
  the fault loops (verified: arm64 hangs).
- The "reclaim" kernel thread ages every `croi.reclaim.aging_ms` (15 s)
  only while reclaimable VMOs exist, so an idle machine still makes no
  wakeups. Eviction (`Reclaim.evict(target:minAge:ignoreHint:)`, one at a
  time under a Mutex): DONT_NEED first, then oldest first down to
  `minAge` (6 for the watchdog, 2 at OOM, ages 0-1 never); clean,
  unpinned pages of attached pager VMOs, ALWAYS_NEED only with
  ignoreHint; a discardable VMO goes whole when its first committed
  page's turn comes. Pages are taken out under the VMO lock, unmapped run
  by run, then freed; the pager is asked again on the next access.
  `reclamationEvents` is ZX_INFO_VMO's committed_change_events.
- DISCARDABLE (vmo_create option 4, with RESIZABLE allowed; no children,
  cache policy stays cached): LOCK / TRY_LOCK / UNLOCK through
  vmo_op_range (READ or WRITE; whole VMO else OUT_OF_RANGE; LOCK checks
  its buffer after locking and unlocks on failure; UNLOCK at count 0
  BAD_STATE; TRY_LOCK of a discarded VMO UNAVAILABLE). States unset /
  locked / reclaimable / discarded (`DiscardState`): reclaimable only
  after a lock and unlock; discarded, commit and lookups fail (faults
  kill, vmo_read/write NOT_FOUND) until LOCK, which reports
  discarded_size = size.
- Hints (vmo_op_range and vmar_op_range 12/13, no rights): pager VMOs
  (a snapshot child's go to its pager ancestor), others ignore them.
  ALWAYS_NEED pages the range in and is sticky for those pages.
- Memory watchdog (Zircon's, `croi.oom.*`: outofmemory_mb 50,
  imminent_oom_delta_mb 10, critical_mb 150, warning_mb 300, debounce_mb
  1, hysteresis_seconds 10, eviction_delay_ms 5000, evict_at_warning,
  eviction_delta_at_oom_mb 10, reboot_timeout_ms 50000,
  trigger_on_alloc_failure, enable=0; out of order: off). The PMM wakes
  it when the free count leaves the current level's band
  (`Pmm.setFreeMemorySignal`; also a failed single-page allocation) via a
  zero-delay timer, since it may be under any lock. One event object per
  level, exactly one SIGNALED; system_get_event(root job, kind): handles
  WAIT | DUPLICATE | TRANSFER, OUT_OF_MEMORY needs MANAGE_PROCESS, other
  jobs ACCESS_DENIED. Worse levels signal at once, better ones after the
  hysteresis; a worse level at or below critical evicts (after the
  delay) to the critical watermark + debounce; OOM evicts at once (ages
  2+, hints ignored), then signals, logs and reboots after the timeout
  (`Power.reboot`). Log lines go to the debuglog (`KernelLog.write`, which
  DMA's warnings use too).
- KMEM_STATS: vmo_reclaim_total/newest/oldest bytes, discardable
  locked/unlocked bytes. Test hooks (syscall 6): 6 aging passes, 7 evict,
  8 watermarks/hysteresis/delay (0: the command line's), 9 free bytes.
- Tests: mode 17's `reclaim` (checks 600-619: eviction order, refault from
  the pager, hints, dirty pages kept, discardable states, the events moved
  by test watermarks); `boot-oom` (watermarks above RAM: OOM at boot,
  reboot). Lock order: aspace -> vmo (harvest); the registry lock is a
  leaf (heap below it).

## Page loaning (K14f)

Page loaning, K14f (Kernel/Vm/Loans.swift, Pmm.swift's loaning part;
Zircon's physical page borrowing; Todhchai requirement 3):
- Lenders: a contiguous VMO's decommitted range (vmo_op_range DECOMMIT,
  `Loans.decommit`; refused on slices, with children, over pinned pages)
  and the contiguous pool's free pages (lent at boot and on each free,
  taken back by `ContiguousPool.allocate`). `croi.ppb.loan=off` turns it
  off (contiguous DECOMMIT NOT_SUPPORTED again, the pool idle).
- PMM: lent free pages are PageState `.freeLoaned` on their own list,
  which only `allocateLoaned` (a borrower) draws from; `Page.loaned` /
  `loanCancelled` in `reclaimFlags`; a borrowed page keeps its borrower
  in `next` (VmoRecord) and `prev` (index). A borrowed page's free goes
  back to the loaned list, or to its lender if cancelled. `unloan` is
  the lender's step: back (free, or not lent), evict (borrowed), wait (in
  transit). KMEM free_loaned_bytes.
- A contiguous VMO's lent pages are bits in `VmoRecord.lent`: `lookup` /
  `commit(at:)` see them absent, eager mapping skips them (the mapper
  registered and the bits read in one locked step: `addMapper(lentIn:)`),
  the fault path and every `Pagers.ensure*` take them back through
  `Loans.ensure` (zeroed; written back for uncached VMOs), as does pin;
  slices of a VMO with lent pages are BAD_STATE; the VMO's end takes them
  back first (`endOfLender`). `Loans.mutex` (outermost) serializes lending
  and taking back. Attribution and ZX_INFO_VMO count lent pages out.
- Borrowers (part 2): only a pager VMO's clean pages (not TRAP_DIRTY, not
  detached, never pinned: `VmoRecord.everPinned`), swapped onto free lent
  pages by each aging pass (`Loans.borrow`, Zircon's borrow-on-MRU; age
  and hints copied, `copyReclaimState`); the originals are freed for
  anyone. `Loans.unborrow` swaps one back to an ordinary page before
  `prepareWrite` dirties it, before a pin, and on ALWAYS_NEED. Taking a
  page back evicts it from its borrower (`unloan` retains the borrower
  under pmmLock while the backlink is good; the pager supplies the page
  again). Eviction (K14a) evicts borrowed pages like any. The write-fault
  path that makes an entry writable first checks it maps the VMO's
  current page (a read-only entry can outlive a swap until its unmap).
- Mode 17's `page_loaning` (checks 636-643) and `page_borrowing`
  (644-649).

## Memory statistics

Memory statistics (Todhchai's M3 resident-memory budget; task.h,
resource.h, UserAspace.taskStats, Kernel/Object/KernelMemory.swift):
- object_get_info(process, CROI_INFO_TASK_STATS = 12 | 1 << 28, or _V1 =
  12 for the first 32 bytes), Zircon's zx_info_task_stats_t, INSPECT:
  per mapping, mapped bytes, and committed bytes (anonymous: the page
  list's count in range; contiguous: all; physical: none) as private if
  only this address space maps the VMO, else shared and scaled by the
  number of address spaces, with the fraction in 63-bit fixed point.
  Every process maps the vDSO, so its code is shared once there are two.
- object_get_info(INFO system resource or root, CROI_INFO_KMEM_STATS =
  17 | 1 << 28, or _V1 = 17): total, free, wired, heap (slab + large
  pages, free = less bytes in use), vmo, mmu, other (allocated), from a
  scan of the PMM's page records (`Pmm.pageCounts`), and K14a's reclaim
  fields. The rest are 0.
- Boot test mode 13 (`ProcessSelfTest.runMemoryStats`).
