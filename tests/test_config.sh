#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

python3 tests/test_yaml.py
for script in setup-nvidia-g4dn.sh tests/test_api.sh tests/test_config.sh; do
  bash -n "$script"
done
python3 tests/test_compose.py

if command -v ansible-playbook >/dev/null 2>&1; then
  ansible-playbook -i inventory/hosts.yml playbook.yml --syntax-check
else
  echo "WARNING: ansible-playbook not found; YAML parsing passed, but the full Ansible syntax check was skipped." >&2
fi

if command -v ansible-lint >/dev/null 2>&1; then
  ansible-lint playbook.yml roles/
else
  echo "NOTE: ansible-lint not installed; skipping lint checks."
fi

printf '\nAvailable configuration checks passed. Hardware/runtime behavior is not tested by this script.\n'
