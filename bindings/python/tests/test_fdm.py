"""Test Feature Distribution Matching binding functionality."""

import pytest

import zignal


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

    def test_fdm_accepts_images(self):
        """Test FDM accepts Image objects."""
        src_img = zignal.Image(10, 10, (100, 100, 100))
        ref_img = zignal.Image(10, 10, (200, 200, 200))

        # Create FDM instance and apply
        fdm = zignal.FeatureDistributionMatching()
        result = fdm.match(src_img, ref_img)

        # Should return None (in-place modification)
        assert result is None

    def test_fdm_works_with_different_sizes(self):
        src_img = zignal.Image(20, 30, (0, 0, 0))
        ref_img = zignal.Image(50, 40, (0, 0, 0))

        # Should work without error
        fdm = zignal.FeatureDistributionMatching()
        fdm.match(src_img, ref_img)

        # Source dimensions should be unchanged
        assert src_img.rows == 20
        assert src_img.cols == 30

    def test_fdm_batch_processing(self):
        """Test FDM batch processing with reused target."""
        target_img = zignal.Image(10, 10, (200, 200, 200))

        fdm = zignal.FeatureDistributionMatching()
        fdm.set_target(target_img)

        for i in range(3):
            val = 50 + i * 50
            src_img = zignal.Image(10, 10, (val, val, val))
            org_img = src_img.copy()

            fdm.set_source(src_img)
            fdm.update()

            assert not src_img[0, 0] == org_img[0, 0]


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

    def test_fdm_mixed_types(self):
        """Test FDM with one valid and one invalid argument."""
        img = zignal.Image(10, 10, 0)

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
