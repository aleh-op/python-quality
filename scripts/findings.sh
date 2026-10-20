#!/usr/bin/env bash
# findings.sh — the agent-facing view: every finding as one JSON object per
# line, in the shared fleet schema.
#
#   {"tool":..,"rule":..,"level":"error|warning|note","path":..,"line":N,
#    "col":N?,"message":..,"fingerprint":"rule:path:line[:key]"}
#
# gate.sh renders the same checks for humans from the same functions in lib.sh.
# A pure producer: it never re-gates and never aborts on a finding. Dedup
# across runs via `fingerprint`.
#
# ruff and pyrefly both have native JSON reporters, so nothing here parses
# human output. pyrefly is asked at `--min-severity info`: this is a producer,
# and a kind's severity is data to pass through, not a verdict. A tool that
# exits non-zero WITHOUT a report gets an explicit `*-failed` record — a run
# that could not check must never read as a run that found nothing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
. "$HERE/lib.sh"

OUT="${1:-}"

if [ ! -f pyproject.toml ]; then
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] && cd "$top"
fi

emit() {  # stdin: lib.sh records -> stdout: JSONL
  pq_py -c '
import json, sys
for raw in sys.stdin:
    parts = raw.rstrip("\n").split("\t")
    if len(parts) < 5:
        continue
    rule, level, path, line, message = parts[:5]
    key = parts[5] if len(parts) > 5 else ""
    print(json.dumps({
        "tool": "pq", "rule": rule, "level": level, "path": path,
        "line": int(line), "message": message,
        "fingerprint": f"{rule}:{path}:{line}" + (f":{key}" if key else ""),
    }, separators=(",", ":")))'
}

# tool_findings <tool> <step> <json-file> <rc> — a native JSON report -> JSONL.
# `step` names the invocation in a `-failed` record, so `ruff check` and
# `ruff format` failing in one run do not collide on one fingerprint.
tool_findings() {
  ROOT="$(pwd)" pq_py - "$@" <<'PY'
import json, os, sys
tool, step, path, rc = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
root = os.environ["ROOT"]

def rel(p):
    return os.path.relpath(p, root) if os.path.isabs(p) else p

def out(rule, level, p, line, message, col=None):
    r = {"tool": tool, "rule": rule, "level": level, "path": p, "line": line,
         "message": message, "fingerprint": f"{rule}:{p}:{line}"}
    if col:
        r["col"] = col
    print(json.dumps(r, separators=(",", ":")))

try:
    data = json.load(open(path))
except (json.JSONDecodeError, OSError):
    data = None

if tool == "ruff" and isinstance(data, list):
    for d in data:
        loc = d.get("location") or {}
        # ruff has no warning tier: every selected rule is an error.
        out(d.get("code") or "ruff", "error", rel(d["filename"]), loc.get("row") or 1,
            d.get("message") or "", loc.get("column"))
elif tool == "pyrefly" and isinstance(data, dict) and "errors" in data:
    sev = {"error": "error", "warn": "warning", "info": "note"}
    for e in data["errors"]:
        out(e.get("name") or "pyrefly", sev.get(e.get("severity"), "note"), rel(e["path"]),
            e.get("line") or 1, e.get("concise_description") or e.get("description") or "",
            e.get("column"))
elif rc != 0:
    # Most often uv, not the tool: `uv run --locked` refuses a stale uv.lock
    # and exits 1 before the tool starts — the same code as "found something".
    out(f"{step}-failed", "error", "pyproject.toml", 1,
        f"`{step}` exited {rc} without a report — stale uv.lock, env not synced, "
        "or a broken config; these findings are incomplete")
PY
}

# `ruff format --check` has the same JSON reporter as `ruff check` (one
# `unformatted` record per file), so both go through one parser. It replaced a
# scrape of "Would reformat:" lines, which ruff 0.17 no longer prints — that
# scrape matched nothing and the format leg reported clean on unformatted code.
ruff_findings() {
  local json rc
  json="$(mktemp)"
  rc=0; uvr ruff check --output-format json . >"$json" 2>/dev/null || rc=$?
  tool_findings ruff ruff-check "$json" "$rc"
  rc=0; uvr ruff format --check --output-format json . >"$json" 2>/dev/null || rc=$?
  tool_findings ruff ruff-format "$json" "$rc"
  rm -f "$json"
}

pyrefly_findings() {
  local json rc=0
  json="$(mktemp)"
  uvr pyrefly check --min-severity info --summary=none --output-format json >"$json" 2>/dev/null || rc=$?
  tool_findings pyrefly pyrefly "$json" "$rc"
  rm -f "$json"
}

# sub <name> — run one of our own checkers as a producer. `--warn-only` makes a
# clean run exit 0 whatever it found, so a non-zero exit here means the checker
# itself broke. Swallowing that with `|| true` once turned a crashed audit into
# "0 records" — a run that could not check reading as one that found nothing.
sub() {
  local rc=0
  bash "$HERE/$1.sh" --format jsonl --warn-only 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'pq-failed\terror\tpyproject.toml\t1\t%s.sh exited %d — its findings are missing from this file\t%s\n' "$1" "$rc" "$1" | emit
  fi
}

stream() {
  ruff_findings
  pyrefly_findings
  emit < <(tracked_py | while IFS= read -r f; do ai_lint "$f"; done; god_files)
  sub config-check
  sub supply-chain
  sub audit
}

if [ -n "$OUT" ]; then
  mkdir -p "$(dirname "$OUT")"
  stream > "$OUT"
  total=$(grep -c . "$OUT" 2>/dev/null || true)
  errs=$(grep -c '"level":"error"' "$OUT" 2>/dev/null || true)
  echo "findings: ${total:-0} total, ${errs:-0} error(s) -> $OUT" >&2
else
  stream
fi
