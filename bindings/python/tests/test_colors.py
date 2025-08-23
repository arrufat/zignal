"""Test suite for zignal color type bindings.

These tests focus on verifying the Python bindings work correctly,
not testing color conversion accuracy (which is tested in Zig).
"""

import pytest
import zignal


class TestColorAvailability:
    """Test that all color types are available and properly exposed."""

    def test_all_color_types_available(self):
        """Test that all 12 color types are available."""
        expected_types = [
            "Rgb",
            "Rgba",
            "Hsv",
            "Hsl",
            "Lab",
            "Xyz",
            "Oklab",
            "Oklch",
            "Lch",
            "Lms",
            "Xyb",
            "Ycbcr",
        ]

        for color_type in expected_types:
            assert hasattr(zignal, color_type), f"Missing color type: {color_type}"
            assert callable(getattr(zignal, color_type)), f"{color_type} is not callable"

    def test_color_type_signatures(self):
        """Test that color types accept the correct number of arguments."""
        test_cases = [
            (zignal.Rgb, (128, 128, 128)),
            (zignal.Rgba, (128, 128, 128, 255)),
            (zignal.Hsv, (180.0, 50.0, 50.0)),
            (zignal.Hsl, (180.0, 50.0, 50.0)),
            (zignal.Lab, (50.0, 0.0, 0.0)),
            (zignal.Xyz, (0.5, 0.5, 0.5)),
            (zignal.Oklab, (0.5, 0.0, 0.0)),
            (zignal.Oklch, (0.5, 0.1, 180.0)),
            (zignal.Lch, (50.0, 10.0, 180.0)),
            (zignal.Lms, (0.3, 0.3, 0.3)),
            (zignal.Xyb, (0.0, 0.0, 0.0)),
            (zignal.Ycbcr, (128.0, 128.0, 128.0)),
        ]

        for color_type, args in test_cases:
            # Should work with correct number of arguments
            color = color_type(*args)
            assert color is not None

            # Should fail with wrong number of arguments
            with pytest.raises(TypeError):
                color_type()  # No args
            with pytest.raises(TypeError):
                color_type(*args, 0)  # Too many


class TestColorProperties:
    """Test color type properties are accessible."""

    def test_rgb_properties(self):
        """Test RGB color type properties."""
        color = zignal.Rgb(255, 128, 0)
        assert color.r == 255
        assert color.g == 128
        assert color.b == 0
        assert "Rgb" in str(color)

    def test_rgba_properties(self):
        """Test RGBA color type properties."""
        color = zignal.Rgba(255, 128, 0, 200)
        assert color.r == 255
        assert color.g == 128
        assert color.b == 0
        assert color.a == 200
        assert "Rgba" in str(color)

    def test_other_color_properties(self):
        """Test that other color types have accessible properties."""
        # Just verify properties exist and can be accessed
        hsv = zignal.Hsv(30.0, 100.0, 100.0)
        assert hasattr(hsv, "h")
        assert hasattr(hsv, "s")
        assert hasattr(hsv, "v")

        lab = zignal.Lab(50.0, 20.0, -10.0)
        assert hasattr(lab, "l")
        assert hasattr(lab, "a")
        assert hasattr(lab, "b")


class TestColorConversions:
    """Test color space conversion methods exist and work."""

    def test_conversion_methods_exist(self):
        """Test that color types have conversion methods."""
        rgb = zignal.Rgb(128, 64, 192)

        # Test a few key conversions exist and are callable
        conversion_methods = [
            "to_rgba",
            "to_hsv",
            "to_hsl",
            "to_lab",
            "to_xyz",
            "to_oklab",
        ]

        for method_name in conversion_methods:
            assert hasattr(rgb, method_name), f"Missing method: {method_name}"
            method = getattr(rgb, method_name)
            result = method()
            assert result is not None

    def test_all_types_have_conversions(self):
        """Test each color type can convert to others."""
        # Create one instance of each type
        colors = [
            zignal.Rgb(128, 64, 192),
            zignal.Hsv(270.0, 66.7, 75.3),
            zignal.Lab(50.0, 20.0, -30.0),
            zignal.Xyz(0.3, 0.2, 0.5),
            zignal.Oklab(0.5, 0.1, -0.1),
        ]

        # Each should have to_rgba at minimum
        for color in colors:
            assert hasattr(color, "to_rgba")

            # Test to_rgba works
            rgba = color.to_rgba()
            assert rgba is not None

            # Test to_rgb works (except for Rgb itself)
            if not isinstance(color, zignal.Rgb):
                assert hasattr(color, "to_rgb")
                rgb = color.to_rgb()
                assert rgb is not None


class TestColorValidation:
    """Test basic input validation."""

    def test_rgb_validation(self):
        """Test RGB component validation."""
        # Valid range
        zignal.Rgb(0, 0, 0)
        zignal.Rgb(255, 255, 255)

        # Invalid values
        with pytest.raises(ValueError):
            zignal.Rgb(-1, 0, 0)
        with pytest.raises(ValueError):
            zignal.Rgb(256, 0, 0)

    def test_invalid_types(self):
        """Test type validation."""
        with pytest.raises(TypeError):
            zignal.Rgb("255", 0, 0)  # String instead of int
        with pytest.raises(TypeError):
            zignal.Hsv(None, 50.0, 50.0)  # None instead of float


class TestColorEquality:
    """Test color equality comparison."""

    def test_same_color_equal(self):
        """Test that colors with same values are equal."""
        # RGB
        rgb1 = zignal.Rgb(128, 64, 192)
        rgb2 = zignal.Rgb(128, 64, 192)
        assert rgb1 == rgb2
        assert not (rgb1 != rgb2)

        # RGBA
        rgba1 = zignal.Rgba(128, 64, 192, 255)
        rgba2 = zignal.Rgba(128, 64, 192, 255)
        assert rgba1 == rgba2
        assert not (rgba1 != rgba2)

        # HSV
        hsv1 = zignal.Hsv(180.0, 50.0, 75.0)
        hsv2 = zignal.Hsv(180.0, 50.0, 75.0)
        assert hsv1 == hsv2
        assert not (hsv1 != hsv2)

    def test_different_values_not_equal(self):
        """Test that colors with different values are not equal."""
        rgb1 = zignal.Rgb(128, 64, 192)
        rgb2 = zignal.Rgb(128, 64, 193)  # Different blue
        assert rgb1 != rgb2
        assert not (rgb1 == rgb2)

        rgba1 = zignal.Rgba(128, 64, 192, 255)
        rgba2 = zignal.Rgba(128, 64, 192, 254)  # Different alpha
        assert rgba1 != rgba2
        assert not (rgba1 == rgba2)

    def test_different_types_equal_if_same_color(self):
        """Test that colors of different types are equal if they represent the same visual color."""
        # Same red color in different representations
        rgb = zignal.Rgb(255, 0, 0)
        rgba = zignal.Rgba(255, 0, 0, 255)
        hsv = zignal.Hsv(0.0, 100.0, 100.0)  # Red in HSV

        # RGB vs RGBA (same red)
        assert rgb == rgba
        assert not (rgb != rgba)

        # RGB vs HSV (same red)
        assert rgb == hsv
        assert not (rgb != hsv)

        # RGBA vs HSV (same red)
        assert rgba == hsv
        assert not (rgba != hsv)

        # But different colors should not be equal
        blue_rgb = zignal.Rgb(0, 0, 255)
        assert rgb != blue_rgb
        assert not (rgb == blue_rgb)

    def test_non_color_comparison(self):
        """Test comparison with non-color objects and tuples."""
        rgb = zignal.Rgb(128, 64, 192)

        # Tuples with matching values should be equal (duck typing)
        assert rgb == (128, 64, 192)
        assert rgb == (128, 64, 192, 255)  # RGBA tuple with default alpha

        # Grayscale integers
        gray = zignal.Rgb(100, 100, 100)
        assert gray == 100  # Grayscale integer comparison

        # Non-matching values
        assert rgb != (128, 64, 193)  # Different blue value
        assert rgb != 42  # Wrong grayscale value

        # Non-color types that can't be converted
        assert rgb != "color"
        assert rgb != [128, 64, 192]  # Lists not supported
        assert rgb != None

        # Ensure == also returns False for non-convertible types
        assert not (rgb == "color")
        assert not (rgb == [128, 64, 192])
        assert not (rgb == None)

    def test_same_instance_equal(self):
        """Test that a color is equal to itself."""
        rgb = zignal.Rgb(128, 64, 192)
        assert rgb == rgb
        assert not (rgb != rgb)

        lab = zignal.Lab(50.0, 20.0, -30.0)
        assert lab == lab
        assert not (lab != lab)


class TestColorToGray:
    """Test the to_gray method on all color types."""

    def test_to_gray_basic(self):
        """Test that to_gray works for all color types and returns valid integers."""
        # Test one instance of each color type
        test_cases = [
            (zignal.Rgb(128, 128, 128), "Rgb"),
            (zignal.Rgba(128, 128, 128, 255), "Rgba"),
            (zignal.Hsv(0.0, 0.0, 50.0), "Hsv"),
            (zignal.Hsl(0.0, 0.0, 50.0), "Hsl"),
            (zignal.Lab(50.0, 0.0, 0.0), "Lab"),
            (zignal.Xyz(0.2, 0.2, 0.2), "Xyz"),
            (zignal.Oklab(0.5, 0.0, 0.0), "Oklab"),
            (zignal.Oklch(0.5, 0.0, 0.0), "Oklch"),
            (zignal.Lch(50.0, 0.0, 0.0), "Lch"),
            (zignal.Lms(0.2, 0.2, 0.2), "Lms"),
            (zignal.Xyb(0.0, 0.0, 0.0), "Xyb"),
            (zignal.Ycbcr(128.0, 128.0, 128.0), "Ycbcr"),
        ]

        for color, name in test_cases:
            gray = color.to_gray()
            assert isinstance(gray, int), f"{name}.to_gray() did not return an int"
            assert 0 <= gray <= 255, f"{name}.to_gray() = {gray} out of range"

    def test_to_gray_black_white(self):
        """Test black and white conversions."""
        assert zignal.Rgb(0, 0, 0).to_gray() == 0
        assert zignal.Rgb(255, 255, 255).to_gray() == 255


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
