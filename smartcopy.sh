#!/bin/bash
# smartcopy v12.2 — resumable, self-healing copy of a drive OR a folder on macOS, with checksum
# verification and a plain-English report of every problem, with steps to fix and avoid it.
#
#   sudo smartcopy SOURCE DESTINATION                copy (asks to confirm the first time)
#   sudo smartcopy --background SOURCE DESTINATION   keeps running if Terminal closes
#   sudo smartcopy --dry-run SOURCE DESTINATION      preview what would be copied
#   sudo smartcopy --verify-only SOURCE DESTINATION  only check an earlier copy (resumes if stopped)
#   sudo smartcopy --stop DESTINATION                stop a running copy cleanly
#   sudo smartcopy --speed-test SOURCE DESTINATION   measure both drives and say what limits speed
#
# SOURCE and DESTINATION can be whole drives or folders on any drive, for example:
#   sudo smartcopy "/Volumes/Photos SSD/2024" "/Volumes/Backup/Photos/2024"
# Everything INSIDE the source goes INTO the destination folder (created if it doesn't exist).
#
# Options:  -y, --yes     skip the first-run confirmation
#           --no-verify   skip the final checksum check (faster)
#           --verify-only only run the checksum check on a finished copy (e.g. later, overnight)
#           --jobs N      copy N files side by side (default: tuned automatically while copying)
#           --force       override safety checks (swapped drives, Time Machine, whole boot disk)
# Resume:   run the exact same command again after any interruption, crash or reboot.
# Privacy:  file names are never shown on screen or in the report. Where it matters which files
#           are affected, the report gives a count and points to a private list in the log folder
#           (hidden; locked to your account on APFS drives).
# Storage:  everything this script writes (logs, report, file lists, resume state, locks, temporary
#           files) goes in a hidden "rsync-logs" folder on the DESTINATION drive — nothing is ever
#           written to the Mac's own drive or to the source drive.
# Hash list: every file's fingerprint is saved on the destination (.smartcopy-hashes) while copying
#           and checking, so later checks only need to read the destination drive.

set -u

ts()   { date '+%F %T'; }
usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
hk()   { awk -v k="${1:-0}" 'BEGIN{split("KB MB GB TB PB",u);i=1;while(k>=1024&&i<5){k/=1024;i++};printf "%.1f %s",k,u[i]}'; }
# Word-wrap stdin: wrap FIRST_INDENT REST_INDENT
wrap() {
  awk -v f="$1" -v r="$2" -v w=78 '{ line=""; first=1; n=split($0,a," ")
    for (i=1;i<=n;i++) {
      if (line=="") line=(first?f:r) a[i]
      else if (length(line)+1+length(a[i])>w) { print line; first=0; line=r a[i] }
      else line=line " " a[i] }
    if (line!="") print line }'
}

SELF="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
REPORT_ON=0
MAX_STUCK="${MAX_STUCK:-6}"
MAX_PASSES="${MAX_PASSES:-500}"
VERIFY="${VERIFY:-1}"
YES=0; DETACH=0; FORCE=0; DRYRUN=0; STOP=0; VERIFY_ONLY=0; SPEEDTEST=0; JOBS="${JOBS:-auto}"
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)        YES=1 ;;
    -b|--background) DETACH=1 ;;
    -n|--dry-run)    DRYRUN=1 ;;
    --no-verify)     VERIFY=0 ;;
    --verify-only)   VERIFY_ONLY=1; VERIFY=1 ;;
    --speed-test)    SPEEDTEST=1 ;;
    --jobs)          shift; JOBS="${1:-}" ;;
    --jobs=*)        JOBS="${1#--jobs=}" ;;
    --force)         FORCE=1 ;;
    --stop)          STOP=1 ;;
    -h|--help)       usage 0 ;;
    --)              shift; POS+=("$@"); break ;;
    -*)              echo "Unknown option: $1"; usage 1 ;;
    *)               POS+=("$1") ;;
  esac
  shift
done

# fatal TITLE WHAT FIX AVOID [SIDE] — stop, and explain in the report (or on screen before logging starts)
fatal() {
  echo "ERROR: $1" >&2
  if [ "$REPORT_ON" -eq 1 ]; then
    add_issue PROBLEM "${5:-GENERAL}" "$1" "${2:-}" "${3:-}" "${4:-}"
    RESULT="❌ Stopped because of a problem — see below."
  else
    [ -n "${2:-}" ] && printf '%s\n' "$2" | wrap "       " "       " >&2
    [ -n "${3:-}" ] && printf '%s\n' "$3" | sed 's/^/       • /' >&2
  fi
  exit 1
}

[ "$(id -u)" -eq 0 ] || fatal "Please run this with sudo." "" "Put sudo in front of the command, e.g.: sudo $0 SOURCE DESTINATION"

# ---------------- Path helpers ----------------
abspath() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
resolve() {   # real path (symlinks resolved); parts that don't exist yet are kept as typed
  local p="${1%/}" rest="" r
  [ -z "$p" ] && p="/"
  while [ ! -d "$p" ]; do rest="/$(basename "$p")$rest"; p="$(dirname "$p")"; done
  r="$(cd "$p" 2>/dev/null && pwd -P)"; [ "$r" = "/" ] && r=""
  r="${r}${rest}"; printf '%s' "${r:-/}"
}
mountpoint_of() { df -P "$1" 2>/dev/null | tail -1 | sed -E 's/.*%[[:space:]]+//'; }   # macOS pads columns
dev_of() { if [ "$(uname)" = Darwin ]; then stat -f %d "$1"; else stat -c %d "$1"; fi 2>/dev/null; }
volume_of() {     # the drive a path lives on: /Volumes/Name for external drives, else its mount point
  local p="$1" top e
  case "$p" in
    /Volumes/?*) top="/Volumes/$(printf '%s' "${p#/Volumes/}" | cut -d/ -f1)"
                 [ -L "$top" ] || { printf '%s' "$top"; return; } ;;
  esac
  e="$p"; while [ ! -e "$e" ]; do e="$(dirname "$e")"; done
  mountpoint_of "$e"
}
# The "rsync-logs" folder: at the top of the destination drive (or inside the destination folder
# when the destination isn't an external drive). Nothing is written anywhere else.
logbase_for() {
  local v; v="$(volume_of "$1")"
  case "$v" in /Volumes/?*) printf '%s/rsync-logs' "$v" ;; *) printf '%s/rsync-logs' "$1" ;; esac
}
lock_path() { echo "$(logbase_for "$1")/locks/$(printf '%s' "$1" | shasum | cut -c1-12).lock"; }
lock_pid()  {   # PID of the live smartcopy process holding this lock, if any
  local p; p=$(cat "$1/pid" 2>/dev/null)
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && ps -p "$p" -o command= 2>/dev/null | grep -qE 'smartcopy|safe-copy' && echo "$p"
}

# ---------------- --stop ----------------
if [ "$STOP" -eq 1 ]; then
  [ ${#POS[@]} -eq 1 ] || usage 1
  target="$(resolve "$(abspath "${POS[0]}")")"
  pid=$(lock_pid "$(lock_path "$target")") || fatal "No copy to $target is running."
  pkill -TERM -P "$pid" 2>/dev/null   # rsync, sleep, caffeinate
  kill -TERM "$pid" 2>/dev/null
  echo "Stopped the copy (PID $pid). Run the same copy command again to resume."
  exit 0
fi

[ ${#POS[@]} -eq 2 ] || usage 1
SRC="$(resolve "$(abspath "${POS[0]}")")"
DST="$(resolve "$(abspath "${POS[1]}")")"

check_paths() {
  [ "$SRC" != "$DST" ] || fatal "The source and destination are the same folder." "" "Give two different locations."
  case "$DST/" in "$SRC/"*) fatal "The destination is inside the source." \
    "Copying a folder into itself would loop forever." "Choose a destination outside $SRC." ;; esac
  case "$SRC/" in "$DST/"*) fatal "The source is inside the destination." \
    "Copying into a folder that contains the source would mix the copy with the original." "Choose a destination that doesn't contain $SRC." ;; esac
  case "$DST" in
    /|/Users|/Volumes|/Applications|/Library|/System|/System/Volumes/Data|/Users/Shared|\
/System/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/private|/private/etc*|/private/var*|/etc|/etc/*|/var|/var/*|/Library/*|/opt|/opt/homebrew*)
      fatal "The destination ($DST) is a system location." \
        "Copying into it could damage macOS or your apps." \
        "Choose a folder on another drive, e.g. /Volumes/Backup/MyCopy" ;;
  esac
  if [ -n "${SUDO_USER:-}" ] && [ "$DST" = "$(eval echo "~$SUDO_USER" 2>/dev/null)" ]; then
    fatal "The destination is your whole home folder." "That would mix the copy into your own files." "Use a subfolder, e.g. ~/Copies/Photos"
  fi
}
check_paths

LOCK="$(lock_path "$DST")"
running=$(lock_pid "$LOCK") && fatal "A copy to $DST is already running (PID $running)." "" "Stop it first: sudo $0 --stop \"$DST\""

# ---------------- rsync 3.x (macOS ships an old/openrsync build lacking key features) ----------------
RSYNC=""
for r in /opt/homebrew/bin/rsync /usr/local/bin/rsync; do
  [ -x "$r" ] || continue
  ver=$("$r" --version 2>/dev/null | awk 'NR==1{split($3,v,"."); print v[1]*100+v[2]}')
  if [ "${ver:-0}" -ge 302 ] 2>/dev/null; then RSYNC="$r"; break; fi
done
[ -n "$RSYNC" ] || fatal "A modern rsync (version 3.2 or newer) isn't installed." \
  "The rsync that comes with macOS is too old to copy Mac file details reliably." \
  "Install Homebrew from https://brew.sh if you don't have it
Then run: brew install rsync   (or brew upgrade rsync if it's already installed)"
RSYNC_CAPS="$("$RSYNC" --version 2>/dev/null | tr ',' '\n' | sed 's/^ *//')"
has_cap() { printf '%s\n' "$RSYNC_CAPS" | grep -qx "$1"; }
MAC_FLAGS="-aH"                       # archive + hard links
has_cap ACLs    && MAC_FLAGS="${MAC_FLAGS}A"
has_cap xattrs  && MAC_FLAGS="${MAC_FLAGS}X"
has_cap crtimes && MAC_FLAGS="${MAC_FLAGS}N"
# xxh128 checksums are many times faster to compute than rsync's default MD5 — same safety for this job
CSUM=(); printf '%s\n' "$RSYNC_CAPS" | grep -qw xxh128 && CSUM=(--checksum-choice=xxh128)

# ---------------- Logs and report ----------------
# Names are set here; the folder itself is created by init_logs() only after the destination drive
# is confirmed mounted, so nothing can ever land on the Mac's own drive.
LOGDIR="$(logbase_for "$DST")"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOGDIR/copy-$STAMP.log"            # everything rsync did
REPORT="$LOGDIR/report-$STAMP.txt"       # the plain-English report
VERIFYLOG="$LOGDIR/verify-$STAMP.txt"
FAILED="$LOGDIR/affected-files-$STAMP.txt"
PASSLOG="$LOGDIR/.pass-$STAMP.log"; PASSERR="$LOGDIR/.passerr-$STAMP"
ALLERR="$LOGDIR/.allerr-$STAMP";   FINALERR="$LOGDIR/.finalerr-$STAMP"
ISSUES="$LOGDIR/.issues-$STAMP";   NOTES="$LOGDIR/.notes-$STAMP"
RESULT="❌ Did not finish — see below."
BATCH_SECS=0; BATCH_BYTES=0; TOTAL_PASSES=0; LOOPS=0; SRC_DROPS=0; DST_DROPS=0; STARTED=0; COPY_SECS=0; PREV_UNFINISHED=0
OWN_LOCK=0; SPOT_WAS_ON=0; SPOT_NOTE=""; LOGS_READY=0
init_logs() {
  mkdir -p "$LOGDIR/locks" || fatal "Couldn't create the log folder on the destination drive ($LOGDIR)." \
    "The drive may be read-only or full." "Check the drive in Finder, run Disk Utility > First Aid on it, then run the same command again."
  chflags hidden "$LOGDIR" 2>/dev/null          # out of sight in Finder (Cmd-Shift-. shows hidden items)
  chmod 700 "$LOGDIR" 2>/dev/null               # private on APFS/HFS drives
  : > "$ISSUES"; : > "$NOTES"; : > "$ALLERR"; : > "$FINALERR"
  LOGS_READY=1; REPORT_ON=1
}

# add_issue PROBLEM|NOTE SIDE TITLE WHAT FIX AVOID [EXAMPLES]  (FIX/AVOID/EXAMPLES: one item per line)
add_issue() {
  local out="$NOTES"; [ "$1" = PROBLEM ] && out="$ISSUES"
  {
    echo "■ [$2] $3"
    [ -n "$4" ] && printf '%s\n' "$4" | wrap "    " "    "
    if [ -n "${7:-}" ]; then
      echo "    Which files: listed in your private file list (see the end of this report)."
      [ "$7" = "__LISTED__" ] || { echo "== $3"; printf '%s\n' "$7"; echo; } >> "$FAILED"
    fi
    if [ -n "$5" ]; then echo "    How to fix:";               printf '%s\n' "$5" | wrap "      • " "        "; fi
    if [ -n "$6" ]; then echo "    How to avoid it next time:"; printf '%s\n' "$6" | wrap "      • " "        "; fi
    echo
  } >> "$out"
}
dinfo() { diskutil info "$1" 2>/dev/null | awk -F': *' -v k="$2" '$1 ~ k {print $2; exit}'; }
give_logs_back() {
  [ "$LOGS_READY" -eq 1 ] && [ -d "$LOGDIR" ] || return 0
  [ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER" "$LOGDIR" 2>/dev/null
  chmod -R go-rwx "$LOGDIR" 2>/dev/null       # private: only your Mac account can open the logs
  return 0
}
notify() {
  [ -n "${SUDO_USER:-}" ] || return 0
  launchctl asuser "$(id -u "$SUDO_USER")" sudo -u "$SUDO_USER" \
    osascript -e "display notification \"$1\" with title \"smartcopy\" sound name \"Glass\"" >/dev/null 2>&1
  return 0
}

# ---------------- Mount checks: never write to the internal disk when a drive is missing ----------------
is_mounted() {
  local a b
  [ -d "$1" ] || return 1
  [ "$1" = "/" ] && return 0
  [ "$(mountpoint_of "$1")" = "$1" ] && return 0
  a=$(dev_of "$1"); b=$(dev_of "$(dirname "$1")")
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ]
}
dst_used_k() { is_mounted "$DST_VOL" && df -kP "$DST_VOL" 2>/dev/null | tail -1 | awk '{print $3}'; }

# A plain folder at /Volumes/Name stops the drive mounting there (it comes back as "Name 1").
clear_stale_mountpoint() {
  local v="$1" side="$2"
  case "$v" in /Volumes/?*) ;; *) return ;; esac
  if [ -d "$v" ] && ! is_mounted "$v"; then
    if [ -z "$(ls -A "$v" 2>/dev/null)" ]; then
      rmdir "$v" 2>/dev/null
    else
      fatal "$v is an ordinary folder on your internal disk, not the $side drive." \
        "The drive isn't mounted, and a folder with files in it is sitting where the drive should appear. This can happen if something wrote there while the drive was unplugged." \
        "Move that folder somewhere else (e.g. to your Desktop) and check what's in it
Reconnect the drive, then run the same command again" \
        "Always eject drives before unplugging them" "$(echo "$side" | tr "[:lower:]" "[:upper:]")"
    fi
  fi
}
wait_for_mounts() {
  local warned=0 s_down d_down waited=0 told=0
  until is_mounted "$SRC_VOL" && is_mounted "$DST_VOL"; do
    s_down=0; d_down=0
    is_mounted "$SRC_VOL" || s_down=1
    is_mounted "$DST_VOL" || d_down=1
    clear_stale_mountpoint "$SRC_VOL" source
    clear_stale_mountpoint "$DST_VOL" destination
    if [ "$warned" -eq 0 ]; then
      [ "$STARTED" -eq 1 ] && { SRC_DROPS=$(( SRC_DROPS + s_down )); DST_DROPS=$(( DST_DROPS + d_down )); }
      [ "$s_down" -eq 1 ] && echo "$(ts)  Waiting for the source drive to be connected: $SRC_VOL"
      [ "$d_down" -eq 1 ] && echo "$(ts)  Waiting for the destination drive to be connected: $DST_VOL"
      local list="" v; for v in /Volumes/*; do [ -e "$v" ] && list="${list:+$list, }${v#/Volumes/}"; done
      echo "       Drives connected now: ${list:-none}"
      echo "       (Check the name is spelled exactly right. If the drive came back as e.g. \"Name 1\", eject it and plug it in again.)"
      warned=1
    fi
    if [ "$waited" -ge 600 ] && [ "$told" -eq 0 ]; then notify "Waiting for a drive to be reconnected"; told=1; fi
    sleep 15; waited=$(( waited + 15 ))
  done
}

# ============================ Error analysis (for the report) ============================
error_lines() {   # unique error/warning messages from rsync output files
  cat "$@" 2>/dev/null | sed -E 's/^[0-9\/]+ [0-9:]+ \[[0-9]+\] //' \
    | grep -E '^(rsync( error)?:|file has vanished|WARNING: .*failed verification|ERROR: .*failed verification)' | sort -u
}
# -> SIDE <tab> CATEGORY <tab> PATH
classify() {
  awk -v src="$SRC/" -v dst="$DST/" '
  { l=$0; m=l; gsub(/"[^"]*"/, "", m)          # m = message without file names
    if (m ~ /^rsync error:/) {
      if (m ~ /protocol data stream|error in IPC|unexpectedly closed|socket IO/) cat="crashed"; else next }
    else if (m ~ /file has vanished/)                    cat="vanished"
    else if (m ~ /failed verification/)                  cat="verifyfail"
    else if (m ~ /No space left on device|quota exceeded/) cat="nospace"
    else if (m ~ /Read-only file system/)                cat="readonly"
    else if (m ~ /File too large/)                       cat="toolarge"
    else if (m ~ /File name too long/)                   cat="namelong"
    else if (m ~ /Input\/output error/)                  cat="io"
    else if (m ~ /Device not configured|No such device/) cat="disconnected"
    else if (m ~ /xattr|rsync_xal/)                      cat="xattr"
    else if (m ~ /set_acl|sys_acl|_acl\(/)               cat="acl"
    else if (m ~ /chown|lchown/)                         cat="owner"
    else if (m ~ /unexpectedly closed|Broken pipe/)      cat="crashed"
    else if (m ~ /Operation not permitted/)              cat="notpermitted"
    else if (m ~ /Permission denied/)                    cat="permission"
    else if (m ~ /Invalid argument|Illegal byte sequence/) cat="badname"
    else if (m ~ /No such file or directory/)            cat="missing"
    else                                                 cat="other"
    side="GENERAL"
    if (index(l, "\"" src) || index(l, " " src)) side="SOURCE"
    else if (index(l, "\"" dst) || index(l, " " dst)) side="DESTINATION"
    else if (l ~ /\[sender\]/) side="SOURCE"
    else if (l ~ /\[(receiver|generator)\]/) side="DESTINATION"
    path=""; if (match(l, /"[^"]+"/)) path=substr(l, RSTART+1, RLENGTH-2)
    else if (cat=="verifyfail") { path=l; sub(/^(WARNING|ERROR): /, "", path); sub(/ failed verification.*$/, "", path); path=src path }
    if (match(path, /\/\.[^\/]+\.[A-Za-z0-9]{6}$/)) {          # rsync temp file -> real name
      b=substr(path, RSTART+2); sub(/\.[A-Za-z0-9]{6}$/, "", b); path=substr(path, 1, RSTART) b }
    if (cat=="other" && path=="") path=l
    print side "\t" cat "\t" path }'
}
cat_name() {
  case "$1" in
    io) echo "disk read/write errors";; disconnected) echo "drive disconnections";; permission) echo "permission denied";;
    notpermitted) echo "blocked by macOS protection";; nospace) echo "drive full";; readonly) echo "read-only drive";;
    crashed) echo "copy process cut off";; missing) echo "files or folders went missing";; vanished) echo "files changed during the copy";;
    verifyfail) echo "files damaged in transit";; badname) echo "file names not allowed";; toolarge) echo "files too big for the drive format";;
    namelong) echo "names too long";; xattr) echo "extended attributes";; acl) echo "access lists";; owner) echo "file owners";; *) echo "other errors";;
  esac
}

# explain SIDE CATEGORY COUNT EXAMPLES
explain() {
  local side="$1" cat="$2" n="$3" ex="$4" files src_or_dst
  files="$n file$([ "$n" -eq 1 ] || echo s)"
  local are=are have=have were=were; [ "$n" = 1 ] && { are=is; have=has; were=was; }
  src_or_dst="destination"; [ "$side" = SOURCE ] && src_or_dst="source"
  case "$side:$cat" in
    SOURCE:io)
      add_issue PROBLEM SOURCE "$files could not be read — the source drive reported read errors" \
"The drive returned errors when reading these files. This usually means it has damaged areas (bad sectors), or the connection dropped while reading. If the same files fail every time, the damage is permanent and those files may be lost." \
"Plug the drive straight into the Mac (no hub) with a known-good cable, then run the same command again.
Run Disk Utility > select the source drive > First Aid.
For files that still fail, try copying them one at a time in Finder, or use a recovery tool such as ddrescue (brew install ddrescue).
Copy anything important off this drive soon — it may be failing." \
"Replace drives as soon as they show read errors.
Check drive health now and then: brew install smartmontools, then sudo smartctl -a diskN (diskN from 'diskutil list'; works on most internal and some USB drives)." "$ex" ;;
    *:io)
      add_issue PROBLEM "$side" "$files could not be written — the $src_or_dst drive reported write errors" \
"The drive failed while writing these files. The drive may be failing, or the connection dropped mid-write." \
"Plug the drive straight into the Mac (no hub) with a known-good cable.
Run Disk Utility > select the $src_or_dst drive > First Aid.
Run the same command again — it rewrites the failed files." \
"Use a reliable drive and a direct connection; bus-powered drives on hubs are a common cause.
Don't trust a drive that has shown write errors for important backups." "$ex" ;;
    *:disconnected|*:dropped)
      local title="The $src_or_dst drive disconnected during the copy"
      [ "$cat" = dropped ] && title="The $src_or_dst drive disconnected $n time(s) during the copy (the copy waited and carried on)"
      add_issue PROBLEM "$side" "$title" \
"macOS lost contact with the drive (\"Device not configured\"). Files being copied at that moment were not finished." \
"Reconnect the drive and run the same command again — it carries on from where it stopped." \
"Use a direct connection and a good cable; avoid unpowered hubs for drives that need a lot of power.
Stop drives from sleeping during long copies: sudo pmset -a disksleep 0 (restore later with sudo pmset -a disksleep 10).
Keep a MacBook plugged in with the lid open." "$ex" ;;
    SOURCE:permission)
      add_issue PROBLEM SOURCE "$files could not be read — permission denied" \
"macOS refused to let the copy read these files." \
"Make sure the command starts with sudo.
Give Terminal Full Disk Access: System Settings > Privacy & Security > Full Disk Access > turn on Terminal, then quit and reopen Terminal.
Run the same command again." \
"Always run with sudo from a Terminal that has Full Disk Access." "$ex" ;;
    *:permission)
      add_issue PROBLEM "$side" "$files could not be written — permission denied" \
"macOS refused to let the copy create or replace these files in the $src_or_dst." \
"Make sure the command starts with sudo.
Check the destination isn't locked: select the folder in Finder > Get Info > untick Locked, or run: sudo chflags -R nouchg \"$DST\"
Run the same command again." \
"Don't lock files or folders in the destination; always run with sudo." "$ex" ;;
    SOURCE:notpermitted)
      add_issue PROBLEM SOURCE "$files $are protected by macOS and could not be read" \
"macOS privacy protection or System Integrity Protection blocked access. Files inside system folders can never be copied this way — that part is expected." \
"Give Terminal Full Disk Access: System Settings > Privacy & Security > Full Disk Access > turn on Terminal, then quit and reopen Terminal.
Run the same command again. If the files are inside /System or app bundles, you can ignore them." \
"Copy your own folders (Documents, Photos, projects) rather than system folders." "$ex" ;;
    *:notpermitted)
      add_issue PROBLEM "$side" "macOS blocked changes to $files in the $src_or_dst" \
"These files are locked or protected, so they could not be created or replaced." \
"Unlock them: sudo chflags -R nouchg,noschg \"$DST\"
Give Terminal Full Disk Access (System Settings > Privacy & Security), then run the same command again." \
"Don't lock files in the destination." "$ex" ;;
    *:nospace)
      add_issue PROBLEM DESTINATION "The destination drive is full" \
"The copy stopped because there is no space left on $DST_VOL." \
"Free up space on the destination, use a bigger drive, or copy a smaller folder.
Then run the same command again — what's already copied is kept." \
"Preview the size first with --dry-run, and check the free space shown at the first-run confirmation." ;;
    *:readonly)
      add_issue PROBLEM DESTINATION "The destination drive is read-only" \
"macOS switches a drive to read-only when it finds damage in its file system. NTFS (Windows) drives are always read-only on a Mac." \
"Run Disk Utility > select the destination drive > First Aid, then eject and reconnect it.
If it's an NTFS drive, use an APFS or exFAT drive instead (reformatting erases it)." \
"Use APFS for Mac-only drives, exFAT if Windows also needs to read it.
Always eject drives before unplugging them." ;;
    *:toolarge)
      add_issue PROBLEM DESTINATION "$files $are too big for the destination drive's format" \
"The destination is formatted as FAT32 (MS-DOS), which cannot hold files bigger than 4 GB." \
"Copy the important data off the destination, then reformat it as APFS (Mac only) or exFAT (Mac + Windows) in Disk Utility > Erase. Erasing deletes everything on it.
Run the same command again." \
"Don't use FAT32 drives for backups." "$ex" ;;
    *:namelong)
      add_issue PROBLEM "$side" "$files $have names or paths too long for the $src_or_dst" \
"Some file or folder names, or the full path, are longer than the drive format allows." \
"Shorten the long names (or the folder names above them) on the source, then run the same command again." \
"Keep folder nesting reasonable; use APFS for the destination." "$ex" ;;
    DESTINATION:badname|GENERAL:badname)
      add_issue PROBLEM DESTINATION "$files $have names the destination drive doesn't allow" \
"Drives formatted as exFAT or FAT don't allow some characters (such as : * ? \" < > | \\) or names that end with a dot or space." \
"Rename those files on the source, then run the same command again.
Or reformat the destination as APFS (Disk Utility > Erase — this deletes everything on it)." \
"Use APFS for Mac-only drives." "$ex" ;;
    *:missing)
      if [ "$side" = SOURCE ]; then
        add_issue NOTE SOURCE "$files disappeared from the source before they could be copied" \
"They were deleted or moved while the copy was running, or the source drive briefly disconnected." \
"Run the same command again to pick up anything new." "Close apps that are using the source while copying." "$ex"
      else
        add_issue PROBLEM "$side" "Files or folders disappeared from the destination during the copy" \
"The destination drive most likely disconnected or was ejected mid-copy." \
"Reconnect the drive and run the same command again." \
"Use a direct, reliable connection and keep the Mac awake and plugged in." "$ex"
      fi ;;
    *:vanished)
      add_issue NOTE SOURCE "$files changed or $were deleted on the source while copying" \
"Normal if apps were using the source. Those files reflect whatever existed when the copy reached them." \
"Run the same command again when nothing is using the source, to catch the latest versions." \
"Quit apps that use the source (Photos, Lightroom, Mail, virtual machines) before copying." "$ex" ;;
    *:verifyfail)
      add_issue PROBLEM GENERAL "$files $were damaged in transit and had to be re-sent" \
"rsync checks every file after copying it. These failed that check and were copied again. Once is a fluke; repeatedly points to an unreliable cable, hub, port or drive." \
"Run the same command again; the final verification confirms the result." \
"Try a different cable and port, and avoid hubs.
If it keeps happening, run Apple Diagnostics (restart holding D, or the power button on Apple silicon) to check the Mac's memory." "$ex" ;;
    *:xattr)
      add_issue NOTE "$side" "Some hidden file attributes on $files could not be copied" \
"Extended attributes are extra data macOS attaches to files (Finder tags, comments, download flags). A few are protected by macOS and can't be set by any app. The file contents themselves were copied." \
"Usually nothing to do. If Finder tags or comments matter to you, check a few of the files listed." "" "$ex" ;;
    *:acl)
      add_issue NOTE DESTINATION "Access lists on $files could not be copied" \
"Access-control lists (detailed sharing permissions) aren't supported by the destination's format. File contents were copied." \
"Only matters if you rely on custom sharing permissions; if so, use an APFS destination." "" "$ex" ;;
    *:owner)
      add_issue NOTE DESTINATION "File owners could not be kept on $files" \
"The destination ignores ownership or its format doesn't store it. File contents were copied." \
"Turn ownership on: sudo diskutil enableOwnership \"$DST_VOL\" (or Finder > Get Info on the drive > untick \"Ignore ownership on this volume\"), then run the same command again." "" "$ex" ;;
    *:crashed)
      add_issue PROBLEM GENERAL "The copy process was cut off mid-way" \
"rsync stopped unexpectedly — usually because a drive disconnected, or the Mac went to sleep." \
"Run the same command again; it resumes where it stopped." \
"Keep the Mac awake and plugged in, lid open, with drives connected directly." ;;
    *)
      add_issue PROBLEM "$side" "$n other error(s) the script doesn't recognise" \
"rsync reported errors that don't fit a known pattern. The exact messages are below and in the log." \
"Run the same command again; if they persist, search the exact message online or check the log." "" "$ex" ;;
  esac
}

analyse_errors() {
  local final cats_final cats_all extra
  final="$LOGDIR/.classified-$STAMP"
  error_lines "$FINALERR" "$VERIFYLOG" | classify | sort -u > "$final"
  if [ -s "$final" ]; then
    { echo "Files affected by problems (side, problem, file):"; echo
      awk -F'\t' '{printf "%-12s %-14s %s\n", $1, $2, $3}' "$final"; echo; } >> "$FAILED"
  fi
  # Group by side+category, most serious first
  awk -F'\t' 'BEGIN{ split("nospace readonly io disconnected crashed permission notpermitted toolarge badname namelong verifyfail missing other owner acl xattr vanished",o," "); for(i in o) p[o[i]]=i }
    { k=$1 FS $2; n[k]++; if ($3!="") ex[k]=ex[k] (ex[k]==""?"":"\034") $3 }
    END { for (k in n) { split(k,a,FS); print (p[a[2]]?p[a[2]]:50) FS k FS n[k] FS ex[k] } }' "$final" \
  | sort -n | while IFS=$'\t' read -r _ side cat n ex; do
      explain "$side" "$cat" "$n" "$([ -n "$ex" ] && echo "__LISTED__")"
    done
  if [ "${FDA_MISSING:-0}" -eq 1 ]; then
    if grep -qE "$(printf '\t')(permission|notpermitted)$(printf '\t')" "$final"; then
      add_issue PROBLEM GENERAL "Terminal doesn't have Full Disk Access — the likely cause of the blocked files above" \
"Without it, macOS blocks access to protected locations (Mail, Messages, Safari data, some Library folders and some external drives)." \
"Open System Settings > Privacy & Security > Full Disk Access, turn on Terminal, quit and reopen Terminal, then run the same command again." \
"Leave Full Disk Access on for Terminal if you copy drives regularly."
    else
      add_issue NOTE GENERAL "Terminal doesn't have Full Disk Access" \
"Nothing was blocked this time, but copying protected locations (Mail, Messages, some Library folders) would fail without it." "" \
"Turn it on in System Settings > Privacy & Security > Full Disk Access if you copy those."
    fi
  fi
  # Problems that happened on earlier passes but were fixed by retrying
  if [ $(( TOTAL_PASSES - LOOPS )) -gt 0 ]; then
    cats_final=$(cut -f2 "$final" | sort -u)
    cats_all=$(error_lines "$ALLERR" | classify | cut -f2 | sort -u)
    extra=""
    for c in $cats_all; do
      printf '%s\n' "$cats_final" | grep -qx "$c" || extra="${extra:+$extra, }$(cat_name "$c")"
    done
    [ -n "$extra" ] && add_issue NOTE GENERAL "Some problems were temporary and fixed themselves by retrying" \
"The copy needed $(( TOTAL_PASSES - LOOPS )) extra pass(es). Problems seen along the way that went away on retry: $extra." "" \
"If this happens often, check cables and connections, and keep the Mac awake and plugged in."
  fi
  [ "$SRC_DROPS" -gt 0 ] && explain SOURCE dropped "$SRC_DROPS" ""
  [ "$DST_DROPS" -gt 0 ] && explain DESTINATION dropped "$DST_DROPS" ""
  rm -f "$final"
}

STEP_N=0; STEP_TOTAL=0
step() {   # step "TITLE" "what happens" "what comes next"
  STEP_N=$(( STEP_N + 1 ))
  echo
  echo "━━━━━━━━ STEP $STEP_N of $STEP_TOTAL: $1 ━━━━━━━━"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | wrap "  " "  "
  [ -n "${3:-}" ] && echo "  Next: $3"
  echo
}
done_msg() { printf '\r\033[K'; echo "  ✓ $*"; }
# Show a heartbeat while a background job runs:  heartbeat PID "message"
heartbeat() {
  local pid="$1" msg="$2" t0=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s — %s so far   ' "$msg" "$(fmt_left $(( SECONDS - t0 )) | sed 's/<1 min/under a minute/')"
    sleep 3
  done
  printf '\r\033[K'
}

copied_paths()  {   # "size<TAB>path" for each file copied this run, each file once
  awk '$4 ~ /^>f/ { line = $0; for (i = 1; i <= 6; i++) sub(/^[^ ]+ +/, "", line); sz[line] = $5; n[line]++ }
       END { for (p in sz) print sz[p] "\t" n[p] "\t" p }' "$LOG" 2>/dev/null
}
copied_bytes()  { copied_paths | awk -F'\t' '{ s += $1 } END { printf "%.0f", s }'; }
copied_count()  { copied_paths | wc -l | tr -d ' '; }
copied_twice()  { copied_paths | awk -F'\t' '$2 > 1' | wc -l | tr -d ' '; }
copy_bytes_per_sec()  {   # measured over the main copying stage only
  local b secs="$COPY_SECS"; b=$(copied_bytes)
  [ "${BATCH_SECS:-0}" -gt 0 ] && { secs=$BATCH_SECS; b=$BATCH_BYTES; }
  [ "$secs" -gt 0 ] && echo $(( ${b:-0} / secs ))
}
fmt_dur()             { echo "$(( $1 / 3600 ))h $(( $1 % 3600 / 60 ))m"; }

# Explain a slow copy: what was measured, and which of the likely causes apply here
speed_note() {
  local b bps n avg causes="" fix="" ssd
  b=$(copied_bytes); [ "${b:-0}" -gt 5000000000 ] 2>/dev/null || return 0      # only for copies over 5 GB
  bps=$(copy_bytes_per_sec); [ "${bps:-0}" -gt 0 ] || return 0
  [ "$bps" -lt 100000000 ] || return 0                                          # 100 MB/s or more is fine
  n=$(copied_count); avg=$(( b / (n > 0 ? n : 1) ))
  case "$DST_FS" in exfat|msdos)
    causes="${causes}– The destination is formatted as $FS_LABEL. macOS's support for it is slow with many files and large folders — Carbon Copy Cloner's developers advise avoiding exFAT on a Mac unless Windows needs the drive too.
"
    fix="${fix}If the drive is only used with Macs: copy anything important off it, reformat it as APFS in Disk Utility > Erase (this deletes everything on it), and run the copy again. APFS is usually much faster for this and also keeps Mac details (permissions, tags, links) that exFAT drops.
" ;;
  esac
  ssd=$(dinfo "$SRC_VOL" 'Solid State')
  if [ "$ssd" = "No" ]; then
    causes="${causes}– The source is a spinning hard drive. These are much slower than SSDs, especially when reading many separate files.
"
    fix="${fix}Nothing to change for the hard drive itself — but keep the Mac from doing other heavy disk work on it during the copy.
"
  fi
  if [ "$avg" -lt 1000000 ]; then
    causes="${causes}– The files are small (on average $(hk $(( avg / 1024 )))). With small files, the work per file — not the data — sets the speed.
"
    fix="${fix}For huge numbers of tiny files, consider zipping folders first and copying the archives.
"
  fi
  [ "${TM_RUNNING:-0}" -eq 1 ] && causes="${causes}– Time Machine was backing up during the copy, competing for the drives.
"
  causes="${causes}– A slow connection: a hub, an old cable or a USB 2 port limits speed (USB 2 tops out around 35–40 MB/s).
"
  fix="${fix}Run  sudo $0 --speed-test \"$SRC\" \"$DST\"  to measure both drives and see exactly what limits the speed (it also says whether --jobs helps).
"
  fix="${fix}Plug both drives directly into the Mac with the cables they came with. To check the link speed: Apple menu > About This Mac > More Info > System Report > USB; each drive should show \"Up to 5 Gb/s\" or faster.
"
  add_issue NOTE GENERAL "The copy ran at $(( bps / 1000000 )) MB/s on average — here's what usually slows it down" \
"$(hk $(( b / 1024 ))) was copied in $(fmt_dur "$COPY_SECS") of copying time ($n file$([ "$n" -eq 1 ] || echo s), $(hk $(( avg / 1024 ))) on average). Likely causes, most likely first:
${causes}" "${fix%$'\n'}" ""
}

render_report() {
  local np nn copied speed=""
  analyse_errors
  speed_note
  local twice; twice=$(copied_twice)
  if [ "${twice:-0}" -gt 0 ]; then
    add_issue NOTE DESTINATION "$twice file(s) were copied twice — once in the main copy, then again in the final pass" \
"After the main copy, the final pass found these files' dates or sizes on the destination didn't match the source, so it copied them again. The result is correct; it only cost time. On exFAT drives macOS sometimes changes a file's date just after it's written, which causes this." "" \
"If it happens on every run, reformatting the destination as APFS avoids it (erasing deletes everything on it)."
  fi
  local bps; bps=$(copy_bytes_per_sec)
  [ "${bps:-0}" -gt 0 ] 2>/dev/null && [ "$(copied_bytes)" -gt 50000000 ] && speed="    Speed: $(( bps / 1000000 )) MB/s"
  np=$(grep -c '^■' "$ISSUES"); nn=$(grep -c '^■' "$NOTES")
  copied=$(copied_count)
  {
    echo "=================================================================="
    echo " FINISHED — REPORT — $(ts)"
    echo "=================================================================="
    echo " From:    $SRC"
    echo " To:      $DST"
    echo " Result:  $RESULT"
    [ $(( ${HASH_CHECKED:-0} + ${FULL_CHECKED:-0} )) -gt 0 ] && \
      echo " Check:   ${HASH_CHECKED:-0} files via the saved hash list (destination only), ${FULL_CHECKED:-0} compared with the source"
    echo " Time:    $(fmt_dur "$SECONDS")    Passes: $TOTAL_PASSES    Files copied this run: ${copied:-0}${speed}"
    echo
    if [ "$np" -eq 0 ]; then
      echo "No problems found."; echo
    else
      echo "PROBLEMS ($np)"; echo "------------------------------------------------------------------"; cat "$ISSUES"
    fi
    if [ "$nn" -gt 0 ]; then
      echo "NOTES — for your information ($nn)"; echo "------------------------------------------------------------------"; cat "$NOTES"
    fi
    if [ -s "$FAILED" ]; then
      echo "Private file list: $FAILED"
      echo "  (file names are kept out of this report; that list is in the hidden rsync-logs folder"
      echo "   on the destination drive — to read it:  open -e \"$FAILED\")"
    fi
    echo "This report: $REPORT"
    echo "Full logs:   $LOGDIR"
  } > "$REPORT"
  echo; cat "$REPORT"
}

cleanup() {
  if [ "$SPOT_WAS_ON" -eq 1 ]; then
    local l other=0
    for l in "$LOGDIR"/locks/*.lock; do     # another copy still writing to this drive? leave it off for now;
      [ -d "$l" ] && [ "$l" != "$LOCK" ] || continue   # that copy turns it back on when it finishes
      [ "$(cat "$l/vol" 2>/dev/null)" = "$DST_VOL" ] && [ -n "$(lock_pid "$l")" ] && other=1
    done
    [ "$other" -eq 0 ] && mdutil -i on "$DST_VOL" >/dev/null 2>&1 && rm -f "$SPOT_NOTE"
  fi
  [ "$OWN_LOCK" -eq 1 ] && rm -rf "$LOCK"
  if [ "$REPORT_ON" -eq 1 ]; then
    render_report
    if [ "$DRYRUN" -eq 0 ]; then
      notify "$(printf '%s' "$RESULT" | sed 's/^[^A-Za-z]* //')"
      # In background mode, open the report so it's waiting for you
      [ -n "${SMARTCOPY_CHILD:-}" ] && [ -n "${SUDO_USER:-}" ] && \
        launchctl asuser "$(id -u "$SUDO_USER")" sudo -u "$SUDO_USER" open -e "$REPORT" >/dev/null 2>&1
    fi
  fi
  if [ "$LOGS_READY" -eq 1 ]; then
    rm -f "${HASH_NEW:-}" "$PASSLOG" "$PASSERR" "$ALLERR" "$FINALERR" "$ISSUES" "$NOTES" "$LOGDIR/.plan-$STAMP"*
    give_logs_back
  fi
}
trap cleanup EXIT
on_signal() {
  echo
  if [ "$STARTED" -eq 0 ]; then REPORT_ON=0; echo "Cancelled before the copy started. Nothing was copied."; exit 20; fi
  RESULT="⏸ Stopped before finishing — run the same command again; it continues where it stopped."
  pkill -TERM -P $$ 2>/dev/null      # worker copies
  exit 20
}
trap on_signal INT TERM HUP

# ============================ Pre-flight checks ============================
SRC_VOL="$(volume_of "$SRC")"
DST_VOL="$(volume_of "$DST")"
wait_for_mounts
# Re-resolve now that both drives are present (symlinks on the drives themselves)
SRC="$(resolve "$SRC")"; DST="$(resolve "$DST")"; check_paths
LOCK="$(lock_path "$DST")"
LOGDIR="$(logbase_for "$DST")"; init_logs
running=$(lock_pid "$LOCK") && fatal "A copy to $DST is already running (PID $running)." "" "Stop it first: sudo $0 --stop \"$DST\""
[ -d "$SRC" ] || fatal "The source folder doesn't exist: $SRC" \
  "The drive is connected, but this folder isn't on it." \
  "Check the spelling and capital letters. Tip: type the command, then drag the folder from Finder into Terminal to paste its exact path." "" SOURCE

if [ "$SRC_VOL" = "$SRC" ]; then SRC_DESC="the whole drive $SRC"; else SRC_DESC="the folder $SRC"; fi

# Swapped-drives guard: a marker in the destination records what it's a copy of
MARK=".smartcopy-target"
# Copies made before the rename to smartcopy used ".safe-copy-…" names: adopt them
if [ -d "$DST" ]; then
  [ -f "$DST/.safe-copy-target" ] && [ ! -f "$DST/$MARK" ] && mv "$DST/.safe-copy-target" "$DST/$MARK" 2>/dev/null
  [ -f "$DST/.safe-copy-hashes" ] && [ ! -f "$DST/.smartcopy-hashes" ] && mv "$DST/.safe-copy-hashes" "$DST/.smartcopy-hashes" 2>/dev/null
fi
# Swapped-drives guard also recognises the old marker name
[ -f "$SRC/.safe-copy-target" ] && [ "$FORCE" -eq 0 ] && [ ! -f "$SRC/$MARK" ] && \
  fatal "The source looks like the destination — the two may be swapped." \
    "$SRC was itself the destination of an earlier copy. Running this way round could overwrite your originals with the copy. Nothing was changed." \
    "Check the order: the command is  sudo $0 FROM TO
If you really mean to copy this way round, add --force."
SRC_ID="$(dinfo "$SRC_VOL" 'Volume UUID'):${SRC#"$SRC_VOL"}"
if [ -f "$SRC/$MARK" ] && [ "$FORCE" -eq 0 ]; then
  fatal "The source looks like the destination — the two may be swapped." \
    "$SRC was itself the destination of an earlier copy (it contains a $MARK marker). Running this way round could overwrite your originals with the copy. Nothing was changed." \
    "Check the order: the command is  sudo $0 FROM TO
If you really mean to copy this way round, add --force."
fi
if [ -d "$SRC/Backups.backupdb" ] && [ "$FORCE" -eq 0 ]; then
  fatal "The source is a Time Machine backup." \
    "rsync can't reproduce Time Machine backups properly." \
    "Use Apple's method for moving Time Machine backups (search \"Transfer Time Machine backups\" on support.apple.com)." "" SOURCE
fi
if { [ "$SRC" = "/" ] || [ "$SRC" = "/System/Volumes/Data" ]; } && [ "$FORCE" -eq 0 ]; then
  fatal "The source is your whole startup disk." \
    "Copying a running macOS system this way won't produce a working, bootable copy." \
    "Copy just the folders you need (e.g. /Users/yourname)
For a bootable clone use a dedicated app such as Carbon Copy Cloner or SuperDuper"
fi

DST_FS="$(dinfo "$DST_VOL" 'Type \\(Bundle\\)')"
case "$DST_FS" in exfat) FS_LABEL="exFAT";; msdos) FS_LABEL="FAT32 (MS-DOS)";; apfs) FS_LABEL="APFS";; hfs) FS_LABEL="Mac OS Extended";; *) FS_LABEL="${DST_FS:-unknown}";; esac
case "$DST_FS" in
  apfs|hfs|"")
    META=("$MAC_FLAGS" -8 --numeric-ids)   # archive + hard links + ACLs + xattrs + creation times (when supported)
    case "$DST_VOL" in /Volumes/?*)
      if diskutil info "$DST_VOL" 2>/dev/null | grep -qE 'Owners: +Disabled'; then
        if diskutil enableOwnership "$DST_VOL" >/dev/null 2>&1; then
          add_issue NOTE DESTINATION "Turned on ownership for $DST_VOL" \
"The drive was set to \"Ignore ownership on this volume\", which would have made every copied file belong to an unknown user. It's now on, so owners are kept." "" ""
        else
          add_issue PROBLEM DESTINATION "Ownership is turned off on the destination, so file owners won't be kept" \
"The drive is set to \"Ignore ownership on this volume\" and the script couldn't change it." \
"Run: sudo diskutil enableOwnership \"$DST_VOL\" — or Finder > Get Info on the drive > untick \"Ignore ownership on this volume\". Then run the same command again." ""
        fi
      fi ;;
    esac ;;
  msdos|exfat)
    META=(-rt -8 --modify-window=2)  # FAT/exFAT can't hold owners, perms, xattrs or links; 2s timestamps
    add_issue NOTE DESTINATION "The destination is formatted as $FS_LABEL, so Mac-specific details aren't kept" \
"Owners, permissions, Finder tags and other extended attributes, and symbolic links can't be stored on $FS_LABEL. File contents and dates are copied." "" \
"For a faithful copy of Mac files, use an APFS drive (or exFAT only when Windows also needs it)." ;;
  *)
    META=(-rt -8)
    add_issue NOTE DESTINATION "The destination's format ($DST_FS) only gets file contents and dates" "" "" "Use APFS for a faithful copy of Mac files." ;;
esac

# How many files to copy side by side. Parallel copies overlap the per-file waiting that dominates
# with many files — but on a spinning hard drive they make the head jump around, which is slower.
SRC_SSD="$(dinfo "$SRC_VOL" 'Solid State')"
JOBS_ARG="$JOBS"; AUTO_TUNE=0
if [ "$JOBS" = auto ]; then
  AUTO_TUNE=1                                    # measured during the first minutes of big jobs
  if [ "$SRC_SSD" = "Yes" ]; then JOBS=4; else JOBS=1; fi   # used for jobs too small to measure
  JOBS_WHY="tuned automatically while copying"
else
  case "$JOBS" in ''|*[!0-9]*) fatal "--jobs needs a number, e.g. --jobs 4" ;; esac
  [ "$JOBS" -ge 1 ] && [ "$JOBS" -le 16 ] || fatal "--jobs must be between 1 and 16"
  JOBS_WHY="you chose --jobs $JOBS"
fi
TM_RUNNING=0
tmutil status 2>/dev/null | grep -q 'Running = 1' && TM_RUNNING=1

# First-run confirmation (skipped when resuming the same copy)
need_confirm=1; first_run=1
if [ "${SMARTCOPY_FIRST_RUN:-}" = "1" ]; then
  need_confirm=0                      # parent already asked
elif [ -f "$DST/$MARK" ]; then
  prev_id="$(sed -n 's/^source_id=//p' "$DST/$MARK")"
  # (v4 markers stored only the drive ID for whole-drive copies)
  if [ "$prev_id" = "$SRC_ID" ] || { [ "$SRC_VOL" = "$SRC" ] && [ "$prev_id:" = "$SRC_ID" ]; }; then
    need_confirm=0; first_run=0
    echo "Resuming the copy of $SRC_DESC into $DST."
  else
    add_issue NOTE DESTINATION "The destination previously held a copy of something else" \
"$DST was an earlier copy of $(sed -n 's/^source_name=//p' "$DST/$MARK"). Files from both are now mixed in this folder." "" \
"Use a separate destination folder for each source."
  fi
fi

# Space check on the first run (a folder is measured; a whole drive uses its usage figure)
if [ "$first_run" -eq 1 ]; then
  if [ "$SRC_VOL" = "$SRC" ]; then src_k=$(df -kP "$SRC" | tail -1 | awk '{print $3}')
  else echo "Measuring the source folder..."; src_k=$(du -sk "$SRC" 2>/dev/null | awk '{print $1}'); fi
  free_k=$(df -kP "$DST_VOL" | tail -1 | awk '{print $4}')
  if [ "${src_k:-0}" -gt "${free_k:-0}" ] 2>/dev/null; then
    add_issue PROBLEM DESTINATION "The source ($(hk "$src_k")) may not fit in the free space on the destination ($(hk "$free_k"))" \
"Unless much of it is already there from an earlier copy, the destination will fill up before the copy finishes." \
"Free up space on $DST_VOL, use a bigger drive, or copy a smaller folder." \
"Check sizes before starting; --dry-run shows how much would be copied."
    echo "WARNING: the source ($(hk "$src_k")) may not fit in the destination's free space ($(hk "$free_k"))."
  fi
fi

# FAT32 can't hold files of 4 GB or more — find them before wasting hours
if [ "$DST_FS" = "msdos" ] && [ "$DRYRUN" -eq 0 ]; then
  echo "Checking for files too big for FAT32..."
  big=$(find "$SRC" -type f -size +4194303k 2>/dev/null)
  if [ -n "$big" ]; then
    add_issue PROBLEM DESTINATION "$(printf '%s\n' "$big" | wc -l | tr -d ' ') file(s) are 4 GB or bigger and can't go on a FAT32 drive" \
"The destination is FAT32 (MS-DOS), which can't store files of 4 GB or more. These will fail; everything else will copy." \
"Reformat the destination as APFS (Mac only) or exFAT (Mac + Windows) in Disk Utility > Erase (this deletes everything on it), then run the same command again." \
"Don't use FAT32 drives for backups." "$(printf '%s\n' "$big" | sed "s|^$SRC/||")"
  fi
fi

# ============================ --speed-test ============================
timed() { /usr/bin/time -p sh -c '"$@" >/dev/null 2>&1' sh "$@" 2>&1 >/dev/null | awk '/^real/ {print $2}'; }
fsize() { if [ "$(uname)" = Darwin ]; then stat -f %z "$1"; else stat -c %s "$1"; fi 2>/dev/null; }
rate()  { awk -v b="$1" -v t="$2" 'BEGIN { if (t <= 0) t = 0.01; printf "%.0f", b / t / 1000000 }'; }   # MB/s
frate() { awk -v n="$1" -v t="$2" 'BEGIN { if (t <= 0) t = 0.01; printf "%.0f", n / t }'; }            # files/s
ratio() { awk -v a="$1" -v b="$2" 'BEGIN { if (b <= 0) b = 1; printf "%.2f", a / b }'; }
ge()    { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }

if [ "$SPEEDTEST" -eq 1 ]; then
  REPORT_ON=0
  T="$DST/.smartcopy-speedtest.$$"
  mkdir -p "$T" 2>/dev/null || fatal "Can't write to $DST for the speed test."
  trap 'rm -rf "$T"' EXIT
  echo "Measuring — this takes about a minute and writes ~600 MB of test files (deleted afterwards)."
  echo

  # 1. Source: reading one big file
  big=$(cd "$SRC" && find . -type f -size +262144k 2>/dev/null | head -1)
  if [ -n "$big" ]; then
    b=$(fsize "$SRC/$big"); [ "$b" -gt 1073741824 ] && b=1073741824
    t=$(timed dd if="$SRC/$big" of=/dev/null bs=1048576 count=1024); SR=$(rate "$b" "$t")
  else SR=""; fi
  # 2. Destination: writing one big file
  t=$(timed sh -c 'dd if=/dev/zero of="$1" bs=1048576 count=512 && sync' sh "$T/big"); DW=$(rate 536870912 "$t")
  rm -f "$T/big"
  # 3. Destination: creating many small files, one at a time vs 4 at once
  head -c 16777216 /dev/urandom > "$T/seed"
  for i in 1 2 3 4; do head -c 4194304 /dev/urandom > "$T/seed$i"; mkdir -p "$T/p$i"; done
  mkdir -p "$T/s1"
  t=$(timed sh -c 'split -b 65536 "$1/seed" "$1/s1/x" && sync' sh "$T"); DS1=$(frate 256 "$t")
  t=$(timed sh -c 'for i in 1 2 3 4; do split -b 65536 "$1/seed$i" "$1/p$i/x" & done; wait; sync' sh "$T"); DS4=$(frate 256 "$t")
  # 4. Source: reading many small files, one at a time vs 4 at once (different files, so no caching)
  L="$T/list"; (cd "$SRC" && find . -type f -size -1024k 2>/dev/null | head -2000) > "$L"
  nl=$(wc -l < "$L" | tr -d ' ')
  if [ "$nl" -ge 400 ]; then
    half=$(( nl / 2 )); head -n "$half" "$L" > "$L.a"; tail -n "$half" "$L" > "$L.b"
    t=$(timed sh -c 'cd "$1" && tr "\n" "\0" < "$2" | xargs -0 cat' sh "$SRC" "$L.a"); SS1=$(frate "$half" "$t")
    t=$(timed sh -c 'cd "$1" && tr "\n" "\0" < "$2" | xargs -0 -P 4 -n 25 cat' sh "$SRC" "$L.b"); SS4=$(frate "$half" "$t")
  else SS1=""; SS4=""; fi

  {
    echo "=================================================================="
    echo " SPEED TEST — $(ts)"
    echo "=================================================================="
    echo " Source:       $SRC_VOL  ($([ "$SRC_SSD" = Yes ] && echo SSD || { [ "$SRC_SSD" = No ] && echo "hard drive" || echo "type unknown"; }))"
    echo " Destination:  $DST_VOL  ($FS_LABEL)"
    echo
    echo " Big files:    source reads ${SR:-?} MB/s · destination writes $DW MB/s"
    echo " Small files:  source reads ${SS1:-?} files/s (one at a time), ${SS4:-?} files/s (4 at once)"
    echo "               destination creates $DS1 files/s (one at a time), $DS4 files/s (4 at once)"
    echo
    echo "WHAT THIS MEANS"
    if [ -n "$SR" ]; then
      if ge "$SR" "$DW"; then lim="writing to the destination ($DW MB/s)"; else lim="reading the source ($SR MB/s)"; fi
      echo "  • For big files the limit is $lim." | wrap "  " "    "
    fi
    sl="the destination"; [ -n "$SS1" ] && ! ge "$SS1" "$DS1" && sl="the source"
    echo "  • For small files the limit is $sl. Most real copies are a mix; the more files you have, the more this matters." | wrap "  " "    "
    rec=1
    if [ -n "$SS1" ]; then
      ge "$(ratio "$SS4" "$SS1")" 1.25 && ge "$(ratio "$DS4" "$DS1")" 1.1 && rec=4
    else
      ge "$(ratio "$DS4" "$DS1")" 1.25 && rec=4
    fi
    if [ "$rec" -gt 1 ]; then
      echo "  • Copying 4 files at once is clearly faster here. Use:  --jobs 4" | wrap "  " "    "
    else
      echo "  • Copying several files at once doesn't help here (it can even slow things down). Use:  --jobs 1" | wrap "  " "    "
    fi
    case "$DST_FS" in exfat|msdos)
      echo "  • The destination is $FS_LABEL, which macOS handles slowly. If it's only used with Macs, reformatting it as APFS is usually the biggest single speed-up (erasing deletes everything on it)." | wrap "  " "    " ;;
    esac
    ge "${DW:-0}" 150 || echo "  • Destination writes under 150 MB/s on a USB SSD often mean a slow port, hub or cable. Plug it straight into the Mac and check System Report > USB shows \"Up to 5 Gb/s\" or faster." | wrap "  " "    "
    [ "$TM_RUNNING" -eq 1 ] && echo "  • Time Machine is backing up right now and competing for the drives. Let it finish, or pause it, before copying." | wrap "  " "    "
    echo
    echo " Readings vary a little between runs; if a copy is running at the same time, they'll be lower."
  } | tee "$LOGDIR/speedtest-$STAMP.txt"
  give_logs_back
  exit 0
fi

if [ "$VERIFY_ONLY" -eq 1 ] && [ "$first_run" -eq 1 ]; then
  fatal "There's no earlier copy here to verify." \
    "--verify-only checks a copy made earlier by this script, but $DST doesn't contain one of $SRC_DESC." \
    "Run the normal copy command first (without --verify-only)."
fi
[ "$VERIFY_ONLY" -eq 1 ] && need_confirm=0
if [ "$need_confirm" -eq 1 ] && [ "$YES" -eq 0 ] && [ "$DRYRUN" -eq 0 ]; then
  [ -t 0 ] || fatal "The first run needs your confirmation." "" "Run it in Terminal, or add --yes to skip the question."
  echo
  echo "  FROM  $SRC_DESC"
  echo "  INTO  $DST$([ -d "$DST" ] || echo "   (will be created)")"
  echo "        drive $DST_VOL has $(hk "$(df -kP "$DST_VOL" | tail -1 | awk '{print $4}')") free"
  echo "  Everything inside the source is copied into the destination folder."
  echo "  Files already in the destination that aren't in the source are left alone;"
  echo "  files with the same name are replaced by the source's version."
  printf "Type yes to start: "
  read -r answer
  [ "$answer" = "yes" ] || { REPORT_ON=0; echo "Cancelled. Nothing was changed."; exit 0; }
fi

FDA_MISSING=0
if ! head -c1 "/Library/Application Support/com.apple.TCC/TCC.db" >/dev/null 2>&1; then
  FDA_MISSING=1
  echo "WARNING: Terminal doesn't seem to have Full Disk Access — protected files may fail to copy."
fi

COMMON=(
  --human-readable
  --info=none
  --no-inc-recursive            # list everything first, so the % and time left are accurate
  '--log-file-format=%i %l %C %n%L'  # each file's size and fingerprint (hash), for speed figures and the hash list
)
case "$DST_FS" in
  msdos|exfat)
    # macOS is slow at creating and renaming folder entries on exFAT/FAT. Writing each file straight
    # into place (instead of to a temporary name, then renaming it) avoids two of those per file.
    # A file cut off mid-write has the wrong size or date, so the next run copies it again.
    WRITE_MODE=(--inplace) ;;
  *)
    WRITE_MODE=(--partial-dir=.rsync-partial) ;;   # half-copied files are parked here, never left in place
esac
EXCLUDES=(
  --exclude='/.Spotlight-V100' --exclude='/.fseventsd' --exclude='/.Trashes'
  --exclude='/.DocumentRevisions-V100' --exclude='/.TemporaryItems'
  --exclude='/.MobileBackups' --exclude='/.PKInstallSandboxManager*'
  --exclude='.rsync-partial' --exclude="/$MARK" --exclude='/.smartcopy-hashes*' --exclude='/.safe-copy-hashes*' --exclude='/.safe-copy-target' --exclude='/rsync-logs/' 
)

# ---------------- --dry-run ----------------
if [ "$DRYRUN" -eq 1 ]; then
  echo "Dry run — nothing will be written. Working out what would be copied..."
  dr=$("$RSYNC" "${META[@]}" --dry-run --mkpath --no-inc-recursive --out-format='%i %l' \
    "${EXCLUDES[@]}" "$SRC/" "$DST/" 2> "$FINALERR" \
    | awk '$1 ~ /^>f/ { n++; s += $2 } $1 ~ /^cd/ { d++ } END { printf "%d %.0f %d", n, s, d }')
  rc=${PIPESTATUS[0]}
  read -r dn ds dd <<< "$dr"
  echo "  Would copy $dn files ($(hk $(( ${ds:-0} / 1024 )))) and create $dd folders."
  [ -s "$FINALERR" ] && echo "  Some files couldn't be read — see the report below."
  RESULT="Dry run only — nothing was copied."
  exit "$rc"
fi

# ---------------- Create the destination folder (only now that its drive is confirmed present) ----------------
wait_for_mounts
mkdir -p "$DST" 2>/dev/null || fatal "Couldn't create the destination folder $DST" \
  "The drive may be read-only or full, or the folder above it is locked." \
  "Check the drive in Finder, run Disk Utility > First Aid on it, then run the same command again." "" DESTINATION
probe="$DST/.smartcopy-write-test.$$"
if ( : > "$probe" ) 2>/dev/null; then rm -f "$probe"
else
  fatal "The destination can't be written to." \
    "macOS mounts NTFS (Windows) drives read-only, and switches any drive to read-only when it finds damage." \
    "Run Disk Utility > First Aid on the destination drive, then eject and reconnect it.
If it's NTFS, use an APFS or exFAT drive instead." "Use APFS (Mac only) or exFAT (Mac + Windows) drives." DESTINATION
fi
# Did the previous run on this destination stop part-way? (Then half-written files may exist.)
PREV_UNFINISHED="${SMARTCOPY_PREV_UNFINISHED:-}"
if [ -z "$PREV_UNFINISHED" ]; then
  PREV_UNFINISHED=0
  [ -f "$DST/$MARK" ] && ! grep -q '^finished=yes' "$DST/$MARK" && PREV_UNFINISHED=1
fi
printf 'source_id=%s\nsource_name=%s\nstarted=%s\n' "$SRC_ID" "$SRC" "$(ts)" > "$DST/$MARK"
mark_finished() { echo "finished=yes" >> "$DST/$MARK" 2>/dev/null; }

# ---------------- --background: re-launch detached so closing Terminal doesn't stop it ----------------
if [ "$DETACH" -eq 1 ] && [ -z "${SMARTCOPY_CHILD:-}" ]; then
  CONSOLE="$LOGDIR/console-$STAMP.log"
  args=(--yes); [ "$VERIFY" = "0" ] && args+=(--no-verify); [ "$FORCE" -eq 1 ] && args+=(--force)
  [ "$VERIFY_ONLY" -eq 1 ] && args+=(--verify-only)
  args+=(--jobs "$JOBS_ARG")
  SMARTCOPY_CHILD=1 SMARTCOPY_FIRST_RUN="$first_run" SMARTCOPY_PREV_UNFINISHED="$PREV_UNFINISHED" nohup /bin/bash "$SELF" "${args[@]}" "$SRC" "$DST" > "$CONSOLE" 2>&1 < /dev/null &
  REPORT_ON=0
  echo "Copy is running in the background (PID $!). You can close Terminal."
  echo "  Watch progress:  tail -f \"$CONSOLE\""
  echo "  Stop it:         sudo $0 --stop \"$DST\""
  echo "When it finishes you'll get a notification and the report opens in TextEdit."
  exit 0
fi

# ---------------- Lock, Spotlight, sleep prevention ----------------
if ! mkdir "$LOCK" 2>/dev/null; then
  running=$(lock_pid "$LOCK") && fatal "A copy to $DST is already running (PID $running)." "" "Stop it first: sudo $0 --stop \"$DST\""
  rm -rf "$LOCK"; mkdir "$LOCK" || fatal "Cannot create the lock $LOCK"     # stale lock from a crash
fi
echo $$ > "$LOCK/pid"; echo "$DST_VOL" > "$LOCK/vol"; OWN_LOCK=1

# Spotlight indexing a destination drive slows big copies a lot: pause it, restore it after.
# A note in the log folder remembers this, so a crash or power cut can't leave it off for good.
SPOT_NOTE="$LOGDIR/.spotlight-paused-$(printf '%s' "$DST_VOL" | shasum | cut -c1-12)"
case "$DST_VOL" in /Volumes/?*)
  if command -v mdutil >/dev/null; then
    [ -f "$SPOT_NOTE" ] && SPOT_WAS_ON=1          # paused by an earlier run that didn't finish
    if mdutil -s "$DST_VOL" 2>/dev/null | grep -q 'Indexing enabled'; then
      mdutil -i off "$DST_VOL" >/dev/null 2>&1 && SPOT_WAS_ON=1
    fi
    [ "$SPOT_WAS_ON" -eq 1 ] && : > "$SPOT_NOTE"
  fi ;;
esac

if [ "$PREV_UNFINISHED" -eq 1 ] && [ "${WRITE_MODE[0]}" = --inplace ] && [ "$VERIFY_ONLY" -eq 0 ]; then
  echo "Tidying up temporary files left by the interrupted run..."
  find "$DST" -type d -name .rsync-partial -prune -exec rm -rf {} + 2>/dev/null
fi

caffeinate -ims -w $$ &
STARTED=1

echo "From:   $SRC_DESC"
[ "$VERIFY_ONLY" -eq 1 ] && echo "Task:   check an existing copy (nothing will be copied unless a file doesn't match)"
echo "Into:   $DST   (drive: $DST_VOL, $FS_LABEL)"
echo "Copies at a time: $([ "$AUTO_TUNE" -eq 1 ] && echo "automatic" || echo "$JOBS") ($JOBS_WHY)"
echo "Log:    $LOG"
echo

errors_in() { grep -E '^rsync( error)?:' "$1" | sort -u; }

# ============================ Copy loop ============================
# Returns 0 when a pass finishes, 23 when only persistent errors remain.
# Keeps going while passes make progress; gives up after MAX_STUCK passes in a row with none.
copy_loop() {
  local label="$1"; shift
  local extra=("$@")
  local pass=0 stuck=0 prev_sig="" same=0 sig rc moved used_before used_after wait_s
  LOOPS=$(( LOOPS + 1 ))

  while :; do
    pass=$(( pass + 1 )); TOTAL_PASSES=$(( TOTAL_PASSES + 1 ))
    wait_for_mounts
    [ -d "$SRC" ] || fatal "The source folder is gone: $SRC" \
      "It was moved, renamed or deleted while the copy was running." \
      "Put it back (or fix the path), then run the same command again." "" SOURCE
    : > "$PASSLOG"
    used_before=$(dst_used_k)
    echo "=== $label — pass $pass — $(ts) ===" >> "$LOG"
    [ "$pass" -gt 1 ] && echo "  Trying again (attempt $pass)..."
    # Copy whole files (fastest). Only when a previous attempt was cut off, and the destination keeps
    # half-copied files aside (APFS/HFS), compare against them so big files resume instead of restarting.
    delta=--whole-file
    if [ "${WRITE_MODE[0]}" != --inplace ] && { [ "$PREV_UNFINISHED" -eq 1 ] || [ "$pass" -gt 1 ]; }; then
      delta=--no-whole-file
    fi
    t0=$SECONDS
    "$RSYNC" "${META[@]}" "${COMMON[@]}" "${CSUM[@]}" "${WRITE_MODE[@]}" "$delta" ${extra[@]+"${extra[@]}"} "${EXCLUDES[@]}" \
      --log-file="$PASSLOG" "$SRC/" "$DST/" > /dev/null 2> "$PASSERR" &
    local rpid=$!
    heartbeat "$rpid" "$label: going through all files on both drives"
    wait "$rpid"; rc=$?
    COPY_SECS=$(( COPY_SECS + SECONDS - t0 ))
    sleep 1                                   # let the error capture finish writing
    cat "$PASSLOG" >> "$LOG"
    cat "$PASSERR" >> "$ALLERR"; cp "$PASSERR" "$FINALERR"
    used_after=$(dst_used_k)

    case $rc in
      0)  echo "$label: pass finished cleanly." >> "$LOG"; return 0 ;;
      24) echo "$label: finished (some source files changed during the copy)." >> "$LOG"; return 0 ;;
      20) RESULT="⏸ Stopped before finishing — run the same command again to resume."; exit 20 ;;
      1|2|4) fatal "rsync couldn't start (error code $rc)." \
               "This is a setup problem that retrying won't fix — usually an option this rsync doesn't support." \
               "Update rsync: brew upgrade rsync, then run the same command again.
The exact message is at the end of $LOG" ;;
    esac
    echo "$label: some files had problems (rsync code $rc)." >> "$LOG"
    echo "  Some files had problems — they'll be explained in the report at the end."

    # Problems that retrying cannot fix: stop now; the report explains them
    if grep -qE 'No space left on device|Read-only file system' "$PASSERR"; then
      RESULT="❌ Stopped — the destination can't take any more data. See below."
      exit 1
    fi

    # Progress = files completed, or the destination grew (a huge file cut off part-way)
    moved=$(grep -cE '\] (>f|cd|cL|hf)' "$PASSLOG")
    if [ "$moved" -gt 0 ] || { [ -n "$used_after" ] && [ "$used_after" != "$used_before" ]; }; then
      stuck=0
    else
      stuck=$(( stuck + 1 ))
    fi

    # Same files failing the same way, with nothing else left to copy = permanent problems
    sig=$(errors_in "$PASSERR" | shasum | cut -c1-40)
    if [ "$sig" = "$prev_sig" ]; then same=$(( same + 1 )); else same=0; fi
    if [ "$rc" -eq 23 ] && [ "$same" -ge 1 ] && { [ "$moved" -eq 0 ] || [ "$same" -ge 2 ]; }; then
      echo "  The same files keep failing, so retrying won't help. Everything else is copied." | tee -a "$LOG"
      return 23
    fi
    prev_sig="$sig"

    if [ "$stuck" -ge "$MAX_STUCK" ] || [ "$pass" -ge "$MAX_PASSES" ]; then
      RESULT="❌ Stopped after $stuck passes in a row made no progress. See below."
      exit "$rc"
    fi

    wait_s=$(( (stuck + 1) * 15 )); [ "$wait_s" -gt 300 ] && wait_s=300
    echo "  Waiting ${wait_s}s, then trying again..."
    sleep "$wait_s"
  done
}

# ============================ Planning, batches and the time-left display ============================
fmt_left() {
  local x="$1"
  if [ "$x" -lt 60 ]; then echo "<1 min"
  elif [ "$x" -lt 3570 ]; then echo "$(( (x + 30) / 60 )) min"
  else x=$(( x + 30 )); echo "$(( x / 3600 ))h $(( x % 3600 / 60 ))m"; fi
}
clock_at() {   # clock time N seconds from now; adds the weekday when it isn't today
  local e fmt="+%H:%M"
  e=$(( $(date +%s) + $1 ))
  if [ "$(uname)" = Darwin ]; then
    [ "$(date +%j)" != "$(date -r "$e" +%j)" ] && fmt="+%a %H:%M"; date -r "$e" "$fmt"
  else
    [ "$(date +%j)" != "$(date -d "@$e" +%j)" ] && fmt="+%a %H:%M"; date -d "@$e" "$fmt"
  fi
}

# Time-left estimator — built to be steady:
#  • "work" = bytes + a fixed allowance per file (each file has a set-up cost), so a run of tiny
#    files doesn't look like the copy has stalled
#  • speed = half the average since this stage started + half the average of the last 15 minutes
#  • the displayed finish time moves only gradually (it can't jump hours from one reading to the next)
#  • nothing is shown until there's at least a minute of real progress to go on
PER_FILE=262144
est_reset() { EST_TS=(); EST_WK=(); EST_I=0; EST_T0=$SECONDS; EST_W0=-1; EST_RATE=0; EST_FIN=0; EST_N=0; }
est_add() {    # est_add DONE_BYTES DONE_FILES
  local w=$(( $1 + $2 * PER_FILE )) n span_all span_win r_all r_win
  [ "$EST_W0" -lt 0 ] && { EST_W0=$w; EST_T0=$SECONDS; }
  n=${#EST_TS[@]}
  if [ "$n" -gt 0 ] && [ $(( SECONDS - EST_TS[n-1] )) -lt 5 ]; then return 0; fi
  EST_TS+=("$SECONDS"); EST_WK+=("$w"); n=$(( n + 1 ))
  while [ $(( SECONDS - EST_TS[EST_I] )) -gt 900 ] && [ "$EST_I" -lt $(( n - 2 )) ]; do EST_I=$(( EST_I + 1 )); done
  span_all=$(( SECONDS - EST_T0 )); span_win=$(( SECONDS - EST_TS[EST_I] ))
  [ "$span_all" -ge 60 ] && [ "$w" -gt "$EST_W0" ] || { EST_RATE=0; return 0; }
  r_all=$(( (w - EST_W0) / span_all ))
  r_win=$r_all; [ "$span_win" -ge 60 ] && r_win=$(( (w - EST_WK[EST_I]) / span_win ))
  EST_RATE=$(( (r_all + r_win) / 2 )); [ "$EST_RATE" -gt 0 ] || EST_RATE=1
  EST_N=$(( EST_N + 1 ))
}
est_secs() {   # est_secs BYTES FILES [per-file factor]
  [ "$EST_RATE" -gt 0 ] || { echo 0; return; }
  awk -v b="$1" -v f="$2" -v k="${3:-1}" -v pf="$PER_FILE" -v r="$EST_RATE" 'BEGIN { printf "%.0f", (b + f*pf*k) / r }'
}
# Smooth the finish time: move 1/6 of the way towards the new estimate each update (~30 s settle),
# except right after the first estimate, and never show a time already in the past.
est_finish() {  # est_finish SECONDS_LEFT -> prints smoothed seconds left
  local now tgt; now=$(date +%s); tgt=$(( now + $1 ))
  if [ "$EST_FIN" -eq 0 ]; then EST_FIN=$tgt; else EST_FIN=$(( EST_FIN + (tgt - EST_FIN) / 6 )); fi
  [ "$EST_FIN" -lt "$now" ] && EST_FIN=$now
  echo $(( EST_FIN - now ))
}

# One clearly labelled status line, refreshed every few seconds
progress_line() {   # progress_line LABEL DONE_BYTES TOTAL_BYTES DONE_FILES TOTAL_FILES
  local label="$1" db="$2" tb="$3" df="$4" tf="$5" pct el bps left="estimating…" when="" secs vsecs
  el=$(( SECONDS - PHASE_T0 )); [ "$el" -gt 0 ] || el=1
  bps=$(( (db - ${PHASE_B0:-0}) / el )); [ "$bps" -ge 0 ] || bps=0
  pct=100; [ "$tb" -gt 0 ] && pct=$(( db * 100 / tb ))
  if [ "${TUNING:-0}" -eq 1 ]; then
    left="measuring speed (first ~5 min)"
  elif [ "$EST_RATE" -gt 0 ]; then
    secs=$(est_secs $(( tb > db ? tb - db : 0 )) $(( tf > df ? tf - df : 0 )))
    if [ "$label" = "Copying" ] && [ "$VERIFY" != "0" ]; then
      vsecs=$(est_secs "$ALL_BYTES" "$ALL_FILES" 0.3)       # rough: checking reads, it doesn't create files
      secs=$(est_finish $(( secs + vsecs )))
      left="$(fmt_left "$secs") (incl. ~$(fmt_left "$vsecs") checking)"
    else
      secs=$(est_finish "$secs"); left="$(fmt_left "$secs")"
    fi
    when=$(clock_at "$secs")
  fi
  # Build the line from the most important parts outward, dropping the least important ones
  # when the window is narrow — the time left and the finish time are never cut off.
  local line cols head tail fl=$(( tf > df ? tf - df : 0 )) part
  local -a extras
  head=$(printf '%s %d%%' "$label" "$pct")
  tail=" · TIME LEFT: $left${when:+ · FINISHES ≈ $when}"
  extras=( " · $(hk $(( db / 1024 ))) of $(hk $(( tb / 1024 )))" " · $fl files left" " · $(( bps / 1000000 )) MB/s" )
  cols=$(tput cols 2>/dev/null); [ "${cols:-0}" -ge 40 ] || cols=200
  line="$head"
  for part in "${extras[@]}"; do
    [ $(( ${#line} + ${#part} + ${#tail} )) -lt "$cols" ] && line="$line$part"
  done
  line="$line$tail"
  if [ "${#line}" -ge "$cols" ]; then          # very narrow window: shortest form
    line="$head · LEFT: $left${when:+ · ≈ $when}"
    [ "${#line}" -ge "$cols" ] && line="${line:0:$(( cols - 2 ))}…"
  fi
  printf '\r%s\033[K' "$line"
  if [ $(( SECONDS - LAST_NL )) -ge 600 ]; then echo; LAST_NL=$SECONDS; fi     # keep a history line every 10 min
}

# Scan both drives once: every file in the source (for checking) and which still need copying
plan_scan() {
  PLAN_ALL="$LOGDIR/.plan-$STAMP.all"; PLAN_TODO="$LOGDIR/.plan-$STAMP.todo"
  wait_for_mounts
  ( "$RSYNC" "${META[@]}" --dry-run --no-inc-recursive -ii --out-format='%i %l %n' "${EXCLUDES[@]}" \
      "$SRC/" "$DST/" 2>/dev/null \
    | awk -v all="$PLAN_ALL" -v todo="$PLAN_TODO" '
        substr($1, 2, 1) == "f" && $1 ~ /^[.>]/ {
          i1 = index($0, " "); r = substr($0, i1 + 1); sub(/^ +/, "", r); i2 = index(r, " ")
          line = substr(r, 1, i2 - 1) "\t" substr(r, i2 + 1)
          print line > all; if ($1 ~ /^>/) print line > todo }' ) &
  local scan_pid=$!
  heartbeat "$scan_pid" "Listing every file on both drives"
  wait "$scan_pid"     # wait for the scan only (a bare "wait" would also wait for caffeinate, forever)
  : >> "$PLAN_ALL"; : >> "$PLAN_TODO"
  ALL_FILES=$(wc -l < "$PLAN_ALL" | tr -d ' ');   ALL_BYTES=$(awk -F'\t' '{ s += $1 } END { printf "%.0f", s }' "$PLAN_ALL")
  TODO_FILES=$(wc -l < "$PLAN_TODO" | tr -d ' '); TODO_BYTES=$(awk -F'\t' '{ s += $1 } END { printf "%.0f", s }' "$PLAN_TODO")
  done_msg "Found $ALL_FILES files ($(hk $(( ALL_BYTES / 1024 )))) on the source."
}

# Cut a plan (size<TAB>path, in folder order) into batches of ~1–8 GB / up to 5000 files.
# Writes PREFIX.0001 … and PREFIX.sizes ("batch bytes files"); loads sizes into BSIZE/BCOUNT.
make_batches() {
  local plan="$1" pre="$2" total target b sz cnt
  total=$(awk -F'\t' '{ s += $1 } END { printf "%.0f", s }' "$plan")
  target=$(( total / 64 ))
  [ "$target" -lt 1073741824 ] && target=1073741824; [ "$target" -gt 8589934592 ] && target=8589934592
  awk -F'\t' -v pre="$pre" -v tgt="$target" '
    BEGIN { b = 1; acc = 0; n = 0; f = sprintf("%s.%04d", pre, b) }
    { if ((acc >= tgt || n >= 5000) && n > 0) { close(f); b++; acc = 0; n = 0; f = sprintf("%s.%04d", pre, b) }
      print $2 > f; acc += $1; n++; sz[b] += $1; cnt[b]++ }
    END { close(f); for (i = 1; i <= b; i++) if (cnt[i] > 0) printf "%d %.0f %d\n", i, sz[i], cnt[i] > (pre ".sizes") }' "$plan"
  NB=0; BSIZE=(); BCOUNT=()
  while read -r b sz cnt; do BSIZE[b]=$sz; BCOUNT[b]=$cnt; NB=$b; done < "$pre.sizes"
}

# Keep K rsyncs busy, one batch each. With AUTO_TUNE on big jobs it measures 1-at-a-time against
# 4-at-a-time for ~2 minutes each, then carries on with whichever was faster.
run_batches() {    # run_batches copy|verify PREFIX TOTAL_BYTES TOTAL_FILES
  local mode="$1" pre="$2" tb="$3" tf="$4" k="$JOBS" next=1 slot pid rc b f running done_b done_f r
  local tkv cal=0 stage=0 el work t1 w1 m1 t2 w2 m2 t3 w3 m3 ra rb label="Copying" done_b_tune=0
  local -a PIDS BATCH
  [ "$mode" = verify ] && label="Checking"
  [ "$mode" = hash ] && label="Checking"
  if [ "$AUTO_TUNE" -eq 1 ] && [ "$tb" -ge 21474836480 ] && [ "$tf" -ge 2000 ] && [ "$NB" -ge 6 ]; then
    tkv="TUNED_$mode"
    if [ -n "${!tkv:-}" ]; then k=${!tkv}; else cal=1; k=1; fi
  fi
  RETRY_BATCHES=""; HAD23=0; B_DONE_BYTES=0; B_DONE_FILES=0
  PHASE_T0=$SECONDS; PHASE_B0=0; LAST_NL=$SECONDS; est_reset
  while :; do
    running=0
    for slot in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
      pid="${PIDS[slot]:-}"; [ -n "$pid" ] || continue
      if kill -0 "$pid" 2>/dev/null; then running=$(( running + 1 )); continue; fi
      wait "$pid"; rc=$?; b="${BATCH[slot]}"; PIDS[slot]=""
      B_DONE_BYTES=$(( B_DONE_BYTES + BSIZE[b] )); B_DONE_FILES=$(( B_DONE_FILES + BCOUNT[b] ))
      case $rc in 0|24) ;; 23) HAD23=1 ;; *) RETRY_BATCHES="$RETRY_BATCHES $b" ;; esac
      # A checked batch with no differences is remembered, so an interrupted check can resume
      f=$(printf '%s.%04d' "$pre" "$b")
      if [ "$mode" = verify ]; then
        vharvest < "$f.out" >> "$HASH_NEW"          # matching files: save their fingerprints
        { [ "$rc" -eq 0 ] || [ "$rc" -eq 24 ]; } && [ -z "$(vdiffs < "$f.out")" ] && cat "$f" >> "$VSTATE"
      elif [ "$mode" = hash ]; then
        hcompare "$f" "$f.out" > "$f.diff"
        { [ "$rc" -eq 0 ] || [ "$rc" -eq 24 ]; } && [ ! -s "$f.diff" ] && cat "$f" >> "$VSTATE"
      fi
    done
    if [ "$mode" = copy ]; then
      r=$(cat "$pre".*.log 2>/dev/null | awk '$4 ~ /^>f/ { s += $5; n++ } END { printf "%.0f %d", s, n }')
      done_b=${r% *}; done_f=${r#* }
    else
      r=$(cat "$pre".*.out 2>/dev/null | awk 'substr($1,2,1) == "f" && $2 ~ /^[0-9]+$/ { s += $2; n++ } END { printf "%.0f %d", s, n }')
      done_b=${r% *}; done_f=${r#* }
    fi
    est_add "$done_b" "$done_f"
    if [ "$cal" -eq 1 ]; then          # auto-tuning: compare 1 vs 4 copies at a time
      # Measure data actually landing on the destination (counts big files still being written)
      el=$(( SECONDS - PHASE_T0 ))
      if [ "$mode" = copy ]; then r=$(dst_used_k); r=$(( ${r:-0} * 1024 )); else r=$done_b; fi
      work=$(( r + done_f * 262144 )); done_b_tune=$r
      case $stage in
        0) if [ "$el" -ge 20 ];  then t1=$el; w1=$work; m1=$done_b_tune; stage=1; fi ;;
        1) if [ "$el" -ge 120 ]; then t2=$el; w2=$work; m2=$done_b_tune; k=4; stage=2; fi ;;
        2) if [ "$el" -ge 140 ]; then t3=$el; w3=$work; m3=$done_b_tune; stage=3; fi ;;
        3) if [ "$el" -ge 240 ]; then
             ra=$(( (w2 - w1) / (t2 - t1) )); rb=$(( (work - w3) / (el - t3) ))
             if [ "$rb" -gt $(( ra * 12 / 10 )) ]; then k=4; else k=1; fi
             printf -v "TUNED_$mode" '%s' "$k"
             printf '\r\033[K'
             echo "  Speed tuning: 1 at a time ran at $(( (m2 - m1) / (t2 - t1) / 1000000 )) MB/s, 4 at a time at $(( (done_b_tune - m3) / (el - t3) / 1000000 )) MB/s — using $k at a time from now on."
             stage=4; cal=0; est_reset; PHASE_T0=$SECONDS; PHASE_B0=$done_b
           fi ;;
      esac
    fi
    while [ "$running" -lt "$k" ] && [ "$next" -le "$NB" ]; do
      if ! is_mounted "$SRC_VOL" || ! is_mounted "$DST_VOL"; then printf '\n'; wait_for_mounts; fi
      for slot in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do [ -z "${PIDS[slot]:-}" ] && break; done
      b=$next; f=$(printf '%s.%04d' "$pre" "$b")
      if [ "$mode" = copy ]; then
        "$RSYNC" "${META[@]}" -r '--log-file-format=%i %l %C %n%L' "${CSUM[@]}" "${WRITE_MODE[@]}" "$COPY_DELTA" \
          "${EXCLUDES[@]}" --files-from="$f" --log-file="$f.log" "$SRC/" "$DST/" > /dev/null 2> "$f.err" &
      elif [ "$mode" = verify ]; then
        "$RSYNC" "${META[@]}" -r --checksum "${CSUM[@]}" --dry-run -ii --out-format='%i %l %C %n' \
          "${EXCLUDES[@]}" --files-from="$f" "$SRC/" "$DST/" > "$f.out" 2>&1 &
      elif [ "$mode" = hash ]; then
        # Destination only: list its files into an empty folder; nothing is written, only hashes are read
        "$RSYNC" -r -8 --checksum "${CSUM[@]}" --dry-run -i --out-format='%i %l %C %n' \
          --files-from="$f" "$DST/" "$EMPTY_DIR/" > "$f.out" 2>&1 &
      fi
      PIDS[slot]=$!; BATCH[slot]=$b; next=$(( next + 1 )); running=$(( running + 1 ))
    done
    TUNING=$cal; progress_line "$label" "$done_b" "$tb" "$done_f" "$tf"
    [ "$running" -eq 0 ] && [ "$next" -gt "$NB" ] && break
    sleep 1
  done
  echo
}

# Fast copy of everything the scan found missing or changed
batch_copy() {
  local pre="$LOGDIR/.plan-$STAMP.c" t0
  [ "$TODO_FILES" -gt 0 ] || return 0
  COPY_DELTA=--whole-file
  [ "${WRITE_MODE[0]}" != --inplace ] && [ "$PREV_UNFINISHED" -eq 1 ] && COPY_DELTA=--no-whole-file
  make_batches "$PLAN_TODO" "$pre"
  t0=$SECONDS
  run_batches copy "$pre" "$TODO_BYTES" "$TODO_FILES"
  COPY_SECS=$(( COPY_SECS + SECONDS - t0 )); BATCH_SECS=$(( SECONDS - t0 )); [ "$BATCH_SECS" -gt 0 ] || BATCH_SECS=1
  BATCH_BYTES=$(cat "$pre".*.log 2>/dev/null | awk '$4 ~ /^>f/ { s += $5 } END { printf "%.0f", s }')
  cat "$pre".*.log >> "$LOG" 2>/dev/null; cat "$pre".*.err >> "$ALLERR" 2>/dev/null
  [ -n "$RETRY_BATCHES" ] && PREV_UNFINISHED=1     # half-written files possible: the final pass resumes them
  rm -f "$pre".*
}

# ---------------- Hash list (fingerprints of the source files, kept on the destination) ----------------
HALGO="${CSUM[0]:-}"; HALGO="${HALGO#--checksum-choice=}"; HALGO="${HALGO:-default}"
hash_list_ok() { [ -s "$HASHFILE" ] && head -1 "$HASHFILE" | grep -q "algo=$HALGO\$"; }
# From a copy log: fingerprints of files that were copied ("hash<TAB>size<TAB>path")
charvest() {
  awk '$4 ~ /^>f/ && length($6) == 32 && $6 ~ /^[0-9a-f]+$/ {
    line = $0; for (i = 1; i <= 6; i++) sub(/^[^ ]+ +/, "", line)
    print $6 "\t" $5 "\t" line }' "$@"
}
# From full-check output: fingerprints of files that matched the destination exactly
vharvest() {
  awk '{ i = substr($0, 1, 11)
    if (i ~ /^[.h]f/ && substr(i, 3) ~ /^ *$/ && substr($0, 12, 1) == " ") {
      rest = substr($0, 13); sz = rest; sub(/ .*/, "", sz); sub(/^[0-9]+ /, "", rest)
      h = substr(rest, 1, 32); p = substr(rest, 34)
      if (h ~ /^[0-9a-f]+$/ && length(h) == 32) print h "\t" sz "\t" p } }'
}
# Merge new fingerprints (file of "hash<TAB>size<TAB>path") into the list on the destination
hash_merge() {
  local new="$1" tmp="$HASHFILE.new.$$"
  [ -s "$new" ] || return 0
  hash_list_ok || : > "$HASHFILE"
  { echo "#smartcopy-hashes v1 algo=$HALGO"
    awk -F'\t' -v cur="$HASHFILE" 'FILENAME == cur { if (FNR > 1) { p = $0; sub(/^[^\t]*\t[^\t]*\t/, "", p); h[p] = $1 "\t" $2 } next }
      { p = $0; sub(/^[^\t]*\t[^\t]*\t/, "", p); h[p] = $1 "\t" $2 } END { for (p in h) print h[p] "\t" p }' "$HASHFILE" "$new"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$HASHFILE"
  rm -f "$tmp"; : > "$new"
}
# Compare destination-only hashes with the list. Prints differences as ">fc........ path".
hcompare() {   # hcompare BATCH_LIST RSYNC_OUTPUT
  awk -v man="$HASHFILE" -v lst="$1" '
    FILENAME == man { if (FNR > 1) { p = $0; sub(/^[^\t]*\t[^\t]*\t/, "", p); split($0, a, "\t"); h[p] = a[1] } next }
    FILENAME == lst { want[$0] = 1; next }
    substr($0, 1, 2) == ">f" { rest = substr($0, 13); sub(/^[0-9]+ /, "", rest); got[substr(rest, 34)] = substr(rest, 1, 32) }
    END { for (p in want) if (!(p in got) || got[p] != h[p]) print ">fc........ " p }' "$HASHFILE" "$1" "$2"
}

# Turn checker output ("%i size path" for every file) into just the differences, as "%i path".
vdiffs() {
  awk '{
    i = substr($0, 1, 11)
    if (i ~ /^[<>ch.*][fdLDS]/ && substr($0, 12, 1) == " ") {
      rest = substr($0, 13); sub(/^[0-9]+ /, "", rest); rest = substr(rest, 34)
      flags = substr(i, 3); gsub(/ /, "", flags)
      if (i ~ /^[<>c*]/ || flags != "") print i " " rest
    } else if ($0 != "") print }'
}

# ============================ Verification ============================
# Compares every file's contents (checksums) in batches, with the same tuning and time-left display,
# then a quick size/date pass over everything for folders and links. LIST = size<TAB>path lines.
verify() {
  local list="$1" pre="$LOGDIR/.plan-$STAMP.v" vb vf b f rc todo="$LOGDIR/.plan-$STAMP.vtodo" skipped
  : > "$VERIFYLOG"; vrc=0
  # Skip files already confirmed by an earlier check that was interrupted
  touch "$VSTATE"
  awk -F'\t' -v st="$VSTATE" 'FILENAME == st { ok[$0]; next } !($2 in ok)' "$VSTATE" "$list" > "$todo"
  skipped=$(( $(wc -l < "$list") - $(wc -l < "$todo") ))
  [ "$skipped" -gt 0 ] && done_msg "$skipped files were already checked in an earlier run — skipping those."
  list="$todo"
  # Files with a saved fingerprint (same size, unchanged on the source) only need the destination read
  local hc="$LOGDIR/.plan-$STAMP.hc" full="$LOGDIR/.plan-$STAMP.full" hpre="$LOGDIR/.plan-$STAMP.h" hn hb skipf="/dev/null"
  : > "$hc"; cp "$list" "$full"
  [ "$VERIFY_ONLY" -eq 1 ] && [ -s "${PLAN_TODO:-}" ] && skipf="$PLAN_TODO"
  if hash_list_ok; then
    awk -F'\t' -v man="$HASHFILE" -v sk="$skipf" -v hc="$hc" '
      FILENAME == man { if (FNR > 1) { p = $0; sub(/^[^\t]*\t[^\t]*\t/, "", p); sz[p] = $2 } next }
      FILENAME == sk { skip[$2] = 1; next }
      { if (($2 in sz) && sz[$2] == $1 && !($2 in skip)) print > hc; else print }' \
      "$HASHFILE" "$skipf" "$list" > "$full"
  fi
  hn=$(wc -l < "$hc" | tr -d ' ')
  if [ "$hn" -gt 0 ]; then
    hb=$(awk -F'\t' '{ s += $1 } END { printf "%.0f", s }' "$hc")
    done_msg "$hn files ($(hk $(( hb / 1024 )))) have saved fingerprints — checking those by reading only the destination drive."
    EMPTY_DIR=$(mktemp -d "$LOGDIR/.empty.XXXXXX")
    make_batches "$hc" "$hpre"
    run_batches hash "$hpre" "$hb" "$hn"
    : > "$hpre.retry"
    for b in $RETRY_BATCHES; do cat "$(printf '%s.%04d' "$hpre" "$b")" >> "$hpre.retry"; done
    cat "$hpre".*.diff >> "$VERIFYLOG" 2>/dev/null
    # batches that couldn't be read are checked the full way instead
    [ -s "$hpre.retry" ] && awk -F'\t' -v r="$hpre.retry" 'FILENAME == r { x[$0]; next } ($2 in x)' "$hpre.retry" "$hc" >> "$full"
    rm -rf "$hpre".* "$EMPTY_DIR"
    HASH_CHECKED=$(( HASH_CHECKED + hn ))
    [ -s "$full" ] && done_msg "Destination-only part done. Now comparing the remaining files with the source."
  fi
  list="$full"
  vf=$(wc -l < "$list" | tr -d ' '); vb=$(awk -F'\t' '{ s += $1 } END { printf "%.0f", s }' "$list")
  FULL_CHECKED=$(( FULL_CHECKED + vf ))
  if [ "$vf" -gt 0 ]; then
    make_batches "$list" "$pre"
    run_batches verify "$pre" "$vb" "$vf"
    for b in $RETRY_BATCHES; do         # batches cut off by a drive dropping out: once more
      f=$(printf '%s.%04d' "$pre" "$b"); wait_for_mounts
      "$RSYNC" "${META[@]}" -r --checksum "${CSUM[@]}" --dry-run -ii --out-format='%i %l %C %n' \
        "${EXCLUDES[@]}" --files-from="$f" "$SRC/" "$DST/" > "$f.out" 2>&1
      rc=$?
      case $rc in 0|24) ;; 23) HAD23=1 ;; 20) RESULT="⏸ Stopped during verification — run the same command again to redo it."; exit 20 ;; *) vrc=$rc ;; esac
    done
    cat "$pre".*.out 2>/dev/null | vdiffs >> "$VERIFYLOG"
    hash_merge "$HASH_NEW"
    [ "$HAD23" -eq 1 ] && [ "$vrc" -eq 0 ] && vrc=23
    rm -f "$pre".*
  fi
  rm -f "$todo" "$hc" "$full"
  wait_for_mounts
  "$RSYNC" "${META[@]}" --dry-run --itemize-changes "${EXCLUDES[@]}" "$SRC/" "$DST/" >> "$VERIFYLOG" 2>&1 &
  heartbeat $! "Checking folders and links"
  wait $!; rc=$?
  case $rc in 0|24) ;; 23) [ "$vrc" -eq 0 ] && vrc=23 ;; 20) RESULT="⏸ Stopped during verification — run the same command again to redo it."; exit 20 ;; *) [ "$vrc" -eq 0 ] && vrc=$rc ;; esac
  DIFFS=$(grep -E '^[<>ch*]' "$VERIFYLOG" | sed 's/^[^ ]* //' | sort -u | wc -l | tr -d ' ')   # count each file once
  META_DIFFS=$(sort -u "$VERIFYLOG" | awk '$1 ~ /^\./ { f = (substr($1,2,1)=="d") ? substr($1,6) : substr($1,5);
                                 if (f ~ /[tpogaxnb]/) c++ } END { print c+0 }')
}

# ============================ Main ============================
PERSISTENT=0
VSTATE="$LOGDIR/.verified-$(printf '%s|%s' "$SRC_ID" "$DST" | shasum | cut -c1-12)"
HASHFILE="$DST/.smartcopy-hashes"; HASH_NEW="$LOGDIR/.hashnew-$STAMP"; : > "$HASH_NEW"
HASH_CHECKED=0; FULL_CHECKED=0
if [ "$VERIFY_ONLY" -eq 1 ]; then STEP_TOTAL=2; elif [ "$VERIFY" = 0 ]; then STEP_TOTAL=3; else STEP_TOTAL=4; fi
if [ "$VERIFY_ONLY" -eq 1 ]; then
  step "List the files" "Making a list of every file on both drives, so the check knows exactly how much there is." "check every file's contents"
else
  step "List the files" "Comparing both drives to see what's already copied and what isn't." "copy what's missing"
fi
plan_scan
if [ "$VERIFY_ONLY" -eq 0 ]; then
  if [ "$TODO_FILES" -gt 0 ]; then
    step "Copy the files" "Copying $TODO_FILES files ($(hk $(( TODO_BYTES / 1024 )))) that are missing or changed. The first few minutes measure which speed setting is fastest." "a final pass for folders and links"
    batch_copy
    done_msg "Copied $TODO_FILES files."
    rm -f "$VSTATE"                    # files changed: earlier check results no longer apply
  else
    step "Copy the files" "Nothing to copy — everything is already on the destination." "a final pass for folders and links"
  fi
  step "Final pass" "Creating folders and links, and catching anything that changed or was missed. This mostly just reads; it can take several minutes on a big drive." \
    "$([ "$VERIFY" = 0 ] && echo "the report" || echo "check every file's contents against the source")"
  copy_loop "Final pass" || PERSISTENT=1
  charvest "$LOG" > "$HASH_NEW"; hash_merge "$HASH_NEW"      # save fingerprints of everything copied
  done_msg "Final pass done."
fi

if [ "$VERIFY" = "0" ]; then
  if [ "$PERSISTENT" -eq 1 ]; then RESULT="⚠️ Copied, except files that couldn't be read or written — see below."; exit 3; fi
  RESULT="✅ Copied (not verified — --no-verify was used). Verify later with --verify-only."; mark_finished; exit 0
fi

step "Check every file" "Proving the copy is exact. Files with a saved fingerprint are checked by reading only the destination; the rest are compared with the source (and their fingerprints saved for next time). All files are already copied — you can press Ctrl-C to stop this at any time; next time it continues where it stopped:
sudo $0 --verify-only \"$SRC\" \"$DST\"" "the report"
verify "$PLAN_ALL"
done_msg "Check finished."

if [ "$DIFFS" -gt 0 ]; then
  first_diffs=$DIFFS
  echo "  $DIFFS items didn't match — copying just those again, then re-checking them..."
  RLIST="$LOGDIR/.plan-$STAMP.repair"
  grep -E '^[<>ch*]f' "$VERIFYLOG" | sed 's/^[^ ]* //' | sort -u > "$RLIST"
  if [ -s "$RLIST" ]; then copy_loop "Repair" -r --checksum "${CSUM[@]}" --files-from="$RLIST" || PERSISTENT=1; fi
  if grep -qE '^[<>c*][dLDS]' "$VERIFYLOG"; then copy_loop "Repair folders and links" || PERSISTENT=1; fi
  charvest "$LOG" > "$HASH_NEW"; hash_merge "$HASH_NEW"
  awk '{ print "0\t" $0 }' "$RLIST" > "$RLIST.v"
  echo "  Re-checking the repaired files..."
  verify "$RLIST.v"
  if [ "$DIFFS" -eq 0 ]; then
    add_issue PROBLEM GENERAL "$first_diffs file(s) didn't match after copying, and were repaired" \
"The final check found files on the destination whose contents differed from the source even though they looked the same (same size and date). They were copied again and now match. Silent damage like this usually comes from an unreliable drive, cable or hub — or a file that changed during the copy." \
"Nothing to do for this copy — it's now verified." \
"If it happens again, try another cable and port, run Disk Utility > First Aid on both drives, and consider replacing the destination drive."
  fi
fi

[ "$META_DIFFS" -gt 0 ] && add_issue NOTE DESTINATION "$META_DIFFS file(s) have identical contents but different permissions, owners, dates or attributes" \
"The data is correct; only the extra details differ. They're listed in the private check log in your log folder." \
"Run the same command again; if they still differ, the destination probably can't store those details (see any notes about ownership or the drive format)." ""

if [ "$DIFFS" -eq 0 ] && { [ "$vrc" -eq 0 ] || [ "$vrc" -eq 24 ]; } && [ "$PERSISTENT" -eq 0 ]; then
  if [ "$VERIFY_ONLY" -eq 1 ]; then RESULT="✅ Checked — the copy matches the source byte-for-byte. Nothing more to do."
  else RESULT="✅ Copied and verified — the destination matches the source byte-for-byte. Nothing more to do."; fi
  mark_finished
  exit 0
elif [ "$DIFFS" -eq 0 ]; then
  RESULT="⚠️ Copied and verified, except files that couldn't be read or written — see below."
  exit 3
else
  add_issue PROBLEM GENERAL "$DIFFS file(s) still differ from the source after repair" \
"Even after copying them again with full checksums, these files don't match. Either they keep changing on the source, or one of the drives is corrupting data." \
"Make sure nothing is using the source, then run the same command again.
Run Disk Utility > First Aid on both drives.
The differing files are listed in the private check log in your log folder." \
"Quit apps using the source before copying; replace drives that corrupt data."
  RESULT="❌ Verification failed — some files still differ. See below."
  exit 2
fi
