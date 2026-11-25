# smartcopy

A resumable, self-checking copy tool for macOS, built on `rsync`. It copies a whole drive or a single folder to another drive, keeps going through interruptions and disconnects, checks every file's contents at the end, and finishes with a report in plain English.

Privacy comes first: **file names never appear on screen or in the report**, and **everything the tool writes stays on the destination drive**. Nothing is written to the Mac's own drive or to the source drive.

```bash
sudo smartcopy "/Volumes/Archive" "/Volumes/Backup/Archive"
```

## What it does

- **Resumes after anything.** Ctrl-C, a closed window, a crash, a power cut or an unplugged drive: run the same command again and it carries on from where it stopped.
- **Waits for drives.** If a drive disconnects, it waits for it to come back and then continues.
- **Retries, but knows when to stop.** Failed files are retried. Files that keep failing the same way (for example because of damaged areas on a drive) are reported instead of retried for ever.
- **Checks the result.** It compares fingerprints (xxh128 hashes) of every file on both drives, re-copies any file that doesn't match, then checks it again.
- **Re-checks faster.** Each file's fingerprint is saved on the destination, so later checks only need to read the destination drive. Fingerprints are saved as the copy goes, so they survive an interruption.
- **Handles millions of files.** Its own bookkeeping grows in step with the number of files, with bounded memory (measured up to 3 million files).
- **Starts copying at once.** Listing, copying and checking run at the same time as one pipeline (the streaming engine): the first file is copied within moments, even on a drive with millions of files, and copied files are checked while later ones are still copying. See [docs/STREAMING.md](docs/STREAMING.md).
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
- Copying from a **spinning hard drive** and only the total time matters? Try `--engine batch`. The default engine lists and copies at the same time, which starts copying sooner but makes a hard drive's head jump between the two.

**How much faster is v13?** It depends on what limits the copy.
- Big files on slow drives, like the 1 TB runs above: the drives set the pace, so expect only about 3–10% less time.
- A copy that was stopped and resumed: about 20–40% less time, because files copied before the stop are no longer re-read from the source during the check.
- Hundreds of thousands to millions of small files: about 30–60% less time.
- Copying starts within seconds instead of after a few minutes of listing.

These are estimates from measurements on a test bed, where jobs finished 48–59% sooner than with v12.2. Details are in [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

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

**Download:** [smartcopy (latest, zip)](https://github.com/jamalxcode/smartcopy/archive/refs/heads/main.zip)

**Quickest: install or update with curl** (no git needed). Paste this into Terminal:

```bash
brew install rsync                                   # the one dependency (skip if already installed)
cd ~/Downloads
curl -fL -o smartcopy.zip https://github.com/jamalxcode/smartcopy/archive/refs/heads/main.zip
unzip -oq smartcopy.zip
cd smartcopy-main
sudo ./install.sh
```

Then check the version: `sudo smartcopy --help | head -1` should show `smartcopy v13.0` or newer. You can then delete `~/Downloads/smartcopy.zip` and `~/Downloads/smartcopy-main`.

**Or with git:**

```bash
brew install rsync                                   # the one dependency (or: brew bundle)
git clone https://github.com/jamalxcode/smartcopy.git
cd smartcopy
sudo ./install.sh
```

That installs two files:

| File | Where |
|---|---|
| the program | `/usr/local/bin/smartcopy`, so you run it from anywhere as `sudo smartcopy …` |
| the manual | `/usr/local/share/man/man1/smartcopy.1`, read with `man smartcopy` |

The installer also checks for rsync, removes the "downloaded from the internet" flag, and removes the man page of the old `safe-copy` version if it's there. Then give Terminal **Full Disk Access** (System Settings → Privacy & Security → Full Disk Access).

**Downloaded the files instead of cloning?** Put `smartcopy.sh`, `smartcopy.1` and `install.sh` in one folder and run `sudo ./install.sh` from there. Or install by hand:

```bash
sudo mkdir -p /usr/local/bin /usr/local/share/man/man1
sudo install -m 755 ~/Downloads/smartcopy.sh /usr/local/bin/smartcopy
sudo install -m 644 ~/Downloads/smartcopy.1  /usr/local/share/man/man1/smartcopy.1
```

**Check it:** `which smartcopy` should print `/usr/local/bin/smartcopy`; then run `sudo smartcopy --help`.

**Without installing:** run it from the folder as `sudo ./smartcopy.sh …` and read the manual with `man ./man/smartcopy.1`.

### Update

Run the same curl commands as above. They download the latest version over the old one and install it. With a git clone, run `git pull` in the folder, then `sudo ./install.sh` again.

- If a copy is running, it's safe to install the update, because the running copy keeps using the version it started with. Don't start a second copy to the **same** destination until the first one finishes.
- Existing copies carry on with the new version: their markers and hash lists are picked up automatically, including copies made under the old name `safe-copy`.

### Uninstall

```bash
sudo ./install.sh --uninstall
```

This removes the program and its manual. Your copies, and the `rsync-logs` folders on your drives, are left alone.

### Moving from `safe-copy` (versions before v12.1)

1. Install smartcopy as above.
2. **Wait for any copy started with `safe-copy.sh` to finish.** It keeps its logs and resume progress in `~/rsync-logs` while it runs.
3. Then remove the old files:
   ```bash
   rm -f ~/path/to/safe-copy.sh
   sudo rm -rf ~/rsync-logs          # old logs on the Mac; they contain file names
   ```
4. To resume or check an old copy, run `sudo smartcopy` with the same source and destination.

## Usage

```bash
# Copy a whole drive, or one folder
sudo smartcopy /Volumes/Archive "/Volumes/Backup/Archive"
sudo smartcopy ~/Projects "/Volumes/Backup/Projects"

# Preview: counts and sizes only
sudo smartcopy --dry-run /Volumes/Archive "/Volumes/Backup/Archive"

# Long copies: keep running after Terminal closes, then stop cleanly
sudo smartcopy --background /Volumes/Archive "/Volumes/Backup/Archive"
sudo smartcopy --stop "/Volumes/Backup/Archive"

# Copy now, check later
sudo smartcopy --no-verify   /Volumes/Archive "/Volumes/Backup/Archive"
sudo smartcopy --verify-only /Volumes/Archive "/Volumes/Backup/Archive"

# Speed
sudo smartcopy --speed-test /Volumes/Archive "/Volumes/Backup/Archive"
sudo smartcopy --jobs 4     /Volumes/Archive "/Volumes/Backup/Archive"
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
| `--engine batch` | List everything first, then copy (the v12.3 engine). Default: `stream`, which lists and copies at the same time |
| `--speed-test` | Measure both drives and explain what limits speed |
| `--force` | Override the swapped-drives, Time Machine and startup-disk checks |
| `MAX_STUCK=N` | Give up after N passes in a row with no progress (default 6) |

Exit codes: `0` finished, `1` stopped because of a problem the report explains, `2` files still differ after repair, `3` some files couldn't be read or written, `20` stopped by you.

## What you see

```
━━━━━━━━ STEP 1 of 3: List and copy the files ━━━━━━━━
  Listing the source and copying at the same time: copying starts as soon as
  the first files are found, and totals keep growing until the listing is
  done. Copied files are checked as they finish, by reading them back from the
  destination.
  Next: a final pass for folders and links

Copying · 12.4 GB of 31.0 GB found so far · 41230 files found · 180 MB/s · STILL LISTING
  Speed tuning: 1 at a time ran at 22 MB/s, 4 at a time at 27 MB/s — using 4 at a time from now on.
Copying 49% · 106.8 GB of 215.8 GB · 23 MB/s · 51200 checked · TIME LEFT: 1h 6m · FINISHES ≈ 13:05
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

- [`man/smartcopy.1`](man/smartcopy.1): full manual with examples (`man smartcopy` once installed)
- [`install.sh`](install.sh): installer and uninstaller
- [`docs/DEPENDENCIES.md`](docs/DEPENDENCIES.md): what to install, and the macOS tools it uses
- [`docs/DESIGN.md`](docs/DESIGN.md): how it works and why
- [`docs/STREAMING.md`](docs/STREAMING.md): the streaming engine (v13): one pipeline for listing, copying and checking
- [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md): measured speed, memory and work before and after v12.3, and how to reproduce them
- [`tests/run.sh`](tests/run.sh) and [`bench/`](bench/README.md): automated tests (including the privacy rules) and benchmarks, run on Linux with stand-ins for the macOS tools
- [`docs/CONVERSATION.md`](docs/CONVERSATION.md): how the tool was designed, one request at a time
- [`CHANGELOG.md`](CHANGELOG.md): version history

## License

MIT. See [LICENSE](LICENSE).

## Limits

- It makes a data copy, not a bootable clone of macOS.
- exFAT destinations work but are slower on a Mac and don't keep owners, permissions, Finder tags or symbolic links. APFS is faster and keeps everything.
- Files that are on the destination but not on the source are left alone and not reported, because the tool never deletes.
