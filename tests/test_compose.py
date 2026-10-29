#!/usr/bin/env python3
"""Render Compose in GPU and CPU modes and verify the resulting YAML structure."""
from __future__ import annotations

import json
from pathlib import Path

import yaml
from jinja2 import Environment, FileSystemLoader, StrictUndefined

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE_DIR = ROOT / "roles" / "ollama" / "templates"
env = Environment(
    loader=FileSystemLoader(str(TEMPLATE_DIR)),
    undefined=StrictUndefined,
    trim_blocks=True,
    lstrip_blocks=True,
)
env.filters["to_json"] = json.dumps
env.filters["bool"] = bool

base = {
    "ollama_image": "ollama/ollama:0.40.13",
    "ollama_bind_address": "127.0.0.1",
    "ollama_enable_gpu": False,
    "ollama_volume_name": "ollama_data",
}

for gpu_enabled in (False, True):
    context = dict(base, ollama_enable_gpu=gpu_enabled)
    rendered = env.get_template("compose.yml.j2").render(**context)
    try:
        compose = yaml.safe_load(rendered)
    except yaml.YAMLError as exc:
        raise SystemExit(f"FAIL: Compose template did not render valid YAML (gpu={gpu_enabled}): {exc}")

    service = compose["services"]["ollama"]
    assert service["image"] == base["ollama_image"], service
    assert service["ports"] == ["127.0.0.1:11434:11434"], service
    assert "ollama_data:/root/.ollama" in service["volumes"], service
    assert compose["volumes"]["ollama_data"]["name"] == "ollama_data", compose["volumes"]
    has_gpu_device = "deploy" in service
    assert has_gpu_device is gpu_enabled, service
    print(f"OK: Docker Compose rendered and validated with GPU={gpu_enabled}")

# Check Jinja escaping used for literal Docker format strings in Ansible tasks.
for expression, expected in (
    ("{{ '{{' }}.DockerRootDir{{ '}}' }}", "{{.DockerRootDir}}"),
    ("{{ '{{' }}.ServerVersion{{ '}}' }}", "{{.ServerVersion}}"),
):
    assert env.from_string(expression).render() == expected
print("OK: Docker Go-template format strings survive Jinja rendering")
