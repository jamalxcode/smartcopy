#!/bin/bash
# Scaling benchmark of smartcopy's file-list handling, old (v12.2) against new, on synthetic lists.
#   bench/micro.sh [N...]          default N: 100000 300000 1000000 3000000
# For each N (number of files) it times, and records the peak memory of:
#   check-dest    destination-only check of all N files in 5000-file batches
#                 old: hcompare() reads the whole fingerprint list once per batch
#                 new: finish_hash() reads only that batch's expected fingerprints
#   select        deciding how each file is checked (fingerprint list + stopped-check checkpoint)
#                 old: awk tables of the whole fingerprint list and checkpoint in memory
#                 new: select_checks() merges sorted lists
#   save          adding N new fingerprints to a list of N
#                 old: hash_merge() (whole list in memory, rewritten each call; called 2-3 times a run)
#                 new: journal_fold() + manifest_write() (sort only the new entries, merge, write once)
#   poll          one refresh of the progress line at the end of the copy
#                 old: re-reads every batch log so far; new: only the batches still running (4)
#   report        copy figures for the report
#                 old: copied_paths() run 5 times over the log, whole list in memory each time
#                 new: copy_stats() once, external sort
# Times and memory come from GNU time (%e seconds, %M peak KB of the largest process).
# Old runs are skipped above OLD_MAX files (default 1000000) where they take too long.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
SIZES="${*:-100000 300000 1000000 3000000}"
OLD_MAX="${OLD_MAX:-1000000}"
W="${W:-/tmp/sc-micro}"; rm -rf "$W"; mkdir -p "$W/tmp"
export TMPDIR="$W/tmp" SMARTCOPY_LIB=1 LC_ALL=C
. "$here/../smartcopy.sh"
TIME=/usr/bin/time

# ---------------- v12.2 code, verbatim (smartcopy.sh at commit 8005cbd) ----------------
old_hcompare() {   # hcompare BATCH_LIST RSYNC_OUTPUT
  awk -v man="$HASHFILE" -v lst="$1" '
    FILENAME == man { if (FNR > 1) { p = $0; sub(/^[^\t]*\t[^\t]*\t/, "", p); split($0, a, "\t"); h[p] = a[1] } next }
    FILENAME == lst { want[$0] = 1; next }
    substr($0, 1, 2) == ">f" { rest = substr($0, 13); sub(/^[0-9]+ /, "", rest); got[substr(rest, 34)] = substr(rest, 1, 32) }
    END { for (p in want) if (!(p in got) || got[p] != h[p]) print ">fc........ " p }' "$HASHFILE" "$1" "$2"
}
old_select() {   # the selection step of v12.2 verify(): checkpoint skip, then fingerprint lookup
  awk -F'\t' -v st="$VSTATE" 'FILENAME == st { ok[$0]; next } !($2 in ok)' "$VSTATE" "$1" > "$W/todo"
  awk -F'\t' -v man="$HASHFILE" -v sk="/dev/null" -v hc="$W/hc" '
      FILENAME == man { if (FNR > 1) { p = $0; sub(/^[^\t]*\t[^\t]*\t/, "", p); sz[p] = $2 } next }
      FILENAME == sk { skip[$2] = 1; next }
      { if (($2 in sz) && sz[$2] == $1 && !($2 in skip)) print > hc; else print }' \
      "$HASHFILE" "/dev/null" "$W/todo" > "$W/full"
}
old_hash_merge() {
  local new="$1" tmp="$HASHFILE.new.$$"
  { echo "#smartcopy-hashes v1 algo=xxh128"
    awk -F'\t' -v cur="$HASHFILE" 'FILENAME == cur { if (FNR > 1) { p = $0; sub(/^[^\t]*\t[^\t]*\t/, "", p); h[p] = $1 "\t" $2 } next }
      { p = $0; sub(/^[^\t]*\t[^\t]*\t/, "", p); h[p] = $1 "\t" $2 } END { for (p in h) print h[p] "\t" p }' "$HASHFILE" "$new"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$HASHFILE"
}
old_copied_paths() {
  awk '$4 ~ /^>f/ { line = $0; for (i = 1; i <= 6; i++) sub(/^[^ ]+ +/, "", line); sz[line] = $5; n[line]++ }
       END { for (p in sz) print sz[p] "\t" n[p] "\t" p }' "$1"
}
old_report() {   # render_report() + speed_note() called copied_bytes/count/twice 5 times in all
  old_copied_paths "$1" | awk -F'\t' '{ s += $1 } END { printf "%.0f", s }' >/dev/null
  old_copied_paths "$1" | awk -F'\t' '{ s += $1 } END { printf "%.0f", s }' >/dev/null
  old_copied_paths "$1" | wc -l >/dev/null
  old_copied_paths "$1" | awk -F'\t' '$2 > 1' | wc -l >/dev/null
  old_copied_paths "$1" | wc -l >/dev/null
}

# ---------------- synthetic data ----------------
gen() {   # gen N: files named like a real tree; old and new formats of the same data
  local n="$1"
  awk -v n="$n" -v d="$W" 'BEGIN {
    srand(1)
    for (i = 0; i < n; i++) {
      p = sprintf("Photos %03d/Album %04d/IMG_%08d café.jpg", i % 397, int(i / 1000), i)
      sz = int(rand() * 4000000); m = sprintf("2024/%02d/%02d-12:00:%02d", i % 12 + 1, i % 28 + 1, i % 60)
      h = sprintf("%08x%08x%08x%08x", i, i * 7 + 3, i * 13 + 5, i * 31 + 7)
      print p "\t" sz "\t" m "\t-" > (d "/plan.unsorted")                         # new plan
      print p "\t" sz "\t" m "\t" h > (d "/man.unsorted")                         # new fingerprint list
      print h "\t" sz "\t" p > (d "/old.man.body")                                # old fingerprint list
      print sz "\t" p > (d "/old.plan")                                           # old plan
      if (i % 2) print p "\t" sz "\t" m "\tV" > (d "/vs.unsorted")                # half checked already
      if (i % 2) print p > (d "/old.vstate")
      print p "\t" sz "\t" m "\t" h > (d "/journal")                              # new fingerprints
      print h "\t" sz "\t" p > (d "/old.new")
      printf ">f+++++++++ %d %s %s %s\n", sz, m, h, p > (d "/out.new")             # rsync output (new format)
      printf ">f+++++++++ %d %s %s\n", sz, h, p > (d "/out.old")                   # rsync output (old format)
      printf "2026/01/01 10:00:00 [123] >f+++++++++ %d %s %s\n", sz, h, p > (d "/log.old")
    } }'
  { echo "#smartcopy-hashes v1 algo=xxh128"; cat "$W/old.man.body"; } > "$W/old.man"
  csort -k1,1 "$W/plan.unsorted" > "$W/plan"
  { echo "#smartcopy-hashes v2 algo=xxh128"; csort -k1,1 "$W/man.unsorted"; } > "$W/man"
  csort -k1,1 "$W/vs.unsorted" > "$W/vs"
  rm -f "$W/plan.unsorted" "$W/man.unsorted" "$W/vs.unsorted" "$W/old.man.body"
}
measure() {   # measure LABEL N VERSION COMMAND...: one result line
  local label="$1" n="$2" v="$3"; shift 3
  local r; $TIME -o "$W/time.out" -f '%e %M' bash -c "$*" >/dev/null 2>"$W/err.out"; r=$(tail -1 "$W/time.out")
  printf '{"op":"%s","files":%d,"version":"%s","seconds":%s,"peak_rss_mb":%.1f}\n' "$label" "$n" "$v" "${r% *}" "$(echo "${r#* }" | awk '{ print $1 / 1024 }')"
}
export -f old_hcompare old_select old_hash_merge old_copied_paths old_report csort finish_hash select_checks journal_fold \
  manifest_write copy_stats progress_count make_batches
export AWK_LIB MERGE_LIB TAB SORT_MEM W

for n in $SIZES; do
  gen "$n" >&2
  nb=$(( (n + 4999) / 5000 ))
  # per-batch inputs for the destination-only check
  split -l 5000 -d -a 5 "$W/out.old" "$W/ob."; split -l 5000 -d -a 5 "$W/out.new" "$W/nb."
  for f in "$W"/ob.*; do awk '{ p = $0; sub(/^([^ ]+ +){3}/, "", p); print p }' "$f" > "$f.lst"; done
  for f in "$W"/nb.*; do awk '{ s = $0; sub(/^([^ ]+ +){4}/, "", s); print s "\t" $2 "\t" $3 "\t" $4 }' "$f" > "$f.rec"; done
  if [ "$n" -le "$OLD_MAX" ]; then
    measure check-dest "$n" old "export HASHFILE=$W/old.man; for f in $W/ob.?????; do old_hcompare \$f.lst \$f; done"
  fi
  measure check-dest "$n" new "for f in $W/nb.?????; do finish_hash \$f.rec \$f $W/diffs; done"
  if [ "$n" -le "$OLD_MAX" ]; then
    measure select "$n" old "export HASHFILE=$W/old.man VSTATE=$W/old.vstate; old_select $W/old.plan"
  fi
  measure select "$n" new "select_checks $W/plan $W/man '' $W/vs $W/hc $W/full"
  if [ "$n" -le "$OLD_MAX" ]; then
    cp "$W/old.man" "$W/old.man.bak"
    measure save "$n" old "export HASHFILE=$W/old.man; old_hash_merge $W/old.new"
    mv "$W/old.man.bak" "$W/old.man"
  fi
  measure save "$n" new "cp $W/journal $W/j1; journal_fold $W/cj $W/j1 && manifest_write $W/man.out xxh128 $W/cj $W/man $W/plan; rm -f $W/cj"
  # progress refresh at the end of a copy: old reads all logs so far; new reads the 4 running batches
  split -l 5000 -d -a 5 "$W/log.old" "$W/lb."
  if [ "$n" -le "$OLD_MAX" ]; then
    measure poll "$n" old "cat $W/lb.* | awk '\$4 ~ /^>f/ { s += \$5; n++ } END { printf \"%.0f %d\", s, n }'"
  fi
  measure poll "$n" new "progress_count copy \$(ls $W/nb.????? | tail -4)"
  if [ "$n" -le "$OLD_MAX" ]; then
    measure report "$n" old "old_report $W/log.old"
  fi
  awk '{ s = $0; sub(/^([^ ]+ +){4}/, "", s); print }' "$W/out.new" > /dev/null
  measure report "$n" new "copy_stats $W/out.new"
  rm -f "$W"/ob.* "$W"/nb.* "$W"/lb.* "$W"/j1 "$W"/man.out
done
