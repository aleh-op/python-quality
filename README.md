# python-quality

Shared Python quality gate for the fleet — the canonical ruff and pyrefly
baselines, a two-mode gate, the supply-chain posture check, and the consumer
guide. Consumed by [provision](https://github.com/alehatsman/provision). The
Python sibling of `rust-quality`, `go-quality` and `ts-quality`.

- [docs/STACK.md](docs/STACK.md) — what the gate runs and what it deliberately
  does not, with versions verified against PyPI.
- [SPEC.md](SPEC.md) — decisions, measurements and the validation record.

## What's here

```
ruff.base.toml        the canonical lint + format baseline (copied, extended)
pyrefly.base.toml     the canonical type-check baseline (copied, extended)
pyproject-block.toml  the canonical pyproject.toml text; pyproject cannot be extended, so this is printed
scripts/
  lib.sh              the checks the toolchain does not do, defined once
  gate.sh             fast | full
  findings.sh         JSONL for agents
  config-check.sh     did the consumer weaken the shared config
  supply-chain.sh     is the cooldown configured
  audit.sh            pip-audit over uv.lock, with the offline case handled honestly
  tools.sh            install | check
```

| Component | What it does | Network |
|---|---|---|
| `ci.yml` | full pre-push gate — uv.lock drift, ruff format + check, pyrefly, pytest, config drift, supply chain, pip-audit, ai-lint over tracked files, soft caps | audit only; offline it is a note |
| `fast.yml` | pre-commit gate — uv.lock drift, ruff format + check over staged files, pyrefly, ai-lint over staged files, soft caps | none |
| `tools.yml` | `uv sync --locked --inexact`, then verify ruff / pyrefly / pytest resolve offline | install only |
| `sync-config.yml` | copy the two base files in, print the pyproject block | none |
| `config-check.yml` | did the consumer quietly weaken the baseline | none |
| `findings.yml` | every finding as JSONL → `.gate/findings.jsonl` | audit only |

## How a consumer wires it in

Same shape as every sibling: a pinned checkout in the consumer's own plan,
then `use:` by path. Nothing fetches at gate time.

```yaml
# tasks/tools.yml
steps:
  # THE PIN LIVES HERE AND NOWHERE ELSE. Bump it in one place.
  - vars:
      pq_ref: v0.1.0
      pq_dir: "{{ home }}/.cache/provision/tools/python-quality"
  - name: "python-quality at {{ pq_ref }}"
    git:
      repo: https://github.com/alehatsman/python-quality.git
      dest: "{{ pq_dir }}"
      ref: "{{ pq_ref }}"
  - name: Sync the gate's tools
    use: ~/.cache/provision/tools/python-quality/tools.yml
```

```yaml
# tasks/ci-fast.yml
steps:
  - name: fast gate
    use: ~/.cache/provision/tools/python-quality/fast.yml

# tasks/ci.yml
steps:
  - name: full gate
    use: ~/.cache/provision/tools/python-quality/ci.yml
```

A project that is not at the repo root passes `props: { dir: api }` to every
component. Each prop defaults to what a single-project repo wants, so most
consumers pass nothing.

### First-time setup

```
provision apply tasks/tools.yml          # checkout + uv sync
provision apply tasks/sync-config.yml    # ruff.base.toml + pyrefly.base.toml in; prints the block
# merge the printed block into pyproject.toml, then:
uv lock && uv sync
provision apply tasks/ci.yml
```

`tasks/sync-config.yml` and `tasks/config-check.yml` are one-step `use:` files
like the two above. Re-run sync-config after every `pq_ref` bump —
config-check reports a stale base copy as `base-copy-stale` until you do.

The only host prerequisite is **uv**, which dotfiles provisions. ruff, pyrefly
and pytest are the consumer's `dev` dependencies, pinned by its own `uv.lock`:
the gate, the editor and CI run the same versions, and nothing is installed
globally.

## The config contract

Two files are copied and **merged natively**; one block cannot be.

```toml
# pyproject.toml — the [gate] parts of pyproject-block.toml
[dependency-groups]
dev = ["pyrefly>=1.4.0", "pytest>=9.1.1", "ruff>=0.17.1"]

[tool.uv]
exclude-newer = "3 days"          # the supply-chain cooldown

[tool.ruff]
extend = "ruff.base.toml"         # add with lint.extend-select, remove with lint.ignore

[tool.pyrefly]
extends = "pyrefly.base.toml"     # never set `preset` here
```

pyproject.toml has no include mechanism, so the block is printed and pasted —
the same answer rust-quality gives for `[workspace.lints]` and ts-quality for
`package.json`. Where the gate must not mutate, it enforces:

```
ruff-not-extended        the active ruff config does not extend ruff.base.toml
ruff-select-override     `select` REPLACES the base selection — use extend-select
ruff-rule-dropped        a baseline rule is not enabled after resolution (warning)
ruff-unresolved          ruff could not resolve the config at all
pyrefly-not-extended     the active pyrefly config does not extend pyrefly.base.toml
pyrefly-preset-override  the consumer sets `preset`
pyrefly-rule-off         an error kind is false / ignore / info (warning)
base-copy-missing        a base file is absent — run sync-config
base-copy-stale          a base file differs from the pinned checkout (warning)
dev-group-missing        ruff / pyrefly / pytest not in the dev group
```

A standalone `ruff.toml`, `.ruff.toml` or `pyrefly.toml` wins over
`pyproject.toml` for its tool, and config-check reads whichever one the tool
actually reads.

## What the gate exists to get right

Each of these passes silently without it — all reproduced, see SPEC.md:

- **A consumer `lint.select` replaces the whole baseline** rather than adding
  to it. ruff then gates the consumer's handful of rules while looking like it
  gates the baseline's ~400. config-check compares *resolved* rule sets
  (`ruff check --show-settings`), not file text.
- **pyrefly hides warnings and exits 0 on them.** Its display floor is `error`,
  so a kind set to `"warn"` gates nothing. Every gate invocation carries
  `--min-severity warn`.
- **A consumer `preset = "basic"` silences even `bad-assignment`**, exit 0.
  config-check: `pyrefly-preset-override`.
- **`uv run` without `--locked` re-locks silently** and can fetch a different
  ruff mid-gate. Every invocation is `uv run --locked --offline`.
- **pytest exits 5 when it collects nothing.** That is reported, not failed.
- **ruff checks a file passed by name even if the config excludes it.**
  The staged path carries `--force-exclude`.
- **pip-audit answers from pip's HTTP cache** when the network is gone — a
  replay of old advisories presented as a result. Each run gets a fresh cache
  directory: a live answer, or an explicit `audit-unavailable` note.

## Supply chain

Every 2026 PyPI compromise (LiteLLM, telnyx, xinference, lightning, mistralai)
was a fresh malicious release of a legitimate package, pulled within hours to
days. An advisory database knows nothing about one in that window, so
`pip-audit` is necessary and not the defence. The defence is the cooldown —
`exclude-newer = "3 days"`, relative, so uv.lock records the span and does not
go stale — and `supply-chain.sh` reports on it:

| Rule | Level | Meaning |
|---|---|---|
| `no-lockfile` | error | no uv.lock |
| `no-release-cooldown` | warning | `exclude-newer` unset |
| `cooldown-absolute` | warning | a fixed date: resolution frozen, fixes never arrive |
| `release-cooldown-short` | note | below `MIN_RELEASE_AGE` days |
| `unsafe-index-strategy` | warning | a second index can shadow a PyPI name |

Provenance and attestations are deliberately not checked: the 2026 uploads
came from hijacked, correctly attested workflows.

## Findings for agents

`findings.yml` writes `.gate/findings.jsonl` — ruff (lint and format), pyrefly,
ai-lint, soft caps, config drift, supply chain and advisories — in the shared
fleet schema:

```json
{"tool":"pyrefly","rule":"implicit-any-parameter","level":"error","path":"src/api/x.py","line":6,"col":7,"message":"...","fingerprint":"implicit-any-parameter:src/api/x.py:6"}
```

`level:error` is gate-failing. A pure producer: it never re-gates and never
aborts. A tool or checker that fails without a report becomes an explicit
`*-failed` record — a run that could not check never reads as a run that
found nothing.

## Knobs

| Var | Prop | Default | Meaning |
|---|---|---|---|
| `CAP_LOC` | `cap_loc` | `500` | god-file soft cap, code lines |
| `PQ_AUDIT` | `audit` | `1` | `0` skips pip-audit |
| `RUFF_ARGS` | `ruff_args` | — | extra flags for `ruff check` |
| `PYREFLY_ARGS` | `pyrefly_args` | — | extra flags for `pyrefly check` |
| `PYTEST_ARGS` | `pytest_args` | — | extra flags for `pytest` (`ci` only) |
| `MIN_RELEASE_AGE` | — | `3` | cooldown in DAYS supply-chain expects |
| `AUDIT_OMIT_DEV` | — | `1` | audit runtime dependencies only |
| `AUDIT_IGNORE` | — | — | space-separated advisory IDs to ignore |

## Everyday commands

One invocation is a `uv run`, not a component — it works with no provision:

```
uv run ruff format              # format
uv run ruff check --fix         # lint + safe fixes
uv run pyrefly check --min-severity warn
uv run pytest
uvx deptry .                    # on demand: unused / missing dependencies
uvx vulture --min-confidence 80 # on demand: cross-module dead code
```
