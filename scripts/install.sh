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

# Must run UNDER bash, not merely be invoked as ./install.sh. On Alpine, `sh ./scripts/install.sh`
# linked eight commands and exited 0 -- every one unrunnable, because each script begins
# #!/usr/bin/env bash and the box has no bash. Reporting success for a wholly non-functional
# install is precisely the failure this repo exists to catch. (busybox ash accepts
# `set -o pipefail`, so nothing below would have stopped it.)
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    echo "install.sh must run under bash:  bash ./scripts/install.sh" >&2
  else
    echo "install.sh needs bash, and this system has none." >&2
    echo "Every Quorum script starts with #!/usr/bin/env bash, so installing them here would" >&2
    echo "put unrunnable commands on your PATH. Install bash first." >&2
  fi
  exit 1
fi

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
TOOLS="quorum-setup quorum-status quorum-auth quorum-flags quorum-claude-on quorum-verify quorum-sanitize prep-image make-probe-image"

# --- uninstall -----------------------------------------------------------------------------
# There was no way to undo an install, and nothing said so. A user who wanted out had to work
# out unaided that it means: symlinks in ~/.local/bin, a PATH line in one of five possible
# shell files, an export line in the same file, ~/.config/quorum/, and optionally copies
# under ~/.claude/. Reusing $TOOLS here means this list cannot drift from what was installed.
#
# Removes ONLY symlinks that resolve into THIS clone. A same-named file belonging to someone
# else is left exactly where it is -- the mirror of the install path refusing to overwrite it.
if [ "${1:-}" = "--uninstall" ]; then
  DEST="${2:-$HOME/.local/bin}"
  removed=0; skipped=0
  for t in $TOOLS; do
    [ -L "$DEST/$t" ] || { [ -e "$DEST/$t" ] && { echo "  kept     $DEST/$t (not a symlink — not ours)"; skipped=$((skipped+1)); }; continue; }
    target=$(readlink "$DEST/$t")
    case "$target" in
      "$SRC/$t") rm -f "$DEST/$t"; echo "  removed  $DEST/$t"; removed=$((removed+1)) ;;
      *) echo "  kept     $DEST/$t -> $target (points at a different clone)"; skipped=$((skipped+1)) ;;
    esac
  done
  echo
  echo "$removed removed, $skipped left alone."
  echo
  echo "NOT removed, because they may hold things you want — check them by hand:"
  echo "  $QUORUM_ENVFILE_SHORT        a PATH line, and possibly an exported API key"
  echo "  ~/.config/quorum/            endpoint presets"
  echo "  ~/.claude/agents, skills, commands/quorum   if you copied them there"
  echo
  echo "This clone is still at $SRC — delete it separately if you want it gone."
  exit 0
fi

mkdir -p "$DEST"

# Warn if these symlinks already point at a DIFFERENT clone. Silently repointing them is
# how you end up with eight dangling commands on PATH after deleting a throwaway clone.
existing=$(readlink "$DEST/quorum-verify" 2>/dev/null || true)
case "$existing" in
  ""|"$SRC/quorum-verify") ;;
  *) printf '  NOTE  re-pointing an existing install:\n        was %s\n        now %s\n\n' \
       "$(dirname "$existing")" "$SRC" ;;
esac

# `ln -sf` over a REGULAR file deletes it without a word. Eight of these names are generic
# -- prep-image, make-probe-image -- and the documented `./scripts/install.sh /usr/local/bin`
# form aims them at a shared directory. Measured: a user's own ~/.local/bin/quorum-status was
# replaced, its contents unrecoverable, with no warning of any kind in the output. The NOTE
# above did not fire because `readlink` fails on a regular file, so `existing` was empty and
# matched the "" case.
#
# Refuse instead. Destroying a file someone wrote is not a reasonable default, and there is
# no way to undo it afterwards.
clobber=0
for t in $TOOLS; do
  if [ ! -f "$SRC/$t" ]; then echo "  MISSING  $t (skipped)"; continue; fi
  if [ -e "$DEST/$t" ] && [ ! -L "$DEST/$t" ]; then
    printf '  REFUSED  %s already exists and is not a symlink\n' "$DEST/$t"
    printf '           it is not ours to overwrite. Move or delete it, then re-run.\n'
    clobber=1
    continue
  fi
  chmod +x "$SRC/$t"
  ln -sf "$SRC/$t" "$DEST/$t"
  echo "  linked   $DEST/$t"
done

echo
# Print the command in the SYNTAX of the target file, and create its directory. quorum-lib.sh
# resolves QUORUM_ENVFILE_SYNTAX and says "callers that WRITE must check this" -- this caller
# did not. On fish the target is ~/.config/fish/conf.d/quorum.fish, a directory that does not
# exist on a machine where fish has never written a config, so the printed command failed
# outright: "No such file or directory", rc=1. It also printed posix `export` immediately
# above a sentence explaining that fish wants `set -gx`.
case ":$PATH:" in
  *":$DEST:"*) echo "$DEST is already on PATH." ;;
  *)
    if [ "$QUORUM_ENVFILE_SYNTAX" = fish ]; then
      cat <<EOM
$DEST is NOT on PATH. Add it in $QUORUM_ENVFILE_SHORT:

  mkdir -p $(dirname "$QUORUM_ENVFILE")
  echo 'fish_add_path $DEST' >> $QUORUM_ENVFILE

$QUORUM_ENVFILE_WHY.
EOM
    else
      cat <<EOM
$DEST is NOT on PATH. Add it in $QUORUM_ENVFILE_SHORT:

  mkdir -p $(dirname "$QUORUM_ENVFILE")
  echo 'export PATH="$DEST:\$PATH"' >> $QUORUM_ENVFILE

$QUORUM_ENVFILE_WHY.
EOM
    fi
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

# A refused link means the install is INCOMPLETE. Exiting 0 here would be the same defect
# as every other one this repo has fixed: a partial result reported as success.
if [ "$clobber" != 0 ]; then
  echo
  echo "install.sh: one or more commands were NOT installed (see REFUSED above)." >&2
  exit 1
fi
