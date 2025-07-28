"""Test Feature Distribution Matching binding functionality.

These tests focus on verifying the Python binding works correctly,
not testing the FDM algorithm itself (which is tested in Zig).
"""

import pytest
import zignal
import tempfile
import os

try:
    import numpy as np

    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False


class TestFDMBinding:
    """Test FDM function binding."""

    def test_fdm_function_exists(self):
        """Test feature_distribution_match function is available."""
        assert hasattr(zignal, "feature_distribution_match")
        assert callable(zignal.feature_distribution_match)

    @pytest.mark.skipif(not HAS_NUMPY, reason="NumPy not available")
    def test_fdm_accepts_images(self):
        """Test FDM accepts Image objects."""
        # Create two simple images
        src_arr = np.full((10, 10, 3), 100, dtype=np.uint8)
        ref_arr = np.full((10, 10, 3), 200, dtype=np.uint8)

        src_img = zignal.Image.from_numpy(src_arr)
        ref_img = zignal.Image.from_numpy(ref_arr)

        # Should work without error
        result = zignal.feature_distribution_match(src_img, ref_img)

        # Should return None (in-place modification)
        assert result is None

    @pytest.mark.skipif(not HAS_NUMPY, reason="NumPy not available")
    def test_fdm_works_with_different_sizes(self):
        """Test FDM works with different sized images."""
        # Different sized images should be accepted
        src_arr = np.zeros((20, 30, 3), dtype=np.uint8)
        ref_arr = np.zeros((50, 40, 3), dtype=np.uint8)

        src_img = zignal.Image.from_numpy(src_arr)
        ref_img = zignal.Image.from_numpy(ref_arr)

        # Should work without error
        zignal.feature_distribution_match(src_img, ref_img)

        # Source dimensions should be unchanged
        assert src_img.rows == 20
        assert src_img.cols == 30


class TestFDMErrors:
    """Test FDM error handling."""

    def test_fdm_none_arguments(self):
        """Test FDM with None arguments."""
        with pytest.raises(TypeError):
            zignal.feature_distribution_match(None, None)

    def test_fdm_wrong_types(self):
        """Test FDM with wrong argument types."""
        with pytest.raises(TypeError):
            zignal.feature_distribution_match("not_an_image", "also_not_an_image")

        with pytest.raises(TypeError):
            zignal.feature_distribution_match(123, 456)

    @pytest.mark.skipif(not HAS_NUMPY, reason="NumPy not available")
    def test_fdm_mixed_types(self):
        """Test FDM with one valid and one invalid argument."""
        arr = np.zeros((10, 10, 3), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # First arg invalid
        with pytest.raises(TypeError):
            zignal.feature_distribution_match("not_an_image", img)

        # Second arg invalid
        with pytest.raises(TypeError):
            zignal.feature_distribution_match(img, "not_an_image")


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
