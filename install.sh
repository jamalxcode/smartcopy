#!/bin/bash
# Install smartcopy so it runs from anywhere as:  sudo smartcopy SOURCE DESTINATION
#
#   sudo ./install.sh              install (or update) the command and its man page
#   sudo ./install.sh --uninstall  remove them
#
# Installs:  /usr/local/bin/smartcopy                 the program
#            /usr/local/share/man/man1/smartcopy.1    the manual  (man smartcopy)
# Run it from the smartcopy folder (a git clone, an unzipped download, or a folder in Downloads
# holding smartcopy.sh and smartcopy.1). Nothing else on the Mac is changed.

set -u
PREFIX="${PREFIX:-/usr/local}"
BIN="$PREFIX/bin/smartcopy"
MAN="$PREFIX/share/man/man1/smartcopy.1"
OLD_MAN="$PREFIX/share/man/man1/safe-copy.1"

die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Run with sudo:  sudo ./install.sh"

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$BIN" "$MAN" "$OLD_MAN"
  echo "Removed $BIN and its man page."
  echo "Copies and their rsync-logs folders on your drives were not touched."
  exit 0
fi

HERE="$(cd "$(dirname "$0")" && pwd -P)"
SCRIPT=""; for f in "$HERE/smartcopy.sh" "$HERE/../smartcopy.sh"; do [ -f "$f" ] && { SCRIPT="$f"; break; }; done
PAGE="";   for f in "$HERE/man/smartcopy.1" "$HERE/smartcopy.1"; do [ -f "$f" ] && { PAGE="$f"; break; }; done
[ -n "$SCRIPT" ] || die "smartcopy.sh not found next to install.sh."

if [ -x "$BIN" ]; then echo "Updating $(sed -n '2s/^# //;2s/ —.*//p' "$BIN") → $(sed -n '2s/^# //;2s/ —.*//p' "$SCRIPT")"
else echo "Installing $(sed -n '2s/^# //;2s/ —.*//p' "$SCRIPT")"; fi

mkdir -p "$PREFIX/bin" || die "Couldn't create $PREFIX/bin"
install -m 755 "$SCRIPT" "$BIN" || die "Couldn't install $BIN"
xattr -d com.apple.quarantine "$BIN" 2>/dev/null
echo "  ✓ program:  $BIN"

if [ -n "$PAGE" ]; then
  mkdir -p "$(dirname "$MAN")" && install -m 644 "$PAGE" "$MAN" && echo "  ✓ manual:   $MAN   (man smartcopy)"
else
  echo "  – manual not found next to install.sh; skipped"
fi
[ -f "$OLD_MAN" ] && rm -f "$OLD_MAN" && echo "  ✓ removed the old safe-copy man page"

# Check the one dependency
ok=0
for r in /opt/homebrew/bin/rsync /usr/local/bin/rsync; do
  [ -x "$r" ] || continue
  v=$("$r" --version 2>/dev/null | awk 'NR==1{split($3,a,"."); print a[1]*100+a[2]}')
  [ "${v:-0}" -ge 302 ] && ok=1
done
if [ "$ok" -eq 1 ]; then echo "  ✓ rsync 3.2+ found"
else echo "  ! rsync 3.2+ not found — install it with:  brew install rsync"; fi

case ":$PATH:" in *":$PREFIX/bin:"*) ;; *) echo "  ! $PREFIX/bin isn't in your PATH; run it as: sudo $BIN" ;; esac
echo
echo "Done. Try:  sudo smartcopy --help"
echo "Also give Terminal Full Disk Access: System Settings > Privacy & Security > Full Disk Access."
