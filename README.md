# smartcopy

A resumable, self-checking copy tool for macOS, built on `rsync`. It copies a whole drive or a single folder to another drive, keeps going through interruptions and disconnects, checks every file's contents at the end, and finishes with a report in plain English.

Privacy comes first: **file names never appear on screen or in the report**, and **everything the tool writes stays on the destination drive**. Nothing is written to the Mac's own drive or to the source drive.

```bash
sudo ./smartcopy.sh "/Volumes/Archive" "/Volumes/Backup/Archive"
```

## What it does

- **Resumes after anything.** Ctrl-C, a closed window, a crash, a power cut or an unplugged drive: run the same command again and it carries on from where it stopped.
- **Waits for drives.** If a drive disconnects, it waits for it to come back and then continues.
- **Retries, but knows when to stop.** Failed files are retried. Files that keep failing the same way (for example because of damaged areas on a drive) are reported instead of retried for ever.
- **Checks the result.** It compares fingerprints (xxh128 hashes) of every file on both drives, re-copies any file that doesn't match, then checks it again.
- **Re-checks faster.** Each file's fingerprint is saved on the destination, so later checks only need to read the destination drive.
- **Tunes its own speed.** On big jobs it measures copying 1 file at a time against 4 at a time, then uses the faster setting.
- **Explains problems plainly.** It recognises about 17 kinds of problem, such as read errors, a full drive, missing permissions or file names a drive doesn't allow. For each it says which drive was involved, how to fix it and how to avoid it.
- **Shows clear progress.** The work is shown as numbered steps, with one status line showing the time left and the expected finish time.
- **Has safety checks.** It confirms before the first run, refuses source and destination paths that look swapped, refuses system folders as a destination, and never deletes anything.

## It can be slow, and that's fine

Big copies take hours, and the final check reads everything again, which can roughly double the total time. Copying to **exFAT** drives, and from **spinning hard drives**, is especially slow on a Mac. Real runs managed about 25–30 MB/s, so 1 TB took about 10 hours.

**You never lose progress.** Stop it at any time with Ctrl-C, by closing the window, with `--stop`, or because the Mac sleeps or a drive is unplugged. Then run the **same command** again and it carries on where it stopped:

- Files that are already copied are skipped.
- A stopped check skips the files it already confirmed.
- On APFS destinations, a big file that was cut off resumes part-way.

Ways to make it fit your day:

- `--background`: start it and close Terminal; you get a notification when it's done.
- `--no-verify` now, `--verify-only` later (overnight, for example). Both can be stopped and resumed.
- After the first full check, re-checks read only the destination, which is usually much faster.
- Biggest speed-up: if the destination is only used with Macs, format it as **APFS** instead of exFAT. Erasing deletes everything on it.

## Requirements

| Dependency | Install |
|---|---|
| macOS (Apple silicon or Intel), run with `sudo` | — |
| [Homebrew](https://brew.sh) | see brew.sh |
| **rsync 3.2+** (Homebrew's build includes xxhash for fast checksums) | `brew install rsync`, or `brew bundle` using the included `Brewfile` |
| Terminal with **Full Disk Access** | System Settings → Privacy & Security → Full Disk Access → Terminal |
| git (only to clone) | `xcode-select --install` |

The rsync that comes with macOS is too old. Everything else smartcopy uses is built into macOS. The full list, plus a readiness check, is in [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md).

## Install

```bash
brew install rsync            # or: brew bundle
git clone https://github.com/jamalxcode/smartcopy.git
cd smartcopy
chmod +x smartcopy.sh
```

Optional: install the man page so `man smartcopy` works.

```bash
sudo mkdir -p /usr/local/share/man/man1
sudo cp man/smartcopy.1 /usr/local/share/man/man1/
man smartcopy
```

Without installing it, you can read it with `man ./man/smartcopy.1`.

## Usage

```bash
# Copy a whole drive, or one folder
sudo ./smartcopy.sh /Volumes/Archive "/Volumes/Backup/Archive"
sudo ./smartcopy.sh ~/Projects "/Volumes/Backup/Projects"

# Preview: counts and sizes only
sudo ./smartcopy.sh --dry-run /Volumes/Archive "/Volumes/Backup/Archive"

# Long copies: keep running after Terminal closes, then stop cleanly
sudo ./smartcopy.sh --background /Volumes/Archive "/Volumes/Backup/Archive"
sudo ./smartcopy.sh --stop "/Volumes/Backup/Archive"

# Copy now, check later
sudo ./smartcopy.sh --no-verify   /Volumes/Archive "/Volumes/Backup/Archive"
sudo ./smartcopy.sh --verify-only /Volumes/Archive "/Volumes/Backup/Archive"

# Speed
sudo ./smartcopy.sh --speed-test /Volumes/Archive "/Volumes/Backup/Archive"
sudo ./smartcopy.sh --jobs 4     /Volumes/Archive "/Volumes/Backup/Archive"
```

To resume after any interruption, run the same command again.

| Option | What it does |
|---|---|
| `-y`, `--yes` | Skip the first-run confirmation |
| `-b`, `--background` | Keep running after Terminal closes; notify when done |
| `-n`, `--dry-run` | Show what would be copied (counts and sizes only) |
| `--no-verify` | Copy only; skip the final check |
| `--verify-only` | Only check an earlier copy; resumes if stopped |
| `--stop DEST` | Stop a running copy cleanly |
| `--jobs N` | Copy or check N files at once (default: tuned automatically) |
| `--speed-test` | Measure both drives and explain what limits speed |
| `--force` | Override the swapped-drives, Time Machine and startup-disk checks |
| `MAX_STUCK=N` | Give up after N passes in a row with no progress (default 6) |

Exit codes: `0` finished, `1` stopped because of a problem the report explains, `2` files still differ after repair, `3` some files couldn't be read or written, `20` stopped by you.

## What you see

```
━━━━━━━━ STEP 2 of 4: Copy the files ━━━━━━━━
  Copying 94574 files (215.8 GB) that are missing or changed. The first few
  minutes measure which speed setting is fastest.
  Next: a final pass for folders and links

  Speed tuning: 1 at a time ran at 22 MB/s, 4 at a time at 27 MB/s — using 4 at a time from now on.
Copying 49% · 106.8 GB of 215.8 GB · 23 MB/s · TIME LEFT: 1h 6m · FINISHES ≈ 13:05
```

And at the end:

```
 Result:  ⚠️ Copied and verified, except files that couldn't be read or written — see below.

■ [SOURCE] 2 files could not be read — the source drive reported read errors
    The drive returned errors when reading these files...
    Which files: listed in your private file list (see the end of this report).
    How to fix:
      • Plug the drive straight into the Mac (no hub) with a known-good cable...
    How to avoid it next time:
      • Replace drives as soon as they show read errors...
```

## Privacy

See [PRIVACY.md](PRIVACY.md). In short:

- No file names on screen, in the report, in notifications or in the dry run. You get counts, and a pointer to a private file list.
- Everything is written to a hidden `rsync-logs` folder on the **destination drive**: logs, reports, file lists, the progress needed to resume, locks and temporary files.
- Nothing is written to the Mac's own drive or to the source drive. If the destination isn't connected, the tool waits and creates nothing in its place.
- exFAT and FAT drives can't restrict who opens files. For real confidentiality, use an encrypted APFS destination.

## Documentation

- [`man/smartcopy.1`](man/smartcopy.1): full manual with examples
- [`docs/DEPENDENCIES.md`](docs/DEPENDENCIES.md): what to install, and the macOS tools it uses
- [`docs/DESIGN.md`](docs/DESIGN.md): how it works and why
- [`docs/CONVERSATION.md`](docs/CONVERSATION.md): how the tool was designed, one request at a time
- [`CHANGELOG.md`](CHANGELOG.md): version history

## License

MIT. See [LICENSE](LICENSE).

## Limits

- It makes a data copy, not a bootable clone of macOS.
- exFAT destinations work but are slower on a Mac and don't keep owners, permissions, Finder tags or symbolic links. APFS is faster and keeps everything.
- File names containing a tab or a line break aren't supported.
- Files that are on the destination but not on the source are left alone and not reported, because the tool never deletes.
