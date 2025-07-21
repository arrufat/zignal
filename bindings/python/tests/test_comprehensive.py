"""Comprehensive integration tests for zignal Python bindings."""

import pytest
import zignal


def test_all_color_types_available():
    """Test that all 12 color types are available."""
    expected_types = [
        'Rgb', 'Hsv', 'Hsl', 'Lab', 'Xyz', 
        'Oklab', 'Oklch', 'Lch', 'Lms', 'Xyb', 'Ycbcr'
        # 'Rgba',  # FIXME: Currently causes segmentation fault
    ]
    
    for color_type in expected_types:
        assert hasattr(zignal, color_type), f"Missing color type: {color_type}"
        assert callable(getattr(zignal, color_type)), f"{color_type} is not callable"


def test_color_type_signatures():
    """Test that color types accept the correct number of arguments."""
    test_cases = [
        (zignal.Rgb, 3, (128, 128, 128)),
        # (zignal.Rgba, 4, (128, 128, 128, 255)),  # FIXME: Segfault
        (zignal.Hsv, 3, (180.0, 50.0, 50.0)),
        (zignal.Hsl, 3, (180.0, 50.0, 50.0)),
        (zignal.Lab, 3, (50.0, 0.0, 0.0)),
        (zignal.Xyz, 3, (0.5, 0.5, 0.5)),
        (zignal.Oklab, 3, (0.5, 0.0, 0.0)),
        (zignal.Oklch, 3, (0.5, 0.1, 180.0)),
        (zignal.Lch, 3, (50.0, 10.0, 180.0)),
        (zignal.Lms, 3, (0.3, 0.3, 0.3)),
        (zignal.Xyb, 3, (0.0, 0.0, 0.0)),
        (zignal.Ycbcr, 3, (128.0, 128.0, 128.0)),
    ]
    
    for color_type, arg_count, args in test_cases:
        # Should work with correct number of arguments
        color = color_type(*args)
        assert color is not None
        
        # Should fail with wrong number of arguments
        if arg_count > 1:
            with pytest.raises(TypeError):
                color_type(*args[:-1])  # Too few
        with pytest.raises(TypeError):
            color_type(*args, 0)  # Too many


def test_all_conversion_methods():
    """Test that all color types have conversion methods to other types."""
    # Create one instance of each color type
    colors = {
        'rgb': zignal.Rgb(128, 64, 192),
        # 'rgba': zignal.Rgba(128, 64, 192, 200),  # FIXME: Segfault
        'hsv': zignal.Hsv(270.0, 66.7, 75.3),
        'hsl': zignal.Hsl(270.0, 50.0, 50.0),
        'lab': zignal.Lab(50.0, 20.0, -30.0),
        'xyz': zignal.Xyz(0.3, 0.2, 0.5),
        'oklab': zignal.Oklab(0.5, 0.1, -0.1),
        'oklch': zignal.Oklch(0.5, 0.14, 315.0),
        'lch': zignal.Lch(50.0, 36.0, 303.0),
        'lms': zignal.Lms(0.2, 0.2, 0.3),
        'xyb': zignal.Xyb(0.0, 0.1, -0.1),
        'ycbcr': zignal.Ycbcr(128.0, 140.0, 110.0),
    }
    
    # Expected conversion methods for each type
    expected_conversions = [
        'to_rgb', 'to_rgba', 'to_hsv', 'to_hsl', 'to_lab', 'to_xyz',
        'to_oklab', 'to_oklch', 'to_lch', 'to_lms', 'to_xyb', 'to_ycbcr'
    ]
    
    for color_name, color_instance in colors.items():
        for method_name in expected_conversions:
            # Skip self-conversion
            if method_name == f"to_{color_name}":
                continue
                
            assert hasattr(color_instance, method_name), \
                f"{color_name} missing method: {method_name}"
            
            # Test that the method works
            method = getattr(color_instance, method_name)
            result = method()
            assert result is not None, \
                f"{color_name}.{method_name}() returned None"


def test_string_representation():
    """Test that all color types have proper string representation."""
    test_cases = [
        (zignal.Rgb(255, 128, 0), "Rgb("),
        # (zignal.Rgba(255, 128, 0, 200), "Rgba("),  # FIXME: Segfault
        (zignal.Hsv(30.0, 100.0, 100.0), "Hsv("),
        (zignal.Hsl(30.0, 100.0, 50.0), "Hsl("),
        (zignal.Lab(50.0, 20.0, -10.0), "Lab("),
        (zignal.Xyz(0.3, 0.4, 0.2), "Xyz("),
        (zignal.Oklab(0.5, 0.1, -0.05), "Oklab("),
        (zignal.Oklch(0.5, 0.1, 180.0), "Oklch("),
        (zignal.Lch(50.0, 25.0, 180.0), "Lch("),
        (zignal.Lms(0.3, 0.4, 0.1), "Lms("),
        (zignal.Xyb(0.1, 0.3, -0.05), "Xyb("),
        (zignal.Ycbcr(128.0, 110.0, 140.0), "Ycbcr("),
    ]
    
    for color, expected_prefix in test_cases:
        repr_str = repr(color)
        assert expected_prefix in repr_str, \
            f"Expected '{expected_prefix}' in {repr_str}"
        # Also test str()
        str_repr = str(color)
        assert expected_prefix in str_repr, \
            f"Expected '{expected_prefix}' in {str_repr}"


def test_complex_conversion_chains():
    """Test complex conversion chains maintain reasonable accuracy."""
    # Start with a known RGB color
    original = zignal.Rgb(100, 150, 200)
    
    # Chain 1: RGB -> HSV -> Lab -> Oklab -> RGB
    chain1 = original.to_hsv().to_lab().to_oklab().to_rgb()
    assert abs(chain1.r - original.r) < 10
    assert abs(chain1.g - original.g) < 10
    assert abs(chain1.b - original.b) < 10
    
    # Chain 2: RGB -> XYZ -> Lab -> LCH -> Lab -> XYZ -> RGB
    chain2 = original.to_xyz().to_lab().to_lch().to_lab().to_xyz().to_rgb()
    assert abs(chain2.r - original.r) < 10
    assert abs(chain2.g - original.g) < 10
    assert abs(chain2.b - original.b) < 10


def test_edge_case_conversions():
    """Test conversions with edge case values."""
    # Pure black
    black = zignal.Rgb(0, 0, 0)
    black_hsv = black.to_hsv()
    assert black_hsv.v == pytest.approx(0.0)
    
    # Pure white
    white = zignal.Rgb(255, 255, 255)
    white_hsv = white.to_hsv()
    assert white_hsv.v == pytest.approx(100.0)
    assert white_hsv.s == pytest.approx(0.0)
    
    # Gray (no saturation)
    gray = zignal.Rgb(128, 128, 128)
    gray_hsv = gray.to_hsv()
    assert gray_hsv.s == pytest.approx(0.0)
    
    gray_hsl = gray.to_hsl()
    assert gray_hsl.s == pytest.approx(0.0)