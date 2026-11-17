#!/usr/bin/env python3
import socket, struct, sys, time

ETH_P_ALL = 3

def m2b(s):
    return bytes.fromhex(s.replace(':', ''))

def send(iface, count, dst, src, vid, gap=0.003):
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ALL))
    s.bind((iface, 0))
    hdr = m2b(dst) + m2b(src)
    if vid:
        hdr += struct.pack('!HH', 0x8100, vid & 0xfff)
    hdr += struct.pack('!H', 0x0800)
    body = bytes([0x41] * 46)
    for i in range(count):
        s.send(hdr + body)
        if gap:
            time.sleep(gap)
    s.close()
    print('sent %d frames vid=%s on %s' % (count, vid if vid else 'untagged', iface))

def sniff(iface, seconds, maxframes, wanttx=0):
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ALL))
    s.bind((iface, 0))
    s.settimeout(0.2)
    t0 = time.time()
    n = 0
    print('sniffing %s for %.1fs (max %d, tx=%d)' % (iface, seconds, maxframes, wanttx))
    while time.time() - t0 < seconds and n < maxframes:
        try:
            f, addr = s.recvfrom(2048)
        except socket.timeout:
            continue
        out = addr[2] == socket.PACKET_OUTGOING
        if out and not wanttx:
            continue
        tag = 'TX' if out else 'RX'
        et = struct.unpack('!H', f[12:14])[0]
        if et == 0x8100:
            vid = struct.unpack('!H', f[14:16])[0] & 0xfff
            print('  %s #%d dst=%s src=%s TAGGED vid=%d len=%d' %
                  (tag, n, f[0:6].hex(':'), f[6:12].hex(':'), vid, len(f)))
        else:
            print('  %s #%d dst=%s src=%s UNTAGGED et=0x%04x len=%d' %
                  (tag, n, f[0:6].hex(':'), f[6:12].hex(':'), et, len(f)))
        n += 1
    s.close()
    print('captured %d frames on %s' % (n, iface))

if __name__ == '__main__':
    if sys.argv[1] == 'send':
        send(sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5], int(sys.argv[6]))
    elif sys.argv[1] == 'sniff':
        sniff(sys.argv[2], float(sys.argv[3]), int(sys.argv[4]),
              int(sys.argv[5]) if len(sys.argv) > 5 else 0)
    else:
        print('usage: c2c.py send|sniff ...')
