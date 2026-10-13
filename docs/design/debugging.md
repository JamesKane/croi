# Debugging user processes

Suspension, process memory, debugger exception channels, single-step and hardware breakpoints. Part of croi's design notes (index in CLAUDE.md).

## Suspension and process memory (K13g part 1)

Suspension and process memory, K13g part 1 (Kernel/Object/Debug.swift,
User/DebugSyscalls.swift, syscalls 230-232; task.h):
- task_suspend (232; Zircon's task_suspend_token too): WRITE on a thread
  or process (not the caller's own: NOT_SUPPORTED; others WRONG_TYPE),
  a token (type 27, TRANSFER | INSPECT) that resumes it when closed.
  `ThreadObject.suspendCount` (atomic); the scheduler thread's
  `suspendPending` makes `UserTraps.leaving` (and the first entry) park it
  on `suspendQueue` until the count is 0 or it is killed, `suspended` and
  the SUSPENDED / RUNNING signals (1 << 5 / 1 << 4) meanwhile; ZX_INFO_
  THREAD says SUSPENDED; thread_read/write_state work on its stack-top
  frame. A process counts once and suspends each thread; threads started
  meanwhile start suspended.
- Blocked threads: Zircon wakes interruptible waits with INTR_RETRY and the
  vDSO re-issues the call; croi's programs call the kernel directly, so
  the kernel restarts: `Syscalls.restartable` (nanosleep, wait_one,
  port_wait, vmo_read, futex_wait, interrupt_wait, counter_wait, readv,
  readv_at, wait_many) marks `Thread.restartable`;
  `Scheduler.requestSuspend` ends such a wait (`suspendRetry`), and
  dispatch leaves the result unwritten and rewinds the PC over the syscall
  (`ExceptionFrame.restartSyscall`: amd64 rip - 2, arm64 elr - 4, rv64 sepc
  not yet advanced). A pager wait under a user page fault is left the
  same way (the fault is taken again). Other waits (channel_call,
  exceptions) suspend when they end.
- process_read_memory (230; READ | WRITE) / process_write_memory (231;
  WRITE; `croi.debug_syscalls=on`, implied by croi.test=1, else
  NOT_SUPPORTED): within the one mapping at the address (NOT_FOUND
  otherwise), clamped, OUT_OF_RANGE for nothing; pager pages waited for;
  writing a mapping that isn't writable first gives it a private snapshot
  child (`UserAspacePointer.privatize`, Zircon's ForceWritable), the vDSO
  refused; executable code written is synced for instruction fetch.
- Mode 17's `debugging`.

## Debugger channels (K13g part 2)

Debugger channels, K13g part 2 (Kernel/Object/Exception.swift; task.h):
- task_create_exception_channel in Zircon's order: options (DEBUGGER 1),
  NEW_CHANNEL policy, INSPECT | DUPLICATE | TRANSFER | MANAGE_THREAD,
  a thread's debugger INVALID_ARGS, non-tasks WRONG_TYPE, a job or process
  without ENUMERATE ACCESS_DENIED; the user end TRANSFER | WAIT | READ. A
  process's debugger channel (`ProcessObject.debugChannel`, one:
  ALREADY_BOUND while open) or a job's (`debugChannels`, up to 32, closed
  ones pruned).
- Routing (`Exceptions.raise` / `deliver`, a `Handlers` list of channel
  and type): architectural and policy exceptions go to the process's
  debugger, the thread's, the process's channel, the debugger again if it
  set ZX_PROP_EXCEPTION_STRATEGY (18) to SECOND_CHANCE (debugger
  exceptions only, else BAD_STATE), then each job's. Synthetic
  (`raiseSynthetic`): PROCESS_STARTING to every job debugger up from the
  job (the initial thread, `startsProcess`), THREAD_STARTING to the process
  debugger with a frame of the entry registers it may change (read back
  before entering user mode: pc, sp, three arguments), THREAD_EXITING
  with no registers (state NOT_SUPPORTED) to each handler, the reply
  ignored.
- While an exception is offered the thread keeps its report (`inException`,
  `exceptionReport`): ZX_INFO_THREAD_EXCEPTION_REPORT (11 | 1 << 28, V1
  11), croi_exception_report_t with Zircon's arch part (amd64 vector,
  error code, cr2; arm64 ESR, FAR; rv64 scause, stval); THREAD info gives
  the channel type. ZX_INFO_PROCESS DEBUGGER_ATTACHED and ZX_INFO_JOB
  debugger_attached while a debugger channel is open.
- process_exit marks the caller killed before it exits (Zircon kills it
  too), so its THREAD_EXITING doesn't wait for a debugger: a process that
  was its own debugger hung there.
- thread_raise_exception (236, K14d; Zircon's): options
  TARGET_JOB_DEBUGGER, type ZX_EXCP_USER (0x8309) and a readable
  croi_exception_context_t, else INVALID_ARGS; the caller offers it to
  every job debugger from its process's job up, one at a time, the reply
  ignored (`Exceptions.raiseUser`), with synth_code/synth_data in the
  report and the syscall's registers readable. Walking a job's debugger
  list (this, PROCESS_STARTING, an attach) prunes closed channels.
- Mode 17's `debugger`: our own process's debugger sees a thread start
  (registers) and exit, a breakpoint with a second chance.
- Post-mortem freeze (Todhchai requirement 19) is user space's, as on
  Fuchsia (its crash service's "Limbo"): a crashed thread stays in its
  exception while a handler holds the exception handle; its registers,
  exception report and the process's memory can be read, the handle can
  move over a channel to a debugger, and the thread stays frozen until
  its holder resumes or ends it. Mode 17's `postmortem` checks the flow.

## Single-step and hardware breakpoints (K13g part 3)

Single-step and hardware breakpoints, K13g part 3 (Kernel/Object/HardwareDebug.swift,
cpu.S `arch_debug_*`; task.h):
- thread_read/write_state kinds DEBUG_REGS (4, croi_thread_state_debug_
  regs_t per arch) and SINGLE_STEP (5, u32 0/1), on a stopped thread
  (suspended or in an exception); writes need debugging syscalls (Zircon's
  bit test gates both). A thread's state is `Thread.debugState` (heap
  DebugState from its first write), loaded at a switch to it and cleared
  at a switch to one without (`cpus[].debugLoaded`).
- amd64: TF in the frame's RFLAGS (stays until cleared); DR0-3 (0 or user
  addresses), DR6 (user bits B0-3, BD, BS, BT) and DR7 (L/G0-3, RW/LEN;
  LE/GE/bit 10 forced). A user #DB is HW_BREAKPOINT with DR6 saved for the
  debugger and reset; a kernel #DB (a user watchpoint hit by a user copy)
  is ignored.
- arm64: MDSCR_EL1.SS per thread plus SPSR.SS in the frame (one
  instruction per write, Zircon's); breakpoint and watchpoint pairs up to
  ID_AA64DFR0_EL1's counts, EL0 only (control registers rebuilt from
  their E bit), MDSCR_EL1.MDE while any is enabled; EC 0x30/0x32/0x34 from
  EL0 are HW_BREAKPOINT, a watchpoint's FAR/ESR saved. The OS lock (set at
  reset, it disables debug exceptions) is cleared on every CPU.
- rv64: single-step NOT_SUPPORTED, debug registers a u32 written and
  ignored (Zircon's).
- Mode 17's `stepping`: from a software breakpoint, one stepped
  instruction and a hardware breakpoint on a function (QEMU TCG delivers
  both on amd64 and arm64).
