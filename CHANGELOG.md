# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] · 2026-02-23

### Added
- `fleet audit` command · checks config, agent health, CI, resources, backups with actionable warnings
- Terminal demo GIF in README (live recording against real gateways)
- Universal compatibility playbook in SKILL.md · agents install deps and adapt to any environment
- Auto PATH setup in `fleet init` · symlinks to `~/.local/bin`, updates shell rc files
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

## [1.0.0] · 2026-02-23

### Added
- Core CLI with modular architecture (`lib/core/` + `lib/commands/`)
- `fleet health` · health check all gateways and endpoints
- `fleet agents` · show agent fleet with live status and latency
- `fleet sitrep` · structured status report with delta tracking
- `fleet ci` · GitHub CI status across repos
- `fleet skills` · list installed ClawHub skills
- `fleet backup` / `fleet restore` · config backup and restoration
- `fleet init` · interactive setup with auto-detection
- Config-driven design (`~/.fleet/config.json`)
- Three fleet patterns: solo-empire, dev-team, research-lab
- SKILL.md for ClawHub publishing
- CI pipeline with ShellCheck and integration tests
- SVG banner with CSS animations
- Full documentation (configuration reference, patterns guide)

[1.1.0]: https://github.com/oguzhnatly/fleet/releases/tag/v1.1.0
[1.0.0]: https://github.com/oguzhnatly/fleet/releases/tag/v1.0.0
