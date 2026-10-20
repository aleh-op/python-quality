# The stack

What the gate runs, what it deliberately does not, and when to revisit.
**Versions verified against PyPI on 2026-10-21**, not from memory.

Defaults, not laws. Deviating is fine; deviating *silently* is not — write the
reason next to the override. Companion: [README](../README.md), [SPEC](../SPEC.md).

---

## Platform

| | Version | Note |
|---|---|---|
| Python | floor **3.12**, test on 3.14 | 3.15.0 released 2026-10-09; 3.10 is EOL (2026-10-01). Move the floor when a consumer needs it. |
| uv | 0.13.x (latest 0.13.4) | The one host prerequisite; dotfiles provisions it. |
| build backend | `uv_build>=0.13,<0.14` | What `uv init --package` writes. hatchling (1.32.4) when a build hook is needed. |

## In the gate

| Job | Tool | Version | Why this one |
|---|---|---|---|
| env, lock, run | uv | 0.13.x | Already the fleet's manager. `uv lock --check` is drift; `exclude-newer` is the cooldown. |
| lint + format | ruff | 0.17.1 | One binary for what black, flake8 + plugins, isort, mccabe, most of bandit and pylint's useful rules did. Native `extend`; JSON/SARIF for check *and* format. |
| types | pyrefly | 1.4.0 | Stable since 1.0 (2026-05-12), native binary, `extends`, JSON output. Already in the fleet (autolab). |
| tests | pytest | 9.1.1 | The default. |
| advisories | pip-audit (via `uvx`) | 2.10.1 | PyPA. Pinned in `scripts/audit.sh`, not in consumer locks: ~15 transitive deps and it needs the network anyway. |

## Considered and left out

| Tool | Version | Why not |
|---|---|---|
| black | 26.10.1 | `ruff format`. |
| flake8 / isort / mccabe | 7.4.1 / — / — | ruff ports them. |
| pylint | 4.1.3 | Slow, noisy, a second linter; its useful rules are ruff `PL*`. |
| bandit | 1.9.4 | ruff `S` is the port (73 rules). Two security linters double-report. |
| mypy | 2.4.0 | Stable and the reference semantics — the runner-up. No config `extends` ("Unrecognized option", verified), so the baseline could not be a file copy. |
| ty | 0.0.90 | Beta, no stable API, no `extends`, no JSON. **Revisit at 1.0** — it is the Astral-consistent choice. |
| pyright | 1.1.414 | The PyPI wrapper downloads Node at runtime. |
| basedpyright | 1.40.2 | Bundles ~30 MB of Node; a single-maintainer fork. |
| pytest-cov / coverage | 7.1.0 / 7.16.2 | No shared coverage floor yet (ts-quality made the same call). A consumer that wants one runs `coverage run -m pytest` + `fail_under` in its own config. |
| radon / xenon | 6.0.1 / 0.9.3 | Dormant since 2024. ruff `C901` + `PLR09xx` cover complexity. |
| complexipy | 8.1.0 | Cognitive complexity is nice; not worth a dependency. |
| vulture | 2.16 | Cross-module dead code, but false positives need per-repo whitelists. On demand: `uvx vulture --min-confidence 80`. |
| deptry | 0.25.1 | Still classified Alpha; false positives on dynamic imports. On demand: `uvx deptry .`. |
| `uv audit` | uv 0.13.x | Native, reads uv.lock — but preview (`--preview-features audit-command`). **Switch when it graduates**; it drops the pin and the export. |
| osv-scanner | 2.7.0 | A Go binary, not on PyPI. |
| safety | 3.8.1 | Scans need an account; free tier "not for commercial purposes". |
| poetry / pdm / hatch | 2.5.1 / 2.29.3 / 1.18.1 | A second project manager. |
| twine | 7.0.0 | `uv publish`. |

## Watch list

- **ty 1.0** — re-run the type-checker comparison when it lands.
- **`uv audit` leaving preview** — replace pip-audit.
- **pyrefly `dump-config`** printing resolved error kinds — would let
  config-check ask pyrefly the way it asks ruff, instead of reading the table.
- **pip-audit listing each advisory twice** (2.10.1) — deduped in audit.sh;
  drop the dedupe when fixed upstream.
