# User mode, programs and boot-time user space

Entering and leaving user mode, the vDSO, user FP/SIMD, sampling and the PMU, program loading, userboot and m2. Part of croi's design notes (index in CLAUDE.md).

## User mode (K6)

User mode (K6a, Kernel/User/, include/user.h): a user thread's registers
are an arch_exception_frame_t at the top of its kernel stack while it is in
the kernel; `UserTraps.enter` (setAspace, `Scheduler.setKernelStack`,
`arch_enter_user`) drops to user mode, and traps/syscalls/interrupts come
back through `arch_exception` (`ExceptionFrame.fromUser`) to
`UserTraps.handle`: interrupts preempt as usual, syscalls go to
`Syscalls.dispatch` (interrupts on), user page faults resolve through the
VM or kill the thread, anything else kills it (exit codes
`killedByFault`/`killedByException` until K7's exception channels).
switchAway keeps PerCpu `kernel_sp` (and the amd64 TSS RSP0) at the next
thread's stack top.
- amd64: swapgs on every user entry/exit (in the kernel GS_BASE is the
  PerCpu, KERNEL_GS_BASE the user's); SYSCALL (LSTAR `syscall_entry`,
  number in rax, args rdi rsi rdx r10 r8 r9) builds the same frame
  (vector 0x100) and returns with sysretq (the rip is SYSCALL's, so
  canonical); STAR/FMASK in `arch_syscall_init`, per CPU.
  `arch_syscall` runs `UserTraps.leaving()` after the dispatch, as every
  other way back to user mode does (it didn't: a killed thread retrying
  failing syscalls ran on until an interrupt caught it in user mode).
- arm64: EL0 vectors (slots 8-15) skip the overflow check and save/restore
  SP_EL0; SP_EL1 is the stack top because user frames sit there; svc #0
  with the number in x16 (Zircon's); TPIDRRO_EL0 is kernel scratch and 0
  for user mode. IRQs from EL0 are slot 9.
- rv64: sscratch is 0 in S-mode (set in arch_init_exceptions: firmware
  leaves anything) and the PerCpu in U-mode; the entry swaps it with tp
  to tell the origins apart; ecall with the number in a7.
- `arch_copy_from_user`/`to_user`: byte loops listed in .croi_fixups
  (arm64 ldtrb/sttrb; rv64 with SUM).
- K6b: user-access protection on every CPU (`arch_user_protection_enable`,
  `croi_user_protection`): amd64 SMEP + SMAP (stac/clac in the accessors
  and `arch_user_access_begin/end`), arm64 PAN set on every kernel entry
  (SPAN clear; accessors use ldtr/sttr, which PAN doesn't block), rv64 SUM
  only inside the accessors. A fault the protection caused
  (`ExceptionFrame.userAccessBlocked`) goes straight to recovery.
  Syscalls touch user memory only through `UserCopy`, which checks the
  user range first: the arch copies don't, and on amd64/rv64 would write
  kernel pages through a pointer user space chose (a test caught it).
  The object syscalls (user/include/croi/syscall.h: handles, signals,
  waits, events, ports, VMOs, vmo_map until VMARs, trace_configure) use
  the thread's `handleTable` (K7: the process's). `syscall` trace
  category (enter/exit). User programs: `user/` is built with user flags
  (CMake custom command, static at the address the kernel maps it) and
  included with `.incbin` (kernel/userprogram.S).
- K6c: shared read-only pages (include/shared.h, Kernel/User/Vdso.swift):
  the time page, a topology page and a power page (ext 9), each with a
  seqlock sequence (`SharedPages.write` bumps it odd/even); the scheduler
  republishes a CPU's capacity and power hints when they change
  (`publishPowerHints`, outside its lock). The vDSO (user/vdso: header
  with function offsets at byte 0, code, then the three pages, all
  reached PC-relatively) is mapped by `Vdso.map` into a region of its
  own: code read/execute, pages read only (`Vmo(sharedKernelPage:)`, the
  only RAM a physical VMO may cover, never writable). User counter
  access per CPU (`arch_user_counter_enable`: arm64 CNTKCTL_EL1.EL0VCTEN,
  rv64 scounteren.TM). User binaries come from `croi_user_binary`
  (cmake/CroiUser.cmake) with `CROI_USER_CFLAGS` (cmake/arch).
- K6d: user FP/SIMD. Every user thread gets an ExtendedState area at
  `UserTraps.enter`; `Scheduler` saves the outgoing and restores the
  incoming thread's state at each switch (`arch_xstate_save/restore`,
  arch cpu.S; kernel threads have none, and the kernel never uses FP, so
  traps and syscalls don't save it). `croi_xstate_config` picks the
  format: amd64 XSAVE with XCR0 = the shared features less PKRU (the
  scheduler switches it) and AMX tiles; arm64 Neon, or SVE Z/P/FFR at the
  boot vector length; rv64 F/D, plus V at vlenb (sstatus FS/VS on for
  user threads). Not yet: lazy AMX via XFD, SME/streaming mode (trapped),
  per-thread SVE vector length. User code is built for the baseline ISA
  with FP/SIMD (`CROI_USER_CFLAGS`: x86-64, Armv8, rv64gc; SVE, V and
  AVX are run-time options); amd64 `_start` realigns its stack.
- K6e, sampling (Kernel/Trace/Sampler.swift): with CROI_TRACE_SAMPLE on,
  each CPU running a thread samples it every 1/sample_hz (trace_configure
  start's sixth argument, default 1 kHz): a SAMPLE record (PC, frame
  count, source) and FRAMES records (two return addresses each, up to
  16), consecutive in the ring. Kernel addresses are image offsets with
  CROI_SAMPLE_KERNEL set. Frame-pointer walks: kernel frames only inside
  the interrupted 32 KiB stack block; user frames via `UserCopy`, and a
  thread sampled in a syscall continues into its user frames (the frame
  at its kernel stack top). Any fixup fault in interrupt context goes
  straight to recovery (`PerCpu.interruptFrame`, set by
  `Interrupts.handle`), so nothing pages in from an interrupt. The
  sampling timer is armed at a switch to a thread and lapses on a tick
  that finds the CPU idle, so idle CPUs stay tickless. Kernel and user
  code keep frame pointers; amd64 user `_start` is a crt-style stub that
  calls C (a C entry with a 16-aligned stack misaligns rbp).
- K6e, PMU (Kernel/Trace/Pmu.swift, include/pmu.h, syscall 51
  pmu_configure): per-thread counters (up to 4 generic or raw events;
  `Thread.pmu`, stopped and accumulated at switch-out, restarted at
  switch-in) and overflow sampling into the same SAMPLE records (source
  1 + generic event) with the tracing resource. The sampling counter is
  stopped while a CPU idles. amd64: Intel architectural PerfMon (CPUID
  0xA, full-width writes) or AMD core counters (PerfCtrExtCore, PerfMonV2
  global control), LVTPC vector 0xF8 (not NMI: masked code isn't
  sampled); arm64 PMUv3 (overflow PPI from the GICC's performance GSIV,
  offset 20); rv64 SBI PMU (counters chosen per event by the SBI) with
  Sscofpmf's LCOFI (interrupt 13) when the RHCT lists it. QEMU TCG amd64
  has no PMU; KVM on this AMD host covers the AMD backend; the Intel
  backend is unverified until it runs on an Intel machine. QEMU arm64
  counts instructions only with icount, so its tests use cycles.
- User threads killed by a fault or exception are logged (cause and PC)
  until K7's exception channels report them.
- The boot test runs `usertest.S` (per arch) from a VMO: registers kept
  across syscalls, a message, a fault and a privileged instruction killed,
  preemption of user code; it reports the null syscall time (KVM: ~40 ns).

## Debuglog and user programs (K8a)

Debuglog and user programs (K8a, Kernel/Object/DebugLog.swift,
Kernel/User/ProgramLoader.swift, include/log.h, include/processargs.h,
syscalls 110-112):
- `DebugLog`: one ring of 512 fixed 256-byte croi_log_record_t slots
  (oldest overwritten), Zircon's record layout. Log objects (type 12):
  write-only ones need no resource, READABLE ones the debuglog system
  resource (base 12) or root; each reader has its own position (starts at
  the oldest record) and READABLE while behind. A `dlog-dumper` thread
  prints every record as `[sssss.mmm] pid:tid> text`. Lock order:
  debuglog -> object -> scheduler.
- Console: `ConsoleLock` serializes `Uart.write` calls between CPUs
  (recursive holders pass, waiters give up after 10^8 spins so a panic
  can't hang); the dumper's `writeLines` waits up to 50 ms for another
  CPU to finish a line it is writing in pieces.
- `ProgramLoader.start`: an ET_EXEC from kernel memory into a new process
  (each PT_LOAD copied into its own VMO, stack of PT_GNU_STACK's size or
  256 KiB) and a bootstrap channel whose first message is Zircon's
  processargs: PROC_SELF, THREAD_SELF, VMAR_ROOT, then the caller's
  handles (PA_FD 1 = stdout debuglog, PA_RESOURCE, ...), argv[0], the
  environment. PT_GNU_RELRO's pages are read only once relocated (K14c).
  Static PIEs load at a random base (K11b).
- User programs (`croi_user_program` in cmake/CroiUser.cmake): C and/or
  Embedded Swift, linked at 0x1000000 with separate page-aligned
  segments, against the user runtime (user/lib/runtime, C: `_start` reads
  the bootstrap message, `croi_take_startup_handle`, stdout line-buffered
  into debuglog records, a size-class heap over 64 KiB VMO chunks in the
  root VMAR, plus lib/rt). Swift user code imports `CroiRuntime`
  (user/include/module.modulemap); the ABI headers it reaches are module
  `CroiAbi` in kernel/include (which CKernel re-exports through abi.h), so
  user code never builds the kernel's private headers. User Swift isn't
  bound by the kernel's no-ARC rule (low-half addresses). The boot test
  runs user/test/swift: stdout, heap, environment, debuglog round trip.

## bootfs and userboot (K8b)

bootfs and userboot (K8b, Kernel/User/Userboot.swift, user/userboot,
tools/mkbootfs.py):
- bootfs.img is Zircon's bootfs format (no ZBI around it), built by
  `tools/mkbootfs.py` from the `bootfs` target (today `bin/m2`). The
  kernel adopts the loader's CROI_MEM_BOOTFS pages into an anonymous VMO
  (`Vmo(adopting:)`, `Pmm.adopt`: wired -> vmo; freed when the VMO goes).
- After "boot complete" the kernel starts userboot (an ELF in the kernel
  image, Embedded Swift, compiling lib/elf's source in) with
  `ProgramLoader`: root job, root resource, bootfs VMO (with EXECUTE),
  a stdout debuglog, and the command line's words as its environment
  (`BootOptions.withEnvironment`).
- userboot maps bootfs, finds `userboot.next=` (default bin/launcher;
  the build appends `userboot.next=${CROI_USERBOOT_NEXT}`, default
  bin/m2, to the ESP cmdline), loads its ELF into a new process
  (segments that are all file mapped straight from the bootfs VMO, others
  copied; stack from PT_GNU_STACK), passes on every handle it got plus a
  new stdout in a processargs message, starts it, waits, and prints
  `userboot: <name> exited with <code>`. Boot tests wait for that line
  with code 0 (`CROI_BOOT_DONE`).
- Syscalls added for it: `vmo_get_size` (44) and object_get_info
  CROI_INFO_VMAR (base, length). Embedded Swift `String ==` needs the
  Unicode tables (not linked): compare bytes.

## The M2 exit test and budgets (K8c)

The M2 exit test and budgets (K8c, user/m2, Kernel/Object/ProfileObject.swift,
include/profile.h):
- `bin/m2` is userboot.next (CROI_USERBOOT_NEXT): channel pair, a VMO
  passed across, a port wait with a deadline timer, debuglog output; then
  it measures the budgets from the trace (user marks via TRACE_OP_RINGS, 4:
  each CPU's ring as a read/map-only VMO) and reports them as `budget`
  lines (K9f: enforced only with `croi.enforce_budgets=1` where
  `croi_timing_is_real()`, user/lib/runtime/timing.c; see "Timing
  discipline"). KVM: null 32-36 ns,
  channel_call ~1.4 µs (target 1 µs, enforced against 1.6 µs for now),
  port wake median ~1.75 µs (p99 noisy, not enforced), wake error p99
  27-46 µs. Measure wake error with `Sys.now()` directly: converting trace
  counter time from an anchor mark was off by up to 170 µs.
- Profile objects (25): `profile_create` (120, profile system resource
  base 10 or root; zx_profile_info_t), `object_set_profile` (121: MANAGE_THREAD on
  the thread, APPLY_PROFILE on the profile), refusal reasons (ext 4) in an out-parameter.
  Test-only syscall 6 is still used by the kernel self-test.
- Under a hypervisor an idle CPU polls for `croi.idle_poll_us` (default
  200, 0 on hardware) before halting, announced in `pollingCpus`, so a
  cross-core wake skips the IPI (and its VM exits).
- `m2.ipc_profile=1` on the command line (K14l): after the channel_call
  batches m2 traces 200 more with syscall, scheduler and IPC records (and
  any kernel `CROI_TK_MARK` probes added while chasing something) and
  prints a call's events with the median gap before each, then samples PCs
  at 10 kHz over 300,000 calls and prints the top ones (kernel ones as
  image offsets with bit 63 set; samples land where interrupts come back
  on, so masked stretches show at their end).
- `m2.wake_profile=1` (K14n): one fair thread, then four, timing out on a
  port every 5 ms (Todhchai's executor), printed as lateness (deadline to
  user space by the vDSO clock) split into the timer interrupt arriving
  late and the kernel's interrupt-to-user path, plus a few wakes' records.
- `m2.portwake_profile=1` (K14o): the port wake bench again, traced,
  each wake's records from both CPUs merged in time (signal entry to
  port_wait exit), median gap before each.
- Timed wakes under KVM (K14n): every VM exit cost ~4-5 us on this host.
  `LocalApic.endOfInterrupt` uses KVM's PV EOI where offered (per-CPU
  words in one page, MSR 0x4B564D04; `croi.pv_eoi=off`), testing and
  clearing the bit in one instruction (`arch_test_and_clear_bit0`, btr):
  KVM may clear it at the exit it takes for a newly pending interrupt, and
  a separate test and clear skipped the needed EOI write, leaving the
  vector in service (half the full KVM boots hung). An x86 timer interrupt
  no longer disarms the spent TSC deadline. Under a hypervisor the timer
  hardware is armed early by `Timers.wakeLead` (a running average of how
  late interrupts came after the armed time, capped at 50 us;
  `croi.timer_lead=off`) and the interrupt waits out the rest, so timers
  still never run early. A fair thread's 5 ms port_wait timeout: ~3-6 us
  late (median), from 15-40.
- Hot-path notes from the budget work: `Scheduler.locked` drops the lock
  through `cancelTimeout` (one round trip); `Timers.arm` writes the
  hardware only for a sooner timer and `cancel` leaves it armed (the
  invariant: armed no later than the earliest pending `latest`; the
  interrupt re-arms via `program`); amd64 saves with XSAVEOPT; the heap's
  double-free walk runs only for an object still poisoned;
  `UserAspace.covers` binary-searches; `ObjectWait.one` returns at once
  if the signals are already set. Channel and port default rights are
  Zircon's (no DUPLICATE; ports no WAIT). -O was worse than -Osize.
