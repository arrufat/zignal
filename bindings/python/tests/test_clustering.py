from __future__ import annotations

import random

import pytest

import zignal

BLOBS = [
    [0.0, 0.0],
    [0.1, 0.2],
    [0.2, 0.0],
    [9.0, 9.0],
    [9.1, 9.2],
    [9.2, 9.0],
]


def partition(labels: list[int]) -> set[frozenset[int]]:
    """The grouping a label list describes, ignoring which id each group happens to get."""
    groups: dict[int, set[int]] = {}
    for node, label in enumerate(labels):
        groups.setdefault(label, set()).add(node)
    return {frozenset(group) for group in groups.values()}


def test_separates_two_blobs():
    labels = zignal.chinese_whispers_clustering(BLOBS, 1.0)
    assert partition(labels) == {frozenset({0, 1, 2}), frozenset({3, 4, 5})}
    # Cluster ids are contiguous and start at 0.
    assert sorted(set(labels)) == [0, 1]


def test_threshold_controls_granularity():
    # Below every pairwise distance: nothing is connected.
    assert sorted(zignal.chinese_whispers_clustering(BLOBS, 0.01)) == [0, 1, 2, 3, 4, 5]
    # Above the largest distance: everything merges.
    assert zignal.chinese_whispers_clustering(BLOBS, 100.0) == [0] * len(BLOBS)


def test_accepts_a_matrix():
    matrix = zignal.Matrix(BLOBS)
    assert zignal.chinese_whispers_clustering(matrix, 1.0) == zignal.chinese_whispers_clustering(BLOBS, 1.0)


def test_is_deterministic_for_a_seed():
    first = zignal.chinese_whispers_clustering(BLOBS, 1.0, seed=7)
    assert first == zignal.chinese_whispers_clustering(BLOBS, 1.0, seed=7)


def test_rejects_bad_input():
    with pytest.raises(ValueError):
        zignal.chinese_whispers_clustering(BLOBS, -1.0)
    with pytest.raises(ValueError):
        zignal.chinese_whispers_clustering([[0.0, 1.0], [2.0]], 1.0)
    with pytest.raises(TypeError):
        zignal.chinese_whispers_clustering([[0.0, "x"]], 1.0)


def test_clusters_wide_embeddings():
    rng = random.Random(3)
    dim, per_cluster, planted = 128, 20, 3
    embeddings = [
        [10.0 * c + rng.uniform(-0.005, 0.005) for _ in range(dim)]
        for c in range(planted)
        for _ in range(per_cluster)
    ]

    labels = zignal.chinese_whispers_clustering(embeddings, 1.0)
    assert partition(labels) == {
        frozenset(range(c * per_cluster, (c + 1) * per_cluster)) for c in range(planted)
    }
