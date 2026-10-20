#!/usr/bin/env bash
# config-check — assert the consumer did not quietly weaken the shared config.
#
# ruff and pyrefly both extend a base file natively, so the baseline really is
# copied in and really does merge. That solves "did the copy drift" and creates
# a different problem: an extending config can OVERRIDE what it inherits, and
# two of those overrides are silent and total —
#
#   * a consumer `lint.select` REPLACES the base selection instead of adding to
#     it (ruff 0.17.1, verified). ruff then gates the consumer's list while
#     looking like it gates the baseline's.
#   * a consumer `preset = "basic"` under pyrefly silenced even
#     `bad-assignment`, exit 0 (pyrefly 1.4.0, verified).
#
# For ruff this asks the RESOLVED config, not the file text: `ruff check
# --show-settings` lists every enabled rule after `extend`, so the comparison
# is base-resolved vs consumer-resolved — the move ts-quality makes with
# `tsc --showConfig`. pyrefly has no equivalent (`dump-config` prints paths,
# not error kinds), so its half reads the consumer's own table, which is the
# only layer that can override the base.
#
#   ruff-not-extended      the active ruff config does not extend ruff.base.toml
#   ruff-select-override   the consumer uses `select`, which replaces the base
#   ruff-rule-dropped      a baseline rule is not enabled after resolution (warning)
#   ruff-unresolved        ruff could not resolve the config (not installed? broken?)
#   pyrefly-not-extended   the active pyrefly config does not extend pyrefly.base.toml
#   pyrefly-preset-override  the consumer sets `preset`
#   pyrefly-rule-off       the consumer turned an error kind off (warning)
#   base-copy-missing      ruff.base.toml / pyrefly.base.toml absent — run pq/sync-config
#   base-copy-stale        the copied base differs from this checkout's (warning)
#   dev-group-missing      ruff / pyrefly / pytest not in [dependency-groups] dev
#
# Usage:
#   bash scripts/config-check.sh                # human report
#   bash scripts/config-check.sh --format jsonl # structured findings
#   bash scripts/config-check.sh --warn-only    # always exit 0
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
. "$HERE/lib.sh"

FORMAT="text"
WARN_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --format)    FORMAT="${2:-}"; shift 2 ;;
    --format=*)  FORMAT="${1#*=}"; shift ;;
    --warn-only) WARN_ONLY=1; shift ;;
    -h|--help)   sed -n '2,36p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done
case "$FORMAT" in
  text|jsonl) ;;
  *) echo "config-check: unknown --format '$FORMAT' (want text|jsonl)" >&2; exit 2 ;;
esac

# Resolved rule sets, buffered to files: a pipeline would hide ruff's exit
# status, and "ruff is not installed" must not read the same as "clean". An
# empty file means "could not resolve"; python reports it as such.
BASE_SET="$(mktemp)"; CONS_SET="$(mktemp)"
trap 'rm -f "$BASE_SET" "$CONS_SET"' EXIT
uvr ruff check --config "$PQ_DIR/ruff.base.toml" --show-settings . >"$BASE_SET" 2>/dev/null || : >"$BASE_SET"
uvr ruff check --show-settings . >"$CONS_SET" 2>/dev/null || : >"$CONS_SET"

CANON_DIR="$PQ_DIR" BASE_SET="$BASE_SET" CONS_SET="$CONS_SET" \
FORMAT="$FORMAT" WARN_ONLY="$WARN_ONLY" pq_py - <<'PY'
import json, os, pathlib, re, sys, tomllib

fmt       = os.environ["FORMAT"]
warn_only = os.environ["WARN_ONLY"] == "1"
canon     = pathlib.Path(os.environ["CANON_DIR"])

# Always stderr: in jsonl mode stdout is the data, and in text mode this is
# a report of defects that provision's failure view only shows from stderr.
def say(*a):
    print(*a, file=sys.stderr)

records = []
def rec(rule, level, path, line, message, key=""):
    records.append((rule, level, path, line, message, key))

def line_of(path, pattern):
    try:
        for i, l in enumerate(pathlib.Path(path).read_text().splitlines(), 1):
            if re.search(pattern, l):
                return i
    except OSError:
        pass
    return 1

def load(path):
    try:
        return tomllib.loads(pathlib.Path(path).read_text())
    except (OSError, tomllib.TOMLDecodeError):
        return None

pyproject = load("pyproject.toml") or {}

def active(tool, standalone):
    """The file and table a tool actually reads. A standalone file wins over
    pyproject.toml for both ruff and pyrefly, so checking only [tool.x] would
    bless a pyproject the tool never looks at."""
    for name in standalone:
        if pathlib.Path(name).is_file():
            return name, load(name) or {}
    return "pyproject.toml", (pyproject.get("tool") or {}).get(tool)

def enabled(path):
    text = pathlib.Path(path).read_text()
    m = re.search(r"^linter\.rules\.enabled = \[(.*?)^\]", text, re.S | re.M)
    return set(re.findall(r"\(([A-Z]+[0-9]+)\)", m.group(1))) if m else None

# ── the copied bases ────────────────────────────────────────────────────────
for base in ("ruff.base.toml", "pyrefly.base.toml"):
    p = pathlib.Path(base)
    if not p.is_file():
        rec("base-copy-missing", "error", base, 1, "absent — run pq/sync-config", base)
    elif p.read_bytes() != (canon / base).read_bytes():
        rec("base-copy-stale", "warning", base, 1,
            "differs from the python-quality checkout — re-run pq/sync-config after a bump", base)

# ── ruff ────────────────────────────────────────────────────────────────────
rpath, rcfg = active("ruff", (".ruff.toml", "ruff.toml"))
if rcfg is None:
    rec("ruff-not-extended", "error", rpath, 1,
        'no [tool.ruff] — add `extend = "ruff.base.toml"`')
else:
    ext = rcfg.get("extend") or ""
    extended = pathlib.Path(ext).name == "ruff.base.toml"
    if not extended:
        rec("ruff-not-extended", "error", rpath, line_of(rpath, r"^\s*extend\s*=") ,
            'does not extend the baseline — set `extend = "ruff.base.toml"`')
    lint = rcfg.get("lint") or {}
    overridden = "select" in rcfg or "select" in lint
    if overridden:
        rec("ruff-select-override", "error", rpath, line_of(rpath, r"^\s*(lint\.)?select\s*="),
            "`select` REPLACES the baseline selection — use `extend-select` and `ignore`")
    base, cons = enabled(os.environ["BASE_SET"]) if os.path.getsize(os.environ["BASE_SET"]) else None, \
                 enabled(os.environ["CONS_SET"]) if os.path.getsize(os.environ["CONS_SET"]) else None
    if base is None or cons is None:
        rec("ruff-unresolved", "error", rpath, 1,
            "`ruff check --show-settings` failed — is ruff in the dev group and the env synced? (pq/tools)")
    elif extended and not overridden:
        # Per-rule drops only when they are the whole story. Without the
        # extend, or under a `select` override, nearly every baseline rule is
        # "dropped": measured, a `select = ["E", "F"]` produced ~400 records
        # and provision's failure view elided the one error that explained them.
        for code in sorted(base - cons):
            rec("ruff-rule-dropped", "warning", rpath, line_of(rpath, re.escape(code)),
                f"{code} is in the baseline but not enabled — record why next to the ignore", code)

# ── pyrefly ─────────────────────────────────────────────────────────────────
ppath, pcfg = active("pyrefly", ("pyrefly.toml",))
if pcfg is None:
    rec("pyrefly-not-extended", "error", ppath, 1,
        'no [tool.pyrefly] — add `extends = "pyrefly.base.toml"`')
else:
    if pathlib.Path(pcfg.get("extends") or "").name != "pyrefly.base.toml":
        rec("pyrefly-not-extended", "error", ppath, line_of(ppath, r"^\s*extends?\s*="),
            'does not extend the baseline — set `extends = "pyrefly.base.toml"`')
    if "preset" in pcfg:
        rec("pyrefly-preset-override", "error", ppath, line_of(ppath, r"^\s*preset\s*="),
            f'preset = "{pcfg["preset"]}" overrides the baseline\'s — remove it')
    # "info" is off too: the gate runs --min-severity warn, so an info-level
    # kind is never shown and never fails.
    for kind, val in (pcfg.get("errors") or {}).items():
        if val is False or val in ("ignore", "info"):
            rec("pyrefly-rule-off", "warning", ppath, line_of(ppath, rf"^\s*{re.escape(kind)}\s*="),
                f"{kind} = {json.dumps(val)} — the gate no longer sees it; record why", kind)

# ── the dev group ───────────────────────────────────────────────────────────
dev = (pyproject.get("dependency-groups") or {}).get("dev") or []
names = {re.split(r"[\s\[<>=!~;@]", d, maxsplit=1)[0].lower() for d in dev if isinstance(d, str)}
for tool in ("ruff", "pyrefly", "pytest"):
    if tool not in names:
        rec("dev-group-missing", "error", "pyproject.toml", line_of("pyproject.toml", r"^\s*dev\s*="),
            f"{tool} is not in [dependency-groups] dev — the gate runs it from the project env", tool)

# ── render ──────────────────────────────────────────────────────────────────
# Errors last: provision's failure view keeps the head and the TAIL of a long
# report, so the records that failed the gate belong where it looks.
records.sort(key=lambda r: r[1] == "error")
if fmt == "jsonl":
    for rule, level, path, line, message, key in records:
        print(json.dumps({
            "tool": "pq", "rule": rule, "level": level, "path": path,
            "line": line, "message": message,
            "fingerprint": f"{rule}:{path}:{line}" + (f":{key}" if key else ""),
        }, separators=(",", ":")))
else:
    if not records:
        say("  ✓ config-check: consumer config matches the baseline")
    for rule, level, path, line, message, _ in records:
        say(f"  {path}:{line}: {rule}: {message}")

if warn_only:
    sys.exit(0)
sys.exit(1 if any(r[1] == "error" for r in records) else 0)
PY
