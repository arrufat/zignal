from __future__ import annotations

import math

import pytest

import zignal


def _central_moments(values: list[float]) -> tuple[float, float, float, float]:
    n = len(values)
    mean = sum(values) / n
    centered = [x - mean for x in values]
    m2 = sum(c**2 for c in centered)
    m3 = sum(c**3 for c in centered)
    m4 = sum(c**4 for c in centered)
    return mean, m2, m3, m4


def _expected_skewness(values: list[float]) -> float:
    n = len(values)
    if n <= 2:
        return 0.0
    mean, m2, m3, _ = _central_moments(values)
    if math.isclose(m2, 0.0):
        return 0.0
    variance = m2 / (n - 1)
    skew = (n / ((n - 1) * (n - 2))) * (m3 / (m2 / n))
    return skew / (variance**1.5)


def _expected_excess_kurtosis(values: list[float]) -> float:
    n = len(values)
    if n <= 3:
        return 0.0
    _, m2, _, m4 = _central_moments(values)
    if math.isclose(m2, 0.0):
        return 0.0
    n1 = n - 1
    kurt = ((n * (n + 1)) / (n1 * (n - 2) * (n - 3))) * (m4 / ((m2 * m2) / (n * n)))
    kurt -= (3 * n1 * n1) / ((n - 2) * (n - 3))
    return kurt


def test_running_stats_accumulates_values():
    stats = zignal.RunningStats()

    assert stats.count == 0
    assert stats.sum == pytest.approx(0.0)
    assert stats.mean == pytest.approx(0.0)
    assert stats.variance == pytest.approx(0.0)
    assert stats.std_dev == pytest.approx(0.0)
    assert stats.skewness == pytest.approx(0.0)
    assert stats.ex_kurtosis == pytest.approx(0.0)
    assert stats.min == pytest.approx(0.0)
    assert stats.max == pytest.approx(0.0)

    stats.add(1.5)
    stats.extend([2.5, -1.0])

    values = [1.5, 2.5, -1.0]
    mean, m2, _, _ = _central_moments(values)
    variance = m2 / (len(values) - 1)

    assert stats.count == len(values)
    assert stats.sum == pytest.approx(sum(values))
    assert stats.mean == pytest.approx(mean)
    assert stats.variance == pytest.approx(variance)
    assert stats.std_dev == pytest.approx(math.sqrt(variance))
    assert stats.min == pytest.approx(min(values))
    assert stats.max == pytest.approx(max(values))
    assert stats.skewness == pytest.approx(_expected_skewness(values))
    assert stats.ex_kurtosis == pytest.approx(_expected_excess_kurtosis(values))

    # scale should match manual z-score
    value = 2.5
    expected_scale = (value - mean) / math.sqrt(variance)
    assert stats.scale(value) == pytest.approx(expected_scale)

    stats.clear()
    assert stats.count == 0
    assert stats.mean == pytest.approx(0.0)
    assert stats.std_dev == pytest.approx(0.0)

    stats.add(4.0)
    assert stats.std_dev == pytest.approx(0.0)
    assert stats.scale(10.0) == pytest.approx(0.0)


def test_running_stats_combine_produces_new_instance():
    left = zignal.RunningStats()
    right = zignal.RunningStats()

    left.extend([1.0, 2.0])
    right.extend([10.0, 20.0, 30.0])

    combined = left.combine(right)

    assert isinstance(combined, zignal.RunningStats)
    assert combined is not left
    assert combined is not right

    left_values = [1.0, 2.0]
    right_values = [10.0, 20.0, 30.0]
    all_values = left_values + right_values

    assert combined.count == len(all_values)
    assert combined.sum == pytest.approx(sum(all_values))
    assert combined.mean == pytest.approx(sum(all_values) / len(all_values))
    _, m2, _, _ = _central_moments(all_values)
    variance = m2 / (len(all_values) - 1)
    assert combined.variance == pytest.approx(variance)
    assert combined.skewness == pytest.approx(_expected_skewness(all_values))
    assert combined.ex_kurtosis == pytest.approx(_expected_excess_kurtosis(all_values))
    assert combined.min == pytest.approx(min(all_values))
    assert combined.max == pytest.approx(max(all_values))

    # original stats should remain untouched
    assert left.count == len(left_values)
    assert right.count == len(right_values)
