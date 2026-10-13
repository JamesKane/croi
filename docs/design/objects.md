# Kernel objects and syscalls

Handles, waits, ports, tasks, IPC, synchronization and the other object types, mostly Zircon's ABI. Part of croi's design notes (index in CLAUDE.md).

## Kernel objects (K5)

Kernel objects (K5, Kernel/Object/; Zircon's status codes, rights,
signals and object types, so the ABI matches):
- Every object record starts with an `ObjectHeader` (type, koid from 1024,
  signals, observers, lock, atomic refcount); `ObjectPointer` reaches it,
  `Objects.destroy` frees by type. Not `Ref<T>`: objects mutate under
  their own lock, like VMOs and aspaces. `ObjectRef` (~Copyable) is a
  reference held by kernel code; handles hold one each.
- `HandleTable` (per process from K7): slots of (object, rights); a value
  is slot + 8-bit generation + Zircon's fixed low bits, so stale handles
  fail. get (bad handle, wrong type, access denied, in that order),
  duplicate/replace (rights subset or sameRights), close (cancels waits
  through the handle). `HandleTable.withBorrowed` for threads sharing one.
- Waiting: observers on an object's list; `updateSignals` runs them under
  the object lock. `ObjectWait.one/many` (deadlines, canceled on close;
  WaitState on the heap so no trigger outlives it). Ports (`PortObject`):
  FIFO of `PortPacket` (zx_port_packet_t layout), `Ports.queue/wait/
  cancel`; `Observers.waitAsync` is one-shot with EDGE and TIMESTAMP,
  its packet allocated at registration. Lock order: object -> scheduler
  -> port packets (object locks may be held while taking the scheduler
  lock; nothing takes them under it).
- `PacketSource`: kernel events reporting to a port with one owned,
  coalescing packet (count): budget overruns (ext 3,
  `SchedContext.bindOverrunPort`, fired under the scheduler lock) and
  memory pressure (ext 6, `MemoryAccount.bindPressurePort`).
- `VmoObject` (default rights as ZX_DEFAULT_VMO_RIGHTS; `forMapping`
  needs map plus read/write/execute per access). `ResourceObject`: root
  (made at boot) mints system resources; the tracing one (base 14, as
  Zircon) gates `TraceControl` (start, stop, rewind, mark, rings as
  read/map-only VMO handles).

## Processes (K7a)

Processes (K7a, Kernel/Object/Process.swift, include/task.h, syscalls
60-74 in User/TaskSyscalls.swift):
- Job (17), process (1), thread (2) and VMAR (18) objects, Zircon's
  rights and TERMINATED signal. A root job at boot. A process owns its
  `UserAspace` (the vDSO mapped at creation) and `HandleTable`; threads'
  syscalls use the process's table. Its first thread gets the transferred
  handle, arg2 and the vDSO base in the first three argument registers
  (`arch_enter_user` takes three); a C entry on amd64 needs a call-aligned
  stack (crt-style stub, or start sp at top - 8).
- Each user scheduler thread holds a reference to its thread object
  (`Thread.object`), which holds the process. The last running thread
  tears the process down from its own context: `setAspace(nil)`, close
  every handle (so a process holding its own handle still dies), wait
  until earlier exiters have left the address space, destroy it. A
  process whose threads never ran is torn down by its last reference.
- Kill (`task_kill`, process_exit, a fault until K7d's exceptions):
  `Scheduler.interrupt` marks the thread; interruptible waits (syscall
  waits: object/port waits, nanosleep: `block(interruptible: true)`) end
  with `.interrupted`, a running thread is preempted, and every return to
  user mode (`UserTraps.leaving`) exits a marked thread. Return codes
  -1024 (killed), -1026 (policy) and -1028 (exception), Zircon's. Kernel-only waits stay
  uninterruptible.
- A job's children and a process's threads are non-owning lists (an
  object's destroy takes it out under the parent's lock): anything that
  walks one and uses an entry after the lock drops takes a reference
  with `tryRetain` under it. kill(process:) didn't, and a job kill
  (Todhchai's shutdown, ~3 boots in 20 one afternoon) locked a thread
  object freed meanwhile: its poisoned lock word spun forever. SpinLock
  now panics on a holder that isn't a CPU.
- VMARs wrap K4 regions (`UserAspace.withView`); `vmar_map` and friends
  pack handle | options << 32 into one register (six argument
  registers). A dead address space refuses operations under its lock
  (`VmError.dead`). User code has `croi_syscall6`.
  `vmar_unmap_handle_close_thread_exit` (75) is a syscall (Zircon's is
  vDSO code): `Syscalls.run` exits the thread after the handle-table
  borrow ends, so no frame holds a reference; a failed close raises an
  undefined-instruction exception (Zircon's vDSO traps).
- User TLS (`Thread.tls`/`gs`, switched in `switchUserTls`): amd64 FS
  and user GS bases only through object_set/get_property REGISTER_FS/GS
  (4/2; the calling thread's own handle, canonical; CR4.FSGSBASE stays
  off, so the record is the truth and a per-CPU cache skips unchanged
  WRMSRs); arm64 TPIDR_EL0 saved and restored per user thread; rv64 tp
  is in the frame. thread_read/write_state carry them.
- `vmo_create` rounds sizes up to a page (Zircon's RoundSize); size 0
  makes a zero-size VMO, as Zircon's (since K9a).
- `object_get_child` (78, K15d; Zircon's, for Todhchai's Inspector,
  `Processes.child`): a job's child job or process, or a process's
  thread, by koid. ENUMERATE on the parent, SAME_RIGHTS (exactly) for the
  parent handle's rights or a subset of them (else ACCESS_DENIED), a koid
  not a live child NOT_FOUND (dead threads and processes stay listed
  until their last reference, so they are filtered: Zircon drops them
  at exit), other parents WRONG_TYPE. Mode 17's checks 746-751.
- Lock order: job -> process -> thread object -> scheduler.

## Channels (K7b)

Channels (K7b, Kernel/Object/Channel.swift, include/ipc.h, syscalls 80-86
in User/IpcSyscalls.swift):
- Channel (4) and eventpair (16) endpoints share a `PeerShared` (lock,
  channel id = smaller koid); peers link without references and reach
  each other with `ObjectPointer.tryRetain`. Messages (bytes up to 64
  KiB, up to 64 handles) are one heap block owning a reference per
  handle; as in Zircon, write and call consume every listed handle
  whether or not they succeed (`build` takes each out of the table,
  closing the bad ones, first error wins: TRANSFER, not the channel
  itself, a repeat finds BAD_HANDLE), unless the list can't be read. Closing an endpoint
  raises PEER_CLOSED on the peer, ends calls waiting on it, and frees
  unread messages outside the lock. READABLE/WRITABLE/PEER_CLOSED are
  object signals, so waits and ports see them.
- `channel_call`: the kernel writes a txid (high bit set) into the first
  four bytes; a write whose txid matches a pending call on the peer goes
  straight to that caller. Ext 2 donation: the thread that reads a call
  becomes the owner of the caller's call-record queue
  (`Scheduler.setOwner`, refused if it would close a cycle), so K3b
  inheritance lends it the caller's profile until the reply; an exiting
  thread drops what it owns (`dropOwnership`). `channel_read` packs its
  capacities (bytes | handles << 32) and actuals.
- `ipc` trace: CHANNEL_WRITE/READ and DONATE records carry
  `croi_flow_id(channel id, txid)` (ipc.h, splitmix64 finalizer), which
  user space computes from `object_get_info(HANDLE_BASIC)` koids and the
  txid, so a call and its reply share one flow.
- Test-only syscall 6 (`TestHooks.profile`; NOT_SUPPORTED unless
  `croi.test=1` or `croi.debug_syscalls=on`, since review round 1: its
  hooks reboot, evict and sign with the kernel's key): bind to / report a deadline
  context a self-test provides, until profiles are objects.

## Futexes and timers (K7c)

Futexes and timers (K7c, Kernel/Object/Futex.swift, TimerObject.swift,
syscalls 90-97 in User/SyncSyscalls.swift):
- Futexes keyed by (address space, user address) in a 256-bucket table
  under the scheduler lock, which is the futex lock: a wait reads the
  word with `UserCopy.wordNoPageIn` (PerCpu.noPageIn: a fault goes to
  recovery; the wait drops the lock, pages it in and retries), compares
  and blocks under it. Records are allocated outside the lock and retire
  when no waiter refers to them (`users`: a woken waiter hasn't run yet
  when its waker returns), the queue is empty and nobody owns them;
  `Thread.futex` follows a waiter through requeue. Owners use K7b's
  `setOwner` (a cycle leaves the futex unowned); wake clears the owner,
  wake_single_owner hands it to the woken thread. `futex` trace records.
- Out-pointer checks (`Syscalls.check`) ask the address space whether
  writable mappings cover the range (`UserAspace.covers`): nothing is
  read or written, so any size works and a concurrent user write isn't
  clobbered; the copy out still recovers from faults. K14m: a thread
  caches the mapping its last check found (`Thread.coverStart/End`) with
  the address space's `mapGeneration` (bumped under its lock at every
  change to `mappings`), and a check inside it with the generation
  unchanged skips the lock.
- Timer objects (22): set arms the object's own timer node on the calling
  CPU, holding a reference (generation numbers ignore stale callbacks;
  cancel takes the node out of the arming CPU's queue from anywhere);
  slack windows as Zircon's center/early/late; zero slack for a
  thread on a deadline profile. Set and cancel clear SIGNALED (cancel
  too for a timer that already fired, as Zircon's). The last handle's
  close cancels (K14b: `Objects.lastHandleClosed`, Zircon's
  on_zero_handles, run from `HandleTable.close`, a freed message's
  handles and `releaseTaken`; handle_replace adds the new handle before
  closing the old so the count never passes through 0).

## Exceptions and job policy (K7d)

Exceptions and job policy (K7d, Kernel/Object/Exception.swift, task.h,
syscalls 100-107 in User/ExceptionSyscalls.swift):
- A user fault or exception (`UserTraps.offer`, typed per arch by
  `ExceptionFrame.exceptionType`) is offered to the thread's, process's,
  then each job's exception channel up the tree. The kernel keeps its
  end of each (`task_create_exception_channel`; ALREADY_BOUND while the
  user end is open); a message is croi_exception_info_t plus a handle to
  an exception object (29). The faulting thread waits (interruptibly)
  until the object's last reference goes, then: HANDLED resumes it with
  whatever `thread_write_state` put in its frame (`ThreadObject.
  exceptionFrame`, general registers only while in an exception),
  THREAD_EXIT ends it, TRY_NEXT moves on; unhandled kills the process
  (-1028). amd64 #BP's IDT gate is DPL 3 so a user int3 is a breakpoint.
- Job policy (`Policy`): an action per ZX_POL condition in each job,
  copied to child jobs at creation, settable only while the job has no
  children (ABSOLUTE refuses conflicts, RELATIVE skips them; NEW_ANY
  expands to every NEW_*). Creation syscalls check NEW_*; a BAD_HANDLE
  result checks BAD_HANDLE. KILL marks the process killed and lets the
  syscall unwind (Swift frames hold references) before the thread exits
  on its way out; *_EXCEPTION raise POLICY_ERROR first.
- Not yet: SError delivery to the faulting process. (Debugger channels
  and exception reports came in K13g.)

## Counters (K10a)

Counters, K10a (Kernel/Object/Counter.swift, User/CounterSyscalls.swift,
include/counter.h, syscalls 160-165):
- Zircon's counter (type 34; create, add, read, write; POSITIVE /
  NON_POSITIVE; add needs READ and WRITE, OUT_OF_RANGE on overflow) plus
  croi's waits at a value: `counter_wait(counter, value, deadline)` and
  `counter_wait_async(counter, port, key, value)` (one packet of type
  0x82: target, value reached, time), needing WAIT and READ.
- A value wait is an observer with a threshold (`Observer.byValue`,
  `atValue`): `Observers.notify` fires it when the counter's value
  reaches it, so registration, cancellation on handle close, port_cancel
  and port delivery are the signal waits'.
- Each thread keeps its WaitState (`Thread.waitState`, freed with the
  thread; `WaitStatePointer.forCurrentThread`), so a counter wait
  allocates only its observer; the wait reads how it ended in the same
  scheduler-lock pass that blocks. That took counter wake from ~2.5 to
  ~1.6 µs. ObjectWait still allocates a WaitState per wait.
- Budget `counter.wake_median` (m2, as port wake: counter_add's entry on
  CPU 1 to counter_wait's exit on CPU 2; limit 2 µs): KVM ~1.6 µs.
- Boot test mode 14 (`ProcessSelfTest.runCounters`).

## Display timelines (K10b)

Display timelines, K10b (Kernel/Object/Timeline.swift, include/timeline.h,
syscalls 170-173 in User/CounterSyscalls.swift; Todhchai ext 1):
- croi's object (type 48), created under the display system resource
  (base 16, croi's): a vblank count, waited on with the counter calls
  (`Counters.waitable` takes a counter or a timeline; value observers;
  `Observers.notify` asks `Counters.valueLocked` for both types).
- Driven: `timeline_advance(timeline, timestamp)` counts a vblank at the
  hardware's time. Synthetic (`CROI_TIMELINE_SYNTHETIC`, the GOP
  framebuffer): the value is base_count + (now - base_time) / period, and
  `Timelines.watchLocked` (after a value observer is added) arms one
  kernel timer, zero slack, for the earliest vblank any waiter needs; the
  firing notifies and re-arms for the next. Nothing waiting, nothing
  armed: a static screen makes no wakeups. The armed timer holds a
  reference; a generation makes a superseded one a no-op.
- `timeline_set_period` re-bases at the current vblank (the count carries
  on). `timeline_get_page`: a read-only handle to a one-page contiguous
  VMO (`sharedReadOnly`: mappings read only, cache policy fixed) holding
  croi_timeline_page_t under a seqlock (period, base count and time,
  synthesized flag), written only at creation, period changes and
  advances.
- Budget `timeline.wake_p99` (m2: the deadline thread on its own CPU
  waiting for each next vblank of a 1 ms synthetic timeline, from the
  page's vblank time; limit 100 µs): KVM median ~10 µs, p99 17-35 µs.
- Boot test mode 15 (`ProcessSelfTest.runTimelines`).

## FIFOs and executable VMOs (K13b)

FIFOs and executable VMOs, K13b (Kernel/Object/Fifo.swift; syscalls 87-89
in IpcSyscalls, 49 in Syscalls; Todhchai's block, input and GPU rings):
- Zircon's FIFO (type 19, ZX_DEFAULT_FIFO_RIGHTS): `fifo_create(count,
  size, options, out0, out1)` (count and size non-zero, count x size at
  most 4096, else OUT_OF_RANGE; NEW_FIFO policy, condition 10), each
  endpoint a heap ring of records its holder reads; a write fills the
  peer's ring. `fifo_write/read(fifo, elem_size, data, count, actual)`
  move as many whole records as fit or are there (size mismatch or count
  0 OUT_OF_RANGE; none: SHOULD_WAIT, or PEER_CLOSED with no peer and,
  for reads, nothing left). READABLE / WRITABLE (room in the peer's
  ring) / PEER_CLOSED (the peer's last close, which also clears
  WRITABLE) kept under the pair's `PeerShared` lock. User bytes go
  through a heap bounce buffer outside the lock (reads check the
  destination writable first). signal_peer and related koids cover
  FIFOs.
- `vmo_replace_as_executable(vmo, vmex, out)` (49): the vmex must be the
  VMEX system resource (base 1) or root; the new handle has the old
  rights plus EXECUTE; the old handle is gone either way (Zircon's).
- Mode 17's `fifos_and_exec`.

## Sockets (K13c)

Sockets, K13c (Kernel/Object/Socket.swift, User/SocketSyscalls.swift,
syscalls 190-193; ipc.h):
- Zircon's socket (type 14, ZX_DEFAULT_SOCKET_RIGHTS incl. MANAGE_SOCKET
  1 << 20), STREAM or DATAGRAM, the pinned tree's error orders and signal
  rules (its spec, quirks included, is in the K13c roadmap notes): writes
  fill the peer's buffer (stream: short writes; datagram: all or nothing,
  OUT_OF_RANGE above capacity); reads (PEEK; a datagram read shorter than
  the message drops the rest; size 0 consumes nothing); empty: SHOULD_WAIT,
  BAD_STATE once the peer disabled writing, PEER_CLOSED with no peer;
  set_disposition (WRITE_DISABLED / WRITE_ENABLED per side, BAD_STATE
  re-enabling before the old data is read, MANAGE_SOCKET); thresholds
  (properties 12/13, READ_THRESHOLD / WRITE_THRESHOLD); ZX_INFO_SOCKET
  (22); user signals to the peer; NEW_SOCKET policy (9).
- Receive buffers are rings of up to 64 PMM pages (256 KiB; Zircon's is
  264160), a page allocated when written and freed when drained; a
  datagram has a 4-byte length in the ring (counted against capacity).
  The pair shares a `SocketShared` with a blocking `Mutex`, so user copies
  go straight into and out of the ring (they may fault and page in);
  lock order mutex -> object.
- Mode 17's `sockets`.

## Streams (K13c)

Streams, K13c (Kernel/Object/Stream.swift, User/StreamSyscalls.swift,
syscalls 194-201; vmo.h):
- Zircon's stream (type 31; ZX_DEFAULT_STREAM_RIGHTS, READ / WRITE by
  mode, APPEND adds none; no policy) over an anonymous VMO (else
  WRONG_TYPE): create, writev/readv (at the seek, which moves under the
  stream's Mutex), writev_at/readv_at, seek (START/CURRENT/END, checked
  arithmetic), ZX_INFO_STREAM (26), ZX_PROP_STREAM_MODE_APPEND (19).
  `croi_iovec_t` (capacity uint64_t: the ABI headers have no size_t).
- The stream size (`VmoRecord.streamSize`, nil = the VMO's size):
  vmo_get_stream_size (200, no rights; 0 for non-anonymous),
  vmo_set_stream_size (201, WRITE; OUT_OF_RANGE past the VMO; zeroes from
  min(old, new) to the VMO's end), ZX_PROP_VMO_CONTENT_SIZE (17). Reads
  stop at it; writes zero-fill a gap past it and grow it by what lands;
  a write at or past the VMO's end is OUT_OF_RANGE, one reaching it cut
  short (streams never grow their VMO, as the pinned tree's don't:
  vmo_set_size does, K13h); append writes at
  the stream size. Size changes (stream writes, vmo_set_stream_size,
  vmo_set_size) hold their VMO's size lock (`Streams.withSizeLock`, as
  Zircon's per-VMO StreamSizeManager: a wait queue on the VmoRecord,
  `sizeQueue`, made on first use; review 2 replaced one global Mutex,
  which a pager wait held for every stream). A user buffer that faults ends
  a transfer short, NOT_FOUND if nothing moved. vmo_write doesn't move
  the stream size (as Zircon).
- Mode 17's `streams`.

## The small calls (K13e part 1)

The small calls, K13e part 1 (syscalls 210-215 in User/IpcSyscalls.swift,
Kernel/Object/Names.swift; ipc.h, task.h; the pinned tree's semantics):
- object_wait_many (210, croi_wait_item_t): count 0 sleeps to the deadline
  and is TIMED_OUT, over 64 OUT_OF_RANGE, a bad item writes nothing back,
  otherwise every pending is written back (OK, TIMED_OUT, CANCELED; only
  the closed handle's item gets HANDLE_CLOSED).
- handle_close_many (211): 0 skipped, bad values BAD_HANDLE with the rest
  still closed, 64 per chunk.
- port_cancel_key (212): every async wait to the port with the key,
  whatever its source, and every queued packet with it (user ones too;
  not kernel sources' or interrupts'), NOT_FOUND if none. Each port keeps
  `watched` (an object address per observer to it, under its packets
  lock; Observers.add/remove, notify, handleClosed and port_cancel keep
  it), safe because an object loses its observers before its last
  reference.
- channel_write_etc / read_etc / call_etc (213-215): croi_handle_
  disposition_t (MOVE or DUPLICATE, type 0 = any, rights reduced or
  SAME_RIGHTS, result per entry) and croi_handle_info_t, Zircon's order of
  checks (TRANSFER, not the channel itself, type, rights subset; DUPLICATE
  needs DUPLICATE); every entry processed, MOVE consumes whatever happens,
  the array copied back if any failed. channel_read(_etc) now check the
  handle first and refuse unknown options with NOT_SUPPORTED;
  CROI_CHANNEL_READ_MAY_DISCARD drops a message that doesn't fit.
- ZX_PROP_NAME (3): 32-byte names (31 + NUL) on processes, threads (BAD_
  STATE once dead), jobs, BTIs and VMOs (in the VmoRecord), resources read
  only, others WRONG_TYPE; process_create and thread_create now store
  theirs.
- Mode 17's `small_calls`.

## Info topics and vmar_op_range (K13e part 2)

Info topics and vmar_op_range, K13e part 2 (User/InfoTopics.swift,
TaskSyscalls `vmarOpRange`, syscall 76; task.h, vmo.h):
- object_get_info takes Zircon's actual and avail (fifth and sixth
  arguments, optional). Fixed-size topics: actual 1 (0 and BUFFER_TOO_
  SMALL when short), avail 1; lists fill what fits and give the total.
  Topics are matched on bits 27:0 with the version in 31:28.
- PROCESS (STARTED / EXITED, `ProcessObject.startTime`), THREAD (state
  from ThreadObject and the scheduler; a blocked thread's BLOCKED_* reason
  from the syscall in its user frame, a page fault's PAGER;
  `exceptionChannelType` while an exception is offered; affinity in
  mask[0]), THREAD_STATS (BAD_STATE once dead), TASK_RUNTIME (cpu and
  queue time: `Thread.totalRuntime` grows in `charge`, `queueTime` at
  switch-in from `readySince`; exiting threads add theirs to the process,
  dying processes and jobs to their job), JOB (return code -1024 after
  task_kill), JOB_CHILDREN / JOB_PROCESSES / PROCESS_THREADS (koids,
  ENUMERATE), VMO (no rights needed; koid kept on the VmoRecord, flags,
  committed/private/scaled bytes; V1-V3 prefixes), PROCESS_VMOS (VMO
  handles then one entry per mapping; running processes only),
  PROCESS_MAPS (aspace, then regions and mappings depth first; V1/V2
  entries), HANDLE_TABLE (INSPECT | MANAGE_PROCESS | MANAGE_THREAD;
  `HandleTable.snapshot`). Not tracked: page-fault and lock-contention
  time. (Debugger attachment: K13g.)
- vmar_op_range (76): COMMIT, DECOMMIT, MAP_RANGE, ZERO, DONT_NEED and
  ALWAYS_NEED (K14a's hints), PREFETCH; rights by op on the VMAR
  handle, then per mapping; gaps BAD_STATE; mappings of sub-VMARs only
  with OP_CHILDREN (never for COMMIT/DECOMMIT/PREFETCH). Checked whole
  under the aspace lock, then done piece by piece without it (pagers may
  be waited for); `UserAspacePointer.mapPresent` maps what the VMO has.
- Mode 17's `info_topics`.

## Clock objects (K13f)

Clock objects, K13f (Kernel/Object/ClockObject.swift, User/ClockSyscalls.swift,
syscalls 216-219 and 77; clock.h):
- Zircon's clock (type 30; rights BASIC | IO | SIGNAL | PROPERTY, MAP for
  a MAPPABLE one; no policy): clock_create (options MONOTONIC, CONTINUOUS,
  AUTO_START, BOOT, MAPPABLE; args version in bits 63:58, v1 backstop),
  clock_read, clock_get_details (v1), clock_update (v1 value / rate ppm
  +-1000 / error bound, v2 with a reference value), vmar_map_clock (77:
  read-only, one page), ZX_INFO_CLOCK_MAPPED_SIZE (40), NAME. Zircon's
  checks and rules: unstarted reads the backstop and only a value starts
  it (BAD_STATE), MONOTONIC never back, CONTINUOUS no jumps once started,
  never below the backstop; STARTED set at the start, UPDATED pulsed at
  every update (set then cleared: waits and async waits see it).
- croi's reference "ticks" are monotonic ns (the counter's 32.32 scale has
  no u32/u32 ratio): reference_ticks_to_synthetic = reference_to_
  synthetic and the details' tick fields are ns. BOOT is monotonic (no
  suspend); timer_create takes clock id BOOT (1) too.
- State is croi_clock_page_t (Zircon's mapped layout) in the object under
  its lock; a MAPPABLE clock publishes it to a one-page read-only
  contiguous VMO under `seq_lock` (generation = seq / 2, 1 when created).
  Values: b_off + floor((r - a_off) * num / den), saturating (128-bit).
  PA_CLOCK_UTC (0x40) is defined; nothing creates a UTC clock yet.
- Mode 17's `clocks`.
