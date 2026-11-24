# Design

How smartcopy works, and why each decision was made. The numbers come from real runs on a Mac copying from an external hard drive to a USB SSD formatted as exFAT, with about 108,000 files and 1.16 TB.

## Goals

1. **Finish no matter what.** Interruptions, disconnects, crashes and flaky cables should never mean starting over.
2. **Prove the result.** A copy isn't done until every byte is confirmed.
3. **Explain problems in plain English.** Say what went wrong, on which side, how to fix it and how to avoid it.
4. **Privacy.** No file names on screen, and no files written anywhere except the destination drive.
5. **Speed,** without trading away any of the above.

## The run, step by step

```
STEP 1  List the files     one rsync dry run over both drives → every source file, and which still need copying
STEP 2  Copy the files     only what's missing or changed, in batches, 1 or 4 at a time (tuned automatically)
STEP 3  Final pass         normal recursive rsync: folders, links, anything missed; retries until stable
STEP 4  Check every file   fingerprints compared (destination-only where a saved fingerprint exists)
        Report             plain English; problems first, then notes
```

`--no-verify` skips step 4, and `--verify-only` runs steps 1 and 4 only.

## Resuming and retrying

- **Resume is mostly free with rsync.** Files already copied match on size and date and are skipped. A marker file (`.smartcopy-target`) records what the destination is a copy of, so a rerun resumes without asking for confirmation again.
- **Half-copied files.** On APFS/HFS+, partial files go to `.rsync-partial/`, and large files resume from where they stopped. On exFAT, files are written in place (`--inplace`). A file cut off part-way ends up with the wrong size or date, so the next pass copies it again. This avoids an extra rename for every file, which is slow on exFAT.
- **Progress, not a fixed retry count.** It keeps retrying as long as passes make progress, and gives up after `MAX_STUCK` (6) passes in a row with none. Progress means files completed or the destination growing, which covers one huge file being cut off part-way each time.
- **Permanent failures are detected.** The same set of errors three times in a row means unreadable files or bad sectors, so it stops retrying and reports them. Before this fix, a damaged file could cause up to 500 full rescans.
- **Unfixable errors stop immediately.** "No space left", "Read-only file system" and rsync setup errors aren't retried.
- **Unplugged drives.** Before every pass and batch it checks that both drives are mounted, and waits if not. Being mounted is confirmed two independent ways: the drive's mount point from `df`, and a device number that differs from `/Volumes`. A leftover folder at `/Volumes/Name` that would make macOS remount the drive as "Name 1" is removed if empty; if it holds files (data that landed on the internal disk), the run stops.
- **Locks** stop two copies writing to the same destination at once. A lock left by a crash is detected (the process is gone, or isn't smartcopy) and cleared.

## Checking

- **Fingerprints, not size and date.** The final check compares contents (`rsync --checksum`) using **xxh128**, which is much faster to compute than rsync's default MD5 and just as good at catching accidental damage. SHA-256 was considered and rejected: it's slower, and its protection against deliberate tampering isn't needed here.
- **A check can't avoid reading both copies.** Any hash has to read every byte, so hashing alone doesn't remove reads. The saving comes from reading the source only once, as below.
- **The hash list.** rsync can report each file's fingerprint while it copies (`%C` in the log format), using data it's already reading. These go into `.smartcopy-hashes` on the destination. A full check also saves the source fingerprint of every file that matched. Later checks hash only the destination copy (`rsync --checksum --dry-run` into an empty folder, which reads one side and writes nothing) and compare with the list. If the source is the slower drive (about 30 MB/s from a hard disk against 200–460 MB/s from the SSD), that's an estimated **85–92% less time**. Files that changed on the source since they were copied are always compared with the source instead.
- **Repairs are targeted.** Files that don't match are re-copied with `--checksum`, then just those files are checked again.
- **A stopped check resumes.** Batches that came out clean are recorded, so a stopped check skips them on the next run.

## Speed

Findings from the real runs:

- **exFAT on macOS is slow with many files.** About 26–30 MB/s overall, against the SSD's roughly 460 MB/s rating for steady writes. Writing in place on exFAT helped. Reformatting the destination as APFS is the biggest remaining speed-up.
- **Parallel copying helps SSDs and hurts hard drives**, because a hard drive's head jumps between files. So it isn't hard-coded: big jobs copy 1 file at a time for about 2 minutes, then 4 at a time for about 2 minutes, and keep whichever is faster. One real run measured 22 MB/s against 27 MB/s and switched to 4. Copying and checking are tuned separately.
- **Batching.** The list of files to copy is cut into batches of 1–8 GB or 5,000 files, in folder order. Each worker runs `rsync --files-from` on its batch.
- **Spotlight** indexing on the destination is paused during the run and restored afterwards, including after a crash on the next run. If two copies run to the same drive, it stays off until the last one finishes.

## The time-left estimate

The first version of the estimate swung wildly, between 11 minutes and 7 hours. Progress arrived in big jumps, and the estimate tried to separate "seconds per byte" from "seconds per file". The current design:

- **Work** = bytes plus a fixed 256 KB allowance per file, so a run of tiny files doesn't look like a stall.
- **Speed** = half the average since the stage began plus half the average of the last 15 minutes.
- **Displayed finish time** moves a sixth of the way towards each new estimate, so it settles in about 30 seconds and never jumps. It never shows a time already in the past.
- **Shown only after a minute of progress,** or after the speed tuning finishes.
- **Fits the window.** The line is built by priority: in a narrow Terminal it drops speed, then files left, then sizes. TIME LEFT and FINISHES are always shown.

## The report

Errors from rsync are grouped into about 17 kinds, each with the side (source, destination or general), a plain explanation, how to fix it and how to avoid it. Problems are listed first, most serious at the top, then notes. Some issues are caught before copying starts: not enough space, files over 4 GB headed for FAT32, ownership turned off on the destination, and Terminal lacking Full Disk Access. The report also notes drive disconnects, errors that went away on retry, files that silently didn't match and were repaired, and files copied twice (see below).

## Privacy

See [../PRIVACY.md](../PRIVACY.md). The design points:

- File names are kept out of anything the user sees. Problems give a count and point to a private file list.
- Every file the tool writes goes in `rsync-logs` on the destination drive, created only after that drive is confirmed mounted. The script never writes to `$HOME` or `/tmp`.
- `rsync -8` is used everywhere. Without it, under some language settings rsync escapes non-ASCII names (`café` → `caf\#303\#251`). The file lists then don't match the real files, and files with accented, Arabic or emoji names were falsely reported as "disappeared".

## Bugs found the hard way

Each of these was found on a real Mac and wasn't reproducible in the original test setup. They show why test stand-ins must behave like the real thing.

| Bug | Cause | Fix |
|---|---|---|
| Drive reported "not mounted" | macOS `df` pads its columns; the mount point was read with a leading space | Tolerant parsing, plus a second test using device numbers |
| Script hung after listing | A bare `wait` also waited for `caffeinate -w $$`, which waits for the script | Wait only for the specific process |
| Check skipped every file | awk's `NR==FNR` trick breaks when the first file is empty | Compare `FILENAME` instead |
| Speed tuning measured 0 MB/s | Tuning measured destination growth, which never changes while checking | Measure the right quantity for each mode |
| "Files copied: 296" for 148 files | The exFAT final pass re-copied files whose dates changed after writing | Count unique files; report "copied twice" with the likely cause |
| Accented, Arabic and emoji names "disappeared" | rsync escaping (see Privacy) | `-8` on every call |
| `--background` silently didn't start | The script was re-launched through a path that wasn't executable | Re-launch with `/bin/bash` and the script's real path |
| Finish time cut off | The line was wider than the Terminal window | Build the line by priority |

## Ideas considered and not done

- **Running copies at once on hard drives:** slower, because of head seeks. Handled by tuning instead.
- **Retrying only the failed files:** needs complex file lists. Re-scanning is slower but simpler and more reliable.
- **Restarting automatically after a reboot (launchd):** a lot of setup for little gain, since rerunning the command already resumes.
- **Spot checks of 1–2% of files:** fast, but can't prove every file. The hash list gives full proof quickly instead.
- **SHA-256:** slower than xxh128, with no benefit for spotting accidental damage.
