"""Unit tests for setup-as-agent-actions task generation."""
from __future__ import annotations

from pathlib import Path

from scripts.prepare_task import prepare_setup_variant


def test_setup_variant_strips_image_and_adds_preamble(tmp_path: Path) -> None:
    src = Path("vendor/deep-swe/tasks/httpx-streaming-json-iteration")
    dst = tmp_path / "httpx-streaming-json-iteration"
    summary = prepare_setup_variant(
        src,
        dst,
        agent_network_mode="public",
        allowed_hosts=None,
        base_strategy="prebuilt-wipe",
    )
    assert summary["docker_image_cleared"] is True
    assert summary["setup_run_count"] >= 2
    dockerfile = (dst / "environment" / "Dockerfile").read_text()
    assert "git clone" not in dockerfile
    assert "pip install" not in dockerfile
    assert "find /app -mindepth 1" in dockerfile
    assert "swe-bench-202605:" in dockerfile
    instruction = (dst / "instruction.md").read_text()
    assert "Environment setup" in instruction
    assert "encode/httpx" in instruction
    assert "b5addb64f0161ff6bfe94c124ef76f6a1fba5254" in instruction
    toml = (dst / "task.toml").read_text()
    assert "docker_image" not in toml
    assert 'network_mode = "public"' in toml
    # Verifier stays isolated.
    assert toml.count('network_mode = "no-network"') >= 1
    assert (dst / "tests" / "test.sh").is_file()
    assert (dst / "SETUP_VARIANT_MANIFEST.json").is_file()
