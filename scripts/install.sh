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

# Resolve through symlinks so the shared lib is findable when installed the documented
# way: install.sh links this onto PATH, and `dirname "$0"` would give ~/.local/bin, not the
# repo. macOS has no `readlink -f`.
_qsrc="$0"
while [ -L "$_qsrc" ]; do
  _qdir=$(cd -P "$(dirname "$_qsrc")" && pwd)
  _qsrc=$(readlink "$_qsrc")
  case "$_qsrc" in /*) ;; *) _qsrc="$_qdir/$_qsrc" ;; esac
done
# shellcheck source=/dev/null
. "$(cd -P "$(dirname "$_qsrc")" && pwd)/quorum-lib.sh"

SRC=$(cd "$(dirname "$0")" && pwd)
DEST="${1:-$HOME/.local/bin}"
TOOLS="quorum-setup quorum-status quorum-auth quorum-flags quorum-claude-on quorum-verify prep-image make-probe-image"

mkdir -p "$DEST"

# Warn if these symlinks already point at a DIFFERENT clone. Silently repointing them is
# how you end up with eight dangling commands on PATH after deleting a throwaway clone.
existing=$(readlink "$DEST/quorum-verify" 2>/dev/null || true)
case "$existing" in
  ""|"$SRC/quorum-verify") ;;
  *) printf '  NOTE  re-pointing an existing install:\n        was %s\n        now %s\n\n' \
       "$(dirname "$existing")" "$SRC" ;;
esac

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
$DEST is NOT on PATH. Add it in $QUORUM_ENVFILE_SHORT:

  echo 'export PATH="$DEST:\$PATH"' >> $QUORUM_ENVFILE

$QUORUM_ENVFILE_WHY.
EOM
  ;;
esac

echo
# Print the spelling that will ACTUALLY work from here. The old version printed
# "Next: quorum-setup" unconditionally, directly under "$DEST is NOT on PATH" — so the
# documented next command was one the preceding paragraph had just explained could not run.
# Measured on a clean Debian container and on macOS: `command not found`, exit 127.
# `./scripts/quorum-setup` works either way, because quorum-setup fixes PATH itself.
case ":$PATH:" in
  *":$DEST:"*) echo "Next:  quorum-setup    (guided: prerequisites -> providers -> auth -> verify)" ;;
  *) cat <<EOM
Next:  ./scripts/quorum-setup    (guided: prerequisites -> providers -> auth -> verify)

Run it with the ./scripts/ prefix from this directory — the bare name will not work
until you have added $DEST to PATH and opened a new terminal.
EOM
  ;;
esac
