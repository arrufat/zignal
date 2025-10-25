import zignal


def test_rectangle_api():
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

    # Convenience accessors
    assert r.center() == (20.0, 30.0)
    assert r.top_left() == (10.0, 20.0)
    assert r.top_right() == (30.0, 20.0)
    assert r.bottom_left() == (10.0, 40.0)
    assert r.bottom_right() == (30.0, 40.0)

    # Transformations
    moved = r.translate(5, -5)
    assert isinstance(moved, zignal.Rectangle)
    assert (moved.left, moved.top, moved.right, moved.bottom) == (15.0, 15.0, 35.0, 35.0)

    clipped = r.clip(zignal.Rectangle(0, 0, 25, 35))
    assert (clipped.left, clipped.top, clipped.right, clipped.bottom) == (10.0, 20.0, 25.0, 35.0)

    # Overlap helpers
    assert r.overlaps((25, 25, 50, 50), iou_thresh=0.0, coverage_thresh=0.0) is True
    assert r.overlaps((30, 40, 60, 80), iou_thresh=0.0, coverage_thresh=0.0) is False

    outer = zignal.Rectangle(0, 0, 100, 100)
    assert outer.covers(r) is True
    assert r.covers(outer) is False

    # Misc helpers
    assert isinstance(r.diagonal(), float)
