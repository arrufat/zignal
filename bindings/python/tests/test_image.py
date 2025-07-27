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
