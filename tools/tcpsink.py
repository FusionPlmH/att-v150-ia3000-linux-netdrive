#!/usr/bin/env python3
# TCP 打流服务器：连上就满速发 10 秒（或直到对端断开）
import socket, sys, time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 5201
DUR = float(sys.argv[2]) if len(sys.argv) > 2 else 12.0

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('0.0.0.0', PORT))
srv.listen(1)
print('tcpsink listening on %d (%.0fs per run)' % (PORT, DUR), flush=True)
while True:
    c, a = srv.accept()
    print('connect from %s:%d' % a, flush=True)
    buf = b'\x00' * 262144
    total = 0
    t0 = time.time()
    try:
        while time.time() - t0 < DUR:
            total += c.send(buf)
    except Exception:
        pass
    dt = time.time() - t0
    print('SENT %.1f MB in %.2f s = %.1f Mbps' % (total/1e6, dt, total*8/dt/1e6), flush=True)
    try: c.close()
    except Exception: pass
