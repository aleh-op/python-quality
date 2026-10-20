#!/usr/bin/env bash
# gate.sh — the quality gate. `gate.sh fast` before a commit, `gate.sh full`
# before a push. First failure stops the run.
#
# There is no per-command wrapper here. ruff, pyrefly and pytest already are
# the interface; wrapping one `uv run` in YAML adds a file and removes nothing.
# What this script owns is the part they cannot express: ordering, fail-fast,
# and the gotchas that pass silently otherwise —
#
#   * `uv run` without --locked re-locks silently and can reach the network,
#     so the gate could run a ruff the lockfile never pinned -> uvr in lib.sh
#   * pyrefly hides warn-level kinds by default AND exits 0 on them. Every
#     invocation carries --min-severity warn
#   * ruff checks a file passed by name even when the config excludes it;
#     --force-exclude makes the staged path honour `extend-exclude`
#   * pytest exits 5 when it collects nothing; that is not a failing suite
#   * a consumer `lint.select` replaces the base selection -> config-check
#   * agent residue is invisible to ruff -> ai-lint
#
# Tool output is sent to STDERR. provision's failure view shows a step's
# stderr and not its stdout, so a ruff report on stdout produced "gate failed"
# with no findings above it (ts-quality's lesson). Progress lines stay on stdout.
#
# Knobs: CAP_LOC (500), RUFF_ARGS, PYREFLY_ARGS, PYTEST_ARGS, PQ_AUDIT (1).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
. "$HERE/lib.sh"

MODE="${1:-full}"

# Gate the project the caller is standing in — `dir` is a `cd` before this
# script runs, and an unconditional jump to the toplevel would undo it. Falling
# back to the toplevel keeps "run it from anywhere" in a single-project repo.
if [ ! -f pyproject.toml ]; then
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] && cd "$top"
fi
[ -f pyproject.toml ] || { echo "✗ no pyproject.toml here or at the repo root" >&2; exit 1; }
command -v uv >/dev/null 2>&1 || { echo "✗ uv is not on PATH — it is provisioned by dotfiles (components/languages)" >&2; exit 1; }

step() { printf '[%s/%s] %s\n' "$1" "$TOTAL" "$2"; }

# render <title> — lib.sh records on stdin -> an indented human report.
# Never call through a pipe: a pipeline subshell discards FAILED=1 and the
# gate would exit 0 while printing error-level findings. Process substitution
# keeps it in this shell.
render() {
  # The optional sixth field (`key`) is read into `_` so it is not appended
  # to `msg`; it only disambiguates fingerprints downstream.
  local n=0 rule level path lineno msg
  while IFS=$'\t' read -r rule level path lineno msg _; do
    printf '  %s:%s: %s: %s\n' "$path" "$lineno" "$rule" "$msg" >&2
    n=$((n + 1))
    [ "$level" = "error" ] && FAILED=1
  done
  if [ "$n" -eq 0 ]; then printf '  ✓ %s: clean\n' "$1" >&2; fi
}
FAILED=0

# Three different failures share exit 1, and each has a different remedy. uv
# says which in its message; the message is the only thing that tells them
# apart. "Could not answer offline" fails too — a gate that cannot answer must
# not pass — but it must not tell anyone their lockfile is stale.
lock_check() {
  local out
  if out="$(uv lock --check --offline 2>&1)"; then echo "  ✓ in sync"; return 0; fi
  case "$out" in
    *"Unable to find lockfile"*)
      echo "  ✗ no uv.lock — run 'uv lock', commit it" >&2 ;;
    *"needs to be updated"*)
      echo "  ✗ pyproject.toml and uv.lock disagree — run 'uv lock', stage uv.lock" >&2 ;;
    *"network was disabled"*)
      echo "  ✗ cannot verify uv.lock offline — a dependency's metadata is not in uv's cache." >&2
      echo "    Run 'uv lock' once with network; the gate stays offline." >&2 ;;
    *)
      echo "  ✗ uv lock --check failed:" >&2; printf '%s\n' "$out" | sed 's/^/    /' >&2 ;;
  esac
  exit 1
}

# shellcheck disable=SC2086  # *_ARGS are flag lists, split on purpose
ruff_fmt()  { uvr ruff format --check --force-exclude "$@" 1>&2 || { echo "  ✗ fix with: uv run ruff format" >&2; exit 1; }; }
# shellcheck disable=SC2086
ruff_lint() { uvr ruff check --force-exclude ${RUFF_ARGS:-} "$@" 1>&2; }
# shellcheck disable=SC2086
typecheck() { uvr pyrefly check --min-severity warn --summary=none ${PYREFLY_ARGS:-} 1>&2; }

# A read loop, not mapfile: bash 3.2.
staged=()
collect_staged() {
  local f
  while IFS= read -r f; do [ -n "$f" ] && staged+=("$f"); done < <(staged_py)
}

case "$MODE" in
# ── fast: pre-commit. No test suite, no network. ─────────────────────────────
fast)
  TOTAL=6
  step 1 "uv.lock (drift)"
  lock_check

  collect_staged
  step 2 "ruff format --check (staged)"
  if [ "${#staged[@]}" -eq 0 ]; then echo "  (no staged .py files)"; else ruff_fmt -- "${staged[@]}"; fi

  step 3 "ruff check (staged)"
  if [ "${#staged[@]}" -eq 0 ]; then echo "  (no staged .py files)"; else ruff_lint -- "${staged[@]}"; fi

  # The whole project, not the staged files: a type error is a property of
  # the call site AND the definition, and the staged half is not enough.
  step 4 "pyrefly"
  typecheck

  step 5 "ai-lint (staged)"
  if [ "${#staged[@]}" -eq 0 ]; then echo "  (no staged .py files)"; else
    render "ai-lint" < <(ai_lint "${staged[@]}")
  fi

  step 6 "soft caps"
  render "soft caps" < <(god_files)
  ;;

# ── full: pre-push. ─────────────────────────────────────────────────────────
full)
  TOTAL=10
  step 1 "uv.lock (drift)"
  lock_check

  step 2 "ruff format --check"
  ruff_fmt .

  step 3 "ruff check"
  ruff_lint .

  step 4 "pyrefly"
  typecheck

  # Exit 5 is "collected nothing". A project that has not written its first
  # test yet is told so, not failed — the step asks whether the tests pass,
  # and vacuously they do. rust-quality made the same call with nextest's
  # `--no-tests=warn`. 1-4 are real failures (tests, interrupt, internal, usage).
  step 5 "pytest"
  rc=0
  # shellcheck disable=SC2086
  uvr pytest ${PYTEST_ARGS:-} 1>&2 || rc=$?
  case "$rc" in
    0) ;;
    5) echo "  (no tests collected — pytest exit 5, not a failure)" ;;
    *) echo "  ✗ pytest exited $rc" >&2; exit 1 ;;
  esac

  step 6 "config drift"
  bash "$HERE/config-check.sh"

  step 7 "supply chain"
  bash "$HERE/supply-chain.sh"

  step 8 "audit"
  bash "$HERE/audit.sh"

  # Over tracked files, not staged: `fast` only sees a staged diff, so a
  # --no-verify commit, an amend, a rebase or a merge walks agent residue
  # straight past the only error-level rules here.
  step 9 "ai-lint (tracked)"
  render "ai-lint" < <(tracked_py | while IFS= read -r f; do ai_lint "$f"; done)

  step 10 "soft caps"
  render "soft caps" < <(god_files)
  ;;

*)
  echo "usage: gate.sh [fast|full]" >&2; exit 2 ;;
esac

[ "$FAILED" -eq 0 ] || { echo; echo "✗ gate failed on the findings above." >&2; exit 1; }
echo
if [ "$MODE" = "fast" ]; then
  echo "✓ fast checks green — full gate runs on push."
else
  echo "✓ all checks green — safe to push."
fi
