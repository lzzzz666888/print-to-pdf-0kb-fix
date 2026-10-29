import numpy as np, struct, os, glob, sys, time

def pe_checksum_ok(path):
    try:
        with open(path, 'rb') as f:
            d = f.read()
    except Exception:
        return None
    if len(d) < 0x40 or d[:2] != b'MZ':
        return None
    try:
        pe = struct.unpack_from('<I', d, 0x3c)[0]
        if d[pe:pe+4] != b'PE\x00\x00':
            return None
        opt = pe + 24
        stored = struct.unpack_from('<I', d, opt + 64)[0]
    except Exception:
        return None
    if stored == 0:
        return ('NOCHK', 0, 0)
    a = bytearray(d)
    a[opt + 64:opt + 68] = b'\x00\x00\x00\x00'
    n = len(a)
    odd = n & 1
    body = np.frombuffer(bytes(a[:n - odd]), dtype='<u2').astype(np.uint64)
    s = int(body.sum())
    if odd:
        s += a[n - 1]
    while s > 0xFFFF:
        s = (s & 0xFFFF) + (s >> 16)
    calc = ((s & 0xFFFF) + n) & 0xFFFFFFFF
    return ('OK' if calc == stored else 'BAD', stored, calc)

roots = [
    (r'C:\Windows\System32', '*.exe'),
    (r'C:\Windows\System32', '*.dll'),
    (r'C:\Windows\System32\drivers', '*.sys'),
]

bad = []
nochk = 0
total = 0
t0 = time.time()
for root, pat in roots:
    files = glob.glob(os.path.join(root, pat))
    print(f'扫描 {root}\\{pat}  共 {len(files)} 个文件', flush=True)
    for i, f in enumerate(files):
        r = pe_checksum_ok(f)
        if r is None:
            continue
        total += 1
        if r[0] == 'BAD':
            bad.append((f, os.path.getsize(f), r[1], r[2]))
            print('  [BAD] %s  存储=0x%08X 实算=0x%08X' % (f, r[1], r[2]), flush=True)
        elif r[0] == 'NOCHK':
            nochk += 1
        if (i + 1) % 1000 == 0:
            print(f'  ...已检查 {i+1}/{len(files)}', flush=True)

print()
print('=' * 60)
print('检查的 PE 文件数 : %d' % total)
print('未设置校验和     : %d' % nochk)
print('校验和不匹配     : %d' % len(bad))
print('耗时             : %.1f 秒' % (time.time() - t0))
if bad:
    print()
    print('不匹配清单:')
    for f, sz, st, ca in bad:
        print('  %-70s %10d 字节  存储=0x%08X 实算=0x%08X' % (f, sz, st, ca))
