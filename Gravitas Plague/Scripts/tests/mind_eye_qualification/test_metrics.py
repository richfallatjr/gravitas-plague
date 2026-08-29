import pytest

from mind_eye_qualification.metrics import bytes_to_mib, median, nonnegative_delta, percentile


def test_metrics_are_deterministic():
    assert median([3, 1, 2]) == 2
    assert percentile([0, 10], 0.95) == pytest.approx(9.5)
    assert bytes_to_mib(1_048_576) == 1
    with pytest.raises(ValueError):
        nonnegative_delta(1, 2)
