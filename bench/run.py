#!/usr/bin/env python3
"""Run smartcopy once and measure it (Linux test bed; see bench/README.md).

  run.py SCRIPT [--strace] [--stop-after SECS] [--no-drop] -- SMARTCOPY-ARGS...

Prints one JSON object:
  wall_s            elapsed time of the whole run (to the report = fully verified completion)
  cpu_user_s/sys_s  CPU used by smartcopy and every child it waited for (rsync, awk, sort, ...)
  peak_tree_rss_mb  highest combined resident memory of the whole process tree (sampled 4x/s)
  peak_proc_rss_mb  largest single process (getrusage)
  first_transfer_s  time until the first file appears on the destination
  copy_s            time from "STEP 2" to the next step (the main copy), when present
  steps             seconds at which each STEP line appeared
  exit              exit code
With --strace (a separate run; strace slows things down) it adds syscall counts:
  execs, forks, metadata_calls (stat/lstat/statx/access/readlink/xattr reads),
  opens, getdents, fs_writes (create/rename/unlink/mkdir/chmod/utime/xattr writes), syscalls.
"""
import json, os, re, signal, subprocess, sys, threading, time

args = sys.argv[1:]
script = args.pop(0)
opt = {"strace": False, "stop": None, "drop": True}
while args and args[0] != "--":
    a = args.pop(0)
    if a == "--strace": opt["strace"] = True
    elif a == "--stop-after": opt["stop"] = float(args.pop(0))
    elif a == "--no-drop": opt["drop"] = False
args.pop(0)
dst = args[-1]

if opt["drop"]:
    os.sync()
    try:
        open("/proc/sys/vm/drop_caches", "w").write("3\n")
    except OSError:
        pass

env = dict(os.environ)
env["PATH"] = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests", "stubs") + ":" + env["PATH"]
cmd = ["bash", script, "--yes"] + args
straceout = None
if opt["strace"]:
    straceout = "/tmp/sc-strace.%d" % os.getpid()
    cmd = ["strace", "-f", "-c", "-o", straceout] + cmd

t0 = time.monotonic()
p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, start_new_session=True)
steps, lines = {}, []
first = [None]
peak = [0]
done = threading.Event()

def reader():
    buf = b""
    for chunk in iter(lambda: p.stdout.read1(65536), b""):
        buf += chunk
        while True:
            m = re.search(rb"[\r\n]", buf)
            if not m: break
            line, buf = buf[:m.start()].decode("utf-8", "replace"), buf[m.end():]
            lines.append(line)
            s = re.search(r"STEP (\d+) of \d+: (.*?) ━", line)
            if s: steps[s.group(1) + " " + s.group(2)] = round(time.monotonic() - t0, 2)
    if buf: lines.append(buf.decode("utf-8", "replace"))

def tree_rss():
    kids, rss = {}, {}
    for d in os.listdir("/proc"):
        if not d.isdigit(): continue
        try:
            st = open("/proc/%s/stat" % d).read()
            f = st[st.rindex(")") + 2:].split()
            kids.setdefault(int(f[1]), []).append(int(d)); rss[int(d)] = int(f[21]) * 4096
        except (OSError, ValueError, IndexError):
            pass
    tot, todo = 0, [p.pid]
    while todo:
        x = todo.pop(); tot += rss.get(x, 0); todo += kids.get(x, [])
    return tot

def has_file(d):
    try:
        with os.scandir(d) as it:
            for e in it:
                if e.name == "rsync-logs" or e.name.startswith(".smartcopy"): continue
                if e.is_file(follow_symlinks=False): return True
                if e.is_dir(follow_symlinks=False) and has_file(e.path): return True
    except OSError:
        pass
    return False

def sampler():
    while not done.is_set():
        peak[0] = max(peak[0], tree_rss())
        if first[0] is None and has_file(dst): first[0] = round(time.monotonic() - t0, 2)
        if opt["stop"] and time.monotonic() - t0 > opt["stop"]:
            os.killpg(p.pid, signal.SIGTERM) if opt["strace"] else os.kill(p.pid, signal.SIGTERM)
            opt["stop"] = None
        time.sleep(0.25)

rt = threading.Thread(target=reader); rt.start()
st = threading.Thread(target=sampler); st.start()
_, status, ru = os.wait4(p.pid, 0)
wall = time.monotonic() - t0
done.set(); rt.join(); st.join()
res = {
    "wall_s": round(wall, 2), "cpu_user_s": round(ru.ru_utime, 2), "cpu_sys_s": round(ru.ru_stime, 2),
    "peak_tree_rss_mb": round(peak[0] / 1048576, 1), "peak_proc_rss_mb": round(ru.ru_maxrss / 1024, 1),
    "first_transfer_s": first[0], "steps": steps, "exit": os.waitstatus_to_exitcode(status),
}
ks = sorted(steps.items(), key=lambda kv: kv[1])
for i, (k, v) in enumerate(ks):
    if "Copy the files" in k:
        res["copy_s"] = round((ks[i + 1][1] if i + 1 < len(ks) else wall) - v, 2)
if straceout:
    c = {}
    for line in open(straceout):
        f = line.split()
        if len(f) >= 5 and f[-1].isidentifier() and f[-1] != "total" and f[3].isdigit():
            c[f[-1]] = int(f[3])
        elif len(f) == 4 and f[-1].isidentifier() and f[2].isdigit():   # no errors column
            c[f[-1]] = int(f[2])
    g = lambda names: sum(c.get(n, 0) for n in names)
    res.update({
        "execs": g(["execve"]), "forks": g(["clone", "clone3", "fork", "vfork"]),
        "metadata_calls": g(["stat", "lstat", "fstat", "newfstatat", "statx", "access", "faccessat", "faccessat2",
                             "readlink", "readlinkat", "getxattr", "lgetxattr", "listxattr", "llistxattr", "statfs", "fstatfs"]),
        "opens": g(["open", "openat"]), "getdents": g(["getdents", "getdents64"]),
        "fs_writes": g(["rename", "renameat", "renameat2", "unlink", "unlinkat", "mkdir", "mkdirat", "chmod", "fchmod",
                        "fchmodat", "chown", "fchown", "lchown", "fchownat", "utimensat", "setxattr", "lsetxattr", "rmdir"]),
        "syscalls": sum(c.values()),
    })
    os.unlink(straceout)
res["tail"] = [l for l in lines if l.strip()][-3:]
print(json.dumps(res))
