# Contributing to Fleet

Thanks for your interest in contributing to Fleet! This project is built by and for the multi-agent community.

## Ways to Contribute

### Bug Reports

Open an [issue](https://github.com/oguzhnatly/fleet/issues/new?template=bug_report.md) with:
- Fleet version (`fleet --version`)
- Your OS and bash version (`bash --version`)
- Steps to reproduce
- Expected vs actual behavior

### Feature Requests

Open an [issue](https://github.com/oguzhnatly/fleet/issues/new?template=feature_request.md) describing:
- What problem you're solving
- Your proposed solution
- Example usage

### Code Contributions

1. Fork the repo
2. Create a branch (`git checkout -b feature/my-feature`)
3. Make your changes
4. Run tests (`bash tests/test_cli.sh`)
5. Commit with a clear message
6. Open a PR

### New Commands

Fleet is modular — each command is a separate file in `lib/commands/`. To add a new command:

1. Create `lib/commands/yourcommand.sh`
2. Define a `cmd_yourcommand()` function
3. Add a case in `bin/fleet`'s router
4. Add tests in `tests/test_cli.sh`
5. Document in README.md and SKILL.md

### New Fleet Patterns

Add examples to `examples/your-pattern/`:
- `config.json` — working config file
- `README.md` — explanation of the pattern, when to use it, architecture diagram

## Code Style

- **Bash 4+** — no bashisms that break on older systems
- **ShellCheck clean** — all code must pass `shellcheck -S warning`
- **Python 3.10+** — for JSON parsing and complex logic inside heredocs
- **No external dependencies** — no pip packages, no npm, no jq. Just bash, python3, and curl.
- **Colors via `lib/core/output.sh`** — use `out_ok`, `out_fail`, `out_warn`, `out_info` helpers
- **Config via `lib/core/config.sh`** — use `_json_get` for reading config values

## Testing

```bash
# Run all tests
bash tests/test_cli.sh

# Check syntax
for f in bin/fleet lib/core/*.sh lib/commands/*.sh; do
    bash -n "$f"
done

# Validate JSON
for f in examples/*/config.json templates/configs/*.json; do
    python3 -c "import json; json.load(open('$f'))"
done
```

## Commit Messages

Use conventional commits:
- `feat: add new command`
- `fix: resolve ShellCheck warning`
- `docs: update configuration reference`
- `test: add integration test for backup`

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
