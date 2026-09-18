import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import struct
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("compare_qwen_quality_evidence", ROOT / "Scripts/turing/compare_qwen_quality_evidence.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
HASH = "a" * 64


def wav_bytes(samples, rate=24000):
    payload = struct.pack("<" + "f" * len(samples), *samples)
    data = (b"RIFF" + struct.pack("<I", 48 + len(payload)) + b"WAVEfmt "
            + struct.pack("<IHHIIHH", 16, 3, 1, rate, rate * 4, 4, 32)
            + b"fact" + struct.pack("<II", 4, len(samples))
            + b"data" + struct.pack("<I", len(payload)) + payload)
    return data, payload


def write_json(path, value):
    data = json.dumps(value, sort_keys=True, indent=2).encode()
    path.write_bytes(data)
    return data


def write_fixture(root, run_id, rows=None, eos=True, arithmetic="legacy", samples=None):
    root.mkdir()
    rows = rows if rows is not None else [list(range(16)), list(range(16, 32))]
    references = [list(range(32, 48)), list(range(48, 64))]
    seed = 9_155_153_355_066_127_096
    workload = dict(schemaVersion=1, id="full", origin="test", characterID="big_mike", voiceID="voice",
                    language="English", segments=["Native full segment"], samplingSeed=seed,
                    maximumRowsPerSegment=160, wallCapSeconds=180, footprintCapMiB=6000,
                    requireCompleteSegments=True)
    policy = dict(zip(MODULE.POLICY_KEYS, [1, arithmetic, "legacyDense", "legacy", "legacy", "legacy", "existing", "legacy"]))
    write_json(root / "workload.json", workload)
    write_json(root / "policy.json", policy)
    codes = dict(schemaVersion=1, runID=run_id, voiceID="voice", segmentIndex=0,
                 generatedCodeRows=rows, conditioningReferenceCodeRows=references,
                 decodeReferenceCodeRows=references[-1:], semantics="Exact native rows; EOS separate")
    code_data = write_json(root / "segment-000.codes.json", codes)
    code_payload = b"".join(struct.pack("<16i", *row) for row in rows)
    wav, payload = wav_bytes(samples if samples is not None else [0.25] * (len(rows) * 16))
    (root / "segment-000.wav").write_bytes(wav)
    segment = dict(segmentIndex=0, voiceID="voice", text=workload["segments"][0],
                   textSHA256=MODULE.digest(workload["segments"][0].encode()), samplingSeed=seed,
                   status="CAPTURED_UNASSESSED", stopReason="naturalEOS" if eos else "didNotReachEOS", reachedEOS=eos,
                   generatedRowCount=len(rows), conditioningReferenceRowCount=2, decodeReferenceRowCount=1,
                   codebookCount=16, generatedCodesI32LESHA256=MODULE.digest(code_payload),
                   codeRowsFilename="segment-000.codes.json", codeRowsFileSHA256=MODULE.digest(code_data),
                   sampleCount=len(payload) // 4, sampleRate=24000, pcmF32LESHA256=MODULE.digest(payload),
                   wavFilename="segment-000.wav", wavFileSHA256=MODULE.digest(wav), unavailable=[])
    manifest = dict(schemaVersion=1, status="UNASSESSED_REQUIRES_LISTENING_AND_TOKEN_COMPARISON",
                    performancePromotionEligible=False, serializationAfterRenderTiming=True,
                    retainedPayloadBytes=1000, runID=run_id, characterID="big_mike", voiceID="voice",
                    workloadSHA256=MODULE.workload_digest(workload), policySHA256=MODULE.policy_digest(policy),
                    workloadFilename="workload.json", policyFilename="policy.json",
                    identitySHA256={key: HASH for key in MODULE.IDENTITY_KEYS},
                    runOutcome="SCOUT_COMPLETED" if eos else "FAILED_OR_BUDGET_STOPPED",
                    runFailure=None if eos else "No natural EOS", samplingSeedPolicy="fixture seed + segment index (UInt64 wrapping addition)",
                    maximumRowsPerSegment=160, segments=[segment])
    write_json(root / "evidence.json", manifest)
    return root


def change_manifest(root, change):
    path = root / "evidence.json"
    manifest = json.loads(path.read_text())
    change(manifest)
    write_json(path, manifest)


def change_codes(root, change):
    path = root / "segment-000.codes.json"
    codes = json.loads(path.read_text())
    change(codes)
    data = write_json(path, codes)
    def update(manifest):
        segment = manifest["segments"][0]
        segment["codeRowsFileSHA256"] = MODULE.digest(data)
        try:
            payload = b"".join(struct.pack("<" + "i" * len(row), *row) for row in codes["generatedCodeRows"])
            segment["generatedCodesI32LESHA256"] = MODULE.digest(payload)
        except (TypeError, struct.error):
            pass
    change_manifest(root, update)


class QualityEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.a = write_fixture(self.root / "baseline", "baseline-run")
        self.b = write_fixture(self.root / "candidate", "candidate-run", arithmetic="bf16Candidate")

    def assert_invalid(self, contains=None):
        result = MODULE.compare(self.a, self.b)
        self.assertEqual(result["status"], "INVALID_EVIDENCE")
        self.assertEqual(result["qualityStatus"], "NOT_A_QUALITY_PASS")
        self.assertEqual(result["segments"], [])
        if contains:
            self.assertTrue(any(contains in error for error in result["errors"]), result["errors"])
        return result

    def test_identical_tokens_pcm_and_large_uint64_seed_are_not_quality_pass(self):
        result = MODULE.compare(self.a, self.b / "evidence.json")
        self.assertEqual(result["errors"], [])
        self.assertEqual(result["status"], "EVIDENCE_COMPARABLE")
        self.assertEqual(result["qualityStatus"], "NOT_A_QUALITY_PASS")
        self.assertFalse(result["performancePromotionEligible"])
        self.assertFalse(result["qualityFromHashes"])
        self.assertEqual(result["policyDifferences"], {"arithmetic": {"baseline": "legacy", "candidate": "bf16Candidate"}})
        segment = result["segments"][0]
        self.assertEqual(segment["samplingSeed"], 9_155_153_355_066_127_096)
        self.assertTrue(segment["identicalGeneratedRows"] and segment["equalCommonPrefix"] and segment["identicalPCM"])
        self.assertEqual(segment["commonPrefixTokenCount"], 32)
        self.assertIsNone(segment["firstTokenDivergence"])
        self.assertAlmostEqual(segment["baselinePCM"]["durationSeconds"], 32 / 24000)
        self.assertTrue(result["pendingGates"])

    def test_first_divergent_token_reports_exact_row_and_residual_column(self):
        change_codes(self.b, lambda codes: codes["generatedCodeRows"][1].__setitem__(6, 101))
        result = MODULE.compare(self.a, self.b)
        self.assertEqual(result["errors"], [])
        segment = result["segments"][0]
        self.assertEqual(segment["firstTokenDivergence"], {"kind": "token", "rowIndex": 1, "codebookColumn": 6,
                                                         "baselineToken": 22, "candidateToken": 101})
        self.assertEqual(segment["commonPrefixTokenCount"], 22)
        self.assertEqual(segment["commonPrefixWholeRows"], 1)
        self.assertFalse(segment["equalCommonPrefix"])
        self.assertTrue(segment["identicalPCM"])  # Byte identity never overrides token evidence.

    def test_length_divergence_and_eos_are_separate_from_common_tokens(self):
        longer = write_fixture(self.root / "longer", "longer", rows=[list(range(16)), list(range(16, 32)), list(range(32, 48))])
        shorter = write_fixture(self.root / "shorter", "shorter", eos=False)
        result = MODULE.compare(longer, shorter)
        self.assertEqual(result["errors"], [])
        segment = result["segments"][0]
        self.assertTrue(segment["equalCommonPrefix"])
        self.assertEqual(segment["commonPrefixWholeRows"], 2)
        self.assertEqual(segment["firstTokenDivergence"], {"kind": "rowCount", "rowIndex": 2, "codebookColumn": 0,
                                                         "baselineToken": 32, "candidateToken": None})
        self.assertTrue(segment["baselineReachedEOS"])
        self.assertFalse(segment["candidateReachedEOS"])
        self.assertFalse(result["allSegmentsNaturallyCompleted"])

    def test_tampered_code_wav_and_policy_hashes_are_rejected(self):
        for filename, suffix, expected in (("segment-000.codes.json", b" ", "code rows file hash"),
                                           ("segment-000.wav", b"x", "WAV file hash"),
                                           ("policy.json", None, "Execution policy hash")):
            with self.subTest(filename=filename):
                path = self.b / filename
                original = path.read_bytes()
                if suffix is not None:
                    path.write_bytes(original + suffix)
                else:
                    policy = json.loads(original)
                    policy["arithmetic"] = "legacy"
                    write_json(path, policy)
                self.assert_invalid(expected)
                path.write_bytes(original)

    def test_semantic_residual_vocab_shape_and_integer_types_are_validated(self):
        original_manifest = (self.b / "evidence.json").read_bytes()
        original_codes = (self.b / "segment-000.codes.json").read_bytes()
        for row in ([4096] + [0] * 15, [0, 2048] + [0] * 14, [-1] + [0] * 15,
                    [0, True] + [0] * 14, [0, 1.0] + [0] * 14, [0] * 15, [0] * 17):
            with self.subTest(row=row):
                change_codes(self.b, lambda codes: codes["generatedCodeRows"].__setitem__(0, row))
                self.assert_invalid("16 integer columns")
                (self.b / "evidence.json").write_bytes(original_manifest)
                (self.b / "segment-000.codes.json").write_bytes(original_codes)
        change_codes(self.b, lambda codes: codes["generatedCodeRows"].__setitem__(0, [4095] + [2047] * 15))
        self.assertEqual(MODULE.compare(self.a, self.b)["errors"], [])

    def test_control_identity_text_seed_and_exact_reference_mismatches_reject(self):
        original_manifest = (self.b / "evidence.json").read_bytes()
        for change, expected in ((lambda m: m["identitySHA256"].__setitem__("referenceCodes", "b" * 64), "identitySHA256"),
                                 (lambda m: m["segments"][0].__setitem__("text", "Different"), "voice/text mismatch"),
                                 (lambda m: m["segments"][0].__setitem__("samplingSeed", 1), "sampling seed mismatch"),
                                 (lambda m: m["segments"][0].__setitem__("reachedEOS", 1), "EOS evidence")):
            with self.subTest(expected=expected):
                change_manifest(self.b, change)
                self.assert_invalid(expected)
                (self.b / "evidence.json").write_bytes(original_manifest)
        change_codes(self.b, lambda c: c["conditioningReferenceCodeRows"][0].__setitem__(0, 77))
        self.assert_invalid("unmatched exact reference rows")

    def test_workload_hash_and_duplicate_missing_segments_are_rejected(self):
        original = (self.b / "evidence.json").read_bytes()
        for change, expected in ((lambda m: m.__setitem__("workloadSHA256", "b" * 64), "Workload hash mismatch"),
                                 (lambda m: m.__setitem__("segments", []), "Incomplete segment evidence"),
                                 (lambda m: m["segments"][0].__setitem__("segmentIndex", 1), "out-of-range"),
                                 (lambda m: m["segments"].append(copy.deepcopy(m["segments"][0])), "Incomplete segment evidence"),
                                 (lambda m: m.__setitem__("status", "PARTIAL_EVIDENCE_UNASSESSED"), "Incomplete/unavailable")):
            with self.subTest(expected=expected):
                change_manifest(self.b, change)
                self.assert_invalid(expected)
                (self.b / "evidence.json").write_bytes(original)

    def test_filenames_and_symlinks_cannot_escape_evidence_directory(self):
        original = (self.b / "evidence.json").read_bytes()
        for filename in ("../baseline/policy.json", str(self.a / "policy.json"), "..\\baseline\\policy.json"):
            with self.subTest(filename=filename):
                change_manifest(self.b, lambda m: m.__setitem__("policyFilename", filename))
                self.assert_invalid("single local filename")
                (self.b / "evidence.json").write_bytes(original)
        (self.b / "outside.json").symlink_to(self.a / "policy.json")
        change_manifest(self.b, lambda m: m.__setitem__("policyFilename", "outside.json"))
        self.assert_invalid("escapes its evidence directory")

    def test_wav_header_fact_payload_and_pcm_claim_must_agree(self):
        original_wav = (self.b / "segment-000.wav").read_bytes()
        original_manifest = (self.b / "evidence.json").read_bytes()
        for offset, value, expected in ((20, 1, "IEEE float32"), (44, 99, "fact sample count"), (52, 99, "Truncated WAV")):
            with self.subTest(offset=offset):
                changed = bytearray(original_wav)
                changed[offset] = value
                (self.b / "segment-000.wav").write_bytes(changed)
                change_manifest(self.b, lambda m: m["segments"][0].__setitem__("wavFileSHA256", MODULE.digest(changed)))
                self.assert_invalid(expected)
                (self.b / "segment-000.wav").write_bytes(original_wav)
                (self.b / "evidence.json").write_bytes(original_manifest)
        change_manifest(self.b, lambda m: m["segments"][0].__setitem__("pcmF32LESHA256", "b" * 64))
        self.assert_invalid("WAV/PCM metadata mismatch")

    def test_cli_creates_output_exclusively_and_cannot_replace_evidence(self):
        output = self.root / "comparison.json"
        args = ["--baseline", str(self.a), "--candidate", str(self.b), "--output", str(output)]
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(MODULE.main(args), 0)
        original = output.read_bytes()
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            MODULE.main(args)
        self.assertEqual(error.exception.code, 2)
        self.assertEqual(output.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
