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
    assert rect.width == 90  # 100 - 10
    assert rect.height == 60  # 80 - 20


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


def test_rectangle_exclusive_bounds():
    """Test that Rectangle uses exclusive bounds for right and bottom."""
    rect = zignal.Rectangle(0, 0, 100, 100)

    # Points inside the rectangle
    assert rect.contains(0, 0) is True  # Top-left corner (inclusive)
    assert rect.contains(50, 50) is True  # Center
    assert rect.contains(99, 99) is True  # Just inside
    assert rect.contains(99.9, 99.9) is True  # Very close to edge

    # Points on exclusive edges should be outside
    assert rect.contains(100, 50) is False  # On right edge (exclusive)
    assert rect.contains(50, 100) is False  # On bottom edge (exclusive)
    assert rect.contains(100, 100) is False  # Bottom-right corner (exclusive)

    # Points outside
    assert rect.contains(101, 50) is False
    assert rect.contains(50, 101) is False
    assert rect.contains(-1, 50) is False
    assert rect.contains(50, -1) is False


def test_rectangle_dimensions():
    """Test that width and height are calculated correctly with exclusive bounds."""
    # Rectangle from (10, 20) to (110, 70)
    rect = zignal.Rectangle(10, 20, 110, 70)
    assert rect.width == 100  # 110 - 10
    assert rect.height == 50  # 70 - 20
    assert rect.area() == 5000  # 100 * 50

    # Zero-sized rectangle
    empty = zignal.Rectangle(50, 50, 50, 50)
    assert empty.width == 0
    assert empty.height == 0
    assert empty.area() == 0
    assert empty.is_empty() is True
