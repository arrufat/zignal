"""Bindings-level smoke tests for Rectangle."""

import zignal


def test_rectangle_smoke():
    r = zignal.Rectangle(10, 20, 30, 40)
    assert (r.left, r.top, r.right, r.bottom) == (10, 20, 30, 40)
    assert (r.width, r.height) == (20, 20)
    assert isinstance(r.is_empty(), bool)
    r2 = zignal.Rectangle.init_center(20, 20, 10, 10)
    assert isinstance(r.intersect(r2) or r, zignal.Rectangle)
    assert isinstance(r.intersect((15, 25, 35, 45)) or r, zignal.Rectangle)  # tuple support
    assert isinstance(r.iou(r2), float)
    assert isinstance(r.iou((15, 25, 35, 45)), float)  # tuple support
    assert isinstance(r.overlaps(r2), bool)
    assert isinstance(r.overlaps((15, 25, 35, 45), iou_thresh=0.1), bool)  # tuple and kwargs
