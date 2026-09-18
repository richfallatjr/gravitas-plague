import argparse
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("qwen_bounded_runner", ROOT / "Scripts/turing/qwen_bounded_runner.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class BoundedRunnerCommandTests(unittest.TestCase):
    def args(self, profile, policy=None):
        return argparse.Namespace(binary=Path("binary"), model_root=Path("model"),
                                  bundle_root=Path("resources"), workload=Path("workload.json"),
                                  output=Path("report.json"), mode="bounded-replay",
                                  command_buffer_profile=profile, profiler_state="unattached", policy=policy)

    def test_requested_profile_is_forwarded_without_rewriting(self):
        for profile in MODULE.COMMAND_BUFFER_PROFILES:
            command = MODULE.native_command(self.args(profile))
            self.assertEqual(command[command.index("--command-buffer-profile") + 1], profile)
            self.assertEqual(command.count("--command-buffer-profile"), 1)

    def test_candidate_policy_is_explicit_and_does_not_change_profile(self):
        command = MODULE.native_command(self.args("deviceDefault", Path("candidate.json")))
        self.assertEqual(command[command.index("--policy") + 1], str(Path("candidate.json").resolve()))
        self.assertEqual(command[command.index("--command-buffer-profile") + 1], "deviceDefault")

    def test_baseline_does_not_inject_candidate_policy(self):
        self.assertNotIn("--policy", MODULE.native_command(self.args("deviceDefault")))

    def test_evidence_capture_is_only_forwarded_when_explicit(self):
        args = self.args("deviceDefault")
        self.assertNotIn("--evidence-directory", MODULE.native_command(args))
        args.evidence_directory = Path("new-evidence")
        command = MODULE.native_command(args)
        self.assertEqual(command[command.index("--evidence-directory") + 1],
                         str(args.evidence_directory.resolve()))


class BoundedRunnerBudgetTests(unittest.TestCase):
    def fixture(self, **changes):
        return dict(maximumRowsPerSegment=32, wallCapSeconds=180,
                    footprintCapMiB=6500, **changes)

    def test_complete_segments_accept_full_production_row_budget(self):
        fixture = self.fixture(requireCompleteSegments=True)
        for rows in (1, 32, 160):
            with self.subTest(rows=rows):
                fixture["maximumRowsPerSegment"] = rows
                self.assertEqual(MODULE.validate_fixture_budgets(fixture), (rows, 180, 6500))

    def test_complete_segments_reject_rows_beyond_safety_bound(self):
        fixture = self.fixture(requireCompleteSegments=True)
        for rows in (0, 161):
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                fixture["maximumRowsPerSegment"] = rows
                MODULE.validate_fixture_budgets(fixture)

    def test_legacy_or_disabled_complete_segments_retain_scout_budget(self):
        for changes in ({}, {"requireCompleteSegments": False}, {"requireCompleteSegments": None}):
            fixture = self.fixture(**changes)
            with self.subTest(changes=changes):
                self.assertEqual(MODULE.validate_fixture_budgets(fixture), (32, 180, 6500))
                for rows in (33, 160):
                    fixture["maximumRowsPerSegment"] = rows
                    with self.assertRaises(ValueError):
                        MODULE.validate_fixture_budgets(fixture)

    def test_invalid_completion_flag_types_are_rejected(self):
        for complete in (0, 1, 1.0, "true", "false", [], {}):
            with self.subTest(complete=complete), self.assertRaises(ValueError):
                MODULE.validate_fixture_budgets(self.fixture(requireCompleteSegments=complete))

    def test_complete_segments_keep_wall_and_memory_bounds(self):
        fixture = self.fixture(requireCompleteSegments=True)
        fixture["maximumRowsPerSegment"] = 160
        for key, invalid in (("wallCapSeconds", (0, 180.01)), ("footprintCapMiB", (255.99, 6500.01))):
            for value in invalid:
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    MODULE.validate_fixture_budgets(dict(fixture, **{key: value}))
        fixture.update(wallCapSeconds=1.0, footprintCapMiB=256.0)
        self.assertEqual(MODULE.validate_fixture_budgets(fixture), (160, 1.0, 256.0))

    def test_budget_types_and_non_finite_numbers_are_rejected(self):
        invalid_values = {
            "maximumRowsPerSegment": (True, False, "32", 32.0, 1.5, None, []),
            "wallCapSeconds": (True, False, "180", None, [], float("inf"), float("nan")),
            "footprintCapMiB": (True, False, "6500", None, [], float("inf"), float("nan")),
        }
        for key, values in invalid_values.items():
            for value in values:
                fixture = self.fixture(requireCompleteSegments=True)
                fixture[key] = value
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    MODULE.validate_fixture_budgets(fixture)

    def test_missing_budgets_or_non_object_fixture_are_rejected(self):
        for fixture in (None, [], {}, {"requireCompleteSegments": True}):
            with self.subTest(fixture=fixture), self.assertRaises(ValueError):
                MODULE.validate_fixture_budgets(fixture)


if __name__ == "__main__":
    unittest.main()
