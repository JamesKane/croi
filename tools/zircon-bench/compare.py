#!/usr/bin/env python3
"""croi's M2 budgets against Zircon's, on this machine, interleaved.

Each round boots every configuration once, in a rotating order, so all of
them see the same machine (tools/bench.py --compare's rule). A budget's
result is its median over the rounds, with the range beside it.

Configurations:
  croi            the amd64 build's ESP as built, plus croi.selftest=off
                  (bench.py's "lean" profile, as Todhchai boots)
  croi-nopoll     ... plus croi.idle_poll_us=0: idle CPUs halt at once,
                  so a cross-core wake needs an IPI, as on Zircon
  zircon          the parity bench (run.sh), Zircon's default options
  zircon-nomitig  ... plus kernel.x86.disable_spec_mitigations=true
                  (croi has no speculative-execution mitigations)

The croi ESP is copied once at the start, so a rebuild during the run
changes nothing. Like bench.py, a load average above a quarter of the CPUs
marks the round as taken on a busy machine.

    tools/zircon-bench/compare.py [--rounds N] [--only CONFIG,...]
"""

import argparse
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CROI = os.path.dirname(os.path.dirname(HERE))
LINE = re.compile(r"budget name=(\S+) value=(\d+) unit=(\w+)")
CROI_DONE = "userboot: bin/m2 exited with"
BUDGETS = ["syscall.null", "ipc.channel_call", "port.wake_median", "port.wake_p99",
           "timer.wake_error_p99", "vdso.clock_monotonic"]


def edk2_dir():
    with open(os.path.join(CROI, "build", "amd64", "CMakeCache.txt")) as f:
        for line in f:
            if line.startswith("CROI_EDK2_DIR:"):
                return line.split("=", 1)[1].strip()
    return "/usr/share/edk2"


def boot_croi(work, extra, log):
    esp = os.path.join(work, "esp-boot")
    shutil.rmtree(esp, ignore_errors=True)
    shutil.copytree(os.path.join(work, "esp"), esp)
    cmdline = os.path.join(esp, "croi", "cmdline")
    with open(cmdline) as f:
        words = f.read().split()
    words += ["croi.selftest=off"] + extra
    with open(cmdline, "w") as f:
        f.write(" ".join(words) + "\n")
    qemu_work = os.path.join(work, "qemu")
    os.makedirs(qemu_work, exist_ok=True)
    with open(log, "w") as out:
        result = subprocess.run([os.path.join(CROI, "tools", "qemu.sh"), "--test", CROI_DONE, "amd64", esp,
                                 qemu_work, edk2_dir(), "-accel", "kvm", "-cpu", "host"],
                                stdout=out, stderr=subprocess.STDOUT, timeout=180)
    return result.returncode == 0


def boot_zircon(extra, log):
    result = subprocess.run([os.path.join(HERE, "run.sh"), "--log", log] + extra,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=240)
    return result.returncode == 0


CONFIGS = {
    "croi": lambda work, log: boot_croi(work, [], log),
    "croi-nopoll": lambda work, log: boot_croi(work, ["croi.idle_poll_us=0"], log),
    "zircon": lambda work, log: boot_zircon([], log),
    "zircon-nomitig": lambda work, log: boot_zircon(["kernel.x86.disable_spec_mitigations=true"], log),
}


def budgets(log):
    values = {}
    with open(log, errors="replace") as f:
        for line in f:
            m = LINE.search(line)
            if m:
                values[m.group(1)] = int(m.group(2))
    return values


def fmt(ns):
    if ns is None:
        return "-"
    return f"{ns} ns" if ns < 10_000 else f"{ns / 1000:.1f} us"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--rounds", type=int, default=6)
    parser.add_argument("--only", help="comma-separated configurations")
    parser.add_argument("--logs", help="keep boot logs here (default: a temporary directory)")
    args = parser.parse_args()
    configs = args.only.split(",") if args.only else list(CONFIGS)
    for c in configs:
        if c not in CONFIGS:
            sys.exit(f"compare.py: unknown configuration {c}")

    work = tempfile.mkdtemp(prefix="zircon-compare-")
    logs = args.logs or work
    os.makedirs(logs, exist_ok=True)
    shutil.copytree(os.path.join(CROI, "build", "amd64", "esp"), os.path.join(work, "esp"))
    head = subprocess.run(["git", "-C", CROI, "describe", "--always", "--dirty"],
                          capture_output=True, text=True).stdout.strip()
    print(f"croi {head} (ESP copied {work}/esp), {args.rounds} rounds, logs in {logs}")

    results = {c: {} for c in configs}
    busy_rounds = 0
    quarter = os.cpu_count() / 4
    for r in range(args.rounds):
        load_before = os.getloadavg()[0]
        order = configs[r % len(configs):] + configs[:r % len(configs)]
        line = []
        for c in order:
            log = os.path.join(logs, f"{c}-{r}.log")
            ok = CONFIGS[c](work, log)
            values = budgets(log)
            if not ok or not values:
                line.append(f"{c} FAILED ({log})")
                continue
            for name, value in values.items():
                results[c].setdefault(name, []).append(value)
            line.append(f"{c} ok")
        load = max(load_before, os.getloadavg()[0])
        busy = load > quarter
        busy_rounds += busy
        print(f"round {r + 1}: {', '.join(line)}; load {load:.1f}{' (busy)' if busy else ''}", flush=True)

    print()
    width = max(len(c) for c in configs)
    print(f"{'budget':22}" + "".join(f"  {c:>{max(width, 26)}}" for c in configs))
    for name in BUDGETS:
        row = f"{name:22}"
        for c in configs:
            v = results[c].get(name)
            cell = "-" if not v else f"{fmt(int(statistics.median(v)))} [{fmt(min(v))}-{fmt(max(v))}]"
            row += f"  {cell:>{max(width, 26)}}"
        print(row)
    print("\nmedian over rounds [min-max]")
    if busy_rounds:
        print(f"{busy_rounds} of {args.rounds} rounds ran with load above {quarter:.0f}: "
              "treat the figures as a shared machine's")
    shutil.rmtree(os.path.join(work, "esp"), ignore_errors=True)
    shutil.rmtree(os.path.join(work, "esp-boot"), ignore_errors=True)


if __name__ == "__main__":
    main()
