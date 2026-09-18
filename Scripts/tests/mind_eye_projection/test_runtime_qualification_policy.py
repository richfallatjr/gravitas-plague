"""Compile the real Foundation-only Angel policy, without building the app."""

import json
import os
import pathlib
import platform
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[3]
PROJECTION = ROOT / "Gravitas Plague/Gravitas Plague/Turing/MindsEye/Projection"
RESOURCE = (
    ROOT
    / "Gravitas Plague/TuringResources/Turing/MindsEye/Projection/qualification"
    / "angel_head_v1.material-parity.json"
)

HARNESS = r'''
import Foundation

enum RegressionFailure: Error {
    case unexpectedResult(String)
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw RegressionFailure.unexpectedResult(message) }
}

@main
struct RuntimeQualificationPolicyRegression {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let scenario = CommandLine.arguments[2]
        let shipped = try JSONDecoder().decode(
            MindEyeProjectionMaterialParityQualification.self, from: data
        )
        try require(!shipped.passed, "the shipped resource must remain unqualified")
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if scenario != "shipped" {
            // Synthetic passing evidence exists only in this process. Never rewrite
            // the shipped resource or confuse this fixture with measured parity.
            object["maskPixelCount"] = 1024
            object["RMSELinearRGB"] = 0.001
            object["p99AbsoluteErrorLinearRGB"] = 0.002
            object["maximumAbsoluteErrorLinearRGB"] = 0.003
            object["PSNRDecibels"] = 60.0
            object["passed"] = scenario != "failed"
        }
        let qualification = try JSONDecoder().decode(
            MindEyeProjectionMaterialParityQualification.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        func identity(_ field: String, _ value: String) -> String {
            scenario == "stale_" + field ? "stale-identity" : value
        }
        let identities = MindEyeProjectionQualificationIdentities(
            subjectAssetSHA256: identity("subjectAssetSHA256", shipped.subjectAssetSHA256),
            profileSHA256: identity("profileSHA256", shipped.profileSHA256),
            cameraSHA256: identity("cameraSHA256", shipped.cameraSHA256),
            targetSHA256: identity("targetSHA256", shipped.targetSHA256),
            importedPBRContractSHA256: identity(
                "importedPBRContractSHA256", shipped.importedPBRContractSHA256
            )
        )
        let expectedPassed = scenario == "valid"
        try require(
            MindEyeProjectionQualificationPolicy.production == .runtimePlayback,
            "production must select runtime playback in every build configuration"
        )
        for policy: MindEyeProjectionQualificationPolicy in [
            .production, .runtimePlayback, .allowUnqualifiedAuthoringRun
        ] {
            let passed = try policy.evaluate(qualification, identities: identities)
            try require(passed == expectedPassed, "permissive policy falsified qualification")
        }
        do {
            let passed = try MindEyeProjectionQualificationPolicy.requirePassingResource
                .evaluate(qualification, identities: identities)
            try require(expectedPassed && passed, "strict policy accepted unqualified evidence")
        } catch MindEyeProjectionError.materialParityUnqualified {
            try require(!expectedPassed, "strict policy rejected valid synthetic evidence")
        }
        print("PASS \(scenario)")
    }
}
'''


class RuntimeQualificationPolicySourceTests(unittest.TestCase):
    def test_controller_uses_production_without_debug_policy_switch(self):
        source = (PROJECTION / "MindEyeAngelProjectionController.swift").read_text()
        self.assertRegex(source, r"qualificationPolicy\s*:\s*\.production\b")
        self.assertNotIn("runtimeQualificationPolicy", source)
        self.assertNotRegex(source, r"#(?:if|elseif)\s+[^\n]*\bDEBUG\b")

    def test_loader_evaluates_qualification_with_actual_resource_identities(self):
        source = (PROJECTION / "MindEyeProjectionPlatePackage.swift").read_text()
        self.assertRegex(source, r"try\s+qualificationPolicy\.evaluate\s*\(\s*qualification\s*,")
        for field, variable in (
            ("subjectAssetSHA256", "subjectHash"),
            ("profileSHA256", "profileHash"),
            ("cameraSHA256", "cameraHash"),
            ("targetSHA256", "targetHash"),
            ("importedPBRContractSHA256", "contractHash"),
        ):
            self.assertRegex(source, rf"\b{field}\s*:\s*{variable}\b")
        self.assertNotRegex(source, r"if\s+qualificationPolicy\s*==\s*\.requirePassingResource")


class RuntimeQualificationPolicySwiftTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if shutil.which("xcrun") is None:
            raise unittest.SkipTest("requires the installed Xcode Swift compiler")
        cls.environment = os.environ.copy()
        compiler = subprocess.run(
            ["xcrun", "--find", "swiftc"],
            env=cls.environment,
            capture_output=True,
            text=True,
            check=True,
            timeout=30,
        ).stdout.strip()
        sdk = subprocess.run(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"],
            env=cls.environment,
            capture_output=True,
            text=True,
            check=True,
            timeout=30,
        ).stdout.strip()
        cls.temporary = tempfile.TemporaryDirectory(prefix="angel-runtime-policy-")
        cls.addClassCleanup(cls.temporary.cleanup)
        directory = pathlib.Path(cls.temporary.name)
        harness = directory / "RuntimeQualificationPolicyRegression.swift"
        harness.write_text(HARNESS)
        cls.executables = {}
        for configuration, flags in (
            ("Debug", ["-D", "DEBUG", "-Onone"]),
            ("Release", ["-O"]),
        ):
            executable = directory / f"qualification-policy-{configuration.lower()}"
            result = subprocess.run(
                [
                    compiler,
                    *flags,
                    "-sdk",
                    sdk,
                    "-target",
                    f"{platform.machine()}-apple-macosx15.0",
                    "-module-cache-path",
                    str(directory / "module-cache"),
                    str(PROJECTION / "MindEyeProjectionError.swift"),
                    str(PROJECTION / "MindEyeProjectionMaterialParityQualification.swift"),
                    str(harness),
                    "-o",
                    str(executable),
                ],
                env=cls.environment,
                capture_output=True,
                text=True,
                timeout=60,
            )
            if result.returncode:
                raise AssertionError(f"{configuration} compile failed:\n{result.stdout}{result.stderr}")
            cls.executables[configuration] = executable

    def assert_scenario(self, scenario):
        original_resource = RESOURCE.read_bytes()
        for configuration, executable in self.executables.items():
            with self.subTest(configuration=configuration, scenario=scenario):
                result = subprocess.run(
                    [str(executable), str(RESOURCE), scenario],
                    env=self.environment,
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout.strip(), f"PASS {scenario}")
        self.assertEqual(RESOURCE.read_bytes(), original_resource)

    def test_shipped_false_is_runtime_accepted_but_not_strictly_qualified(self):
        self.assertIs(json.loads(RESOURCE.read_text())["passed"], False)
        self.assert_scenario("shipped")

    def test_valid_synthetic_record_passes_every_policy(self):
        self.assert_scenario("valid")

    def test_false_pass_flag_is_not_overridden_by_valid_metrics(self):
        self.assert_scenario("failed")

    def test_each_stale_identity_remains_unqualified(self):
        for field in (
            "subjectAssetSHA256",
            "profileSHA256",
            "cameraSHA256",
            "targetSHA256",
            "importedPBRContractSHA256",
        ):
            self.assert_scenario("stale_" + field)


if __name__ == "__main__":
    unittest.main()
