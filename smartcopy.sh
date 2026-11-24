#!/bin/bash
# smartcopy v13.0 — resumable, self-healing copy of a drive OR a folder on macOS, with checksum
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
#           --engine batch  list everything first, then copy (default: stream — list and copy at once)
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

TAB="$(printf '\t')"
ts()   { date '+%F %T'; }
usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
# hk_v VAR KB: a size in KB as "12.3 GB", stored in VAR (pure shell: no subprocess)
hk_v() {
  local _var="$1" k="${2:-0}" i=0 d=1 x
  local -a u=(KB MB GB TB PB)
  k="${k%%.*}"; case "$k" in ''|*[!0-9]*) k=0 ;; esac
  while [ "$i" -lt 4 ] && [ "$k" -ge $(( d * 1024 )) ]; do d=$(( d * 1024 )); i=$(( i + 1 )); done
  x=$(( (k * 10 + d / 2) / d ))
  printf -v "$_var" '%d.%d %s' $(( x / 10 )) $(( x % 10 )) "${u[i]}"
}
hk() { local _h; hk_v _h "${1:-0}"; printf '%s' "$_h"; }
# words "STRING" VAR...: split a line of numbers into variables. (Here-documents are avoided on
# purpose: macOS's bash 3.2 writes them to temporary files, possibly on the Mac's own drive.)
words() { local _s="$1" _v _i=0; shift; local -a _w; _w=($_s); for _v in "$@"; do printf -v "$_v" '%s' "${_w[_i]:-0}"; _i=$(( _i + 1 )); done; }
# Word-wrap stdin: wrap FIRST_INDENT REST_INDENT
wrap() {
  awk -v f="$1" -v r="$2" -v w=78 '{ line=""; first=1; n=split($0,a," ")
    for (i=1;i<=n;i++) {
      if (line=="") line=(first?f:r) a[i]
      else if (length(line)+1+length(a[i])>w) { print line; first=0; line=r a[i] }
      else line=line " " a[i] }
    if (line!="") print line }'
}

# ============================ File-list library ============================
# Everything that handles lists of files lives here, so it can be tested on its own
# (SMARTCOPY_LIB=1 . smartcopy.sh loads just this part).
#
# Record format: one line per file, fields separated by tabs. A file name is stored the way
# rsync prints it (control characters as \#ooo, and a backslash before # as \#134) with tabs
# also written as \#011, so a stored name never contains a tab or a line break, whatever
# characters the real name has. unesc() turns it back into the real name, which is handed to
# rsync as a NUL-separated list (--from0), so every legal file name works.
#
#   plan        name  size  mtime  T|-          every source file; T = still needs copying
#   fingerprint name  size  mtime  hash         .smartcopy-hashes (sorted, after one header line)
#   journal     name  size  mtime  hash         new fingerprints, appended while copying/checking
#   checkpoint  name  size  mtime               files a stopped check already confirmed
#
# size and mtime are the SOURCE file's at the moment its fingerprint was taken, so a fingerprint
# or checkpoint is only reused while the source file still has that size and date.
# Lists are sorted by name in byte order (LC_ALL=C), and lists are combined by merging sorted
# streams, so memory stays bounded by sort's buffer however many files there are.
SORT_MEM="${SMARTCOPY_SORT_MEM:-256M}"
csort() { LC_ALL=C sort -t "$TAB" -S "$SORT_MEM" -T "${TMPDIR:?}" "$@"; }

AWK_LIB='
function unesc(s,   out, o) {
  out = ""
  while (match(s, /\\#[0-7][0-7][0-7]/)) {
    o = substr(s, RSTART + 2, 1) * 64 + substr(s, RSTART + 3, 1) * 8 + substr(s, RSTART + 4, 1)
    out = out substr(s, 1, RSTART - 1) sprintf("%c", o); s = substr(s, RSTART + 5)
  }
  return out s
}
function safe(s,   i) {
  while ((i = index(s, "\t")) > 0) s = substr(s, 1, i - 1) "\\#011" substr(s, i + 1)
  return s
}
# item(line, F, withC): split an rsync line "%i %l %M [%C] %n" into F[i,l,m,c,n]; 0 = not an item
function item(s, F, withC,   r, j) {
  if (substr(s, 12, 1) != " " || substr(s, 1, 2) !~ /^[<>ch.*][fdLDS]$/) return 0
  F["i"] = substr(s, 1, 11); r = substr(s, 13)
  j = index(r, " "); if (!j) return 0; F["l"] = substr(r, 1, j - 1); r = substr(r, j + 1)
  j = index(r, " "); if (!j) return 0; F["m"] = substr(r, 1, j - 1); r = substr(r, j + 1)
  F["c"] = ""
  if (withC) { F["c"] = substr(r, 1, 32); r = substr(r, 34); if (F["c"] !~ /^[0-9a-f]+$/) F["c"] = "" }
  F["n"] = safe(r)
  return F["l"] ~ /^[0-9]+$/
}'

# scan_parse ALL OTHER SUM < rsync -ii --out-format='%i %l %M %n' output
# ALL: plan records (unsorted). OTHER: folders, links and other non-files (for the final pass).
# SUM: "files bytes todo_files todo_bytes others hardlinks".
scan_parse() {
  LC_ALL=C awk -v all="$1" -v other="$2" -v sum="$3" "$AWK_LIB"'
    item($0, F, 0) {
      t = substr(F["i"], 2, 1); c = substr(F["i"], 1, 1); n = F["n"]
      if (t == "f") {
        if (c == "h") { nh++; print n > other; next }          # hard link: made by the final pass
        if (c != "." && c != ">") next
        todo = (c == ">") ? "T" : "-"
        print n "\t" F["l"] "\t" F["m"] "\t" todo > all
        nf++; nb += F["l"]; if (todo == "T") { tf++; tb += F["l"] }
      } else {
        if (n == "./") n = "."; else sub(/\/$/, "", n)
        print n > other; no++
      }
    }
    END { printf "%d %.0f %d %.0f %d %d\n", nf, nb, tf, tb, no, nh > sum; close(sum); close(all); close(other) }'
}

# nul_list < stored names -> real names, NUL-separated (for rsync --from0 --files-from)
nul_list() { LC_ALL=C awk -F'\t' "$AWK_LIB"'{ printf "%s%c", unesc($1), 0 }'; }

# make_batches LIST PREFIX copy|check|hash TOTAL_BYTES
# Cuts a sorted list into batches of ~1-8 GB or 5000 files (in folder order): PREFIX.0001 (NUL
# name list for rsync), PREFIX.0001.rec (the records, for check/hash) and PREFIX.sizes.
# copy uses only the files marked T. Sets NB, BSIZE[], BCOUNT[].
make_batches() {
  local list="$1" pre="$2" mode="$3" total="${4:-0}" target b sz cnt
  total="${total%%.*}"; target=$(( total / 64 ))
  [ "$target" -lt 1073741824 ] && target=1073741824; [ "$target" -gt 8589934592 ] && target=8589934592
  : > "$pre.sizes" || return 1
  LC_ALL=C awk -F'\t' -v pre="$pre" -v tgt="$target" -v mode="$mode" "$AWK_LIB"'
    function done_batch() { close(f); if (mode != "copy") close(r); printf "%d %.0f %d\n", b, acc, n > (pre ".sizes") }
    mode == "copy" && $4 != "T" { next }
    { if (b == 0 || acc >= tgt || n >= 5000) {
        if (b) done_batch()
        b++; acc = 0; n = 0; f = sprintf("%s.%04d", pre, b); r = f ".rec" }
      printf "%s%c", unesc($1), 0 > f
      if (mode == "check") print $1 "\t" $2 "\t" $3 > r
      else if (mode == "hash") print $1 "\t" $2 "\t" $3 "\t" $4 > r
      acc += $2; n++ }
    END { if (b) done_batch(); close(pre ".sizes") }' "$list" || return 1
  NB=0; BSIZE=(); BCOUNT=()
  while read -r b sz cnt; do BSIZE[b]=$sz; BCOUNT[b]=$cnt; NB=$b; done < "$pre.sizes"
}

# The awk part shared by the merges below: lines arrive grouped by name (any order inside a
# group) and are told apart by their shape: plan (4th field T or -), checkpoint (V), sorted
# journal (5th field J), new journal entries (5th field = sequence number), else fingerprint.
MERGE_LIB='
function reset() { havep = 0; ps = pm = vs = vm = js = jm = jh = ms = mm = mh = ""; nseq = -1 }
function take(  ) {
  if (NF < 4) return
  if (NF == 5) {
    if ($5 == "J") { if (nseq < 0) { js = $2; jm = $3; jh = $4 } }
    else if ($5 + 0 > nseq) { nseq = $5 + 0; js = $2; jm = $3; jh = $4 }
  }
  else if ($4 == "T" || $4 == "-") { havep = 1; ps = $2; pm = $3 }
  else if ($4 == "V") { vs = $2; vm = $3 }
  else { ms = $2; mm = $3; mh = $4 }
}
# latest(): the newest fingerprint in the group -> L[s,m,h]; 0 if none
function latest(L) {
  if (jh != "") { L["s"] = js; L["m"] = jm; L["h"] = jh; return 1 }
  if (mh != "") { L["s"] = ms; L["m"] = mm; L["h"] = mh; return 1 }
  return 0
}'

# journal_fold SORTED_JOURNAL NEW_FILE... : sort the new entries once and merge them into the sorted
# journal (newest wins), replacing it atomically. Each entry is sorted exactly once.
journal_fold() {
  local cj="$1" tmp="$1.tmp.$$" srt="$1.new.$$"; shift
  [ $# -gt 0 ] || return 0
  ( set -o pipefail
    cat "$@" | LC_ALL=C awk -F'\t' -v OFS='\t' 'NF == 4 { print $0, NR }' | csort -k1,1 > "$srt" || exit 1
    { if [ -s "$cj" ]; then csort -m -k1,1 "$cj" "$srt"; else cat "$srt"; fi; } \
      | LC_ALL=C awk -F'\t' "$MERGE_LIB"'
          function flush(  L) { if (latest(L)) print cur "\t" L["s"] "\t" L["m"] "\t" L["h"] "\tJ"; reset() }
          BEGIN { reset() } $1 != cur { if (NR > 1) flush(); cur = $1 } { take() } END { if (NR) flush() }' > "$tmp" \
      && mv -f "$tmp" "$cj" ) || { rm -f "$tmp" "$srt"; return 1; }
  rm -f "$srt" "$@"
}

# select_checks PLAN FINGERPRINTS|"" SORTED_JOURNAL|"" SORTED_CHECKPOINT|"" HASHLIST FULLLIST
# Decides how each planned file is checked: skipped (confirmed by a stopped check and unchanged on the
# source), destination-only (a fingerprint taken from the source at its current size and date) or
# full (compared with the source). Prints "skipped hash_files hash_bytes full_files full_bytes".
select_checks() {
  local plan="$1" man="$2" cj="$3" vs="$4" hc="$5" full="$6"
  ( set -o pipefail
    csort -m -k1,1 "$plan" ${man:+"$man"} ${cj:+"$cj"} ${vs:+"$vs"} \
    | LC_ALL=C awk -F'\t' -v hc="$hc" -v full="$full" "$MERGE_LIB"'
        function flush(  L) {
          if (havep) {
            if (vs != "" && vs == ps && vm == pm) sk++
            else if (latest(L) && L["s"] == ps && L["m"] == pm) { print cur "\t" ps "\t" pm "\t" L["h"] > hc; hn++; hb += ps }
            else { print cur "\t" ps "\t" pm > full; fn++; fb += ps }
          }
          reset() }
        BEGIN { reset(); printf "" > hc; printf "" > full }
        $1 != cur { if (NR > 1) flush(); cur = $1 } { take() }
        END { if (NR) flush(); close(hc); close(full); printf "%d %d %.0f %d %.0f\n", sk, hn, hb, fn, fb }' )
}

# manifest_write OUT ALGO SORTED_JOURNAL FINGERPRINTS|"" PLAN|""
# Writes a new fingerprint list: the old one merged with the journal (newest wins). Given a plan,
# keeps only files that still exist with the same size and date (so the list never goes stale).
manifest_write() {
  local out="$1" algo="$2" cj="$3" man="$4" plan="$5"
  ( set -o pipefail
    { echo "#smartcopy-hashes v2 algo=$algo"
      csort -m -k1,1 "$cj" ${man:+"$man"} ${plan:+"$plan"} \
      | LC_ALL=C awk -F'\t' -v prune="${plan:+1}" "$MERGE_LIB"'
          function flush(  L) {
            if (latest(L) && (!prune || (havep && L["s"] == ps && L["m"] == pm))) print cur "\t" L["s"] "\t" L["m"] "\t" L["h"]
            reset() }
          BEGIN { reset() } $1 != cur { if (NR > 1) flush(); cur = $1 } { take() } END { if (NR) flush() }'
    } > "$out" )
}

# harvest_copy RSYNC_OUTPUT JOURNAL: fingerprints of copied files -> journal; prints "bytes files"
harvest_copy() {
  [ -f "$1" ] || { echo "0 0"; return; }
  LC_ALL=C awk -v j="$2" "$AWK_LIB"'
    item($0, F, 1) && substr(F["i"], 1, 2) == ">f" {
      n++; b += F["l"]; if (F["c"] != "") print F["n"] "\t" F["l"] "\t" F["m"] "\t" F["c"] >> j }
    END { printf "%.0f %d\n", b, n }' "$1" 2>/dev/null | tail -1
}

# finish_check RSYNC_OUTPUT JOURNAL DIFFLOG: one full-check batch, read once. Matching files'
# source fingerprints -> journal, differences -> DIFFLOG. Prints "bytes files differences".
finish_check() {
  [ -f "$1" ] || { echo "0 0 1"; return; }
  LC_ALL=C awk -v j="$2" -v d="$3" "$AWK_LIB"'
    item($0, F, 1) {
      i = F["i"]; fl = substr(i, 3); gsub(/ /, "", fl)
      if (substr(i, 2, 1) == "f") { n++; b += F["l"] }
      if (i ~ /^[<>c*]/ || fl != "") { print i " " F["n"] >> d; nd++ }
      else if (i ~ /^[.h]f/ && F["c"] != "") print F["n"] "\t" F["l"] "\t" F["m"] "\t" F["c"] >> j
    }
    END { printf "%.0f %d %d\n", b, n, nd }' "$1" 2>/dev/null | tail -1
}

# finish_hash BATCH_RECORDS RSYNC_OUTPUT DIFFLOG: one destination-only batch. Only this batch'"'"'s
# expected fingerprints are held in memory. Prints "bytes files differences".
finish_hash() {
  [ -f "$1" ] && [ -f "$2" ] || { echo "0 0 1"; return; }
  LC_ALL=C awk -F'\t' -v d="$3" -v rec="$1" "$AWK_LIB"'
    FILENAME == rec { want[$1] = $4; next }
    item($0, F, 1) && substr(F["i"], 2, 1) == "f" { got[F["n"]] = F["c"]; n++; b += F["l"] }
    END { for (p in want) if (!(p in got) || got[p] != want[p]) { print ">fc........ " p >> d; nd++ }
          printf "%.0f %d %d\n", b, n, nd }' "$1" "$2" 2>/dev/null | tail -1
}

# progress_count copy|check FILE...: bytes and files done so far in the batches still running
progress_count() {
  local m="$1" f; shift
  local -a have=(); for f in "$@"; do [ -f "$f" ] && have+=("$f"); done
  [ ${#have[@]} -gt 0 ] || { echo "0 0"; return; }
  set -- "${have[@]}"
  LC_ALL=C awk -v m="$m" 'm == "copy" && substr($0, 1, 2) == ">f" { s += $2; n++; next }
    m != "copy" && substr($0, 2, 1) == "f" && $2 ~ /^[0-9]+$/ { s += $2; n++ }
    END { printf "%.0f %d\n", s, n }' "$@" 2>/dev/null | tail -1
}

# stream_route PLAN OTHER PREFIX < source listing (rsync -ii --out-format='%i %l %M %n' against an
# empty folder, which streams as it goes). The router of the streaming engine: every file goes to the
# plan, folders and links to OTHER, and files are cut into batches AS THEY ARE FOUND (PREFIX.0001 ...,
# NUL-separated names). Each finished batch is announced on stdout as one fixed-size line
# "B id files bytes found_files found_bytes" (padded to 400 bytes: written whole, and the pipe holds
# only a few dozen, so a router that runs ahead of the copiers simply waits — backpressure). The
# first batches are small so copying starts at once; they double up to 5000 files / 1 GB.
# Ends with "S files bytes others hardlinks". Memory: a few counters.
stream_route() {
  LC_ALL=C awk -v plan="$1" -v other="$2" -v pre="$3" "$AWK_LIB"'
    function lim_n(b,  x) { x = 100; while (--b > 0 && x < 5000) x *= 2; return x > 5000 ? 5000 : x }
    function lim_b(b,  x) { x = 33554432; while (--b > 0 && x < 1073741824) x *= 2; return x > 1073741824 ? 1073741824 : x }
    function say(t) { printf "%-400s\n", t; fflush() }
    function cut() { if (!n) return; close(f); say(sprintf("B %d %d %.0f %d %.0f", b, n, acc, nf, nb)); n = 0; acc = 0 }
    item($0, F, 0) {
      t = substr(F["i"], 2, 1); c = substr(F["i"], 1, 1); nm = F["n"]
      if (t == "f") {
        if (c == "h") { nh++; print nm > other; next }          # hard link: made by the final pass
        if (c != "." && c != ">") next
        print nm "\t" F["l"] "\t" F["m"] "\tT" > plan
        nf++; nb += F["l"]
        if (n == 0) { b++; f = sprintf("%s.%04d", pre, b) }
        printf "%s%c", unesc(nm), 0 > f; n++; acc += F["l"]
        if (n >= lim_n(b) || acc >= lim_b(b)) cut()
      } else {
        if (nm == "./") nm = "."; else sub(/\/$/, "", nm)
        print nm > other; no++
      }
    }
    END { cut(); close(plan); close(other); say(sprintf("S %d %.0f %d %d", nf, nb, no, nh)) }'
}

# harvest_stream WORKER_OUTPUT JOURNAL BATCH_RECORDS LOG: one finished streaming copy batch, read once.
# Copied files' fingerprints -> journal and BATCH_RECORDS (for checking them straight away), changed
# items -> LOG. Prints "copied_bytes copied_files processed_bytes processed_files".
harvest_stream() {
  [ -f "$1" ] || { echo "0 0 0 0"; return; }
  : > "$3"
  LC_ALL=C awk -v j="$2" -v rec="$3" -v lo="$4" "$AWK_LIB"'
    item($0, F, 1) {
      if (substr(F["i"], 2, 1) == "f") { pn++; pb += F["l"] }
      if (substr(F["i"], 1, 1) != ".") print $0 >> lo
      if (substr(F["i"], 1, 2) == ">f") {
        n++; b += F["l"]
        if (F["c"] != "") { r = F["n"] "\t" F["l"] "\t" F["m"] "\t" F["c"]; print r >> j; print r > rec }
      }
    }
    END { printf "%.0f %d %.0f %d\n", b, n, pb, pn }' "$1" 2>/dev/null | tail -1
}

# copy_stats LOG: "files bytes copied_twice" — each copied file counted once
copy_stats() {
  ( set -o pipefail
    LC_ALL=C awk "$AWK_LIB"'item($0, F, 1) && substr(F["i"], 1, 2) == ">f" { print F["n"] "\t" F["l"] }' "$1" \
    | csort -k1,1 -s | LC_ALL=C awk -F'\t' '
        function flush() { if (p != "") { u++; ub += sz; if (c > 1) tw++ } }
        $1 != p { flush(); p = $1; c = 0 } { c++; sz = $2 } END { flush(); printf "%d %.0f %d\n", u, ub, tw }' ) 2>/dev/null \
  || echo "0 0 0"
}

# diff_summary DIFFLOG REPAIRLIST: unique differing items, items differing only in details, and the
# list of differing files to copy again. Prints "differences detail_differences".
diff_summary() {
  local log="$1" rl="$2" d m
  d=$( LC_ALL=C awk '/^[<>ch*]/ { s = $0; sub(/^[^ ]* /, "", s); print s }' "$log" | csort -u | wc -l | tr -d ' ' )
  LC_ALL=C awk '/^[<>ch*]f/ { s = $0; sub(/^[^ ]* /, "", s); print s }' "$log" | csort -u > "$rl"
  m=$( csort -u "$log" | LC_ALL=C awk '$1 ~ /^\./ { f = (substr($1,2,1)=="d") ? substr($1,6) : substr($1,5); if (f ~ /[tpogaxnb]/) c++ } END { print c+0 }' )
  echo "${d:-0} ${m:-0}"
}

[ "${SMARTCOPY_LIB:-}" = 1 ] && return 0 2>/dev/null

SELF="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
REPORT_ON=0
MAX_STUCK="${MAX_STUCK:-6}"
MAX_PASSES="${MAX_PASSES:-500}"
VERIFY="${VERIFY:-1}"
YES=0; DETACH=0; FORCE=0; DRYRUN=0; STOP=0; VERIFY_ONLY=0; SPEEDTEST=0; JOBS="${JOBS:-auto}"
ENGINE="${SMARTCOPY_ENGINE:-stream}"   # stream (lists and copies at the same time) or batch (v12.3: list, then copy)
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
    --engine)        shift; ENGINE="${1:-}" ;;
    --engine=*)      ENGINE="${1#--engine=}" ;;
    --force)         FORCE=1 ;;
    --stop)          STOP=1 ;;
    -h|--help)       usage 0 ;;
    --)              shift; POS+=("$@"); break ;;
    -*)              echo "Unknown option: $1"; usage 1 ;;
    *)               POS+=("$1") ;;
  esac
  shift
done

# The report is kept in memory until it's written (on the destination drive only)
ISSUES_TXT=""; NOTES_TXT=""; NP=0; NN=0

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

case "$ENGINE" in stream|batch) ;; *) fatal "--engine must be stream or batch" ;; esac
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
dest_key()  { printf '%s' "$1" | shasum | cut -c1-12; }
lock_path() { echo "$(logbase_for "$1")/locks/$(dest_key "$1").lock"; }
is_ours()   { kill -0 "$1" 2>/dev/null && ps -p "$1" -o command= 2>/dev/null | grep -qE 'smartcopy|safe-copy'; }
lock_pid()  {   # PID of the live smartcopy process holding this lock, if any
  local p; p=$(cat "$1/pid" 2>/dev/null)
  [ -n "$p" ] && is_ours "$p" && echo "$p"
}
kill_tree() {   # stop a process's children and grandchildren (rsync workers, list scans, sleep)
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; kill -TERM "$c" 2>/dev/null; done
}

# ---------------- --stop ----------------
if [ "$STOP" -eq 1 ]; then
  [ ${#POS[@]} -eq 1 ] || usage 1
  target="$(resolve "$(abspath "${POS[0]}")")"
  pid=$(lock_pid "$(lock_path "$target")") || fatal "No copy to $target is running."
  kill_tree "$pid"   # rsync, sleep, caffeinate
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
has_cap() { case "$TAB$(printf '%s' "$RSYNC_CAPS" | tr '\n' "$TAB")$TAB" in *"$TAB$1$TAB"*) return 0 ;; esac; return 1; }
MAC_FLAGS="-aH"                       # archive + hard links
has_cap ACLs    && MAC_FLAGS="${MAC_FLAGS}A"
has_cap xattrs  && MAC_FLAGS="${MAC_FLAGS}X"
has_cap crtimes && MAC_FLAGS="${MAC_FLAGS}N"
# xxh128 checksums are many times faster to compute than rsync's default MD5 — same safety for this job
CSUM=(); printf '%s\n' "$RSYNC_CAPS" | grep -qw xxh128 && CSUM=(--checksum-choice=xxh128)
HALGO="${CSUM[0]:-}"; HALGO="${HALGO#--checksum-choice=}"; HALGO="${HALGO:-default}"

# ---------------- Logs and report ----------------
# Names are set here; the folder itself is created by init_logs() only after the destination drive
# is confirmed mounted, so nothing can ever land on the Mac's own drive.
LOGDIR="$(logbase_for "$DST")"
STAMP="$(date +%Y%m%d-%H%M%S)"
set_log_names() {
  LOG="$LOGDIR/copy-$STAMP.log"            # everything rsync did
  REPORT="$LOGDIR/report-$STAMP.txt"       # the plain-English report
  VERIFYLOG="$LOGDIR/verify-$STAMP.txt"
  FAILED="$LOGDIR/affected-files-$STAMP.txt"
  RUNDIR="$LOGDIR/.run-$$-$STAMP"          # this run's working files; removed when it ends
  PASSLOG="$RUNDIR/pass.log"; PASSERR="$RUNDIR/pass.err"
  ALLERR="$RUNDIR/all.err";   FINALERR="$RUNDIR/final.err"
}
set_log_names
RESULT="❌ Did not finish — see below."
BATCH_SECS=0; BATCH_BYTES=0; TOTAL_PASSES=0; LOOPS=0; SRC_DROPS=0; DST_DROPS=0; STARTED=0; COPY_SECS=0; PREV_UNFINISHED=0
OWN_LOCK=0; SPOT_WAS_ON=0; SPOT_NOTE=""; LOGS_READY=0; PLAN_COMPLETE=0; PLAN=""
COPIED_FILES=0; COPIED_BYTES=0
VOLUMES_DEV="$(dev_of /Volumes)"

# Is the current directory really on the destination drive (not a leftover folder on the Mac's drive)?
on_dst_volume() {
  case "$DST_VOL" in /Volumes/?*) [ -n "$VOLUMES_DEV" ] && [ "$(dev_of .)" != "$VOLUMES_DEV" ] ;; *) return 0 ;; esac
}
# in_dst CMD...: run CMD with the destination folder as its working directory, or exit 98 if the
# destination drive isn't really there. Writing through the working directory means that if the
# drive is unplugged, writes fail — they can never land in a folder on the Mac's own drive.
# Use as "in_dst ... &" (background) or "( in_dst ... )" (foreground): it replaces its process.
in_dst() { cd "$DST" 2>/dev/null && on_dst_volume || exit 98; exec "$@"; }

init_logs() {
  local d pid
  if [ "${LOGDIR%/rsync-logs}" = "$DST_VOL" ]; then   # on the drive itself: create it from inside the drive
    ( cd "$DST_VOL" 2>/dev/null && on_dst_volume && mkdir -p rsync-logs/locks )
  else
    mkdir -p "$LOGDIR/locks"
  fi || fatal "Couldn't create the log folder on the destination drive ($LOGDIR)." \
    "The drive may be read-only or full." "Check the drive in Finder, run Disk Utility > First Aid on it, then run the same command again."
  chflags hidden "$LOGDIR" 2>/dev/null          # out of sight in Finder (Cmd-Shift-. shows hidden items)
  chmod 700 "$LOGDIR" 2>/dev/null               # private on APFS/HFS drives
  for d in "$LOGDIR"/.run-*; do                 # working files left by a run that crashed
    [ -d "$d" ] || continue
    pid="${d##*/.run-}"; pid="${pid%%-*}"
    is_ours "$pid" || rm -rf "$d"
  done
  mkdir -p "$RUNDIR/tmp" || fatal "Couldn't create the log folder on the destination drive ($LOGDIR)." \
    "The drive may be read-only or full." "Check the drive in Finder, run Disk Utility > First Aid on it, then run the same command again."
  # Every temporary file any tool makes (sort, the shell) goes here, on the destination drive
  TMPDIR="$RUNDIR/tmp"; export TMPDIR
  : > "$ALLERR"; : > "$FINALERR"
  LOGS_READY=1; REPORT_ON=1
}
drives_here() { is_mounted "$SRC_VOL" && is_mounted "$DST_VOL" && [ -d "$RUNDIR" ]; }
logs_here() {   # the log folder can be written: logs set up, and the destination drive is connected
  [ "$LOGS_READY" -eq 1 ] && is_mounted "$DST_VOL" && [ -d "$LOGDIR" ]
}

# add_issue PROBLEM|NOTE SIDE TITLE WHAT FIX AVOID [EXAMPLES]  (FIX/AVOID/EXAMPLES: one item per line)
add_issue() {
  local block
  block="$(
    echo "■ [$2] $3"
    [ -n "$4" ] && printf '%s\n' "$4" | wrap "    " "    "
    if [ -n "${7:-}" ]; then
      echo "    Which files: listed in your private file list (see the end of this report)."
      [ "$7" = "__LISTED__" ] || { echo "== $3"; printf '%s\n' "$7"; echo; } >> "$FAILED" 2>/dev/null
    fi
    if [ -n "$5" ]; then echo "    How to fix:";               printf '%s\n' "$5" | wrap "      • " "        "; fi
    if [ -n "$6" ]; then echo "    How to avoid it next time:"; printf '%s\n' "$6" | wrap "      • " "        "; fi
  )"
  if [ "$1" = PROBLEM ]; then ISSUES_TXT="$ISSUES_TXT$block

"; NP=$(( NP + 1 ))
  else NOTES_TXT="$NOTES_TXT$block

"; NN=$(( NN + 1 )); fi
}
# Drive details from diskutil, read once per drive (load_dinfo) and looked up from memory
DI_SRC=""; DI_DST=""
load_dinfo() { DI_SRC="$(diskutil info "$SRC_VOL" 2>/dev/null)"; DI_DST="$(diskutil info "$DST_VOL" 2>/dev/null)"; }
dinfo() {
  local t=""; [ "$1" = "$SRC_VOL" ] && t="$DI_SRC"; [ "$1" = "$DST_VOL" ] && t="$DI_DST"
  printf '%s\n' "$t" | awk -F': *' -v k="$2" '$1 ~ k {print $2; exit}'
}
give_logs_back() {
  logs_here || return 0
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
dst_used_k() {   # space used on the destination drive, from a single df (empty if it isn't mounted there)
  df -kP "$DST_VOL" 2>/dev/null | awk -v v="$DST_VOL" '{ m = $0; u = $3 } END { sub(/.*%[[:space:]]+/, "", m); if (m == v || v == "/") print u }'
}

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
    | grep -E '^(rsync( error)?:|file has vanished|WARNING: .*failed verification|ERROR: .*failed verification|could not make way for|cannot delete non-empty directory)' | csort -u
}
# -> SIDE <tab> CATEGORY <tab> PATH
classify() {
  awk -v src="$SRC/" -v dst="$DST/" '
  { l=$0; m=l; gsub(/"[^"]*"/, "", m)          # m = message without file names
    if (m ~ /^rsync error:/) {
      if (m ~ /protocol data stream|error in IPC|unexpectedly closed|socket IO/) cat="crashed"; else next }
    else if (m ~ /^could not make way for|^cannot delete non-empty directory/) cat="inway"
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
    if (cat=="inway") side="DESTINATION"
    path=""; if (match(l, /"[^"]+"/)) path=substr(l, RSTART+1, RLENGTH-2)
    else if (cat=="inway") { path=l; sub(/^[^:]*: /, "", path); path=dst path }
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
    namelong) echo "names too long";; inway) echo "items in the way on the destination";; xattr) echo "extended attributes";; acl) echo "access lists";; owner) echo "file owners";; *) echo "other errors";;
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
    *:inway)
      add_issue PROBLEM DESTINATION "$files couldn't be copied because something with the same name is in the way on the destination" \
"On the destination, a folder has the same name as a file on the source (or the other way round). smartcopy never deletes anything, so it can't replace it." \
"Move or rename those items on the destination (they're listed in your private file list), then run the same command again." \
"Copy into an empty folder, or one that only holds an earlier copy of the same source." "$ex" ;;
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
  local final cats_final cats_all extra groups side cat n ex
  final="$RUNDIR/classified"; groups="$RUNDIR/groups"
  error_lines "$FINALERR" "$VERIFYLOG" | classify | csort -u > "$final" 2>/dev/null || : > "$final" 2>/dev/null
  if [ -s "$final" ]; then
    { echo "Files affected by problems (side, problem, file):"; echo
      awk -F'\t' '{printf "%-12s %-14s %s\n", $1, $2, $3}' "$final"; echo; } >> "$FAILED"
  fi
  # Group by side+category, most serious first (memory: one counter per kind of problem)
  awk -F'\t' 'BEGIN{ split("nospace readonly io disconnected crashed permission notpermitted toolarge badname namelong inway verifyfail missing other owner acl xattr vanished",o," "); for(i in o) p[o[i]]=i }
    { k=$1 FS $2; n[k]++; if ($3!="") ex[k]=1 }
    END { for (k in n) { split(k,a,FS); print (p[a[2]]?p[a[2]]:50) FS k FS n[k] FS (ex[k]?1:0) } }' "$final" 2>/dev/null \
  | sort -n > "$groups" 2>/dev/null
  while IFS="$TAB" read -r _ side cat n ex; do
    explain "$side" "$cat" "$n" "$([ "$ex" = 1 ] && echo "__LISTED__")"
  done < "$groups"
  if [ "${FDA_MISSING:-0}" -eq 1 ]; then
    if grep -qE "$TAB(permission|notpermitted)$TAB" "$final" 2>/dev/null; then
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
    cats_final=$(cut -f2 "$final" 2>/dev/null | sort -u)
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
  rm -f "$final" "$groups"
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
  local pid="$1" msg="$2" t0=$SECONDS el
  while kill -0 "$pid" 2>/dev/null; do
    el=$(( SECONDS - t0 ))
    if [ "$el" -ge 2 ]; then
      if [ "$el" -lt 60 ]; then printf '\r  %s — under a minute so far   ' "$msg"
      else printf '\r  %s — %s so far   ' "$msg" "$(fmt_left "$el")"; fi
    fi
    sleep 1
  done
  printf '\r\033[K'
}

# Copy figures for the report, worked out once from the log
STATS_DONE=0; CS_FILES=0; CS_BYTES=0; CS_TWICE=0
load_stats() {
  [ "$STATS_DONE" -eq 1 ] && return 0
  STATS_DONE=1
  if logs_here && [ -s "$LOG" ]; then words "$(copy_stats "$LOG")" CS_FILES CS_BYTES CS_TWICE
  else CS_FILES=$COPIED_FILES; CS_BYTES=$COPIED_BYTES; CS_TWICE=0; fi
}
copy_bytes_per_sec()  {   # measured over the main copying stage only
  local b secs="$COPY_SECS"; b=$CS_BYTES
  [ "${BATCH_SECS:-0}" -gt 0 ] && { secs=$BATCH_SECS; b=$BATCH_BYTES; }
  [ "$secs" -gt 0 ] && echo $(( ${b:-0} / secs ))
}
fmt_dur()             { echo "$(( $1 / 3600 ))h $(( $1 % 3600 / 60 ))m"; }

# Explain a slow copy: what was measured, and which of the likely causes apply here
speed_note() {
  local b bps n avg causes="" fix="" ssd
  b=$CS_BYTES; [ "${b:-0}" -gt 5000000000 ] 2>/dev/null || return 0      # only for copies over 5 GB
  bps=$(copy_bytes_per_sec); [ "${bps:-0}" -gt 0 ] || return 0
  [ "$bps" -lt 100000000 ] || return 0                                          # 100 MB/s or more is fine
  n=$CS_FILES; avg=$(( b / (n > 0 ? n : 1) ))
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
  local copied speed="" txt saved=1
  logs_here || saved=0
  [ "$saved" -eq 1 ] && analyse_errors
  load_stats
  speed_note
  if [ "${CS_TWICE:-0}" -gt 0 ]; then
    add_issue NOTE DESTINATION "$CS_TWICE file(s) were copied twice — once in the main copy, then again in the final pass" \
"After the main copy, the final pass found these files' dates or sizes on the destination didn't match the source, so it copied them again. The result is correct; it only cost time. On exFAT drives macOS sometimes changes a file's date just after it's written, which causes this." "" \
"If it happens on every run, reformatting the destination as APFS avoids it (erasing deletes everything on it)."
  fi
  local bps; bps=$(copy_bytes_per_sec)
  [ "${bps:-0}" -gt 0 ] 2>/dev/null && [ "${CS_BYTES:-0}" -gt 50000000 ] && speed="    Speed: $(( bps / 1000000 )) MB/s"
  copied=$CS_FILES
  txt="$(
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
    if [ "$NP" -eq 0 ]; then
      echo "No problems found."; echo
    else
      echo "PROBLEMS ($NP)"; echo "------------------------------------------------------------------"; printf '%s' "$ISSUES_TXT"
    fi
    if [ "$NN" -gt 0 ]; then
      echo "NOTES — for your information ($NN)"; echo "------------------------------------------------------------------"; printf '%s' "$NOTES_TXT"
    fi
    if [ "$saved" -eq 1 ] && [ -s "$FAILED" ]; then
      echo "Private file list: $FAILED"
      echo "  (file names are kept out of this report; that list is in the hidden rsync-logs folder"
      echo "   on the destination drive — to read it:  open -e \"$FAILED\")"
    fi
    if [ "$saved" -eq 1 ]; then
      echo "This report: $REPORT"
      echo "Full logs:   $LOGDIR"
    else
      echo "This report couldn't be saved: the destination drive isn't connected (nothing is ever saved anywhere else)."
    fi
  )"
  [ "$saved" -eq 1 ] && { printf '%s\n' "$txt" > "$REPORT" 2>/dev/null || saved=0; }
  echo; printf '%s\n' "$txt"
}

# The fingerprint list on the destination is usable: current format, same checksum type
hash_list_ok() { [ -s "$HASHFILE" ] && [ "$(head -1 "$HASHFILE")" = "#smartcopy-hashes v2 algo=$HALGO" ]; }
# Fold the fingerprints gathered during this run into the list on the destination (once per run)
save_fingerprints() {
  local cj="$JPREFIX.sorted" j=() f man="" pl=""
  logs_here || return 0
  for f in "$JPREFIX".new-*; do [ -s "$f" ] && j+=("$f"); done
  [ ${#j[@]} -gt 0 ] && { journal_fold "$cj" "${j[@]}" || return 1; }
  [ -s "$cj" ] || return 0
  [ -d "$DST" ] || return 1
  hash_list_ok && man="$HASHFILE"
  [ "$PLAN_COMPLETE" -eq 1 ] && [ -s "$PLAN" ] && pl="$PLAN"
  if manifest_write "$HASHFILE.new.$$" "$HALGO" "$cj" "$man" "$pl" 2>/dev/null && mv -f "$HASHFILE.new.$$" "$HASHFILE"; then
    rm -f "$cj"
  else
    rm -f "$HASHFILE.new.$$"; return 1     # the journal stays on the destination; the next run uses it
  fi
}

# Copies that were stopped mid-way: keep the fingerprints of the files they finished. Their output
# is read once here; the last line is dropped, as it may have been cut off mid-write.
harvest_unfinished() {
  local f
  logs_here || return 0
  for f in "$RUNDIR"/c.*.log "$PASSLOG"; do
    [ -s "$f" ] || continue
    sed '$d' "$f" > "$f.done" 2>/dev/null && harvest_copy "$f.done" "$JOURNAL" >/dev/null
    cat "$f.done" 2>/dev/null >> "$LOG"; rm -f "$f" "$f.done"
  done
}

cleanup() {
  trap '' INT TERM HUP          # finish tidying up even if Ctrl-C is pressed again
  if [ "$SPOT_WAS_ON" -eq 1 ]; then
    local l other=0
    for l in "$LOGDIR"/locks/*.lock; do     # another copy still writing to this drive? leave it off for now;
      [ -d "$l" ] && [ "$l" != "$LOCK" ] || continue   # that copy turns it back on when it finishes
      [ "$(cat "$l/vol" 2>/dev/null)" = "$DST_VOL" ] && [ -n "$(lock_pid "$l")" ] && other=1
    done
    [ "$other" -eq 0 ] && mdutil -i on "$DST_VOL" >/dev/null 2>&1 && rm -f "$SPOT_NOTE"
  fi
  [ "$STARTED" -eq 1 ] && kill_tree $$       # listing, copiers, checkers: stop them before tidying up
  if [ "$STARTED" -eq 1 ] && [ "$DRYRUN" -eq 0 ]; then
    harvest_unfinished
    save_fingerprints || echo "  (Couldn't update the fingerprint list now; the next run will.)"
  fi
  [ "$OWN_LOCK" -eq 1 ] && rm -rf "$LOCK" 2>/dev/null
  if [ "$REPORT_ON" -eq 1 ]; then
    render_report
    if [ "$DRYRUN" -eq 0 ]; then
      notify "$(printf '%s' "$RESULT" | sed 's/^[^A-Za-z]* //')"
      # In background mode, open the report so it's waiting for you
      [ -n "${SMARTCOPY_CHILD:-}" ] && [ -n "${SUDO_USER:-}" ] && logs_here && \
        launchctl asuser "$(id -u "$SUDO_USER")" sudo -u "$SUDO_USER" open -e "$REPORT" >/dev/null 2>&1
    fi
  fi
  if [ "$LOGS_READY" -eq 1 ] && logs_here; then
    rm -rf "$RUNDIR"
    give_logs_back
  fi
}
trap cleanup EXIT
on_signal() {
  echo
  if [ "$STARTED" -eq 0 ]; then REPORT_ON=0; echo "Cancelled before the copy started. Nothing was copied."; kill_tree $$; exit 20; fi
  RESULT="⏸ Stopped before finishing — run the same command again; it continues where it stopped."
  kill_tree $$      # worker copies and list scans
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
LOGDIR="$(logbase_for "$DST")"; set_log_names; init_logs
running=$(lock_pid "$LOCK") && fatal "A copy to $DST is already running (PID $running)." "" "Stop it first: sudo $0 --stop \"$DST\""
[ -d "$SRC" ] || fatal "The source folder doesn't exist: $SRC" \
  "The drive is connected, but this folder isn't on it." \
  "Check the spelling and capital letters. Tip: type the command, then drag the folder from Finder into Terminal to paste its exact path." "" SOURCE
load_dinfo
DKEY="$(dest_key "$DST")"
HASHFILE="$DST/.smartcopy-hashes"
JPREFIX="$LOGDIR/.hashes-$DKEY"; JOURNAL="$JPREFIX.new-$STAMP-$$"   # new fingerprints, kept until merged

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
VSTATE="$LOGDIR/.verified-$(printf '%s|%s' "$SRC_ID" "$DST" | shasum | cut -c1-12)"
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
      if printf '%s\n' "$DI_DST" | grep -qE 'Owners: +Disabled'; then
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

# rsync normally lists folders as it goes (memory stays small). With hard links (-H) that mode can
# hang or fail when an item can't be replaced (seen with rsync 3.2.7), so then it lists everything
# first, as earlier versions always did.
NOINC=(); case "${META[0]}" in -a*H*) NOINC=(--no-inc-recursive) ;; esac

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

# Space check on the first run. A whole drive uses its usage figure (instant); a folder is measured
# exactly in step 1 — while listing the files — instead of reading the whole folder twice.
if [ "$first_run" -eq 1 ] && [ "$SRC_VOL" = "$SRC" ]; then
  src_k=$(df -kP "$SRC" | tail -1 | awk '{print $3}')
  free_k=$(df -kP "$DST_VOL" | tail -1 | awk '{print $4}')
  if [ "${src_k:-0}" -gt "${free_k:-0}" ] 2>/dev/null; then
    add_issue PROBLEM DESTINATION "The source ($(hk "$src_k")) may not fit in the free space on the destination ($(hk "$free_k"))" \
"Unless much of it is already there from an earlier copy, the destination will fill up before the copy finishes." \
"Free up space on $DST_VOL, use a bigger drive, or copy a smaller folder." \
"Check sizes before starting; --dry-run shows how much would be copied."
    echo "WARNING: the source ($(hk "$src_k")) may not fit in the destination's free space ($(hk "$free_k"))."
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
  trap 'rm -rf "$T"; logs_here && rm -rf "$RUNDIR"' EXIT
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

# rsync prints one line per item: "%i %l %M %C %n" (change summary, size, date, fingerprint, name).
# Names in rsync's printed output are escaped, so they're safe to parse; its --log-file isn't.
FMT='%i %l %M %C %n'
COMMON=(
  ${NOINC[@]+"${NOINC[@]}"}
  --info=none
  "--out-format=$FMT"           # each file's size, date and fingerprint, for speed figures and the hash list
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
  "$RSYNC" "${META[@]}" ${NOINC[@]+"${NOINC[@]}"} --dry-run --mkpath --out-format='%i %l' \
    "${EXCLUDES[@]}" "$SRC/" "$DST/" 2> "$FINALERR" \
    | awk '$1 ~ /^>f/ { n++; s += $2 } $1 ~ /^cd/ { d++ } END { printf "%d %.0f %d\n", n, s, d }' > "$RUNDIR/dryrun"
  st=("${PIPESTATUS[@]}"); rc=${st[0]}; [ "$rc" -eq 0 ] && [ "${st[1]}" -ne 0 ] && rc=1
  words "$(cat "$RUNDIR/dryrun" 2>/dev/null)" dn ds dd
  echo "  Would copy ${dn:-0} files ($(hk $(( ${ds:-0} / 1024 )))) and create ${dd:-0} folders."
  [ -s "$FINALERR" ] && echo "  Some files couldn't be read — see the report below."
  RESULT="Dry run only — nothing was copied."
  exit "$rc"
fi

# ---------------- Create the destination folder (only now that its drive is confirmed present) ----------------
wait_for_mounts
if [ "$DST" = "$DST_VOL" ]; then :
elif [ "${DST#"$DST_VOL"/}" != "$DST" ]; then           # create it from inside the drive, never on the Mac's drive
  ( cd "$DST_VOL" 2>/dev/null && on_dst_volume && mkdir -p "./${DST#"$DST_VOL"/}" ) 2>/dev/null
else mkdir -p "$DST" 2>/dev/null; fi
[ -d "$DST" ] || fatal "Couldn't create the destination folder $DST" \
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
TIDIED=0; [ -f "$DST/$MARK" ] && grep -q '^partial_tidied=yes' "$DST/$MARK" && TIDIED=1
printf 'source_id=%s\nsource_name=%s\nstarted=%s\n' "$SRC_ID" "$SRC" "$(ts)" > "$DST/$MARK"
[ "$TIDIED" -eq 1 ] && echo "partial_tidied=yes" >> "$DST/$MARK"
mark_finished() { echo "finished=yes" >> "$DST/$MARK" 2>/dev/null; }

# ---------------- --background: re-launch detached so closing Terminal doesn't stop it ----------------
if [ "$DETACH" -eq 1 ] && [ -z "${SMARTCOPY_CHILD:-}" ]; then
  CONSOLE="$LOGDIR/console-$STAMP.log"
  args=(--yes); [ "$VERIFY" = "0" ] && args+=(--no-verify); [ "$FORCE" -eq 1 ] && args+=(--force)
  [ "$VERIFY_ONLY" -eq 1 ] && args+=(--verify-only)
  args+=(--jobs "$JOBS_ARG" --engine "$ENGINE")
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
rm -f "$DST"/.smartcopy-hashes.new.* 2>/dev/null    # left by a run that was cut off while saving fingerprints

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

# Versions before the exFAT write-in-place mode left .rsync-partial folders behind; tidy them once
if [ "$PREV_UNFINISHED" -eq 1 ] && [ "${WRITE_MODE[0]}" = --inplace ] && [ "$VERIFY_ONLY" -eq 0 ] && [ "$TIDIED" -eq 0 ]; then
  echo "Tidying up temporary files left by the interrupted run..."
  find "$DST" -type d -name .rsync-partial -prune -exec rm -rf {} + 2>/dev/null
  echo "partial_tidied=yes" >> "$DST/$MARK"
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
PASS_MOVED_TOTAL=0
copy_loop() {
  local label="$1"; shift
  local extra=("$@")
  local pass=0 stuck=0 prev_sig="" same=0 sig rc moved used_before used_after wait_s r
  LOOPS=$(( LOOPS + 1 ))

  while :; do
    pass=$(( pass + 1 )); TOTAL_PASSES=$(( TOTAL_PASSES + 1 ))
    wait_for_mounts
    [ -d "$SRC" ] || fatal "The source folder is gone: $SRC" \
      "It was moved, renamed or deleted while the copy was running." \
      "Put it back (or fix the path), then run the same command again." "" SOURCE
    used_before=$(dst_used_k)
    echo "=== $label — pass $pass — $(ts) ===" 2>/dev/null >> "$LOG"
    [ "$pass" -gt 1 ] && echo "  Trying again (attempt $pass)..."
    # Copy whole files (fastest). Only when a previous attempt was cut off, and the destination keeps
    # half-copied files aside (APFS/HFS), compare against them so big files resume instead of restarting.
    delta=--whole-file
    if [ "${WRITE_MODE[0]}" != --inplace ] && { [ "$PREV_UNFINISHED" -eq 1 ] || [ "$pass" -gt 1 ]; }; then
      delta=--no-whole-file
    fi
    t0=$SECONDS
    in_dst "$RSYNC" "${META[@]}" "${COMMON[@]}" "${CSUM[@]}" "${WRITE_MODE[@]}" "$delta" ${extra[@]+"${extra[@]}"} "${EXCLUDES[@]}" \
      "$SRC/" ./ > "$PASSLOG" 2> "$PASSERR" &
    local rpid=$!
    heartbeat "$rpid" "$label: going through all files on both drives"
    wait "$rpid"; rc=$?
    COPY_SECS=$(( COPY_SECS + SECONDS - t0 ))
    if [ "$rc" -eq 98 ] || ! drives_here; then  # a drive went away (even before rsync could start): wait, try again
      TOTAL_PASSES=$(( TOTAL_PASSES - 1 )); pass=$(( pass - 1 )); continue
    fi
    r=$(harvest_copy "$PASSLOG" "$JOURNAL"); [ -n "$r" ] || r="0 0"   # fingerprints of what this pass copied
    COPIED_FILES=$(( COPIED_FILES + ${r#* } )); COPIED_BYTES=$(( COPIED_BYTES + ${r% *} ))
    cat "$PASSLOG" 2>/dev/null >> "$LOG"
    cat "$PASSERR" 2>/dev/null >> "$ALLERR"; cp "$PASSERR" "$FINALERR" 2>/dev/null
    used_after=$(dst_used_k)
    moved=$(grep -cE '^(>f|cd|cL|hf)' "$PASSLOG" 2>/dev/null); moved=${moved:-0}
    : > "$PASSLOG" 2>/dev/null                # read once; nothing left for harvest_unfinished
    PASS_MOVED_TOTAL=$(( PASS_MOVED_TOTAL + moved ))

    case $rc in
      0)  echo "$label: pass finished cleanly." 2>/dev/null >> "$LOG"; return 0 ;;
      24) echo "$label: finished (some source files changed during the copy)." 2>/dev/null >> "$LOG"; return 0 ;;
      20) RESULT="⏸ Stopped before finishing — run the same command again to resume."; exit 20 ;;
      1|2|4) fatal "rsync couldn't start (error code $rc)." \
               "This is a setup problem that retrying won't fix — usually an option this rsync doesn't support." \
               "Update rsync: brew upgrade rsync, then run the same command again.
The exact message is at the end of $LOG" ;;
    esac
    echo "$label: some files had problems (rsync code $rc)." 2>/dev/null >> "$LOG"
    echo "  Some files had problems — they'll be explained in the report at the end."

    # Problems that retrying cannot fix: stop now; the report explains them
    if grep -qE 'No space left on device|Read-only file system' "$PASSERR" 2>/dev/null; then
      RESULT="❌ Stopped — the destination can't take any more data. See below."
      exit 1
    fi

    # Progress = files completed, or the destination grew (a huge file cut off part-way)
    if [ "$moved" -gt 0 ] || { [ -n "$used_after" ] && [ "$used_after" != "$used_before" ]; }; then
      stuck=0
    else
      stuck=$(( stuck + 1 ))
    fi

    # Same files failing the same way, with nothing else left to copy = permanent problems
    sig=$(errors_in "$PASSERR" 2>/dev/null | shasum | cut -c1-40)
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
fmt_left_v() {   # fmt_left_v VAR SECONDS (no subprocess)
  local x="$2"
  if [ "$x" -lt 60 ]; then printf -v "$1" '%s' "<1 min"
  elif [ "$x" -lt 3570 ]; then printf -v "$1" '%d min' $(( (x + 30) / 60 ))
  else x=$(( x + 30 )); printf -v "$1" '%dh %dm' $(( x / 3600 )) $(( x % 3600 / 60 )); fi
}
EPOCH0=$(( $(date +%s) - SECONDS ))    # wall clock = EPOCH0 + SECONDS, without calling date
CLOCK_KEY=""; CLOCK_TXT=""
clock_at_v() {   # clock_at_v VAR SECONDS: clock time N seconds from now; adds the weekday when it isn't today
  local e fmt="+%H:%M" key
  e=$(( EPOCH0 + SECONDS + $2 )); key=$(( e / 60 ))
  if [ "$key" != "$CLOCK_KEY" ]; then           # only ask date when the shown minute changes
    if [ "$(uname)" = Darwin ]; then
      [ "$(date +%j)" != "$(date -r "$e" +%j)" ] && fmt="+%a %H:%M"; CLOCK_TXT=$(date -r "$e" "$fmt")
    else
      [ "$(date +%j)" != "$(date -d "@$e" +%j)" ] && fmt="+%a %H:%M"; CLOCK_TXT=$(date -d "@$e" "$fmt")
    fi
    CLOCK_KEY=$key
  fi
  printf -v "$1" '%s' "$CLOCK_TXT"
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
# Smooth the finish time: move 1/6 of the way towards the new estimate each update (~30 s settle),
# except right after the first estimate, and never show a time already in the past.
est_finish() {  # est_finish SECONDS_LEFT -> smoothed seconds left in EST_LEFT
  local now tgt; now=$(( EPOCH0 + SECONDS )); tgt=$(( now + $1 ))
  if [ "$EST_FIN" -eq 0 ]; then EST_FIN=$tgt; else EST_FIN=$(( EST_FIN + (tgt - EST_FIN) / 6 )); fi
  [ "$EST_FIN" -lt "$now" ] && EST_FIN=$now
  EST_LEFT=$(( EST_FIN - now ))
}

# One clearly labelled status line, refreshed every second (no subprocesses except a rare date/tput)
COLS=0; COLS_AT=-100
progress_line() {   # progress_line LABEL DONE_BYTES TOTAL_BYTES DONE_FILES TOTAL_FILES
  local label="$1" db="$2" tb="$3" df="$4" tf="$5" pct el bps left="estimating…" when="" secs vsecs f1 f2 h1 h2 listing="${LISTING:-0}"
  el=$(( SECONDS - PHASE_T0 )); [ "$el" -gt 0 ] || el=1
  bps=$(( (db - ${PHASE_B0:-0}) / el )); [ "$bps" -ge 0 ] || bps=0
  pct=100; [ "$tb" -gt 0 ] && pct=$(( db * 100 / tb ))
  if [ "$listing" -eq 1 ]; then
    left="once the listing is done"
  elif [ "${TUNING:-0}" -eq 1 ]; then
    left="measuring speed (first ~5 min)"
  elif [ "$EST_RATE" -gt 0 ]; then
    secs=$(( EST_RATE > 0 ? ( (tb > db ? tb - db : 0) + (tf > df ? tf - df : 0) * PER_FILE ) / EST_RATE : 0 ))
    if [ "$label" = "Copying" ] && [ "$VERIFY" != "0" ]; then
      vsecs=$(( (ALL_BYTES * 10 + ALL_FILES * PER_FILE * 3) / (EST_RATE * 10) ))   # rough: checking reads, it doesn't create files
      est_finish $(( secs + vsecs )); secs=$EST_LEFT
      fmt_left_v f1 "$secs"; fmt_left_v f2 "$vsecs"; left="$f1 (incl. ~$f2 checking)"
    else
      est_finish "$secs"; secs=$EST_LEFT; fmt_left_v left "$secs"
    fi
    clock_at_v when "$secs"
  fi
  # Build the line from the most important parts outward, dropping the least important ones
  # when the window is narrow — the time left and the finish time are never cut off.
  local line head tail fl=$(( tf > df ? tf - df : 0 )) part
  local -a extras
  head="$label $pct%"
  tail=" · TIME LEFT: $left${when:+ · FINISHES ≈ $when}"
  hk_v h1 $(( db / 1024 )); hk_v h2 $(( tb / 1024 ))
  extras=( " · $h1 of $h2" " · $fl files left" " · $(( bps / 1000000 )) MB/s" )
  if [ "$listing" -eq 1 ]; then               # totals still growing: say so, and show no percentage or time left
    head="$label"; tail=" · STILL LISTING"
    extras=( " · $h1 of $h2 found so far" " · $tf files found" " · $(( bps / 1000000 )) MB/s" )
  fi
  [ "${STREAM_CHECKED:-0}" -gt 0 ] && extras+=( " · $STREAM_CHECKED checked" )
  if [ $(( SECONDS - COLS_AT )) -ge 15 ]; then COLS=$(tput cols 2>/dev/null); COLS_AT=$SECONDS; fi
  local cols="$COLS"; [ "${cols:-0}" -ge 40 ] 2>/dev/null || cols=200
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

# Scan both drives once: every file in the source (for checking), which still need copying, and the
# folders and links (for the final pass). Lists are written to the destination drive and sorted.
plan_scan() {
  local raw="$RUNDIR/plan.raw" err="$RUNDIR/scan.err" tries=0 rc pid
  PLAN="$RUNDIR/plan"; PLAN_OTHER="$RUNDIR/plan.other"; PLAN_SUM="$RUNDIR/plan.sum"
  while :; do
    wait_for_mounts
    ( "$RSYNC" "${META[@]}" ${NOINC[@]+"${NOINC[@]}"} --dry-run -ii --out-format='%i %l %M %n' "${EXCLUDES[@]}" "$SRC/" "$DST/" 2> "$err" \
        | scan_parse "$raw" "$PLAN_OTHER" "$PLAN_SUM"
      st=("${PIPESTATUS[@]}")
      [ "${st[1]}" -eq 0 ] || exit 199          # couldn't write the list on the destination
      exit "${st[0]}" ) &
    pid=$!
    heartbeat "$pid" "Listing every file on both drives"
    wait "$pid"; rc=$?   # wait for the scan only (a bare "wait" would also wait for caffeinate, forever)
    cat "$err" 2>/dev/null >> "$ALLERR"
    case $rc in
      0|24) PLAN_COMPLETE=1; break ;;
      23)   PLAN_COMPLETE=0; break ;;            # some items couldn't be read; the copy reports them
    esac
    drives_here || { tries=$(( tries - 1 )); rc=0; }   # a drive went away: wait for it, don't count the try
    case $rc in
      20)   RESULT="⏸ Stopped before finishing — run the same command again to resume."; exit 20 ;;
      1|2|4) fatal "rsync couldn't start (error code $rc)." \
               "This is a setup problem that retrying won't fix — usually an option this rsync doesn't support." \
               "Update rsync: brew upgrade rsync, then run the same command again." ;;
    esac
    tries=$(( tries + 1 ))
    if [ "$tries" -ge 4 ] && is_mounted "$SRC_VOL" && is_mounted "$DST_VOL"; then
      fatal "Couldn't list the files on the drives (error code $rc)." \
        "Listing the files was cut off several times in a row." \
        "Check both drives in Disk Utility > First Aid, then run the same command again."
    fi
    echo "  Listing the files was cut off — trying again..."
    sleep 15
  done
  csort -k1,1 "$raw" > "$PLAN" || { wait_for_mounts; csort -k1,1 "$raw" > "$PLAN"; } || \
    fatal "Couldn't write the file list on the destination drive." "The drive may be full or was disconnected." \
      "Free some space or reconnect the drive, then run the same command again." "" DESTINATION
  rm -f "$raw"
  words "$(cat "$PLAN_SUM" 2>/dev/null)" ALL_FILES ALL_BYTES TODO_FILES TODO_BYTES N_OTHER N_HLINKS
  done_msg "Found $ALL_FILES files ($(hk $(( ALL_BYTES / 1024 )))) on the source."
}

# Checks that need the file list: does it fit, and (FAT32) files of 4 GB or more
post_scan_checks() {
  local free_k big
  if [ "$first_run" -eq 1 ] && [ "$SRC_VOL" != "$SRC" ] && [ "$VERIFY_ONLY" -eq 0 ]; then
    free_k=$(df -kP "$DST_VOL" | tail -1 | awk '{print $4}')
    if [ $(( TODO_BYTES / 1024 )) -gt "${free_k:-0}" ] 2>/dev/null; then
      add_issue PROBLEM DESTINATION "The files to copy ($(hk $(( TODO_BYTES / 1024 )))) may not fit in the free space on the destination ($(hk "$free_k"))" \
"The destination will fill up before the copy finishes." \
"Free up space on $DST_VOL, use a bigger drive, or copy a smaller folder." \
"Check sizes before starting; --dry-run shows how much would be copied."
      echo "WARNING: the files to copy ($(hk $(( TODO_BYTES / 1024 )))) may not fit in the destination's free space ($(hk "$free_k"))."
    fi
  fi
  # FAT32 can't hold files of 4 GB or more — find them before wasting hours
  if [ "$DST_FS" = "msdos" ] && [ "$VERIFY_ONLY" -eq 0 ]; then
    big=$(LC_ALL=C awk -F'\t' '$4 == "T" && $2 > 4294967295 { n++; print $1 > f } END { print n+0 }' f="$RUNDIR/big" "$PLAN")
    if [ "${big:-0}" -gt 0 ]; then
      add_issue PROBLEM DESTINATION "$big file(s) are 4 GB or bigger and can't go on a FAT32 drive" \
"The destination is FAT32 (MS-DOS), which can't store files of 4 GB or more. These will fail; everything else will copy." \
"Reformat the destination as APFS (Mac only) or exFAT (Mac + Windows) in Disk Utility > Erase (this deletes everything on it), then run the same command again." \
"Don't use FAT32 drives for backups." "__LISTED__"
      { echo "== $big file(s) are 4 GB or bigger and can't go on a FAT32 drive"; cat "$RUNDIR/big"; echo; } >> "$FAILED"
    fi
  fi
}

# Keep K rsyncs busy, one batch each. With AUTO_TUNE on big jobs it measures 1-at-a-time against
# 4-at-a-time for ~2 minutes each, then carries on with whichever was faster. Each batch's output is
# read once, when it finishes; the progress line only reads the batches still running.
run_batches() {    # run_batches copy|verify|hash PREFIX TOTAL_BYTES TOTAL_FILES
  local mode="$1" pre="$2" tb="$3" tf="$4" k="$JOBS" next=1 slot pid rc b f running done_b done_f r
  local tkv cal=0 stage=0 el work t1 w1 m1 t2 w2 m2 t3 w3 m3 ra rb label="Copying" done_b_tune=0 fin_b=0 fin_f=0 nd
  local -a PIDS BATCH live
  [ "$mode" = verify ] && label="Checking"
  [ "$mode" = hash ] && label="Checking"
  tb="${tb%%.*}"
  if [ "$AUTO_TUNE" -eq 1 ] && [ "$tb" -ge 21474836480 ] && [ "$tf" -ge 2000 ] && [ "$NB" -ge 6 ]; then
    tkv="TUNED_$mode"
    if [ -n "${!tkv:-}" ]; then k=${!tkv}; else cal=1; k=1; fi
  fi
  RETRY_BATCHES=""; HAD23=0; BATCH_FAILED=0
  PHASE_T0=$SECONDS; PHASE_B0=0; LAST_NL=$SECONDS; est_reset
  while :; do
    running=0; live=()
    for slot in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
      pid="${PIDS[slot]:-}"; [ -n "$pid" ] || continue
      printf -v f '%s.%04d' "$pre" "${BATCH[slot]}"
      if kill -0 "$pid" 2>/dev/null; then
        running=$(( running + 1 ))
        if [ "$mode" = copy ]; then live+=("$f.log"); else live+=("$f.out"); fi
        continue
      fi
      wait "$pid"; rc=$?; b="${BATCH[slot]}"; PIDS[slot]=""
      case $rc in 0|24) ;; 23) HAD23=1; BATCH_FAILED=1 ;; *) RETRY_BATCHES="$RETRY_BATCHES $b"; BATCH_FAILED=1 ;; esac
      if [ "$mode" = copy ]; then
        r=$(harvest_copy "$f.log" "$JOURNAL"); [ -n "$r" ] || r="0 0"   # fingerprints of the copied files
        COPIED_FILES=$(( COPIED_FILES + ${r#* } )); COPIED_BYTES=$(( COPIED_BYTES + ${r% *} ))
        cat "$f.log" 2>/dev/null >> "$LOG"; cat "$f.err" 2>/dev/null >> "$ALLERR"
      elif [ "$mode" = verify ]; then
        r=$(finish_check "$f.out" "$JOURNAL" "$VERIFYLOG"); cat "$f.err" 2>/dev/null >> "$VERIFYLOG"
      else
        r=$(finish_hash "$f.rec" "$f.out" "$VERIFYLOG"); cat "$f.err" 2>/dev/null >> "$VERIFYLOG"
      fi
      [ "$mode" = copy ] || [ -n "$r" ] || r="0 0 1"
      if [ "$mode" != copy ]; then
        # A checked batch with no differences is remembered, so an interrupted check can resume
        nd=${r##* }; r=${r% *}
        { [ "$rc" -eq 0 ] || [ "$rc" -eq 24 ]; } && [ "$nd" -eq 0 ] && cut -f1-3 "$f.rec" 2>/dev/null >> "$VSTATE"
      fi
      fin_b=$(( fin_b + ${r% *} )); fin_f=$(( fin_f + ${r#* } ))
      rm -f "$f.log" "$f.err" "$f.out"
      case $rc in 0|23|24) rm -f "$f" "$f.rec" ;; esac          # failed batches keep their lists for the retry
    done
    done_b=$fin_b; done_f=$fin_f
    if [ "$running" -gt 0 ]; then
      if [ "$mode" = copy ]; then r=$(progress_count copy "${live[@]}"); else r=$(progress_count check "${live[@]}"); fi
      [ -n "$r" ] || r="0 0"
      done_b=$(( done_b + ${r% *} )); done_f=$(( done_f + ${r#* } ))
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
      b=$next; printf -v f '%s.%04d' "$pre" "$b"
      if [ "$mode" = copy ]; then
        in_dst "$RSYNC" "${META[@]}" -r "--out-format=$FMT" "${CSUM[@]}" "${WRITE_MODE[@]}" "$COPY_DELTA" \
          "${EXCLUDES[@]}" --from0 --files-from="$f" "$SRC/" ./ > "$f.log" 2> "$f.err" &
      elif [ "$mode" = verify ]; then
        in_dst "$RSYNC" "${META[@]}" -r --checksum "${CSUM[@]}" --dry-run -ii "--out-format=$FMT" \
          "${EXCLUDES[@]}" --from0 --files-from="$f" "$SRC/" ./ > "$f.out" 2> "$f.err" &
      elif [ "$mode" = hash ]; then
        # Destination only: list its files into an empty folder; nothing is written, only hashes are read
        in_dst "$RSYNC" -r -8 --checksum "${CSUM[@]}" --dry-run -i "--out-format=$FMT" \
          --from0 --files-from="$f" ./ "$EMPTY_DIR/" > "$f.out" 2> "$f.err" &
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
  local pre="$RUNDIR/c" t0
  [ "$TODO_FILES" -gt 0 ] || return 0
  COPY_DELTA=--whole-file
  [ "${WRITE_MODE[0]}" != --inplace ] && [ "$PREV_UNFINISHED" -eq 1 ] && COPY_DELTA=--no-whole-file
  until make_batches "$PLAN" "$pre" copy "$TODO_BYTES"; do
    drives_here && fatal "Couldn't write the file list on the destination drive." \
      "The drive may be full." "Free some space on the destination, then run the same command again." "" DESTINATION
    wait_for_mounts
  done
  local b0=$COPIED_BYTES
  t0=$SECONDS
  run_batches copy "$pre" "$TODO_BYTES" "$TODO_FILES"
  COPY_SECS=$(( COPY_SECS + SECONDS - t0 )); BATCH_SECS=$(( SECONDS - t0 )); [ "$BATCH_SECS" -gt 0 ] || BATCH_SECS=1
  BATCH_BYTES=$(( COPIED_BYTES - b0 ))
  [ "$BATCH_FAILED" -eq 1 ] && PREV_UNFINISHED=1     # half-written files possible: the final pass resumes them
  COPY_BATCH_FAILED=$BATCH_FAILED
  rm -f "$pre".*
}

# ============================ Streaming engine ============================
# One continuous pipeline instead of "list everything, then copy, then check":
#
#   listing (rsync, source only) ─▶ router (awk) ─▶ [batch queue] ─▶ copiers (K rsyncs) ─▶ [check queue] ─▶ checkers
#                                     │ plan, folders/links                │ fingerprints → journal
#
# • The listing reads only the source (against an empty folder, so it streams folder by folder) and
#   is done once. The router writes the plan (for the final check) and cuts batches as files appear;
#   the first batches are small, so the first file is copied within moments.
# • Queues are bounded: the batch queue holds STREAM_QMAX batches in memory, the pipe from the router
#   a few dozen fixed-size announcements; when the copiers are busy, the router and the listing wait
#   (backpressure). The check queue holds STREAM_VQMAX batches; beyond that, batches are left for the
#   final check instead of slowing the copy down.
# • Copiers and checkers are pools of slots: any free slot takes the next batch (dynamic distribution).
#   Each copier reports every file it looked at (-ii), so progress counts files already up to date too.
# • Checkers read back the files a batch just copied (destination only) and compare them with the
#   fingerprints taken while copying; confirmed files go in the checkpoint, so the final check skips
#   them. Everything else (files copied earlier, batches not checked in time) is checked at the end.
# • Folders get their dates and permissions in the final pass, after their contents are written;
#   links and hard links are made there too (hard links by a full pass with -H).
# • If the listing is cut off (a drive unplugged, an error), what was copied is kept and the run
#   carries on with the batch engine: a full listing of both drives, then copying what's left.
# All lists and batches live in the run folder on the destination; the queues themselves are in memory.
STREAM_QMAX=4; STREAM_VQMAX=16; STREAM_CHECKERS=1
DISC_META=("${META[@]}"); DISC_META[0]="${META[0]//[AXN]/}"   # listing: no ACLs/xattrs/creation dates needed
stream_producer() {
  "$RSYNC" "${DISC_META[@]}" --dry-run -ii --out-format='%i %l %M %n' "${EXCLUDES[@]}" "$SRC/" "$STREAM_EMPTY/" 2> "$RUNDIR/scan.err" \
    | stream_route "$RUNDIR/plan.raw" "$PLAN_OTHER" "$RUNDIR/c"
  local st=("${PIPESTATUS[@]}")
  printf 'E %s %s\n' "${st[0]}" "${st[1]}"
}
stream_copy() {
  local pre="$RUNDIR/c" k="$JOBS" slot pid rc b f r kind a1 a2 a3 a4 a5 eof=0 instant=0 before running vrunning nd
  local cb cf xb xf fin_b=0 fin_f=0 done_b done_f copy_done=0 last_prog=-1 t_start=$SECONDS warned=0 free_k sort_pid=""
  local cal=0 stage=0 tune0=0 el work t1 w1 m1 t2 w2 m2 t3 w3 m3 ra rb tb
  local -a PIDS=() BATCH=() VPIDS=() VBATCH=() Q=() VQ=() live=()
  STREAM_OK=0; STREAM_CHECKED=0; DISC_FILES=0; DISC_BYTES=0; DRC=""; DARC=""; COPY_BATCH_FAILED=0
  ALL_FILES=0; ALL_BYTES=0; N_OTHER=0; N_HLINKS=0; NB=0; BSIZE=(); BCOUNT=(); LISTING=1
  PLAN_OTHER="$RUNDIR/plan.other"; : > "$RUNDIR/plan.raw"; : > "$PLAN_OTHER"
  STREAM_EMPTY=$(mktemp -d "$RUNDIR/empty.XXXXXX")
  COPY_DELTA=--whole-file
  [ "${WRITE_MODE[0]}" != --inplace ] && [ "$PREV_UNFINISHED" -eq 1 ] && COPY_DELTA=--no-whole-file
  rm -f "$VSTATE"          # this run copies: an earlier stopped check no longer applies; this run records its own
  free_k=$(df -kP "$DST_VOL" | tail -1 | awk '{print $4}')
  wait_for_mounts
  exec 3< <(stream_producer)
  PHASE_T0=$SECONDS; PHASE_B0=0; LAST_NL=$SECONDS; est_reset
  while :; do
    # --- finished copiers: read each batch's output once; queue its copied files for checking
    running=0; live=()
    for slot in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
      pid="${PIDS[slot]:-}"; [ -n "$pid" ] || continue
      printf -v f '%s.%04d' "$pre" "${BATCH[slot]}"
      if kill -0 "$pid" 2>/dev/null; then running=$(( running + 1 )); live+=("$f.log"); continue; fi
      wait "$pid"; rc=$?; b="${BATCH[slot]}"; PIDS[slot]=""
      case $rc in 0|24) ;; *) COPY_BATCH_FAILED=1 ;; esac
      words "$(harvest_stream "$f.log" "$JOURNAL" "$f.rec" "$LOG")" cb cf xb xf
      COPIED_BYTES=$(( COPIED_BYTES + cb )); COPIED_FILES=$(( COPIED_FILES + cf ))
      fin_b=$(( fin_b + xb )); fin_f=$(( fin_f + xf ))
      cat "$f.err" 2>/dev/null >> "$ALLERR"; rm -f "$f" "$f.log" "$f.err"
      if [ "$VERIFY" != 0 ] && [ -s "$f.rec" ] && [ ${#VQ[@]} -lt "$STREAM_VQMAX" ] && { [ "$rc" -eq 0 ] || [ "$rc" -eq 23 ] || [ "$rc" -eq 24 ]; }; then
        VQ+=("$b")
      else rm -f "$f.rec"; fi                                    # checked in the final check instead
    done
    # --- finished checkers
    vrunning=0
    for slot in 1 2 3 4; do
      pid="${VPIDS[slot]:-}"; [ -n "$pid" ] || continue
      if kill -0 "$pid" 2>/dev/null; then vrunning=$(( vrunning + 1 )); continue; fi
      wait "$pid"; rc=$?; printf -v f '%s.%04d' "$pre" "${VBATCH[slot]}"; VPIDS[slot]=""
      words "$(finish_hash "$f.rec" "$f.vout" "$RUNDIR/stream.diffs")" xb xf nd
      if { [ "$rc" -eq 0 ] || [ "$rc" -eq 24 ]; } && [ "$nd" -eq 0 ]; then
        cut -f1-3 "$f.rec" 2>/dev/null >> "$VSTATE"; STREAM_CHECKED=$(( STREAM_CHECKED + xf ))
      fi                                                         # otherwise the final check repeats it
      rm -f "$f.rec" "$f.v0" "$f.vout" "$f.verr"
    done
    [ "$eof" -eq 1 ] && [ ${#Q[@]} -eq 0 ] && [ "$running" -eq 0 ] && copy_done=1
    [ "$copy_done" -eq 1 ] && [ "$vrunning" -eq 0 ] && break
    # --- start checkers (destination only: read the files back, compare with the fingerprints)
    while [ "$copy_done" -eq 0 ] && [ "$vrunning" -lt "$STREAM_CHECKERS" ] && [ ${#VQ[@]} -gt 0 ]; do
      b="${VQ[0]}"; VQ=(${VQ[@]+"${VQ[@]:1}"}); printf -v f '%s.%04d' "$pre" "$b"
      for slot in 1 2 3 4; do [ -z "${VPIDS[slot]:-}" ] && break; done
      nul_list < "$f.rec" > "$f.v0"
      in_dst "$RSYNC" -r -8 --checksum "${CSUM[@]}" --dry-run -i "--out-format=$FMT" \
        --from0 --files-from="$f.v0" ./ "$STREAM_EMPTY/" > "$f.vout" 2> "$f.verr" &
      VPIDS[slot]=$!; VBATCH[slot]=$b; vrunning=$(( vrunning + 1 ))
    done
    # --- speed tuning, once the job is known to be big: 1 at a time against 4 at a time
    if [ "$AUTO_TUNE" -eq 1 ] && [ "$cal" -eq 0 ] && [ "$stage" -eq 0 ] && [ -z "${TUNED_copy:-}" ] \
       && [ "${DISC_BYTES%%.*}" -ge 21474836480 ] && [ "$DISC_FILES" -ge 2000 ]; then
      cal=1; k=1; tune0=$SECONDS
    fi
    if [ "$cal" -eq 1 ]; then
      el=$(( SECONDS - tune0 )); r=$(dst_used_k); r=$(( ${r:-0} * 1024 )); work=$(( r + fin_f * 262144 ))
      case $stage in
        0) if [ "$el" -ge 20 ];  then t1=$el; w1=$work; m1=$r; stage=1; fi ;;
        1) if [ "$el" -ge 120 ]; then t2=$el; w2=$work; m2=$r; k=4; stage=2; fi ;;
        2) if [ "$el" -ge 140 ]; then t3=$el; w3=$work; m3=$r; stage=3; fi ;;
        3) if [ "$el" -ge 240 ]; then
             ra=$(( (w2 - w1) / (t2 - t1) )); rb=$(( (work - w3) / (el - t3) ))
             if [ "$rb" -gt $(( ra * 12 / 10 )) ]; then k=4; else k=1; fi
             TUNED_copy=$k; printf '\r\033[K'
             echo "  Speed tuning: 1 at a time ran at $(( (m2 - m1) / (t2 - t1) / 1000000 )) MB/s, 4 at a time at $(( (r - m3) / (el - t3) / 1000000 )) MB/s — using $k at a time from now on."
             stage=4; cal=0
           fi ;;
      esac
    fi
    # --- start copiers on queued batches
    while [ "$running" -lt "$k" ] && [ ${#Q[@]} -gt 0 ]; do
      if ! is_mounted "$SRC_VOL" || ! is_mounted "$DST_VOL"; then printf '\n'; wait_for_mounts; fi
      b="${Q[0]}"; Q=(${Q[@]+"${Q[@]:1}"}); printf -v f '%s.%04d' "$pre" "$b"
      for slot in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do [ -z "${PIDS[slot]:-}" ] && break; done
      in_dst "$RSYNC" "${META[@]}" -r -ii "--out-format=$FMT" "${CSUM[@]}" "${WRITE_MODE[@]}" "$COPY_DELTA" \
        "${EXCLUDES[@]}" --from0 --files-from="$f" "$SRC/" ./ > "$f.log" 2> "$f.err" &
      PIDS[slot]=$!; BATCH[slot]=$b; running=$(( running + 1 ))
    done
    # --- take announcements from the router while there's room in the queue (this read is also the
    #     loop's one-second tick; a full queue leaves the router waiting)
    if [ "$eof" -eq 0 ] && [ ${#Q[@]} -lt "$STREAM_QMAX" ]; then
      before=$SECONDS
      if IFS=' ' read -r -t 1 -u 3 kind a1 a2 a3 a4 a5; then
        instant=0
        case "$kind" in
          B) Q+=("$a1"); BCOUNT[a1]=$a2; BSIZE[a1]=$a3; NB=$a1; DISC_FILES=$a4; DISC_BYTES=$a5 ;;
          S) ALL_FILES=$a1; ALL_BYTES=$a2; N_OTHER=$a3; N_HLINKS=$a4; DISC_FILES=$a1; DISC_BYTES=$a2 ;;
          E) eof=1; DRC=$a1; DARC=$a2; LISTING=0
             if { [ "$DRC" = 0 ] || [ "$DRC" = 24 ]; } && [ "$DARC" = 0 ]; then   # sort the plan while copying goes on
               csort -k1,1 "$RUNDIR/plan.raw" > "$RUNDIR/plan" & sort_pid=$!
             fi ;;
        esac
      elif [ "$SECONDS" -eq "$before" ]; then                  # no wait at all: the router's pipe closed
        instant=$(( instant + 1 )); [ "$instant" -ge 3 ] && { eof=1; LISTING=0; DRC=${DRC:-255}; }
        sleep 1
      fi
    else
      sleep 1
    fi
    # --- the destination may not hold everything (first copy of a folder)
    if [ "$warned" -eq 0 ] && [ "$first_run" -eq 1 ] && [ "$SRC_VOL" != "$SRC" ] && [ $(( ${DISC_BYTES%%.*} / 1024 )) -gt "${free_k:-0}" ] 2>/dev/null; then
      warned=1; printf '\r\033[K'
      add_issue PROBLEM DESTINATION "The source ($(hk $(( ${DISC_BYTES%%.*} / 1024 ))) found so far) may not fit in the free space on the destination ($(hk "$free_k"))" \
"The destination will fill up before the copy finishes." \
"Free up space on $DST_VOL, use a bigger drive, or copy a smaller folder." \
"Check sizes before starting; --dry-run shows how much would be copied."
      echo "WARNING: the source ($(hk $(( ${DISC_BYTES%%.*} / 1024 ))) found so far) may not fit in the destination's free space ($(hk "$free_k"))."
    fi
    # --- progress, once a second: done = files looked at (copied or already there), of those found
    if [ "$SECONDS" -ne "$last_prog" ]; then
      last_prog=$SECONDS; done_b=$fin_b; done_f=$fin_f
      if [ "$running" -gt 0 ]; then
        words "$(progress_count check "${live[@]}")" xb xf; done_b=$(( done_b + xb )); done_f=$(( done_f + xf ))
      fi
      est_add "$done_b" "$done_f"; TUNING=$cal; tb="${DISC_BYTES%%.*}"
      progress_line "Copying" "$done_b" "$tb" "$done_f" "$DISC_FILES"
    fi
  done
  exec 3<&-
  echo
  for b in ${VQ[@]+"${VQ[@]}"}; do printf -v f '%s.%04d' "$pre" "$b"; rm -f "$f.rec"; done   # left for the final check
  rm -rf "$STREAM_EMPTY"
  BATCH_SECS=$(( SECONDS - t_start )); [ "$BATCH_SECS" -gt 0 ] || BATCH_SECS=1; BATCH_BYTES=$COPIED_BYTES
  COPY_SECS=$(( COPY_SECS + BATCH_SECS ))
  cat "$RUNDIR/scan.err" 2>/dev/null >> "$ALLERR"
  [ "$COPY_BATCH_FAILED" -eq 1 ] && PREV_UNFINISHED=1
  if [ -n "$sort_pid" ] && wait "$sort_pid" && drives_here; then
    STREAM_OK=1; PLAN_COMPLETE=1; PLAN="$RUNDIR/plan"; rm -f "$RUNDIR/plan.raw"
    TODO_FILES=0; TODO_BYTES=0                 # (the space check already ran while listing)
  fi
}

# ---------------- Hash list (fingerprints of the source files, kept on the destination) ----------------

# ============================ Verification ============================
# Compares every file's contents (checksums) in batches, with the same tuning and time-left display,
# then a quick size/date pass over everything for folders and links.
# LIST = sorted plan records; HOW = select (reuse fingerprints and a stopped check) or full.
verify() {
  local list="$1" how="$2" pre="$RUNDIR/v" hpre="$RUNDIR/h" hc="$RUNDIR/hc" full="$RUNDIR/full"
  local vs="" man="" cj="" sel skipped=0 hn=0 hb=0 vf=0 vb=0 b f rc r j=() x
  wait_for_mounts
  : > "$VERIFYLOG"; vrc=0
  if [ "$how" = select ]; then
    for x in "$JPREFIX".new-*; do [ -s "$x" ] && j+=("$x"); done
    [ ${#j[@]} -gt 0 ] && journal_fold "$JPREFIX.sorted" "${j[@]}"
    [ -s "$JPREFIX.sorted" ] && cj="$JPREFIX.sorted"
    if hash_list_ok; then man="$HASHFILE"
    elif [ -s "$HASHFILE" ]; then done_msg "The saved fingerprints are from an older version; this check compares with the source and saves new ones."; fi
    if [ -s "$VSTATE" ]; then
      vs="$RUNDIR/checkpoint"
      ( set -o pipefail; LC_ALL=C awk -F'\t' 'NF == 3 { print $0 "\tV" }' "$VSTATE" | csort -k1,1 > "$vs" ) || vs=""
    fi
    until sel=$(select_checks "$list" "$man" "$cj" "$vs" "$hc" "$full"); do   # a drive went away: wait, try again
      drives_here && fatal "Couldn't work out which files to check." "Writing the check list on the destination drive failed — it may be full." \
        "Free some space on the destination, then run the same command again." "" DESTINATION
      printf '\n'; wait_for_mounts
    done
    words "$sel" skipped hn hb vf vb
    [ "$skipped" -gt 0 ] && done_msg "$skipped files were already checked (as they were copied, or by a check that was stopped) — skipping those."
  else
    cp "$list" "$full"; : > "$hc"
    words "$(LC_ALL=C awk -F'\t' '{ s += $2 } END { printf "%d %.0f\n", NR, s }' "$full")" vf vb
  fi
  # Files with a saved fingerprint (unchanged on the source since) only need the destination read
  if [ "$hn" -gt 0 ]; then
    done_msg "$hn files ($(hk $(( ${hb%%.*} / 1024 )))) have saved fingerprints — checking those by reading only the destination drive."
    EMPTY_DIR=$(mktemp -d "$RUNDIR/empty.XXXXXX")
    until make_batches "$hc" "$hpre" hash "$hb"; do
      drives_here && fatal "Couldn't write the file list on the destination drive." \
        "The drive may be full." "Free some space on the destination, then run the same command again." "" DESTINATION
      wait_for_mounts
    done
    run_batches hash "$hpre" "$hb" "$hn"
    for b in $RETRY_BATCHES; do         # batches that couldn't be read are checked the full way instead
      printf -v f '%s.%04d' "$hpre" "$b"
      cut -f1-3 "$f.rec" >> "$full"; vf=$(( vf + BCOUNT[b] )); vb=$(( ${vb%%.*} + BSIZE[b] ))
    done
    rm -rf "$hpre".* "$EMPTY_DIR"
    HASH_CHECKED=$(( HASH_CHECKED + hn ))
    [ "$vf" -gt 0 ] && done_msg "Destination-only part done. Now comparing the remaining files with the source."
  fi
  FULL_CHECKED=$(( FULL_CHECKED + vf ))
  if [ "$vf" -gt 0 ]; then
    until make_batches "$full" "$pre" check "$vb"; do
      drives_here && fatal "Couldn't write the file list on the destination drive." \
        "The drive may be full." "Free some space on the destination, then run the same command again." "" DESTINATION
      wait_for_mounts
    done
    run_batches verify "$pre" "$vb" "$vf"
    for b in $RETRY_BATCHES; do         # batches cut off by a drive dropping out: once more
      printf -v f '%s.%04d' "$pre" "$b"; wait_for_mounts
      ( in_dst "$RSYNC" "${META[@]}" -r --checksum "${CSUM[@]}" --dry-run -ii "--out-format=$FMT" \
        "${EXCLUDES[@]}" --from0 --files-from="$f" "$SRC/" ./ ) > "$f.out" 2> "$f.err"
      rc=$?
      case $rc in 0|24) ;; 23) HAD23=1 ;; 20) RESULT="⏸ Stopped during verification — run the same command again to redo it."; exit 20 ;; *) vrc=$rc ;; esac
      r=$(finish_check "$f.out" "$JOURNAL" "$VERIFYLOG"); cat "$f.err" 2>/dev/null >> "$VERIFYLOG"
    done
    [ "$HAD23" -eq 1 ] && [ "$vrc" -eq 0 ] && vrc=23
    rm -f "$pre".*
  fi
  rm -f "$hc" "$full" "$RUNDIR/checkpoint"
  wait_for_mounts
  in_dst "$RSYNC" "${META[@]}" ${NOINC[@]+"${NOINC[@]}"} --dry-run --itemize-changes --out-format='%i %n' "${EXCLUDES[@]}" "$SRC/" ./ >> "$VERIFYLOG" 2>&1 &
  heartbeat $! "Checking folders and links"
  wait $!; rc=$?
  case $rc in 0|24) ;; 23) [ "$vrc" -eq 0 ] && vrc=23 ;; 20) RESULT="⏸ Stopped during verification — run the same command again to redo it."; exit 20 ;; *) [ "$vrc" -eq 0 ] && vrc=$rc ;; esac
  words "$(diff_summary "$VERIFYLOG" "$RUNDIR/repair")" DIFFS META_DIFFS
  rm -f "$VSTATE"                       # the check is complete: a later check starts afresh
}

# ============================ Main ============================
PERSISTENT=0; COPY_BATCH_FAILED=0
HASH_CHECKED=0; FULL_CHECKED=0
[ "$VERIFY_ONLY" -eq 1 ] && ENGINE=batch          # checking an existing copy: the batch engine
if [ "$VERIFY_ONLY" -eq 1 ]; then STEP_TOTAL=2
elif [ "$ENGINE" = stream ]; then STEP_TOTAL=3; [ "$VERIFY" = 0 ] && STEP_TOTAL=2
elif [ "$VERIFY" = 0 ]; then STEP_TOTAL=3; else STEP_TOTAL=4; fi
STREAM_OK=0; STREAM_CHECKED=0
if [ "$VERIFY_ONLY" -eq 1 ]; then
  step "List the files" "Making a list of every file on both drives, so the check knows exactly how much there is." "check every file's contents"
  plan_scan; post_scan_checks
elif [ "$ENGINE" = stream ]; then
  step "List and copy the files" "Listing the source and copying at the same time: copying starts as soon as the first files are found, and totals keep growing until the listing is done.$([ "$VERIFY" != 0 ] && echo " Copied files are checked as they finish, by reading them back from the destination.")" "a final pass for folders and links"
  stream_copy
  if [ "$STREAM_OK" -eq 1 ]; then
    done_msg "Found $ALL_FILES files ($(hk $(( ${ALL_BYTES%%.*} / 1024 )))) on the source; copied $COPIED_FILES.$([ "$STREAM_CHECKED" -gt 0 ] && echo " $STREAM_CHECKED already checked.")"
    post_scan_checks
  else
    STREAM_FAILED=$COPY_BATCH_FAILED
    done_msg "The listing was cut off — what was copied is kept. Finishing with a full listing of both drives."
    plan_scan; post_scan_checks
    if [ "$TODO_FILES" -gt 0 ]; then batch_copy; done_msg "Copied $TODO_FILES more files."; fi
    [ "$STREAM_FAILED" -eq 1 ] && COPY_BATCH_FAILED=1
  fi
  HASH_CHECKED=$(( HASH_CHECKED + STREAM_CHECKED ))
  # Safety net: whatever happened above, never go on without a complete file list
  if [ -z "$PLAN" ] || [ ! -f "$PLAN" ]; then
    done_msg "Making a full list of both drives."
    plan_scan; post_scan_checks
    if [ "$TODO_FILES" -gt 0 ]; then batch_copy; fi
    COPY_BATCH_FAILED=1
  fi
else
  step "List the files" "Comparing both drives to see what's already copied and what isn't." "copy what's missing"
  plan_scan; post_scan_checks
fi
if [ "$VERIFY_ONLY" -eq 0 ] && [ "$ENGINE" = stream ]; then :
elif [ "$VERIFY_ONLY" -eq 0 ]; then
  if [ "$TODO_FILES" -gt 0 ]; then
    step "Copy the files" "Copying $TODO_FILES files ($(hk $(( TODO_BYTES / 1024 )))) that are missing or changed. The first few minutes measure which speed setting is fastest." "a final pass for folders and links"
    batch_copy
    done_msg "Copied $TODO_FILES files."
  else
    step "Copy the files" "Nothing to copy — everything is already on the destination." "a final pass for folders and links"
  fi
fi
if [ "$VERIFY_ONLY" -eq 0 ]; then
  FINAL_C0=$COPIED_FILES
  # The final pass only needs the folders and links when every file was copied cleanly and the final
  # check will run anyway; otherwise (or with hard links) it goes through everything, as a safety net.
  if [ "$VERIFY" != 0 ] && [ "$COPY_BATCH_FAILED" -eq 0 ] && [ "${N_HLINKS:-0}" -eq 0 ] && [ -s "$PLAN_OTHER" ]; then
    step "Final pass" "Creating folders and links and setting their dates. Every file was copied cleanly and the check comes next, so this only visits the $N_OTHER folders and links, not every file." \
      "check every file's contents against the source"
    nul_list < "$PLAN_OTHER" > "$RUNDIR/other0"
    META_ALL=("${META[@]}"); META=(); for x in "${META_ALL[@]}"; do [ "$x" = -rt ] && x=-t; META+=("$x"); done   # no recursion
    copy_loop "Final pass" --from0 --files-from="$RUNDIR/other0" || PERSISTENT=1
    META=("${META_ALL[@]}")
  else
    step "Final pass" "Creating folders and links, and catching anything that changed or was missed. This mostly just reads; it can take several minutes on a big drive." \
      "$([ "$VERIFY" = 0 ] && echo "the report" || echo "check every file's contents against the source")"
    copy_loop "Final pass" || PERSISTENT=1
  fi
  # files changed: earlier check results no longer apply (the streaming engine keeps what it checked
  # itself, unless the final pass copied files again)
  if [ "$ENGINE" = stream ]; then [ "$COPIED_FILES" -gt "$FINAL_C0" ] && rm -f "$VSTATE"
  else { [ "$TODO_FILES" -gt 0 ] || [ "$COPIED_FILES" -gt 0 ]; } && rm -f "$VSTATE"; fi
  done_msg "Final pass done."
fi

if [ "$VERIFY" = "0" ]; then
  if [ "$PERSISTENT" -eq 1 ]; then RESULT="⚠️ Copied, except files that couldn't be read or written — see below."; exit 3; fi
  RESULT="✅ Copied (not verified — --no-verify was used). Verify later with --verify-only."; mark_finished; exit 0
fi

step "Check every file" "Proving the copy is exact. Files with a saved fingerprint are checked by reading only the destination; the rest are compared with the source (and their fingerprints saved for next time). All files are already copied — you can press Ctrl-C to stop this at any time; next time it continues where it stopped:
sudo $0 --verify-only \"$SRC\" \"$DST\"" "the report"
verify "$PLAN" select
done_msg "Check finished."

if [ "$DIFFS" -gt 0 ]; then
  first_diffs=$DIFFS
  echo "  $DIFFS items didn't match — copying just those again, then re-checking them..."
  RLIST="$RUNDIR/repair"; mv -f "$RUNDIR/repair" "$RLIST.list" 2>/dev/null; RLIST="$RLIST.list"
  if [ -s "$RLIST" ]; then
    nul_list < "$RLIST" > "$RLIST.0"
    copy_loop "Repair" -r --checksum "${CSUM[@]}" --from0 --files-from="$RLIST.0" || PERSISTENT=1
  fi
  if grep -qE '^[<>c*][dLDS]' "$VERIFYLOG"; then copy_loop "Repair folders and links" || PERSISTENT=1; fi
  LC_ALL=C awk '{ print $0 "\t0\t-" }' "$RLIST" > "$RLIST.v"
  echo "  Re-checking the repaired files..."
  verify "$RLIST.v" full
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
