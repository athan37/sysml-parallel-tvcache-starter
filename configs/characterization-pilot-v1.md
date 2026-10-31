# Characterization pilot v1 (shared with teammate)

Goal: same harness + same tasks; vary only the model. Measure whether tool-call patterns differ.

## Models

| Person | Model id string (log exactly) | Where |
| --- | --- | --- |
| Guohao | `Qwen/Qwen3.5-9B` | NERSC inference + Mac Harbor/Pi |
| Teammate | exact local id, e.g. `Qwen/Qwen3-4B-Instruct` | local |

## Tasks (3)

| # | DeepSWE task id | Language | Why |
| --- | --- | --- | --- |
| 1 | `clack-async-autocomplete-options` | TypeScript | Multi-file async UI lifecycle; pipeline already validated on our Harbor path |
| 2 | `httpx-streaming-json-iteration` | Python | Clear API surface across response/stream/codec paths; likely multi-read exploration |
| 3 | `actionlint-action-pinning-lint` | Go | New lint rule + config wiring; forces navigate/check/config file reads |

Use the **official** task directories under `vendor/deep-swe/tasks/<task_id>/`. Same image/instruction/verifier. No setup-as-agent-actions variant in this pilot.

## Fixed inference / harness knobs

| Knob | Value |
| --- | --- |
| Harbor | `0.24.0` |
| Pi | `1.4.0` |
| Agent | Pi (`-a pi` or equivalent loopback adapter that does **not** change tools) |
| Cache | **none** (`cache_mode=none`, no TVCache) |
| `model_api` | `openai-completions` |
| `thinking` | **off** |
| `max_turns` | **50** |
| temperature | **0.7** |
| top_p | **0.9** |
| Attempts per task | **5** (`k=5` or five separate `k=1` runs with attempt index 1..5) |
| Network policy | keep official task `no-network` agent policy |

Do not change instruction text, Dockerfile, or verifier. Reward 0 is a valid graded outcome; keep the attempt.

## Budget

- Per person: 3 tasks × 5 attempts = **15** trials
- Team total: **30** trials

## Trace format (required, so we can count commands)

**Primary: standard Harbor trial layout.** Do not substitute a custom log format for this. Every attempt must leave an intact Harbor job tree; analysis reads Pi sessions from it. Optional CSV/manifest exports are secondary.

### 1. Native Harbor / Pi (source of truth)

Preserve the trial folder under `jobs/` (Harbor’s default), especially:

```text
jobs/<job-or-run-id>/<task_id>__<suffix>/
  result.json
  config.json / lock.json
  agent/pi/sessions/*.jsonl          # REQUIRED for tool-call counting
  agent/trajectory.json               # if present
  agent/pi.txt                        # if present
  verifier/reward.json
  verifier/ctrf.json                  # if present
  artifacts/logs/artifacts/model.patch
```

Use a distinct Harbor `--job-name` (or jobs subdir) per campaign wave so runs are not overwritten. Never delete graded trials to “clean up.”

Pi session JSONL: each assistant message is one **turn**. Tool calls are content parts with `"type":"toolCall"` (or `tool_call`) and fields `id`, `name`, `arguments`.

Counting rules (both people use these):

- Turn = assistant message in the session JSONL (including zero-call final messages)
- Tool call / “command” = one `toolCall` part (`read`, `bash`, `edit`, `write`, …)
- Parallel turn = turn with **>1** toolCall
- Parallel-turn % = (# parallel turns) / (# all assistant turns)
- Per-tool rows: count only that tool’s calls on the same all-turn denominator

### 2. Shared run manifest (one JSON per person or per campaign)

```json
{
  "benchmark": "DeepSWE",
  "purpose": "model-comparison-pilot-v1",
  "cache_mode": "none",
  "harness": {"harbor": "0.24.0", "pi": "1.4.0"},
  "inference": {
    "thinking": "off",
    "max_turns": 50,
    "temperature": 0.7,
    "top_p": 0.9
  },
  "model": "Qwen/Qwen3.5-9B",
  "attempts": [
    {
      "id": "clack-async-autocomplete-options-a01",
      "task": "clack-async-autocomplete-options",
      "attempt": 1,
      "path": "jobs/.../clack-async-autocomplete-options__XXXX",
      "include": true,
      "reason": ""
    }
  ]
}
```

Set `"include": false` only for infrastructure failures (backend crash, no session). Keep graded reward-0 / zero-tool attempts with `"include": true`.

### 3. Normalized tool-call CSV (one row per tool call)

Write `traces/<model_slug>/<task_id>/attempt-0N.calls.csv` with header:

```text
model,task_id,attempt,session_path,turn_id,call_id,tool_name,arguments_json,hit,cache_mode
```

- `hit` = `false` for this uncached pilot
- `cache_mode` = `none`
- `arguments_json` = compact JSON of the tool arguments (needed to see duplicate commands)

Optional companion `attempt-0N.turns.csv`:

```text
model,task_id,attempt,turn_id,n_calls,tool_names
```

where `tool_names` is a `|`-joined list in emission order.

### 4. Analysis command (either side)

From this repo (or a shared copy of the analyzer):

```sh
.venv/bin/python scripts/export_characterization.py configs/manifests/<your-manifest>.json \
  --output-dir results/characterization/<model_slug>-pilot-v1
```

Share: manifest, `table1-workload.csv`, CDF JSON/SVG, and the native `agent/pi/sessions/*.jsonl` files.

## Out of scope for this pilot

- Pass@k as the primary metric (still record reward)
- TVCache A/B/C
- Setup-as-agent-actions task variants
- Pooling both models before reporting per-model CDFs
