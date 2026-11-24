# Changelog

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
