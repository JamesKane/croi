# zircon-bench: croi's budgets measured on Zircon

A comparison model for croi's performance budgets. When croi misses a
budget, the question is whether the target is attainable under Zircon's
semantics at all, and if so how far croi is from the reference. This
directory answers that on the same machine, under the same VM, with the
same workload:

- `parity_bench.cc` ports the M2 bench (`user/m2/Bench.swift`) to Zircon:
  the same workloads, run order, CPU masks (client 1, waiter 2, sleeper 3),
  iteration counts and statistics. It prints m2's `budget name=...` lines
  under m2's names. It runs as a kernel ZBI test: userboot starts it
  directly, with no component framework, as croi's userboot starts `m2`.
- `run.sh` boots it once under QEMU/KVM and prints its results.
- `compare.py` boots croi and Zircon alternately and tabulates both.
- `BUILD.gn` builds it in a Fuchsia tree as `//local/croi-parity`.

| Budget (m2's name) | Workload |
|---|---|
| `syscall.null` | 10k `zx_syscall_test_0`, mean |
| `ipc.channel_call` | Same core, client on a 4 ms / 10 ms deadline profile, server fair; 10 batches of 200 calls of 8 bytes; median of the batch means |
| `port.wake_median`, `port.wake_p99` | Waiter on CPU 2 in `zx_port_wait`; signaler on CPU 1 sleeps 100 µs, then signals; 200 wakes |
| `timer.wake_error_p99` | Deadline thread (1 ms / 10 ms) on CPU 3 sleeping to now + 500 µs; 200 sleeps |
| `vdso.clock_monotonic` | 1000 `zx_clock_get_monotonic` through the vDSO, mean (croi reports its own in usertest) |

Besides the budget lines, each boot prints `croi-parity: <name> <value> ns`
lines with more detail: the channel call's min and max batch means, and
p10, median, p90, p99 and max for port wake and wake error.

## Differences that matter when comparing

- **Timing.** Zircon is timed with `zx_ticks_get` in user space. croi's
  port wake runs from the signal syscall's kernel entry to `port_wait`'s
  kernel exit, so Zircon's figure includes one extra entry and exit (tens
  of ns).
- **Idle polling.** Under a hypervisor croi's idle loop polls for 200 µs
  before halting (`croi.idle_poll_us`), and the port wake test sleeps only
  100 µs, so a croi wake never needs an IPI or a HLT exit. Zircon has no
  such option. `compare.py` therefore also boots croi with
  `croi.idle_poll_us=0`.
- **Mitigations.** croi has no speculative-execution mitigations, Zircon
  has them on by default. `compare.py` boots Zircon both ways.
- **Donation.** Zircon has no scheduling-context donation.
  `zx_channel_call` blocks on an owned wait queue, so the server inherits
  the caller's deadline profile: the nearest equivalent.
- **Kernel build.** The `eng.lk_debug_level_0` kernel image: production
  assertion level, with the eng command line. The ZBI test adds
  `kernel.power.boot-boost=false` and turns the page scanner off.

## Setup, once

The Fuchsia tree is a jiri checkout beside croi, `../fuchsia-jiri`, pinned
to the integration revision that rolled `fuchsia` to croi's reference
commit (e8b19ec722, CLAUDE.md). A plain fuchsia.git clone (`../fuchsia`)
can't build: it has no prebuilts and no third-party repos.

    cd ..
    curl -s "https://fuchsia.googlesource.com/jiri/+/HEAD/scripts/bootstrap_jiri?format=TEXT" \
        | base64 --decode > /tmp/bootstrap_jiri
    bash /tmp/bootstrap_jiri fuchsia-jiri
    cd fuchsia-jiri
    .jiri_root/bin/jiri import -name=integration \
        -revision=78729f5a56702b368a8f492b42d36a087d09d829 \
        flower https://fuchsia.googlesource.com/integration
    .jiri_root/bin/jiri -j=4 update -attempts=6

About 41 GB. googlesource rate-limits jiri's default 32 jobs (HTTP 429);
`-j=4` gets through, and a rerun resumes. Packages skipped "due to lack of
access" are Google-internal and not needed. To move to a new reference
commit, find its roll in the integration repo (`git log --grep` on the
fuchsia commit's subject) and re-import with that revision.

Then link this directory in and configure (`/local` is ignored by
fuchsia.git):

    ln -s "$PWD/../croi/tools/zircon-bench" local/croi-parity
    export PATH="$PWD/.jiri_root/bin:$PATH"
    fx set bringup.x64 --release --with //local/croi-parity

## Building

From `../fuchsia-jiri`, after any change to `parity_bench.cc`:

    fx build //local/croi-parity:croi-parity-zbi-test.eng.lk_debug_level_0.zbi \
        kernel.phys32/linux-x86-boot-shim.bin

Only those two targets: a plain `fx build` builds all of bringup.

## Running Zircon alone

    tools/zircon-bench/run.sh [--log FILE] [kernel options...]

One boot; results on stdout, the serial log in `--log` (else a temporary
file); exit status 1 if the bench failed. It calls QEMU directly with
run-zircon's x64 KVM arguments (`fx qemu` needs ffx, and
`fx run-boot-test` builds the whole product first), and stops QEMU once
the test reports, since Zircon can't power off q35. A boot takes about 5 s.

- `PIN=1` pins vCPU n to host CPU `VCPU_BASE`+n (default 2) and QEMU's
  other threads to `HOST_CPU` (default 6). Off by default, as croi's
  `tools/bench.py` boots.
- `CPU=` overrides the CPU model (default `host,migratable=no,+invtsc`).
- `FUCHSIA_DIR`, `FUCHSIA_OUT` point at another tree or build directory.
- Kernel options pass through, e.g. `kernel.x86.disable_spec_mitigations=true`,
  or `croi-parity.sleeper=fair` to run the wake-error sleeper on a fair
  profile instead of a deadline one.

## Comparing croi with Zircon

    tools/zircon-bench/compare.py [--rounds N] [--only CONFIG,...] [--logs DIR]

Needs croi's amd64 build (`cmake --build --preset amd64`) and the Zircon
build above. Each round boots every configuration once, in a rotating
order, so all of them see the same machine (bench.py `--compare`'s rule):

| Configuration | What boots |
|---|---|
| `croi` | `build/amd64/esp` with `croi.selftest=off` (bench.py's lean profile) |
| `croi-nopoll` | ... plus `croi.idle_poll_us=0` |
| `zircon` | the parity bench, Zircon's defaults |
| `zircon-nomitig` | ... plus `kernel.x86.disable_spec_mitigations=true` |

The croi ESP is copied once at the start, so a rebuild during the run
changes nothing. The table gives each budget's median over the rounds and
its range. Rounds taken with a load average above a quarter of the CPUs
are flagged, as bench.py does: such figures are a shared machine's and
only show a pattern. Run on a quiet machine with six rounds or more before
drawing conclusions.

### Reading the result for a missed budget

1. **Zircon meets it, croi doesn't:** the target is attainable with these
   semantics. Diff the two paths (`--logs` keeps every boot's log; a
   Zircon ktrace or croi's own trace explains where the time goes).
2. **Neither meets it:** the target may be beyond this design under KVM.
   Record a decision in docs/roadmap.md (design change, or revise the
   target) instead of tuning blind.
3. **croi meets it only in one configuration** (e.g. port wake only with
   idle polling): the budget depends on that mechanism, and the roadmap
   should say so.

### Adding a workload

When m2 gains a budget, mirror it here: a function in `parity_bench.cc`
with the same workload, called from `TEST(CroiParity, Bench)` in m2's
order, printing `Budget("<m2's name>", ns)`. Add the name to `BUDGETS` in
`compare.py`. The two must stay comparable: change both sides together.

## Results so far (2026-10-10, AMD Ryzen 7 9700X, KVM, busy machine)

croi at 6e93cf0 (clean tree), six interleaved rounds with another build and
QEMU tests running (load 6.5-7.5), so a pattern, not a measurement. Median
over the rounds, [min-max]:

| Budget | croi | croi-nopoll | zircon | zircon-nomitig |
|---|---|---|---|---|
| `syscall.null` (< 100 ns) | 33 ns [32-43] | 34 ns [30-39] | 39 ns [37-59] | 33 ns [33-45] |
| `ipc.channel_call` (< 1 µs) | 1.45 µs [1.41-1.82] | 1.39 µs [1.38-1.59] | 2.24 µs [2.16-3.13] | 2.04 µs [2.02-2.65] |
| `port.wake_median` (< 2 µs) | 1.86 µs [1.82-2.35] | 6.16 µs [6.10-6.51] | 5.94 µs [5.84-7.49] | 5.77 µs [5.73-7.32] |
| `port.wake_p99` | 7.7 µs [3.2-84] | 17.7 µs [11.9-39.8] | 20.9 µs [11.1 µs-8.4 ms] | 12.7 µs [11.2-99.4] |
| `timer.wake_error_p99` (< 100 µs) | 26 µs [20-45] | 35 µs [25 µs-1.5 ms] | 1.84 ms [27 µs-2.09 ms] | 2.02 ms [22 µs-2.09 ms] |

- Null syscall: level; Zircon's mitigations cost ~6 ns here.
- `channel_call`: croi is ~0.6-0.8 µs faster than Zircon; neither meets
  1 µs. Zircon is no proof the target is attainable.
- Port wake: croi meets 2 µs only through idle polling. Without it croi
  and Zircon are level at ~6 µs (IPI plus HLT exit under KVM).
- Wake error: Zircon is usually far over (errors spread evenly over
  0-2 ms), with some boots near 20-30 µs. Not timer slack (none by
  default), pinning, the sleeper's profile, or the TSC-deadline timer
  (`CPU=host,-tsc-deadline` doesn't help). croi without idle polling had
  one such boot too (1.5 ms), so a halted vCPU's late wake under host load
  is a suspect, one Zircon meets far more often. Unexplained so far; next
  is a ktrace of the sleeper's CPU.

Host: governor `powersave`, boost on, KVM `halt_poll_ns` 200000. These
change the absolute figures for both kernels.
