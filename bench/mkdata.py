#!/usr/bin/env python3
"""Create a deterministic test tree for smartcopy benchmarks and tests.

  mkdata.py DIR --files N [--dirs D] [--median BYTES] [--big K --big-mb M] [--seed S] [--odd-names]

File sizes follow a log-normal distribution around --median. --odd-names adds names with
spaces, accents, emoji, a tab, a newline, a backslash sequence and the marker word SECRETNAME
(used by the privacy tests to prove names never reach the screen or the report).
"""
import argparse, os, random

ap = argparse.ArgumentParser()
ap.add_argument("dir"); ap.add_argument("--files", type=int, required=True)
ap.add_argument("--dirs", type=int, default=0); ap.add_argument("--median", type=int, default=8192)
ap.add_argument("--big", type=int, default=0); ap.add_argument("--big-mb", type=int, default=128)
ap.add_argument("--seed", type=int, default=1); ap.add_argument("--odd-names", action="store_true")
a = ap.parse_args()
rnd = random.Random(a.seed)
ndirs = a.dirs or max(1, a.files // 20)
dirs = []
for i in range(ndirs):                      # three levels deep
    d = os.path.join(a.dir, "L1-%03d" % (i % 50), "L2-%03d" % (i // 50 % 50), "L3-%05d" % i)
    os.makedirs(d, exist_ok=True); dirs.append(d)
blob = rnd.randbytes(4 << 20)
total = 0
for i in range(a.files):
    sz = min(int(rnd.lognormvariate(0, 1.2) * a.median), 4 << 20)
    off = rnd.randrange(0, len(blob) - sz + 1)
    with open(os.path.join(dirs[i % ndirs], "file-%07d.dat" % i), "wb") as f:
        f.write(blob[off:off + sz]); f.write(i.to_bytes(8, "little"))   # every file unique
    total += sz + 8
for i in range(a.big):
    p = os.path.join(a.dir, "big", "big-%02d.bin" % i); os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as f:
        for _ in range(a.big_mb // 4): f.write(rnd.randbytes(4 << 20))
    total += a.big_mb << 20
if a.odd_names:
    odd = os.path.join(a.dir, "odd SECRETNAME dir")
    os.makedirs(odd, exist_ok=True)
    for n in ["SECRETNAME café.txt", "SECRETNAME 日本語.txt", "SECRETNAME 🙂.txt", "SECRETNAME\ttab.txt",
              "SECRETNAME\nnewline.txt", "SECRETNAME back\\#011slash.txt", "SECRETNAME  two  spaces .txt",
              "SECRETNAME -> arrow.txt", "SECRETNAME => arrow.txt", "-SECRETNAME-dash.txt"]:
        with open(os.path.join(odd, n), "wb") as f: f.write(n.encode() * 50); total += len(n.encode()) * 50
    os.symlink("SECRETNAME café.txt", os.path.join(odd, "SECRETNAME link"))
    os.link(os.path.join(odd, "SECRETNAME café.txt"), os.path.join(odd, "SECRETNAME hardlink.txt"))
print(total)
