"""Test image functionality focusing on Python bindings.

These tests verify the Python bindings work correctly,
not the underlying image processing algorithms (which are tested in Zig).
"""

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


class TestImageBinding:
    """Test core Image binding functionality."""

    def test_image_creation_from_numpy(self):
        """Test basic image creation from numpy."""
        arr = np.zeros((10, 20, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Check dimensions
        assert img.rows == 10
        assert img.cols == 20

    def test_image_methods_exist(self):
        """Test Image methods are accessible."""
        arr = np.zeros((10, 10, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Verify methods exist and are callable
        assert hasattr(img, "save")
        assert hasattr(img, "to_numpy")
        assert hasattr(img, "resize")
        assert hasattr(img, "letterbox")
        assert hasattr(img, "canvas")

    def test_image_save_load(self):
        """Test saving and loading images works."""
        # Create a test image
        arr = np.full((50, 50, 4), 128, dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Save to temporary file
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
            temp_path = f.name

        try:
            # Should save without error
            img.save(temp_path)
            assert os.path.exists(temp_path)

            # Should load without error
            loaded = zignal.Image.load(temp_path)
            assert loaded is not None
            assert loaded.rows == 50
            assert loaded.cols == 50

        finally:
            os.unlink(temp_path)

    def test_image_class_methods(self):
        """Test class methods are available."""
        assert hasattr(zignal.Image, "load")
        assert hasattr(zignal.Image, "from_numpy")
        assert hasattr(zignal.Image, "add_alpha")


class TestResize:
    """Test resize method binding."""

    def test_resize_scale(self):
        """Test resize accepts scale factor."""
        arr = np.zeros((10, 20, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Scale factor should work
        img2x = img.resize(2.0)
        assert img2x.rows == 20
        assert img2x.cols == 40

        img_half = img.resize(0.5)
        assert img_half.rows == 5
        assert img_half.cols == 10

    def test_resize_dimensions(self):
        """Test resize accepts dimension tuple."""
        arr = np.zeros((50, 100, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Dimension tuple should work
        resized = img.resize((25, 200))
        assert resized.rows == 25
        assert resized.cols == 200

    def test_resize_interpolation_methods(self):
        """Test resize accepts interpolation methods."""
        arr = np.zeros((10, 10, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # All interpolation methods should be accepted
        methods = [
            zignal.InterpolationMethod.NEAREST_NEIGHBOR,
            zignal.InterpolationMethod.BILINEAR,
            zignal.InterpolationMethod.BICUBIC,
            zignal.InterpolationMethod.LANCZOS,
        ]

        for method in methods:
            resized = img.resize(2.0, method=method)
            assert resized is not None

    def test_resize_errors(self):
        """Test resize error handling."""
        arr = np.zeros((10, 10, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Invalid scale
        with pytest.raises(ValueError):
            img.resize(0.0)

        # Invalid dimensions
        with pytest.raises(ValueError):
            img.resize((0, 10))

        # Invalid type
        with pytest.raises(TypeError):
            img.resize("invalid")


class TestLetterbox:
    """Test letterbox method binding."""

    def test_letterbox_square(self):
        """Test letterbox with single size parameter."""
        arr = np.zeros((20, 30, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Single size should work
        square = img.letterbox(40)
        assert square.rows == 40
        assert square.cols == 40

    def test_letterbox_dimensions(self):
        """Test letterbox with dimension tuple."""
        arr = np.zeros((30, 30, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Dimension tuple should work
        wide = img.letterbox((20, 60))
        assert wide.rows == 20
        assert wide.cols == 60

    def test_letterbox_interpolation(self):
        """Test letterbox accepts interpolation methods."""
        arr = np.zeros((10, 15, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Should accept interpolation method
        result = img.letterbox(50, method=zignal.InterpolationMethod.BILINEAR)
        assert result is not None

    def test_letterbox_errors(self):
        """Test letterbox error handling."""
        arr = np.zeros((10, 10, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Invalid size
        with pytest.raises(ValueError):
            img.letterbox(0)

        # Invalid dimensions
        with pytest.raises(ValueError):
            img.letterbox((0, 10))

        # Invalid type
        with pytest.raises(TypeError):
            img.letterbox("invalid")


class TestNumpyIntegration:
    """Test NumPy-specific functionality."""

    def test_from_numpy_validation(self):
        """Test from_numpy validates inputs correctly."""
        # Wrong dtype
        arr = np.zeros((10, 20, 3), dtype=np.float32)
        with pytest.raises(TypeError, match="dtype uint8"):
            zignal.Image.from_numpy(arr)

        # Wrong shape (2D)
        arr = np.zeros((10, 20), dtype=np.uint8)
        with pytest.raises(ValueError, match="shape"):
            zignal.Image.from_numpy(arr)

        # Wrong channels
        arr = np.zeros((10, 20, 2), dtype=np.uint8)
        with pytest.raises(ValueError, match="3 channels.*or 4 channels"):
            zignal.Image.from_numpy(arr)

        # Non-contiguous
        arr = np.zeros((10, 20, 6), dtype=np.uint8)
        arr_view = arr[:, :, ::2]  # Non-contiguous view
        with pytest.raises(ValueError, match="not C-contiguous"):
            zignal.Image.from_numpy(arr_view)

    def test_to_numpy_options(self):
        """Test to_numpy include_alpha parameter."""
        arr = np.zeros((5, 5, 4), dtype=np.uint8)
        arr[:, :] = [100, 150, 200, 128]
        img = zignal.Image.from_numpy(arr)

        # With alpha (default)
        arr_with_alpha = img.to_numpy()
        assert arr_with_alpha.shape == (5, 5, 4)

        # Without alpha
        arr_without_alpha = img.to_numpy(include_alpha=False)
        assert arr_without_alpha.shape == (5, 5, 3)

    def test_add_alpha_static_method(self):
        """Test add_alpha helper method."""
        # Create 3-channel array
        arr_rgb = np.zeros((10, 20, 3), dtype=np.uint8)

        # Add alpha with default
        arr_rgba = zignal.Image.add_alpha(arr_rgb)
        assert arr_rgba.shape == (10, 20, 4)
        assert np.all(arr_rgba[:, :, 3] == 255)

        # Add alpha with custom value
        arr_rgba2 = zignal.Image.add_alpha(arr_rgb, 128)
        assert np.all(arr_rgba2[:, :, 3] == 128)


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
