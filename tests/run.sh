#!/bin/bash
# Automated tests for smartcopy, on Linux with loop-mounted drives standing in for Mac drives.
#
#   sudo tests/run.sh [SCRIPT] [TEST...]        default SCRIPT: ./smartcopy.sh, default: all tests
#
# Needs: root, rsync 3.2+ (linked as /usr/local/bin/rsync), mkfs.ext4, strace, python3.
# Stand-ins for macOS tools (diskutil, mdutil, caffeinate, launchctl, ...) are in tests/stubs.
# Env: SC_AWK=original-awk|mawk runs everything with that awk (the macOS awk is BWK awk).
#
# What is tested:
#   copy        copy + check of a tree with difficult names (tab, newline, backslash, emoji, ...)
#   privacy     no file names on screen, in notifications or in the report; names only in the
#               private files on the destination
#   nowrites    nothing written anywhere except the destination drive: not the source drive, not
#               the Mac's drive (whole root file system checked), not TMPDIR or HOME
#   nonet       no network sockets at all (strace)
#   corrupt     a damaged destination file with the same size and date is found and repaired
#   recheck     a second --verify-only checks everything again (checkpoint not reused after a full check)
#   checkpoint  a stopped check resumes, but not for source files changed since
#   resume      an interrupted copy keeps its fingerprints: the check after resuming reads only the destination
#   disconnect  the destination is unplugged mid-copy: smartcopy waits, writes nothing in its place,
#               and finishes when it comes back
#   dryrun      dry run shows counts only and passes rsync's exit code on
#   errors      an rsync error naming a file: the report explains it without the name; exit code 3
#   exfat       exFAT mode (contents and dates only, write in place, folders-and-links final pass)
#   stop        --background then --stop: every rsync stops; running again finishes the copy
#   lib         unit tests of the file-list library (record format, merges, batches)
set -u
here="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$(cd "$here/.." && pwd)/smartcopy.sh"
if [ $# -gt 0 ] && [ -f "$1" ]; then SCRIPT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; shift; fi
TESTS="${*:-lib copy privacy nowrites nonet corrupt recheck checkpoint resume disconnect dryrun errors exfat stop}"
IMG="${IMG:-/tmp/sc-test-img}"; W="${W:-/tmp/sc-test-work}"
SRCV=/Volumes/SCTSRC; DSTV=/Volumes/SCTDST
PASS=0; FAIL=0; FAILED=""
mkdir -p "$IMG" "$W"
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
[ -e /usr/local/bin/rsync ] || ln -s "$(command -v rsync)" /usr/local/bin/rsync
export PATH="$here/stubs:$PATH"
if [ -n "${SC_AWK:-}" ]; then mkdir -p "$W/awkbin"; ln -sf "$(command -v "$SC_AWK")" "$W/awkbin/awk"; export PATH="$W/awkbin:$PATH"; fi
export SC_TEST_NOTIFY="$W/notifications"; export SUDO_USER=root

ok()   { PASS=$(( PASS + 1 )); echo "  ok   $*"; }
bad()  { FAIL=$(( FAIL + 1 )); FAILED="$FAILED $CUR"; echo "  FAIL $*"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

vol() {   # vol MOUNTPOINT SIZE: fresh ext4 drive
  local m="$1" img="$IMG/$(basename "$1").img"
  umount "$m" 2>/dev/null; mkdir -p "$m"
  rm -f "$img"; truncate -s "$2" "$img"; mkfs.ext4 -qF "$img"; mount -o loop "$img" "$m"
}
fresh() {   # fresh [mkdata options]: new source tree with difficult names, empty destination
  vol "$SRCV" 1G; vol "$DSTV" 1G
  python3 "$here/../bench/mkdata.py" "$SRCV/data" --files "${NFILES:-1500}" --dirs 40 --odd-names "$@" >/dev/null
  : > "$SC_TEST_NOTIFY"
}
sc() {   # sc OUTFILE ARGS...: run smartcopy, keep its console output; returns its exit code
  local out="$1"; shift
  timeout "${SC_TIMEOUT:-900}" bash "$SCRIPT" --yes "$@" > "$out" 2>&1 < /dev/null
}
same_trees() { diff -r -x .smartcopy-target -x .smartcopy-hashes -x rsync-logs "$SRCV/data" "$DSTV/copy" >/dev/null 2>&1; }
report_of() { ls -t "$DSTV"/rsync-logs/report-*.txt 2>/dev/null | head -1; }
no_names_in() { ! grep -qa SECRETNAME "$@" 2>/dev/null; }

t_lib() {
  local T="$W/lib"; rm -rf "$T"; mkdir -p "$T/tmp"
  ( export TMPDIR="$T/tmp" SMARTCOPY_LIB=1; . "$SCRIPT"
    cd "$T"
    # record format: every name survives escape -> list -> real bytes
    mkdir -p s; for n in "a b" "tab	x" "nl
x" 'back\#011' 'back\\' "café 🙂" "-dash" "x -> y"; do printf '%s' "$n" > "s/$n"; done
    rsync -a -8 --dry-run -ii --out-format='%i %l %M %n' s/ d/ | scan_parse all other sum
    [ "$(cut -d' ' -f1 sum)" = 8 ] || { echo "count $(cat sum)"; exit 1; }
    csort -k1,1 all > plan; LC_ALL=C cut -f1 plan | nul_list > list0
    rm -rf d; mkdir d; rsync -a --from0 --files-from=list0 s/ d/ || exit 1
    diff -r s d || exit 1
    LC_ALL=C awk -F"\t" "NF != 4 { bad = 1 } END { exit bad }" plan || exit 1   # no raw tab inside a stored name
    [ "$(wc -l < plan)" -eq 8 ] || exit 1               # no raw newline inside a stored name
    echo names-ok
  ) > "$T/out" 2>&1; check "record format round-trips every name (tab, newline, backslash, emoji)" grep -q names-ok "$T/out"
  ( export TMPDIR="$T/tmp" SMARTCOPY_LIB=1; . "$SCRIPT"; cd "$T"
    printf 'a\t10\tM1\t-\nb\t20\tM2\t-\nc\t30\tM3\t-\nd\t40\tM4\t-\n' > plan
    { echo '#smartcopy-hashes v2 algo=x'; printf 'a\t10\tM1\tHA\nb\t20\tOLD\tHB\nc\t30\tM3\tHC\n'; } > man
    printf 'c\t30\tM3\tHC2\n' > j1; printf 'c\t30\tM3\tHC3\n' > j2
    journal_fold cj j1 j2 || exit 1
    [ "$(cut -f4 cj)" = HC3 ] || { echo "newest journal entry should win"; exit 1; }
    printf 'd\t40\tM4\tV\na\t10\tOLD\tV\n' > vs
    r=$(select_checks plan man cj vs hc full)
    [ "$r" = "1 2 40 1 20" ] || { echo "select: $r"; cat hc full; exit 1; }   # d skipped; a,c by hash; b full (stale)
    [ "$(cut -f1,4 hc | tr '\t\n' ':,')" = "a:HA,c:HC3," ] || { echo "hc"; exit 1; }
    manifest_write out x cj man plan || exit 1
    [ "$(tail -n +2 out | cut -f1,4 | tr '\t\n' ':,')" = "a:HA,c:HC3," ] || { echo "manifest"; cat out; exit 1; }  # stale b pruned
    awk 'BEGIN { for (i = 0; i < 12001; i++) printf "f%06d\t1\tM\tT\n", i }' > big
    make_batches big pre copy 12001 || exit 1
    [ "$NB" -eq 3 ] && [ "${BCOUNT[1]}" -eq 5000 ] && [ "${BCOUNT[3]}" -eq 2001 ] || { echo "batches $NB"; exit 1; }
    [ "$(tr -cd '\0' < pre.0001 | wc -c)" -eq 5000 ] || exit 1
    echo merge-ok
  ) > "$T/out2" 2>&1; check "fingerprint, checkpoint and journal merges; stale entries dropped; batches" grep -q merge-ok "$T/out2"
[ -z "$(ls -A "$T/tmp")" ] && ok "library leaves no temporary files" || bad "library leaves no temporary files"
}

t_copy() {
  fresh
  sc "$W/copy.out" "$SRCV/data" "$DSTV/copy"; local rc=$?
  check "copy exits 0 (got $rc)" [ "$rc" -eq 0 ]
  check "destination tree identical to source" same_trees
  check "report says verified" grep -q "Copied and verified" "$(report_of)"
  check "no working files left behind" bash -c "! ls -d $DSTV/rsync-logs/.run-* >/dev/null 2>&1"
  check "fingerprint list in v2 format" grep -qx '#smartcopy-hashes v2 algo=xxh128' <(head -1 "$DSTV/copy/.smartcopy-hashes")
}

t_privacy() {
  fresh
  # an error that names a file: a folder sits where the source has a file
  mkdir -p "$DSTV/copy/odd SECRETNAME dir/SECRETNAME café.txt/x"
  sc "$W/priv1.out" "$SRCV/data" "$DSTV/copy"
  sc "$W/priv2.out" --dry-run "$SRCV/data" "$DSTV/copy"
  sc "$W/priv3.out" --verify-only "$SRCV/data" "$DSTV/copy"
  check "no file names on screen (copy, dry run, check)" no_names_in "$W"/priv[123].out
  check "no file names in notifications" no_names_in "$SC_TEST_NOTIFY"
  check "no file names in any report" no_names_in "$DSTV"/rsync-logs/report-*.txt
  check "names are in the private file list instead" grep -qa SECRETNAME "$DSTV"/rsync-logs/affected-files-*.txt
  check "report points to the private list" grep -q "Private file list" "$(report_of)"
}

t_nowrites() {
  fresh
  local mark="$W/mark" tmpd="$W/tmpdir" homed="$W/home" before after
  rm -rf "$tmpd" "$homed"; mkdir -p "$tmpd" "$homed"
  ( cd "$SRCV/data" && find . -printf '%p %s %T@ %C@ %m\n' | sort ) > "$W/src.before"
  sync; touch "$mark"; sleep 1
  TMPDIR="$tmpd" HOME="$homed" sc "$W/nw1.out" "$SRCV/data" "$DSTV/copy"
  TMPDIR="$tmpd" HOME="$homed" sc "$W/nw2.out" --verify-only "$SRCV/data" "$DSTV/copy"
  echo corrupt >> "$DSTV/copy/L1-000/L2-000/L3-00000/file-0000000.dat"
  TMPDIR="$tmpd" HOME="$homed" sc "$W/nw3.out" "$SRCV/data" "$DSTV/copy"
  TMPDIR="$tmpd" HOME="$homed" sc "$W/nw4.out" --speed-test "$SRCV/data" "$DSTV/copy"
  sync
  ( cd "$SRCV/data" && find . -printf '%p %s %T@ %C@ %m\n' | sort ) > "$W/src.after"
  check "source drive unchanged (names, sizes, dates, permissions, change times)" cmp -s "$W/src.before" "$W/src.after"
  check "nothing new on the source drive" bash -c "[ -z \"\$(find $SRCV -newer $mark -o -cnewer $mark | head -1)\" ]"
  check "TMPDIR untouched" bash -c "[ -z \"\$(ls -A $tmpd)\" ]"
  check "HOME untouched" bash -c "[ -z \"\$(ls -A $homed)\" ]"
  # The whole Mac-side file system (here: the root file system), minus this test's own files
  find / -xdev \( -newer "$mark" -o -cnewer "$mark" \) \( -type f -o -type d -o -type l \) 2>/dev/null \
    | grep -vE "^($W|$IMG|/tmp/scimg|/proc|/sys|/dev|/run|/root/\.ccr|/root/\.claude|/var/log)(/|$)" \
    | grep -vE "^/Volumes$|^$DSTV$|^$SRCV$|^/tmp$|^/tmp/claude|^/home/user/smartcopy/(tests|bench)|/__pycache__" > "$W/rootfs.new"
  check "nothing written on the Mac's own drive (root file system scan)" bash -c "[ ! -s $W/rootfs.new ] || { cat $W/rootfs.new >&2; false; }"
}

t_nonet() {
  fresh
  strace -f -qq -e trace=socket,connect -o "$W/net.trace" bash "$SCRIPT" --yes "$SRCV/data" "$DSTV/copy" > "$W/net.out" 2>&1 < /dev/null
  check "no network sockets opened (no AF_INET/AF_INET6)" bash -c "! grep -E 'AF_INET6?|AF_PACKET|AF_NETLINK' $W/net.trace"
  check "copy still verified under strace" same_trees
}

t_corrupt() {
  fresh
  sc "$W/c1.out" "$SRCV/data" "$DSTV/copy"
  local f="$DSTV/copy/L1-001/L2-000/L3-00001/file-0000001.dat" m
  m=$(stat -c %Y "$f"); printf 'X' | dd of="$f" bs=1 seek=3 conv=notrunc 2>/dev/null; touch -d "@$m" "$f"
  sc "$W/c2.out" --verify-only "$SRCV/data" "$DSTV/copy"; local rc=$?
  check "damaged file (same size and date) found and repaired" grep -q "didn't match after copying, and were repaired" "$(report_of)"
  check "repaired copy identical (exit $rc)" same_trees
}

t_recheck() {
  fresh
  sc "$W/r1.out" "$SRCV/data" "$DSTV/copy"
  sc "$W/r2.out" --verify-only "$SRCV/data" "$DSTV/copy"
  local f="$DSTV/copy/L1-002/L2-000/L3-00002/file-0000002.dat" m
  m=$(stat -c %Y "$f"); printf 'Y' | dd of="$f" bs=1 seek=5 conv=notrunc 2>/dev/null; touch -d "@$m" "$f"
  sc "$W/r3.out" --verify-only "$SRCV/data" "$DSTV/copy"
  check "a finished check isn't reused: the next check doesn't skip files" bash -c "! grep -q 'already checked in an earlier run' $W/r3.out"
  check "the next check finds damage made after the last check" grep -q "didn't match after copying" "$(report_of)"
}

t_checkpoint() {
  NFILES=12000 fresh
  sc "$W/k1.out" --no-verify "$SRCV/data" "$DSTV/copy"
  rm -f "$DSTV/copy/.smartcopy-hashes" "$DSTV"/rsync-logs/.hashes-*        # force a full (source + destination) check
  # stop the check after its first batch has finished
  bash "$SCRIPT" --yes --jobs 1 --verify-only "$SRCV/data" "$DSTV/copy" > "$W/k2.out" 2>&1 < /dev/null &
  local p=$! i=0
  while [ $i -lt 600 ] && ! ls "$DSTV"/rsync-logs/.verified-* >/dev/null 2>&1; do sleep 0.1; i=$(( i + 1 )); done
  kill -TERM $p; wait $p
  local vs; vs=$(ls "$DSTV"/rsync-logs/.verified-* 2>/dev/null | head -1)
  check "stopped check left a checkpoint" [ -s "$vs" ]
  # change a checkpointed file on the source (same size, new content and date)
  local name; name=$(head -1 "$vs" | cut -f1)
  printf 'Z' | dd of="$SRCV/data/$name" bs=1 seek=1 conv=notrunc 2>/dev/null; touch -d '+5 seconds' "$SRCV/data/$name"
  sc "$W/k3.out" --verify-only "$SRCV/data" "$DSTV/copy"
  check "resumed check skips what was already confirmed" grep -q "already checked in an earlier run" "$W/k3.out"
  check "but not a source file that changed since: it is compared and repaired" grep -q "didn't match after copying" "$(report_of)"
  check "copy identical afterwards" same_trees
}

t_resume() {
  NFILES=12000 fresh --big 2 --big-mb 64
  bash "$SCRIPT" --yes --jobs 1 "$SRCV/data" "$DSTV/copy" > "$W/s1.out" 2>&1 < /dev/null &
  local p=$! i=0
  while [ $i -lt 600 ] && [ "$(cat "$DSTV"/rsync-logs/copy-*.log 2>/dev/null | wc -l)" -lt 5000 ]; do sleep 0.1; i=$(( i + 1 )); done
  check "copy was stopped part-way (some files copied, not all)" bash -c "[ -n \"\$(ls $DSTV/copy 2>/dev/null)\" ] && ! grep -q 'Copied and verified' $W/s1.out"
  kill -TERM $p; wait $p
  check "interrupted copy kept the fingerprints of what it copied" bash -c "ls $DSTV/rsync-logs/.hashes-* >/dev/null 2>&1 || [ -s $DSTV/copy/.smartcopy-hashes ]"
  sc "$W/s2.out" "$SRCV/data" "$DSTV/copy"; local rc=$?
  check "resumed copy verified (exit $rc)" same_trees
  local full; full=$(sed -n 's/.*hash list (destination only), \([0-9]*\) compared.*/\1/p' "$(report_of)")
  check "check after resuming read only the destination (compared with source: ${full:-?}; only hard-linked files expected)" [ "${full:-99}" -le 2 ]
}

t_disconnect() {
  NFILES=6000 fresh --big 3 --big-mb 64
  bash "$SCRIPT" --yes --jobs 1 "$SRCV/data" "$DSTV/copy" > "$W/d.out" 2>&1 < /dev/null &
  local p=$! i=0
  while [ $i -lt 600 ] && ! grep -q "STEP 2" "$W/d.out"; do sleep 0.1; i=$(( i + 1 )); done
  sleep 1
  umount -l "$DSTV"                                   # "unplug" the destination
  i=0; while [ $i -lt 900 ] && ! grep -q "Waiting for the destination drive" "$W/d.out"; do sleep 0.1; i=$(( i + 1 )); done
  check "smartcopy pauses and waits for the destination" grep -q "Waiting for the destination drive" "$W/d.out"
  sleep 3
  check "nothing written where the destination was (no fallback to the Mac's drive)" \
    bash -c "[ ! -e $DSTV ] || [ -z \"\$(ls -A $DSTV 2>/dev/null)\" ]"
  mkdir -p "$DSTV"; mount -o loop "$IMG/$(basename "$DSTV").img" "$DSTV"   # plug it back in
  wait $p; local rc=$?
  check "copy finishes after the drive comes back (exit $rc)" [ "$rc" -eq 0 ]
  check "copy identical" same_trees
  check "report notes the disconnection" grep -q "destination drive disconnected" "$(report_of)"
}

t_dryrun() {
  fresh
  sc "$W/dr.out" --dry-run "$SRCV/data" "$DSTV/copy"; local rc=$?
  check "dry run exits 0 (got $rc)" [ "$rc" -eq 0 ]
  check "dry run shows counts" grep -qE "Would copy [0-9]+ files" "$W/dr.out"
  check "dry run copies nothing" bash -c "[ ! -e $DSTV/copy ]"
}

t_errors() {
  fresh
  mkdir -p "$DSTV/copy/odd SECRETNAME dir/SECRETNAME 日本語.txt/inner"
  sc "$W/e.out" "$SRCV/data" "$DSTV/copy"; local rc=$?
  check "exits 2 or 3 for files that couldn't be written (got $rc)" [ "$rc" -eq 2 -o "$rc" -eq 3 ]
  check "report explains the problem" grep -q "PROBLEMS" "$(report_of)"
  check "without naming the file" no_names_in "$(report_of)" "$W/e.out"
}

t_exfat() {
  fresh
  SC_TEST_FS=exfat sc "$W/x.out" "$SRCV/data" "$DSTV/copy"; local rc=$?
  check "exFAT-mode copy exits 0 (got $rc)" [ "$rc" -eq 0 ]
  check "final pass visits only folders and links" grep -q "only visits the" "$W/x.out"
  check "file contents identical" bash -c "cd $SRCV/data && find . -type f | sort > $W/xf; cd $DSTV/copy && find . -type f ! -name '.smartcopy-*' | sort | cmp -s - $W/xf && cd $SRCV/data && while IFS= read -r f; do cmp -s \"\$f\" \"$DSTV/copy/\$f\" || exit 1; done < <(find . -type f ! -name '*newline*')"
}

t_stop() {
  pgrep -af "rsync.*$DSTV" > "$W/b.before"
  check "no rsync left running by earlier tests" bash -c "[ ! -s $W/b.before ] || { cat $W/b.before >&2; pkill -f 'rsync.*$DSTV'; false; }"
  NFILES=12000 fresh --big 2 --big-mb 64
  bash "$SCRIPT" --yes --background --jobs 2 "$SRCV/data" "$DSTV/copy" > "$W/b.out" 2>&1 < /dev/null
  local i=0; while [ $i -lt 300 ] && ! ls "$DSTV"/rsync-logs/locks/*.lock/pid >/dev/null 2>&1; do sleep 0.1; i=$(( i + 1 )); done
  sleep 3
  bash "$SCRIPT" --stop "$DSTV/copy" > "$W/b2.out" 2>&1
  sleep 3
  pgrep -af "rsync.*$DSTV" > "$W/b.left"; check "--stop ends every rsync" bash -c "[ ! -s $W/b.left ] || { cat $W/b.left >&2; false; }"
  check "background copy started" grep -q "running in the background" "$W/b.out"
  sc "$W/b3.out" "$SRCV/data" "$DSTV/copy"; local rc=$?
  check "running again finishes the copy (exit $rc)" [ "$rc" -eq 0 ]
  check "copy identical" same_trees
}

for CUR in $TESTS; do
  echo "== $CUR"
  "t_$CUR"
done
umount "$SRCV" "$DSTV" 2>/dev/null
echo
echo "$PASS passed, $FAIL failed${FAILED:+ (in:$FAILED)}"
[ "$FAIL" -eq 0 ]
