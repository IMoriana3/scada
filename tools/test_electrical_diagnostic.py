#!/usr/bin/env python3
"""Tests for explainable electrical diagnostic rules."""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "api"))

from electrical_diagnostic import (  # noqa: E402
    ElectricalDiagnosticError,
    diagnose_sibling_strings,
)

MPPT = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
S = [
    "11111111-1111-4111-8111-111111111111",
    "22222222-2222-4222-8222-222222222222",
    "33333333-3333-4333-8333-333333333333",
    "44444444-4444-4444-8444-444444444444",
]


def rows(ratios):
    return [
        {
            "asset_id": asset,
            "actual_dc_power_kw": 10.0 * ratio,
            "expected_dc_power_kw": 10.0,
            "quality": "GOOD",
            "freshness": "FRESH",
        }
        for asset, ratio in zip(S, ratios)
    ]


def test_localized_string_underperformance_is_explicit():
    out = diagnose_sibling_strings(
        rows([1.00, 1.02, 0.72, 0.99]),
        mppt_asset_id=MPPT,
    )
    assert out["status"] == "ANOMALY"
    assert len(out["diagnoses"]) == 1
    d = out["diagnoses"][0]
    assert d["asset_id"] == S[2]
    assert d["code"] == "LOCALIZED_STRING_UNDERPERFORMANCE"
    assert "measure_voc" in d["recommended_checks"]


def test_common_mode_drop_is_not_blames_one_string():
    out = diagnose_sibling_strings(
        rows([0.78, 0.79, 0.80, 0.78]),
        mppt_asset_id=MPPT,
    )
    assert out["status"] == "COMMON_MODE_UNDERPERFORMANCE"
    assert out["diagnoses"] == []
    assert "curtailment_or_ppc_limit" in out["next_evidence"]


def test_curtailment_blocks_fault_attribution():
    out = diagnose_sibling_strings(
        rows([0.60, 0.61, 0.59, 0.60]),
        mppt_asset_id=MPPT,
        curtailment_active=True,
    )
    assert out["status"] == "CURTAILMENT_PRESENT_NO_FAULT_ATTRIBUTION"
    assert out["diagnoses"] == []


def test_missing_or_bad_quality_evidence_yields_unknown():
    bad = rows([1.0, 1.0, 1.0])
    bad[0]["quality"] = "BAD"
    bad[1]["freshness"] = "STALE"
    out = diagnose_sibling_strings(bad, mppt_asset_id=MPPT)
    assert out["status"] == "UNKNOWN_INSUFFICIENT_EVIDENCE"
    assert out["evidence"]["usable_strings"] == 1


def test_normal_group_is_ok():
    out = diagnose_sibling_strings(
        rows([0.98, 1.01, 1.00, 0.99]),
        mppt_asset_id=MPPT,
    )
    assert out["status"] == "OK"
    assert out["diagnoses"] == []


def test_identity_is_never_normalized_or_guessed():
    try:
        diagnose_sibling_strings(
            rows([1.0, 1.0, 1.0]),
            mppt_asset_id=MPPT.upper(),
        )
    except ElectricalDiagnosticError:
        pass
    else:
        raise AssertionError("noncanonical MPPT id accepted")


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items())
             if k.startswith("test_") and callable(v)]
    for test in tests:
        test()
        print("OK", test.__name__)
    print(f"{len(tests)} electrical diagnostic tests OK")
