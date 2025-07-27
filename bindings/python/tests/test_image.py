"""Test image functionality including numpy integration and resize."""

import pytest
import tempfile
import os

try:
    import numpy as np
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False

import zignal

# Skip all tests in this module if numpy is not available
pytestmark = pytest.mark.skipif(not HAS_NUMPY, reason="NumPy is not installed")


def test_image_creation():
    """Test basic image creation from numpy."""

    # Create image from numpy array
    arr = np.zeros((10, 20, 4), dtype=np.uint8)
    img = zignal.Image.from_numpy(arr)

    # Check dimensions
    assert img.rows == 10
    assert img.cols == 20


def test_image_save_load():
    """Test saving and loading images."""

    # Create a test image
    arr = np.zeros((100, 150, 4), dtype=np.uint8)
    arr[:50, :75] = [255, 0, 0, 255]  # Red top-left
    arr[50:, 75:] = [0, 0, 255, 255]  # Blue bottom-right

    img = zignal.Image.from_numpy(arr)

    # Save to temporary file
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
        temp_path = f.name

    try:
        img.save(temp_path)

        # Load back
        loaded = zignal.Image.load(temp_path)

        # Check dimensions
        assert loaded.rows == 100
        assert loaded.cols == 150

        # Check data
        loaded_arr = loaded.to_numpy()
        np.testing.assert_array_equal(arr, loaded_arr)

    finally:
        os.unlink(temp_path)


def test_resize_scale():
    """Test resizing by scale factor."""

    # Create a small test image
    arr = np.zeros((10, 20, 4), dtype=np.uint8)
    arr[:, :] = [100, 150, 200, 255]
    img = zignal.Image.from_numpy(arr)

    # Scale up by 2x
    img2x = img.resize(2.0)
    assert img2x.rows == 20
    assert img2x.cols == 40

    # Scale down by 0.5x
    img_half = img.resize(0.5)
    assert img_half.rows == 5
    assert img_half.cols == 10

    # Scale by 1.0 (no change)
    img_same = img.resize(1.0)
    assert img_same.rows == 10
    assert img_same.cols == 20


def test_resize_dimensions():
    """Test resizing to specific dimensions."""

    # Create test image
    arr = np.zeros((50, 100, 4), dtype=np.uint8)
    img = zignal.Image.from_numpy(arr)

    # Resize to specific dimensions
    resized = img.resize((25, 200))
    assert resized.rows == 25
    assert resized.cols == 200

    # Resize to square
    square = img.resize((64, 64))
    assert square.rows == 64
    assert square.cols == 64


def test_resize_interpolation():
    """Test different interpolation methods."""

    # Create a small test image with pattern
    arr = np.zeros((10, 10, 4), dtype=np.uint8)
    # Create checkerboard pattern
    arr[::2, ::2] = [255, 255, 255, 255]  # White
    arr[1::2, 1::2] = [255, 255, 255, 255]  # White
    img = zignal.Image.from_numpy(arr)

    # Test all interpolation methods
    methods = [
        zignal.InterpolationMethod.NEAREST_NEIGHBOR,
        zignal.InterpolationMethod.BILINEAR,
        zignal.InterpolationMethod.BICUBIC,
        zignal.InterpolationMethod.CATMULL_ROM,
        zignal.InterpolationMethod.MITCHELL,
        zignal.InterpolationMethod.LANCZOS,
    ]

    for method in methods:
        # Should not raise any errors
        resized = img.resize(2.0, method=method)
        assert resized.rows == 20
        assert resized.cols == 20


def test_resize_errors():
    """Test resize error handling."""

    arr = np.zeros((10, 10, 4), dtype=np.uint8)
    img = zignal.Image.from_numpy(arr)

    # Invalid scale factor
    with pytest.raises(ValueError):
        img.resize(0.0)

    with pytest.raises(ValueError):
        img.resize(-1.5)

    # Invalid dimensions
    with pytest.raises(ValueError):
        img.resize((0, 10))

    with pytest.raises(ValueError):
        img.resize((10, -5))

    # Invalid argument type
    with pytest.raises(TypeError):
        img.resize("invalid")

    # Invalid tuple size
    with pytest.raises((TypeError, ValueError)):
        img.resize((10,))  # Only one dimension

    with pytest.raises((TypeError, ValueError)):
        img.resize((10, 20, 30))  # Too many dimensions


def test_letterbox_square():
    """Test letterboxing to square dimensions."""

    # Create a 3:2 aspect ratio image (wider than tall)
    arr = np.zeros((20, 30, 4), dtype=np.uint8)
    arr[:, :] = [100, 150, 200, 255]  # Light blue
    img = zignal.Image.from_numpy(arr)

    # Letterbox to square - should add padding top and bottom
    square = img.letterbox(40)
    assert square.rows == 40
    assert square.cols == 40

    # Check that the image was scaled to fit width
    square_arr = square.to_numpy()

    # The original 20x30 image scaled to fit 40x40 should be 27x40 (rounded)
    # So padding should be approximately (40-27)/2 = 6-7 rows on top and bottom

    # Check top padding is black
    assert np.all(square_arr[0, :, :3] == 0)  # First row should be black

    # Check bottom padding is black
    assert np.all(square_arr[-1, :, :3] == 0)  # Last row should be black

    # Check middle has the original color
    mid_row = square.rows // 2
    assert np.all(square_arr[mid_row, 20, :3] == [100, 150, 200])


def test_letterbox_custom_dimensions():
    """Test letterboxing to custom dimensions."""

    # Create a square image
    arr = np.zeros((30, 30, 4), dtype=np.uint8)
    arr[:] = [255, 100, 50, 255]  # Orange
    img = zignal.Image.from_numpy(arr)

    # Letterbox to wide format - should add padding left and right
    wide = img.letterbox((20, 60))
    assert wide.rows == 20
    assert wide.cols == 60

    wide_arr = wide.to_numpy()

    # The 30x30 image scaled to fit 20x60 should be 20x20
    # So padding should be (60-20)/2 = 20 columns on each side

    # Check left padding is black
    assert np.all(wide_arr[:, 0, :3] == 0)

    # Check right padding is black
    assert np.all(wide_arr[:, -1, :3] == 0)

    # Check middle has the original color
    mid_col = wide.cols // 2
    assert np.all(wide_arr[10, mid_col, :3] == [255, 100, 50])

    # Letterbox to tall format - should add padding top and bottom
    tall = img.letterbox((60, 20))
    assert tall.rows == 60
    assert tall.cols == 20

    tall_arr = tall.to_numpy()

    # Check top and bottom padding
    assert np.all(tall_arr[0, :, :3] == 0)
    assert np.all(tall_arr[-1, :, :3] == 0)


def test_letterbox_no_padding_needed():
    """Test letterbox when aspect ratio already matches."""

    # Create image with 2:1 aspect ratio
    arr = np.ones((50, 100, 4), dtype=np.uint8) * 128
    img = zignal.Image.from_numpy(arr)

    # Letterbox to same aspect ratio - should just resize
    result = img.letterbox((100, 200))
    assert result.rows == 100
    assert result.cols == 200

    # Should be uniformly gray (no black padding)
    result_arr = result.to_numpy()
    assert np.all(result_arr[:, :, :3] == 128)


def test_letterbox_interpolation_methods():
    """Test letterbox with different interpolation methods."""

    # Create a small test image
    arr = np.zeros((10, 15, 4), dtype=np.uint8)
    arr[5, 7] = [255, 255, 255, 255]  # Single white pixel
    img = zignal.Image.from_numpy(arr)

    methods = [
        zignal.InterpolationMethod.NEAREST_NEIGHBOR,
        zignal.InterpolationMethod.BILINEAR,
        zignal.InterpolationMethod.BICUBIC,
        zignal.InterpolationMethod.LANCZOS,
    ]

    for method in methods:
        # Should not raise any errors
        result = img.letterbox(50, method=method)
        assert result.rows == 50
        assert result.cols == 50


def test_letterbox_errors():
    """Test letterbox error handling."""

    arr = np.zeros((10, 10, 4), dtype=np.uint8)
    img = zignal.Image.from_numpy(arr)

    # Invalid size (0 or negative)
    with pytest.raises(ValueError):
        img.letterbox(0)

    with pytest.raises(ValueError):
        img.letterbox(-10)

    # Invalid dimensions
    with pytest.raises(ValueError):
        img.letterbox((0, 10))

    with pytest.raises(ValueError):
        img.letterbox((10, -5))

    # Invalid argument type
    with pytest.raises(TypeError):
        img.letterbox("invalid")

    # Invalid tuple size
    with pytest.raises((TypeError, ValueError)):
        img.letterbox((10,))  # Only one dimension

    with pytest.raises((TypeError, ValueError)):
        img.letterbox((10, 20, 30))  # Too many dimensions


def test_letterbox_preserves_aspect_ratio():
    """Test that letterbox correctly preserves aspect ratio."""

    # Create distinct pattern to verify aspect ratio preservation
    arr = np.zeros((40, 60, 4), dtype=np.uint8)
    # Create a circle in the center
    center_y, center_x = 20, 30
    radius = 15
    for y in range(40):
        for x in range(60):
            if (y - center_y)**2 + (x - center_x)**2 <= radius**2:
                arr[y, x] = [255, 255, 255, 255]

    img = zignal.Image.from_numpy(arr)

    # Letterbox to different sizes
    small_square = img.letterbox(30)
    large_square = img.letterbox(100)
    wide = img.letterbox((50, 200))

    # Convert back to numpy
    small_arr = small_square.to_numpy()
    large_arr = large_square.to_numpy()
    wide_arr = wide.to_numpy()

    # In all cases, the circle should remain circular (not stretched)
    # We can't easily verify the exact shape, but we can check that
    # there's padding where expected

    # Small square should have top/bottom padding
    assert np.any(small_arr[0, :, :3] == 0)  # Top row has black
    assert np.any(small_arr[-1, :, :3] == 0)  # Bottom row has black

    # Wide format should have left/right padding
    assert np.any(wide_arr[:, 0, :3] == 0)  # Left column has black
    assert np.any(wide_arr[:, -1, :3] == 0)  # Right column has black


def test_resize_preserves_content():
    """Test that resize preserves image content reasonably."""

    # Create image with distinct regions
    arr = np.zeros((40, 40, 4), dtype=np.uint8)
    # Red square in top-left
    arr[:20, :20] = [255, 0, 0, 255]
    # Green square in top-right
    arr[:20, 20:] = [0, 255, 0, 255]
    # Blue square in bottom-left
    arr[20:, :20] = [0, 0, 255, 255]
    # White square in bottom-right
    arr[20:, 20:] = [255, 255, 255, 255]

    img = zignal.Image.from_numpy(arr)

    # Resize smaller
    small = img.resize((20, 20))
    small_arr = small.to_numpy()

    # Check corners still have appropriate colors
    # Top-left should be reddish
    assert small_arr[0, 0, 0] > 200  # High red
    assert small_arr[0, 0, 1] < 50   # Low green

    # Top-right should be greenish
    assert small_arr[0, -1, 1] > 200  # High green
    assert small_arr[0, -1, 0] < 50   # Low red

    # Bottom-left should be blueish
    assert small_arr[-1, 0, 2] > 200  # High blue
    assert small_arr[-1, 0, 0] < 50   # Low red

    # Bottom-right should be white
    assert small_arr[-1, -1, 0] > 200  # High red
    assert small_arr[-1, -1, 1] > 200  # High green
    assert small_arr[-1, -1, 2] > 200  # High blue


# ============================================================================
# NumPy Integration Tests
# ============================================================================

def test_from_numpy_basic():
    """Test basic from_numpy functionality with a simple array."""
    # Create a simple 2x3x3 RGB image
    arr = np.zeros((2, 3, 3), dtype=np.uint8)
    arr[0, 0] = [255, 0, 0]  # Red pixel
    arr[0, 1] = [0, 255, 0]  # Green pixel
    arr[0, 2] = [0, 0, 255]  # Blue pixel
    arr[1, 0] = [255, 255, 0]  # Yellow pixel
    arr[1, 1] = [255, 0, 255]  # Magenta pixel
    arr[1, 2] = [0, 255, 255]  # Cyan pixel

    # Create image from numpy array
    img = zignal.Image.from_numpy(arr)

    # Check dimensions
    assert img.rows == 2
    assert img.cols == 3

    # Convert back to numpy and check if it's the same
    arr2 = img.to_numpy(include_alpha=False)
    np.testing.assert_array_equal(arr, arr2)


def test_from_numpy_rgba():
    """Test that from_numpy works with 4-channel RGBA arrays."""
    # Create a 4-channel RGBA array
    arr = np.zeros((10, 20, 4), dtype=np.uint8)
    arr[5, 10] = [100, 150, 200, 128]  # Semi-transparent pixel

    # Create image from numpy array
    img = zignal.Image.from_numpy(arr)

    # Check dimensions
    assert img.rows == 10
    assert img.cols == 20

    # Convert back to numpy with alpha
    arr2 = img.to_numpy(include_alpha=True)

    # Should be zero-copy for 4-channel arrays
    assert arr2 is arr
    np.testing.assert_array_equal(arr, arr2)

    # Test without alpha
    arr3 = img.to_numpy(include_alpha=False)
    assert arr3.shape == (10, 20, 3)
    np.testing.assert_array_equal(arr3[5, 10], [100, 150, 200])


def test_from_numpy_wrong_dtype():
    """Test that from_numpy rejects arrays with wrong dtype."""
    # Float array
    arr = np.zeros((10, 20, 3), dtype=np.float32)
    with pytest.raises(TypeError, match="dtype uint8"):
        zignal.Image.from_numpy(arr)

    # Int32 array
    arr = np.zeros((10, 20, 3), dtype=np.int32)
    with pytest.raises(TypeError, match="dtype uint8"):
        zignal.Image.from_numpy(arr)


def test_from_numpy_wrong_shape():
    """Test that from_numpy rejects arrays with wrong shape."""
    # 2D array
    arr = np.zeros((10, 20), dtype=np.uint8)
    with pytest.raises(ValueError, match="shape"):
        zignal.Image.from_numpy(arr)

    # 4D array
    arr = np.zeros((5, 10, 20, 3), dtype=np.uint8)
    with pytest.raises(ValueError, match="shape"):
        zignal.Image.from_numpy(arr)

    # Wrong number of channels
    arr = np.zeros((10, 20, 2), dtype=np.uint8)
    with pytest.raises(ValueError, match="3 channels.*or 4 channels"):
        zignal.Image.from_numpy(arr)

    arr = np.zeros((10, 20, 5), dtype=np.uint8)
    with pytest.raises(ValueError, match="3 channels.*or 4 channels"):
        zignal.Image.from_numpy(arr)


def test_from_numpy_non_contiguous():
    """Test that from_numpy requires C-contiguous arrays."""
    # Create a non-contiguous array by using a slice
    arr = np.zeros((10, 20, 6), dtype=np.uint8)
    # Take every other channel to make it non-contiguous
    arr_view = arr[:, :, ::2]  # Shape is (10, 20, 3) but non-contiguous
    assert arr_view.shape == (10, 20, 3)
    assert not arr_view.flags["C_CONTIGUOUS"]

    # Should raise ValueError for non-contiguous arrays
    with pytest.raises(ValueError, match="not C-contiguous"):
        zignal.Image.from_numpy(arr_view)

    # But works when made contiguous
    arr_contiguous = np.ascontiguousarray(arr_view)
    img = zignal.Image.from_numpy(arr_contiguous)

    # Check dimensions
    assert img.rows == 10
    assert img.cols == 20


def test_add_alpha_helper():
    """Test the add_alpha static helper method."""
    # Create a 3-channel RGB array
    arr_rgb = np.zeros((10, 20, 3), dtype=np.uint8)
    arr_rgb[5, 10] = [100, 150, 200]

    # Add alpha channel
    arr_rgba = zignal.Image.add_alpha(arr_rgb)

    # Check shape
    assert arr_rgba.shape == (10, 20, 4)

    # Check that RGB values are preserved
    np.testing.assert_array_equal(arr_rgba[:, :, :3], arr_rgb)

    # Check that alpha is 255
    assert np.all(arr_rgba[:, :, 3] == 255)

    # Test with custom alpha value
    arr_rgba2 = zignal.Image.add_alpha(arr_rgb, 128)
    assert np.all(arr_rgba2[:, :, 3] == 128)

    # Now we can use zero-copy
    img = zignal.Image.from_numpy(arr_rgba)
    arr_back = img.to_numpy(include_alpha=True)

    # Should be the same object (zero-copy)
    assert arr_back is arr_rgba


def test_to_numpy_include_alpha():
    """Test the include_alpha parameter of to_numpy."""
    # Create a 4-channel array
    arr = np.zeros((5, 5, 4), dtype=np.uint8)
    for i in range(5):
        for j in range(5):
            arr[i, j] = [i*50, j*50, (i+j)*25, 200]

    # Create image
    img = zignal.Image.from_numpy(arr)

    # Get with alpha (default)
    arr_with_alpha = img.to_numpy()
    assert arr_with_alpha.shape == (5, 5, 4)
    np.testing.assert_array_equal(arr_with_alpha, arr)

    # Get without alpha
    arr_without_alpha = img.to_numpy(include_alpha=False)
    assert arr_without_alpha.shape == (5, 5, 3)
    np.testing.assert_array_equal(arr_without_alpha, arr[:, :, :3])


def test_from_numpy_memory_management():
    """Test that memory is properly managed with numpy references."""
    # Create array
    arr = np.ones((10, 10, 3), dtype=np.uint8) * 42

    # Create image
    img = zignal.Image.from_numpy(arr)

    # Delete the original array reference
    del arr

    # Force garbage collection
    import gc
    gc.collect()

    # Image should still be valid because it holds a reference
    assert img.rows == 10
    assert img.cols == 10

    # Should still be able to convert to numpy
    arr2 = img.to_numpy(include_alpha=False)
    assert np.all(arr2 == 42)


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
