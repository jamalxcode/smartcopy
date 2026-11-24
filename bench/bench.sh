#!/bin/bash
# End-to-end benchmark of one or more smartcopy versions on Linux loop-mounted drives.
#   sudo bench/bench.sh OUT.jsonl LABEL=SCRIPT[@OPTION...] ...
#   e.g. batch=./smartcopy.sh@--engine=batch stream=./smartcopy.sh@--engine=stream
# Env: DATASETS="mixed tiny" (also: large = 500,000 files), STRACE_DATASETS="mixed",
#      SCENARIOS="first verify strace interrupt", IMG=/tmp/scimg (drive images).
# Each dataset is generated once (deterministic) on /Volumes/SCSRC; the destination drive
# /Volumes/SCDST is reformatted before every fresh run, and caches are dropped before each run.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
out="$1"; shift
IMG="${IMG:-/tmp/scimg}"; DATASETS="${DATASETS:-mixed tiny}"
mkdir -p "$IMG" /Volumes/SCSRC /Volumes/SCDST
command -v rsync >/dev/null || { echo "install rsync 3.2+ first"; exit 1; }
[ -e /usr/local/bin/rsync ] || ln -s "$(command -v rsync)" /usr/local/bin/rsync

fresh_dst() {
  umount /Volumes/SCDST 2>/dev/null
  [ -f "$IMG/dst.img" ] || truncate -s 16G "$IMG/dst.img"
  mkfs.ext4 -q -F "$IMG/dst.img" && mount -o loop "$IMG/dst.img" /Volumes/SCDST
}
make_src() {   # make_src NAME
  umount /Volumes/SCSRC 2>/dev/null
  if [ ! -f "$IMG/src-$1.img" ]; then
    truncate -s 12G "$IMG/src-$1.img"; mkfs.ext4 -q -F "$IMG/src-$1.img"
    mount -o loop "$IMG/src-$1.img" /Volumes/SCSRC
    case "$1" in
      mixed) python3 "$here/mkdata.py" /Volumes/SCSRC/data --files 50000 --dirs 2500 --median 8192 --big 6 --big-mb 128 ;;
      tiny)  python3 "$here/mkdata.py" /Volumes/SCSRC/data --files 250000 --dirs 5000 --median 600 ;;
      large) python3 "$here/mkdata.py" /Volumes/SCSRC/data --files 500000 --dirs 10000 --median 600 ;;
    esac >/dev/null
    sync; umount /Volumes/SCSRC
  fi
  mount -o loop "$IMG/src-$1.img" /Volumes/SCSRC
}
run() {   # run LABEL SCRIPT DATASET SCENARIO [run.py options]
  local label="$1" script="$2" ds="$3" sc="$4"; shift 4
  local r; r=$(python3 "$here/run.py" "$script" "$@" -- ${OPTS:-} ${SCARGS:-} /Volumes/SCSRC/data /Volumes/SCDST/copy)
  printf '{"version":"%s","dataset":"%s","scenario":"%s","result":%s}\n' "$label" "$ds" "$sc" "$r" | tee -a "$out"
}
for ds in $DATASETS; do
  make_src "$ds"
  for spec in "$@"; do
    label="${spec%%=*}"; script="${spec#*=}"; OPTS=""
    case "$script" in *@*) OPTS="$(printf '%s' "${script#*@}" | tr '@' ' ')"; script="${script%%@*}" ;; esac
    SC="${SCENARIOS:-first verify strace interrupt}"
    fresh_dst; run "$label" "$script" "$ds" first-copy
    case " $SC " in *" verify "*) SCARGS=--verify-only run "$label" "$script" "$ds" verify-only-rerun ;; esac
    case " ${STRACE_DATASETS:-mixed} $SC " in *" $ds "*" strace "*)   # strace slows runs down a lot; mixed only by default
      fresh_dst; run "$label" "$script" "$ds" first-copy-strace --strace ;; esac
    case " $SC " in *" interrupt "*) ;; *) continue ;; esac
    # interrupted copy: stop it partway through copying, then resume and measure the resume
    stop_at=$(python3 -c "import json,sys;r=[json.loads(l) for l in open('$out')];r=[x['result'] for x in r if x['version']=='$label' and x['dataset']=='$ds' and x['scenario']=='first-copy'][-1];print(round((r['first_transfer_s'] or 5)+0.5*r.get('copy_s',10),1))")
    fresh_dst; run "$label" "$script" "$ds" interrupted --stop-after "$stop_at" >/dev/null
    run "$label" "$script" "$ds" resume-after-interrupt
  done
done
