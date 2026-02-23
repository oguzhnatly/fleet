# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-02-23

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

[1.0.0]: https://github.com/oguzhnatly/fleet/releases/tag/v1.0.0
