"""Test blending functionality in zignal Python bindings."""

import zignal


def test_blend_mode_enum():
    """Test that BlendMode enum is accessible and has expected values."""
    # Check that BlendMode exists
    assert hasattr(zignal, "BlendMode")

    # Check that all blend modes are present
    expected_modes = [
        "NORMAL",
        "MULTIPLY",
        "SCREEN",
        "OVERLAY",
        "SOFT_LIGHT",
        "HARD_LIGHT",
        "COLOR_DODGE",
        "COLOR_BURN",
        "DARKEN",
        "LIGHTEN",
        "DIFFERENCE",
        "EXCLUSION",
    ]

    for mode in expected_modes:
        assert hasattr(zignal.BlendMode, mode), f"Missing blend mode: {mode}"

    # Check that enum values are integers
    assert isinstance(zignal.BlendMode.NORMAL.value, int)
    assert zignal.BlendMode.NORMAL.value == 0
    assert zignal.BlendMode.EXCLUSION.value == 11


def test_blend_method_exists():
    """Test that color types have blend method."""
    # Create test colors
    rgb = zignal.Rgb(100, 100, 100)
    rgba = zignal.Rgba(200, 50, 150, 128)

    # Check that blend method exists
    assert hasattr(rgb, "blend"), "Rgb should have blend method"
    assert hasattr(rgba, "blend"), "Rgba should have blend method"

    # Check other color types
    hsl = zignal.Hsl(180, 50, 50)
    assert hasattr(hsl, "blend"), "Hsl should have blend method"


def test_blend_basic():
    """Test basic blending operations."""
    # Create base and overlay colors
    base = zignal.Rgb(100, 100, 100)
    overlay = zignal.Rgba(200, 50, 150, 128)

    # Test normal blend
    result = base.blend(overlay, zignal.BlendMode.NORMAL)
    assert isinstance(result, zignal.Rgb)

    # Test that result is different from base (unless fully transparent)
    assert result.r != base.r or result.g != base.g or result.b != base.b


def test_blend_modes():
    """Test different blend modes produce different results."""
    base = zignal.Rgb(128, 128, 128)
    overlay = zignal.Rgba(64, 192, 128, 255)

    # Test different modes produce different results
    normal = base.blend(overlay, zignal.BlendMode.NORMAL)
    multiply = base.blend(overlay, zignal.BlendMode.MULTIPLY)
    screen = base.blend(overlay, zignal.BlendMode.SCREEN)

    # Results should be different for different modes
    assert normal.r != multiply.r or normal.g != multiply.g or normal.b != multiply.b
    assert normal.r != screen.r or normal.g != screen.g or normal.b != screen.b
    assert multiply.r != screen.r or multiply.g != screen.g or multiply.b != screen.b


def test_blend_transparent():
    """Test blending with transparent colors."""
    base = zignal.Rgb(100, 100, 100)

    # Fully transparent overlay should not change base
    transparent = zignal.Rgba(255, 0, 0, 0)
    result = base.blend(transparent, zignal.BlendMode.NORMAL)
    assert result.r == base.r
    assert result.g == base.g
    assert result.b == base.b

    # Semi-transparent should blend
    semi = zignal.Rgba(255, 0, 0, 128)
    result = base.blend(semi, zignal.BlendMode.NORMAL)
    assert result.r > base.r  # Red should increase
    assert result.g < base.g or result.g == base.g  # Green should decrease or stay
    assert result.b < base.b or result.b == base.b  # Blue should decrease or stay


def test_blend_type_preservation():
    """Test that blend returns the same type as the base color."""
    # Test with different color types
    rgb = zignal.Rgb(100, 100, 100)
    rgba = zignal.Rgba(100, 100, 100, 255)
    hsl = zignal.Hsl(0, 0, 39)  # Roughly equivalent to RGB(100,100,100)
    overlay = zignal.Rgba(200, 50, 150, 128)

    # Each should return its own type
    rgb_result = rgb.blend(overlay, zignal.BlendMode.NORMAL)
    assert isinstance(rgb_result, zignal.Rgb)

    rgba_result = rgba.blend(overlay, zignal.BlendMode.NORMAL)
    assert isinstance(rgba_result, zignal.Rgba)

    hsl_result = hsl.blend(overlay, zignal.BlendMode.NORMAL)
    assert isinstance(hsl_result, zignal.Hsl)


def test_blend_with_tuple():
    """Test that blend accepts tuples as overlay colors."""
    base = zignal.Rgb(100, 100, 100)

    # Test with tuple instead of Rgba
    tuple_overlay = (200, 50, 150, 128)
    result = base.blend(tuple_overlay, zignal.BlendMode.NORMAL)
    assert isinstance(result, zignal.Rgb)

    # Result should be the same as using Rgba
    rgba_overlay = zignal.Rgba(200, 50, 150, 128)
    rgba_result = base.blend(rgba_overlay, zignal.BlendMode.NORMAL)
    assert result.r == rgba_result.r
    assert result.g == rgba_result.g
    assert result.b == rgba_result.b

    # Test with fully opaque tuple
    opaque_tuple = (255, 0, 0, 255)
    result = base.blend(opaque_tuple, zignal.BlendMode.NORMAL)
    assert result.r == 255
    assert result.g == 0
    assert result.b == 0

    # Test with fully transparent tuple
    transparent_tuple = (255, 0, 0, 0)
    result = base.blend(transparent_tuple, zignal.BlendMode.NORMAL)
    assert result.r == base.r
    assert result.g == base.g
    assert result.b == base.b
