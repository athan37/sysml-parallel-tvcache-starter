"""Opt-in Pi agents that append multi-tool-turn steering to the system prompt.

Does not change Harbor's stock `-a pi` or LoopbackPi. Use explicitly:

  harbor run ... -a parallel_tvcache.evaluation.multitool_pi:MultitoolPi \\
    --ak max_turns=8 ...

  # NERSC / socket path:
  harbor run ... -a parallel_tvcache.evaluation.multitool_pi:MultitoolLoopbackPi ...

Steering is injected via the same before_agent_start extension Harbor already
uses for max_turns (requires --ak max_turns=N, or SYSML_MAX_TURNS).
"""
from __future__ import annotations

import os

from harbor.agents.installed.pi import Pi

from parallel_tvcache.evaluation.loopback_pi import LoopbackPi

_MULTITOOL_STEERING = (
    "Two phases: (1) Environment setup MUST be sequential — prefer one bash "
    "with the full setup script; never parallelize clone/install with reads. "
    "(2) Only AFTER setup succeeds, maximize parallel tool use: whenever steps "
    "are independent, emit AS MANY tool calls as possible in the SAME turn "
    "(prefer 5+ reads/searches together). Never issue independent reads or "
    "searches one-per-turn. Dependent or mutating steps stay sequential."
)


def _multitool_max_turns_extension(max_turns: int) -> str:
    # Same shape as Harbor Pi._build_max_turns_extension, plus multitool blurb.
    return f"""export default function (pi: any) {{
  const maxTurns = {max_turns};
  let completedTurns = 0;

  pi.on("before_agent_start", (event: any) => ({{
    systemPrompt: `${{event.systemPrompt}}\\n\\nYou have a hard budget of ${{maxTurns}} model turns. Complete the task and provide your final answer within that budget.\\n\\n{_MULTITOOL_STEERING}`,
  }}));

  pi.on("turn_end", (_event: any, ctx: any) => {{
    completedTurns += 1;
    if (completedTurns >= maxTurns) {{
      ctx.abort();
    }}
  }});
}}
"""


def _ensure_max_turns(agent: Pi) -> None:
    if agent.options.max_turns is not None:
        return
    raw = os.environ.get("SYSML_MAX_TURNS", "8").strip()
    agent.options.max_turns = int(raw) if raw else 8


class MultitoolPi(Pi):
    """Stock Harbor Pi + multi-tool system-prompt steering (for local MLX / --base-url)."""

    @staticmethod
    def _build_max_turns_extension(max_turns: int) -> str:
        return _multitool_max_turns_extension(max_turns)

    async def run(self, instruction, environment, context):
        _ensure_max_turns(self)
        await super().run(instruction, environment, context)


class MultitoolLoopbackPi(LoopbackPi):
    """LoopbackPi (NERSC socket path) + the same multi-tool steering."""

    @staticmethod
    def _build_max_turns_extension(max_turns: int) -> str:
        return _multitool_max_turns_extension(max_turns)

    async def run(self, instruction, environment, context):
        _ensure_max_turns(self)
        await super().run(instruction, environment, context)
