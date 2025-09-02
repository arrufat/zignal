"""Bindings-level smoke tests for Image API."""

import numpy as np
import pytest

import zignal


class TestImageSmoke:
    def test_from_numpy_and_props(self):
        arr = np.zeros((3, 4, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)
        assert (img.rows, img.cols) == (3, 4)
        assert img.is_contiguous() is True

    def test_equality_and_copy(self):
        img1 = zignal.Image(3, 4, (1, 2, 3, 255), dtype=zignal.Rgba)
        img2 = img1.copy()
        assert img1 == img2
        # Mutate copy → no longer equal
        a = img2.to_numpy()
        a[0, 0] = [9, 9, 9, 255]
        assert img1 != img2

    def test_indexing_and_pixel_proxy(self):
        img = zignal.Image(2, 2, (10, 20, 30), dtype=zignal.Rgb)
        px = img[0, 0]
        assert (px.r, px.g, px.b) == (10, 20, 30)
        px.g = 99
        assert img[0, 0].g == 99
        # Equality against tuple and color objects
        assert img[0, 0] == (10, 99, 30)
        assert img[0, 0] == zignal.Rgb(10, 99, 30)

    def test_view_and_memory_sharing(self):
        img = zignal.Image(4, 4, (0, 0, 0, 0), dtype=zignal.Rgba)
        v = img.view(zignal.Rectangle(1, 1, 3, 3))
        assert (v.rows, v.cols) == (2, 2)
        v.fill((5, 6, 7, 255))
        arr = img.to_numpy()
        assert (arr[1, 1] == np.array([5, 6, 7, 255], dtype=np.uint8)).all()

    def test_view_with_tuple(self):
        """Test that view() accepts tuple input"""
        img = zignal.Image(4, 4, (0, 0, 0, 0), dtype=zignal.Rgba)
        # Create view using tuple (left, top, right, bottom)
        v = img.view((1, 1, 3, 3))
        assert (v.rows, v.cols) == (2, 2)

    def test_set_border_smoke(self):
        img = zignal.Image(4, 4, (10, 20, 30), dtype=zignal.Rgb)
        rect = zignal.Rectangle(1, 1, 3, 3)

        # Zero border
        img.set_border(rect)
        arr = img.to_numpy()
        # Corners should be zero
        assert (arr[0, 0] == np.array([0, 0, 0], dtype=np.uint8)).all()
        assert (arr[0, 3] == np.array([0, 0, 0], dtype=np.uint8)).all()
        assert (arr[3, 0] == np.array([0, 0, 0], dtype=np.uint8)).all()
        assert (arr[3, 3] == np.array([0, 0, 0], dtype=np.uint8)).all()
        # Interior remains original color
        assert (arr[1, 1] == np.array([10, 20, 30], dtype=np.uint8)).all()

        # Red border
        img.fill((10, 20, 30))
        img.set_border(rect, (255, 0, 0))
        arr = img.to_numpy()
        assert (arr[0, 0] == np.array([255, 0, 0], dtype=np.uint8)).all()
        assert (arr[1, 1] == np.array([10, 20, 30], dtype=np.uint8)).all()

    def test_set_border_no_overlap_fills_entire_image(self):
        img = zignal.Image(3, 3, (7, 8, 9), dtype=zignal.Rgb)
        # Rectangle completely outside -> whole image becomes zeros
        img.set_border(zignal.Rectangle(10, 10, 20, 20))
        arr_after = img.to_numpy()
        assert (arr_after == np.zeros((3, 3, 3), dtype=np.uint8)).all()

    def test_set_border_requires_rect(self):
        img = zignal.Image(3, 3, (1, 2, 3), dtype=zignal.Rgb)
        with pytest.raises(TypeError):
            img.set_border(None)

    def test_get_rectangle_smoke(self):
        img = zignal.Image(5, 7)
        rect = img.get_rectangle()
        assert isinstance(rect, zignal.Rectangle)
        # Rectangle stores floats; compare as ints
        assert int(rect.left) == 0
        assert int(rect.top) == 0
        assert int(rect.right) == 7
        assert int(rect.bottom) == 5

    def test_numpy_roundtrip_and_validation(self):
        # Round‑trip
        img = zignal.Image(2, 3, (1, 2, 3), dtype=zignal.Rgb)
        arr = img.to_numpy()
        img2 = zignal.Image.from_numpy(arr)
        assert img == img2
        # Minimal invalids
        with pytest.raises(TypeError):
            zignal.Image.from_numpy(np.zeros((2, 3, 3), dtype=np.float32))
        with pytest.raises(ValueError):
            zignal.Image.from_numpy(np.zeros((2, 3), dtype=np.uint8))
        with pytest.raises(ValueError):
            zignal.Image.from_numpy(np.zeros((2, 3, 2), dtype=np.uint8))

    def test_method_smoke(self):
        img = zignal.Image(5, 5, (0, 0, 0, 255), dtype=zignal.Rgba)
        out = img.box_blur(1)
        assert (out.rows, out.cols) == (5, 5)
        with pytest.raises(ValueError):
            img.gaussian_blur(0.0)

    def test_blend_api(self):
        # Test RGBA base blending
        base = zignal.Image(5, 5, (255, 0, 0), dtype=zignal.Rgba)
        overlay = zignal.Image(5, 5, (0, 0, 255, 128), dtype=zignal.Rgba)
        # Blend modifies in place and returns None
        result = base.blend(overlay, zignal.Blending.NORMAL)
        assert result is None
        # Basic check that blending occurred
        pixel = base[2, 2]
        assert pixel.r < 255  # Red reduced
        assert pixel.b > 0  # Blue added

        # Test grayscale base blending
        gray_base = zignal.Image(5, 5, 128, dtype=zignal.Grayscale)
        overlay = zignal.Image(5, 5, (255, 0, 0, 128), dtype=zignal.Rgba)
        gray_base.blend(overlay)
        gray_pixel = gray_base[2, 2]
        # Grayscale value should have changed from pure 128
        assert gray_pixel != 128
        # Should still be grayscale (single value)
        assert isinstance(gray_pixel, int)

    def test_pixel_proxy_methods(self):
        """Test that pixel proxy objects have color methods"""
        # Create RGB image
        img = zignal.Image(10, 10, (255, 0, 0), dtype=zignal.Rgb)
        pixel = img[0, 0]
        assert isinstance(pixel.item(), zignal.Rgb)

        # Test to_gray
        gray = pixel.to_gray()
        assert isinstance(gray, int)
        assert 0 <= gray <= 255

        # Test color conversion
        hsl = pixel.to_hsl()
        assert isinstance(hsl, zignal.Hsl)

        lab = pixel.to_lab()
        assert isinstance(lab, zignal.Lab)

        # Test blend - modifies pixel in place and returns new color
        blended = pixel.blend((0, 255, 0, 128))
        assert isinstance(blended, zignal.Rgb)
        # Pixel should be modified in the image
        assert img[0, 0].g > 0  # Green component added

        # Test format
        repr_str = repr(pixel)
        assert "Rgb" in repr_str

        sgr_str = format(pixel, "sgr")
        assert "\x1b[" in sgr_str  # ANSI escape sequence

    def test_rgba_pixel_proxy_methods(self):
        """Test RGBA pixel proxy has all methods"""
        img = zignal.Image(10, 10, (255, 0, 0, 200), dtype=zignal.Rgba)
        pixel = img[0, 0]
        assert isinstance(pixel.item(), zignal.Rgba)

        # Component access
        assert pixel.r == 255
        assert pixel.a == 200

        # Methods
        gray = pixel.to_gray()
        assert isinstance(gray, int)

        hsl = pixel.to_hsl()
        assert isinstance(hsl, zignal.Hsl)

        # to_rgb conversion
        rgb = pixel.to_rgb()
        assert isinstance(rgb, zignal.Rgb)
        assert rgb.r == 255

    def test_warp_smoke(self):
        """Test image warp API exists and is callable."""
        img = zignal.Image(10, 10)

        # Can warp with similarity
        sim = zignal.SimilarityTransform([(2, 2), (8, 2)], [(3, 3), (7, 3)])
        warped = img.warp(sim)
        assert warped is not None

        # Can warp with affine
        aff = zignal.AffineTransform([(2, 2), (8, 2), (5, 8)], [(3, 3), (7, 3), (5, 7)])
        warped = img.warp(aff)
        assert warped is not None

        # Can warp with projective
        proj = zignal.ProjectiveTransform(
            [(1, 1), (9, 1), (9, 9), (1, 9)], [(2, 2), (8, 1), (9, 8), (1, 9)]
        )
        warped = img.warp(proj)
        assert warped is not None

        # Can warp with options
        warped = img.warp(sim, shape=(20, 20))
        assert warped is not None

        warped = img.warp(sim, method=zignal.Interpolation.NEAREST_NEIGHBOR)
        assert warped is not None

        # Works with different image types
        gray = img.convert(zignal.Grayscale)
        warped = gray.warp(sim)
        assert warped is not None

    def test_motion_blur_smoke(self):
        """Test motion blur API basics"""
        # Create test image
        img = zignal.Image(10, 10, (255, 0, 0), dtype=zignal.Rgb)

        # Test linear motion blur
        linear_config = zignal.MotionBlur.linear(angle=0.0, distance=3)
        blurred = img.motion_blur(linear_config)
        assert blurred.rows == 10 and blurred.cols == 10

        # Test radial zoom blur with defaults
        zoom_config = zignal.MotionBlur.radial_zoom()
        blurred = img.motion_blur(zoom_config)
        assert blurred.rows == 10 and blurred.cols == 10

        # Test radial spin blur with custom center
        spin_config = zignal.MotionBlur.radial_spin(center=(0.3, 0.7), strength=0.8)
        blurred = img.motion_blur(spin_config)
        assert blurred.rows == 10 and blurred.cols == 10
