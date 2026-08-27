#!/usr/bin/env bash
# quorum-lib.sh — platform facts every Quorum script needs, resolved once.
#
# SOURCED, never executed. It is deliberately not symlinked onto PATH by install.sh.
#
# Why this file exists: a clean-Debian install run found that Quorum told a bash user to put
# their PATH in `~/.zshenv` (never read by bash, and zsh was not installed) and told them to
# fix missing prerequisites with `brew install` (macOS only). Worse, `quorum-auth --set-key`
# WROTE the API key to `~/.zshenv`, reported success, and produced a key no shell on that
# machine would ever load.
#
# The same fact lived in fifteen places. Putting it in one place is the point.

# --- Where does an exported variable have to go to reach a non-interactive shell? --------
#
# This is the question that matters, because agents and scripts get non-interactive shells.
# The answer is genuinely different per shell, so this is not a filename swap:
#
#   zsh  — reads ~/.zshenv for EVERY invocation, interactive or not, and skips ~/.zshrc when
#          non-interactive. On macOS this matters doubly: GUI-launched apps never go through
#          a login shell at all, so ~/.zprofile would not be read either.
#   bash — reads NOTHING per-invocation when non-interactive (only $BASH_ENV, unset by
#          default). What works is a LOGIN file: read once at login and *exported*, so every
#          child process, including agents, inherits it. ~/.bashrc is the common guess and it
#          is wrong here — non-interactive bash skips it. Which login file is not fixed: bash
#          reads the FIRST of ~/.bash_profile, ~/.bash_login, ~/.profile that exists and then
#          STOPS, so the answer has to be resolved against the filesystem, not hardcoded.
case "$(basename "${SHELL:-/bin/sh}")" in
  zsh)
    QUORUM_ENVFILE="${ZDOTDIR:-$HOME}/.zshenv"
    QUORUM_ENVFILE_SHORT="~/.zshenv"
    QUORUM_ENVFILE_WHY="~/.zshenv, not ~/.zshrc — zsh reads .zshenv on every invocation, and skips .zshrc when non-interactive, which is what agents get"
    ;;
  bash)
    # bash reads the FIRST of ~/.bash_profile, ~/.bash_login, ~/.profile that EXISTS, and
    # then stops. Hardcoding ~/.profile therefore recreates, for bash users, precisely the
    # bug this file was written to eliminate: the write succeeds, the shell never reads it.
    #
    # Not a corner case. ~/.bash_profile is created by nvm, rvm, conda, pyenv and
    # Homebrew-on-Linux, so most developer machines have one — including this author's,
    # which has ~/.bash_profile and no ~/.profile at all. Measured with both present:
    # `bash -lc` reports the value from .bash_profile and never reads .profile.
    QUORUM_ENVFILE=""
    for _q_f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
      if [ -f "$_q_f" ]; then QUORUM_ENVFILE="$_q_f"; break; fi
    done
    # If none exists, create ~/.profile — bash reads it when the other two are absent.
    [ -n "$QUORUM_ENVFILE" ] || QUORUM_ENVFILE="$HOME/.profile"
    unset _q_f
    QUORUM_ENVFILE_SHORT="~/$(basename "$QUORUM_ENVFILE")"
    QUORUM_ENVFILE_WHY="$QUORUM_ENVFILE_SHORT, not ~/.bashrc — non-interactive bash reads neither, but a login file is exported at login so child processes and agents inherit it; bash reads only the FIRST of .bash_profile, .bash_login, .profile that exists"
    ;;
  fish)
    # fish does not read ~/.profile, so POSIX login files are the wrong target. It DOES
    # understand `export X=y` -- fish ships an `export` function at
    # /usr/share/fish/functions/export.fish, and a posix export line written into a
    # conf.d file was measured working: `fish -c 'command -v quorum-verify'` resolved it,
    # rc=0. An earlier version of this comment asserted fish "cannot parse export X=y",
    # which is simply false, and the repo's own rule is that a wrong explanation beside
    # working code still has to be corrected.
    #
    # `set -gx` and `fish_add_path` remain what we emit, because they are fish's idiom --
    # not because the alternative fails.
    QUORUM_ENVFILE="$HOME/.config/fish/conf.d/quorum.fish"
    QUORUM_ENVFILE_SHORT="~/.config/fish/conf.d/quorum.fish"
    QUORUM_ENVFILE_WHY="fish does not read ~/.profile — use a file under ~/.config/fish/conf.d/, which fish sources for every shell. \`fish_add_path\` and \`set -gx NAME value\` are fish's idiom (it does also understand \`export\`, via a shipped function)"
    QUORUM_ENVFILE_SYNTAX="fish"
    ;;
  *)
    # ash, dash, ksh and anything else POSIX-ish. ~/.profile is the portable answer; say it
    # is a best guess rather than asserting a file that may never be read.
    QUORUM_ENVFILE="$HOME/.profile"
    QUORUM_ENVFILE_SHORT="~/.profile"
    QUORUM_ENVFILE_WHY="~/.profile is the portable choice; if your shell does not read it, use whichever file it loads for NON-interactive shells"
    ;;
esac
# Callers that WRITE must check this: anything other than "posix" means `export X=y` is
# wrong syntax for the target file.
QUORUM_ENVFILE_SYNTAX="${QUORUM_ENVFILE_SYNTAX:-posix}"

# --- How does this machine install a package? --------------------------------------------
# Detect by what is present, not by uname: a Mac can have no Homebrew, and a container can
# be any distro. Falls back to a visible placeholder rather than a command that will fail.
# `sudo` is conditional, and getting this wrong is worse than omitting it. In a container
# the user is usually root and `sudo` is not installed at all, so a hardcoded `sudo apt-get`
# fails with "sudo: command not found" — which sends the reader hunting for the wrong
# problem. Measured on debian:stable-slim: id -u = 0, no sudo binary, and the bare command
# works. If we are not root and sudo is genuinely missing, print the bare command anyway:
# "permission denied" is at least an accurate error the reader can act on.
if [ "$(id -u 2>/dev/null || echo 1)" = 0 ] || ! command -v sudo >/dev/null 2>&1; then
  _q_sudo=""
else
  _q_sudo="sudo "
fi

if   command -v brew    >/dev/null 2>&1; then QUORUM_PKG_INSTALL="brew install"
elif command -v apt-get >/dev/null 2>&1; then QUORUM_PKG_INSTALL="${_q_sudo}apt-get install -y"
elif command -v dnf     >/dev/null 2>&1; then QUORUM_PKG_INSTALL="${_q_sudo}dnf install -y"
elif command -v pacman  >/dev/null 2>&1; then QUORUM_PKG_INSTALL="${_q_sudo}pacman -S --noconfirm"
elif command -v zypper  >/dev/null 2>&1; then QUORUM_PKG_INSTALL="${_q_sudo}zypper install -y"
elif command -v apk     >/dev/null 2>&1; then QUORUM_PKG_INSTALL="${_q_sudo}apk add"
else QUORUM_PKG_INSTALL="<your package manager> install"
fi
unset _q_sudo

# coreutils is the Homebrew package that provides timeout(1) on macOS. Everywhere else
# timeout(1) ships in coreutils already and the package name differs or is irrelevant.
if command -v brew >/dev/null 2>&1; then
  QUORUM_PKG_TIMEOUT="brew install coreutils"
else
  QUORUM_PKG_TIMEOUT="$QUORUM_PKG_INSTALL coreutils"
fi

export QUORUM_ENVFILE QUORUM_ENVFILE_SHORT QUORUM_ENVFILE_WHY QUORUM_ENVFILE_SYNTAX
export QUORUM_PKG_INSTALL QUORUM_PKG_TIMEOUT
