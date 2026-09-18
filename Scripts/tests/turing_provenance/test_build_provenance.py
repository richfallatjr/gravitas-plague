import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

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


if __name__ == "__main__":
    unittest.main()
