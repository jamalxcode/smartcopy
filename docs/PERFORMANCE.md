# Performance

Measurements of v12.3 against v12.2 (list handling), and of v13's streaming engine against the batch engine ([below](#v13-streaming-engine-against-batch-engine)).

## v12.2 → v12.3

v12.3 removes avoidable work from everything smartcopy does around rsync, without changing how files are copied. This page has the measurements, how they were taken and how to reproduce them.

### In short

| | v12.2 | v12.3 |
|---|---|---|
| Copy + full check, 250,000 small files | 91 s | **50 s** (−45%) |
| Copy + full check, 50,000 mixed files (1.65 GB), median of 3 | 25.4 s | **15.5 s** (−38%) |
| Time until the first file is copied (mixed) | 4.3 s | **2.8 s** |
| Programs started / metadata system calls (mixed, strace) | 2,504 / 2.20 M | **2,055 / 1.66 M** (−18% / −24%) |
| Resume after an interruption, then check (mixed / tiny) | 25.9 s / 53.9 s | **17.7 s / 44.1 s** |
| Destination-only check, 1,000,000 files (list handling only) | 599 s, 176 MB | **3.9 s, 4.6 MB** |
| How its own work grows with the number of files | partly quadratic | linear (plus one sort) |
| Its own peak memory, 3,000,000 files | grows with the file count | **bounded: ≈260 MB** (sort's buffer) |

The copying itself is rsync's and runs at about the same speed (the copy step measured 219 → 241 MB/s): the gains come from fewer passes over the drives, list handling that doesn't grow with the square of the number of files, and fewer programs started. On a real Mac the absolute times differ (USB drives, exFAT), but the work removed is the same.

### Test bed

- Linux container, 4 vCPUs, 16 GB RAM; rsync 3.2.7 (xxh128); mawk 1.3.4 as `awk` (BWK awk, as on macOS, was checked separately for correctness); GNU sort.
- Source and destination are separate ext4 images, loop-mounted at `/Volumes/SCSRC` and `/Volumes/SCDST`, on the same virtual disk. The destination is reformatted before every fresh run, and the page cache is dropped before every run.
- macOS tools are replaced by stand-ins (`tests/stubs/`): the destination reports itself as APFS on an SSD, so the APFS code path (hard links, ACLs, extended attributes, `--no-inc-recursive`) is the one measured, with 4 copies at a time.
- Datasets from `bench/mkdata.py` (seed 1): **mixed**: 50,000 files in 2,500 folders, median 8 KB, plus six 128 MB files (1.65 GB in all); **tiny**: 250,000 files of about 600 bytes in 5,000 folders.
- The per-scenario tables below are single runs; the mixed first copy was repeated three times, interleaved, to gauge noise (wall time varied by about ±3% within a version). Timings this short are dominated by per-file work, which is what changed.

The v12.2 baseline was recorded before any change was made (`bench/results/baseline-v12.2-before-changes.jsonl`) and again alongside v12.3 (`bench/results/e2e.jsonl`). The final v12.3 code was measured once more after the last fixes (`bench/results/e2e-final.jsonl`).

### End to end

Each table is one run of each version in the same session (`bench/results/e2e.jsonl`). Wall time is the time to a fully verified finish.

#### mixed — first-copy (exit codes: old 0, new 0)

| | v12.2 | v12.3 | change |
|---|---:|---:|---:|
| Wall time (s) | 24.66 | 17.83 | -28% |
| CPU user+sys (s) | 18.16 | 17.05 | -6% |
| Peak memory, whole tree (MB) | 66.7 | 65.7 | -1% |
| Largest process (MB) | 13.5 | 14.1 | +4% |
| Time to first transfer (s) | 4.31 | 3.05 | -29% |
| Copy step (s) | 7.56 | 8.92 | +18% |
| Steps (s from start) | 1 0.83, 2 3.88, 3 11.44, 4 15.89 | 1 0.52, 2 2.58, 3 11.5, 4 12.55 | |

#### mixed — first-copy-strace (exit codes: old 0, new 0)

| | v12.2 | v12.3 | change |
|---|---:|---:|---:|
| Programs started | 2504 | 2055 | -18% |
| Processes/threads created | 3516 | 1859 | -47% |
| Metadata calls (stat, xattr...) | 2197084 | 1663981 | -24% |
| File opens | 241677 | 222506 | -8% |
| Directory reads | 40804 | 20238 | -50% |
| File-system changes | 165281 | 165332 | +0% |
| All system calls | 12019681 | 11410136 | -5% |
| Wall time under strace (s) | 304.62 | 284.89 | -6% |

#### mixed — resume-after-interrupt (exit codes: old 0, new 0)

| | v12.2 | v12.3 | change |
|---|---:|---:|---:|
| Wall time (s) | 25.85 | 17.72 | -31% |
| CPU user+sys (s) | 11.8 | 11.13 | -6% |
| Peak memory, whole tree (MB) | 76.7 | 58.8 | -23% |
| Largest process (MB) | 13.4 | 14.1 | +5% |
| Time to first transfer (s) | 0.02 | 0.01 | -50% |
| Copy step (s) | 3.12 | 3.13 | +0% |
| Steps (s from start) | 1 0.28, 2 3.32, 3 6.44, 4 10.6 | 1 0.36, 2 2.4, 3 5.53, 4 6.58 | |

#### mixed — verify-only-rerun (exit codes: old 0, new 0)

| | v12.2 | v12.3 | change |
|---|---:|---:|---:|
| Wall time (s) | 6.63 | 10.39 | +57% |
| CPU user+sys (s) | 2.56 | 7.27 | +184% |
| Peak memory, whole tree (MB) | 41.7 | 58.9 | +41% |
| Largest process (MB) | 13.5 | 14.0 | +4% |
| Time to first transfer (s) | 0.01 | 0.04 | +300% |
| Steps (s from start) | 1 0.28, 2 3.32 | 1 0.43, 2 2.48 | |

#### tiny — first-copy (exit codes: old 0, new 0)

| | v12.2 | v12.3 | change |
|---|---:|---:|---:|
| Wall time (s) | 91.05 | 50.47 | -45% |
| CPU user+sys (s) | 86.79 | 56.25 | -35% |
| Peak memory, whole tree (MB) | 88.8 | 92.7 | +4% |
| Largest process (MB) | 55.3 | 57.9 | +5% |
| Time to first transfer (s) | 6.59 | 6.85 | +4% |
| Copy step (s) | 26.59 | 21.17 | -20% |
| Steps (s from start) | 1 2.84, 2 5.99, 3 32.58, 4 41.47 | 1 0.35, 2 6.47, 3 27.64, 4 28.7 | |

#### tiny — resume-after-interrupt (exit codes: old 0, new 0)

| | v12.2 | v12.3 | change |
|---|---:|---:|---:|
| Wall time (s) | 53.89 | 44.09 | -18% |
| CPU user+sys (s) | 50.91 | 44.79 | -12% |
| Peak memory, whole tree (MB) | 88.3 | 92.6 | +5% |
| Largest process (MB) | 47.6 | 57.6 | +21% |
| Time to first transfer (s) | 0.02 | 0.01 | -50% |
| Copy step (s) | 7.61 | 10.03 | +32% |
| Steps (s from start) | 1 0.29, 2 9.39, 3 17.0, 4 21.62 | 1 0.35, 2 7.46, 3 17.49, 4 18.54 | |

#### tiny — verify-only-rerun (exit codes: old 0, new 0)

| | v12.2 | v12.3 | change |
|---|---:|---:|---:|
| Wall time (s) | 16.4 | 27.85 | +70% |
| CPU user+sys (s) | 10.88 | 29.8 | +174% |
| Peak memory, whole tree (MB) | 88.8 | 92.6 | +4% |
| Largest process (MB) | 38.1 | 57.4 | +51% |
| Time to first transfer (s) | 0.02 | 0.02 | +0% |
| Steps (s from start) | 1 0.29, 2 9.37 | 1 0.52, 2 8.67 | |

#### mixed — first-copy, repeated 3× (interleaved)

| | v12.2 | v12.3 |
|---|---|---|
| Wall time (s) | 25.45 / 25.35 / 25.16 | 15.54 / 15.18 / 16.03 |
| Copy step (s) | 8.51 / 7.49 / 7.52 | 6.84 / 6.51 / 7.51 |
| Time to first transfer (s) | 4.3 / 4.31 / 4.31 | 2.79 / 2.8 / 2.8 |
| Copy throughput (MB/s, median copy step; 1,647 MB in 50,006 files) | 218 | 240 |
| Copy throughput, tiny dataset (files/s; 250,000 files, 308 MB) | 9402 | 11809 |

The final v12.3 code (after the last review fixes) measured again: first copy + check 19.32 s (mixed) and 45.74 s (tiny); `--verify-only` rerun 10.24 s and 25.81 s.


**About the `--verify-only` rerun:** v12.3 is slower here because v12.2 didn't actually check anything. It never cleared its record of confirmed files after a finished check, so the second `--verify-only` skipped every file (the `recheck` test shows v12.2 missing a damaged file this way). v12.3 checks every file again, reading only the destination for files with a valid fingerprint.

### File-list handling at scale

`bench/micro.sh` times only smartcopy's list handling (no copying), on synthetic lists, with peak memory of the largest process. v12.2's code is run verbatim and is skipped at 3,000,000 files, where its destination-only check would take over an hour.

| Operation | Files | v12.2 time (s) | v12.3 time (s) | v12.2 peak memory (MB) | v12.3 peak memory (MB) |
|---|---:|---:|---:|---:|---:|
| check-dest | 100,000 | 5.06 | 0.37 | 21.3 | 4.5 |
| check-dest | 300,000 | 46.88 | 1.16 | 55.5 | 4.6 |
| check-dest | 1,000,000 | 599.04 | 3.92 | 175.8 | 4.6 |
| check-dest | 3,000,000 | — | 11.6 | — | 4.6 |
| select | 100,000 | 0.34 | 0.34 | 17.4 | 31.5 |
| select | 300,000 | 1.33 | 1.12 | 47.2 | 88.2 |
| select | 1,000,000 | 6.27 | 2.92 | 152.0 | 224.6 |
| select | 3,000,000 | — | 8.06 | — | 259.1 |
| save | 100,000 | 0.56 | 0.92 | 21.1 | 39.7 |
| save | 300,000 | 2.04 | 2.09 | 58.7 | 113.0 |
| save | 1,000,000 | 7.05 | 6.96 | 190.8 | 259.1 |
| save | 3,000,000 | — | 18.97 | — | 259.3 |
| poll | 100,000 | 0.05 | 0.01 | 3.2 | 3.2 |
| poll | 300,000 | 0.2 | 0.01 | 3.2 | 3.3 |
| poll | 1,000,000 | 0.42 | 0.01 | 3.3 | 3.3 |
| poll | 3,000,000 | — | 0.02 | — | 3.2 |
| report | 100,000 | 3.05 | 0.3 | 24.5 | 12.6 |
| report | 300,000 | 10.53 | 0.65 | 68.7 | 45.7 |
| report | 1,000,000 | 35.78 | 2.1 | 224.7 | 144.9 |
| report | 3,000,000 | — | 7.03 | — | 259.3 |

- **check-dest**: v12.2 re-read the whole fingerprint list for every 5,000-file batch: 3× the files took 9× the time. v12.3 holds one batch's fingerprints: linear time, constant memory.
- **select / save**: v12.3 uses sort's buffer (capped at 256 MB, `SMARTCOPY_SORT_MEM`) and its temporary files on the destination, so memory stops growing (≈259 MB from 1M to 3M files); v12.2's in-memory tables grow without limit (≈190 MB at 1M, and on the order of 2 GB at 10M). v12.3 also rewrites the fingerprint list once per run instead of up to three times, and drops entries that no longer apply.
- **poll**: one progress refresh. v12.2 re-read every batch log so far, every second — over a 10-million-file copy that adds up to hundreds of GB of re-reading. v12.3 reads only the batches still running.
- **report**: v12.2 built the copied-files table five times; v12.3 once, with an external sort.

The remaining memory that grows with the number of files is rsync's own file list when hard links are kept (APFS/HFS destinations use `--no-inc-recursive`, about 100 bytes per file, as in v12.2; see [DESIGN.md](DESIGN.md)).

### Correctness, before and after

The same automated tests (`tests/run.sh`) were run against both versions:

| Test group | v12.2 | v12.3 |
|---|---|---|
| `copy`: tree with difficult names (tab, newline, backslash, emoji) | **fails**: 3 files reported as "disappeared from the source", exit 3 | passes |
| `privacy`: no names on screen, in notifications or reports | passes | passes |
| `nowrites`: nothing written outside the destination (system disk, source, TMPDIR, HOME) | passes | passes |
| `nonet`: no network sockets | passes | passes |
| `corrupt`: a damaged copy (same size and date) is found by `--verify-only` | **fails**: the check skipped every file (checkpoint never cleared) | passes |
| `recheck`: a second `--verify-only` checks everything again | **fails** | passes |
| `checkpoint`: a stopped check resumes, except for source files changed since | not comparable (v12.2 skips by name only, never by size and date) | passes |
| `resume`: fingerprints survive an interrupted copy | **fails**: 12,012 files compared with the source after resuming | passes (1, a hard-linked file) |
| `disconnect`: destination unplugged mid-copy | **fails**: didn't pause; files appeared in the empty mount-point folder on the system disk; its final check then hung for 26 minutes and was stopped by hand | passes |
| `dryrun`, `errors` | pass | pass |
| `lib`, `exfat`, `stop` | not applicable | pass |
| **Total** | 24 of 40 checks | **51 of 51** |

The disconnect test unmounts the destination lazily, which leaves the empty mount-point folder in place. On a Mac that folder normally disappears on unplugging, but it can also be left behind or recreated, which is the case `in_dst` protects against. The library and a subset of the end-to-end tests (`lib copy corrupt checkpoint exfat errors`) also pass with BWK awk (`SC_AWK=original-awk`), the awk family macOS uses. macOS's bash 3.2 couldn't be run here; the script avoids bash 4 features, here-documents and process substitution, and was checked for them.

## v13: streaming engine against batch engine

The same script (v13.0) was run with `--engine batch` (v12.3's list-then-copy engine) and with `--engine stream` (the default from v13), on the test bed described above. The main figures come from three interleaved runs of each engine (`bench/results/engines-repeat.jsonl`); everything else is single runs (`bench/results/engines.jsonl`).

### In short

| | batch engine | stream engine |
|---|---|---|
| First file copied, 250,000 files | 5.8 s | **0.8 s** |
| First file copied, 500,000 files | 12.2 s | **2.7 s** |
| Verified finish, 50,006 files (1.65 GB) | 16.7 s | **13.2 s** (−21%) |
| Verified finish, 250,000 files | 45.7 s | **37.0 s** (−19%) |
| Verified finish, 500,000 files | 114.0 s | **88.9 s** (−22%) |
| Peak memory (whole process tree) | 66–153 MB | 90–159 MB: a little higher (listing, copiers and checker run at the same time), still bounded |

With the batch engine, the time to the first copied file grows with the size of the source, because both drives are listed completely first. With the stream engine it stays at the time needed to find the first 100 files, then copying starts. Totals improve because listing, copying and checking overlap: by the time the listing ends, much of the copying and some of the checking are already done.

### Three interleaved runs

| | batch engine (v12.3) | stream engine (v13) | change (medians) |
|---|---|---|---:|
| mixed: 50,006 files, 1.65 GB — verified finish (s) | 16.95 / 16.63 / 16.72 | 13.08 / 13.22 / 13.76 | -21% |
| mixed: 50,006 files, 1.65 GB — first file copied (s) | 2.8 / 2.8 / 2.8 | 0.77 / 0.77 / 0.77 | -72% |
| mixed: 50,006 files, 1.65 GB — listing + copying done (s) | 10.52 / 10.35 / 10.36 | 9.15 / 8.01 / 7.93 | -23% |
| mixed: 50,006 files, 1.65 GB — CPU user+sys (s) | 17.1 / 16.1 / 16.0 | 16.6 / 16.0 / 16.7 | +3% |
| mixed: 50,006 files, 1.65 GB — peak memory, whole tree (MB) | 66.1 / 66.3 / 65.8 | 89.2 / 92.8 / 97.5 | +40% |
| tiny: 250,000 files, 308 MB — verified finish (s) | 45.72 / 45.95 / 44.57 | 37.58 / 37.0 / 36.45 | -19% |
| tiny: 250,000 files, 308 MB — first file copied (s) | 5.83 / 5.82 / 5.82 | 0.77 / 0.78 / 0.77 | -87% |
| tiny: 250,000 files, 308 MB — listing + copying done (s) | 23.48 / 23.49 / 22.4 | 20.07 / 19.37 / 18.01 | -18% |
| tiny: 250,000 files, 308 MB — CPU user+sys (s) | 49.8 / 51.4 / 49.1 | 50.3 / 49.7 / 49.8 | +0% |
| tiny: 250,000 files, 308 MB — peak memory, whole tree (MB) | 93.1 / 93.1 / 93.6 | 89.5 / 95.3 / 90.1 | -3% |

### 500,000 files (one run each)

#### large — first-copy (exit codes: batch engine 0, stream engine 0)

| | batch engine | stream engine | change |
|---|---:|---:|---:|
| Wall time (s) | 114.03 | 88.89 | -22% |
| CPU user+sys (s) | 121.47 | 106.82 | -12% |
| Peak memory, whole tree (MB) | 152.5 | 158.6 | +4% |
| Largest process (MB) | 112.5 | 134.2 | +19% |
| Time to first transfer (s) | 12.16 | 2.65 | -78% |
| Copy step (s) | 60.45 | 59.22 | -2% |
| Listing + copying done at (s) | 71.97 | 59.69 | -17% |

### Work done (mixed, under strace; one run each)

#### mixed — first-copy-strace (exit codes: batch engine 0, stream engine 0)

| | batch engine | stream engine | change |
|---|---:|---:|---:|
| Programs started | 2201 | 2497 | +13% |
| Processes/threads created | 1993 | 2294 | +15% |
| Metadata calls (stat, xattr...) | 1670669 | 2108461 | +26% |
| File opens | 225469 | 262658 | +16% |
| Directory reads | 20254 | 30362 | +50% |
| File-system changes | 165332 | 165374 | +0% |
| All system calls | 11436894 | 12866229 | +12% |
| Wall time under strace (s) | 261.02 | 336.19 | +29% |

The stream engine makes about 12% more system calls. They come from roughly 300 more short-lived helper programs: progress counts, reading each batch's output, more rsync starts from the small first batches, and the checker's batches. There's also a second lookup of each name: the listing checks it against an empty folder, then the copier checks it against the destination. Under strace every system call is slowed down a lot, so the stream engine is slower there. Without strace, the same work finishes 19–22% sooner, because it overlaps. On a spinning hard drive the overlap means the drive's head moves between listing and copying, so the total time may not improve there (see [STREAMING.md](STREAMING.md)). The time to the first file still does.

### Correctness

The full test suite passes on both engines: 62 of 62 checks with the stream engine, including copying while listing, a listing killed mid-way (falls back and finishes verified), and the destination unplugged mid-copy. With `SMARTCOPY_ENGINE=batch` it's 53 of 53 (the stream-only tests are skipped). The library, copy, stream, fallback and exFAT tests also pass with BWK awk (22 of 22).

### Not compared

- **Resume after an interruption:** each engine was stopped halfway through its own copy time, so the two runs had different amounts left to copy, and the timings aren't comparable. Both resumed and finished verified (`bench/results/engines.jsonl`).
- **`--verify-only`** uses the batch engine's listing in both cases (25.4 s against 26.6 s for 250,000 files: the same code).
- One single run of the batch engine on the mixed dataset took 100 s, because the test disk stalled during copying. The interleaved repeats above (16.6–17.0 s) are the representative figures.

## What to expect on a Mac (estimate)

The test bed's disks are fast, so per-file work dominates there and the gains look large: from v12.2 to v13, 48% less time for 50,000 mixed files and 59% less for 250,000 small files. On a Mac, how much of this shows depends on what limits the copy. These figures are estimates, not measurements on a Mac:

| Situation | Expected gain over v12.2 | Why |
|---|---|---|
| One uninterrupted big copy limited by the drives (e.g. 1 TB, ~10 MB average file, spinning source → exFAT SSD at 25–30 MB/s, ~10 h) | **about 3–10% less time** (20–60 min) | The drives set the pace. The savings are the passes over the drives that are no longer made: the folder-size scan, a full final pass, and the source and destination listed together. |
| A copy that was stopped and resumed | **about 20–40% less time** | v12.2 lost the fingerprints of files copied before the stop, so the check re-read them from the (slow) source. v13 keeps them and reads only the destination. |
| Hundreds of thousands to millions of small files | **about 30–60% less time** | Per-file work dominates, which is what was optimised (close to the test bed's results). |
| Time until the first file is copied | **seconds instead of minutes** | The streaming engine starts after finding the first 100 files instead of listing both drives completely. |

With a spinning hard drive as the source, the streaming engine's overlap of listing and copying makes the drive's head move between the two. Copying still starts sooner, but the total can be a little longer than with `--engine batch`. A run of each engine on the actual drives settles it.

## Reproducing

```bash
sudo apt-get install -y rsync strace time      # Linux test bed; see bench/README.md
git show 8005cbd:smartcopy.sh > /tmp/smartcopy-v12.2.sh
sudo bench/bench.sh results.jsonl old=/tmp/smartcopy-v12.2.sh new=./smartcopy.sh
bench/micro.sh 100000 300000 1000000 3000000 > micro.jsonl
python3 bench/summarize.py results.jsonl micro.jsonl
sudo bench/bench.sh engines.jsonl batch=./smartcopy.sh@--engine=batch stream=./smartcopy.sh@--engine=stream
sudo tests/run.sh                               # 16 test groups, both engines:
sudo SMARTCOPY_ENGINE=batch tests/run.sh
```
