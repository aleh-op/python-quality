#!/usr/bin/env bash
# tools.sh install | check — get a consumer to the point where the gate runs.
#
# Nothing is installed globally, on purpose: ruff, pyrefly and pytest are the
# consumer's dev dependencies, pinned by its own uv.lock. A global copy would
# mean the gate runs a different version than CI and the editor do. uv itself
# is the one host prerequisite, and dotfiles provisions it.
#
# `install` is `uv sync`, with two flags that matter:
#   * --locked: a stale lock is an error, never a silent re-lock.
#   * --inexact: a plain sync REMOVES every package outside the synced groups,
#     so a repo with a `notebook` group would lose jupyter each time this ran.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
. "$HERE/lib.sh"

case "${1:-check}" in
install)
  command -v uv >/dev/null 2>&1 || { echo "✗ uv is not on PATH — provision dotfiles (components/languages)" >&2; exit 1; }
  [ -f pyproject.toml ] || { echo "✗ no pyproject.toml here" >&2; exit 1; }
  if [ ! -f uv.lock ]; then
    # `--locked` requires a lockfile. Saying so beats uv's raw error.
    echo "  (no uv.lock — running 'uv lock' to create one; commit it)"
    uv lock
  fi
  echo "→ uv sync --locked --inexact"
  uv sync --locked --inexact
  echo
  echo "✓ installed. Optional, on demand (uvx, nothing added to the lock):"
  echo "    uvx deptry .                     unused / missing / transitive dependencies"
  echo "    uvx vulture --min-confidence 80  cross-module dead code"
  ;;
check)
  missing=0
  if command -v uv >/dev/null 2>&1; then printf '  ✓ uv (%s)\n' "$(uv --version | awk '{print $2}')"
  else printf '  ✗ uv — MISSING\n'; exit 1; fi
  # Asked through the project env, offline: the real question is "is it in
  # THIS project's environment at the version the lockfile pins".
  for t in ruff pyrefly pytest; do
    if v="$(uvr "$t" --version 2>/dev/null)"; then printf '  ✓ %s\n' "$v"
    else printf '  ✗ %s — not in the project env (dev group + scripts/tools.sh install)\n' "$t"; missing=$((missing + 1)); fi
  done
  [ "$missing" -eq 0 ] || { echo; echo "$missing missing. Run: scripts/tools.sh install"; exit 1; }
  ;;
*)
  echo "usage: tools.sh [install|check]" >&2; exit 2 ;;
esac
