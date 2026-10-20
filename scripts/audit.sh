#!/usr/bin/env bash
# audit.sh — known-vulnerability check over the locked dependency tree.
#
# pip-audit (PyPA), run through `uvx` at a version pinned HERE, not in the
# consumer's lock: it carries ~15 transitive dependencies nobody wants in every
# project's environment, and it needs the network anyway. Its limits are real
# and stated rather than discovered:
#
#   * it needs the NETWORK — the advisory database is PyPI's JSON API. An
#     unreachable database is reported as a note and does not fail the gate:
#     it is an unknown, and failing a push on an unknown trains people to
#     reach for --no-verify. A real advisory does fail it.
#   * it cannot read uv.lock. `uv export` turns the lock into the requirements
#     list it can read, `--frozen` so the export never re-resolves.
#   * it matches versions against advisories. It cannot see a fresh malicious
#     release; supply-chain.sh's cooldown is the defence there.
#   * PyPI advisories carry no severity, so there is no level threshold: any
#     advisory fails. AUDIT_IGNORE is the escape hatch, by ID, with a reason
#     written wherever the knob is set.
#
# `uv audit` would remove the pin and the export; it is still preview
# (`--preview-features audit-command`) as of uv 0.13.4. Switch when it is not.
#
# Usage:
#   bash scripts/audit.sh                 # human report
#   bash scripts/audit.sh --format jsonl  # structured findings
#   bash scripts/audit.sh --warn-only     # always exit 0
#
# Knobs: PQ_AUDIT (1; 0 skips), AUDIT_OMIT_DEV (1), AUDIT_IGNORE (space-separated IDs).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
. "$HERE/lib.sh"

PIP_AUDIT_VERSION="2.10.1"

FORMAT="text"
WARN_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --format)    FORMAT="${2:-}"; shift 2 ;;
    --format=*)  FORMAT="${1#*=}"; shift ;;
    --warn-only) WARN_ONLY=1; shift ;;
    -h|--help)   sed -n '2,29p' "$0"; exit 0 ;;
    *) shift ;;
  esac
done

if [ "${PQ_AUDIT:-1}" = "0" ]; then
  [ "$FORMAT" = "text" ] && echo "  (audit disabled — PQ_AUDIT=0)" >&2
  exit 0
fi

exported="$(mktemp)"; req="$(mktemp)"; raw="$(mktemp)"; cache="$(mktemp -d)"
trap 'rm -rf "$exported" "$req" "$raw" "$cache"' EXIT

export_args=(export --frozen --format requirements-txt --no-hashes --no-emit-project --quiet)
[ "${AUDIT_OMIT_DEV:-1}" = "1" ] && export_args+=(--no-dev)

# STATE says which of four things happened, so none of them can read as
# another: nolock, exportfail, empty (nothing on PyPI to look up), ran.
# Export is buffered to a file, not piped into the filter: a pipeline would
# report grep's status, and a failed export would read as "no dependencies".
if [ ! -f uv.lock ]; then
  STATE=nolock
elif ! uv "${export_args[@]}" >"$exported" 2>/dev/null; then
  STATE=exportfail
else
  # Path and editable dependencies are not on PyPI; there is nothing to look
  # up and pip-audit errors on the line. Only `name==version` lines are kept.
  grep -E '^[A-Za-z0-9._-]+(\[[^]]*\])?==' "$exported" >"$req" || true
  if [ -s "$req" ]; then STATE=ran; else STATE=empty; fi
fi

ignore=()
for id in ${AUDIT_IGNORE:-}; do ignore+=(--ignore-vuln "$id"); done

# Buffered, not piped: pip-audit exits 1 BOTH for an advisory and for an
# unreachable database, and those must not be the same verdict. The JSON body
# is what tells them apart. The cooldown applies to the audit tool's own
# dependency resolution too — it is code we run.
#
# A fresh --cache-dir every run: by default pip-audit answers from pip's HTTP
# cache, so a run with no network replayed yesterday's advisories and called
# it a result. Every run here is a live answer or an explicit "not checked".

if [ "$STATE" = ran ]; then
  uvx --quiet --exclude-newer "${MIN_RELEASE_AGE:-3} days" --from "pip-audit==$PIP_AUDIT_VERSION" \
    pip-audit --no-deps --disable-pip --progress-spinner off --format json --cache-dir "$cache" \
    ${ignore[@]+"${ignore[@]}"} -r "$req" >"$raw" 2>/dev/null || true
fi

STATE="$STATE" FORMAT="$FORMAT" WARN_ONLY="$WARN_ONLY" RAW="$raw" pq_py - <<'PY'
import json, os, pathlib, sys

fmt, state = os.environ["FORMAT"], os.environ["STATE"]
warn_only  = os.environ["WARN_ONLY"] == "1"
raw        = pathlib.Path(os.environ["RAW"]).read_text().strip()

records = []
def rec(rule, lvl, message, key=""):
    records.append((rule, lvl, "uv.lock", 1, message, key))

if state == "nolock":
    rec("audit-unavailable", "note", "no uv.lock — nothing pinned to audit (supply-chain reports it)")
elif state == "exportfail":
    rec("audit-failed", "error", "`uv export --frozen` failed — uv.lock is unreadable; advisories NOT checked")
elif state == "ran":
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        data = None
    # No parseable report means pip-audit never reached its database (or uvx
    # never reached PyPI to fetch pip-audit). That is "not checked", and it is
    # said out loud — never rendered as "no advisories".
    if not isinstance(data, dict) or "dependencies" not in data:
        rec("audit-unavailable", "note",
            "pip-audit could not reach PyPI — advisories NOT checked this run")
    else:
        for dep in data["dependencies"]:
            # pip-audit 2.10.1 lists every advisory twice in its JSON
            # (measured on idna 3.6); one advisory is one finding.
            seen = set()
            for v in dep.get("vulns") or []:
                if v["id"] in seen:
                    continue
                seen.add(v["id"])
                fixes = v.get("fix_versions") or []
                remedy = f"fixed in {', '.join(fixes)}" if fixes else "no fix released"
                aliases = ", ".join(v.get("aliases") or [])
                rec("vulnerable-dep", "error",
                    f"{dep['name']} {dep.get('version', '?')}: {v['id']}"
                    + (f" ({aliases})" if aliases else "") + f" — {remedy}",
                    f"{dep['name']}:{v['id']}")

if fmt == "jsonl":
    for rule, lvl, path, line, message, key in records:
        print(json.dumps({
            "tool": "pip-audit", "rule": rule, "level": lvl, "path": path,
            "line": line, "message": message,
            "fingerprint": f"{rule}:{path}:{line}" + (f":{key}" if key else ""),
        }, separators=(",", ":")))
else:
    if not records:
        print("  ✓ audit: no known advisories" if state == "ran"
              else "  ✓ audit: no PyPI dependencies to audit", file=sys.stderr)
    for rule, lvl, path, line, message, _ in records:
        print(f"  {path}:{line}: {rule}: {message}", file=sys.stderr)
    errs = sum(1 for r in records if r[1] == "error")
    if errs:
        print(f"  ✗ {errs} advisory(ies)", file=sys.stderr)

if warn_only:
    sys.exit(0)
sys.exit(1 if any(r[1] == "error" for r in records) else 0)
PY
