#!/usr/bin/env python3
"""Copy a DeepSWE task, optionally as a handout setup-as-agent-actions variant.

Default (copy only):
  python scripts/prepare_task.py <task_id>

Handout variant (thin agent image + setup preamble in instruction.md):
  python scripts/prepare_task.py <task_id> --setup-as-agent-actions

Never mutates vendor/deep-swe. Verifier/tests are left authoritative.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
from pathlib import Path

try:
    import tomllib
except ImportError:  # pragma: no cover
    import tomli as tomllib  # type: ignore


PREAMBLE_TEMPLATE = """\
# Environment setup (do this first)

This task starts from a **base image without the repository pre-installed**.
Before solving the coding task below, set up the workspace yourself:

1. Work in `/app` (create/clean as needed so `/app` becomes the project root).
2. Clone and pin the repository (do **not** use a newer commit than the pin):
   - repository: `{repository_url}`
   - required commit (BASE_SHA): `{base_commit_hash}`
3. Run the following setup commands (adapted from the original environment
   Dockerfile). Preserve a real branch at BASE_SHA and remove remote/future
   history so you cannot see later commits or a reference solution:

```bash
{setup_script}
```

4. After setup succeeds, solve the original task described below. Work on a new
   branch from the pinned default branch and commit when done.

---

# Original task

"""

# Agent must reach git forges + language package indexes during setup.
# Verifier stays no-network. Tighten later if allowlist is preferred.
DEFAULT_AGENT_NETWORK_MODE = "public"

DEFAULT_ALLOWED_HOSTS = [
    "github.com",
    "*.github.com",
    "*.githubusercontent.com",
    "registry.npmjs.org",
    "registry.yarnpkg.com",
    "pypi.org",
    "files.pythonhosted.org",
    "proxy.golang.org",
    "sum.golang.org",
    "storage.googleapis.com",
]


def _parse_dockerfile(text: str) -> dict:
    """Split a DeepSWE-style Dockerfile into base image, env, and setup RUNs."""
    lines = text.splitlines()
    from_image = None
    env_lines: list[str] = []
    setup_runs: list[str] = []
    i = 0
    while i < len(lines):
        raw = lines[i]
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            i += 1
            continue
        upper = stripped.split(maxsplit=1)[0].upper()
        if upper == "FROM":
            from_image = stripped.split(maxsplit=1)[1].strip()
            i += 1
            continue
        if upper == "WORKDIR":
            i += 1
            continue
        if upper == "ENV":
            env_lines.append(stripped)
            i += 1
            continue
        if upper == "ARG":
            # BASE_SHA etc. become instruction variables; skip in thin image.
            i += 1
            continue
        if upper == "CMD":
            i += 1
            continue
        if upper == "RUN":
            parts = [stripped[3:].lstrip()]
            while parts[-1].endswith("\\"):
                parts[-1] = parts[-1][:-1].rstrip()
                i += 1
                if i >= len(lines):
                    break
                parts.append(lines[i].strip())
            body = " ".join(p for p in parts if p)
            # Normalize "cd /app &&" prefix noise for the agent script.
            setup_runs.append(body)
            i += 1
            continue
        # Unknown directive: keep as a comment in the review summary only.
        i += 1
    if not from_image:
        raise SystemExit("Dockerfile missing FROM")
    return {"from": from_image, "env": env_lines, "runs": setup_runs}


def _runs_to_shell(runs: list[str], repository_url: str, base_sha: str) -> str:
    """Turn Dockerfile RUN bodies into a bash script for the agent preamble."""
    blocks: list[str] = []
    for run in runs:
        # Substitute build-arg style BASE_SHA if present as literal in RUN.
        run = run.replace("$BASE_SHA", base_sha)
        run = re.sub(r"\$\{BASE_SHA\}", base_sha, run)
        # If clone URL in Dockerfile differs, still document toml URL as source of truth.
        blocks.append(run.strip())
    header = [
        "set -euo pipefail",
        "mkdir -p /app",
        "cd /app",
        # Base image may ship an empty workdir or leftover files; clone needs empty/ownable /app.
        "find /app -mindepth 1 -maxdepth 1 -exec rm -rf {} +",
        f"# Expected repository: {repository_url}",
        f"BASE_SHA={base_sha}",
    ]
    return "\n".join(header + blocks) + "\n"


def _thin_dockerfile(
    from_image: str,
    env_lines: list[str],
    *,
    wipe_app: bool = False,
) -> str:
    parts = [
        f"FROM {from_image}",
        "",
        "WORKDIR /app",
        "",
        "# Setup-as-agent-actions variant: agent must clone/build from instruction.md.",
        "",
    ]
    if wipe_app:
        parts.extend(
            [
                "# Start from the published task image (cached locally) but clear /app so",
                "# the workspace is empty — agent still performs setup. Prefer --base-strategy",
                "# mars when public.ecr.aws/x8v8d7g8/mars-base:latest is pullable.",
                "RUN find /app -mindepth 1 -maxdepth 1 -exec rm -rf {} + || true",
                "",
            ]
        )
    else:
        parts.extend(
            [
                "# Thin base: no repo clone/install at image build.",
                "",
            ]
        )
    for env in env_lines:
        parts.append(env)
    if env_lines:
        parts.append("")
    parts.append('CMD ["/bin/bash"]')
    parts.append("")
    return "\n".join(parts)


def _patch_task_toml(
    text: str,
    *,
    task_id: str,
    agent_network_mode: str,
    allowed_hosts: list[str] | None,
) -> str:
    """Best-effort TOML rewrite without dropping unknown tables."""
    # Remove prebuilt agent image so Harbor builds environment/Dockerfile.
    text = re.sub(
        r'(?m)^docker_image\s*=\s*"[^"]*"\s*\n',
        "",
        text,
        count=1,
    )
    # Ensure metadata task_id reflects variant name if renamed.
    text = re.sub(
        r'(?m)^(task_id\s*=\s*")[^"]*(")',
        rf"\g<1>{task_id}\g<2>",
        text,
        count=1,
    )
    # Agent network: allow setup traffic.
    if re.search(r"(?m)^\[agent\]", text):
        if re.search(r"(?ms)^\[agent\].*?^network_mode\s*=", text):
            text = re.sub(
                r"(?ms)(^\[agent\][^\[]*?^network_mode\s*=\s*)[^\n]+",
                rf'\g<1>"{agent_network_mode}"',
                text,
                count=1,
            )
        else:
            text = re.sub(
                r"(?m)^(\[agent\]\s*\n)",
                rf'\g<1>network_mode = "{agent_network_mode}"\n',
                text,
                count=1,
            )
    if agent_network_mode == "allowlist" and allowed_hosts:
        hosts_toml = ", ".join(f'"{h}"' for h in allowed_hosts)
        if re.search(r"(?ms)^\[agent\].*?^allowed_hosts\s*=", text):
            text = re.sub(
                r"(?ms)(^\[agent\][^\[]*?^allowed_hosts\s*=\s*)\[[^\]]*\]",
                rf"\g<1>[{hosts_toml}]",
                text,
                count=1,
            )
        else:
            text = re.sub(
                r'(?m)^(network_mode\s*=\s*"allowlist"\s*\n)',
                rf"\g<1>allowed_hosts = [{hosts_toml}]\n",
                text,
                count=1,
            )
    # Mark variant in task name if present.
    text = re.sub(
        r'(?m)^(name\s*=\s*"datacurve/)([^"]+)(")',
        rf"\g<1>\g<2>-setup\g<3>",
        text,
        count=1,
    )
    return text


def prepare_copy(src: Path, dst: Path) -> None:
    if not (src / "task.toml").is_file():
        raise SystemExit(f"Missing task.toml: {src}")
    if dst.exists():
        raise SystemExit(f"Will not overwrite: {dst}")
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(src, dst)


def prepare_setup_variant(
    src: Path,
    dst: Path,
    *,
    agent_network_mode: str,
    allowed_hosts: list[str] | None,
    base_strategy: str = "prebuilt-wipe",
) -> dict:
    prepare_copy(src, dst)
    dockerfile_path = dst / "environment" / "Dockerfile"
    instruction_path = dst / "instruction.md"
    toml_path = dst / "task.toml"
    if not dockerfile_path.is_file():
        raise SystemExit(f"Missing {dockerfile_path}")
    meta = tomllib.loads(toml_path.read_text())
    md = meta.get("metadata") or {}
    repository_url = md.get("repository_url") or ""
    base_commit = md.get("base_commit_hash") or ""
    if not repository_url or not base_commit:
        raise SystemExit(f"{toml_path}: need metadata.repository_url and base_commit_hash")

    env_cfg = meta.get("environment") or {}
    prebuilt = env_cfg.get("docker_image")
    parsed = _parse_dockerfile(dockerfile_path.read_text())
    setup_script = _runs_to_shell(parsed["runs"], repository_url, base_commit)

    if base_strategy == "mars":
        from_image = parsed["from"]
        wipe_app = False
    elif base_strategy == "prebuilt-wipe":
        if not prebuilt:
            raise SystemExit(
                f"{toml_path}: prebuilt-wipe needs [environment].docker_image on the source task"
            )
        from_image = prebuilt
        wipe_app = True
    else:
        raise SystemExit(f"Unknown base_strategy: {base_strategy}")

    dockerfile_path.write_text(
        _thin_dockerfile(from_image, parsed["env"], wipe_app=wipe_app)
    )
    original_instruction = instruction_path.read_text()
    instruction_path.write_text(
        PREAMBLE_TEMPLATE.format(
            repository_url=repository_url,
            base_commit_hash=base_commit,
            setup_script=setup_script.rstrip(),
        )
        + original_instruction
    )
    variant_id = dst.name
    toml_path.write_text(
        _patch_task_toml(
            toml_path.read_text(),
            task_id=variant_id,
            agent_network_mode=agent_network_mode,
            allowed_hosts=allowed_hosts,
        )
    )
    summary = {
        "source": str(src),
        "destination": str(dst),
        "repository_url": repository_url,
        "base_commit_hash": base_commit,
        "base_strategy": base_strategy,
        "from_image": from_image,
        "setup_run_count": len(parsed["runs"]),
        "setup_runs": parsed["runs"],
        "agent_network_mode": agent_network_mode,
        "docker_image_cleared": True,
        "verifier_untouched": True,
    }
    (dst / "SETUP_VARIANT_MANIFEST.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summary


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("task_id")
    p.add_argument("--source", type=Path, default=Path("vendor/deep-swe/tasks"))
    p.add_argument(
        "--destination",
        type=Path,
        default=None,
        help="Destination directory (parent). Default depends on mode.",
    )
    p.add_argument(
        "--setup-as-agent-actions",
        action="store_true",
        help="Emit handout variant: thin Dockerfile + setup preamble.",
    )
    p.add_argument(
        "--agent-network-mode",
        default=DEFAULT_AGENT_NETWORK_MODE,
        choices=("public", "allowlist", "no-network"),
    )
    p.add_argument(
        "--base-strategy",
        default="prebuilt-wipe",
        choices=("prebuilt-wipe", "mars"),
        help="prebuilt-wipe: FROM cached swe-bench image and clear /app (default; works offline). "
        "mars: true thin mars-base (needs ECR pull).",
    )
    p.add_argument(
        "--force",
        action="store_true",
        help="Delete destination if it already exists.",
    )
    a = p.parse_args()
    src = a.source / a.task_id
    if a.destination is None:
        if a.setup_as_agent_actions:
            dest_parent = Path("variants/deep-swe-setup/tasks")
            dst = dest_parent / a.task_id
        else:
            dest_parent = Path("results/tasks")
            dst = dest_parent / a.task_id
    else:
        dst = a.destination / a.task_id if a.destination.name != a.task_id else a.destination

    if a.force and dst.exists():
        shutil.rmtree(dst)

    if a.setup_as_agent_actions:
        hosts = DEFAULT_ALLOWED_HOSTS if a.agent_network_mode == "allowlist" else None
        summary = prepare_setup_variant(
            src,
            dst,
            agent_network_mode=a.agent_network_mode,
            allowed_hosts=hosts,
            base_strategy=a.base_strategy,
        )
        print(json.dumps(summary, indent=2))
        print(
            f"\nWrote setup-as-agent-actions variant to {dst}\n"
            "Review SETUP_VARIANT_MANIFEST.json, environment/Dockerfile, "
            "instruction.md preamble, and [agent] network_mode. "
            "Verifier/tests were not modified."
        )
    else:
        prepare_copy(src, dst)
        print(
            f"Copied task to {dst}\nInspect environment/Dockerfile and instruction.md manually.\n"
            "For the handout variant, re-run with --setup-as-agent-actions."
        )


if __name__ == "__main__":
    main()
