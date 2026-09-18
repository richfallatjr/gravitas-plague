import copy
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[2] / "turing" / "qwen_build_provenance.py"
spec = importlib.util.spec_from_file_location("provenance", SCRIPT)
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


def fixture():
    rows = [
        ["clang++", "-O2", "-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST", "-c", "/src/mlx/backend/metal/allocator.cpp"],
        ["swiftc", "-O", "-module-name", "TuringQwenNative", "-DGR_TURING_METAL_STREAM_RECOVERY"],
        ["swiftc", "-O", "-module-name", "Gravitas_Plague"],
        ["metal", "-O2", "-c", "/src/kernel.metal"],
    ]
    records = [{"directory": "/src", "arguments": a, "sha256": p.digest(p.canonical(a))} for a in rows]
    runtime = dict(p.CONTRACT, requestedCommandBufferProfile="deviceDefault",
                   resolvedCommandBufferProfile={"maxOperations": 32, "maxMB": 32},
                   executionPolicy={"arithmetic": "legacy"}, seedPolicy="request-local",
                   recoveryDefines=["GR_TURING_METAL_STREAM_RECOVERY"])
    manifest = {"schemaVersion": 1, "qualification": "unqualified",
                "source": {key: "abc123" for key in ["commit", "trackedDiffSHA256", "relevantSourcesSHA256", "nativeSourcesSHA256", "vendorSourcesSHA256"]},
                "binaryUUIDs": ["0D36EDD2-6C47-44AC-BFEE-39A5F197053F"],
                "models": {"sha256": "model-hash", "files": {"model.safetensors": "hash"}},
                "voices": {"sha256": "voice-hash", "files": {"voice.safetensors": "hash"}},
                "workloadSHA256": "workload-hash", "runtimeContract": runtime,
                "compile": p.compile_evidence(records), "toolchain": {"sdkPath": "/sdk"},
                "buildEvidence": {"succeeded": True, "logSHA256": "success-log",
                    "sourceSnapshotSHA256": "prebuild-source", "sourceUnchangedDuringBuild": True,
                    "binariesBuiltAfterSourceSnapshot": True},
                "buildConfiguration": "Release", "experimentID": "shipping-default"}
    manifest["manifestSHA256"] = p.digest(p.canonical(manifest))
    installed = {"buildManifest": copy.deepcopy(manifest), "binaryUUIDs": manifest["binaryUUIDs"],
                 "compiledFingerprint": {"translationUnit": "mlx/mlx/backend/metal/allocator.cpp", "compiler": "Apple clang",
                    "libcxxVersion": 200000, "hardeningMode": "fast", "internalAssertionsEnabled": False,
                    "optimized": True, "experimentID": "shipping-default"},
                 "installedPayloadSHA256": {"models": "model-hash", "voices": "voice-hash"},
                 "runtimeContract": runtime, "workloadSHA256": "workload-hash",
                 "observation": {k: "observed" for k in ["deviceModel", "osBuild", "runID", "clockBasis", "profilerState", "sceneCondition", "initialThermalState", "initialMemoryBytes"]}}
    return manifest, installed


def refresh_manifest(manifest, installed):
    manifest.pop("manifestSHA256", None)
    manifest["manifestSHA256"] = p.digest(p.canonical(manifest))
    installed["buildManifest"] = copy.deepcopy(manifest)


def alternate_fixture():
    manifest, installed = fixture()
    baseline = dict(p.CONTRACT, requestedCommandBufferProfile="deviceDefault",
                    resolvedCommandBufferProfile={"maximumOperations": 40, "maximumMegabytes": 40},
                    executionPolicy=dict(policyVersion=1, arithmetic="legacy", prefill="legacyDense",
                                         predictor="legacy", workspace="legacy", decoderIO="legacy",
                                         kernelSet="existing", decoderState="legacy"),
                    policySHA256=p.digest(b"1|legacy|legacyDense|legacy|legacy|legacy|existing|legacy"),
                    seedPolicy="fixture seed + segment index",
                    recoveryDefines=["GR_TURING_METAL_STREAM_RECOVERY"], playbackRateApplied=False)
    candidate = copy.deepcopy(baseline)
    candidate["executionPolicy"]["arithmetic"] = "bf16Candidate"
    candidate["policySHA256"] = p.digest(b"1|bf16Candidate|legacyDense|legacy|legacy|legacy|existing|legacy")
    manifest["runtimeContract"] = baseline
    manifest["alternateRuntimeContracts"] = [candidate]
    installed["runtimeContract"] = copy.deepcopy(candidate)
    refresh_manifest(manifest, installed)
    return manifest, installed


class ProvenanceTests(unittest.TestCase):
    def test_dyld_install_names_are_not_response_files(self):
        args = ["clang", "-install_name", "@rpath/Gravitas Plague.debug.dylib", "@loader_path/lib.dylib", "@executable_path/lib.dylib",
                "-rpath", "@loader_path", "@executable_path", "@rpath"]
        self.assertEqual(p.expand_response_files(args, "/not/a/build/directory"), args)
        with self.assertRaises(ValueError):
            p.expand_response_files(["@missing-response-file"], "/not/a/build/directory")

    def test_valid_capture_and_actual_installed_identity_can_qualify_provenance(self):
        a, b = fixture()
        self.assertEqual(p.verify_manifest(a, b)["qualification"], "qualified")

    def test_one_binary_can_qualify_only_its_exact_explicit_legacy_and_c2_contracts(self):
        a, b = alternate_fixture()
        self.assertEqual(p.verify_manifest(a, b)["qualification"], "qualified")
        b["runtimeContract"] = copy.deepcopy(a["runtimeContract"])
        self.assertEqual(p.verify_manifest(a, b)["qualification"], "qualified")
        for contract in [a["runtimeContract"], *a["alternateRuntimeContracts"]]:
            self.assertEqual(p.policy_fingerprint(contract["executionPolicy"]), contract["policySHA256"])

    def test_c2_is_rejected_if_not_explicitly_declared(self):
        a, b = alternate_fixture()
        a.pop("alternateRuntimeContracts")
        refresh_manifest(a, b)
        self.assertIn("Installed runtime contract differs from manifest", p.verify_manifest(a, b)["errors"])
        b["runtimeContract"] = copy.deepcopy(a["runtimeContract"])
        self.assertEqual(p.verify_manifest(a, b)["qualification"], "qualified")

    def test_both_declared_policy_fingerprints_are_checked_even_for_a_baseline_run(self):
        for target in ("baseline", "candidate"):
            a, b = alternate_fixture()
            contract = a["runtimeContract"] if target == "baseline" else a["alternateRuntimeContracts"][0]
            contract["policySHA256"] = "0" * 64
            b["runtimeContract"] = copy.deepcopy(a["runtimeContract"])
            refresh_manifest(a, b)
            with self.subTest(target=target):
                result = p.verify_manifest(a, b)
                self.assertEqual(result["qualification"], "unqualified")
                self.assertTrue(any("policy fingerprint mismatch" in error for error in result["errors"]))

    def test_alternate_contract_cannot_change_any_non_policy_setting(self):
        changes = {"residencyMode": "shared", "laneCount": 1, "weightStoreCount": 1, "decoderCount": 2,
                   "admissionPolicy": "serial", "requestedCommandBufferProfile": "operations16",
                   "resolvedCommandBufferProfile": {"maximumOperations": 16, "maximumMegabytes": 40},
                   "seedPolicy": "different seed", "recoveryDefines": ["GR_TURING_METAL_DEFAULT_STREAM_RECOVERY"],
                   "playbackRateApplied": True}
        for key, value in changes.items():
            a, b = alternate_fixture()
            a["alternateRuntimeContracts"][0][key] = value
            b["runtimeContract"] = copy.deepcopy(a["alternateRuntimeContracts"][0])
            refresh_manifest(a, b)
            with self.subTest(key=key):
                result = p.verify_manifest(a, b)
                self.assertEqual(result["qualification"], "unqualified")
                self.assertTrue(any("Invalid alternate runtime contracts" in error for error in result["errors"]))

    def test_only_c2_generation_arithmetic_is_supported_not_other_policy_candidates(self):
        changes = {"arithmetic": "legacyWithConversionCache", "prefill": "fusedCausalCandidate",
                   "predictor": "cachedStepPlanCandidate", "workspace": "boundedLaneLocalCandidate",
                   "decoderIO": "positionalReaderCandidate", "kernelSet": "custom", "decoderState": "shared",
                   "policyVersion": True}
        for key, value in changes.items():
            a, b = alternate_fixture()
            candidate = a["alternateRuntimeContracts"][0]
            candidate["executionPolicy"][key] = value
            candidate["policySHA256"] = p.digest("|".join(str(candidate["executionPolicy"][field])
                                                          for field in p.POLICY_FIELDS).encode())
            b["runtimeContract"] = copy.deepcopy(candidate)
            refresh_manifest(a, b)
            with self.subTest(key=key):
                self.assertEqual(p.verify_manifest(a, b)["qualification"], "unqualified")

    def test_malformed_alternatives_and_incomplete_contracts_fail_closed(self):
        a, _ = alternate_fixture()
        candidate = a["alternateRuntimeContracts"][0]
        malformed = [None, {}, [], [None], [[]], [candidate, candidate], [a["runtimeContract"]],
                     [dict(candidate, undeclaredField="ignored?")],
                     [{key: value for key, value in candidate.items() if key != "policySHA256"}],
                     [dict(candidate, executionPolicy={"arithmetic": "bf16Candidate"})],
                     [dict(candidate, resolvedCommandBufferProfile={"maximumOperations": True, "maximumMegabytes": 40})],
                     [dict(candidate, recoveryDefines=[{}])], [dict(candidate, playbackRateApplied=0)]]
        for index, alternatives in enumerate(malformed):
            a, b = alternate_fixture()
            a["alternateRuntimeContracts"] = copy.deepcopy(alternatives)
            refresh_manifest(a, b)
            with self.subTest(index=index):
                self.assertEqual(p.verify_manifest(a, b)["qualification"], "unqualified")
        a, b = alternate_fixture()
        a["runtimeContract"].pop("seedPolicy")
        refresh_manifest(a, b)
        self.assertEqual(p.verify_manifest(a, b)["qualification"], "unqualified")

    def test_installed_contract_requires_exact_types_and_cannot_add_or_omit_fields(self):
        changes = {"policySHA256": "0" * 64, "playbackRateApplied": 0, "laneCount": 2.0,
                   "executionPolicy": {"arithmetic": "bf16Candidate"}, "unexpected": True}
        for key, value in changes.items():
            a, b = alternate_fixture()
            b["runtimeContract"][key] = value
            with self.subTest(key=key):
                self.assertEqual(p.verify_manifest(a, b)["qualification"], "unqualified")
        a, b = alternate_fixture()
        b["runtimeContract"].pop("policySHA256")
        self.assertEqual(p.verify_manifest(a, b)["qualification"], "unqualified")
        for recovery in (None, 1, True, "GR_TURING_METAL_STREAM_RECOVERY", {}, [1, {}]):
            a, b = alternate_fixture()
            b["runtimeContract"]["recoveryDefines"] = recovery
            with self.subTest(recovery=recovery):
                self.assertEqual(p.verify_manifest(a, b)["qualification"], "unqualified")

    def test_explicit_alternatives_do_not_waive_embedded_binary_payload_or_build_gates(self):
        mutations = [lambda a, b: b["buildManifest"].pop("alternateRuntimeContracts"),
                     lambda a, b: b.update(binaryUUIDs=["different"]),
                     lambda a, b: b["installedPayloadSHA256"].update(models="different"),
                     lambda a, b: b["installedPayloadSHA256"].update(voices="different"),
                     lambda a, b: b.update(workloadSHA256="different"),
                     lambda a, b: b["compiledFingerprint"].update(hardeningMode="debug"),
                     lambda a, b: b["compiledFingerprint"].update(experimentID="different")]
        for index, mutate in enumerate(mutations):
            a, b = alternate_fixture()
            mutate(a, b)
            with self.subTest(index=index):
                self.assertEqual(p.verify_manifest(a, b)["qualification"], "unqualified")
        for key in ("succeeded", "sourceUnchangedDuringBuild", "binariesBuiltAfterSourceSnapshot"):
            a, b = alternate_fixture()
            a["buildEvidence"][key] = False
            refresh_manifest(a, b)
            self.assertEqual(p.verify_manifest(a, b)["qualification"], "unqualified", key)
        a, b = alternate_fixture()
        a["compile"]["nativeSwiftCommands"][0]["defines"] = {"GR_TURING_METAL_DEFAULT_STREAM_RECOVERY": "1"}
        refresh_manifest(a, b)
        self.assertIn("Actual compile recovery defines differ from runtime contract", p.verify_manifest(a, b)["errors"])

    def test_capture_embeds_explicit_contracts_in_hash_and_keeps_legacy_manifest_shape(self):
        manifest, _ = alternate_fixture()
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            baseline, candidate, output = [root / name for name in ("legacy.json", "c2.json", "manifest.json")]
            baseline.write_text(json.dumps(manifest["runtimeContract"]))
            candidate.write_text(json.dumps(manifest["alternateRuntimeContracts"][0]))
            args = SimpleNamespace(runtime_contract=str(baseline), alternate_runtime_contract=[str(candidate)],
                                   repo=temp, compile_commands=None, build_log=None, binary=[], app_bundle=None,
                                   source_snapshot=None, build_success_log=None, sdk="xros", model_root=None,
                                   voices_root=None, workload=None, configuration="Release", experiment="shipping-default",
                                   output=str(output))
            with mock.patch.object(p, "source_identity", return_value={}), mock.patch.object(p, "run", return_value=None), mock.patch("builtins.print"):
                p.capture(args)
                actual = json.loads(output.read_text())
                self.assertEqual(actual["runtimeContract"], manifest["runtimeContract"])
                self.assertEqual(actual["alternateRuntimeContracts"], manifest["alternateRuntimeContracts"])
                self.assertEqual(actual["manifestSHA256"], p.digest(p.canonical({key: value for key, value in actual.items()
                                                                             if key != "manifestSHA256"})))
                args.alternate_runtime_contract = []
                p.capture(args)
                legacy = json.loads(output.read_text())
                self.assertNotIn("alternateRuntimeContracts", legacy)
                self.assertNotEqual(actual["manifestSHA256"], legacy["manifestSHA256"])
                args.alternate_runtime_contract = [str(candidate), str(candidate)]
                with self.assertRaises(ValueError):
                    p.capture(args)
                args.alternate_runtime_contract = [str(candidate)]
                args.runtime_contract = None
                with self.assertRaises(ValueError):
                    p.capture(args)

    def test_capture_cli_accepts_repeatable_explicit_contract_arguments(self):
        argv = [str(SCRIPT), "capture", "--configuration", "Release", "--output", "unused.json",
                "--runtime-contract", "legacy.json", "--alternate-runtime-contract", "c2.json",
                "--alternate-runtime-contract", "extra.json"]
        with mock.patch.object(p.sys, "argv", argv), mock.patch.object(p, "capture") as capture:
            self.assertEqual(p.main(), 0)
            self.assertEqual(capture.call_args.args[0].alternate_runtime_contract, ["c2.json", "extra.json"])

    def test_same_git_commit_does_not_establish_installed_parity(self):
        a, b = fixture()
        b["binaryUUIDs"] = ["different"]
        self.assertEqual(p.verify_manifest(a, b)["qualification"], "unqualified")

    def test_workload_hash_must_be_observed_not_just_embedded(self):
        a, b = fixture()
        b.pop("workloadSHA256")
        self.assertIn("Installed workload hash unavailable or different", p.verify_manifest(a, b)["errors"])

    def test_workload_codable_canonicalization_matches_optional_and_number_rules(self):
        value = dict(schemaVersion=1, id="test", origin="captured", characterID="dad", voiceID="dad",
                     language="en", segments=["Hello / world — test"], samplingSeed=42, maximumRowsPerSegment=8,
                     wallCapSeconds=30.0, footprintCapMiB=2048.0, decoderCodes=None, decoderReferenceRows=None)
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / "workload.json"
            target.write_text(json.dumps(value, indent=2))
            expected = dict(value)
            expected.pop("decoderCodes")
            expected.pop("decoderReferenceRows")
            expected["wallCapSeconds"] = 30
            expected["footprintCapMiB"] = 2048
            self.assertEqual(p.workload_identity(target), p.digest(p.canonical(expected)))
            value["ignoredBySwift"] = True
            target.write_text(json.dumps(value))
            with self.assertRaises(ValueError):
                p.workload_identity(target)

    def test_unknown_commands_hardening_model_or_runtime_fail_closed(self):
        for key in ["compiledFingerprint", "runtimeContract", "installedPayloadSHA256", "observation"]:
            a, b = fixture()
            b.pop(key)
            self.assertEqual(p.verify_manifest(a, b)["qualification"], "unqualified", key)

    def test_complete_segment_requirement_is_hash_significant_and_preserves_legacy_identity(self):
        value = dict(schemaVersion=1, id="test", origin="captured", characterID="dad", voiceID="dad",
                     language="en", segments=["Hello / world — test"], samplingSeed=42, maximumRowsPerSegment=8,
                     wallCapSeconds=30, footprintCapMiB=2048)
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / "workload.json"
            target.write_text(json.dumps(value))
            legacy_identity = p.workload_identity(target)
            self.assertEqual(legacy_identity, p.digest(p.canonical(value)))
            target.write_text(json.dumps(dict(value, requireCompleteSegments=None)))
            self.assertEqual(p.workload_identity(target), legacy_identity)
            identities = {legacy_identity}
            for complete in (False, True):
                extended = dict(value, requireCompleteSegments=complete)
                target.write_text(json.dumps(extended))
                identity = p.workload_identity(target)
                self.assertEqual(identity, p.digest(p.canonical(extended)))
                self.assertNotIn(identity, identities)
                identities.add(identity)

    def test_workload_identity_rejects_invalid_complete_segment_flag_types(self):
        value = dict(schemaVersion=1, id="test", origin="captured", characterID="dad", voiceID="dad",
                     language="en", segments=["Hello"], samplingSeed=42, maximumRowsPerSegment=8,
                     wallCapSeconds=30, footprintCapMiB=2048)
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / "workload.json"
            for complete in (0, 1, 1.0, "true", "false", [], {}):
                target.write_text(json.dumps(dict(value, requireCompleteSegments=complete)))
                with self.subTest(complete=complete), self.assertRaises(ValueError):
                    p.workload_identity(target)

    def test_missing_allocator_command_fails_even_with_app_optimization(self):
        a, b = fixture()
        a["compile"]["allocatorCommands"] = []
        a.pop("manifestSHA256")
        a["manifestSHA256"] = p.digest(p.canonical(a))
        b["buildManifest"] = copy.deepcopy(a)
        self.assertIn("Missing actual compile commands: allocatorCommands", p.verify_manifest(a, b)["errors"])

    def test_build_source_or_execution_unknown_cannot_qualify(self):
        for key in ["succeeded", "sourceUnchangedDuringBuild", "binariesBuiltAfterSourceSnapshot"]:
            a, b = fixture()
            a["buildEvidence"][key] = False
            a.pop("manifestSHA256")
            a["manifestSHA256"] = p.digest(p.canonical(a))
            b["buildManifest"] = copy.deepcopy(a)
            self.assertEqual(p.verify_manifest(a, b)["qualification"], "unqualified", key)

    def test_failed_build_log_cannot_be_promoted_by_an_earlier_success_marker(self):
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / "build.log"
            target.write_text("** BUILD SUCCEEDED **\n")
            self.assertTrue(p.successful_build_evidence(target)["succeeded"])
            target.write_text("** BUILD SUCCEEDED **\n** BUILD FAILED **\n")
            self.assertFalse(p.successful_build_evidence(target)["succeeded"])
            target.write_text("Build complete! (10s)\n")
            self.assertTrue(p.successful_build_evidence(target)["succeeded"])

    def test_command_definition_replacement_is_explicit_and_conflict_free(self):
        args = ["clang++", "-O0", "-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_DEBUG",
                "-U_LIBCPP_HARDENING_MODE", "-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST"]
        result = p.summarize_command({"arguments": args, "sha256": "hash"})
        self.assertEqual(result["conflictingDefinitions"], [])
        self.assertEqual(result["hardeningDefinition"], "_LIBCPP_HARDENING_MODE_FAST")
        self.assertEqual(result["effectiveOptimization"], "-O0")
        args.remove("-U_LIBCPP_HARDENING_MODE")
        self.assertIn("_LIBCPP_HARDENING_MODE", p.summarize_command({"arguments": args, "sha256": "hash"})["conflictingDefinitions"])

    def test_nested_response_flags_are_captured_and_missing_or_recursive_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "inner.rsp").write_text("-O2 -D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST")
            (root / "outer.rsp").write_text("@inner.rsp -c allocator.cpp")
            self.assertIn("-O2", p.expand_response_files(["clang++", "@outer.rsp"], root))
            with self.assertRaises(ValueError):
                p.expand_response_files(["@missing"], root)
            (root / "inner.rsp").write_text("@outer.rsp")
            with self.assertRaises(ValueError):
                p.expand_response_files(["@outer.rsp"], root)

    def test_hardening_comparison_rejects_optimization_or_recovery_changes(self):
        a, _ = fixture()
        b = copy.deepcopy(a)
        a["experimentID"] = "hardening-debug-control"
        b["experimentID"] = "hardening-fast-only"
        a["compile"]["allocatorCommands"][0]["hardeningDefinition"] = "_LIBCPP_HARDENING_MODE_DEBUG"
        a["compile"]["allocatorCommands"][0]["defines"]["_LIBCPP_HARDENING_MODE"] = "_LIBCPP_HARDENING_MODE_DEBUG"
        self.assertTrue(p.compare_hardening(a, b)["comparable"])
        b["compile"]["allocatorCommands"][0]["effectiveOptimization"] = "-O0"
        self.assertFalse(p.compare_hardening(a, b)["comparable"])
        b = copy.deepcopy(a)
        b["experimentID"] = "hardening-fast-only"
        b["compile"]["nativeSwiftCommands"][0]["defines"]["GR_TURING_METAL_STREAM_RECOVERY"] = "0"
        self.assertFalse(p.compare_hardening(a, b)["comparable"])

    def test_hardening_comparison_cannot_ignore_alternate_contracts(self):
        a, _ = alternate_fixture()
        b = copy.deepcopy(a)
        b.pop("alternateRuntimeContracts")
        self.assertIn("alternateRuntimeContracts", p.compare_hardening(a, b)["differences"])


if __name__ == "__main__":
    unittest.main()
