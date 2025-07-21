"""Comprehensive test suite for zignal color types."""

import pytest
import zignal


class TestColorTypes:
    """Test all color type constructors and basic properties."""

    def test_rgb(self):
        """Test RGB color type."""
        color = zignal.Rgb(255, 128, 0)
        assert color.r == 255
        assert color.g == 128
        assert color.b == 0
        assert "Rgb(r=255, g=128, b=0)" in str(color)

    def test_rgba(self):
        """Test RGBA color type."""
        color = zignal.Rgba(255, 128, 0, 200)
        assert color.r == 255
        assert color.g == 128
        assert color.b == 0
        assert color.a == 200
        assert "Rgba(r=255, g=128, b=0, a=200)" in str(color)

    def test_hsv(self):
        """Test HSV color type."""
        color = zignal.Hsv(30.0, 100.0, 100.0)
        assert color.h == pytest.approx(30.0)
        assert color.s == pytest.approx(100.0)
        assert color.v == pytest.approx(100.0)
        assert "Hsv(" in str(color)

    def test_hsl(self):
        """Test HSL color type."""
        color = zignal.Hsl(30.0, 100.0, 50.0)
        assert color.h == pytest.approx(30.0)
        assert color.s == pytest.approx(100.0)
        assert color.l == pytest.approx(50.0)
        assert "Hsl(" in str(color)

    def test_lab(self):
        """Test Lab color type."""
        color = zignal.Lab(50.0, 20.0, -10.0)
        assert color.l == pytest.approx(50.0)
        assert color.a == pytest.approx(20.0)
        assert color.b == pytest.approx(-10.0)
        assert "Lab(" in str(color)

    def test_xyz(self):
        """Test XYZ color type."""
        color = zignal.Xyz(0.3, 0.4, 0.2)
        assert color.x == pytest.approx(0.3)
        assert color.y == pytest.approx(0.4)
        assert color.z == pytest.approx(0.2)
        assert "Xyz(" in str(color)

    def test_oklab(self):
        """Test Oklab color type."""
        color = zignal.Oklab(0.5, 0.1, -0.05)
        assert color.l == pytest.approx(0.5)
        assert color.a == pytest.approx(0.1)
        assert color.b == pytest.approx(-0.05)
        assert "Oklab(" in str(color)

    def test_oklch(self):
        """Test Oklch color type."""
        color = zignal.Oklch(0.5, 0.1, 180.0)
        assert color.l == pytest.approx(0.5)
        assert color.c == pytest.approx(0.1)
        assert color.h == pytest.approx(180.0)
        assert "Oklch(" in str(color)

    def test_lch(self):
        """Test LCH color type."""
        color = zignal.Lch(50.0, 25.0, 180.0)
        assert color.l == pytest.approx(50.0)
        assert color.c == pytest.approx(25.0)
        assert color.h == pytest.approx(180.0)
        assert "Lch(" in str(color)

    def test_lms(self):
        """Test LMS color type."""
        color = zignal.Lms(0.3, 0.4, 0.1)
        assert color.l == pytest.approx(0.3)
        assert color.m == pytest.approx(0.4)
        assert color.s == pytest.approx(0.1)
        assert "Lms(" in str(color)

    def test_xyb(self):
        """Test XYB color type."""
        color = zignal.Xyb(0.1, 0.3, -0.05)
        assert color.x == pytest.approx(0.1)
        assert color.y == pytest.approx(0.3)
        assert color.b == pytest.approx(-0.05)
        assert "Xyb(" in str(color)

    def test_ycbcr(self):
        """Test YCbCr color type."""
        color = zignal.Ycbcr(128.0, 110.0, 140.0)
        assert color.y == pytest.approx(128.0)
        assert color.cb == pytest.approx(110.0)
        assert color.cr == pytest.approx(140.0)
        assert "Ycbcr(" in str(color)


class TestColorValidation:
    """Test color component validation."""

    def test_rgb_validation(self):
        """Test RGB component validation."""
        # Valid range 0-255
        zignal.Rgb(0, 0, 0)
        zignal.Rgb(255, 255, 255)
        
        # Invalid values
        with pytest.raises(ValueError):
            zignal.Rgb(-1, 0, 0)
        with pytest.raises(ValueError):
            zignal.Rgb(256, 0, 0)
        with pytest.raises(ValueError):
            zignal.Rgb(0, -1, 0)
        with pytest.raises(ValueError):
            zignal.Rgb(0, 256, 0)

    def test_hsv_validation(self):
        """Test HSV component validation."""
        # Valid ranges
        zignal.Hsv(0.0, 0.0, 0.0)
        zignal.Hsv(360.0, 100.0, 100.0)
        
        # Invalid values
        with pytest.raises(ValueError):
            zignal.Hsv(-1.0, 50.0, 50.0)
        with pytest.raises(ValueError):
            zignal.Hsv(361.0, 50.0, 50.0)
        with pytest.raises(ValueError):
            zignal.Hsv(180.0, -1.0, 50.0)
        with pytest.raises(ValueError):
            zignal.Hsv(180.0, 101.0, 50.0)


class TestColorConversions:
    """Test color space conversions."""

    def test_rgb_to_hsv(self):
        """Test RGB to HSV conversion."""
        rgb = zignal.Rgb(255, 0, 0)  # Pure red
        hsv = rgb.to_hsv()
        assert hsv.h == pytest.approx(0.0, abs=1.0)
        assert hsv.s == pytest.approx(100.0, abs=1.0)
        assert hsv.v == pytest.approx(100.0, abs=1.0)

    def test_hsv_to_rgb(self):
        """Test HSV to RGB conversion."""
        hsv = zignal.Hsv(0.0, 100.0, 100.0)  # Pure red
        rgb = hsv.to_rgb()
        assert rgb.r == 255
        assert rgb.g == 0
        assert rgb.b == 0

    def test_rgb_to_lab(self):
        """Test RGB to Lab conversion."""
        rgb = zignal.Rgb(255, 255, 255)  # White
        lab = rgb.to_lab()
        assert lab.l == pytest.approx(100.0, abs=1.0)
        assert lab.a == pytest.approx(0.0, abs=1.0)
        assert lab.b == pytest.approx(0.0, abs=1.0)

    def test_lab_to_rgb(self):
        """Test Lab to RGB conversion."""
        lab = zignal.Lab(50.0, 0.0, 0.0)  # Gray
        rgb = lab.to_rgb()
        # Should be a gray color
        assert abs(rgb.r - rgb.g) < 5
        assert abs(rgb.g - rgb.b) < 5

    def test_rgb_to_xyz(self):
        """Test RGB to XYZ conversion."""
        rgb = zignal.Rgb(255, 255, 255)  # White
        xyz = rgb.to_xyz()
        # D65 white point values (scaled by 100)
        assert xyz.x == pytest.approx(95.05, abs=1.0)
        assert xyz.y == pytest.approx(100.0, abs=1.0)
        assert xyz.z == pytest.approx(108.9, abs=1.0)

    def test_conversion_roundtrip(self):
        """Test conversion round-trip accuracy."""
        original = zignal.Rgb(128, 64, 192)
        
        # RGB -> HSV -> RGB
        hsv = original.to_hsv()
        back_to_rgb = hsv.to_rgb()
        assert back_to_rgb.r == pytest.approx(original.r, abs=1)
        assert back_to_rgb.g == pytest.approx(original.g, abs=1)
        assert back_to_rgb.b == pytest.approx(original.b, abs=1)
        
        # RGB -> Lab -> RGB
        lab = original.to_lab()
        back_to_rgb = lab.to_rgb()
        assert back_to_rgb.r == pytest.approx(original.r, abs=2)
        assert back_to_rgb.g == pytest.approx(original.g, abs=2)
        assert back_to_rgb.b == pytest.approx(original.b, abs=2)


class TestSpecialCases:
    """Test special cases and edge conditions."""

    # def test_rgba_default_alpha(self):
    #     """Test RGBA conversion from RGB uses default alpha."""
    #     # FIXME: RGBA currently causes segmentation fault
    #     # rgb = zignal.Rgb(100, 150, 200)
    #     # rgba = rgb.to_rgba()
    #     # assert rgba.r == 100
    #     # assert rgba.g == 150
    #     # assert rgba.b == 200
    #     # assert rgba.a == 255  # Default alpha

    def test_black_white_colors(self):
        """Test black and white color conversions."""
        # Black
        black_rgb = zignal.Rgb(0, 0, 0)
        black_hsv = black_rgb.to_hsv()
        assert black_hsv.v == pytest.approx(0.0)
        
        # White
        white_rgb = zignal.Rgb(255, 255, 255)
        white_hsv = white_rgb.to_hsv()
        assert white_hsv.v == pytest.approx(100.0)
        assert white_hsv.s == pytest.approx(0.0)

    def test_gray_colors(self):
        """Test gray color conversions."""
        gray = zignal.Rgb(128, 128, 128)
        hsv = gray.to_hsv()
        assert hsv.s == pytest.approx(0.0)  # No saturation for gray
        
        hsl = gray.to_hsl()
        assert hsl.s == pytest.approx(0.0)  # No saturation for gray