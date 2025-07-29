#!/usr/bin/env python3
"""Tests for Canvas Python bindings

These tests focus on verifying the Python bindings work correctly,
not testing the underlying drawing algorithms (which are tested in Zig).
"""

import pytest
import numpy as np
import zignal


class TestCanvasBinding:
    """Test core Canvas binding functionality"""

    def test_canvas_creation(self):
        """Test both ways to create a Canvas work"""
        img = zignal.Image.from_numpy(np.zeros((100, 100, 4), dtype=np.uint8))

        # Method 1: image.canvas()
        canvas1 = img.canvas()
        assert canvas1 is not None

        # Method 2: Canvas(image)
        canvas2 = zignal.Canvas(img)
        assert canvas2 is not None

    def test_canvas_properties(self):
        """Test Canvas properties are accessible"""
        img = zignal.Image.from_numpy(np.zeros((100, 200, 4), dtype=np.uint8))
        canvas = img.canvas()

        # Check properties return correct values
        assert canvas.rows == 100
        assert canvas.cols == 200
        assert canvas.image is img

    def test_canvas_methods_exist(self):
        """Test Canvas methods can be called"""
        img = zignal.Image.from_numpy(np.zeros((50, 50, 4), dtype=np.uint8))
        canvas = img.canvas()

        # Just verify methods can be called without errors
        canvas.fill((128, 128, 128))
        canvas.draw_line((0, 0), (10, 10), (255, 0, 0))

        # Verify the canvas modified the image
        result = img.to_numpy()
        assert np.any(result > 0)


class TestColorParsing:
    """Test Python-specific color handling"""

    def test_color_tuple_parsing(self):
        """Test RGB and RGBA tuples work"""
        img = zignal.Image.from_numpy(np.zeros((10, 10, 4), dtype=np.uint8))
        canvas = img.canvas()

        # RGB tuple
        canvas.fill((255, 0, 0))

        # RGBA tuple
        canvas.fill((0, 255, 0, 128))

        # Both should work without errors
        canvas.draw_line((0, 0), (5, 5), (0, 0, 255))
        canvas.draw_line((0, 0), (5, 5), (255, 255, 0, 200))

    def test_color_object_parsing(self):
        """Test all color object types are accepted"""
        img = zignal.Image.from_numpy(np.zeros((10, 10, 4), dtype=np.uint8))
        canvas = img.canvas()

        # Test a variety of color objects
        color_objects = [
            zignal.Rgb(255, 0, 0),
            zignal.Rgba(0, 255, 0, 128),
            zignal.Hsl(120, 100, 50),
            zignal.Hsv(240, 100, 100),
            zignal.Lab(50, 0, 0),
            zignal.Oklab(0.5, 0, 0),
            zignal.Xyz(50, 50, 50),
        ]

        # All should work without errors
        for color in color_objects:
            canvas.fill(color)

        # Also test with draw_line
        canvas.draw_line((0, 0), (5, 5), zignal.Rgb(255, 255, 255))

    def test_invalid_color_handling(self):
        """Test proper errors for invalid color inputs"""
        img = zignal.Image.from_numpy(np.zeros((10, 10, 4), dtype=np.uint8))
        canvas = img.canvas()

        # Invalid color inputs should raise exceptions
        with pytest.raises(Exception):
            canvas.fill((256, 0, 0))  # Out of range

        with pytest.raises(Exception):
            canvas.fill((255,))  # Too few components

        with pytest.raises(Exception):
            canvas.fill("red")  # Wrong type

        with pytest.raises(Exception):
            canvas.fill([255, 0, 0])  # List instead of tuple


class TestDrawLineBinding:
    """Test draw_line method binding specifics"""

    def test_draw_line_basic(self):
        """Test draw_line accepts required parameters"""
        img = zignal.Image.from_numpy(np.zeros((50, 50, 4), dtype=np.uint8))
        canvas = img.canvas()

        # Basic call with required parameters
        canvas.draw_line((10, 10), (40, 40), (255, 0, 0))

        # Verify it actually drew something
        result = img.to_numpy()
        assert np.any(result[:, :, 0] > 0)  # Some red pixels exist

    def test_draw_line_optional_params(self):
        """Test optional width and mode parameters"""
        img = zignal.Image.from_numpy(np.zeros((50, 50, 4), dtype=np.uint8))
        canvas = img.canvas()

        # Test width parameter
        canvas.draw_line((0, 10), (50, 10), (255, 0, 0), width=3)

        # Test mode parameter
        canvas.draw_line((0, 20), (50, 20), (0, 255, 0), mode=zignal.DrawMode.SOFT)

        # Test both
        canvas.draw_line((0, 30), (50, 30), (0, 0, 255), width=5, mode=zignal.DrawMode.FAST)

        # All should work without errors
        result = img.to_numpy()
        assert np.any(result > 0)

    def test_point_tuple_parsing(self):
        """Test point tuples are properly parsed"""
        img = zignal.Image.from_numpy(np.zeros((100, 100, 4), dtype=np.uint8))
        canvas = img.canvas()

        # Integer coordinates
        canvas.draw_line((0, 0), (50, 50), (255, 0, 0))

        # Float coordinates
        canvas.draw_line((10.5, 20.5), (80.5, 90.5), (0, 255, 0))

        # Mixed types
        canvas.draw_line((10, 10.5), (90.5, 90), (0, 0, 255))

        # All should work
        result = img.to_numpy()
        assert np.any(result > 0)


class TestErrorHandling:
    """Test Python-specific error conditions"""

    def test_canvas_invalid_image(self):
        """Test Canvas constructor with invalid image"""
        with pytest.raises(Exception):
            zignal.Canvas(None)

        with pytest.raises(Exception):
            zignal.Canvas("not an image")

    def test_draw_line_invalid_points(self):
        """Test draw_line with invalid point inputs"""
        img = zignal.Image.from_numpy(np.zeros((50, 50, 4), dtype=np.uint8))
        canvas = img.canvas()

        # Invalid point formats
        with pytest.raises(Exception):
            canvas.draw_line((0,), (10, 10), (255, 0, 0))  # Too few coords

        with pytest.raises(Exception):
            canvas.draw_line([0, 0], (10, 10), (255, 0, 0))  # List not tuple

        with pytest.raises(Exception):
            canvas.draw_line("0,0", (10, 10), (255, 0, 0))  # String


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
