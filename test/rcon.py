import socket, struct, sys, os

PORT = int(os.environ.get("TS_RCON_PORT", "27016"))
PW = os.environ.get("TS_RCON_PW", "tanksquads")

def main():
    cmd = " ".join(sys.argv[1:])
    with socket.create_connection(("127.0.0.1", PORT), timeout=30) as s:
        def send(i, k, b):
            p = struct.pack("<ii", i, k) + b.encode() + b"\x00\x00"
            s.sendall(struct.pack("<i", len(p)) + p)
        def rx():
            n = struct.unpack("<i", s.recv(4))[0]
            d = b""
            while len(d) < n:
                d += s.recv(n - len(d))
            return struct.unpack("<ii", d[:8])[0], d[8:-2].decode("utf8", "replace")
        send(1, 3, PW)
        if rx()[0] == -1:
            sys.exit("rcon auth failed")
        send(2, 2, cmd)
        sys.stdout.write(rx()[1])

main()
