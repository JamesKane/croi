# Hardening: randomness, ASLR, KASLR, PAC, BTI

Part of croi's design notes (index in CLAUDE.md).

## Randomness (K11b)

Randomness, K11b (Kernel/Random.swift, syscalls 181-182; handoff v5):
- The loader reads 32 bytes from EFI_RNG_PROTOCOL if the firmware has
  one (edk2 over virtio-rng: qemu.sh adds `-device virtio-rng-pci`) into
  the handoff (`entropy`, `entropy_size`; v5, 232 bytes). The kernel's
  CPRNG is ChaCha20 (RFC 8439 block, known-answer checked at boot) with
  fast key erasure, seeded first thing in kernel_main from that, the
  CPU's RNG instruction (`arch_hw_random`: amd64 RDSEED, else RDRAND;
  arm64 RNDR when ID_AA64ISAR0_EL1 says so; rv64 none, Zkr's seed CSR
  traps unless M-mode opened it) and counter jitter; the boot line names
  the sources and warns when jitter is all there was. The handoff's copies
  (the kernel's and, since review round 1, the loader's page)
  of the seed are cleared.
- `cprng_draw(buffer, length)` (181) and `cprng_add_entropy` (182):
  Zircon's, at most 256 bytes (CROI_CPRNG_MAX_LEN), INVALID_ARGS beyond
  or for a bad buffer. `Random.word()` for kernel use (ASLR).

## Static PIEs and ASLR (K11b)

Static PIEs and ASLR, K11b (lib/elf `forEachRelocation`,
ProgramLoader `randomBase`, userboot `randomPlace`; cmake `PIE`):
- `croi_user_program(... PIE ...)` builds a static PIE (-fPIE C and
  Swift importer flags, the runtime's -fPIE flavor libcroi-runtime-pie.a,
  `ld.lld -static -pie --no-dynamic-linker -ztext`, linked at 0).
  userboot and bin/m2 are PIEs, so every boot loads both ways; ET_EXEC
  programs (Todhchai's, the self-tests' fixed-address ones) still load
  where linked.
- An ET_EXEC may have a dynamic section (a program linked
  --export-dynamic to host dlopen'd libraries, Todhchai's M5k): it is
  only a symbol table, refused only if it has RELA, REL or JMPREL
  entries to apply (REL and JMPREL are refused for PIEs too). The program
  self-test runs user/test/swift a third time built that way
  (`croi_user_program(... EXPORT_DYNAMIC ...)`: lld makes the section for
  a non-PIC executable only with a shared object linked, so an empty one
  goes in --as-needed).
- Relocations: R_*_RELATIVE only; `ElfImage.forEachRelocation(in:)`
  reads PT_DYNAMIC and the RELA table from the file, and the loaders
  write `base - linkBase + addend` into the segment's VMO before mapping
  it (so RELRO-to-be pages are written while writable).
- RELRO (K14c): `ElfImage.relro` is PT_GNU_RELRO's pages (it must lie in
  one writable PT_LOAD; both ends rounded down to a page, glibc's rule;
  lld makes it a page-padded RW segment of its own), and both loaders
  make them read only after relocating (ProgramLoader `protect`,
  userboot `vmar_protect`). The runtime's `croi_relro_read_only()`
  (user/lib/runtime/image.c: the program's own headers via
  `__ehdr_start`, then PROCESS_MAPS) is checked by user/test/swift (the
  kernel's loader, PIE and ET_EXEC) and bin/m2 (userboot's). Todhchai's
  loader must do the same for its programs.
- Bases: a random page in the lower half of the user range (kernel:
  `Random.word()`, `UserAspace.isRangeFree`, 16 tries; userboot:
  cprng_draw and `vmar_allocate` with SPECIFIC, croi's now as Zircon's,
  ALREADY_EXISTS on a collision, retried). userboot maps writable
  segments as K11a children of the file's range of bootfs (copied at
  first touch, the tail past the file's bytes zeroed with
  vmo_op_range ZERO), read-only ones straight from bootfs.

## KASLR (K14j)

KASLR (K14j; handoff.h CROI_KASLR_*, boot/Loader `kaslrEntropy`,
KernelLayout `randomized`/`describeImage`): the loader picks the kernel's
base, 2 MiB aligned (any segment's alignment), anywhere the image fits in
a window that ends at the link address: 48-bit amd64/arm64 the last
512 GiB top-level slot (~2^18 bases), rv64 the Sv39 high half's last
62 GiB (~2^15). Bits from EFI_RNG_PROTOCOL, else RDRAND/RNDR
(`croi_arch_entropy`), else the counter (the loader says WEAK). The
relocations (R_*_RELATIVE only) are applied for that base
(`ElfImage.load(runningAt:)`); the kernel already used run-time addresses
throughout (image symbols PC-relative, the handoff's kernel_virt, the
sampler's image offsets). `croi.kaslr=off` loads at the link address. The
kernel panics on an image outside the window (or, with self-tests, at the
link address without croi.kaslr=off). It prints `kaslr: image
<start>-<end>, link <link>` at boot and after every PANIC line: kernel
addresses in a log map to the ELF's as address - start + link.
qemu.sh's `--registers-on` backtraces do that (qemu-monitor.py `backtrace
<start> <end> <link>`). Physical placement isn't randomized (the physmap
shows it anyway).

## Pointer authentication, arm64 (K14p)

Pointer authentication, arm64 (K14p; Main.swift `PointerAuth`, cpu.S
`arch_pac_*`, `croi_pac_keys` in kernel.h): the kernel's Swift and C are
built with -mbranch-protection=pac-ret (kernel/CMakeLists.txt), so every
non-leaf function signs its return address with the APIA key and checks
it before returning (paciasp/autiasp: hint space, NOPs without PAuth or
with it off). One random kernel key per boot on every CPU, chosen before
`arch_continue_on_stack`, and one per process (K14s: random in its
`UserAspaceRecord`, `pacKeyLo/Hi`); the key registers serve EL0 and EL1
alike, so entry from EL0 loads the kernel's (`arch_pac_load_kernel_key`,
before any signed code) and every return to EL0 the running process's
(`arch_pac_load_user_key`, also in `arch_enter_user`), read from the
CPU's `croi_percpu_arch_t` (CROI_PERCPU_PAC_USER), where the scheduler
copies it at each switch to a user thread and in `setAspace` (a new
thread takes its address space after the switch to it: the first version
missed that, and a second thread signed with the previous process's key).
SCTLR_EL1.EnIA is set only on paths that never return through an earlier
frame (`arch_pac_enable` in `arch_continue_on_stack` and before
`kernel_ap_main`): a function entered before it would fail its own check.
Both EL2 drops set HCR_EL2.API|APK (else the instructions trap to an EL2
with no handler). Kernel stack walks strip the signatures
(`arch_pac_strip`, XPACLRI; qemu-monitor.py does the same by bit 55); a
failure with FEAT_FPAC is EC 0x1C, "pointer authentication failure".
`croi.pac=off`, or no address authentication (ID_AA64ISAR1/2): unsigned.
The boot self-test checks signing and that another key signs differently;
mode 17's check 676 that user code's signature isn't the kernel's (it
failed with the return path's key load removed), 683-685 that another
thread of the process signs alike and a child process differently (683
failed with one key for every process). User programs aren't built with
pac-ret (their own choice).

## Branch target identification, arm64 (K14q)

Branch target identification, arm64 (K14q; Main.swift `BranchTargets`,
cpu.S `arch_bti_*`, PageTableFormat `guardedKernelText`): built with
-mbranch-protection=pac-ret+bti (croi-rt with bti), so compiled code
carries a landing pad (BTI, or the PACIASP already there) wherever it is
reached by an indirect branch; hand-written assembly reached by `br`/`blr`
must start with `bti j`/`bti c` (today only the PMU sysreg jump tables,
16-byte entries; direct `bl`, `ret` and `eret` need none). With FEAT_BTI
(ID_AA64PFR1_EL1.BT) and no `croi.bti=off`, executable kernel leaves get
the guarded-page bit (50; decided before the kernel's tables are built,
the command line read through the loader's identity map) and
SCTLR_EL1.BT1 is set. A stray indirect branch is EC 0x0D, "branch target
exception". The boot self-test branches to a non-pad instruction
(`arch_bti_probe`) and arch_exception sends it on to a recovery point,
clearing SPSR.BTYPE (else the recovery instruction is checked too); with
the jump tables' pads removed the PMU self-test faults.

## Guarded user pages (K14r)

Guarded user pages (K14r): `CROI_VM_PERM_GUARDED` (task.h, 1 << 30,
croi's) on vmar_map/vmar_protect makes an executable mapping guarded
(`VmRights.guarded`, `MapAttributes.guarded`, bit 50 where FEAT_BTI is in
use; accepted and ignored elsewhere; PROCESS_MAPS reports it). Programs
opt in through their ELF: `ElfImage.branchTargets` reads PT_GNU_PROPERTY's
GNU_PROPERTY_AARCH64_FEATURE_1_AND (bit 0, BTI), which lld sets only when
every object has landing pads; ProgramLoader and userboot then map the
executable segments guarded. croi's arm64 user code is built with
-mbranch-protection=bti (CROI_USER_CFLAGS): userboot, m2 and the Swift
test programs come out marked (an unmarked program, `hello`, runs
unguarded). The vDSO (every entry `bti c`) is always mapped guarded. A
user branch target exception is CROI_EXCP_GENERAL. Mode 17's checks
677-678: through a guarded mapping a BTI C routine is reached and a NOP
one refused (the thread's exception); through a plain one either runs
(678 failed with the user bit not encoded).
