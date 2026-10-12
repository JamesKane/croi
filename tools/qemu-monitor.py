#!/usr/bin/env python3
"""Send one command to a QEMU human monitor on a Unix socket, wait for its
prompt to come back, and print the reply (e.g. `info registers -a`).

`backtrace` is croi's own: for every CPU, its PC and the return addresses
along the frame-pointer chain (amd64: rbp; arm64: x29), read through the
monitor's `x` with that CPU's page tables. Symbolize them with
llvm-symbolizer --obj=build/<arch>/kernel/kernel.elf. With KASLR the kernel
runs away from its link address: `backtrace <start> <end> <link>` (the
kernel's `kaslr: image <start>-<end>, link <link>` line; qemu.sh passes it)
prints addresses in the image as link addresses, ready for the symbolizer.

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


def backtrace(monitor, image=None):
    def at_link(address):
        # arm64 return addresses are signed (K14p): the PAC bits off first
        # (bit 55 says which half), a no-op for canonical addresses.
        address = address | 0xFFFF000000000000 if (address >> 55) & 1 else address & 0x0000FFFFFFFFFFFF
        if image and image[0] <= address < image[1]:
            return address - image[0] + image[2]
        return address

    cpus = monitor.command("info cpus")
    for index in [int(m) for m in re.findall(r"CPU #(\d+)", cpus)]:
        monitor.command(f"cpu {index}")
        registers = monitor.command("info registers")
        pc = re.search(r"\b(?:RIP|PC)=([0-9a-f]+)", registers)
        fp = re.search(r"\bRBP=([0-9a-f]+)", registers) or re.search(r"\bX29=([0-9a-f]+)", registers)
        flags = re.search(r"\bRFL=([0-9a-f]+)", registers)
        line = f"cpu {index}: pc {at_link(int(pc.group(1), 16)):x}" if pc else f"cpu {index}: pc ?"
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
            frames.append(f"{at_link(ret):x}")
            if previous <= address:
                break
            address = previous
        print(line + (" <- " + " <- ".join(frames) if frames else ""))


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__.strip().splitlines()[-1])
    monitor = Monitor(argv[1])
    if argv[2] == "backtrace":
        image = [int(word, 16) for word in argv[3:6]] if len(argv) >= 6 else None
        if image:
            print("(kernel addresses below are link addresses)")
        backtrace(monitor, image)
    else:
        reply = monitor.command(" ".join(argv[2:]))
        sys.stdout.write(reply + ("\n" if reply else ""))
    time.sleep(0.2)  # let QEMU finish writing any output file


if __name__ == "__main__":
    main(sys.argv)
