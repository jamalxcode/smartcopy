#!/usr/bin/env python3
"""Turn bench results into Markdown tables:  summarize.py e2e.jsonl micro.jsonl"""
import json, sys
from collections import defaultdict

def load(p):
    return [json.loads(l) for l in open(p) if l.strip().startswith("{")]

def pct(o, n):
    return "" if not o else "%+.0f%%" % ((n - o) / o * 100)

e2e = load(sys.argv[1])
by = defaultdict(dict)
for r in e2e:
    by[(r["dataset"], r["scenario"])][r["version"]] = r["result"]
cols = [("wall_s", "Wall time (s)"), ("cpu", "CPU user+sys (s)"), ("peak_tree_rss_mb", "Peak memory, whole tree (MB)"),
        ("peak_proc_rss_mb", "Largest process (MB)"), ("first_transfer_s", "Time to first transfer (s)"),
        ("copy_s", "Copy step (s)"), ("tput", "Copy throughput (MB/s)")]
scol = [("execs", "Programs started"), ("forks", "Processes/threads created"), ("metadata_calls", "Metadata calls (stat, xattr...)"),
        ("opens", "File opens"), ("getdents", "Directory reads"), ("fs_writes", "File-system changes"), ("syscalls", "All system calls"),
        ("wall_s", "Wall time under strace (s)")]
SIZES = {"mixed": 50000, "tiny": 250000}
for (ds, sc), v in sorted(by.items()):
    if sc == "interrupted" or "old" not in v or "new" not in v: continue
    o, n = v["old"], v["new"]
    for r in (o, n):
        r["cpu"] = round(r["cpu_user_s"] + r["cpu_sys_s"], 2)
        if r.get("copy_s") and sc.startswith("first-copy"):
            r["tput"] = round(r.get("_bytes", 0) / r["copy_s"] / 1e6, 1) if r.get("_bytes") else None
    print("\n#### %s — %s (exit codes: old %s, new %s)\n" % (ds, sc, o["exit"], n["exit"]))
    print("| | v12.2 | v12.3 | change |\n|---|---:|---:|---:|")
    for k, label in (scol if sc.endswith("strace") else cols):
        a, b = o.get(k), n.get(k)
        if a is None and b is None: continue
        print("| %s | %s | %s | %s |" % (label, a, b, pct(a, b) if isinstance(a, (int, float)) and isinstance(b, (int, float)) else ""))
    if not sc.endswith("strace"):
        print("| Steps (s from start) | %s | %s | |" % (", ".join("%s %s" % (k.split()[0], t) for k, t in o["steps"].items()),
                                                      ", ".join("%s %s" % (k.split()[0], t) for k, t in n["steps"].items())))

if len(sys.argv) > 2:
    m = load(sys.argv[2])
    ops = defaultdict(dict)
    for r in m:
        ops[(r["op"], r["files"])][r["version"]] = r
    print("\n| Operation | Files | v12.2 time (s) | v12.3 time (s) | v12.2 peak memory (MB) | v12.3 peak memory (MB) |\n|---|---:|---:|---:|---:|---:|")
    for (op, nf), v in sorted(ops.items(), key=lambda x: (["check-dest", "select", "save", "poll", "report"].index(x[0][0]), x[0][1])):
        o, n = v.get("old"), v.get("new")
        print("| %s | %s | %s | %s | %s | %s |" % (op, f"{nf:,}", o["seconds"] if o else "—", n["seconds"], o["peak_rss_mb"] if o else "—", n["peak_rss_mb"]))
