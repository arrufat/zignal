"""Test numpy functionality with various array configurations."""

import pytest

try:
    import numpy as np
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False

import zignal

# Skip all tests in this module if numpy is not available
pytestmark = pytest.mark.skipif(not HAS_NUMPY, reason="NumPy is not installed")


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
    img = zignal.ImageRgb.from_numpy(arr)

    # Check dimensions
    assert img.rows == 2
    assert img.cols == 3

    # Convert back to numpy and check if it's the same
    arr2 = img.to_numpy()
    np.testing.assert_array_equal(arr, arr2)


def test_from_numpy_zero_copy():
    """Test that from_numpy uses zero-copy when possible."""
    # Create a C-contiguous array
    arr = np.zeros((10, 20, 3), dtype=np.uint8)
    arr[5, 10] = [100, 150, 200]

    # Create image from numpy array
    img = zignal.ImageRgb.from_numpy(arr)

    # Modify the original array
    arr[5, 10] = [50, 75, 100]

    # Convert back to numpy - should reflect the change if zero-copy
    arr2 = img.to_numpy()

    # Check if modification is reflected (proves zero-copy)
    assert np.array_equal(arr2[5, 10], [50, 75, 100])

    # Also check that to_numpy returns the exact same object
    assert arr2 is arr


def test_from_numpy_copy_non_contiguous():
    """Test that from_numpy requires C-contiguous arrays."""
    # Create a non-contiguous array by using a slice
    arr = np.zeros((10, 20, 6), dtype=np.uint8)
    # Take every other channel to make it non-contiguous
    arr_view = arr[:, :, ::2]  # Shape is (10, 20, 3) but non-contiguous
    assert arr_view.shape == (10, 20, 3)
    assert not arr_view.flags["C_CONTIGUOUS"]

    # Should raise ValueError for non-contiguous arrays
    with pytest.raises(ValueError, match="not C-contiguous"):
        zignal.ImageRgb.from_numpy(arr_view)

    # But works when made contiguous
    arr_contiguous = np.ascontiguousarray(arr_view)
    img = zignal.ImageRgb.from_numpy(arr_contiguous)

    # Check dimensions
    assert img.rows == 10
    assert img.cols == 20


def test_from_numpy_wrong_dtype():
    """Test that from_numpy rejects arrays with wrong dtype."""
    # Float array
    arr = np.zeros((10, 20, 3), dtype=np.float32)
    with pytest.raises(TypeError, match="dtype uint8"):
        zignal.ImageRgb.from_numpy(arr)

    # Int32 array
    arr = np.zeros((10, 20, 3), dtype=np.int32)
    with pytest.raises(TypeError, match="dtype uint8"):
        zignal.ImageRgb.from_numpy(arr)


def test_from_numpy_wrong_shape():
    """Test that from_numpy rejects arrays with wrong shape."""
    # 2D array
    arr = np.zeros((10, 20), dtype=np.uint8)
    with pytest.raises(ValueError, match="shape"):
        zignal.ImageRgb.from_numpy(arr)

    # 4D array
    arr = np.zeros((5, 10, 20, 3), dtype=np.uint8)
    with pytest.raises(ValueError, match="shape"):
        zignal.ImageRgb.from_numpy(arr)

    # Wrong number of channels
    arr = np.zeros((10, 20, 4), dtype=np.uint8)
    with pytest.raises(ValueError, match="3 channels"):
        zignal.ImageRgb.from_numpy(arr)

    arr = np.zeros((10, 20, 1), dtype=np.uint8)
    with pytest.raises(ValueError, match="3 channels"):
        zignal.ImageRgb.from_numpy(arr)


def test_from_numpy_none():
    """Test that from_numpy rejects None."""
    with pytest.raises(TypeError):
        zignal.ImageRgb.from_numpy(None)


def test_from_numpy_roundtrip():
    """Test complete roundtrip: numpy -> ImageRgb -> save -> load -> numpy."""
    import os
    import tempfile

    # Create test array with specific pattern
    arr = np.zeros((50, 100, 3), dtype=np.uint8)
    # Create a gradient
    for i in range(50):
        for j in range(100):
            arr[i, j] = [i * 5, j * 2, (i + j) % 256]

    # Convert to ImageRgb
    img = zignal.ImageRgb.from_numpy(arr)

    # Save to temporary file
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
        temp_path = f.name

    try:
        img.save(temp_path)

        # Load back
        img2 = zignal.ImageRgb.load(temp_path)

        # Convert to numpy
        arr2 = img2.to_numpy()

        # Check that data is preserved
        np.testing.assert_array_equal(arr, arr2)

    finally:
        # Clean up
        os.unlink(temp_path)


def test_from_numpy_memory_management():
    """Test that memory is properly managed with numpy references."""
    # Create array
    arr = np.ones((10, 10, 3), dtype=np.uint8) * 42

    # Create image
    img = zignal.ImageRgb.from_numpy(arr)

    # Delete the original array reference
    del arr

    # Force garbage collection
    import gc

    gc.collect()

    # Image should still be valid because it holds a reference
    assert img.rows == 10
    assert img.cols == 10

    # Should still be able to convert to numpy
    arr2 = img.to_numpy()
    assert np.all(arr2 == 42)


def test_from_numpy_fortran_order():
    """Test that from_numpy requires C-contiguous arrays (not Fortran)."""
    # Create Fortran-ordered array
    arr = np.zeros((10, 20, 3), dtype=np.uint8, order="F")
    arr[5, 10] = [100, 150, 200]
    assert arr.flags["F_CONTIGUOUS"]
    assert not arr.flags["C_CONTIGUOUS"]

    # Should raise error for Fortran-ordered arrays
    with pytest.raises(ValueError, match="not C-contiguous"):
        zignal.ImageRgb.from_numpy(arr)

    # But works when made C-contiguous
    arr_c = np.ascontiguousarray(arr)
    img = zignal.ImageRgb.from_numpy(arr_c)
    assert img.rows == 10
    assert img.cols == 20


def test_from_numpy_slice():
    """Test that from_numpy works with array slices when they're C-contiguous."""
    # Create a larger array
    big_arr = np.zeros((100, 100, 3), dtype=np.uint8)
    big_arr[25:75, 25:75] = 255  # White square in middle

    # Take a slice - this particular slice is not C-contiguous
    slice_arr = big_arr[25:75, 25:75]

    # Check if it's C-contiguous
    if not slice_arr.flags["C_CONTIGUOUS"]:
        # Should fail
        with pytest.raises(ValueError, match="not C-contiguous"):
            zignal.ImageRgb.from_numpy(slice_arr)

        # Make it contiguous
        slice_arr = np.ascontiguousarray(slice_arr)

    # Now it should work
    img = zignal.ImageRgb.from_numpy(slice_arr)
    assert img.rows == 50
    assert img.cols == 50

    # Verify data
    arr2 = img.to_numpy()
    assert np.all(arr2 == 255)


if __name__ == "__main__":
    # Run with verbose output
    pytest.main([__file__, "-v", "-s"])
