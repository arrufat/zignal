import pytest

import zignal


def test_convex_hull_api_and_invalids():
    hull = zignal.ConvexHull()
    assert repr(hull) == "ConvexHull()"

    # Basic triangle returns list of (x, y)
    res = hull.find([(0, 0), (1, 0), (0.5, 1)])
    assert isinstance(res, list) and all(isinstance(p, tuple) and len(p) == 2 for p in res)

    # Too few or collinear points → None
    assert hull.find([]) is None
    assert hull.find([(0, 0)]) is None
    assert hull.find([(0, 0), (1, 1)]) is None
    assert hull.find([(0, 0), (1, 1), (2, 2)]) is None

    # Invalid inputs raise
    with pytest.raises(TypeError):
        hull.find("not a sequence")


def test_convex_hull_get_rectangle_roundtrip():
    hull = zignal.ConvexHull()

    # No hull yet
    assert hull.get_rectangle() is None

    hull.find([(0.0, 0.0), (1.0, 0.0), (0.5, 1.0)])
    rect = hull.get_rectangle()
    assert isinstance(rect, zignal.Rectangle)
    assert (rect.left, rect.top, rect.right, rect.bottom) == (0.0, 0.0, 1.0, 1.0)

    # Degenerate hull clears rectangle
    hull.find([(0.0, 0.0), (1.0, 1.0), (2.0, 2.0)])
    assert hull.get_rectangle() is None
