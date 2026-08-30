import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[2] / "turing" / "analyze_mlx_command_buffers.py"
SPEC = importlib.util.spec_from_file_location("analyze_mlx_command_buffers", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)


class AnalyzerTests(unittest.TestCase):
    def test_reports_failure_adjacency_and_phase_buckets(self):
        records = []
        for index, duration in enumerate((0.010, 0.060, 0.120), 1):
            records.append({
                "sequence": index,
                "commandBufferID": index,
                "GPUSeconds": duration,
                "kernelSeconds": duration / 2,
                "encodedOperationCount": index,
                "referencedInputBytesEstimate": index * 100,
                "primitiveCount": 1,
                "lastContext": {"phase": "speechDecoder", "stage": f"stage.{index}"},
                "isFailure": index == 3,
                "mindEyeInFlightAtSubmit": 1 if index == 2 else 0,
            })
        result = MODULE.analyze([{
            "profile": "deviceDefault",
            "admissionMode": "currentOverlap",
            "recentRecords": records,
        }])
        self.assertEqual(result["totalBuffers"], 3)
        self.assertEqual(result["failures"], 1)
        self.assertEqual(result["buffersOverlappingMindEye"], 1)
        self.assertEqual(len(result["topSlowDecoderBuffers"]), 3)
        self.assertEqual(len(result["failureAdjacentPreceding16"]), 3)


if __name__ == "__main__":
    unittest.main()
