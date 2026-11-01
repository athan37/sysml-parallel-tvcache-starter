from pathlib import Path
import json

from parallel_tvcache.measurement.campaign import (
    analyze_selected,
    load_manifest,
    select_attempt_roots,
    table_rows,
    write_cdf_exports,
    write_table_csv,
)

ROOT = Path(__file__).resolve().parents[1]


def test_manifest_excludes_infrastructure_failure(tmp_path):
    good = tmp_path / "good.jsonl"
    bad = tmp_path / "bad"
    bad.mkdir()
    good.write_text("\n".join([
        json.dumps({"type": "message", "message": {"role": "assistant", "content": [
            {"type": "toolCall", "name": "read", "id": "a", "arguments": {}},
            {"type": "toolCall", "name": "read", "id": "b", "arguments": {}},
        ]}}),
        json.dumps({"type": "message", "message": {"role": "assistant", "content": []}}),
    ]))
    (bad / "noise.jsonl").write_text(json.dumps({
        "type": "message", "message": {"role": "assistant", "content": [
            {"type": "toolCall", "name": "bash", "id": "x", "arguments": {}},
        ]}
    }) + "\n")
    manifest = {
        "benchmark": "DeepSWE",
        "purpose": "unit",
        "model": "test",
        "cache_mode": "none",
        "attempts": [
            {"id": "good", "path": str(good), "include": True},
            {"id": "bad", "path": str(bad), "include": False, "reason": "infra"},
        ],
    }
    man_path = tmp_path / "manifest.json"
    man_path.write_text(json.dumps(manifest))
    loaded = load_manifest(man_path)
    attempts = select_attempt_roots(loaded, tmp_path)
    result = analyze_selected(attempts, benchmark="DeepSWE")
    assert result["sessions"] == 1
    assert result["turns"] == 2
    assert result["tool_calls"] == 2
    assert result["parallel_turn_fraction"] == 0.5
    assert len(result["excluded_attempts"]) == 1
    assert result["excluded_attempts"][0]["reason"] == "infra"
    rows = table_rows(result, "DeepSWE")
    assert rows[0]["tool_type"] == "All tools"
    assert rows[0]["turns_with_gt1_tool_call_pct"] == 50.0
    out = tmp_path / "out"
    write_table_csv(rows, out / "table1-workload.csv")
    written = write_cdf_exports(result, out / "cdf", "DeepSWE")
    assert (out / "table1-workload.csv").exists()
    assert any(p.name == "cdf-all-tools.svg" for p in written)


def test_real_smoke_manifest_loads():
    path = ROOT / "configs" / "manifests" / "m4999-0.6b-smoke.json"
    # Optional local-evidence test; manifests/ and old smoke jobs are not required in-repo.
    if not path.exists() or not (ROOT / "jobs" / "m4999-pi-60365877").exists():
        return
    manifest = load_manifest(path)
    attempts = select_attempt_roots(manifest, ROOT)
    result = analyze_selected(attempts, benchmark=manifest["benchmark"])
    assert result["turns"] == 1
    assert result["tool_calls"] == 0
    assert result["parallel_turn_fraction"] == 0.0
    assert len(result["included_attempts"]) == 1
    assert len(result["excluded_attempts"]) == 1
