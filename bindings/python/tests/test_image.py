from pathlib import Path

import numpy as np
import pytest

import zignal


class TestImage:
    def test_from_numpy_and_props(self):
        arr = np.zeros((3, 4, 4), dtype=np.uint8)
        img = zignal.Image.from_numpy(arr)
        assert (img.rows, img.cols) == (3, 4)
        assert img.is_contiguous() is True

    def test_slice_assignment_converts_between_color_spaces(self):
        rgb = zignal.Image(2, 2, dtype=zignal.Rgb)
        rgb_np = rgb.to_numpy()
        pattern = np.array(
            [
                [[10, 10, 10], [20, 20, 20]],
                [[30, 30, 30], [40, 40, 40]],
            ],
            dtype=np.uint8,
        )
        rgb_np[:] = pattern

        gray = zignal.Image(2, 2, dtype=zignal.Gray)
        gray_np = gray.to_numpy()
        gray_np.fill(0)

        rgba = zignal.Image(2, 2, dtype=zignal.Rgba)
        rgba_np = rgba.to_numpy()
        rgba_np.fill(0)

        gray[:] = rgb
        rgba[:] = rgb

        expected_gray = np.empty((2, 2), dtype=np.uint8)
        for r in range(2):
            for c in range(2):
                rgb_pixel = zignal.Rgb(*map(int, pattern[r, c]))
                expected_gray[r, c] = rgb_pixel.to(zignal.Gray).y

        converted_gray = gray.to_numpy()[..., 0]
        assert np.array_equal(converted_gray, expected_gray)

        converted_rgba = rgba.to_numpy()
        assert np.array_equal(converted_rgba[..., :3], pattern)
        assert np.array_equal(converted_rgba[..., 3], np.full((2, 2), 255, dtype=np.uint8))

    def test_slice_assignment_handles_strided_views(self):
        base_rgb = zignal.Image(4, 4, dtype=zignal.Rgb)
        base_gray = zignal.Image(4, 4, dtype=zignal.Gray)

        rgb_np = base_rgb.to_numpy()
        gray_np = base_gray.to_numpy()
        gray_np.fill(0)

        left_values = np.arange(8, dtype=np.uint8).reshape(4, 2)
        rgb_np[:, :2] = np.repeat(left_values[..., None], 3, axis=2)

        src_view = base_rgb.view((0, 0, 2, 4))
        dst_view = base_gray.view((0, 0, 2, 4))
        dst_view[:] = src_view

        expected_left = np.empty_like(left_values)
        for r in range(left_values.shape[0]):
            for c in range(left_values.shape[1]):
                value = int(left_values[r, c])
                expected_left[r, c] = zignal.Rgb(value, value, value).to(zignal.Gray).y

        gray_after = base_gray.to_numpy()[..., 0]
        assert np.array_equal(gray_after[:, :2], expected_left)
        assert np.array_equal(gray_after[:, 2:], np.zeros((4, 2), dtype=np.uint8))

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
        assert (img[0, 0].item().r, img[0, 0].item().g, img[0, 0].item().b) == (10, 99, 30)

    def test_view_and_memory_sharing(self):
        img = zignal.Image(4, 4, (0, 0, 0, 0), dtype=zignal.Rgba)
        v = img.view(zignal.Rectangle(1, 1, 3, 3))
        assert (v.rows, v.cols) == (2, 2)
        v.fill((5, 6, 7, 255))
        arr = img.to_numpy()
        assert (arr[1, 1] == np.array([5, 6, 7, 255], dtype=np.uint8)).all()

    def test_view_with_tuple(self):
        img = zignal.Image(4, 4, (0, 0, 0, 0), dtype=zignal.Rgba)
        # Create view using tuple (left, top, right, bottom)
        v = img.view((1, 1, 3, 3))
        assert (v.rows, v.cols) == (2, 2)

    def test_set_border(self):
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

    def test_get_rectangle(self):
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

    def test_ssim_matches_zig(self):
        img = zignal.Image(16, 16, (10, 20, 30), dtype=zignal.Rgb)
        noisy = img.copy()
        noisy_arr = noisy.to_numpy()
        noisy_arr[0, 0] = [12, 22, 32]
        value = img.ssim(noisy)
        assert 0.0 <= value <= 1.0
        identical = img.copy()
        assert img.ssim(identical) == pytest.approx(1.0)

    def test_ssim_requires_minimum_size(self):
        small = zignal.Image(8, 8, dtype=zignal.Gray)
        with pytest.raises(ValueError):
            small.ssim(small.copy())

    def test_psnr_and_mean_pixel_error(self):
        ref = zignal.Image(4, 4, (10, 20, 30), dtype=zignal.Rgb)
        distorted = ref.copy()
        arr = distorted.to_numpy()
        arr[0, 0] = [12, 24, 36]

        psnr_value = ref.psnr(distorted)
        assert psnr_value > 30.0

        mpe = ref.mean_pixel_error(distorted)
        assert mpe > 0.0
        assert ref.mean_pixel_error(ref.copy()) == pytest.approx(0.0)

    def test_filtering_methods(self):
        img = zignal.Image(5, 5, (0, 0, 0, 255), dtype=zignal.Rgba)
        out = img.box_blur(1)
        assert (out.rows, out.cols) == (5, 5)
        with pytest.raises(ValueError):
            img.gaussian_blur(0.0)

        median = img.median_blur(1)
        assert isinstance(median, zignal.Image)

        percentile = img.percentile_blur(1, 1.0)
        assert isinstance(percentile, zignal.Image)

        wrapped = img.percentile_blur(1, 0.0, border=zignal.BorderMode.WRAP)
        assert isinstance(wrapped, zignal.Image)

        with pytest.raises(ValueError):
            img.percentile_blur(1, 1.5)

        min_filter = img.min_blur(1)
        max_filter = img.max_blur(1)
        midpoint = img.midpoint_blur(1)
        trimmed = img.alpha_trimmed_mean_blur(1, 0.1)

        for result in (min_filter, max_filter, midpoint, trimmed):
            assert isinstance(result, zignal.Image)

        with pytest.raises(ValueError):
            img.alpha_trimmed_mean_blur(1, 0.6)

    def test_threshold_otsu_and_rgb_autoconvert(self):
        img = zignal.Image(4, 4, dtype=zignal.Gray)
        arr = img.to_numpy()
        arr[:2, :] = 20
        arr[2:, :] = 200

        binary, threshold = img.threshold_otsu()
        assert isinstance(binary, zignal.Image)
        assert 0 <= threshold <= 255
        binary_arr = binary.to_numpy()
        assert set(np.unique(binary_arr)) <= {0, 255}

        rgb = zignal.Image(4, 4, dtype=zignal.Rgb)
        rgb_arr = rgb.to_numpy()
        rgb_arr[:, :2] = [30, 30, 30]
        rgb_arr[:, 2:] = [220, 220, 220]
        rgb_binary, _ = rgb.threshold_otsu()
        assert set(np.unique(rgb_binary.to_numpy())) <= {0, 255}

    def test_adaptive_threshold_and_morphology(self):
        base = zignal.Image(10, 10, dtype=zignal.Gray)
        arr = base.to_numpy()
        arr[:] = np.linspace(10, 200, arr.size, dtype=np.uint8).reshape(arr.shape)

        adaptive = base.threshold_adaptive_mean(radius=2, c=3.0)
        adaptive_arr = adaptive.to_numpy()
        assert set(np.unique(adaptive_arr)) <= {0, 255}

        dilated = adaptive.dilate_binary(kernel_size=5, iterations=2)
        eroded = adaptive.erode_binary()
        opened = adaptive.open_binary()
        closed = adaptive.close_binary(iterations=2)

        for result in (dilated, eroded, opened, closed):
            assert isinstance(result, zignal.Image)
            data = result.to_numpy()
            assert data.shape == arr.shape
            assert set(np.unique(data)) <= {0, 255}

        with pytest.raises(ValueError):
            adaptive.dilate_binary(kernel_size=2)

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
        gray_base = zignal.Image(5, 5, 128, dtype=zignal.Gray)
        overlay = zignal.Image(5, 5, (255, 0, 0, 128), dtype=zignal.Rgba)
        gray_base.blend(overlay)
        gray_pixel = gray_base[2, 2]
        # Gray value should have changed from pure 128
        assert gray_pixel != 128
        # Should still be grayscale (single value)
        assert isinstance(gray_pixel, int)

    def test_pixel_proxy_methods(self):
        # Create RGB image
        img = zignal.Image(10, 10, (255, 0, 0), dtype=zignal.Rgb)
        pixel = img[0, 0]
        assert isinstance(pixel.item(), zignal.Rgb)

        # Test to_gray via class-based API
        gray = pixel.to(zignal.Gray)
        assert gray.y >= 0 and gray.y <= 255

        # Test color conversion
        hsl = pixel.to(zignal.Hsl)
        assert isinstance(hsl, zignal.Hsl)

        lab = pixel.to(zignal.Lab)
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
        img = zignal.Image(10, 10, (255, 0, 0, 200), dtype=zignal.Rgba)
        pixel = img[0, 0]
        assert isinstance(pixel.item(), zignal.Rgba)

        # Component access
        assert pixel.r == 255
        assert pixel.a == 200

        # Methods
        gray = pixel.to(zignal.Gray)
        assert isinstance(gray, zignal.Gray)

        hsl = pixel.to(zignal.Hsl)
        assert isinstance(hsl, zignal.Hsl)

        # to_rgb conversion via class-based API
        rgb = pixel.to(zignal.Rgb)
        assert isinstance(rgb, zignal.Rgb)
        assert rgb.r == 255

    def test_warp(self):
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
        gray = img.convert(zignal.Gray)
        warped = gray.warp(sim)
        assert warped is not None

    def test_invert(self):
        # Test grayscale
        gray = zignal.Image(2, 2, 100, dtype=zignal.Gray)
        inverted = gray.invert()
        assert inverted[0, 0] == 155  # 255 - 100

        # Test RGB
        rgb = zignal.Image(1, 1, (0, 128, 255), dtype=zignal.Rgb)
        inverted = rgb.invert()
        inv = inverted[0, 0].item()
        assert (inv.r, inv.g, inv.b) == (255, 127, 0)

        # Test RGBA (alpha should be preserved)
        rgba = zignal.Image(1, 1, (0, 128, 255, 64), dtype=zignal.Rgba)
        inverted = rgba.invert()
        inv = inverted[0, 0].item()
        assert (inv.r, inv.g, inv.b, inv.a) == (255, 127, 0, 64)

    def test_motion_blur(self):
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

    def test_shen_castan(self):
        # Create test image with some structure
        img = zignal.Image(20, 20, (128, 128, 128), dtype=zignal.Rgb)

        # Test with default parameters
        edges = img.shen_castan()
        assert edges.rows == 20 and edges.cols == 20
        # Result should be grayscale
        assert edges.dtype == zignal.Gray

        # Test with custom parameters - equivalent to old presets
        # Low noise preset equivalent
        edges = img.shen_castan(smooth=0.95, high_ratio=0.98)
        assert edges.rows == 20 and edges.cols == 20

        # High noise preset equivalent
        edges = img.shen_castan(smooth=0.7, window_size=11)
        assert edges.rows == 20 and edges.cols == 20

        # Heavy smooth preset equivalent (for very noisy images)
        edges = img.shen_castan(smooth=0.5, window_size=9, high_ratio=0.95)
        assert edges.rows == 20 and edges.cols == 20

        # Sensitive preset equivalent
        edges = img.shen_castan(high_ratio=0.97, low_rel=0.4)
        assert edges.rows == 20 and edges.cols == 20

        # NMS thinning
        edges = img.shen_castan(use_nms=True)
        assert edges.rows == 20 and edges.cols == 20

        # No hysteresis (strong edges only)
        edges = img.shen_castan(hysteresis=False)
        assert edges.rows == 20 and edges.cols == 20

        # Test parameter validation
        with pytest.raises(ValueError):
            img.shen_castan(smooth=1.5)  # Must be in (0, 1)

        with pytest.raises(ValueError):
            img.shen_castan(window_size=4)  # Must be odd

        with pytest.raises(ValueError):
            img.shen_castan(high_ratio=0.0)  # Must be in (0, 1)

    def test_autocontrast(self):
        # Gray
        gray = zignal.Image(5, 5, 128, dtype=zignal.Gray)
        enhanced = gray.autocontrast()
        assert enhanced.rows == 5 and enhanced.cols == 5

        # RGB
        rgb = zignal.Image(5, 5, (100, 150, 200), dtype=zignal.Rgb)
        enhanced_rgb = rgb.autocontrast(cutoff=0.02)
        assert enhanced_rgb.rows == 5 and enhanced_rgb.cols == 5

        # RGBA
        rgba = zignal.Image(5, 5, (100, 150, 200, 255), dtype=zignal.Rgba)
        enhanced_rgba = rgba.autocontrast()
        assert enhanced_rgba.rows == 5 and enhanced_rgba.cols == 5

    def test_equalize(self):
        # Gray
        gray = zignal.Image(5, 5, 128, dtype=zignal.Gray)
        equalized = gray.equalize()
        assert equalized.rows == 5 and equalized.cols == 5

        # RGB
        rgb = zignal.Image(5, 5, (100, 150, 200), dtype=zignal.Rgb)
        equalized_rgb = rgb.equalize()
        assert equalized_rgb.rows == 5 and equalized_rgb.cols == 5

        # RGBA
        rgba = zignal.Image(5, 5, (100, 150, 200, 255), dtype=zignal.Rgba)
        equalized_rgba = rgba.equalize()
        assert equalized_rgba.rows == 5 and equalized_rgba.cols == 5

    def test_canny(self):
        # Create simple test image
        img = zignal.Image(20, 20, dtype=zignal.Gray)

        # Test with defaults
        edges = img.canny()
        assert edges.rows == 20 and edges.cols == 20
        assert edges.dtype == zignal.Gray

        # Test with custom parameters
        edges = img.canny(sigma=1.0, low=30, high=90)
        assert edges.rows == 20 and edges.cols == 20

        # Test with sigma=0 (no blur)
        edges = img.canny(sigma=0)
        assert edges.rows == 20 and edges.cols == 20

        # Test parameter validation
        with pytest.raises(ValueError):
            img.canny(sigma=-1)

    def test_canny_rejects_non_finite(self):
        img = zignal.Image(20, 20, dtype=zignal.Gray)

        # Test NaN
        with pytest.raises(ValueError):
            img.canny(sigma=float("nan"))
        with pytest.raises(ValueError):
            img.canny(low=float("nan"))
        with pytest.raises(ValueError):
            img.canny(high=float("nan"))

        # Test infinity
        with pytest.raises(ValueError):
            img.canny(sigma=float("inf"))
        with pytest.raises(ValueError):
            img.canny(low=float("inf"))
        with pytest.raises(ValueError):
            img.canny(high=float("inf"))

        # Test negative infinity
        with pytest.raises(ValueError):
            img.canny(sigma=float("-inf"))
        with pytest.raises(ValueError):
            img.canny(low=float("-inf"))
        with pytest.raises(ValueError):
            img.canny(high=float("-inf"))

    def test_image_copy_from_conversion(self):
        # Create source images
        src_gray = zignal.Image(10, 10, 128, dtype=zignal.Gray)
        src_rgb = zignal.Image(10, 10, (10, 20, 30), dtype=zignal.Rgb)
        src_rgba = zignal.Image(10, 10, (40, 50, 60, 128), dtype=zignal.Rgba)

        # Test conversions to RGB
        dst_rgb = zignal.Image(10, 10, dtype=zignal.Rgb)
        dst_rgb[:] = src_gray
        rgb_item = dst_rgb[0, 0].item()
        assert (rgb_item.r, rgb_item.g, rgb_item.b) == (128, 128, 128)

        dst_rgb[:] = src_rgba
        rgb_item = dst_rgb[0, 0].item()
        assert (rgb_item.r, rgb_item.g, rgb_item.b) == (40, 50, 60)

        # Test conversions to RGBA
        dst_rgba = zignal.Image(10, 10, dtype=zignal.Rgba)
        dst_rgba[:] = src_gray
        assert dst_rgba[0, 0].item() == zignal.Rgba(128, 128, 128, 255)

        dst_rgba[:] = src_rgb
        assert dst_rgba[0, 0].item() == zignal.Rgba(10, 20, 30, 255)

        # Test conversions to Gray
        dst_gray = zignal.Image(10, 10, dtype=zignal.Gray)
        dst_gray[:] = src_rgb  # luma of (10, 20, 30)
        expected_rgb_gray = zignal.Rgb(10, 20, 30).to(zignal.Gray)
        assert dst_gray[0, 0] == expected_rgb_gray.y

        dst_gray[:] = src_rgba  # luma of (40, 50, 60) with alpha ignored
        expected_rgba_gray = zignal.Rgb(40, 50, 60).to(zignal.Gray)
        assert dst_gray[0, 0] == expected_rgba_gray.y

        # Test with a strided view as destination
        dst_view_img = zignal.Image(20, 20, dtype=zignal.Rgb)
        dst_view = dst_view_img.view(zignal.Rectangle(5, 5, 15, 15))
        assert not dst_view.is_contiguous()

        dst_view[:] = src_rgba
        # Check a pixel in the view
        view_item = dst_view[0, 0].item()
        assert (view_item.r, view_item.g, view_item.b) == (40, 50, 60)
        # Check the corresponding pixel in the original image
        img_item = dst_view_img[5, 5].item()
        assert (img_item.r, img_item.g, img_item.b) == (40, 50, 60)
        # Check a pixel outside the view to make sure it's untouched
        outside_item = dst_view_img[0, 0].item()
        assert (outside_item.r, outside_item.g, outside_item.b) == (0, 0, 0)
