#!/bin/bash
# fleet skills · List installed ClawHub skills

cmd_skills() {
    local skills_dir

    # Check config first, then standard locations
    if fleet_has_config; then
        skills_dir=$(_json_get "$FLEET_CONFIG_PATH" "skillsDir" "")
    fi

    if [ -z "$skills_dir" ] || [ ! -d "$skills_dir" ]; then
        skills_dir="$(fleet_workspace)/skills"
    fi
    if [ ! -d "$skills_dir" ]; then
        skills_dir="$HOME/.openclaw/skills"
    fi

    if [ ! -d "$skills_dir" ]; then
        out_header "Skills"
        echo "  No skills directory found."
        echo "  Install skills with: clawhub install <skill-name>"
        return
    fi

    out_header "Installed Skills"
    out_dim "from $skills_dir"
    echo ""

    python3 - "$skills_dir" <<'SKILLS_PY'
import json, sys
from pathlib import Path

skills_dir = Path(sys.argv[1])
D = "\033[2m"; B = "\033[1m"; G = "\033[32m"; N = "\033[0m"

def get_meta(d):
    meta = d / "_meta.json"
    if meta.exists():
        try:
            return json.loads(meta.read_text())
        except Exception:
            pass
    return {}

def get_desc(d, meta):
    desc = meta.get("description") or meta.get("summary") or ""
    if desc:
        return desc.strip()[:70]
    skill = d / "SKILL.md"
    if skill.exists():
        for line in skill.read_text(errors="ignore").splitlines():
            s = line.strip()
            if s.startswith("description:"):
                return s.split(":", 1)[1].strip().strip('"\'')[:70]
    return ""

skills = sorted(
    [d for d in skills_dir.iterdir() if d.is_dir() and not d.name.startswith(".")],
    key=lambda p: p.name.lower()
)

if not skills:
    print("  No skills installed.")
    sys.exit(0)

for s in skills:
    meta = get_meta(s)
    ver = meta.get("version", "?")
    desc = get_desc(s, meta)
    has_scripts = (s / "scripts").is_dir()
    has_hooks = (s / "hooks").is_dir()
    extras = []
    if has_scripts: extras.append("scripts")
    if has_hooks: extras.append("hooks")
    extras_str = f" {D}[{', '.join(extras)}]{N}" if extras else ""

    print(f"  {G}●{N} {B}{s.name}{N} {D}v{ver}{N}{extras_str}")
    if desc:
        print(f"    {D}{desc}{N}")
SKILLS_PY
}
