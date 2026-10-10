#!/usr/bin/env python3
"""Send one command to a QEMU human monitor on a Unix socket, wait for its
prompt to come back, and print the reply (e.g. `info registers -a`).

`backtrace` is croi's own: for every CPU, its PC and the return addresses
along the frame-pointer chain (amd64: rbp; arm64: x29), read through the
monitor's `x` with that CPU's page tables. Symbolize them with
llvm-symbolizer --obj=build/<arch>/kernel/kernel.elf.

Usage: qemu-monitor.py <socket> <command...>
"""

import re
import socket
import sys
import time


class Monitor:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(10)
        self.sock.connect(path)
        self.until_prompt()

    def until_prompt(self):
        data = b""
        while not data.endswith(b"(qemu) "):
            chunk = self.sock.recv(4096)
            if not chunk:
                break
            data += chunk
        return data

    def command(self, text):
        self.sock.sendall(text.encode() + b"\n")
        reply = self.until_prompt().decode(errors="replace").replace("\r", "")
        # Drop the echoed command line and the trailing prompt.
        lines = reply.split("\n")[1:]
        if lines and lines[-1].startswith("(qemu)"):
            lines = lines[:-1]
        return "\n".join(lines)


def backtrace(monitor):
    cpus = monitor.command("info cpus")
    for index in [int(m) for m in re.findall(r"CPU #(\d+)", cpus)]:
        monitor.command(f"cpu {index}")
        registers = monitor.command("info registers")
        pc = re.search(r"\b(?:RIP|PC)=([0-9a-f]+)", registers)
        fp = re.search(r"\bRBP=([0-9a-f]+)", registers) or re.search(r"\bX29=([0-9a-f]+)", registers)
        flags = re.search(r"\bRFL=([0-9a-f]+)", registers)
        line = f"cpu {index}: pc {pc.group(1) if pc else '?'}"
        if flags:
            line += f" (interrupts {'on' if int(flags.group(1), 16) & 0x200 else 'masked'})"
        frames = []
        address = int(fp.group(1), 16) if fp else 0
        for _ in range(24):
            if address == 0 or address % 8:
                break
            words = re.findall(r":\s*0x([0-9a-f]+)\s+0x([0-9a-f]+)", monitor.command(f"x/2gx {address:#x}"))
            if not words:
                break
            previous, ret = int(words[0][0], 16), int(words[0][1], 16)
            if ret == 0:
                break
            frames.append(f"{ret:x}")
            if previous <= address:
                break
            address = previous
        print(line + (" <- " + " <- ".join(frames) if frames else ""))


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__.strip().splitlines()[-1])
    monitor = Monitor(argv[1])
    if argv[2] == "backtrace":
        backtrace(monitor)
    else:
        reply = monitor.command(" ".join(argv[2:]))
        sys.stdout.write(reply + ("\n" if reply else ""))
    time.sleep(0.2)  # let QEMU finish writing any output file


if __name__ == "__main__":
    main(sys.argv)
