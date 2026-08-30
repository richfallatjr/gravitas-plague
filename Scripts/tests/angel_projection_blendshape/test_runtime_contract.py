import json
import unittest
from pathlib import Path


class RuntimeContractTests(unittest.TestCase):
    def test_locked_mapping_keeps_teeth_closed(self):
        root = Path(__file__).resolve().parents[3]
        descriptor = json.loads((root / (
            "Gravitas Plague/TuringResources/Turing/Chapter03/"
            "AngelProjection/angel_jaw_open_projection.json"
        )).read_text(encoding="utf-8"))
        self.assertEqual(descriptor["blendShapeName"], "jawOpenProjection")
        self.assertEqual(descriptor["poseWeights"], {
            "rest": 0.0,
            "small": 0.33,
            "wide": 1.0,
            "round": 0.5,
            "teeth": 0.0,
        })
        self.assertTrue(descriptor["requiresProjectionReady"])


if __name__ == "__main__":
    unittest.main()
