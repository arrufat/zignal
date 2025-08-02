"""Test Rectangle API."""

import pytest
import zignal


def test_rectangle_creation():
    """Test basic Rectangle creation and properties."""
    rect = zignal.Rectangle(10, 20, 100, 80)
    assert isinstance(rect, zignal.Rectangle)
    assert rect.left == 10
    assert rect.top == 20
    assert rect.right == 100
    assert rect.bottom == 80
    assert rect.width == 90
    assert rect.height == 60


def test_rectangle_init_center():
    """Test Rectangle.init_center class method."""
    rect = zignal.Rectangle.init_center(50, 50, 100, 60)
    assert isinstance(rect, zignal.Rectangle)
    assert rect.width == 100
    assert rect.height == 60


def test_rectangle_methods():
    """Test Rectangle instance methods exist and return correct types."""
    rect = zignal.Rectangle(0, 0, 100, 100)

    # Test is_empty returns bool
    assert isinstance(rect.is_empty(), bool)

    # Test area returns float
    assert isinstance(rect.area(), float)

    # Test contains returns bool
    assert isinstance(rect.contains(50, 50), bool)

    # Test grow returns Rectangle
    grown = rect.grow(10)
    assert isinstance(grown, zignal.Rectangle)

    # Test shrink returns Rectangle
    shrunk = rect.shrink(5)
    assert isinstance(shrunk, zignal.Rectangle)

    # Test intersect returns Rectangle or None
    rect2 = zignal.Rectangle(50, 50, 150, 150)
    intersection = rect.intersect(rect2)
    assert isinstance(intersection, zignal.Rectangle)

    # Non-overlapping should return None
    rect3 = zignal.Rectangle(200, 200, 300, 300)
    assert rect.intersect(rect3) is None
