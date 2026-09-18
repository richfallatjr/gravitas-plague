import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("compare_qwen_performance", ROOT / "Scripts/turing/compare_qwen_performance.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)
HASH = "a" * 64


def run_fixture(run_id, voice="big_mike", wall=10.0):
    policy = {"decoderReader": "legacy"}
    source = {key: HASH for key in MODULE.SOURCE_KEYS}
    contract = dict(MODULE.CONTRACT, resolvedCommandBufferProfile={"maximumOperations": 40, "maximumMegabytes": 32},
                    requestedCommandBufferProfile="operations40Megabytes32", recoveryDefines=["GR_TURING_METAL_STREAM_RECOVERY"],
                    seedPolicy="fixture seed + segment index", executionPolicy=policy, policySHA256=HASH, playbackRateApplied=False)
    return {
        "schemaVersion": 1, "runID": run_id, "status": "DEVICE_QUALIFICATION_PENDING", "outcome": "SCOUT_COMPLETED",
        "workload": {"id": voice + "-short", "origin": "fixture", "characterID": voice, "voiceID": voice + "_base_clone_v1",
                     "language": "English", "segments": ["Fixture"], "samplingSeed": 42},
        "workloadSHA256": HASH, "policy": policy, "policySHA256": HASH,
        "buildManifest": {"source": source, "binaryUUIDs": ["uuid"], "compile": {"commandsSHA256": HASH},
                          "toolchain": {"xcode": "27", "sdk": "xros27"}, "buildConfiguration": "Release",
                          "models": {"sha256": HASH}, "voices": {"sha256": HASH}},
        "compiledFingerprint": {"translationUnit": "mlx/mlx/backend/metal/allocator.cpp", "hardeningMode": "extensive",
                                "compiler": "clang27", "architecture": "arm64", "libcxxVersion": 210000, "experimentID": "baseline",
                                "optimized": True, "optimizeSize": False, "ndebug": True, "mlxTesting": False, "internalAssertionsEnabled": False},
        "binaryUUIDs": ["uuid"], "runtimeContract": contract,
        "observation": {"runID": run_id, "deviceModel": "Vision Pro M2", "osBuild": "visionOS27", "profilerState": "none",
                        "sceneCondition": "production-full-scene", "coldWarmDefinition": "cold process", "clockBasis": "ContinuousClock",
                        "initialThermalState": 0, "finalThermalState": 0},
        "identitySHA256": {key: HASH for key in MODULE.HASH_KEYS}, "installedPayloadSHA256": {"models": HASH, "voices": HASH},
        "renderWallSeconds": wall, "rawAudioSeconds": 5.0, "rawAudioRTF": wall / 5, "loadInclusiveWallSeconds": wall + 1,
        "coldLoadSeconds": 1.0, "firstNeededPCMSeconds": wall, "orderedPCMReady": [wall],
        "pcm": [{"segmentIndex": 0, "readySeconds": wall, "sampleCount": 120000, "sampleRate": 24000, "pcmSHA256": HASH}],
        "sampledPeakFootprintMiB": 4000, "residualFootprintMiB": 1500, "residualMLXActiveBytes": 0, "residualMLXCacheBytes": 0,
        "commandBuffers": {"submittedCount": 300, "completedCount": 300, "failureCount": 0,
                           "maximumGPUSeconds": .04, "maximumKernelSeconds": .035,
                           "fullRunAccounting": {"pendingCount": 0, "missingGPUTimestampCount": 0, "invalidGPUTimestampCount": 0,
                                                 "aggregate": {"submittedCount": 300, "completedCount": 300, "failureCount": 0}}},
    }


class PerformanceComparisonTests(unittest.TestCase):
    def setUp(self):
        self.gates = json.loads((ROOT / "qwen-performance-gates.json").read_text())
        self.gates["comparison"]["bootstrap_repetitions"] = 100

    def compare(self, a=None, b=None, **kwargs):
        return MODULE.compare(a or [run_fixture("a")], b or [run_fixture("b", wall=9)], self.gates, **kwargs)

    def test_current_report_schema_is_valid_but_not_device_qualified(self):
        self.assertEqual(MODULE.validate_run(run_fixture("a")), [])
        value = self.compare()
        self.assertEqual(value["comparability"], "COMPARABLE")
        self.assertEqual(value["promotionStatus"], "DEVICE_QUALIFICATION_PENDING")
        self.assertFalse(value["qualityFromPCMHash"])
        self.assertAlmostEqual(value["pooledPairedWallRatio"]["median"], .9)
        self.assertTrue(any("quality" in x for x in value["pendingQualification"]))

    def test_all_five_voices_five_interleaved_pairs_pass_only_performance_screen(self):
        a, b, orders = [], [], []
        for voice in self.gates["comparison"]["required_character_ids"]:
            for index in range(5):
                a.append(run_fixture(f"a-{voice}-{index}", voice))
                b.append(run_fixture(f"b-{voice}-{index}", voice, 9))
                orders.append({"baselineRunID": a[-1]["runID"], "candidateRunID": b[-1]["runID"], "order": "AB" if index % 2 else "BA"})
        value = self.compare(a, b, experiment={"id": "F1", "pairOrder": orders})
        self.assertEqual(value["performanceScreen"], "PERFORMANCE_SCREEN_PASSED")
        self.assertEqual(value["promotionStatus"], "DEVICE_QUALIFICATION_PENDING")
        self.assertFalse(value["readyForManualQualificationReview"])
        self.assertEqual(len(value["byCharacter"]), 5)

    def test_invalid_attempt_is_not_silently_removed_to_improve_median(self):
        bad = run_fixture("bad", wall=100)
        bad["failure"] = "device failed"
        value = self.compare([run_fixture("a0"), run_fixture("a1")], [run_fixture("b0", wall=1), bad])
        self.assertEqual(value["promotionStatus"], "REJECTED")
        self.assertEqual(value["pairCount"], 2)
        self.assertIsNone(value["pooledPairedWallRatio"])

    def test_nonfinite_is_rejected_and_output_stays_valid_json(self):
        b = run_fixture("b")
        b["firstNeededPCMSeconds"] = float("nan")
        b["orderedPCMReady"] = [float("nan")]
        value = self.compare(b=[b])
        self.assertEqual(value["performanceScreen"], "INVALID")
        json.dumps(value, allow_nan=False)

    def test_pending_or_missing_telemetry_is_invalid(self):
        for change in ("pending", "missing", "countMismatch"):
            b = run_fixture("b")
            if change == "pending":
                b["commandBuffers"]["fullRunAccounting"]["pendingCount"] = 1
            elif change == "missing":
                del b["commandBuffers"]["fullRunAccounting"]
            else:
                b["commandBuffers"]["fullRunAccounting"]["aggregate"]["submittedCount"] = 301
            self.assertEqual(self.compare(b=[b])["performanceScreen"], "INVALID")

    def test_source_mismatch_cannot_be_waived(self):
        b = run_fixture("b")
        b["buildManifest"]["source"]["commit"] = "b" * 64
        experiment = {"id": "bad", "allowedDifferences": {"source.commit": {"baseline": HASH, "candidate": "b" * 64}}}
        self.assertEqual(self.compare(b=[b], experiment=experiment)["performanceScreen"], "INVALID")

    def test_fresh2_topology_and_sampling_must_match(self):
        for field, value in (("laneCount", 1), ("admissionPolicy", "serialized")):
            b = run_fixture("b")
            b["runtimeContract"][field] = value
            self.assertEqual(self.compare(b=[b])["performanceScreen"], "INVALID")
        b = run_fixture("b")
        b["workload"]["samplingSeed"] = 7
        self.assertEqual(self.compare(b=[b])["performanceScreen"], "INVALID")

    def test_expected_build_difference_requires_named_exact_values(self):
        b = run_fixture("b")
        b["compiledFingerprint"]["hardeningMode"] = "fast"
        self.assertEqual(self.compare(b=[b])["performanceScreen"], "INVALID")
        experiment = {"id": "B-hardening", "allowedDifferences": {
            "compiledFingerprint.hardeningMode": {"baseline": "extensive", "candidate": "fast"}}}
        value = self.compare(b=[b], experiment=experiment)
        self.assertEqual(value["comparability"], "COMPARABLE")
        experiment["allowedDifferences"]["compiledFingerprint.hardeningMode"]["candidate"] = "debug"
        self.assertEqual(self.compare(b=[b], experiment=experiment)["performanceScreen"], "INVALID")

    def test_first_needed_is_not_fastest_packet(self):
        b = run_fixture("b")
        b["firstNeededPCMSeconds"] = 1
        self.assertEqual(self.compare(b=[b])["performanceScreen"], "INVALID")

    def test_rtf_is_wall_over_raw_audio(self):
        b = run_fixture("b")
        b["rawAudioRTF"] = .5
        self.assertEqual(self.compare(b=[b])["performanceScreen"], "INVALID")

    def test_more_than_five_percent_latency_or_memory_requires_review(self):
        b = run_fixture("b", wall=11)
        b["sampledPeakFootprintMiB"] = 4300
        value = self.compare(b=[b])
        self.assertEqual(value["performanceScreen"], "REGRESSION_REVIEW")
        self.assertGreaterEqual(len(value["reviewRequired"]), 3)

    def test_thermal_transition_is_retained_invalid_attempt(self):
        b = run_fixture("b")
        b["observation"]["finalThermalState"] = 1
        value = self.compare(b=[b])
        self.assertEqual(value["performanceScreen"], "INVALID")
        self.assertTrue(any("thermal transition" in x for x in value["errors"]))

    def test_output_length_change_is_not_same_work_speedup(self):
        b = run_fixture("b", wall=8)
        b["pcm"][0]["sampleCount"] = 96000
        b["rawAudioSeconds"] = 4
        b["rawAudioRTF"] = 2
        value = self.compare(b=[b])
        self.assertEqual(value["comparability"], "COMPARABLE")
        self.assertTrue(any("same-work" in x for x in value["pendingQualification"]))

    def test_duplicate_run_is_not_repetition(self):
        self.assertEqual(self.compare([run_fixture("a")] * 2, [run_fixture("b")] * 2)["performanceScreen"], "INVALID")

    def test_no_quality_evidence_from_matching_pcm_hashes(self):
        value = self.compare()
        self.assertFalse(value["evidence"]["quality"]["verifiedArtifact"])

    def test_bootstrap_is_deterministic_and_reports_no_p95_claim(self):
        a = MODULE.summary([.8, .9, 1, .9, .95], self.gates["comparison"])
        self.assertEqual(a, MODULE.summary([.8, .9, 1, .9, .95], self.gates["comparison"]))
        self.assertFalse(a["robustTailPercentileClaim"])
        self.assertLess(a["medianUncertaintyInterval"][0], a["medianUncertaintyInterval"][1])

    def test_host_results_never_qualify_headset(self):
        a, b = run_fixture("a"), run_fixture("b")
        for run in (a, b):
            run["observation"]["deviceModel"] = "Mac15,5"
            run["observation"]["sceneCondition"] = "isolated-host-no-scene"
        value = self.compare([a], [b])
        self.assertTrue(any("Host/device" in x for x in value["pendingQualification"]))

    def test_evidence_artifact_must_exist_match_hash_and_use_precalibrated_tolerance(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = {"quality": {"status": "PASS", "artifact": "missing.json", "sha256": HASH,
                                    "tolerancesCommittedBeforeAssessment": True}}
            value = self.compare(evidence=evidence, evidence_root=Path(directory))
            self.assertFalse(value["evidence"]["quality"]["verifiedArtifact"])

    def test_malformed_report_remains_rejected_attempt(self):
        value = self.compare(b=[{"workload": "invalid"}])
        self.assertEqual(value["performanceScreen"], "INVALID")
        self.assertEqual(value["pairCount"], 1)


if __name__ == "__main__":
    unittest.main()
