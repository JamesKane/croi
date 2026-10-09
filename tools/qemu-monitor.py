#!/usr/bin/env python3
"""Send one command to a QEMU human monitor on a Unix socket and wait for
its prompt to come back.

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
    until_prompt()
    time.sleep(0.2)  # let QEMU finish writing any output file


if __name__ == "__main__":
    main(sys.argv)
