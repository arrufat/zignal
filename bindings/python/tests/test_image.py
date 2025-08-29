"""Bindings-level smoke tests for Image API.

Focus on wiring and Python surface; algorithms are tested in Zig.
"""

import pytest
import numpy as np
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
        result = base.blend(overlay, zignal.BlendMode.NORMAL)
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
