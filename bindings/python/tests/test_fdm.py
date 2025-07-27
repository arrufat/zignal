"""Test Feature Distribution Matching functionality."""

import pytest
import zignal
import tempfile
import os

try:
    import numpy as np
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False


def test_fdm_basic():
    """Test basic FDM functionality with Image objects."""
    # Create temporary test images
    with tempfile.TemporaryDirectory() as tmpdir:
        src_path = os.path.join(tmpdir, "source.png")
        ref_path = os.path.join(tmpdir, "reference.png")

        # Create and save source image (mostly red)
        if HAS_NUMPY:
            src_arr = np.zeros((50, 50, 3), dtype=np.uint8)
            src_arr[:, :, 0] = 200  # High red channel
            src_arr[:, :, 1] = 50   # Low green
            src_arr[:, :, 2] = 50   # Low blue
            src_img = zignal.Image.from_numpy(src_arr)
            src_img.save(src_path)
        else:
            # Skip test if numpy not available
            pytest.skip("NumPy not available for test setup")

        # Create and save reference image (mostly blue)
        if HAS_NUMPY:
            ref_arr = np.zeros((50, 50, 3), dtype=np.uint8)
            ref_arr[:, :, 0] = 50   # Low red
            ref_arr[:, :, 1] = 50   # Low green
            ref_arr[:, :, 2] = 200  # High blue channel
            ref_img = zignal.Image.from_numpy(ref_arr)
            ref_img.save(ref_path)

        # Load images
        src_img = zignal.Image.load(src_path)
        ref_img = zignal.Image.load(ref_path)

        # Apply FDM
        result = zignal.feature_distribution_match(src_img, ref_img)

        # Should return None (in-place modification)
        assert result is None

        # Verify source image was modified
        if HAS_NUMPY:
            result_arr = src_img.to_numpy(include_alpha=False)
            # After FDM, source should have similar color distribution to reference
            # The dominant channel should shift from red to blue
            avg_red = np.mean(result_arr[:, :, 0])
            avg_blue = np.mean(result_arr[:, :, 2])
            assert avg_blue > avg_red, "FDM should transfer blue dominance from reference"


def test_fdm_with_numpy_workflow():
    """Test FDM in a typical NumPy workflow."""
    if not HAS_NUMPY:
        pytest.skip("NumPy not available")

    # Create source array (gradient pattern)
    src_arr = np.zeros((100, 100, 3), dtype=np.uint8)
    for i in range(100):
        for j in range(100):
            src_arr[i, j] = [i * 2, j * 2, (i + j) // 2]

    # Keep a copy of the original for comparison
    src_arr_original = src_arr.copy()

    # Create reference array (different color pattern)
    ref_arr = np.zeros((100, 100, 3), dtype=np.uint8)
    for i in range(100):
        for j in range(100):
            ref_arr[i, j] = [100 + i // 2, 50 + j // 2, 200 - (i + j) // 4]

    # Convert to Image
    src_img = zignal.Image.from_numpy(src_arr)
    ref_img = zignal.Image.from_numpy(ref_arr)

    # Apply FDM
    zignal.feature_distribution_match(src_img, ref_img)

    # Convert back to numpy
    result_arr = src_img.to_numpy(include_alpha=False)

    # Basic sanity checks
    assert result_arr.shape == src_arr_original.shape
    assert result_arr.dtype == src_arr_original.dtype

    # Check that the result is different from original
    assert not np.array_equal(result_arr, src_arr_original)

    # Check that mean colors are closer to reference
    src_mean = np.mean(src_arr_original, axis=(0, 1))
    ref_mean = np.mean(ref_arr, axis=(0, 1))
    result_mean = np.mean(result_arr, axis=(0, 1))

    # Distance from result to reference should be less than original to reference
    orig_dist = np.linalg.norm(src_mean - ref_mean)
    result_dist = np.linalg.norm(result_mean - ref_mean)
    assert result_dist < orig_dist, "Result should be closer to reference distribution"


def test_fdm_error_handling():
    """Test error handling for FDM function."""
    # Test with None arguments
    with pytest.raises(TypeError):
        zignal.feature_distribution_match(None, None)

    # Test with wrong types
    with pytest.raises(TypeError):
        zignal.feature_distribution_match("not_an_image", "also_not_an_image")

    # Test with only one Image
    if HAS_NUMPY:
        arr = np.zeros((10, 10, 3), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        with pytest.raises(TypeError):
            zignal.feature_distribution_match(img, "not_an_image")

        with pytest.raises(TypeError):
            zignal.feature_distribution_match("not_an_image", img)


def test_fdm_preserves_structure():
    """Test that FDM preserves image structure while changing colors."""
    if not HAS_NUMPY:
        pytest.skip("NumPy not available")

    # Create source with a specific pattern (cross)
    src_arr = np.zeros((50, 50, 3), dtype=np.uint8)
    # Vertical line
    src_arr[20:30, :, :] = 255
    # Horizontal line
    src_arr[:, 20:30, :] = 255

    # Create uniform reference
    ref_arr = np.full((50, 50, 3), 128, dtype=np.uint8)
    ref_arr[:, :, 0] = 50   # Low red
    ref_arr[:, :, 1] = 100  # Medium green
    ref_arr[:, :, 2] = 200  # High blue

    # Convert to Image
    src_img = zignal.Image.from_numpy(src_arr)
    ref_img = zignal.Image.from_numpy(ref_arr)

    # Apply FDM
    zignal.feature_distribution_match(src_img, ref_img)

    # Convert back
    result_arr = src_img.to_numpy(include_alpha=False)

    # Convert to grayscale to check structure
    src_gray = np.mean(src_arr, axis=2)
    result_gray = np.mean(result_arr, axis=2)

    # Find edges (where intensity changes)
    src_edges = np.abs(np.diff(src_gray, axis=0))
    result_edges = np.abs(np.diff(result_gray, axis=0))

    # Edge locations should be similar (structure preserved)
    src_edge_mask = src_edges > 10
    result_edge_mask = result_edges > 10

    # Most edge pixels should match
    matching_edges = np.sum(src_edge_mask == result_edge_mask)
    total_pixels = src_edge_mask.size
    match_ratio = matching_edges / total_pixels

    assert match_ratio > 0.9, f"Structure preservation too low: {match_ratio:.2f}"


def test_fdm_different_sizes():
    """Test FDM with different sized images."""
    if not HAS_NUMPY:
        pytest.skip("NumPy not available")

    # Source and reference can have different sizes
    src_arr = np.full((30, 40, 3), 100, dtype=np.uint8)
    ref_arr = np.full((60, 80, 3), 200, dtype=np.uint8)

    src_img = zignal.Image.from_numpy(src_arr)
    ref_img = zignal.Image.from_numpy(ref_arr)

    # Should work fine - FDM handles different sizes
    zignal.feature_distribution_match(src_img, ref_img)

    # Source dimensions should be unchanged
    assert src_img.rows == 30
    assert src_img.cols == 40


if __name__ == "__main__":
    pytest.main([__file__, "-v", "-s"])
