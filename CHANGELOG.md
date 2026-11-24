# Changelog

## v13.0: Streaming engine — listing, copying and checking at the same time
See [docs/STREAMING.md](docs/STREAMING.md) for the design and [docs/PERFORMANCE.md](docs/PERFORMANCE.md) for measurements.
- **One pipeline instead of separate stages.** A single listing of the source streams into a router that cuts batches as files are found. A pool of copiers takes batches as soon as they appear, and a checker reads copied files back from the destination while later batches are still copying. Copying starts within moments (the first batches are small), instead of after both drives have been listed in full.
- **Bounded queues with backpressure.** At most 4 batches wait for a copier and 16 for a checker. When the copiers are busy, the router and the listing wait. Memory stays small however big the job.
- **The source is listed once.** The listing reads only the source; copiers skip what's already there. Files confirmed while copying are skipped by the final check.
- **Progress tells found-so-far from final totals.** While the listing runs, the line shows "… found so far · STILL LISTING", with no percentage or time left. Once the listing ends, the totals are final. Files already confirmed are shown as "checked".
- **Fallback built in.** If the listing is cut off (unplugged drive, error), what was copied is kept and the run finishes with the v12.3 engine: a full listing, then copying what's left. `--engine batch` (or `SMARTCOPY_ENGINE=batch`) uses that engine from the start. `--verify-only` and `--dry-run` use it too.
- **Fix:** the final check now waits for an unplugged drive to come back instead of stopping with an error (both engines).
- Unchanged: the copies are ordinary individual files; content checks and all recovery guarantees; all privacy rules (pipes and queues in memory, lists and batches in the run folder on the destination). The test suite now covers both engines.

## v12.3: Faster with many files; fixes to checking and resuming
Measured results are in [docs/PERFORMANCE.md](docs/PERFORMANCE.md).
- **Scales to millions of files.** File lists are sorted once and combined by merging, so smartcopy's own work grows in step with the number of files and its memory stays bounded. Before, the destination-only check re-read the whole hash list for every batch, the progress line re-read every batch log every second, and the hash list and report figures were built in memory.
- **Fewer passes over the drives.** No separate `du` (folder size) or `find` (FAT32 4 GB files) before copying; the information comes from step 1. When every file copied cleanly and the check follows, the final pass visits only folders and links.
- **Fewer programs started.** The progress line and time-left estimate are worked out in the shell; `diskutil` is read once per drive.
- **Fingerprints survive a stop.** They're saved as each batch finishes, so after an interruption the check still reads only the destination for files copied before the stop.
- **Fix:** after a finished check, the next `--verify-only` skipped every file (the record of confirmed files was never cleared). A stopped check now resumes only for source files that haven't changed since.
- **Fix:** a saved fingerprint is used only while the source file still has the size and date it had when it was taken; outdated entries are dropped from the hash list. (The hash list format is now v2; one from an older version is replaced during the next check.)
- **Fix:** file names containing tabs or line breaks now work everywhere (they're stored in an escaped form and handed to rsync as NUL-separated lists).
- **Fix:** "a folder is in the way" errors (a destination folder with the same name as a source file) are now explained in the report.
- **Fix:** the dry run reported awk's exit code instead of rsync's; an interrupted file listing is retried instead of being used half-finished.
- **Fix:** possible hang in the check's folders-and-links pass when an item couldn't be replaced (incremental listing with hard links).
- **Privacy:** rsync writes from inside the destination folder, after checking that it's really on the destination drive, so an unplugged drive can't cause writes to the Mac's drive. Temporary files from `sort` and the shell go in the run's folder in `rsync-logs` (`TMPDIR`). If the drive is gone at the end, the report is shown on screen only.
- `--stop` now also stops the rsync processes started by the file listing.
- Automated tests (`tests/run.sh`) and benchmarks (`bench/`) added, including privacy audits: no writes outside the destination, no names on screen or in reports, no network use, safe pause on disconnect.

## v12.2: Installer
- `install.sh` installs `smartcopy` into `/usr/local/bin` with its man page, updates in place and uninstalls with `--uninstall`. It also checks for rsync, removes the download flag and removes the old safe-copy man page.
- Run it from anywhere as `sudo smartcopy …`; the docs and examples now use that form.
- `--help` shows the full summary, including `--verify-only`.
- Docs: update, uninstall and moving from safe-copy, including waiting for running old-version copies.

## v12.1: Renamed to smartcopy
- The script is now `smartcopy.sh` and the manual is `man smartcopy`; marker and hash files are now `.smartcopy-target` and `.smartcopy-hashes`.
- Copies made under the old name (`.safe-copy-…` files) are adopted automatically, so resuming and the hash list keep working.
- MIT licence added.

## v12: Everything on the destination drive
- All logs, reports, file lists, resume state, locks and temporary files now go in a hidden `rsync-logs` folder on the destination drive. Nothing is written to the Mac's drive or to the source drive.
- The log folder is created only after the destination drive is confirmed mounted.

## v11.5: No file names shown
- File names were removed from the screen, the report, notifications and the dry run. Problems now give counts plus a private file list.
- The log folder is locked to the user on APFS/HFS+ drives.

## v11.4: International file names
- `rsync -8` on every call. Files with accented, Arabic or emoji names were being falsely reported as "disappeared" and skipped by the fast copy.
- Spotlight stays off until the last copy to a drive finishes.

## v11.3: Progress line fits the window
- The line is built by priority: TIME LEFT and FINISHES are never cut off, and it shows a "files left" count.

## v11.2: Accurate report numbers
- Each copied file is counted once, and speed is measured over copying time only.
- New note when files had to be copied twice (exFAT date changes).

## v11.1: Hang fix
- After listing, the script waited for `caffeinate`, which waits for the script, so neither could finish.

## v11: Hash list
- File fingerprints are saved during copying and checking, so later checks read only the destination.

## v10.1: Steady time estimate
- New estimator: blended averages, a smoothed finish time and no wild swings.

## v10: Clear steps, faster check
- "STEP x of y" messages and no raw rsync statistics.
- xxh128 checksums, per-file progress while checking, and a stopped check resumes.

## v9: Self-tuning and time left
- One scan of both drives at the start, batched copying and automatic 1-vs-4 tuning.
- A TIME LEFT and FINISHES line.

## v8: Parallel copying and speed test
## v7: Faster on exFAT
- Files are written in place, whole files are copied, `--verify-only` was added and the report shows speed.

## v6.1: macOS `df` fix
- The column padding in macOS `df` caused false "not mounted" errors.

## v6: Final review fixes
- The background launcher, a retry storm on bad sectors, lock races, stale locks and rsync version checks were fixed.

## v5: Folders and the plain-English report
- Folders as well as whole drives, and about 17 error kinds with fixes and prevention.

## v4: Safety and usability
- Swapped-drives guard, first-run confirmation, `--dry-run`, `--background`, `--stop`, notifications, Spotlight pausing.

## v3: Resilience
- Retries based on progress, full-disk and read-only detection, locks and stale-mount handling.

## v2: Correctness
- A repair pass that compares checksums, partial-file resume, exFAT/FAT support and correct exit codes.

## v1: First version
- An rsync retry loop with a final checksum comparison.
