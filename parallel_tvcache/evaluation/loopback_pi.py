"""Opt-in inference transport around official Harbor Pi; unchanged tool loop.

No caching. Requires a model-only Unix socket bind at /run/sysml-model/model.sock.
Never imported by the ordinary `-a pi` baseline.
"""
import os
from pathlib import Path

from harbor.agents.installed.pi import Pi


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    return int(raw) if raw else default


class LoopbackPi(Pi):
    def _build_custom_models_json(self, access, model_id):
        config = super()._build_custom_models_json(access, model_id)
        if config is None:
            raise ValueError('The loopback smoke requires an explicit model endpoint')
        context_window = _env_int('SYSML_CONTEXT_WINDOW', 8192)
        max_tokens = _env_int('SYSML_MAX_TOKENS', 1024)
        for provider in config['providers'].values():
            for model in provider['models']:
                model.update(contextWindow=context_window, maxTokens=max_tokens)
        return config

    async def install(self, environment):
        await super().install(environment)
        await environment.upload_file(
            Path(__file__).resolve().parents[1] / 'inference' / 'model_transport.py', '/tmp/sysml-model-transport.py')
        await self.exec_as_agent(environment, command=(
            'nohup python3 /tmp/sysml-model-transport.py sandbox '
            '--socket /run/sysml-model/model.sock --port 18081 '
            '</dev/null >/tmp/sysml-model-transport.log 2>&1 &'))

    async def run(self, instruction, environment, context):
        # Runs inside Harbor's agent phase. Default DeepSWE cell: no-network +
        # model via Unix-socket relay. Setup-as-agent-actions variants need
        # public/allowlist egress for clone/install; set SYSML_ALLOW_AGENT_EGRESS=1
        # (or rely on a non-no-network agent policy) and skip the isolation probe.
        mode = environment.network_policy.network_mode.value
        allow_egress = (
            os.environ.get('SYSML_ALLOW_AGENT_EGRESS', '').strip() in ('1', 'true', 'yes')
            or mode in ('public', 'allowlist')
        )
        if mode != 'no-network' and not allow_egress:
            raise RuntimeError(
                'The optional transport requires no-network agent policy '
                '(or SYSML_ALLOW_AGENT_EGRESS=1 / public|allowlist for setup variants)'
            )
        expected_model = os.environ.get('SYSML_MODEL_ID', 'Qwen/Qwen3-0.6B')
        if allow_egress:
            probe = f"""python3 - <<'PYPROBE'
import json, time, urllib.request
expected = {expected_model!r}
for attempt in range(30):
    try:
        models = json.load(urllib.request.urlopen('http://127.0.0.1:18081/v1/models', timeout=15))
        break
    except OSError:
        if attempt == 29:
            raise
        time.sleep(0.1)
assert any(m['id'] == expected for m in models['data']), (expected, models)
print('MODEL_LOOPBACK_OK; AGENT_EGRESS_ALLOWED')
PYPROBE"""
        else:
            probe = f"""python3 - <<'PYPROBE'
import json, time, urllib.request
expected = {expected_model!r}
for attempt in range(30):
    try:
        models = json.load(urllib.request.urlopen('http://127.0.0.1:18081/v1/models', timeout=15))
        break
    except OSError:
        if attempt == 29:
            raise
        time.sleep(0.1)
assert any(m['id'] == expected for m in models['data']), (expected, models)
try:
    urllib.request.urlopen('http://1.1.1.1/', timeout=5)
except Exception:
    print('MODEL_LOOPBACK_OK; EXTERNAL_HTTP_PROBE_FAILED')
else:
    raise RuntimeError('Unexpected external HTTP access; aborting smoke test')
PYPROBE"""
        result = await self.exec_as_agent(environment, command=probe)
        (self.logs_dir / 'model-network-probe.txt').write_text(result.stdout or '')
        await super().run(instruction, environment, context)
