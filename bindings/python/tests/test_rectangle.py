"""Bindings-level smoke tests for Rectangle."""

import zignal


def test_rectangle_smoke():
    r = zignal.Rectangle(10, 20, 30, 40)
    assert (r.left, r.top, r.right, r.bottom) == (10, 20, 30, 40)
    assert (r.width, r.height) == (20, 20)
    assert isinstance(r.is_empty(), bool)
    r2 = zignal.Rectangle.init_center(20, 20, 10, 10)
    assert isinstance(r.intersect(r2) or r, zignal.Rectangle)
