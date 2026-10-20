#!/usr/bin/env bash
# supply-chain.sh — is this project configured against 2026's PyPI threat model?
#
# An advisory database (audit.sh) knows about a malicious release only after
# someone reports it. Every 2026 PyPI compromise — LiteLLM 1.82.7/8, telnyx,
# xinference, lightning, mistralai 2.4.6, the "Hades" .pth wheels — was a
# fresh malicious version of a legitimate package, quarantined within hours to
# days. An audit run during that window is clean. Trusted publishing and PEP
# 740 attestations did not stop them either: the uploads came from hijacked,
# correctly attested workflows. Provenance proves origin, not innocence, so it
# is deliberately not checked here (ts-quality made the same call).
#
# What stops that class is a cooldown: uv's `exclude-newer` with a RELATIVE
# duration refuses anything published in the last N days. That is
# configuration, and configuration is what this reports on.
#
#   no-lockfile             no uv.lock — installs are unpinned (error)
#   no-release-cooldown     [tool.uv] exclude-newer unset (warning)
#   cooldown-absolute       exclude-newer is a fixed date: resolution is frozen
#                           in time and security fixes never arrive (warning)
#   release-cooldown-short  relative cooldown below MIN_RELEASE_AGE days (note)
#   unsafe-index-strategy   index-strategy = unsafe-*: a name on a second index
#                           can shadow PyPI's — dependency confusion (warning)
#
# Reads pyproject.toml and a project-level uv.toml. A user-level
# ~/.config/uv/uv.toml is not read: what this repo pins is what CI gets.
#
# Usage:
#   bash scripts/supply-chain.sh                 # human report
#   bash scripts/supply-chain.sh --format jsonl  # structured findings
#   bash scripts/supply-chain.sh --warn-only     # always exit 0
#
# Knobs: MIN_RELEASE_AGE (3, days).
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
    -h|--help)   sed -n '2,32p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

WANT_AGE="${MIN_RELEASE_AGE:-3}" FORMAT="$FORMAT" WARN_ONLY="$WARN_ONLY" pq_py - <<'PY'
import json, os, pathlib, re, sys, tomllib

fmt       = os.environ["FORMAT"]
warn_only = os.environ["WARN_ONLY"] == "1"
want_age  = float(os.environ["WANT_AGE"])

def say(*a):
    print(*a, file=sys.stderr)

records = []
def rec(rule, level, path, line, message):
    records.append((rule, level, path, line, message))

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

# uv.toml takes precedence over [tool.uv] when both exist.
if pathlib.Path("uv.toml").is_file():
    upath, uv = "uv.toml", load("uv.toml") or {}
else:
    upath, uv = "pyproject.toml", ((load("pyproject.toml") or {}).get("tool") or {}).get("uv") or {}

UNIT_DAYS = {"second": 1 / 86400, "minute": 1 / 1440, "hour": 1 / 24, "day": 1, "week": 7}

def span_days(s):
    """Days in a relative exclude-newer, or None if it is not relative.
    uv takes `3 days`, `24 hours`, `1 week` and ISO 8601 `P3D` / `PT24H`."""
    s = s.strip()
    m = re.fullmatch(r"(\d+(?:\.\d+)?)\s*(second|minute|hour|day|week)s?", s, re.I)
    if m:
        return float(m[1]) * UNIT_DAYS[m[2].lower()]
    m = re.fullmatch(r"P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?", s, re.I)
    if m and any(m.groups()):
        w, d, h, mi, se = (int(x or 0) for x in m.groups())
        return w * 7 + d + h / 24 + mi / 1440 + se / 86400
    return None

en = uv.get("exclude-newer")
line = line_of(upath, r"^\s*exclude-newer\s*=")
if not en:
    rec("no-release-cooldown", "warning", upath, 1,
        f'exclude-newer is unset — add `exclude-newer = "{want_age:g} days"` under [tool.uv] '
        "so a version published minutes ago cannot be locked")
else:
    days = span_days(str(en))
    if days is None:
        rec("cooldown-absolute", "warning", upath, line,
            f'exclude-newer = "{en}" is a fixed date — resolution is frozen and fixes never arrive; '
            f'use a relative span such as "{want_age:g} days"')
    elif days < want_age:
        rec("release-cooldown-short", "note", upath, line,
            f"exclude-newer is {days:g} days, below the fleet default of {want_age:g}")

strategy = str(uv.get("index-strategy") or "")
if strategy.startswith("unsafe"):
    rec("unsafe-index-strategy", "warning", upath, line_of(upath, r"^\s*index-strategy\s*="),
        f'index-strategy = "{strategy}" lets a second index shadow a PyPI name — dependency confusion')

if not pathlib.Path("uv.lock").is_file():
    rec("no-lockfile", "error", "uv.lock", 1, "no uv.lock — installs are unpinned; run `uv lock` and commit it")

if fmt == "jsonl":
    for rule, level, path, line, message in records:
        print(json.dumps({
            "tool": "supply-chain", "rule": rule, "level": level, "path": path,
            "line": line, "message": message,
            "fingerprint": f"{rule}:{path}:{line}",
        }, separators=(",", ":")))
else:
    if not records:
        say("  ✓ supply-chain: cooldown set, lockfile present")
    for rule, level, path, line, message in records:
        say(f"  {path}:{line}: {rule}: {message}")

if warn_only:
    sys.exit(0)
sys.exit(1 if any(r[1] == "error" for r in records) else 0)
PY
