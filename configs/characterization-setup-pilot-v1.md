# Characterization pilot — setup-as-agent-actions (handout-faithful)

Replaces the unmodified-task cell in `characterization-pilot-v1.md` for handout DeepSWE.
Prior `abl-9b-t8` on stock DeepSWE remains infrastructure / early evidence only.

## Cell

| Knob | Value |
| --- | --- |
| Tasks | setup variants under `variants/deep-swe-setup/tasks/<id>/` |
| Task ids | `clack-async-autocomplete-options`, `httpx-streaming-json-iteration`, `actionlint-action-pinning-lint` |
| Model | `Qwen/Qwen3.5-9B` |
| max_turns | 8 |
| thinking | off |
| Attempts | 5 per task (`pass@5`) |
| cache_mode | `none` |
| Harbor / Pi | 0.24.0 / 1.4.0 |
| Agent network | `public` (needed for clone/install); verifier stays `no-network` |

## Generate / refresh variants

```sh
for t in clack-async-autocomplete-options httpx-streaming-json-iteration actionlint-action-pinning-lint; do
  .venv/bin/python scripts/prepare_task.py "$t" --setup-as-agent-actions --force
  # default --base-strategy=prebuilt-wipe (cached swe-bench image, /app cleared).
  # Use --base-strategy mars when mars-base is pullable for a true thin base.
done
```

## Run

```sh
# Placeholders you may need to set:
#   SYSML_JOB_PREFIX   (default: char-setup-9b-t8v1)
#   SYSML_TUNNEL_LOCAL_PORT (default: 18086)
#   fresh NERSC sshproxy if expired
bash scripts/run_characterization_setup_9b_t8.sh
```

Prefer durable Mac runner: `screen -dmS char-setup bash scripts/run_characterization_setup_9b_t8.sh`
