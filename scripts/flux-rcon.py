#!/usr/bin/env python3
"""flux-rcon: one command to the running Rust server over its WebRCON, the answer on stdout.

    flux-rcon "say Server restart in 5 minutes"
    flux-rcon --quiet server.save

Rust's RCON is a WebSocket at ws://<host>:<rcon.port>/<rcon.password> carrying JSON messages.
The port and the password are the ones the server was started with: the supervisor writes them
to FLUX_RCON_ENV for each generation. Standard library only: the image carries no websocket
package, and a client this small is easier to keep right than a dependency.

Exit codes: 0 answered, 1 no server / refused / timed out, 2 usage.
"""
import base64
import json
import os
import socket
import struct
import sys
import urllib.parse

RCON_ENV = os.environ.get("FLUX_RCON_ENV", "/tmp/flux/rcon.env")
IDENTIFIER = 1001


def read_env(path):
    out = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                key, sep, value = line.rstrip("\n").partition("=")
                if sep:
                    out[key] = value
    except OSError:
        pass
    return out


def frame(payload, opcode=0x1):
    """A client frame: FIN, the opcode, and the payload masked, as RFC 6455 requires."""
    data = payload.encode("utf-8") if isinstance(payload, str) else payload
    head = bytes([0x80 | opcode])
    n = len(data)
    if n < 126:
        head += bytes([0x80 | n])
    elif n < 65536:
        head += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        head += bytes([0x80 | 127]) + struct.pack(">Q", n)
    mask = os.urandom(4)
    return head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data))


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    return buf


def read_frame(sock):
    """One server frame -> (opcode, payload). Fragments are joined."""
    payload = b""
    while True:
        b1, b2 = recv_exact(sock, 2)
        opcode = b1 & 0x0F
        n = b2 & 0x7F
        if n == 126:
            n = struct.unpack(">H", recv_exact(sock, 2))[0]
        elif n == 127:
            n = struct.unpack(">Q", recv_exact(sock, 8))[0]
        if b2 & 0x80:
            mask = recv_exact(sock, 4)
            data = bytes(b ^ mask[i % 4] for i, b in enumerate(recv_exact(sock, n)))
        else:
            data = recv_exact(sock, n)
        payload += data
        if b1 & 0x80:
            return opcode, payload


def rcon(command, host, port, password, timeout):
    sock = socket.create_connection((host, port), timeout=timeout)
    try:
        key = base64.b64encode(os.urandom(16)).decode()
        path = "/" + urllib.parse.quote(password, safe="")
        sock.sendall(
            (
                f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
                f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
            ).encode()
        )
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = sock.recv(1024)
            if not chunk:
                raise ConnectionError("closed during the handshake")
            head += chunk
        status = head.split(b"\r\n", 1)[0]
        if b" 101 " not in status + b" ":
            raise ConnectionError(f"refused: {status.decode(errors='replace')}")
        sock.sendall(frame(json.dumps({"Identifier": IDENTIFIER, "Message": command, "Name": "WebRcon"})))
        while True:
            opcode, data = read_frame(sock)
            if opcode == 0x8:
                raise ConnectionError("closed by the server")
            if opcode == 0x9:
                sock.sendall(frame(data, 0xA))
                continue
            if opcode != 0x1:
                continue
            try:
                msg = json.loads(data.decode("utf-8", errors="replace"))
            except ValueError:
                continue
            if msg.get("Identifier") == IDENTIFIER:
                return msg.get("Message", "")
    finally:
        try:
            sock.sendall(frame(b"", 0x8))
        except OSError:
            pass
        sock.close()


def main(argv):
    quiet = False
    args = []
    for a in argv:
        if a == "--quiet":
            quiet = True
        else:
            args.append(a)
    if not args:
        print("usage: flux-rcon [--quiet] <command...>", file=sys.stderr)
        return 2
    env = read_env(RCON_ENV)
    port = env.get("RCON_PORT") or os.environ.get("FLUX_RCON_PORT") or "28016"
    password = env.get("RCON_PASSWORD") or os.environ.get("RCON_PASSWORD") or ""
    if not password:
        print("flux-rcon: the server has no RCON password", file=sys.stderr)
        return 1
    timeout = float(os.environ.get("FLUX_RCON_TIMEOUT", "10"))
    try:
        answer = rcon(" ".join(args), "127.0.0.1", int(port), password, timeout)
    except (OSError, ConnectionError, ValueError) as e:
        print(f"flux-rcon: {e}", file=sys.stderr)
        return 1
    if not quiet and answer:
        print(answer)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
