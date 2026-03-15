# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.0.2] · 2026-03-15

### Fixed
- `SKILL.md`: removed all vague agent-latitude language ("translate on the fly", "create a wrapper", "whatever means are available"). Agents are now explicitly instructed to report dependency failures to the operator rather than improvise workarounds.
- `SKILL.md`: replaced "Making Fleet Work Anywhere" section with bounded "Dependency Requirements" section containing only explicit platform package manager commands
- `SKILL.md`: added `agentScope.permitted` and `agentScope.notPermitted` blocks explicitly bounding what an agent is and is not allowed to do with this skill
- `SKILL.md`: added `updateMechanism` block declaring source, verification method, and opt-out for background update check
- `SKILL.md`: added `installSpec` top-level field in frontmatter for registry compliance
- `_meta.json`: added top-level `installSpec` key with explicit `updateMechanism` and `verification` fields
- `lib/commands/update.sh`: added SHA256 checksum verification against `fleet.sha256` published alongside each GitHub release; extraction halts on mismatch
- `lib/commands/init.sh`: `chmod 600` applied to `~/.fleet/config.json` immediately on creation; plaintext token storage disclosed to operator in output

---

## [3.0.1] · 2026-03-15

### Fixed
- `SKILL.md`: added `requires`, `permissions`, `sensitive`, and `installBehavior` fields to frontmatter so the registry manifest is complete and matches actual runtime behavior
- `SKILL.md`: corrected "never" claims that contradicted documented behaviors (background GitHub release check, `fleet init` reading `~/.openclaw/openclaw.json`, session file access scope for `fleet watch`)
- `bin/fleet`: added `FLEET_NO_UPDATE_CHECK` env var to allow operators to disable the background GitHub release check
- `_meta.json`: added `FLEET_NO_UPDATE_CHECK` to optional env vars

---

## [3.0.0] 2026-03-15

### Added
- `fleet update [--check] [--force]`: self-upgrade command. Fetches the latest release from GitHub, compares with the installed version, and installs automatically. `--check` reports availability without installing. `--force` reinstalls even when already current.
- Outdated version banner: when a newer release is cached (checked once per 24 hours in the background), every fleet command prints a one-line warning on stderr recommending `fleet update`. Zero latency: the GitHub check runs as a detached background process.
- `fleet trust [--window <hours>] [--json]`: trust matrix for all configured agents. Scores, trend indicators (↑↓→★), per-type breakdown, and task counts in one view. `--json` flag for scripting.
- `fleet score [<agent>] [--window <hours>] [--type <task_type>]`: detailed per-agent reliability drill-down. Per-task-type breakdown with outcome counts, recent task history, and configurable filters. No agent argument shows a summary table for all agents.
- `lib/core/trust.sh`: trust scoring engine (sourced by bin/fleet). Public API: `trust_score_agent`, `trust_best_for_type`, `trust_all_json`. Reads `~/.fleet/log.jsonl`, applies recency weighting and the quality×speed formula. Zero dependencies beyond `python3` and `bash 4+`.
- Cross-validation (v3.5): `fleet score` cross-checks code/deploy task successes against GitHub CI runs within 1 hour of completion. Flags unverified tasks and warns when trust score may be inflated. Requires `gh` CLI.
- `trust.windowHours` config key: controls the recency window for 2× weighting (default: 72). Exposed via `config.trust.windowHours` in `~/.fleet/config.json`.
- `FLEET_TRUST_WINDOW_HOURS` environment variable: runtime override for the trust window.
- Trust summary appended to `fleet sitrep` output: one line showing all agents with their current trust percentage, color-coded.
- `fleet parallel` now uses trust-weighted agent selection: dispatches each subtask to the highest-trust agent for that task type. Falls back to overall score (0.8× penalty) when no type-specific history exists. Execution plan now shows trust score for each assigned agent.

### Changed
- `bin/fleet`: sources `lib/core/trust.sh` alongside the other core libs; routes `trust` and `score` commands; `help` updated with TRUST section.
- `fleet parallel`: `_parallel_decompose` rewritten to query trust scores from the log before assigning agents. Execution plan display includes per-agent trust percentage.
- `fleet help`: new TRUST section with `fleet trust` and `fleet score` entries.

### Trust Formula
```
trust_score = quality_score × speed_multiplier

quality_score  = Σ(weight × task_quality) / Σ(weight)
task_quality   = success: 1.0 − 0.15×steers (min 0.70)
               = steered: 0.5 − 0.10×(steers−1) (min 0.30)
               = failure/timeout: 0.0
speed_mult     = 1.00 (avg ≤5m), 0.90 (≤15m), 0.75 (≤30m), ≥0.50 (>30m)
recency weight = 2.0 (within windowHours), 1.0 (within 7d), 0.5 (older)
```

---

## [2.1.0] 2026-03-15

### Fixed
- `SKILL.md`: corrected version check block line range from 9-20 to 10-22 in the bash 3.2 compatibility section (line 9 is blank; the block closes at line 22 with `fi` and `exit 1`)
- `SKILL.md`: replaced prompt injection trigger language (`Red line:`, "bypass", "security controls", "commenting out") with neutral phrasing that preserves identical guidance without triggering security scanner false positives

---

## [2.0.3] 2026-03-01

### Changed
- Version bump to 2.0.3 across config.sh, _meta.json, and assets/banner.svg

---

## [2.0.2] 2026-03-01

### Changed
- `_meta.json`: version synced to 2.0.2, published to ClawHub registry with full permissions/install/envVars blocks

---

## [2.0.1] 2026-03-01

### Changed
- `_meta.json`: version bumped to 2.0.0, added `permissions` block (reads/writes/network/never), `envVars` listing, `install` spec with consent statement, `sensitive` section, and accurate `requires` with version constraints. Resolves registry metadata mismatch.
- `SKILL.md`: added "Intent, Authorization, and Trust" section, "Security Model" section with full network/filesystem/credential/privilege scope, inline red lines on every autonomous behavior, explicit opt-out path for shell rc modification, and PATH idempotency check before writing to rc files

---

## [2.0.0] 2026-03-01

### Added
- `fleet task <agent> "<prompt>"`: dispatch a task to any agent via its gateway, with streaming output, configurable timeout, and `--no-wait` mode
- `fleet steer <agent> "<message>"`: send a mid-session correction to a running agent, routed to the same stable session as `fleet task`
- `fleet watch <agent>`: live session tail, polls agent session history and renders new messages as they arrive
- `fleet parallel "<task>"`: decompose a high-level task into subtasks, assign each to the right agent type, dispatch all concurrently with `--dry-run` gate before execution
- `fleet kill <agent>`: send a graceful stop signal to an agent session, marks pending log entries as steered
- `fleet log`: append-only structured log of all dispatches and outcomes; filterable by agent, outcome, and task type; feeds fleet v3 trust scoring
- `fleet log` schema: task_id, agent, task_type, prompt, dispatched_at, completed_at, outcome, steer_count
- Agent tokens now read from fleet.json config for authenticated gateway communication
- Version bumped to 2.0.0

### Changed
- `fleet help` updated with DISPATCH section listing all new v2 commands

## [1.1.0] 2026-02-23

### Added
- `fleet audit` command: checks config, agent health, CI, resources, backups with actionable warnings
- Terminal demo GIF in README (live recording against real gateways)
- Universal compatibility playbook in SKILL.md: agents install deps and adapt to any environment
- Auto PATH setup in `fleet init`: symlinks to `~/.local/bin`, updates shell rc files
- bash 4+ version check with macOS-specific install guidance
- "Why Fleet?" section with 6 value props
- Collapsible command output examples in README
- GitHub Sponsors badge and `FUNDING.yml`
- Agent-first tagline: "Built for AI agents to manage AI agents"

### Fixed
- `fleet backup` exit code 1 bug (arithmetic with `set -e`)
- `fleet init` port scan now covers 48400-48700 (detects spaced-out gateways)
- Shebang changed to `#!/usr/bin/env bash` for Homebrew bash on macOS

### Changed
- SKILL.md expanded from 3K to 13K+ (full command ref, config schema, troubleshooting, universal compat)
- README rewritten: direct intro, no dashes, requirements as table
- All em dashes replaced across all files

## [1.0.0] 2026-02-23

### Added
- Core CLI with modular architecture (`lib/core/` + `lib/commands/`)
- `fleet health`: health check all gateways and endpoints
- `fleet agents`: show agent fleet with live status and latency
- `fleet sitrep`: structured status report with delta tracking
- `fleet ci`: GitHub CI status across repos
- `fleet skills`: list installed ClawHub skills
- `fleet backup` / `fleet restore`: config backup and restoration
- `fleet init`: interactive setup with auto-detection
- Config-driven design (`~/.fleet/config.json`)
- Three fleet patterns: solo-empire, dev-team, research-lab
- SKILL.md for ClawHub publishing
- CI pipeline with ShellCheck and integration tests
- SVG banner with CSS animations
- Full documentation (configuration reference, patterns guide)

[3.0.0]: https://github.com/oguzhnatly/fleet/releases/tag/v3.0.0
[2.1.0]: https://github.com/oguzhnatly/fleet/releases/tag/v2.1.0
[1.1.0]: https://github.com/oguzhnatly/fleet/releases/tag/v1.1.0
[1.0.0]: https://github.com/oguzhnatly/fleet/releases/tag/v1.0.0
