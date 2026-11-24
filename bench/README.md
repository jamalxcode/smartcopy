# Benchmarks

Two reproducible benchmarks compare smartcopy versions. Both run on Linux, where loop-mounted ext4 images stand in for Mac drives and `tests/stubs/` stands in for the macOS tools (`diskutil`, `mdutil`, `caffeinate`, ...). They need root, rsync 3.2+ (linked as `/usr/local/bin/rsync`), `mkfs.ext4`, `strace`, GNU `time` and python3.

Results for v12.2 against v12.3 are in [../docs/PERFORMANCE.md](../docs/PERFORMANCE.md).

## End to end: `bench.sh`

```bash
git show 8005cbd:smartcopy.sh > /tmp/smartcopy-v12.2.sh      # the version to compare against
sudo bench/bench.sh results.jsonl old=/tmp/smartcopy-v12.2.sh new=./smartcopy.sh
```

For each dataset it generates a deterministic source tree (`mkdata.py`, seed 1), then for each version runs:

| Scenario | What is measured |
|---|---|
| `first-copy` | copy + check into an empty, freshly formatted destination |
| `verify-only-rerun` | `--verify-only` on that finished copy |
| `first-copy-strace` | the same first copy under `strace -f -c`: programs started, metadata calls (stat, lstat, xattr reads...), opens, directory reads, file-system writes, all system calls |
| `interrupted` + `resume-after-interrupt` | stopped halfway through copying, then run again; the second run is measured |

Caches are dropped before every run. `run.py` records wall time (= fully verified completion), CPU (smartcopy and every child it waited for), peak memory of the whole process tree (sampled 4×/s) and of the largest single process, time until the first file appears on the destination, and the time spent in step 2 (copying).

Datasets: `mixed` (50,000 files, median 8 KB, plus six 128 MB files; 1.65 GB) and `tiny` (250,000 files of about 600 bytes). Set `DATASETS="mixed"` to run one.

## File lists at scale: `micro.sh`

```bash
bench/micro.sh 100000 300000 1000000 3000000
```

This times smartcopy's own list handling, with no copying, on synthetic lists of N files, and records peak memory: the destination-only check, choosing how each file is checked, saving fingerprints, one progress refresh and the report figures. The v12.2 code is included verbatim for comparison, and is skipped above `OLD_MAX` files (default 1,000,000). It needs only bash, awk, sort and GNU time (no root).
