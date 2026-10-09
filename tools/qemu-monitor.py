#!/usr/bin/env python3
"""Send one command to a QEMU human monitor on a Unix socket, wait for its
prompt to come back, and print the reply (e.g. `info registers -a`).

Usage: qemu-monitor.py <socket> <command...>
"""

import socket
import sys
import time


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__.strip().splitlines()[-1])
    sock = socket.socket(socket.AF_UNIX)
    sock.settimeout(10)
    sock.connect(argv[1])

    def until_prompt():
        data = b""
        while not data.endswith(b"(qemu) "):
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
        return data

    until_prompt()
    sock.sendall(" ".join(argv[2:]).encode() + b"\n")
    reply = until_prompt().decode(errors="replace").replace("\r", "")
    # Drop the echoed command line and the trailing prompt.
    lines = reply.split("\n")[1:]
    if lines and lines[-1].startswith("(qemu)"):
        lines = lines[:-1]
    sys.stdout.write("\n".join(lines) + ("\n" if lines else ""))
    time.sleep(0.2)  # let QEMU finish writing any output file


if __name__ == "__main__":
    main(sys.argv)
