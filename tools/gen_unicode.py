#!/usr/bin/env python3
"""Generates src/elz/unicode.zig from Python's bundled Unicode database.

Run from the repository root:  python3 tools/gen_unicode.py
"""
import unicodedata as ud
MAX = 0x110000

def cps(s):
    return [ord(c) for c in s]

def ranges(pred):
    out = []
    start = None
    for cp in range(MAX):
        ok = pred(cp)
        if ok and start is None:
            start = cp
        if not ok and start is not None:
            out.append((start, cp - 1))
            start = None
    if start is not None:
        out.append((start, MAX - 1))
    return out

def is_alpha(cp):
    c = chr(cp)
    return c.isalpha() or ud.category(c) == 'Nl'

WHITE_SPACE = {0x9, 0xA, 0xB, 0xC, 0xD, 0x20, 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000} | set(range(0x2000, 0x200B))

def dec(cp):
    try:
        return ud.decimal(chr(cp))
    except ValueError:
        return None

def simple_map(fn):
    m = {}
    for cp in range(MAX):
        if 0xD800 <= cp <= 0xDFFF:
            continue
        r = fn(chr(cp))
        if len(r) == 1 and ord(r) != cp:
            m[cp] = ord(r)
    return m

def sfold(c):
    f = c.casefold()
    if len(f) == 1:
        return f
    l = c.lower()
    return l if len(l) == 1 else c

def runs(m):
    covered = set()
    out = []
    for cp in sorted(m):
        if cp in covered:
            continue
        d = m[cp] - cp
        best = None
        for step in (1, 2):
            n = 1
            while cp + n * step in m and m[cp + n * step] - (cp + n * step) == d and (cp + n * step) not in covered:
                n += 1
            if best is None or n > best[1]:
                best = (step, n)
        step, n = best
        for k in range(n):
            covered.add(cp + k * step)
        out.append((cp, cp + (n - 1) * step, d, step))
    return out

def specials(fn, simple):
    out = []
    for cp in range(MAX):
        if 0xD800 <= cp <= 0xDFFF:
            continue
        r = cps(fn(chr(cp)))
        if r != [simple.get(cp, cp)] and r != [cp]:
            out.append((cp, r))
    return out

def zr(t):
    return ",\n".join(f"    .{{ .lo = 0x{lo:X}, .hi = 0x{hi:X} }}" for lo, hi in t)

def zm(t):
    return ",\n".join(f"    .{{ .lo = 0x{lo:X}, .hi = 0x{hi:X}, .delta = {d}, .step = {s} }}" for lo, hi, d, s in t)

def zs(t):
    lines = []
    for cp, r in t:
        pad = r + [0] * (3 - len(r))
        lines.append(f"    .{{ .cp = 0x{cp:X}, .len = {len(r)}, .to = .{{ 0x{pad[0]:X}, 0x{pad[1]:X}, 0x{pad[2]:X} }} }}")
    return ",\n".join(lines)

def main():
    alpha = ranges(is_alpha)
    upper = ranges(lambda cp: chr(cp).isupper())
    lower = ranges(lambda cp: chr(cp).islower())
    space = ranges(lambda cp: cp in WHITE_SPACE)
    digits = ranges(lambda cp: dec(cp) is not None)
    for lo, hi in digits:
        assert (hi - lo + 1) % 10 == 0 and dec(lo) == 0, (hex(lo), hex(hi))
    sup = simple_map(str.upper)
    slo = simple_map(str.lower)
    sfo = simple_map(sfold)
    spu = specials(str.upper, sup)
    spl = specials(str.lower, slo)
    spf = specials(str.casefold, sfo)
    assert all(len(r) <= 3 for _, r in spu + spl + spf)
    template = open('tools/unicode_template.zig.txt').read()
    out = template.replace('@@VERSION@@', ud.unidata_version)
    for key, text in [('ALPHA', zr(alpha)), ('UPPER', zr(upper)), ('LOWER', zr(lower)), ('SPACE', zr(space)), ('DIGITS', zr(digits)),
                      ('RUP', zm(runs(sup))), ('RLO', zm(runs(slo))), ('RFO', zm(runs(sfo))), ('SPU', zs(spu)), ('SPL', zs(spl)), ('SPF', zs(spf))]:
        out = out.replace('@@' + key + '@@', text)
    open('src/elz/unicode.zig', 'w').write(out)

if __name__ == '__main__':
    main()
