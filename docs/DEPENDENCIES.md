# Dependencies

## What you need to install

| What | Why | Install |
|---|---|---|
| **Homebrew** | Package manager used to install rsync | See [brew.sh](https://brew.sh), or run: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` |
| **rsync 3.2 or newer** | Does the copying and checking. The rsync that comes with macOS is too old: it lacks progress reporting, creation dates and the fast checksums | `brew install rsync`, or `brew bundle` using this repo's `Brewfile` |
| **git** (only to clone the repo) | Downloading smartcopy | `xcode-select --install` (Apple's Command Line Tools), or download the repo as a zip from GitHub |

Homebrew's rsync comes with **xxhash**, the library behind smartcopy's fast `xxh128` checksums, so there's nothing extra to install. If an rsync without xxhash is used, smartcopy falls back to rsync's default checksum, which still works but is slower.

smartcopy looks for rsync at `/opt/homebrew/bin/rsync` (Apple silicon Macs) or `/usr/local/bin/rsync` (Intel Macs). If neither exists, or the version is older than 3.2, it stops and tells you how to install it.

## Setup (once)

1. **Install rsync:**
   ```bash
   brew install rsync
   ```
2. **Give Terminal Full Disk Access:** System Settings → Privacy & Security → Full Disk Access → turn on Terminal (or iTerm, if you use that), then quit and reopen it. Without this, macOS blocks protected files and they fail to copy.
3. **Get and install smartcopy:**
   ```bash
   git clone https://github.com/jamalxcode/smartcopy.git
   cd smartcopy
   sudo ./install.sh
   ```
   This puts the program at `/usr/local/bin/smartcopy` and the manual at `/usr/local/share/man/man1/smartcopy.1`, and checks that rsync is installed. Remove them with `sudo ./install.sh --uninstall`.

## Check everything is ready

```bash
for r in /opt/homebrew/bin/rsync /usr/local/bin/rsync; do
  [ -x "$r" ] && { "$r" --version | head -1; "$r" --version | grep -q xxh128 && echo "fast checksums (xxh128): yes"; }
done
```

You should see `rsync  version 3.2` or newer, and `fast checksums (xxh128): yes`. No output means Homebrew's rsync isn't installed.

## Built into macOS (nothing to install)

smartcopy also uses standard macOS tools that are always present:

| Tool | Used for |
|---|---|
| `/bin/bash` | Runs the script (works with macOS's bash 3.2) |
| `sudo` | Preserves owners and permissions, and reads protected files |
| `diskutil` | Drive format, volume ID, SSD or hard drive, turning ownership on |
| `df`, `stat` | Checking drives are mounted, free space |
| `caffeinate` | Keeping the Mac awake during a copy |
| `mdutil` | Pausing Spotlight indexing on the destination during a copy |
| `tmutil` | Detecting a Time Machine backup in progress (speed test) |
| `osascript`, `launchctl`, `open` | Notifications; opening the report in TextEdit (background mode) |
| `chflags`, `chmod`, `chown` | Hiding and protecting the `rsync-logs` folder |
| `shasum` | Naming locks |
| `nohup`, `ps`, `pgrep`, `kill` | Background mode, `--stop` (stops every rsync the copy started), locks |
| `awk`, `sed`, `grep`, `sort` (file lists; sorts in the destination's log folder), `find`, `xargs`, `tr`, `cut`, `wc`, `head`, `tail`, `date`, `mktemp`, `tput` | Planning, reports, the progress line |
| `dd`, `split`, `/usr/bin/time` | `--speed-test` only |
| `man` (mandoc) | Reading the man page |
| `install`, `xattr` | `install.sh` only: copying files into place, removing the download flag |

## Supported setups

- **macOS:** recent versions on Apple silicon or Intel. It was developed and used on a current macOS release; the minimum version hasn't been tested.
- **Destination formats:** APFS and Mac OS Extended keep everything. exFAT and FAT32 keep file contents and dates only, and FAT32 can't hold files of 4 GB or more. NTFS is read-only on macOS, so it can't be a destination.
- **Sources:** any readable drive or folder. Not suitable for Time Machine backups or making a bootable copy of a running system.
