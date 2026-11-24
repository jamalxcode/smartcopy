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
- If the drive disconnects mid-run, writes to the log folder simply fail until it returns. They never fall through to the internal disk.
- This was tested by running every mode, including copy, check, dry run, background with stop and resume, and runs with errors, then searching the whole system for new files. The source drive's contents and timestamps were unchanged.

Two system things are outside the tool's control: `sudo` records that the command ran in the system log, and the shell may save the command in its history.

## How confidential the logs are

| Destination format | Protection |
|---|---|
| APFS / Mac OS Extended | `rsync-logs` is locked to your Mac account (folder `700`, files `600`) and hidden in Finder |
| exFAT / FAT | Hidden in Finder only. These formats can't restrict who opens files, so anyone with the drive can read the logs, just as they can read the copied files |

The logs reveal file names, but those names are already visible as the copied files on the same drive. For real confidentiality, encrypt the destination (Disk Utility → Erase → APFS (Encrypted)). Erasing deletes everything on the drive.

## The man page

Installing the man page (`/usr/local/share/man/man1/smartcopy.1`) is the one optional step that writes to the Mac. It contains only instructions and generic examples.

## Older versions

Versions before v12 wrote logs to `~/rsync-logs` on the Mac, and those logs include file names. Remove them with:

```bash
sudo rm -rf ~/rsync-logs
```
