# Privacy

smartcopy is designed so that running it leaks as little as possible about what you copy.

## What is never shown

File names and paths inside the copied data never appear in these places:

- the screen: progress, step messages and errors
- the report at the end
- macOS notifications
- `--dry-run` output, which shows only totals such as "Would copy 6 files (1.7 MB) and create 3 folders"

When it matters which files are affected, for example files that couldn't be read, the report gives a **count** and points to a **private file list**.

The only paths shown are the source and destination you typed, and drive names while the tool waits for a drive. Showing drive names helps catch typos.

## Where files are written

Everything the tool writes goes on the **destination drive**:

| Location | Contents |
|---|---|
| `<destination drive>/rsync-logs/` (hidden) | reports, logs, the private file list, the check log, the progress needed to resume, background-mode output, speed-test results, locks, temporary folders |
| `<destination folder>/.smartcopy-hashes` | fingerprint list for faster re-checks |
| `<destination folder>/.smartcopy-target` | records what this folder is a copy of |
| `<destination folder>/.rsync-partial/` | half-copied files (APFS/HFS+ destinations only) |

When the destination isn't an external drive, `rsync-logs` goes inside the destination folder.

**Nothing is written to the Mac's own drive** (no home-folder logs, no `/tmp` files) **and nothing to the source drive.** Some care went into this:

- The log folder is created only after the destination drive is confirmed mounted. If the drive is missing, nothing gets created in its place on the internal disk. That's a classic `/Volumes` pitfall.
- If the drive disconnects mid-run, writes to the log folder simply fail until it returns. They never fall through to the internal disk. Every rsync that writes runs with the destination folder as its working directory, after checking that this folder really is on the destination drive. If the drive is unplugged, its writes fail instead of landing in an empty `/Volumes/Name` folder on the internal disk. The destination folder and the log folder are created from inside the drive in the same way.
- Temporary files from any tool (`sort`, the shell) go in the run's own folder inside `rsync-logs`: `TMPDIR` points there. The script avoids shell here-documents, which macOS's bash 3.2 writes to temporary files and could put in `/tmp` if `TMPDIR` were unavailable. If the destination drive is missing when a run ends, the report is shown on screen and not saved anywhere.
- No network connections are made, and nothing is sent anywhere. There is no telemetry.
- This was tested by running every mode, including copy, check, dry run, background with stop and resume, and runs with errors, then searching the whole system for new files. The source drive's contents and timestamps were unchanged.
- These rules are checked by automated tests (`sudo tests/run.sh`, on Linux with loop-mounted drives). They scan the whole system disk, `TMPDIR` and `HOME` for anything new after a run. They compare the source's names, sizes, dates, permissions and change times before and after. They trace every network socket. They search the screen output, notifications and reports for a marker word that appears only in test file names. And they unplug the destination mid-copy to check that nothing appears in its place and the copy finishes when it returns.

Two system things are outside the tool's control: `sudo` records that the command ran in the system log, and the shell may save the command in its history.

## How confidential the logs are

| Destination format | Protection |
|---|---|
| APFS / Mac OS Extended | `rsync-logs` is locked to your Mac account (folder `700`, files `600`) and hidden in Finder |
| exFAT / FAT | Hidden in Finder only. These formats can't restrict who opens files, so anyone with the drive can read the logs, just as they can read the copied files |

The logs reveal file names, but those names are already visible as the copied files on the same drive. For real confidentiality, encrypt the destination (Disk Utility → Erase → APFS (Encrypted)). Erasing deletes everything on the drive.

## Installing

`sudo ./install.sh` puts two program files on the Mac: `/usr/local/bin/smartcopy` and `/usr/local/share/man/man1/smartcopy.1`. They contain only the program and its instructions, with generic examples. Nothing about your files or copies is ever stored there. Uninstall with `sudo ./install.sh --uninstall`.

## Older versions

Versions before v12 wrote logs to `~/rsync-logs` on the Mac, and those logs include file names. Once any copy started with the old version has finished (it writes there while running), remove them with:

```bash
sudo rm -rf ~/rsync-logs
```
