import pytest

import zignal


def test_convex_hull_creation():
    """Test ConvexHull object creation."""
    hull = zignal.ConvexHull()
    assert hull is not None
    assert repr(hull) == "ConvexHull()"


def test_convex_hull_basic_api():
    """Test basic API usage of ConvexHull."""
    hull = zignal.ConvexHull()

    # Basic triangle - should return list of tuples
    points = [(0, 0), (1, 0), (0.5, 1)]
    result = hull.find(points)

    assert isinstance(result, list)
    assert len(result) == 3
    assert all(isinstance(p, tuple) for p in result)
    assert all(len(p) == 2 for p in result)
    assert all(isinstance(p[0], float) and isinstance(p[1], float) for p in result)


def test_convex_hull_returns_none():
    """Test cases where find() returns None."""
    hull = zignal.ConvexHull()

    # Empty list
    assert hull.find([]) is None

    # Single point
    assert hull.find([(1, 1)]) is None

    # Two points
    assert hull.find([(0, 0), (1, 1)]) is None

    # Collinear points
    assert hull.find([(0, 0), (1, 1), (2, 2)]) is None


def test_convex_hull_input_types():
    """Test that ConvexHull accepts both lists and tuples."""
    hull = zignal.ConvexHull()

    # Test with list
    points_list = [(0, 0), (1, 0), (0.5, 1)]
    result1 = hull.find(points_list)
    assert result1 is not None
    assert isinstance(result1, list)

    # Test with tuple
    points_tuple = ((0, 0), (1, 0), (0.5, 1))
    result2 = hull.find(points_tuple)
    assert result2 is not None
    assert isinstance(result2, list)


def test_convex_hull_coordinate_types():
    """Test that ConvexHull handles different numeric types."""
    hull = zignal.ConvexHull()

    # Integer coordinates
    points = [(0, 0), (4, 0), (2, 3)]
    result = hull.find(points)
    assert result is not None
    # Results should be floats
    assert all(isinstance(p[0], float) and isinstance(p[1], float) for p in result)

    # Mixed int/float coordinates
    points = [(0.5, 0), (4, 0.5), (2.0, 3)]
    result = hull.find(points)
    assert result is not None


def test_convex_hull_reuse():
    """Test multiple calls on the same ConvexHull object."""
    hull = zignal.ConvexHull()

    # First call
    result1 = hull.find([(0, 0), (1, 0), (0, 1)])
    assert result1 is not None
    assert len(result1) == 3

    # Second call with different points
    result2 = hull.find([(0, 0), (2, 0), (2, 2), (0, 2)])
    assert result2 is not None
    assert len(result2) >= 3  # At least triangle

    # Third call returning None
    result3 = hull.find([(0, 0), (1, 1)])
    assert result3 is None


def test_convex_hull_invalid_input():
    """Test ConvexHull with invalid input."""
    hull = zignal.ConvexHull()

    # Non-list/tuple input
    with pytest.raises(TypeError):
        hull.find("not a list")

    with pytest.raises(TypeError):
        hull.find(123)

    with pytest.raises(TypeError):
        hull.find(None)

    # List with non-tuple elements
    with pytest.raises(TypeError):
        hull.find([1, 2, 3])

    with pytest.raises(TypeError):
        hull.find(["point1", "point2"])

    # Tuple with wrong number of elements
    with pytest.raises(ValueError):
        hull.find([(1,)])  # Only one coordinate

    with pytest.raises(ValueError):
        hull.find([(1, 2, 3)])  # Three coordinates

    with pytest.raises(ValueError):
        hull.find([tuple()])  # Empty tuple

    # Non-numeric coordinates
    with pytest.raises(TypeError):
        hull.find([("a", "b")])

    with pytest.raises(TypeError):
        hull.find([(1, "b")])

    with pytest.raises(TypeError):
        hull.find([(None, 1)])


def test_convex_hull_edge_cases():
    """Test edge cases for the API."""
    hull = zignal.ConvexHull()

    # Large coordinate values
    points = [(1e6, 1e6), (1e6 + 1, 1e6), (1e6, 1e6 + 1)]
    result = hull.find(points)
    assert result is not None

    # Very small differences
    points = [(0, 0), (0.0001, 0), (0, 0.0001)]
    result = hull.find(points)
    assert result is not None

    # Negative coordinates
    points = [(-1, -1), (1, -1), (0, 1)]
    result = hull.find(points)
    assert result is not None