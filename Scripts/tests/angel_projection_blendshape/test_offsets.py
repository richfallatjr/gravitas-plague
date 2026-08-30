import math
import unittest

from Scripts.angel_projection_blendshape.offsets import compute_sparse_offsets


class SparseOffsetTests(unittest.TestCase):
    def test_sparse_offsets_keep_only_changed_points(self):
        result = compute_sparse_offsets(
            [(0, 0, 0), (1, 1, 1), (2, 2, 2)],
            [(0, 0, 0), (1.1, 1, 1), (2, 2, 2.2)],
            0.000001,
        )
        self.assertEqual(result.indices, (1, 2))
        self.assertAlmostEqual(result.values[0][0], 0.1)
        self.assertAlmostEqual(result.maximum_displacement, 0.2)

    def test_zero_deformation_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "zero deformation"):
            compute_sparse_offsets(
                [(0, 0, 0)],
                [(0, 0, 0)],
                0.000001,
            )

    def test_nonfinite_points_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "nonfinite"):
            compute_sparse_offsets(
                [(0, 0, 0)],
                [(math.nan, 0, 0)],
                0.000001,
            )


if __name__ == "__main__":
    unittest.main()
