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
#          default). What actually works is ~/.profile: read once at login and *exported*,
#          so every child process, including agents, inherits it. ~/.bashrc is the common
#          guess and it is wrong here — non-interactive bash skips it.
case "$(basename "${SHELL:-/bin/sh}")" in
  zsh)
    QUORUM_ENVFILE="${ZDOTDIR:-$HOME}/.zshenv"
    QUORUM_ENVFILE_SHORT="~/.zshenv"
    QUORUM_ENVFILE_WHY="~/.zshenv, not ~/.zshrc — zsh reads .zshenv on every invocation, and skips .zshrc when non-interactive, which is what agents get"
    ;;
  bash)
    QUORUM_ENVFILE="$HOME/.profile"
    QUORUM_ENVFILE_SHORT="~/.profile"
    QUORUM_ENVFILE_WHY="~/.profile, not ~/.bashrc — non-interactive bash reads neither, but .profile is exported at login so child processes and agents inherit it"
    ;;
  *)
    # ash, dash, fish, ksh and anything else. ~/.profile is the portable answer for the
    # POSIX-ish ones; say so rather than guessing confidently at a file that may not exist.
    QUORUM_ENVFILE="$HOME/.profile"
    QUORUM_ENVFILE_SHORT="~/.profile"
    QUORUM_ENVFILE_WHY="~/.profile is the portable choice; if your shell does not read it, use whichever file it loads for NON-interactive shells"
    ;;
esac

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

export QUORUM_ENVFILE QUORUM_ENVFILE_SHORT QUORUM_ENVFILE_WHY
export QUORUM_PKG_INSTALL QUORUM_PKG_TIMEOUT
