import pytest

try:
    import numpy as np

    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False

import zignal

pytestmark = pytest.mark.skipif(not HAS_NUMPY, reason="NumPy is not installed")


def test_image_iteration_count_and_order():
    # 2x3 image with 4 channels, values easy to assert
    arr = np.arange(2 * 3 * 4, dtype=np.uint8).reshape(2, 3, 4)
    img = zignal.Image.from_numpy(arr)

    triples = list(img)
    assert len(triples) == 2 * 3

    # First pixel
    r, c, px = triples[0]
    assert (r, c) == (0, 0)
    exp = arr[0, 0]
    assert (px.r, px.g, px.b, px.a) == (int(exp[0]), int(exp[1]), int(exp[2]), int(exp[3]))

    # Last pixel
    r, c, px = triples[-1]
    assert (r, c) == (1, 2)
    exp = arr[1, 2]
    assert (px.r, px.g, px.b, px.a) == (int(exp[0]), int(exp[1]), int(exp[2]), int(exp[3]))


def test_image_iteration_matches_getitem():
    rows, cols = 5, 7
    arr = np.random.randint(0, 256, (rows, cols, 4), dtype=np.uint8)
    img = zignal.Image.from_numpy(arr)

    count = 0
    for r, c, px in img:
        assert img[r, c] == px
        count += 1

    assert count == len(img)


def test_iterator_return_types():
    """Test that iteration returns the correct types for each format."""
    # Test Grayscale format - should return integer
    gray_img = zignal.Image(5, 5, 128, format=zignal.Grayscale)
    for r, c, pixel in gray_img:
        assert isinstance(pixel, int), f"Grayscale should return int, got {type(pixel)}"
        assert pixel == 128
        break  # Just test first pixel

    # Test RGB format - should return Rgb object
    rgb_img = zignal.Image(5, 5, (255, 128, 64), format=zignal.Rgb)
    for r, c, pixel in rgb_img:
        assert isinstance(pixel, zignal.Rgb), f"RGB should return Rgb object, got {type(pixel)}"
        assert pixel.r == 255
        assert pixel.g == 128
        assert pixel.b == 64
        break  # Just test first pixel

    # Test RGBA format - should return Rgba object
    rgba_img = zignal.Image(5, 5, (255, 128, 64, 32), format=zignal.Rgba)
    for r, c, pixel in rgba_img:
        assert isinstance(pixel, zignal.Rgba), f"RGBA should return Rgba object, got {type(pixel)}"
        assert pixel.r == 255
        assert pixel.g == 128
        assert pixel.b == 64
        assert pixel.a == 32
        break  # Just test first pixel


def test_view_iteration_stride_and_bounds():
    rows, cols = 6, 8
    arr = np.arange(rows * cols * 4, dtype=np.uint8).reshape(rows, cols, 4)
    img = zignal.Image.from_numpy(arr)

    # Create a view rectangle (left, top, right, bottom)
    left, top, right, bottom = 2, 1, 6, 5  # width=4, height=4
    rect = zignal.Rectangle(left, top, right, bottom)
    view = img.view(rect)

    triples = list(view)
    assert len(triples) == (bottom - top) * (right - left)

    # Ensure local (r,c) are relative to the view and values match the parent
    for r, c, px in triples:
        assert 0 <= r < (bottom - top)
        assert 0 <= c < (right - left)
        parent_px = img[top + r, left + c]
        assert (px.r, px.g, px.b, px.a) == (parent_px.r, parent_px.g, parent_px.b, parent_px.a)
