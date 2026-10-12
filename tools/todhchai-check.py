#!/usr/bin/env python3
"""Boots Todhchai's test programs on this tree's croi.

Todhchai (../todhchai, ../todhchai-c0) is croi's consumer; its `td ci`
builds croi from its last commit, so a croi change reaches it only after
it is committed. This runs the part of td ci that needs nothing but a
bootfs before committing: the programs td starts with `td boot --next`
(sys-test, pthread-test, tls-test, services-test). A change to the root
filter or resource rules broke sys-test once (port 0xCF9, review round 1)
with every croi test passing.

The ESP is assembled under build/<arch>/todhchai/: croi's loader and kernel
from build/<arch>/esp, Todhchai's newest bootfs.img for the arch (from the
last `td boot` there), and td's command line for a --next boot. QEMU runs
as td boot runs it (tools/td/BootCommand.swift `qemuCommand`: KVM on amd64
when /dev/kvm is usable), not as croi's qemu.sh, whose extra devices (an
IOMMU, edu) Todhchai's tests don't expect. Nothing in Todhchai's trees is
written.

Exit status: 0 all passed, 1 a failure (the console's tail is shown), 77
no Todhchai bootfs for the arch (ctest's SKIP_RETURN_CODE).
"""

import argparse
import os
import shutil
import signal
import struct
import subprocess
import sys
import time

PROGRAMS = ["bin/sys-test", "bin/pthread-test", "bin/tls-test", "bin/services-test"]
EDK2 = "/usr/share/edk2"
BOOTFS_MAGIC = 0xA56D3FF9


def bootfs_names(path):
    """The file names in a bootfs image (Zircon's format, tools/mkbootfs.py)."""
    with open(path, "rb") as f:
        header = f.read(16)
        if len(header) < 16:
            return set()
        magic, dirsize = struct.unpack_from("<II", header)
        if magic != BOOTFS_MAGIC:
            return set()
        directory = f.read(dirsize)
    names, at = set(), 0
    while at + 12 <= len(directory):
        length, _, _ = struct.unpack_from("<III", directory, at)
        if length == 0 or at + 12 + length > len(directory):
            break
        names.add(directory[at + 12:at + 12 + length].rstrip(b"\0").decode(errors="replace"))
        at += (12 + length + 3) & ~3
    return names


def newest_bootfs(trees, arch):
    found = [os.path.join(t, "build", "boot", arch, "esp", "croi", "bootfs.img") for t in trees]
    found = [p for p in found if os.path.exists(p)]
    return max(found, key=os.path.getmtime) if found else None


def qemu_command(arch, esp, work):
    """td boot's QEMU (qemuCommand), plus its test-mode console options."""
    def vars_copy(template, name, size=None):
        path = os.path.join(work, name)
        if not os.path.exists(path):
            shutil.copyfile(template, path)
            if size:
                os.truncate(path, size)
        return path

    if arch == "amd64":
        q = ["qemu-system-x86_64", "-machine", "q35", "-cpu", "max",
             "-drive", f"if=pflash,format=raw,readonly=on,file={EDK2}/ovmf/OVMF_CODE.fd",
             "-drive", f"if=pflash,format=raw,file={vars_copy(f'{EDK2}/ovmf/OVMF_VARS.fd', 'amd64-vars.fd')}"]
        if os.access("/dev/kvm", os.R_OK | os.W_OK):
            q += ["-accel", "kvm"]
    elif arch == "arm64":
        q = ["qemu-system-aarch64", "-machine", "virt,acpi=on,iommu=smmuv3,gic-version=3", "-cpu", "max",
             "-device", "ramfb",
             "-drive", f"if=pflash,format=raw,readonly=on,file={EDK2}/aarch64/QEMU_EFI-pflash.raw",
             "-drive", f"if=pflash,format=raw,file={vars_copy(f'{EDK2}/aarch64/vars-template-pflash.raw', 'arm64-vars.raw')}"]
    else:
        code = os.path.join(work, "rv64-code.fd")
        if not os.path.exists(code):
            shutil.copyfile(f"{EDK2}/riscv/RISCV_VIRT_CODE.fd", code)
            os.truncate(code, 32 << 20)
        q = ["qemu-system-riscv64", "-machine", "virt,acpi=on", "-cpu", "max", "-device", "ramfb",
             "-drive", f"if=pflash,format=raw,unit=0,readonly=on,file={code}",
             "-drive", f"if=pflash,format=raw,unit=1,file={vars_copy(f'{EDK2}/riscv/RISCV_VIRT_VARS.fd', 'rv64-vars.fd', 32 << 20)}"]
    return q + ["-m", "512M", "-smp", "4", "-net", "none",
                "-drive", f"if=none,format=raw,file=fat:rw:{esp},id=esp", "-device", "virtio-blk-pci,drive=esp",
                "-device", "virtio-rng-pci",
                "-display", "none", "-serial", "stdio", "-monitor", "none", "-no-reboot"]


def boot(arch, esp, work, program, timeout):
    """One boot of `program`: True when userboot says it exited with 0."""
    with open(os.path.join(esp, "croi", "cmdline"), "w") as f:
        f.write(f"userboot.next={program} userboot.shutdown=poweroff croi.selftest=off\n")
    log_path = os.path.join(work, program.replace("/", "-") + ".log")
    done = f"userboot: {program} exited with 0".encode()
    failed = f"userboot: {program} exited with".encode()
    with open(log_path, "wb") as log:
        proc = subprocess.Popen(qemu_command(arch, esp, work), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL, start_new_session=True)
        seen, ok, start = b"", None, time.monotonic()
        os.set_blocking(proc.stdout.fileno(), False)
        while ok is None and time.monotonic() - start < timeout and proc.poll() is None:
            chunk = proc.stdout.read() or b""
            if chunk:
                log.write(chunk)
                seen = (seen + chunk)[-65536:]
                # Whole lines only: "exited with" may arrive before its code.
                lines = seen[:seen.rfind(b"\n") + 1]
                if done + b"\n" in lines or done + b"\r" in lines:
                    ok = True
                elif failed in lines or b"PANIC" in lines:
                    ok = False
            else:
                time.sleep(0.05)
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
        rest = proc.stdout.read() or b""
        log.write(rest)
        if ok is None:  # QEMU exited (it powers off) before the loop judged
            lines = seen + rest
            ok = (done + b"\r" in lines or done + b"\n" in lines) and b"PANIC" not in lines
    if not ok:
        tail = open(log_path, "rb").read()[-3000:].decode(errors="replace")
        print(f"todhchai-check: {arch} {program}: FAILED (console: {log_path})\n{tail}")
        return False
    print(f"todhchai-check: {arch} {program}: ok ({time.monotonic() - start:.1f} s)")
    return True


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("arch", nargs="?", default="amd64", choices=["amd64", "arm64", "rv64"])
    parser.add_argument("--build", help="croi's build tree (default build/<arch>)")
    parser.add_argument("--tree", action="append",
                        help="a Todhchai tree (default ../todhchai and ../todhchai-c0; the newest bootfs wins)")
    parser.add_argument("--program", action="append", help=f"a bootfs program (default: {' '.join(PROGRAMS)})")
    parser.add_argument("--timeout", type=float, default=120)
    args = parser.parse_args()

    build = args.build or os.path.join(root, "build", args.arch)
    trees = args.tree or [os.path.join(root, "..", "todhchai"), os.path.join(root, "..", "todhchai-c0")]
    bootfs = newest_bootfs(trees, args.arch)
    if not bootfs:
        print(f"todhchai-check: no Todhchai bootfs for {args.arch} (run td boot there once): skipped")
        return 77
    names = bootfs_names(bootfs)
    programs = [p for p in (args.program or PROGRAMS) if p in names]
    missing = [p for p in (args.program or PROGRAMS) if p not in names]
    if missing:
        print(f"todhchai-check: not in {bootfs}: {' '.join(missing)}")
    if not programs:
        return 77

    croi_esp = os.path.join(build, "esp")
    work = os.path.join(build, "todhchai")
    esp = os.path.join(work, "esp")
    shutil.rmtree(esp, ignore_errors=True)
    shutil.copytree(croi_esp, esp, ignore=shutil.ignore_patterns("bootfs.img", "cmdline"))
    # A copy, not a link: QEMU's FAT drive is read-write, and Todhchai's
    # tree is never written.
    shutil.copyfile(bootfs, os.path.join(esp, "croi", "bootfs.img"))
    print(f"todhchai-check: {args.arch}, croi from {build}, bootfs {bootfs}")
    ok = all([boot(args.arch, esp, work, p, args.timeout) for p in programs])
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
