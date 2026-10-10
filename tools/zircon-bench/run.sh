#!/usr/bin/env bash
# Boot the Zircon parity bench once under QEMU/KVM and print its results.
#
#   run.sh [--log <file>] [kernel cmdline options...]
#
# The QEMU arguments are run-zircon's for x64 with KVM (what `fx qemu` would
# pass), called directly so no ffx or full product build is needed. 4 CPUs,
# as croi's boot-smoke-kvm. FUCHSIA_DIR defaults to ../fuchsia-jiri next to
# croi; FUCHSIA_OUT to its out/bringup.x64-release.
#
# Unpinned by default, as croi's tools/bench.py boots. With PIN=1, vCPU n is
# pinned to host CPU VCPU_BASE+n (default 2) and QEMU's other threads to
# HOST_CPU (default 6). Zircon can't power off this machine, so QEMU is
# stopped once the test reports.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fuchsia="${FUCHSIA_DIR:-$(cd "$here/../../../fuchsia-jiri" && pwd)}"
out="${FUCHSIA_OUT:-$fuchsia/out/bringup.x64-release}"
qemu="$fuchsia/prebuilt/third_party/qemu/linux-x64/bin/qemu-system-x86_64"
shim="$out/kernel.phys32/linux-x86-boot-shim.bin"
zbi="$out/obj/local/croi-parity/croi-parity-zbi-test.eng.lk_debug_level_0.zbi"
vcpu_base="${VCPU_BASE:-2}"
host_cpu="${HOST_CPU:-6}"
pin="${PIN:-0}"
# run-zircon's model. CPU=host is croi's boot-smoke-kvm: without invtsc,
# Zircon uses the LAPIC one-shot timer instead of TSC-deadline.
cpu="${CPU:-host,migratable=no,+invtsc}"

log=""
if [[ "${1:-}" == "--log" ]]; then
  log="$2"
  shift 2
fi
log="${log:-$(mktemp)}"

cmdline="kernel.serial=legacy kernel.halt-on-panic=true"
cmdline+=" kernel.entropy-mixin=$(head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1)"
cmdline+=" $*"

taskset_host=()
if [[ "$pin" == 1 ]]; then
  taskset_host=(taskset -c "$host_cpu")
fi

"${taskset_host[@]}" "$qemu" \
  -name zircon-parity,debug-threads=on \
  -machine q35,smbios-entry-point-type=32 \
  -enable-kvm -cpu "$cpu" \
  -smp 4 -m 2048 \
  -nographic -vga none -net none \
  -no-reboot \
  -kernel "$shim" -initrd "$zbi" -append "$cmdline" \
  > "$log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT

# Pin each vCPU thread ("CPU n/KVM") as soon as it exists.
pinned=0
for _ in $(seq 100); do
  [[ "$pin" == 1 ]] || break
  pinned=0
  for task in /proc/$pid/task/*; do
    if [[ "$(cat "$task/comm" 2>/dev/null)" =~ ^CPU\ ([0-9]+)/KVM ]]; then
      taskset -pc $((vcpu_base + BASH_REMATCH[1])) "${task##*/}" > /dev/null
      pinned=$((pinned + 1))
    fi
  done
  [[ $pinned -eq 4 ]] && break
  sleep 0.05
done
if [[ "$pin" == 1 && $pinned -ne 4 ]]; then
  echo "run.sh: pinned $pinned of 4 vCPUs" >&2
  exit 1
fi

result=""
for _ in $(seq 600); do
  if grep -aq "Boot-test-successful" "$log"; then
    result=pass
    break
  fi
  if grep -aqE "\[  FAILED  \]|ZIRCON KERNEL PANIC|Halted" "$log"; then
    result=fail
    break
  fi
  if ! kill -0 $pid 2>/dev/null; then
    break
  fi
  sleep 0.5
done

grep -a "croi-parity:" "$log" | sed 's/.*croi-parity: //' || true
if [[ "$result" != pass ]]; then
  echo "run.sh: the bench did not pass; see $log" >&2
  exit 1
fi
