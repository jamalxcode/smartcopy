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
STEP 3  Final pass         folders and links only, when every file copied cleanly and the check follows;
                           otherwise a normal recursive rsync over everything; retries until stable
STEP 4  Check every file   fingerprints compared (destination-only where a saved fingerprint exists)
        Report             plain English; problems first, then notes
```

`--no-verify` skips step 4, and `--verify-only` runs steps 1 and 4 only.

## Resuming and retrying

- **Fingerprints survive interruptions.** Each batch's fingerprints are appended to a journal on the destination as soon as the batch finishes, and folded into the hash list when the run ends (or by the next run, if this one was cut off). Before v12.3 they were only saved after the final pass, so a stopped copy lost them and the next check had to read both drives for everything copied before the stop.
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
- **A fingerprint is only used while it can still be true.** Each saved fingerprint records the source file's size and modification date when it was taken. It is used only while the source file still has both; otherwise the file is compared with the source. When the hash list is rewritten, entries for files that no longer exist or have changed are dropped, so it never grows stale.
- **A stopped check resumes.** Batches that came out clean are recorded (with each source file's size and date), so a stopped check skips them on the next run, unless the source file changed since. The record is cleared when a check finishes. (Before v12.3 it was never cleared after a finished check, so the next `--verify-only` skipped every file and couldn't find new damage.)

## Speed

Findings from the real runs:

- **exFAT on macOS is slow with many files.** About 26–30 MB/s overall, against the SSD's roughly 460 MB/s rating for steady writes. Writing in place on exFAT helped. Reformatting the destination as APFS is the biggest remaining speed-up.
- **Parallel copying helps SSDs and hurts hard drives**, because a hard drive's head jumps between files. So it isn't hard-coded: big jobs copy 1 file at a time for about 2 minutes, then 4 at a time for about 2 minutes, and keep whichever is faster. One real run measured 22 MB/s against 27 MB/s and switched to 4. Copying and checking are tuned separately.
- **Batching.** The list of files to copy is cut into batches of 1–8 GB or 5,000 files, in folder order. Each worker runs `rsync --files-from` on its batch.
- **Spotlight** indexing on the destination is paused during the run and restored afterwards, including after a crash on the next run. If two copies run to the same drive, it stays off until the last one finishes.

## Handling millions of files (v12.3)

The copying itself is rsync's. Everything smartcopy does around it — planning, batching, progress, fingerprints, the report — was rewritten so its cost grows in step with the number of files and its memory stays bounded, measured up to 3 million files (see [PERFORMANCE.md](PERFORMANCE.md)).

- **One record format, safe for every file name.** Lists are tab-separated lines, one per file. Names are stored the way rsync prints them on its output (control characters as `\#ooo`), with tabs also escaped, so a stored name never contains a tab or line break. They're turned back into real names only when handed to rsync, as NUL-separated lists (`--from0`). Names with tabs and line breaks, which earlier versions couldn't handle, now work. rsync's `--log-file` isn't parsed any more: it doesn't escape names.
- **Sorted lists, merged instead of looked up.** The file list is sorted once by name (`LC_ALL=C sort`, with a fixed memory buffer and its temporary files in the run's folder on the destination). The hash list is kept sorted. Deciding how each file is checked, adding new fingerprints and pruning old ones are all single passes over sorted lists merged together (`sort -m`), never tables of every file held in memory. New fingerprints are sorted exactly once, and the hash list is rewritten once per run instead of up to three times.
- **Each batch's output is read once.** When a batch finishes, its output is read once to count what it did, save fingerprints and note differences. The progress line only reads the batches still running (at most 4 × 5,000 lines), not every batch so far. Before, the work per refresh grew with the job, so the total grew with the square of the number of files.
- **Destination-only checks hold one batch in memory.** Each batch carries its own expected fingerprints. Before, every batch re-read the whole hash list.
- **Fewer passes over the drives.** The folder size for the space check comes from step 1 instead of a separate `du`; on FAT32 the files of 4 GB or more come from step 1 instead of a `find`. The final pass visits only folders and links when that's safe (see the steps above). A one-off tidy-up from old versions runs once per copy instead of after every interruption.
- **Fewer programs started.** The progress line is built in the shell: sizes, times and the finish time need no `awk` or `date` each second (`date` only when the shown minute changes; `tput` every 15 s). Drive details from `diskutil` are read once per drive.
- **Errors aren't lost in pipelines.** The listing reports both rsync's and the list writer's exit codes; a listing that was cut off is retried, not used half-finished. The dry run reports rsync's exit code (it used to report awk's). A fingerprint journal is only deleted after it has been merged successfully.
- **rsync's own memory.** With hard links (`-H`, used for APFS and Mac OS Extended), rsync is run with `--no-inc-recursive`, as before, because incremental listing with `-H` hung or failed in testing when an item couldn't be replaced (rsync 3.2.7). rsync then holds its file list in memory (roughly 100 bytes per file). For exFAT, FAT32 and other destinations, rsync lists incrementally and its memory stays small.

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
| A second `--verify-only` checked nothing (v12.3) | The record of confirmed files was never cleared after a finished check | Clear it when a check finishes; check source size and date before skipping |
| A stopped copy lost its fingerprints (v12.3) | Fingerprints were saved only after the final pass | Save them as each batch finishes |
| "Folder in the way" errors missing from the report (v12.3) | rsync's "could not make way" message has no `rsync:` prefix | Recognise it and explain it |
| Possible hang in the check (v12.3) | Incremental listing with `-H` hangs when an item can't be replaced | `--no-inc-recursive` whenever `-H` is used |
| Dry run exit code (v12.3) | The pipeline reported awk's status, not rsync's | Take rsync's status from the pipeline |

## Ideas considered and not done

- **Running copies at once on hard drives:** slower, because of head seeks. Handled by tuning instead.
- **Retrying only the failed files:** needs complex file lists. Re-scanning is slower but simpler and more reliable.
- **Restarting automatically after a reboot (launchd):** a lot of setup for little gain, since rerunning the command already resumes.
- **Spot checks of 1–2% of files:** fast, but can't prove every file. The hash list gives full proof quickly instead.
- **SHA-256:** slower than xxh128, with no benefit for spotting accidental damage.
