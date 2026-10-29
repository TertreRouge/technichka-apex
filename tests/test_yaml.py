#!/usr/bin/env python3
"""Lightweight YAML syntax check; not a replacement for ansible-playbook --syntax-check."""
from pathlib import Path
import sys

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required for the fallback YAML check. Install it with: python3 -m pip install PyYAML", file=sys.stderr)
    raise SystemExit(2)

ROOT = Path(__file__).resolve().parents[1]
EXCLUDED = {ROOT / "roles/ollama/templates/compose.yml.j2"}
CANDIDATES = list(ROOT.glob("*.yml")) + list(ROOT.glob("*.yaml"))
CANDIDATES += list((ROOT / "group_vars").glob("*.yml"))
CANDIDATES += list((ROOT / "inventory").glob("*.yml"))
CANDIDATES += list((ROOT / "roles").glob("**/*.yml"))
CANDIDATES += list((ROOT / ".github").glob("**/*.yml"))

failed = False
for path in sorted(set(CANDIDATES) - EXCLUDED):
    try:
        with path.open("r", encoding="utf-8") as stream:
            yaml.safe_load(stream)
    except Exception as exc:  # keep the file path visible for diagnosis
        failed = True
        print(f"FAIL: {path.relative_to(ROOT)}: {exc}", file=sys.stderr)
    else:
        print(f"OK:   {path.relative_to(ROOT)}")

if failed:
    raise SystemExit(1)
print("YAML syntax check passed. Ansible-specific validation still requires ansible-playbook.")
