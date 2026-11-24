# How smartcopy was built

smartcopy was designed in one long working session between the author and Claude (an AI assistant): one request at a time, each followed by a review, real runs on a Mac, and fixes. This is a summary, not a transcript. Drive names, folder names, usernames and file names have been replaced with generic examples, in line with the project's privacy goals.

The approach throughout was to critique each version, improve it meaningfully, test it, and report honestly what was and wasn't verified. Testing used real rsync with simulated macOS commands. Several bugs only showed up on the real Mac, and are listed in [DESIGN.md](DESIGN.md#bugs-found-the-hard-way).

## 1. The starting request
> An rsync command for macOS that copies a volume from one drive to another with error checking, recovers from mistakes until the whole drive is copied, supports interruptions and restarts, and is robust and resilient.

**v1**: a script wrapping rsync in a retry loop, with partial-file handling, sleep prevention, a check that both drives are mounted, and a final checksum comparison.

## 2. "Review it, look for bugs"
**v2** fixed 10 issues:
- Unreadable files were silently skipped by the check.
- "Re-run to fix" couldn't fix files with the same size and date, so a checksum repair pass was added.
- Interrupted passes threw away work.
- Logs could be written to the wrong folder.
- Retries were wasted on bad sectors and on errors that can never succeed.
- exFAT destinations failed on every pass.
- A sleep-prevention flag lasted only 5 seconds.

## 3. "Is it robust? Can it recover from issues?"
**v3**:
- Retries continue while passes make progress, instead of stopping after a fixed count.
- A full or read-only destination stops the run immediately.
- A leftover mount-point folder is cleaned up.
- Locks stop two copies running to one destination.
- The repair pass and check retry if a drive drops out.
- More is checked before starting: write access, Full Disk Access and drive ownership.

## 4. "Critique it, how can it be better?"
**v4** made it safer to use:
- A guard against swapped source and destination drives, the most dangerous mistake possible.
- A confirmation on the first run.
- `--dry-run`, `--background` and `--stop`.
- Notifications.
- Spotlight paused during copies.
- A refusal to copy Time Machine backups.

## 5. "A plain-English report, and folders not just drives"
**v5**:
- Folders as well as whole drives.
- A report that sorts about 17 kinds of rsync error into problems and notes, each with the side involved, an explanation, how to fix it and how to avoid it.

## 6. "Final review"
**v6**:
- `--background` failed when the script wasn't executable.
- A retry storm on bad sectors.
- Lock races and stale locks.
- Older rsync versions passed the version check but lacked needed options.

## 7. First real run: "it failed"
macOS `df` pads its columns, so the source drive was reported as "not mounted". **v6.1** parses `df` more tolerantly and adds a second mount check using device numbers.

## 8. "It's extremely slow, make it faster"
The real average was about 26 MB/s, not the figure rsync showed for the moment, and rsync's percentage was misleading. The likely cause was the exFAT destination.

**v7** wrote files in place on exFAT, copied whole files and added `--verify-only`.

**v8** added parallel copying and a speed test. When the author said "I don't want to test, I just want faster, and a realistic time-left indicator", **v9** made speed tuning automatic and added a clearly labelled TIME LEFT and FINISHES line.

## 9. "Clear messages on where we are and what's next"
**v10**:
- "STEP x of y" banners and no raw rsync statistics.
- A timer for slow stages.
- xxh128 checksums.
- A stopped check resumes.
- Per-file progress while checking.

## 10. "The end time keeps getting pushed back"
Progress arrived in big jumps, and the estimate swung between minutes and hours. **v10.1** replaced it with a steady estimator and fitted the line to the Terminal window.

## 11. "Can't we check with a hash instead of re-reading?"
Any hash has to read every byte, so hashing alone doesn't skip reading. Saving the source's fingerprints during the copy does, because later checks then read only the destination: an estimated 85–92% less time when the source is the slow drive. **v11** built that hash list.

## 12. Real-run fixes
- **v11.1:** the script hung after listing, because it waited for `caffeinate`, which was waiting for the script.
- **v11.2:** the report double-counted files and understated the speed; the cause was the exFAT final pass re-copying files whose dates changed.
- **v11.3:** the finish time was cut off in narrow windows.

## 13. "Bug review"
**v11.4** fixed two bugs:
- Files with accented, Arabic or emoji names were falsely reported as "disappeared". Under some language settings rsync escapes such names, which broke the internal file lists; `-8` fixed it.
- Spotlight handling when two copies run to the same drive.

## 14. Privacy
- **v11.5:** "Do not mention file names anywhere." The screen, report, notifications and dry run now give counts only; names go in a private list.
- **v12:** "Logs, check files and intermediate files on the receiving drive only, nothing on the Mac's main drive, nothing on the original drive." Everything moved to a hidden `rsync-logs` folder on the destination drive, created only once that drive is confirmed present. A whole-system search after every mode found no new files written elsewhere.

## 15. Documentation and release
- A man page with examples for every option.
- The project renamed to **smartcopy** (**v12.1**). Copies made under the old name are adopted automatically.
- A README, a privacy document, design notes, this summary and an MIT licence.

## 16. Installing it properly
"smartcopy is in Downloads, give me the commands to install it in the right places." This led to **v12.2**:
- `install.sh` puts the program in `/usr/local/bin/smartcopy` and the manual where `man` looks.
- Installing an update while an old copy is still running is safe, because a running script keeps its own copy open. The old copy's log folder must stay until it finishes, and a second copy to the same destination must wait.

## Lessons
- **Test stand-ins must behave like the real thing.** A `caffeinate` stand-in that exited at once, and a `df` stand-in that printed single spaces, each hid a bug that broke the first real run.
- **Measure before optimising.** The 26 MB/s speed came from the destination's format and the source drive, not from the script.
- **Plain English matters.** "rsync error code 23" helps nobody; "2 files could not be read, the source drive reported read errors, here's what to do" does.
- **Privacy has to be designed in from the start.** Logs, temporary files and progress lines are easy places for file names to leak.
