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
    """Test FDM class binding."""

    def test_fdm_class_exists(self):
        """Test FeatureDistributionMatching class is available."""
        assert hasattr(zignal, "FeatureDistributionMatching")
        assert callable(zignal.FeatureDistributionMatching)

    def test_fdm_instance_creation(self):
        """Test creating FDM instance."""
        fdm = zignal.FeatureDistributionMatching()
        assert fdm is not None

        # Check that it has expected methods
        assert hasattr(fdm, "match")
        assert hasattr(fdm, "set_source")
        assert hasattr(fdm, "set_target")
        assert hasattr(fdm, "update")

    @pytest.mark.skipif(not HAS_NUMPY, reason="NumPy not available")
    def test_fdm_accepts_images(self):
        """Test FDM accepts Image objects."""
        # Create two simple images
        src_arr = np.full((10, 10, 3), 100, dtype=np.uint8)
        ref_arr = np.full((10, 10, 3), 200, dtype=np.uint8)

        src_img = zignal.Image.from_numpy(src_arr)
        ref_img = zignal.Image.from_numpy(ref_arr)

        # Create FDM instance and apply
        fdm = zignal.FeatureDistributionMatching()
        result = fdm.match(src_img, ref_img)

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
        fdm = zignal.FeatureDistributionMatching()
        fdm.match(src_img, ref_img)

        # Source dimensions should be unchanged
        assert src_img.rows == 20
        assert src_img.cols == 30

    @pytest.mark.skipif(not HAS_NUMPY, reason="NumPy not available")
    def test_fdm_batch_processing(self):
        """Test FDM batch processing with reused target."""
        # Create target and multiple sources
        target_arr = np.full((10, 10, 3), 200, dtype=np.uint8)
        target_img = zignal.Image.from_numpy(target_arr)

        fdm = zignal.FeatureDistributionMatching()
        fdm.set_target(target_img)

        # Process multiple images with same target
        for i in range(3):
            src_arr = np.full((10, 10, 3), 50 + i * 50, dtype=np.uint8)
            src_img = zignal.Image.from_numpy(src_arr)

            fdm.set_source(src_img)
            fdm.update()

            # Verify source was modified
            result_arr = src_img.to_numpy(include_alpha=False)
            assert not np.array_equal(result_arr, src_arr)


class TestFDMErrors:
    """Test FDM error handling."""

    def test_fdm_none_arguments(self):
        """Test FDM with None arguments."""
        fdm = zignal.FeatureDistributionMatching()
        with pytest.raises(TypeError):
            fdm.match(None, None)

    def test_fdm_wrong_types(self):
        """Test FDM with wrong argument types."""
        fdm = zignal.FeatureDistributionMatching()

        with pytest.raises(TypeError):
            fdm.match("not_an_image", "also_not_an_image")

        with pytest.raises(TypeError):
            fdm.match(123, 456)

    @pytest.mark.skipif(not HAS_NUMPY, reason="NumPy not available")
    def test_fdm_mixed_types(self):
        """Test FDM with one valid and one invalid argument."""
        arr = np.zeros((10, 10, 3), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        fdm = zignal.FeatureDistributionMatching()

        # First arg invalid
        with pytest.raises(TypeError):
            fdm.match("not_an_image", img)

        # Second arg invalid
        with pytest.raises(TypeError):
            fdm.match(img, "not_an_image")

    def test_fdm_update_without_images(self):
        """Test calling update without setting images."""
        fdm = zignal.FeatureDistributionMatching()

        # Should raise error when no images are set
        with pytest.raises(RuntimeError):
            fdm.update()


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
