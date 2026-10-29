#!/usr/bin/env bash
set -euo pipefail

OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5:3b}"

command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 1; }

printf 'Checking Ollama version endpoint...\n'
curl --fail --silent --show-error "${OLLAMA_URL}/api/version"
printf '\nChecking model list...\n'
curl --fail --silent --show-error "${OLLAMA_URL}/api/tags"
printf '\nRunning generation smoke test with model %s...\n' "$OLLAMA_MODEL"
response="$(curl --fail --silent --show-error \
  --max-time 600 \
  "${OLLAMA_URL}/api/generate" \
  -H 'Content-Type: application/json' \
  -d "$(MODEL="$OLLAMA_MODEL" python3 - <<'PYJSON'
import json, os
print(json.dumps({"model": os.environ["MODEL"], "prompt": "Ответь одним предложением: что такое Ansible?", "stream": False}))
PYJSON
)")"
printf '%s\n' "$response" | python3 -c 'import json,sys; data=json.load(sys.stdin); text=data.get("response", "").strip(); assert text, "API response field is empty"; print("Generated response:", text)'
printf '\nAPI smoke test passed.\n'
