#!/usr/bin/env bash
# install.sh — symlink Quorum's helper scripts onto PATH.
#
#   ./scripts/install.sh              # -> ~/.local/bin
#   ./scripts/install.sh /usr/local/bin
#
# Symlinks rather than copies, so `git pull` updates them.
#
# Why executables and not shell functions: agents and scripts run in NON-interactive
# shells, where functions and aliases do not exist. A helper defined in ~/.zshrc is
# invisible to every subagent that needs it. See docs/field-notes.md.

set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
DEST="${1:-$HOME/.local/bin}"
TOOLS="quorum-setup quorum-status quorum-auth quorum-flags quorum-claude-on quorum-verify prep-image make-probe-image"

mkdir -p "$DEST"

for t in $TOOLS; do
  if [ ! -f "$SRC/$t" ]; then echo "  MISSING  $t (skipped)"; continue; fi
  chmod +x "$SRC/$t"
  ln -sf "$SRC/$t" "$DEST/$t"
  echo "  linked   $DEST/$t"
done

echo
case ":$PATH:" in
  *":$DEST:"*) echo "$DEST is already on PATH." ;;
  *) cat <<EOM
$DEST is NOT on PATH. Add it in ~/.zshenv (not ~/.zshrc — non-interactive shells,
which is what agents get, do not read ~/.zshrc):

  export PATH="$DEST:\$PATH"
EOM
  ;;
esac

echo
echo "Next:  quorum-setup    (guided: prerequisites -> providers -> auth -> verify)"
