#!/usr/bin/env python3
"""croi's budget bench (K9f), after Todhchai's `td bench` (its
docs/performance.md and lib/bench/Judge.swift).

Boots the amd64 build under KVM several times, in two profiles: "full"
(the command line as built: every self-test runs) and "lean" (plus
croi.selftest=off, as Todhchai boots). Each boot prints `budget name=...
value=... unit=... [limit=...] [target=...]` lines (Budgets.swift, m2).
The bench takes each budget's median over the runs and judges it against
this machine's history, bench/history/<host>.tsv: it fails when it is
above its limit, or slower than the median of the last 5 recorded runs by
more than both its rule's fraction and its floor, so a budget's margin
isn't spent silently.

Timings are only as good as the machine. On a shared machine (other
agents, QEMU sessions, builds) the bench reports and fails nothing, and
--record refuses while the machine is busy (load average above a quarter
of the CPUs, before or after). Only a quiet, dedicated machine runs
--enforce. A regression is fixed, or recorded with --accept as a decision
made in the open (docs/roadmap.md), never silently.

    tools/bench.py [--runs N] [--record [--accept]] [--enforce]
    tools/bench.py --compare REF [--runs N]   # this tree against REF, interleaved

--compare builds REF in a worktree (bench/out/compare/) and alternates
boots of the two, so both see the same machine: comparing runs taken one
after the other on a shared machine mostly measures the machine. REF must
print budget lines (K9f on).

Python because it drives QEMU and parses logs on the host; nothing in it
runs in croi.
"""

import argparse
import datetime
import os
import re
import shutil
import socket
import statistics
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "bench", "out")
HISTORY = os.path.join(ROOT, "bench", "history")
LINE = re.compile(r"budget name=(\S+) value=(\d+) unit=(\w+)(?: limit=(\d+))?(?: target=(\d+))?")
DONE = "userboot: bin/m2 exited with"

# name: (tolerance: a rise above the baseline by more than this fraction
# fails... , floor: ...if it is also more than this many ns). Sized from
# what the same tree measured under KVM on a shared machine (2026-10-10):
# channel_call 1.39-1.42 us quiet, 1.8-2.2 us with a build running.
RULES = {
    "syscall.null": (0.25, 10),
    "ipc.channel_call": (0.15, 150),
    "port.wake_median": (0.25, 300),
    "port.wake_p99": (0.50, 5_000),
    "timer.wake_error_p99": (0.50, 20_000),
    "process.spawn_to_main": (0.50, 30_000),
    "trace.probe_enabled": (0.25, 5),
    "irq.wait_wake_median": (0.25, 3_000),
    "boot.userboot_start": (0.15, 15_000_000),
    "boot.userboot_start_selftests": (0.25, 300_000_000),
    "edf.deadline_misses": (0.0, 0.5),
    "edf.worst_wake": (0.50, 20_000),
}
DEFAULT_RULE = (0.25, 0)
WINDOW = 5


def say(text):
    print(text, flush=True)


def fail(text):
    print(f"bench: {text}", file=sys.stderr)
    sys.exit(2)


def run(command, cwd=ROOT, log=None):
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
    if log:
        with open(log, "w") as f:
            f.write(result.stdout + result.stderr)
    return result


def edk2_dir(build):
    try:
        with open(os.path.join(build, "CMakeCache.txt")) as f:
            for line in f:
                if line.startswith("CROI_EDK2_DIR:"):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return "/usr/share/edk2"


def boot(build, profile, label, index, any_exit=False):
    """One boot of `build` in `profile`; its budget lines as {name: (value, limit, target)}.
    `any_exit`: m2 may fail (a comparison's REF may still enforce its limits)."""
    esp = os.path.join(OUT, "esp", f"{label}-{profile}")
    shutil.rmtree(esp, ignore_errors=True)
    shutil.copytree(os.path.join(build, "esp"), esp)
    cmdline = os.path.join(esp, "croi", "cmdline")
    with open(cmdline) as f:
        words = f.read().split()
    if profile == "lean":
        words.append("croi.selftest=off")
    with open(cmdline, "w") as f:
        f.write(" ".join(words))
    work = os.path.join(OUT, "work", label)
    os.makedirs(work, exist_ok=True)
    log = os.path.join(OUT, "logs", f"{label}-{profile}-{index}.log")
    tree = os.path.dirname(os.path.dirname(os.path.abspath(build)))
    result = run([os.path.join(tree, "tools", "qemu.sh"), "--test", DONE, "amd64", esp, work, edk2_dir(build),
                  "-accel", "kvm", "-cpu", "host"], cwd=tree, log=log)
    if result.returncode != 0 or (not any_exit and f"{DONE} 0" not in result.stdout):
        fail(f"{label} {profile} boot {index} didn't finish; see {log}")
    budgets = {}
    for m in LINE.finditer(result.stdout):
        UNITS[m.group(1)] = m.group(3)
        budgets[m.group(1)] = (int(m.group(2)), m.group(4) and int(m.group(4)), m.group(5) and int(m.group(5)))
    return budgets


UNITS = {}  # budget name -> its unit, as the boot reported it


def collect(build, label, runs, values, meta):
    for i in range(runs):
        for profile in ("full", "lean"):
            for name, (value, limit, target) in boot(build, profile, label, i).items():
                values.setdefault(name, []).append(value)
                meta[name] = (limit, target)


def busy_load():
    load = os.getloadavg()[0]
    return load, load > os.cpu_count() / 4


def machine():
    host = socket.gethostname().split(".")[0]
    model = "unknown CPU"
    try:
        with open("/proc/cpuinfo") as f:
            for line in f:
                if line.startswith("model name"):
                    model = line.split(":", 1)[1].strip()
                    break
    except OSError:
        pass
    return host, f"{host}, {model}, {os.cpu_count()} CPUs"


def commit(tree=ROOT):
    sha = run(["git", "rev-parse", "--short", "HEAD"], cwd=tree).stdout.strip()
    dirty = run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=tree).stdout.strip()
    return sha + ("-dirty" if dirty else "")


def read_history(path):
    samples = []
    try:
        with open(path) as f:
            for line in f:
                if line.startswith("#") or not line.strip():
                    continue
                date, sha, name, value = line.rstrip("\n").split("\t")
                samples.append((name, float(value)))
    except OSError:
        pass
    return samples


def judge(name, value, limit, history):
    tolerance, floor = RULES.get(name, DEFAULT_RULE)
    past = [v for n, v in history if n == name][-WINDOW:]
    baseline = statistics.median(past) if past else None
    if limit is not None and value >= limit:
        verdict = "OVER LIMIT"
    elif baseline is None:
        verdict = "new"
    elif value > baseline * (1 + tolerance) and value - baseline > floor:
        verdict = "REGRESSED"
    else:
        verdict = "ok"
    return baseline, verdict, f"+{int(tolerance * 100)}%, {fmt(floor, name)}"


def fmt(ns, name=None):
    if ns is None:
        return "—"
    if UNITS.get(name) == "count":
        return f"{float(ns):g}"
    ns = float(ns)
    if ns >= 1e6:
        return f"{ns / 1e6:.1f} ms"
    if ns >= 1e4:
        return f"{ns / 1e3:.1f} us"
    return f"{int(round(ns))} ns"


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--build", default=os.path.join(ROOT, "build", "amd64"))
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--record", action="store_true", help="add this run to the machine's history")
    parser.add_argument("--accept", action="store_true", help="record despite a regression or a busy machine")
    parser.add_argument("--enforce", action="store_true", help="fail on a regression (quiet machines only)")
    parser.add_argument("--compare", metavar="REF", help="compare with REF, interleaved")
    args = parser.parse_args()
    if not os.path.exists("/dev/kvm"):
        fail("needs KVM (/dev/kvm): TCG timings aren't judged")
    for d in ("esp", "work", "logs"):
        os.makedirs(os.path.join(OUT, d), exist_ok=True)

    load_before, busy_before = busy_load()
    if args.compare:
        return compare(args, load_before)

    say(f"bench: {args.runs} runs x (full, lean) boots of {args.build} under KVM")
    values, meta = {}, {}
    collect(args.build, "this", args.runs, values, meta)
    load_after, busy_after = busy_load()
    busy = busy_before or busy_after

    host, description = machine()
    history_path = os.path.join(HISTORY, f"{host}.tsv")
    history = read_history(history_path)
    sha = commit()
    rows, bad = [], 0
    for name in sorted(values):
        value = statistics.median(values[name])
        limit, target = meta[name]
        baseline, verdict, rule = judge(name, value, limit, history)
        bad += verdict in ("OVER LIMIT", "REGRESSED")
        change = f"{(value - baseline) / baseline * 100:+.0f}%" if baseline else "—"
        rows.append((name, value, baseline, change, limit, target, rule, verdict))

    date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
    report = [f"# Budget report", "",
              f"Machine `{description}`, commit `{sha}`, {date}, median of {args.runs} boots per profile. "
              f"Load average {load_before:.1f} before, {load_after:.1f} after"
              + (" (busy: a regression may be noise)" if busy else "") + ".", "",
              "| Budget | This run | Baseline | Change | Limit | Target | Rule | Verdict |",
              "|---|---:|---:|---:|---:|---:|---|---|"]
    for name, value, baseline, change, limit, target, rule, verdict in rows:
        shown = f"**{verdict}**" if verdict in ("OVER LIMIT", "REGRESSED") else verdict
        report.append(f"| `{name}` | {fmt(value, name)} | {fmt(baseline, name)} | {change} | {fmt(limit, name)} "
                      f"| {fmt(target, name)} | {rule} | {shown} |")
    report.append("")
    report.append("Enforced: a regression or a missed limit fails." if args.enforce
                  else "Advisory: nothing fails here (a shared machine's timings are noisy).")
    text = "\n".join(report) + "\n"
    with open(os.path.join(OUT, "report.md"), "w") as f:
        f.write(text)
    say(text)

    if args.record:
        if busy and not args.accept:
            say("not recorded: the machine was busy, and a noisy run would skew the baseline. Rerun when it is quiet.")
        elif sha.endswith("-dirty") and not args.accept:
            say("not recorded: the tree has uncommitted changes; record a commit.")
        elif bad and not args.accept:
            say("not recorded: a budget regressed. Fix it, or re-decide with --accept (in the open).")
        else:
            os.makedirs(HISTORY, exist_ok=True)
            new = not os.path.exists(history_path)
            with open(history_path, "a") as f:
                if new:
                    f.write(f"# Budget history for {description}. Appended by tools/bench.py --record.\n")
                for name, value, *_ in rows:
                    f.write(f"{date}\t{sha}\t{name}\t{value:.0f}\n")
            say(f"recorded in {os.path.relpath(history_path, ROOT)}")
    return 1 if args.enforce and bad else 0


def compare(args, load_before):
    """This tree against REF, boots alternating so both see the same machine."""
    ref = run(["git", "rev-parse", "--short", args.compare]).stdout.strip()
    if not ref:
        fail(f"no such commit: {args.compare}")
    tree = os.path.join(OUT, "compare", ref)
    if not os.path.exists(tree):
        os.makedirs(os.path.dirname(tree), exist_ok=True)
        if run(["git", "worktree", "add", "--detach", tree, ref]).returncode != 0:
            fail(f"can't make a worktree for {ref}")
    say(f"bench: building {ref} in {os.path.relpath(tree, ROOT)}")
    other = os.path.join(tree, "build", "amd64")
    log = os.path.join(OUT, "logs", f"compare-{ref}-build.log")
    if not os.path.exists(other):
        run(["cmake", "--preset", "amd64"], cwd=tree, log=log)
    if run(["cmake", "--build", "--preset", "amd64"], cwd=tree, log=log).returncode != 0:
        fail(f"building {ref} failed; see {log}")

    say(f"bench: {args.runs} interleaved runs, this tree ({commit()}) and {ref}")
    a, b, meta = {}, {}, {}
    for i in range(args.runs):
        for label, build, values in (("this", args.build, a), (ref, other, b)):
            for profile in ("full", "lean"):
                for name, (value, limit, target) in boot(build, profile, label, i, any_exit=True).items():
                    values.setdefault(name, []).append(value)
                    meta[name] = (limit, target)
    load_after, busy = busy_load()
    lines = [f"# Comparison: this tree ({commit()}) against {ref}", "",
             f"Median of {args.runs} interleaved boots per profile. Load average {load_before:.1f} before, "
             f"{load_after:.1f} after.", "",
             "| Budget | This tree | " + ref + " | Change | Spread here (min-max) |", "|---|---:|---:|---:|---|"]
    for name in sorted(set(a) | set(b)):
        here, there = a.get(name), b.get(name)
        mh = statistics.median(here) if here else None
        mt = statistics.median(there) if there else None
        change = f"{(mh - mt) / mt * 100:+.0f}%" if mh and mt else "—"
        spread = f"{fmt(min(here), name)}-{fmt(max(here), name)}" if here else "—"
        lines.append(f"| `{name}` | {fmt(mh, name)} | {fmt(mt, name)} | {change} | {spread} |")
    text = "\n".join(lines) + "\n"
    with open(os.path.join(OUT, "compare.md"), "w") as f:
        f.write(text)
    say(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
