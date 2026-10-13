# CPUs: locking, SMP, interrupts, time, scheduling, power

Per-CPU machinery, timers, threads and scheduling policy, idle and power control. Part of croi's design notes (index in CLAUDE.md).

## Locking

Locking (`Kernel/SpinLock.swift`): `SpinLock` masks interrupts on this CPU
while held (Zircon's SpinLock + IrqSave) and spins test-and-test-and-set;
`withLock { }` is the API (releases on throw). The lock word holds the
holder's CPU + 1, so a recursive acquire or a release by a non-holder
panics. `Cpu.current` comes from the per-CPU register. Lock order: vm ->
heap -> pmm (each calls the next with its own lock held). Locks are global `let`s
next to the global state they guard; public mutating methods of `Pmm` and
`Heap` take the lock and call `*Locked` internals. Restoring an
*enabled* interrupt state is untested until interrupt controllers exist.

## SMP

SMP (`Kernel/Smp.swift`, `include/smp.h`, `arch/<arch>/smp.S`):
- `PerCpu` records (heap, never freed) found through the per-CPU register
  (amd64 GS base, arm64 TPIDR_EL1, rv64 tp; zeroed at kernel entry);
  `Cpu.current` reads it. The boot CPU's record is installed on its
  guarded stack; rv64 learns its boot hart ID from the handoff (v2,
  RISCV_EFI_BOOT_PROTOCOL), since S-mode can't read it.
- Every other enabled MADT CPU gets a guarded KernelStack and a startup
  block (`croi_ap_startup_t`, read by physical address with the MMU off)
  and is started one at a time: rv64 SBI HSM hart_start; arm64 PSCI CPU_ON
  (SMC/HVC from the FADT boot flags; repeats the EL2->EL1 drop); amd64
  INIT-SIPI-SIPI with a real-mode trampoline copied to a low page the PMM
  set aside (`lowTrampolinePage`) and a temporary bootstrap PML4 below
  4 GiB. Trampolines turn the MMU on at a physical PC and let the next
  fetch fault into a vector/stvec that holds the continuation's virtual
  address (rv64, arm64); amd64 jumps via the bootstrap PML4's kernel half.
- Secondaries run `kernel_ap_main`: exception vectors (amd64: shared IDT;
  each CPU then installs its own GDT copy, TSS and guarded exception
  stack, `CpuStacks.installThisCpu`), self-test, then the scheduler's idle.
- Boot self-test: per-CPU identity, and all CPUs incrementing a counter
  with a non-atomic load+store under one SpinLock after a start barrier
  (verified to fail without the lock).
- Not yet: CPU hotplug. (Per-CPU TSS/IST and exception stacks, the
  calibrated INIT/SIPI delays (`Clock.delay`) and the scheduler came
  later: see Kernel stacks, Time and Threads.)

## Interrupts and TLB shootdowns (K2a)

Interrupts (`Kernel/Irq/`, K2a): `Interrupts` initializes the controllers
before secondaries start and dispatches everything `arch_exception` sees
as an interrupt. amd64: local APIC (x2APIC when CPUID says so, else xAPIC
MMIO), legacy 8259s and every IOAPIC pin masked; vectors 0xF0 IPI, 0xFE
error, 0xFF spurious. arm64: GICv3 only (QEMU runs `gic-version=3`):
distributor with all SPIs masked, per-CPU redistributor found by
affinity, SGI 0 = IPI; the ITS is found but not set up yet. rv64: IPIs
are SBI `send_ipi` (supervisor software interrupt); the PLIC takes
device interrupts (K9c), IMSIC/APLIC are only counted. Device interrupts
stay masked until an interrupt object takes them (K9c). `Ipi.callOthers(fn, arg)` runs a C function on every other
ready CPU and waits (Zircon's mp_sync_exec); waiters drain their own
mailbox, so cross-calls can't deadlock. `TlbShootdown.flushOthers` (amd64,
rv64) ends every ArchAspace unmap/protect, and map on rv64 only: amd64
caches no not-present entries, so filling a hole needs no remote flush
(K9f: the all-CPU IPI on every user page fault was most of spawn to main,
and it waits on any CPU writing the console with interrupts masked).
A user address space's unmap/protect goes only to the CPUs in its
`activeCpus` (Zircon's x86 active_cpus; `ArchAspace.owner` names the
record; set before the tables load, cleared after; the mask is read
with a locked RMW after the page-table stores, a full fence on x86):
amd64, and rv64 without ASIDs, where a CPU loading the tables later
starts with none of its entries. rv64 with ASIDs keeps entries across
switches, so it broadcasts (as Zircon's riscv64 does); arm64 broadcasts
in hardware. Kernel tables: every CPU. `TlbShootdown.received(cpu)`
counts what each CPU took; `ShootdownSelfTest` checks a reader on
another CPU faults after unmap and protect, and (where targeted) that
an idle bystander takes none of the IPIs. SpinLock restores the
caller's interrupt state while spinning, so a CPU waiting on `vmLock`
still answers the shootdown from the holder. Secondaries idle in
`arch_idle` with interrupts on; boot ends with "boot complete, idling".
The boot test checks sync calls and that a remapped page is seen by every
CPU (verified to fail without remote flushes).

## Time (K2b)

Time (`Kernel/Time/`, K2b): `Clock` gives monotonic ns from the arch
counter (amd64 TSC calibrated by CPUID 0x15 or the HPET; arm64 CNTVCT_EL0
at CNTFRQ_EL0; rv64 `time` at the RHCT timebase). Its parameters live in
a `croi_time_page_t` (include/time.h, a PMM page) that K6 maps into user
space for the vDSO: ns = ((counter - base) * mult) >> 32, 128-bit product.
`Clock.delay` is the calibrated busy wait (INIT/SIPI use it). `Timers`:
tickless per-CPU one-shot timers, `arm(deadline:slack:callback, arg)` /
`cancel`, run on the arming CPU in interrupt context. Hardware is armed
for the earliest deadline+slack; when it fires every due timer runs, so
overlapping windows coalesce and zero slack is exact. amd64 TSC-deadline
(LAPIC one-shot fallback, tested with `-cpu max,-tsc-deadline`), arm64
virtual timer (GTDT PPI), rv64 SBI set_timer. K14b: each CPU's queue is
a list by `latest` under a leaf lock (`TimerNode`s; the head arms the
hardware; `maxSlack` bounds the interrupt's walk for due timers). Kernel
code with a fixed number of timers uses the CPU's 32 slots (`arm(deadline:
...)` -> id, `cancel(id)` on that CPU); anything whose count user space
decides owns a node in its record (thread timeouts, timer objects,
timelines: `arm(node, ...)`, never fails; `cancel(node, on: cpu)` from any
CPU, false once it fired, when on another CPU its callback may still be
running). A thread whose timeout fired elsewhere as it cancelled waits
that CPU out by IPI (`timeoutStragglers`) before leaving the scheduler.
It was a 32-entry array: a 33rd thread blocking with a deadline on one CPU
panicked, a 33rd timer object was NO_RESOURCES.
QEMU TCG has no TSC-deadline mode, so amd64 TCG runs use the LAPIC
one-shot timer: its count comes from the same counter read that bounds
the deadline (a second read past it wrapped the delta and fired a due
timer 68.7 s late; the time self-test arms 200 already-due timers).
`Scheduler.dump` shows each CPU's pending timers, what the hardware is
armed for, interrupt counts, and on amd64 the dumping CPU's ISR/IRR/LVTT.
For lockups, `qemu.sh --registers-on 'ipi mailbox|PANIC'` prints every
CPU's PC and frame-pointer backtrace when the deadman dump (or a panic)
appears (`qemu-monitor.py backtrace`; symbolize with llvm-symbolizer).
Anything that frees or unmaps kernel memory may wait for TLB-shootdown
acknowledgements while holding vmLock, so it must run with interrupts on:
the idle loop reaps dead threads (freeing their stacks) with interrupts
enabled. Reaping masked deadlocked two reaping CPUs (the sched self-test
stresses it: 6 of 6 KVM boots hung before the fix).
`lib/rt/int128.c` supplies `__udivti3`/`__umodti3`, which
`dividingFullWidth` needs (there is no compiler-rt).

## Exceptions

Exceptions: `arch/<arch>/exceptions.S` saves an `arch_exception_frame_t`
(kernel.h) and calls Swift `arch_exception` (Kernel/Exceptions.swift);
the handler may edit the frame to resume elsewhere. Installed at the top
of kernel_main. amd64: IDT of 256 stubs, TSS with IST1 for NMI/#DF/#MC.
arm64: VBAR_EL1. rv64: stvec, S-mode traps only. Breakpoints resume (the
boot test checks one round trip); anything else prints a register dump to
`panicConsole` and halts via `panic()`.

## Kernel stacks

Kernel stacks (`Kernel/KernelStack.swift`, geometry in `include/stack.h`):
16 KiB from `kernelAspace`, aligned to 32 KiB, guard pages both sides;
`~Copyable`, freed on drop (`keepForever()` for permanent ones). The .bss
boot stack is only used until the VM is up: kernel_main then switches to a
guarded stack (`arch_continue_on_stack` -> `kernel_main_continue`).
Overflow is reported, not a hang: amd64 escalates to #DF on IST1; arm64
and rv64 exception entry test bit CROI_KERNEL_STACK_SHIFT of the would-be
frame address (clear on every valid stack thanks to the alignment) and
switch to a .bss emergency stack (arm64 stashes x0 in TPIDRRO_EL0, rv64
uses sscratch: both must be revisited when user mode arrives). Every stack
the CPU runs on must keep this geometry. Each CPU installs its own guarded
exception stack (`CpuStacks.installThisCpu`): amd64 gets its own GDT copy
and TSS with IST1 on it; arm64/rv64 store it in `croi_percpu_arch_t`
(stack.h), the first field of PerCpu, which exception entry reads through
TPIDR_EL1 / tp. The .bss emergency/IST stacks only cover early boot.
amd64 GDT layout is fixed for syscall/sysret: 0x08 kernel CS, 0x10 kernel
DS, 0x18 user CS32, 0x20 user DS, 0x28 user CS64, 0x30 TSS. A CPU must
have its local interrupt controller up before it maps anything (mapping
can trigger a TLB shootdown, which sends IPIs). A deliberate fault in kernel code must use a
volatile access, or LLVM may delete it (e.g. stores to const symbols).

## Threads (K3a)

Threads (K3a, Kernel/Sched/): `Scheduler.spawn` returns a `ThreadHandle`
(`~Copyable`; `join()` frees the thread, dropping it detaches). Thread
records are heap allocations reached through `ThreadPointer`; `savedSp` must
stay their first field (arch_context_switch stores through the record
address). One global scheduler lock protects all thread, run-queue and
wait-queue state. It is taken masked (`lockMasked`) and handed across the
switch: the resumed thread releases it (`finishSwitch`). Never send a
waiting IPI (`Ipi.call`) while holding it. Use `Scheduler.locked { ... }`
to check a condition and `block(on:deadline:)` without lost wakeups.
Timers belong to the CPU that armed them, so a timeout left on another CPU
is cancelled by IPI after the lock drops; a timer must never outlive its
thread. A timeout that fires while its thread is awake (woken, not yet
running) clears the thread's timer id, so a condition loop blocking again
for the same deadline arms a new one (it used to keep the fired id and
wait forever; the sched self-test forces that window). Timer ids are only unique per CPU, and a thread can resume on
another CPU after any `switchAway`: re-read `Cpu.current` after one (a
stale CPU number in the preemption loop cancelled other CPUs' timers). Preemption: a timeslice (10 ms), or a wakeup onto an idle CPU,
sets a per-CPU request that is acted on when an interrupt returns.
Interrupt frames don't restore the per-CPU register (rv64 `tp` is skipped),
because a preempted thread can resume on another CPU. Queues are ordered
by `Thread.queueKey` (`QueueHead`). Leaving `locked` with interrupts on
is a preemption point. Load balancing (Zircon's idle-time work stealing):
a CPU about to switch to idle, and an idle CPU each time it wakes, takes
the first waiting fair thread it may run (affinity, reservation; not one
admitted to a CPU) from the CPU with the most fair threads waiting
(`Scheduler.steal`; its vruntime lag carried over as at a wakeup;
`steals` counts them, a MIGRATE trace record each); queued threads are
always switched out (the lock is held across a switch), so any may move.
The sched self-test pins two spinners to one CPU, frees them, and has
another CPU go idle: it must take one. Fixed on the way: a ready thread
`requeue` must move (its CPU now reserved for another job, its affinity
changed) kept the old CPU's vruntime instead of its lag rebased onto the
new CPU's minimum; arriving from a CPU it had to itself it waited ~300 ms
behind the new CPU's threads (the EDF self-test's reservation part, once
stealing made it likelier). A wakeup aimed at the local
CPU only sets a request bit, so the idle loop and `preemptIfRequested`
recheck after every switch (`finishSwitch` can make a thread ready here).

## Policy (K3c)

Policy (K3c, Zircon's two disciplines; Sched/Profile.swift): a thread's
`Profile` is fair (weight; priorities 0...31 map through Zircon's table)
or deadline (`DeadlineParams`: capacity of reference-core work within
deadline, every period). Per CPU: a fair queue by virtual runtime (ns x
1024 / weight; slice = 16 ms target latency x weight share, >= 0.75 ms;
tickless when alone), a deadline queue by absolute deadline (always
first), and a throttled queue of reservations waiting for their next
period (an eligibility timer). Deadline budgets are charged in
capacity-scaled time and enforced by the slice timer; running out counts
an overrun on the context (ext 3 hook); `yield()` ends a deadline
thread's period. CBS rule on wakeup. Scheduling contexts
(`SchedContext`, ~Copyable owner of a `SchedContextRecord`) are separate
from threads: a fair weight, or a deadline reservation admitted by
`Scheduler.admit` on one CPU (biggest capacity that fits under 85%), with
`AdmissionRefusal` reasons and a per-user `SchedAccount` budget (ext 4);
admitted threads never migrate. CPU capacity defaults from the core type
(`CoreCapacity`, biggest = 1024), overridable by `setCapacity` (the power
service's call). `reserve(cpu:tag:)` (ext 8). Each CPU publishes
`powerHints` (wake-latency bound, frequency floor) for KP. `frame` intent
(ext 10) is stored only.

## Priority inheritance (K3b)

Priority inheritance (K3b, with K3c's profiles): a `QueueHead` with an
`owner` is an owned wait queue. Its waiters lend their effective profile to
the owner and on down the chain (`updateEffectiveProfile`), by Zircon's
rules: fair weights add; deadline utilizations add with the tightest
deadline, and turn a fair owner into a deadline one. `Mutex` (Thread.swift) is the
kernel's blocking lock on one: unlock hands it to the highest-priority
waiter, and recursion or a deadlock cycle panics (K7's futex will refuse
the owner instead, as Zircon does). A thread may not exit holding one.
`Scheduler.dump` prints every CPU and thread (all are on `allThreads`);
the boot self-tests arm a 20 s deadman that calls it.

## Thread pins

Thread pins (review round 1): code that reads a thread object's `thread`
under its lock and uses it after (futex owners, object_set_profile,
overrun ports, timeline alignment) takes `Processes.pinnedThread`, which
pins the record (`Scheduler.pin`, under the object lock: exit clears
`thread` under it first); the reaper leaves a pinned zombie to the last
`unpin`. `dropOwnership` marks the thread `exiting`, and `setOwner`
refuses exiting or dead owners and (futex waits) a chain through the
waiter itself (`adding:`): two waits naming each other looped inheritance
into a panic. `Thread.enteredUser` (set just before `arch_enter_user`)
gates register access to a suspended thread: one parked in
`UserTraps.enter` has only kernel frames at its stack top (BAD_STATE).

## Extended register state (K3d)

Extended register state (K3d, Sched/ExtendedState.swift, include/xstate.h):
measured on every CPU at boot (IPI call), the shared subset kept (user
threads migrate): amd64 CPUID 0xD (standard-format XSAVE size; AMX tile
data lazy behind XFD), arm64 FP/SIMD, SVE and SME vector lengths
(rdvl/rdsvl with CPACR traps lifted only for the probe; every CPU's
ZCR_EL1/SMCR_EL1 then set to the smallest), rv64 F/D/V from the RHCT
plus `vlenb`. `eagerSize` bytes per user thread (saved each switch) +
`lazySize` on first use (AMX tiles, SME ZA/streaming state).
`spawn(extendedState: true)` allocates the area; kernel threads have
none and never touch FP. The save/restore code is K6's. The arm64 EL2
drop sets CPTR_EL2 from the ID registers (TZ/TSM are traps where SVE/SME
exist, RES1 otherwise: 0x33ff trapped both) and opens ZCR_EL2/SMCR_EL2.

## Deadline-carrying wakeups (K10c)

Deadline-carrying wakeups, K10c (Todhchai ext 5 and 10; profile.h):
- `object_set_profile(target, profile, options, refusal, timeline)`: on an
  interrupt, counter or timeline (WRITE; deadline profiles only, no
  options) the object stores the profile (`lend`), and `Observers.notify`
  / `InterruptObjects` wake through `Scheduler.wakeAll(queue, lending:)`:
  the woken thread's `Thread.lent` joins its effective profile as an
  inherited one (computeEffective), with a period starting at the
  wakeup, and `block` drops it. Not admitted, as channel_call donation
  isn't. A thread that sees the event before it blocks borrows nothing.
- `CROI_PROFILE_ALIGN_TIMELINE` on a thread with a deadline profile
  (BAD_STATE without one): its context keeps the timeline (a reference)
  and its page address; `startPeriod`/`nextPeriod` read the page under
  its seqlock (`vblankGrid`) and start periods on vblanks, only while
  the thread runs on its own context's parameters. The current period is
  re-aligned at once. `SchedContextRecord.intent` is still stored only.
- Test hooks 3/4 (syscall 6) return the running thread's period start
  and deadline. Boot test mode 16 (`ProcessSelfTest.runDeadlineWakeups`).
- Ext 5 proper, K14e (profile.h `CROI_PROFILE_HANDOFF`): object_set_profile
  on an interrupt with that option admits the deadline profile as a
  context the object owns (`InterruptObject.context`; refusals as for
  threads, `Profiles.admit`). `signal` wakes through
  `Scheduler.wakeAll(queue, handingOff:)`: `borrow` makes it the woken
  thread's `context` (its own kept in `homeContext`, its own period and
  budget in `home*`), so placement (the context's CPU), stealing (admitted
  threads stay) and overrun counting follow it. The context keeps the
  period and budget across wakeups (`handoff*`, written back by
  `giveBack`; `makeReady` applies the CBS rule), so wakeups share one
  budget; a wakeup while it is spent wakes the thread on its own. The
  borrow ends when the thread blocks, when the budget runs out (`requeue`:
  an overrun on the context, then its own profile, not throttling), at
  exit, when its own profile changes, or when the context is replaced or
  the object destroyed (`Scheduler.withdraw`, then destroyed). One
  borrower at a time (`borrower`). thread_bind_overrun_port takes the
  interrupt (WRITE) for its context's overruns. A lend replaces a handoff
  and vice versa. Test hook 10 is the borrowed context's CPU or -1
  (syscall 6 sends only ops 6-9 to the reclaim hooks now).

## Kernel-only extensions reaching user space (K10d)

Kernel-only extensions reaching user space, K10d (task.h, profile.h,
log.h; Todhchai ext 3 and 8, its trace export):
- `thread_bind_overrun_port` (122; MANAGE_THREAD, port WRITE): the
  thread's own deadline context (`profileContext`, from
  object_set_profile; else BAD_STATE) gets a PacketSource of type 0x80
  (payload[1] total overruns, [2] since last read), swapped under the
  scheduler lock so the context's deinit retires whichever is bound.
  Overruns count only while the thread runs on its context's own profile
  (not a lent or inherited one).
- `job_set_cpu_reservation` (108; SET_POLICY on the job, CPU system
  resource base 4 or root): `Scheduler.setReservation` reserves the
  mask's CPUs for tag = the job's koid, all or nothing (boot CPU
  INVALID_ARGS, another tag's CPU ALREADY_BOUND, other tags' deadline
  contexts admitted there NO_RESOURCES), only while the job has no
  children and no inherited tag (BAD_STATE). Child jobs and processes
  copy the tag at creation, threads get it at spawn (`Thread.reservation`;
  a context's own tag wins in `tag`), deadline contexts are admitted with
  it. Mask 0 or the job's destruction releases. `interrupt_set_affinity`
  skips CPUs reserved for another tag (`mayRoute`); interrupts routed
  before a reservation stay where they are.
- object_get_info CROI_INFO_THREAD_TRACE (0x10001, INSPECT): task << 12
  | index, as trace records name the thread. CROI_INFO_DEBUGLOG (0x10002,
  any log handle): records written and records the dumper has finished
  (`DebugLog.printed`, stored after the console write).
- Test hook 5 (syscall 6) returns the current CPU. Boot test mode 17
  (`ProcessSelfTest.runExtensions`; child submode 9 reports its CPUs).
- Fixed on the way (since K8c): `Syscalls.dispatch` called
  `preemptIfRequested` with interrupts on, so a thread could read its CPU,
  be preempted and moved, and take the scheduler lock in the old CPU's
  name (rv64: "released by a CPU that doesn't hold it", ~2 boots in 3
  with mode 17). It masks interrupts itself now, and `lockMasked` panics
  if called with them on. A retiring PacketSource takes its queued packet
  back out of the port (`Ports.unqueue`); it used to wait for a reader
  that might never come, keeping the port alive.

## Deadline-aware idle (K15c)

Deadline-aware idle, K15c (Kernel/Sched/Idle.swift, include/power.h,
syscall 245; Todhchai ext 11):
- `cpu_set_idle_states(resource, cpu, croi_idle_state_t *, count)`: the
  POWER system resource (base 5) or root; up to 8 states, exit latencies
  non-decreasing, known flags only, a method this CPU has (HALT; MWAIT
  with a hint, amd64 with CPUID MONITOR; PSCI CPU_SUSPEND with a power
  state, arm64 with PSCI), else INVALID_ARGS / NOT_SUPPORTED; count 0
  removes the table. The table (heap, `PerCpu.idleTable`) is swapped under
  `Idle.lock` and the CPU, if idle, kicked to choose again.
- `Idle.enter` (the idle loop's halt, after `Timers.settle`): the deepest
  state whose target residency is at most the time to the CPU's next
  timer (`Timers.nextLatest`) and whose exit latency is at most its
  wake-latency bound (`Scheduler.wakeLatencyBound`); states with
  TIMER_STOPS or CONTEXT_LOST are skipped (no always-on wake timer or
  context save yet), too-slow ones demoted, each counted; none fits: a
  plain halt. Entries are counted at entry, residency at exit. amd64
  MWAIT is `sti; mwait; cli` (as the halt; QEMU TCG raises #GP for ECX
  bit 0, the masked break event).
- The bound: admitted deadline contexts on the CPU, and (K15c) interrupt
  objects with a deadline profile lent or handed off, at the CPU they are
  routed to (`Scheduler.setInterruptLatency`, from
  `InterruptObjects.latencyChanged`: set_profile, set_affinity, destroy).
  A changed bound kicks an idle CPU.
- object_get_info(INFO resource or root, CROI_INFO_CPU_IDLE_STATES =
  0x10005): croi_idle_state_stats_t per CPU and state (entries,
  residency, demoted, skipped), then one with state DEFAULT for plain
  halts; actual/avail as list topics.
- Mode 17's checks 729-736 (refusals; a deep state entered, a
  TIMER_STOPS one skipped; an interrupt's deadline profile demoting CPU 0
  until it closes; MWAIT where the CPU has it, PSCI standby on arm64).

## An idle machine makes no wakeups (K10f)

An idle machine makes no wakeups, K10f (M4: 0 per second;
resource.h CROI_INFO_CPU_STATS, Smp.swift `CpuStats`):
- object_get_info(INFO resource or root, CROI_INFO_CPU_STATS = 16):
  Zircon's zx_info_cpu_stats_t per CPU, as many as fit, returning the
  count (no actual/avail pointers). Filled: idle_time, context_switches,
  yields, ints (other interrupts), timer_ints, timers (callbacks),
  syscalls, reschedule_ipis, generic_ipis (counted per IPI interrupt).
- m2's last measurement: wait until the dumper has printed everything
  (CROI_INFO_DEBUGLOG), fault in both stats buffers, sleep 500 ms (up
  to three windows, the quietest kept: a periodic wakeup shows in each,
  a straggler a loaded TCG host ran late in one), and
  report every interrupt any CPU took less its own wake as budget
  `idle.wakeups` (unit count, limit 1, always enforced: not a timing).
  Its line shows per-CPU counts by kind for diagnosis.
- What used to wake an idle CPU: `Timers.cancel` leaves the hardware
  armed (hot path), so `Timers.settle()` re-arms for the earliest timer
  still pending (or disarms) on idle entry, before the idle poll, which
  takes interrupts; the sampler's tick lapsed once per idle stretch (and
  after a stop), now cancelled on a switch to idle; deadline-to-counter
  conversion rounded down (rv64's 10 MHz timebase fired up to a tick
  early, then re-armed), now up; the self-test deadman stays armed 20 s
  (disarmed when the self-tests end); a page fault in the window
  broadcasts a shootdown on rv64 (m2 faults its buffers in first).
- Found on the way: a synthetic timeline's value is the clock's, so a
  vblank could pass between counter_wait's check and `watchLocked`,
  which then saw the waiter's value reached and armed nothing: the
  waiter slept until its deadline (m2 on rv64 under host load, ~1 boot
  in 5). `watchLocked` now notifies observers already satisfied.
- Early timer interrupts (each re-arm was a second wakeup): under KVM a
  TSC deadline becomes a host timer on the host's NTP-disciplined clock,
  ~28-34 ppm ahead of our TSC time here (a 60 s sleep came ~1.7 ms
  early). On amd64 under a hypervisor the skew is measured against the
  HPET (which runs on the host's clock) when a deadline 1 s or more out
  is armed and the baseline from boot has doubled; `Timers.leadPpm`
  (shared) arms long deadlines that much later, and an interrupt that
  still comes early raises it. One that comes at most 1 ms early
  (`Timers.earlyTolerance`) waits for the deadline. Timers never run
  early; a long one may run a few ppm late. The TSC frequency comes
  from kvmclock's scale when KVM offers it (no 10 ms HPET loop at boot),
  or a hypervisor leaf 0x40000010. Settled again right before the
  halt (an idle thread switched away mid-poll resumes past the first).
- The hardware is never armed further out than `Timers.maxDistance`
  (2^40 ns, ~18 min; one wakeup per cap for a far timer): KVM converts a
  TSC deadline to host ns in 64 bits (delta x 10^6 / tsc_khz), which
  wraps past ~6000 s, and futex waits with a deadline 146 years out ran
  ~2000x slower under KVM (Todhchai's pthread test: 39 s and a hang).
  The time self-test checks the cap; mode 17's check 620 runs a
  contended futex lock with both kinds of deadline.
- Left: the SBSA watchdog's refresh, now every 20-25 s with slack
  (`croi.watchdog=off` removes it; QEMU has none). The debuglog dumper,
  timeline ticks and idle polling were already event-driven.

## Power control (K10e)

Power control, K10e (Kernel/Power.swift, include/power.h, syscall 180;
Todhchai M4's shutdown):
- `system_powerctl(resource, cmd, arg)`: Zircon's commands and
  zx_system_powerctl_arg_t, under the power system resource (base 5) or
  root. SHUTDOWN / REBOOT / ACPI_TRANSITION_S_STATE(S5) check that the
  machine can, then give the debuglog up to 100 ms to reach the console,
  halt the other CPUs (`Ipi.stopOthers`, a mailbox kind that halts
  masked), print `croi kernel: powering off` / `rebooting` and budget
  `power.shutdown_kernel` / `power.reboot_kernel` (syscall entry to the
  hardware write, less the console wait: KVM ~20-180 µs, limit 10 ms)
  and `power.log_drain` (the wait itself: KVM ~25 ms of m2's last lines,
  a serial byte per VM exit), and act; failure after that halts.
  At the drain's end the dumper is made quiet (it stops at a line's end,
  so no CPU is halted holding the console), the UART is drained
  (`Uart.drain`: an emulator drops what it still holds at power off), and
  the hardware is asked twice, a second apart, before "didn't act".
- `croi.kill_watch=1` (lockup reports): 1 s after a task_kill of a
  process, a kernel thread holding it prints its threads,
  `Scheduler.dump` (with eligibility timers, period starts, kill marks)
  and, from each CPU running one of its threads, where it was
  interrupted plus a frame-pointer backtrace, and for each live thread
  the syscall it entered by and (amd64) its switched-out kernel frames
  (`Ipi.requestReport`, a
  mailbox kind that doesn't wait; addresses as they are, for
  llvm-symbolizer) if it isn't dead. It holds the process that second,
  so self-tests' leak checks see it later.
- Deadlines at or past INT64_MAX (Zircon's ZX_TIME_INFINITE) arm no
  timer in `Scheduler.block`; each used to hold a timer-queue slot. Everything else
  (suspend, hotplug, PL1, bootloader/recovery) is NOT_SUPPORTED.
- amd64: no SHUTDOWN (NOT_SUPPORTED): user space passes \_S5's sleep
  types (ACPI_TRANSITION_S_STATE, target 5), written to PM1a/b control
  (SLP_TYP, then SLP_EN) or the hardware-reduced sleep control register;
  system I/O registers only. Reboot: FADT reset register, then 0xCF9,
  then the 8042. arm64: PSCI SYSTEM_OFF / SYSTEM_RESET (FADT conduit).
  rv64: SBI SRST, legacy shutdown as fallback.
- `userboot.shutdown=poweroff|reboot` (user/userboot/Power.swift): after
  its program exits, userboot powers off or resets (it keeps duplicates
  of the root resource and boot data for it; on amd64 it finds `\_S5`
  by scanning the DSDT bytes, no AML). The build's cmdline has
  `CROI_USERBOOT_SHUTDOWN` (default poweroff), so boot tests pass
  `qemu.sh --exits`: after the expected line QEMU must exit by itself
  (boot-smoke doesn't: its screendump is taken at that line).
  `boot-reboot` (lean) expects the reset; test runs use -no-reboot.
  With --screendump, qemu.sh adds `-action shutdown=pause` so the screen
  can still be read after the guest powers off.
  bench.py passes --exits to trees that support it and records the budget.
- Boot test mode 17 checks the refusals (and, since K10f, kills a
  process with threads in port, counter and event waits plus a spinner
  30 times, each TERMINATED within 500 ms).

## Trace

Trace (Kernel/Trace/, include/trace.h; roadmap "Trace", K3 part):
per-CPU rings (header page + power-of-two records of 32 bytes,
`croi_trace_record_t`: raw counter time, kind, CPU, thread trace id
`task << 12 | thread`, two words), written only by their own CPU with
interrupts masked, no lock; oneshot (drop + count) or circular. Probes are
`Trace.event(category, kind, a, b)`, inlined: the mask
(`croi_trace_mask`, a C global in kernel/trace.c because Swift globals
initialize lazily and would add a guard) is one relaxed load and a branch;
arguments are evaluated only when on. `stop()` clears the mask and waits
for each CPU's `traceWriting` flag (seq_cst on both sides, no IPI).
Categories now: `sched` (switch, wake with the waker, block, preempt with a
reason, migrate, overrun) and `irq` (enter/exit). The self-test reports
an enabled event's cost (budget `trace.probe_enabled`, limit 30 ns,
enforced as "Timing discipline" says; `Budgets.timingIsReal` is the
CPUID check), ~18 ns under KVM. amd64 `arch_percpu` is a %gs-relative load of the
record's `self` field (CROI_PERCPU_SELF), not rdmsr; GS points at a
zeroed dummy record until a CPU has its own.
