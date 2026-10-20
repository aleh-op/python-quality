# python-quality — SPEC

v1, 2026-10-21. Decisions and evidence. The README describes what exists; this
records why, and what was measured to justify it.

## Goal

One canonical source for Python lint/format/type policy, the quality gate and
the supply-chain posture, consumed as a provision component set — so no Python
repo hand-rolls its own gate again (`autolab/tasks/ci-fast.yml` is the one
this replaces). The Python sibling of `rust-quality`, `go-quality` and
`ts-quality`, and deliberately the same shape.

## The governing decision

Inherited unchanged: **ship config, not command wrappers.**

ruff, pyrefly and pytest read their own config natively. So:

1. One invocation is a `uv run <tool>` the consumer types — not a component.
2. A component exists only for multi-step fail-fast ordering, or for copying
   config into a consumer.
3. JSON lives at one edge (`findings.sh`); `gate.sh` renders the same checks
   for humans from the same functions in `lib.sh`.
4. A check ruff already performs is not written twice: ERA001 owns
   commented-out code, so `lib.sh` has no `commented-out-code` rule
   (rust-quality had to write one in awk because clippy has none).
5. The gate runs no step whose work another step already did.

## Decisions taken (2026-10-21)

| # | Question | Decision | Why |
|---|---|---|---|
| Q1 | Where tool versions are pinned | **The consumer's `uv.lock`**, `dev` group | ts-quality's model. Gate, editor and CI run one version; nothing is installed on the host; uv is the only prerequisite and dotfiles already provisions it. |
| Q2 | Type checker | **pyrefly** | Stable since 1.0, native binary, `extends`, JSON; already in autolab. mypy has no `extends`; ty is beta. |
| Q2b | pyrefly baseline | **`default` + `implicit-any-parameter` + `implicit-any-type-argument` at error** | Measured below. `strict` is mostly ceremony; the noImplicitAny analog is what keeps Any out. |
| Q3 | Audit | **pip-audit 2.10.1 via `uvx`**, pinned in `audit.sh` | Stable PyPA tool; ~15 transitive deps stay out of consumer locks; needs the network anyway. `uv audit` is preview. |
| Q4 | Cooldown | **3 days**, `MIN_RELEASE_AGE` knob | Fleet consistency with ts-quality's `min-release-age=3`. |
| Q5 | Docs in v1 | **README + docs/STACK.md** | docs/PY.md (the RUST.md/TS.md analog) is a follow-up. |

Tool picks and every rejection, with versions: [docs/STACK.md](docs/STACK.md).

## Scope

In: lint + format, types, tests, lockfile drift, supply-chain posture,
advisory audit, agent residue, god-file cap, config drift, JSONL findings.

Out: docs/PY.md (Q5), a shared coverage floor, dead-code and unused-dependency
gating (on demand via `uvx`), publishing checks, notebooks.

## Interfaces

### Components

Six, named and shaped as in ts-quality. Every one takes `dir` (`"."`). No
`name:`/`version:` root keys; the tag is the version.

| File | Props beyond `dir` |
|---|---|
| `fast.yml` | `cap_loc`, `ruff_args`, `pyrefly_args` |
| `ci.yml` | `cap_loc`, `audit`, `ruff_args`, `pyrefly_args`, `pytest_args`; `timeout: 30m` |
| `tools.yml` | — |
| `sync-config.yml` | — |
| `config-check.yml` | — |
| `findings.yml` | `cap_loc`, `audit`, `out` |

### Gate steps

```
fast  1 uv.lock drift   2 ruff format --check (staged)   3 ruff check (staged)
      4 pyrefly         5 ai-lint (staged)               6 soft caps
full  1 uv.lock drift   2 ruff format --check            3 ruff check
      4 pyrefly         5 pytest                         6 config drift
      7 supply chain    8 audit                          9 ai-lint (tracked)
     10 soft caps
```

Every tool runs as `uv run --locked --offline --quiet` (`uvr` in lib.sh).
Our own parsing runs as `uv run --no-project --offline --python '>=3.11'
python -I` (`pq_py`) — never a bare `python3`.

### Config contract

- `ruff.base.toml` — copied; consumer `[tool.ruff] extend = "ruff.base.toml"`.
- `pyrefly.base.toml` — copied; consumer `[tool.pyrefly] extends = "pyrefly.base.toml"`.
- `pyproject-block.toml` — printed, merged by hand: `requires-python`, the dev
  group, `exclude-newer`, the two extend lines, pytest strictness.

config-check rules, finding schema and knobs: README. lib.sh records:
`rule<TAB>level<TAB>path<TAB>line<TAB>message[<TAB>key]`. Wire schema, shared
with the siblings: `{"tool","rule","level","path","line","col"?,"message",
"fingerprint":"rule:path:line[:key]"}`.

## Measured before the baselines were fixed

**pyrefly** — every file, against each repo's own `.venv`, run from outside the
repo (no writes). Measured on the HEADs at session start; both repos took new
commits from other sessions during the day, so treat these as a snapshot.

| | `default` | `strict` |
|---|---|---|
| autolab (163 files) | 0 | 144 — `missing-override-decorator` 74, `implicit-any-lambda` 40, `implicit-any-empty-container` 22, `implicit-any-type-argument` 8 |
| money (38 files) | 41 — `missing-attribute` 17, `bad-argument-type` 9, `unsupported-operation` 7 | 344 — adds `implicit-any-parameter` 174, `implicit-any-type-argument` 116 |

The chosen baseline costs autolab 8 and money ~331. money has never had a type
checker; its 41 `default` findings are real defects.

**ruff** — `ruff.base.toml` as shipped, `--no-cache`, `git ls-files`:

| | Findings | Largest buckets |
|---|---|---|
| autolab @ 3af5bdf | 100 | T201 43, PT018 23, PLR0913 6, N818 5 |
| money @ 24493d6 | 84 | PT018 29, RUF100 12, T201 9, S608 7 |

Zero format drift in either. Tuning taken from the first pass: `ARG002`
ignored (every autolab hit was a plugin implementing an interface);
`PLR0913`/`PLR0917` relaxed in tests (fixtures are arguments); `T20` relaxed in
`cli.py` / `__main__.py` (money's 21 prints were all its CLI). `PT018`
(composite asserts) was kept: mechanical to fix and it is what makes a test
failure readable.

## Edge cases — each reproduced, not assumed

- **ruff: a consumer `lint.select` REPLACES the base selection.** A
  `select = ["E", "F"]` consumer passes `ruff check` on code the baseline
  fails. config-check: `ruff-select-override`.
- **That one error drowned in ~400 `ruff-rule-dropped` warnings**, and
  provision's failure view (first 10 + last 20 lines) elided it. Per-rule drops
  are now reported only when the consumer extends and does not override, and
  config-check sorts errors last.
- **pyrefly hides warn-level kinds and exits 0 on them** (display floor
  `error`). `--min-severity warn` shows them and exits 1 — the Python twin of
  Biome's `--error-on-warnings` hole.
- **pyrefly: a consumer `preset = "basic"` silenced `bad-assignment`**, exit 0.
  `pyrefly-preset-override`.
- **pyrefly: a typo'd `extendz` falls back to defaults** with only a WARN line.
  `pyrefly-not-extended`.
- **pyrefly `dump-config` prints paths, not error kinds**, so its half of
  config-check reads the consumer table rather than resolved config.
- **A standalone `ruff.toml` wins over `[tool.ruff]`.** config-check reads the
  file the tool reads; a `ruff.toml` without `extend` is `ruff-not-extended`
  even when pyproject.toml is correct.
- **`uv lock --check --offline` has three failures with one exit code**: stale
  ("needs to be updated"), missing ("Unable to find lockfile"), and
  unanswerable ("network was disabled" — metadata not cached). Told apart by
  message; the third fails with its own remedy, never "your lock is stale".
- **Relative `exclude-newer` does not make the lock stale over time.** uv.lock
  records `exclude-newer-span = "P3D"` and a placeholder date.
- **`uv sync` is exact by default** and would uninstall a consumer's other
  groups (money's `notebook`) on every tools run. `--inexact`.
- **`uv run --locked` on a stale lock exits 1 before the tool starts** — the
  same code as "found something". findings.sh names that cause in its
  `*-failed` record.
- **ruff checks files passed by name even when excluded.** The staged path
  carries `--force-exclude`; a staged `migrations/` file stays out.
- **ruff 0.17 no longer prints "Would reformat:".** A scrape of that line
  matched nothing and reported unformatted code clean. Both ruff legs of
  findings.sh use `--output-format json` (format has it too).
- **pytest exit 5** (no tests collected) is a notice, not a failure.
- **pip-audit cannot read uv.lock**; fed by `uv export --frozen`, with path and
  editable lines filtered. Export is buffered to a file — piped into the filter,
  a failed export read as "no dependencies".
- **pip-audit answers from pip's HTTP cache offline**: with the network cut it
  still reported advisories. Every run gets a fresh `--cache-dir`, so offline
  is `audit-unavailable`, verified with both a warm and a cold uv cache.
- **pip-audit 2.10.1 lists each advisory twice** in its JSON. Deduped by ID.
- **A checker that crashes under `--warn-only` read as "0 records"** in
  findings. `sub` turns a non-zero exit into a `pq-failed` record.
- **ai-lint residue produces zero ruff diagnostics** (ERA001 included) — so it
  double-reports nothing.
- **zsh's `echo` rewrites backslashes in JSON, and zsh does not word-split
  `$var`** — both corrupted measurements in this session; scripts are bash.
- Inherited from the siblings and kept: `cd` before env assignments in every
  component; `git diff --cached --relative`; `git ls-files --deduplicate`;
  `|| true` on every grep pipeline in lib.sh; `render` via process
  substitution, never a pipe; findings to stderr; bash 3.2 floor.

## Validation — actually run, 2026-10-21

Toolchain: uv 0.13.0, ruff 0.17.1, pyrefly 1.4.0, pytest 9.1.1, pip-audit
2.10.1, provision 0.10.0, shellcheck 0.11.0 (ephemeral, via `uvx
shellcheck-py`), Python 3.12.3.

- `bash -n` + `shellcheck -x` clean on all 7 scripts. No `mapfile`, no
  associative arrays, no here-strings.
- **All six components pass `provision validate`**; five pass `--strict`.
  `tools.yml` does not and should not — same reasoning as the siblings.
- **Fixture**: a git repo with the project in `api/`, gated with
  `dir: api` through `provision apply`, components `use`d by path.
  - sync-config wrote both base files; **re-apply was a no-op** (3 ok, 0 changed).
  - tools synced and verified.
  - **27/27 matrix cases pass, twice** (a throwaway harness: each case resets
    the fixture, applies one mutation, runs one `provision apply`, and asserts
    the exit code and that the finding is in provision's output): clean
    fast and full green; unformatted, lint error (committed and staged), type
    error (full and fast), implicit-Any parameter, a consumer `"warn"`
    downgrade still gated, failing test, stale and missing lock, staged
    residue (fast catches), committed residue (fast misses, full catches),
    staged excluded path skipped, select override, not extended, standalone
    `ruff.toml` wins, rule dropped (warning, green), preset override, pyrefly
    not extended, missing base, stale base (warning, green), dev group
    missing, vulnerable dependency (idna 3.6 → PYSEC-2024-60, PYSEC-2026-215).
  - no tests → exit-5 notice, green.
  - supply-chain on six states: clean, unset, absolute date, `P1D`,
    `24 hours`, unsafe index strategy.
  - audit on five states: advisories (exit 1), dead network with warm and cold
    uv cache (note, exit 0), `AUDIT_IGNORE`, `PQ_AUDIT=0`. Full gate offline:
    green with the audit reported as not checked.
  - **findings**: 6 records from 4 tools on a dirty fixture through provision,
    every line valid JSON, 6/6 unique fingerprints; `CAP_LOC=3` adds god-file
    records; a broken ruff config, a stale lock and a crashed checker each
    produce an explicit `*-failed` record.
- **Every finding is visible in provision's failure view** — asserted per
  case, not assumed.

## Known gaps

- **bash 3.2 is claimed, not run.** No macOS host was available; the scripts
  avoid every bash-4 construct rust-quality was bitten by, and that is all.
- **No real consumer has run it.** autolab and money were measured read-only;
  neither has been wired. Their day-one cost is the table above.
- **pyrefly config-check reads text, not resolved config.** A weakening
  introduced some other way (a CLI flag in `pyrefly_args`) is invisible to it.
- **supply-chain does not read `~/.config/uv/uv.toml`.** What the repo pins is
  what CI gets; a user-level cooldown can mask a repo without one.
- **pytest strictness flags are printed, not enforced.**
- **The audit needs the network**, and its tool resolution needs it on first
  use per version. Offline it says so instead of reporting clean.
- **pip-audit sees no severities** (PyPI advisories carry none): any advisory
  fails; `AUDIT_IGNORE` is the only valve.
