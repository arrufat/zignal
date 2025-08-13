#!/usr/bin/env python3
"""Tests for Canvas Python bindings

These tests focus on verifying the Python bindings work correctly,
not testing the underlying drawing algorithms (which are tested in Zig).
"""

import pytest

import zignal


class TestCanvasBinding:
    """Test core Canvas binding functionality"""

    def test_canvas_creation(self):
        """Test both ways to create a Canvas work"""
        image = zignal.Image(100, 100, 0)
        canvas1 = image.canvas()
        assert canvas1 is not None
        canvas2 = zignal.Canvas(image)
        assert canvas2 is not None

    def test_canvas_properties(self):
        """Test Canvas properties are accessible"""
        image = zignal.Image(100, 200, 0)
        canvas = image.canvas()

        # Check properties return correct values
        assert canvas.rows == 100
        assert canvas.cols == 200
        assert canvas.image is image

    def test_canvas_methods_exist(self):
        """Test all Canvas methods can be called"""
        image = zignal.Image(100, 100, 0)
        original = image.copy()
        canvas = image.canvas()

        # Basic methods
        canvas.fill((128, 128, 128))
        canvas.draw_line((0, 0), (10, 10), (255, 0, 0))

        # Rectangle methods
        rect = zignal.Rectangle(10, 10, 30, 30)
        canvas.draw_rectangle(rect, (255, 0, 0))
        canvas.fill_rectangle(rect, (0, 255, 0))

        # Polygon methods
        points = [(10, 10), (20, 10), (15, 20)]
        canvas.draw_polygon(points, (0, 0, 255))
        canvas.fill_polygon(points, (255, 255, 0))

        # Circle methods
        canvas.draw_circle((50, 50), 20, (255, 0, 255))
        canvas.fill_circle((60, 60), 15, (0, 255, 255))

        # Bezier methods
        canvas.draw_quadratic_bezier((0, 0), (50, 0), (50, 50), (255, 128, 0))
        canvas.draw_cubic_bezier((0, 0), (25, 0), (25, 50), (50, 50), (128, 255, 0))

        # Spline methods
        canvas.draw_spline_polygon(points, (128, 0, 255))
        canvas.fill_spline_polygon(points, (255, 0, 128))

        # Verify the canvas modified the image
        assert not image == original


class TestColorParsing:
    """Test Python-specific color handling"""

    def test_color_tuple_parsing(self):
        """Test RGB and RGBA tuples work"""
        img = zignal.Image(10, 10, 0)
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
        canvas = zignal.Image(10, 10, 0).canvas()

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
            assert canvas.image[0, 0] == color

        # Also test with draw_line
        canvas.draw_line((0, 0), (5, 5), zignal.Rgb(255, 255, 255))

    def test_invalid_color_handling(self):
        """Test proper errors for invalid color inputs"""
        canvas = zignal.Image(10, 10, 0).canvas()

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
        canvas = zignal.Image(50, 50, 0).canvas()

        canvas.draw_line((10, 10), (40, 40), (255, 0, 0))

        # Verify it actually drew something
        for i in range(10, 40):
            assert canvas.image[i, i] == (255, 0, 0)

    def test_draw_line_optional_params(self):
        """Test optional width and mode parameters"""
        canvas = zignal.Image(50, 50, 0).canvas()

        # Test width parameter
        canvas.draw_line((0, 10), (50, 10), (255, 0, 0), width=3)

        # Test mode parameter
        canvas.draw_line((0, 20), (50, 20), (0, 255, 0), mode=zignal.DrawMode.SOFT)

        # Test both
        canvas.draw_line((0, 30), (50, 30), (0, 0, 255), width=5, mode=zignal.DrawMode.FAST)

        # All should work without errors
        black = zignal.Rgb(0, 0, 0)
        assert canvas.image[10, 0] != black
        assert canvas.image[20, 0] != black
        assert canvas.image[30, 0] != black

    def test_point_tuple_parsing(self):
        """Test point tuples are properly parsed"""
        canvas = zignal.Image(100, 100, 0).canvas()

        # Integer coordinates
        canvas.draw_line((0, 0), (50, 50), (255, 0, 0))

        # Float coordinates
        canvas.draw_line((10.5, 20.5), (80.5, 90.5), (0, 255, 0))

        # Mixed types
        canvas.draw_line((10, 10.5), (90.5, 90), (0, 0, 255))
        canvas.image.save("mixed.png")

        # All should work
        black = zignal.Rgb(0, 0, 0)
        assert canvas.image[0, 0] != black
        assert canvas.image[20, 10] != black
        assert canvas.image[10, 10] != black


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
        canvas = zignal.Image(50, 50, 0).canvas()

        # Invalid point formats
        with pytest.raises(Exception):
            canvas.draw_line((0,), (10, 10), (255, 0, 0))

        with pytest.raises(Exception):
            canvas.draw_line([0, 0], (10, 10), (255, 0, 0))  # List not tuple

        with pytest.raises(Exception):
            canvas.draw_line("0,0", (10, 10), (255, 0, 0))  # String


class TestShapeDrawing:
    """Test shape drawing and filling methods"""

    def test_drawing_methods(self):
        """Test all drawing methods accept correct parameters"""
        canvas = zignal.Image(100, 100, 0).canvas()

        # Rectangle with optional params
        rect = zignal.Rectangle(5, 5, 25, 25)
        canvas.draw_rectangle(rect, (255, 0, 0), width=2, mode=zignal.DrawMode.SOFT)

        # Polygon with different sizes
        triangle = [(10, 10), (30, 10), (20, 30)]
        canvas.draw_polygon(triangle, (0, 255, 0), width=3)

        pentagon = [(50, 10), (70, 20), (65, 40), (35, 40), (30, 20)]
        canvas.draw_polygon(pentagon, (0, 0, 255))

        # Circle with different parameters
        canvas.draw_circle((70, 70), 15.5, (255, 255, 0), width=2)

    def test_fill_methods(self):
        """Test all fill methods accept correct parameters"""
        canvas = zignal.Image(100, 100, 0).canvas()

        # Fill methods with mode parameter
        rect = zignal.Rectangle(10, 10, 40, 40)
        canvas.fill_rectangle(rect, (255, 0, 0), mode=zignal.DrawMode.SOFT)

        hexagon = [(60, 20), (80, 20), (90, 40), (80, 60), (60, 60), (50, 40)]
        canvas.fill_polygon(hexagon, (0, 255, 0))

        canvas.fill_circle((25, 75), 20, (0, 0, 255), mode=zignal.DrawMode.FAST)


class TestRectangleParameter:
    """Test Rectangle integration with Canvas"""

    def test_rectangle_usage(self):
        """Test Rectangle objects work correctly with canvas methods"""
        canvas = zignal.Image(50, 50, 0).canvas()

        # Create rectangles in different ways
        rect1 = zignal.Rectangle(5, 5, 20, 20)
        rect2 = zignal.Rectangle.init_center(35, 35, 20, 20)

        # Use with canvas methods
        canvas.draw_rectangle(rect1, (255, 0, 0))
        canvas.fill_rectangle(rect2, (0, 255, 0))

        # Verify image was modified
        assert canvas.image[5, 5] == zignal.Rgb(255, 0, 0)
        assert canvas.image[25, 25] == zignal.Rgb(0, 255, 0)


class TestBezierAndSpline:
    """Test bezier and spline curve methods"""

    def test_curve_methods(self):
        """Test bezier and spline methods with correct number of points"""
        canvas = zignal.Image(100, 100, 0).canvas()

        # Quadratic bezier needs 3 points
        canvas.draw_quadratic_bezier((10, 10), (50, 5), (90, 10), (255, 0, 0))

        # Cubic bezier needs 4 points
        canvas.draw_cubic_bezier((10, 30), (30, 20), (70, 20), (90, 30), (0, 255, 0))

        # Spline with tension parameter
        points = [(10, 50), (30, 70), (50, 50), (70, 70), (90, 50)]
        canvas.draw_spline_polygon(points, (0, 0, 255), tension=0.3)
        canvas.fill_spline_polygon(points, (255, 255, 0), tension=0.7)


class TestDrawText:
    """Test text drawing with BitmapFont"""

    def test_draw_text_basic(self):
        """Test basic text drawing"""
        canvas = zignal.Image(100, 200, 0).canvas()
        font = zignal.BitmapFont.font8x8()

        # Draw simple text
        canvas.draw_text("Hello World", (10, 10), (255, 255, 255), font)

        # Draw with scale
        canvas.draw_text("Big", (10, 30), (255, 0, 0), font, scale=2.0)

        # Draw with antialiasing
        canvas.draw_text("Smooth", (10, 60), (0, 255, 0), font, mode=zignal.DrawMode.SOFT)


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
