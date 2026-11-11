#!/usr/bin/env python3
import socket, sys
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 19090
N    = int(sys.argv[2]) if len(sys.argv) > 2 else 4095
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", PORT)); s.listen(16)
print("fake upstream :%d, sending %d bytes" % (PORT, N), flush=True)
while True:
    conn, _ = s.accept()
    try:
        conn.sendall(b"A" * N); conn.shutdown(socket.SHUT_WR)  # данные + EOF
    except OSError: pass
    finally: conn.close()
