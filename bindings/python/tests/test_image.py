"""Test image functionality focusing on Python bindings.

These tests verify the Python bindings work correctly,
not the underlying image processing algorithms (which are tested in Zig).
"""

import os
import tempfile

import pytest

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

    def test_image_equality(self):
        """Test Image equality comparison."""
        # Create two identical images
        arr1 = np.ones((10, 20, 4), dtype=np.uint8) * 100
        img1 = zignal.Image.from_numpy(arr1)

        arr2 = np.ones((10, 20, 4), dtype=np.uint8) * 100
        img2 = zignal.Image.from_numpy(arr2)

        # Test equality
        assert img1 == img2
        assert not (img1 != img2)

        # Test with same image
        assert img1 == img1

        # Create different image (different pixel values)
        arr3 = np.ones((10, 20, 4), dtype=np.uint8) * 200
        img3 = zignal.Image.from_numpy(arr3)

        assert img1 != img3
        assert not (img1 == img3)

        # Create image with different dimensions
        arr4 = np.ones((15, 20, 4), dtype=np.uint8) * 100
        img4 = zignal.Image.from_numpy(arr4)

        assert img1 != img4
        assert not (img1 == img4)

        # Test comparison with non-Image objects
        assert img1 is not None
        assert img1 != "string"
        assert img1 != 42

    def test_image_equality_copies_and_views(self):
        """Test equality between copies and views."""
        # Create original image
        arr = np.random.randint(0, 256, (20, 30, 4), dtype=np.uint8)
        img1 = zignal.Image.from_numpy(arr)

        # Create a copy
        img2 = img1.copy()

        # Copy should be equal
        assert img1 == img2

        # Create a view (sub-image)
        rect = zignal.Rectangle(5, 5, 10, 10)
        view = img1.view(rect)

        # View should not be equal to the whole image (different dimensions)
        assert img1 != view

        # Two views of the same region should be equal
        view2 = img1.view(rect)
        assert view == view2

    def test_image_methods_exist(self):
        """Test Image methods are accessible."""
        arr = np.zeros((10, 10, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Verify methods exist and are callable
        assert hasattr(img, "fill")
        assert hasattr(img, "save")
        assert hasattr(img, "to_numpy")
        assert hasattr(img, "resize")
        assert hasattr(img, "letterbox")
        assert hasattr(img, "blur_box")
        assert hasattr(img, "sharpen")
        assert hasattr(img, "copy")
        assert hasattr(img, "flip_left_right")
        assert hasattr(img, "flip_top_bottom")
        assert hasattr(img, "canvas")
        assert hasattr(img, "crop")
        assert hasattr(img, "extract")
        assert hasattr(img, "insert")
        assert hasattr(img, "psnr")
        assert hasattr(img, "view")
        assert hasattr(img, "is_view")

    def test_blur_box_basic(self):
        """Box blur returns same shape and radius 0 is no-op."""
        arr = np.zeros((8, 12, 4), dtype=np.uint8)
        arr[4, 6] = [255, 128, 64, 255]
        img = zignal.Image.from_numpy(arr)

        # Radius 0 should be a copy
        out0 = img.blur_box(0)
        np.testing.assert_array_equal(out0.to_numpy(), img.to_numpy())

        # Positive radius should keep shape
        out1 = img.blur_box(1)
        assert out1.rows == img.rows
        assert out1.cols == img.cols

    def test_sharpen_basic(self):
        """Sharpen returns same shape and radius 0 is no-op."""
        arr = np.zeros((8, 12, 4), dtype=np.uint8)
        arr[4, 6] = [10, 20, 30, 255]
        img = zignal.Image.from_numpy(arr)

        out0 = img.sharpen(0)
        np.testing.assert_array_equal(out0.to_numpy(), img.to_numpy())

        out1 = img.sharpen(1)
        assert out1.rows == img.rows
        assert out1.cols == img.cols

    def test_copy_independent(self):
        """Copy returns independent image memory."""
        arr = np.zeros((4, 4, 4), dtype=np.uint8)
        arr[0, 0] = [10, 20, 30, 40]
        img = zignal.Image.from_numpy(arr)

        cp = img.copy()
        np.testing.assert_array_equal(cp.to_numpy(), img.to_numpy())

        # Modify original and ensure copy unchanged
        imgarr = img.to_numpy()
        imgarr[0, 0] = [1, 2, 3, 4]
        assert not np.array_equal(cp.to_numpy(), img.to_numpy())

    def test_is_view_property(self):
        """Test is_view property for regular images and views."""
        # Create a regular image
        arr = np.zeros((10, 20, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Regular image should not be a view
        assert img.is_view() is False

        # Create a view
        rect = zignal.Rectangle(0, 0, 10, 10)
        view = img.view(rect)

        # View should be marked as a view
        assert view.is_view() is True

    def test_view_basic(self):
        """Test creating a basic view of an image."""
        # Create an image with identifiable content
        arr = np.zeros((20, 30, 4), dtype=np.uint8)
        arr[5:15, 10:20] = [255, 128, 64, 255]  # Fill a rectangle with color
        img = zignal.Image.from_numpy(arr)

        # Create a view of a portion
        rect = zignal.Rectangle(10, 5, 20, 15)  # (left, top, right, bottom)
        view = img.view(rect)

        # Check view dimensions
        assert view.rows == 10  # bottom - top = 15 - 5
        assert view.cols == 10  # right - left = 20 - 10

        # View should see the colored region
        view_arr = view.to_numpy()
        expected_color = [255, 128, 64, 255]
        np.testing.assert_array_equal(view_arr[0, 0], expected_color)

    def test_view_memory_sharing(self):
        """Test that views share memory with parent image."""
        # Create an image
        arr = np.zeros((10, 10, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Create a view
        rect = zignal.Rectangle(2, 2, 8, 8)
        view = img.view(rect)

        # Modify the view
        view.fill((255, 0, 0, 255))

        # Check that parent image was modified
        parent_arr = img.to_numpy()
        # The region [2:8, 2:8] should be red
        expected_color = [255, 0, 0, 255]
        np.testing.assert_array_equal(parent_arr[2, 2], expected_color)
        np.testing.assert_array_equal(parent_arr[7, 7], expected_color)
        # Outside the view should still be black
        np.testing.assert_array_equal(parent_arr[0, 0], [0, 0, 0, 0])
        np.testing.assert_array_equal(parent_arr[9, 9], [0, 0, 0, 0])

    def test_view_bounds_clipping(self):
        """Test that view bounds are clipped to image dimensions."""
        # Create a small image
        arr = np.ones((10, 10, 4), dtype=np.uint8) * 128
        img = zignal.Image.from_numpy(arr)

        # Try to create a view that extends beyond image bounds
        rect = zignal.Rectangle(5, 5, 20, 20)  # Right and bottom exceed image
        view = img.view(rect)

        # View should be clipped to valid region
        assert view.rows == 5  # 10 - 5 (clipped bottom)
        assert view.cols == 5  # 10 - 5 (clipped right)

    def test_nested_views(self):
        """Test creating a view of a view."""
        # Create base image
        arr = np.zeros((20, 20, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Create first view
        rect1 = zignal.Rectangle(5, 5, 15, 15)
        view1 = img.view(rect1)
        assert view1.rows == 10
        assert view1.cols == 10
        assert view1.is_view() == True

        # Create view of the view
        rect2 = zignal.Rectangle(2, 2, 8, 8)
        view2 = view1.view(rect2)
        assert view2.rows == 6
        assert view2.cols == 6
        assert view2.is_view() == True

        # Modify nested view
        view2.fill((100, 100, 100, 255))

        # Check it affected the parent image
        parent_arr = img.to_numpy()
        # The modification should appear at offset (7,7) in parent
        # (5 from view1 offset + 2 from view2 offset)
        np.testing.assert_array_equal(parent_arr[7, 7], [100, 100, 100, 255])

    def test_psnr_returns_float(self):
        """Test PSNR returns a float value."""
        arr1 = np.zeros((10, 10, 4), dtype=np.uint8)
        arr2 = np.zeros((10, 10, 4), dtype=np.uint8)
        arr2[5, 5] = [10, 10, 10, 0]  # Small difference

        img1 = zignal.Image.from_numpy(arr1)
        img2 = zignal.Image.from_numpy(arr2)

        psnr_value = img1.psnr(img2)
        assert isinstance(psnr_value, float)
        assert psnr_value > 0  # Should be a positive value

    def test_psnr_identical_images_inf(self):
        """Test PSNR returns infinity for identical images."""
        arr = np.ones((10, 10, 4), dtype=np.uint8) * 128
        img1 = zignal.Image.from_numpy(arr)
        img2 = zignal.Image.from_numpy(arr.copy())

        psnr_value = img1.psnr(img2)
        assert psnr_value == float("inf")

    def test_psnr_dimension_mismatch_error(self):
        """Test PSNR raises ValueError for dimension mismatch."""
        arr1 = np.zeros((10, 10, 4), dtype=np.uint8)
        arr2 = np.zeros((10, 20, 4), dtype=np.uint8)

        img1 = zignal.Image.from_numpy(arr1)
        img2 = zignal.Image.from_numpy(arr2)

        with pytest.raises(ValueError, match="dimension"):
            img1.psnr(img2)

    def test_psnr_type_error(self):
        """Test PSNR raises TypeError for non-Image argument."""
        arr = np.zeros((10, 10, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        with pytest.raises(TypeError, match="Image"):
            img.psnr(None)

        with pytest.raises(TypeError, match="Image"):
            img.psnr(arr)

        with pytest.raises(TypeError, match="Image"):
            img.psnr(42)

    def test_psnr_with_different_creation_methods(self):
        """Test PSNR works with images created in different ways."""
        # Create images using different methods
        img1 = zignal.Image(10, 10, (128, 128, 128, 255))

        arr = np.ones((10, 10, 4), dtype=np.uint8)
        arr[:, :] = [128, 128, 128, 255]
        img2 = zignal.Image.from_numpy(arr)

        # Should work regardless of how images were created
        psnr_value = img1.psnr(img2)
        assert psnr_value == float("inf")  # Identical images

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


class TestCropExtractInsert:
    """Test crop, extract, and insert methods."""

    def test_crop_basic(self):
        """Test crop method doesn't crash and returns correct size."""
        arr = np.zeros((100, 100, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Create a rectangle
        rect = zignal.Rectangle(10, 10, 60, 60)  # 50x50 region

        # Crop should work and return correct size
        cropped = img.crop(rect)
        assert cropped is not None
        assert cropped.rows == 50
        assert cropped.cols == 50

    def test_extract_basic(self):
        """Test extract method doesn't crash."""
        arr = np.zeros((100, 100, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        rect = zignal.Rectangle(20, 20, 80, 80)  # 60x60 region

        # Basic extraction
        extracted = img.extract(rect)
        assert extracted is not None
        assert extracted.rows == 60
        assert extracted.cols == 60

        # With angle
        import math

        rotated = img.extract(rect, angle=math.radians(45))
        assert rotated is not None

        # With custom size
        resized = img.extract(rect, size=(30, 30))
        assert resized.rows == 30
        assert resized.cols == 30

        # With interpolation method
        extracted_nn = img.extract(rect, method=zignal.InterpolationMethod.NEAREST_NEIGHBOR)
        assert extracted_nn is not None

    def test_insert_basic(self):
        """Test insert method doesn't crash."""
        # Create destination and source images
        arr_dst = np.zeros((200, 200, 4), dtype=np.uint8)
        dst = zignal.Image.from_numpy(arr_dst)

        arr_src = np.full((50, 50, 4), 255, dtype=np.uint8)
        src = zignal.Image.from_numpy(arr_src)

        rect = zignal.Rectangle(10, 10, 60, 60)

        # Basic insertion - should not raise
        dst.insert(src, rect)

        # With angle
        import math

        rect2 = zignal.Rectangle(100, 100, 150, 150)
        dst.insert(src, rect2, angle=math.radians(45))

        # With interpolation method
        dst.insert(src, rect, method=zignal.InterpolationMethod.BICUBIC)


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


class TestPixelAccess:
    """Test pixel access functionality (getitem/setitem)."""

    def test_getitem_returns_rgba(self):
        """Test that __getitem__ returns an Rgba object."""
        # Create test image
        arr = np.zeros((10, 20, 4), dtype=np.uint8)
        arr[5, 10] = [100, 150, 200, 255]
        img = zignal.Image.from_numpy(arr)

        # Get pixel
        pixel = img[5, 10]
        assert isinstance(pixel, zignal.Rgba)
        assert pixel.r == 100
        assert pixel.g == 150
        assert pixel.b == 200
        assert pixel.a == 255

    def test_getitem_bounds_checking(self):
        """Test that __getitem__ raises IndexError for out-of-bounds access."""
        arr = np.zeros((10, 20, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Out of bounds row
        with pytest.raises(IndexError, match="Row index out of bounds"):
            _ = img[10, 5]

        # Negative row
        with pytest.raises(IndexError, match="Row index out of bounds"):
            _ = img[-1, 5]

        # Out of bounds col
        with pytest.raises(IndexError, match="Column index out of bounds"):
            _ = img[5, 20]

        # Negative col
        with pytest.raises(IndexError, match="Column index out of bounds"):
            _ = img[5, -1]

    def test_getitem_type_errors(self):
        """Test that __getitem__ handles type errors properly."""
        arr = np.zeros((10, 20, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Not a tuple
        with pytest.raises(TypeError, match="must be a tuple"):
            _ = img[5]

        # Wrong number of indices
        with pytest.raises(ValueError, match="exactly 2 integers"):
            _ = img[5, 10, 2]

        # Non-integer indices
        with pytest.raises(TypeError, match="must be an integer"):
            _ = img["5", 10]

    def test_setitem_with_tuple(self):
        """Test setting pixels with RGB/RGBA tuples."""
        arr = np.zeros((10, 20, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Set with RGB tuple
        img[5, 10] = (100, 150, 200)
        pixel = img[5, 10]
        assert pixel.r == 100
        assert pixel.g == 150
        assert pixel.b == 200
        assert pixel.a == 255  # Default alpha

        # Set with RGBA tuple
        img[5, 11] = (50, 75, 100, 128)
        pixel = img[5, 11]
        assert pixel.r == 50
        assert pixel.g == 75
        assert pixel.b == 100
        assert pixel.a == 128

    def test_setitem_with_color_objects(self):
        """Test setting pixels with various color objects."""
        arr = np.zeros((10, 20, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Set with Rgba object
        img[0, 0] = zignal.Rgba(255, 0, 0, 255)
        pixel = img[0, 0]
        assert pixel.r == 255
        assert pixel.g == 0
        assert pixel.b == 0
        assert pixel.a == 255

        # Set with Rgb object (should convert to RGBA)
        img[0, 1] = zignal.Rgb(0, 255, 0)
        pixel = img[0, 1]
        assert pixel.r == 0
        assert pixel.g == 255
        assert pixel.b == 0
        assert pixel.a == 255

        # Set with Hsl object (should convert to RGBA)
        img[0, 2] = zignal.Hsl(0, 100, 50)  # Red in HSL
        pixel = img[0, 2]
        assert pixel.r == 255
        assert pixel.g == 0
        assert pixel.b == 0
        assert pixel.a == 255

    def test_setitem_with_grayscale_int(self):
        """Test setting pixels with grayscale integer values."""
        arr = np.zeros((10, 20, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Set with grayscale black
        img[0, 0] = 0
        pixel = img[0, 0]
        assert pixel.r == 0
        assert pixel.g == 0
        assert pixel.b == 0
        assert pixel.a == 255  # Default alpha

        # Set with grayscale gray
        img[0, 1] = 128
        pixel = img[0, 1]
        assert pixel.r == 128
        assert pixel.g == 128
        assert pixel.b == 128
        assert pixel.a == 255

        # Set with grayscale white
        img[0, 2] = 255
        pixel = img[0, 2]
        assert pixel.r == 255
        assert pixel.g == 255
        assert pixel.b == 255
        assert pixel.a == 255

    def test_setitem_bounds_checking(self):
        """Test that __setitem__ raises IndexError for out-of-bounds access."""
        arr = np.zeros((10, 20, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Out of bounds row
        with pytest.raises(IndexError, match="Row index out of bounds"):
            img[10, 5] = (255, 0, 0)

        # Out of bounds col
        with pytest.raises(IndexError, match="Column index out of bounds"):
            img[5, 20] = (255, 0, 0)

    def test_setitem_type_errors(self):
        """Test that __setitem__ handles type errors properly."""
        arr = np.zeros((10, 20, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Invalid color value
        with pytest.raises(TypeError):
            img[5, 10] = "red"  # String not supported

        # Invalid tuple size
        with pytest.raises(ValueError):
            img[5, 10] = (255,)  # Too few values

        with pytest.raises(ValueError):
            img[5, 10] = (255, 0, 0, 255, 128)  # Too many values

        # Invalid grayscale values
        with pytest.raises(ValueError):
            img[5, 10] = -1  # Negative value

        with pytest.raises(ValueError):
            img[5, 10] = 256  # Value too large

    def test_pixel_modification_reflected_in_numpy(self):
        """Test that pixel modifications are reflected in numpy array (zero-copy)."""
        arr = np.zeros((10, 20, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Modify pixel
        img[5, 10] = (100, 150, 200, 255)

        # Check if reflected in numpy array (zero-copy behavior)
        np_view = img.to_numpy()
        assert np_view[5, 10, 0] == 100
        assert np_view[5, 10, 1] == 150
        assert np_view[5, 10, 2] == 200
        assert np_view[5, 10, 3] == 255

    def test_len_returns_total_pixels(self):
        """Test that len() returns the total number of pixels."""
        # Test various sizes
        test_cases = [
            (10, 20),  # 200 pixels
            (100, 100),  # 10000 pixels
            (1, 1),  # 1 pixel
            (480, 640),  # 307200 pixels
        ]

        for rows, cols in test_cases:
            arr = np.zeros((rows, cols, 4), dtype=np.uint8)
            img = zignal.Image.from_numpy(arr)
            assert len(img) == rows * cols

    def test_len_uninitialized_image(self):
        """Test that len() raises ValueError for uninitialized image."""
        # This test would require creating an uninitialized image,
        # but since Image() constructor doesn't allow direct instantiation,
        # we can't test this case directly from Python


class TestFlipMethods:
    """Test flip_left_right and flip_top_bottom methods."""

    def test_flip_returns_image(self):
        """Test that flip methods return Image objects."""
        arr = np.zeros((10, 10, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Test flip_left_right
        result_lr = img.flip_left_right()
        assert result_lr is not None
        assert isinstance(result_lr, zignal.Image)
        assert result_lr is not img  # Different object

        # Test flip_top_bottom
        result_tb = img.flip_top_bottom()
        assert result_tb is not None
        assert isinstance(result_tb, zignal.Image)
        assert result_tb is not img  # Different object

    def test_dimensions_preserved(self):
        """Test that dimensions are preserved after flip."""
        arr = np.zeros((15, 20, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # flip_left_right preserves dimensions
        flipped_lr = img.flip_left_right()
        assert flipped_lr.rows == img.rows
        assert flipped_lr.cols == img.cols

        # flip_top_bottom preserves dimensions
        flipped_tb = img.flip_top_bottom()
        assert flipped_tb.rows == img.rows
        assert flipped_tb.cols == img.cols

    def test_original_unchanged(self):
        """Test that original image is not modified."""
        # Create image with specific color
        arr = np.full((5, 5, 4), [255, 128, 64, 255], dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)

        # Store original pixel values
        orig_pixel = img[0, 0]
        orig_r = orig_pixel.r
        orig_g = orig_pixel.g
        orig_b = orig_pixel.b
        orig_a = orig_pixel.a

        # Flip should not change original
        _ = img.flip_left_right()
        pixel_after_lr = img[0, 0]
        assert pixel_after_lr.r == orig_r
        assert pixel_after_lr.g == orig_g
        assert pixel_after_lr.b == orig_b
        assert pixel_after_lr.a == orig_a

        _ = img.flip_top_bottom()
        pixel_after_tb = img[0, 0]
        assert pixel_after_tb.r == orig_r
        assert pixel_after_tb.g == orig_g
        assert pixel_after_tb.b == orig_b
        assert pixel_after_tb.a == orig_a


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
