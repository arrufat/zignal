import pytest

import zignal


def test_basic_types_and_properties():
    rgb = zignal.Rgb(255, 128, 0)
    rgba = zignal.Rgba(1, 2, 3, 4)
    assert (rgb.r, rgb.g, rgb.b) == (255, 128, 0)
    assert (rgba.r, rgba.g, rgba.b, rgba.a) == (1, 2, 3, 4)


def test_conversions_exist_and_run():
    c = zignal.Rgb(10, 20, 30)
    assert c.to_rgba() is not None
    assert c.to_hsv() is not None


def test_validation_minimal():
    zignal.Rgb(0, 0, 0)
    zignal.Rgb(255, 255, 255)
    with pytest.raises(ValueError):
        zignal.Rgb(256, 0, 0)
    with pytest.raises(TypeError):
        zignal.Hsv(None, 0.0, 0.0)


def test_equality_duck_typing():
    rgb = zignal.Rgb(1, 2, 3)
    assert rgb == (1, 2, 3)
    assert zignal.Rgba(1, 2, 3, 255) == zignal.Rgb(1, 2, 3)


def test_blend_mode_and_blend():
    # Enum available and usable
    assert hasattr(zignal, "Blending")
    base = zignal.Rgb(100, 100, 100)
    res = base.blend(zignal.Rgba(200, 50, 150, 128), zignal.Blending.NORMAL)
    assert isinstance(res, zignal.Rgb)

    # Tuple overlay works
    res2 = base.blend((200, 50, 150, 128), zignal.Blending.MULTIPLY)
    assert isinstance(res2, zignal.Rgb)


def test_color_invert_methods():
    rgb = zignal.Rgb(0, 128, 255)
    assert rgb.invert() == zignal.Rgb(255, 127, 0)

    rgba = zignal.Rgba(10, 20, 30, 64)
    inverted_rgba = rgba.invert()
    assert inverted_rgba == zignal.Rgba(245, 235, 225, 64)
    assert inverted_rgba.a == 64

    hsl = zignal.Hsl(200.0, 60.0, 40.0)
    expected_rgb = hsl.to_rgb().invert()
    assert hsl.invert().to_rgb() == expected_rgb


@pytest.mark.parametrize(
    "factory",
    [
        lambda: zignal.Rgb(12, 34, 56),
        lambda: zignal.Rgba(12, 34, 56, 78),
        lambda: zignal.Hsl(200.0, 50.0, 40.0),
        lambda: zignal.Hsv(200.0, 50.0, 40.0),
        lambda: zignal.Lab(50.0, 10.0, -20.0),
        lambda: zignal.Lch(60.0, 20.0, 120.0),
        lambda: zignal.Lms(10.0, 20.0, 30.0),
        lambda: zignal.Oklab(0.5, 0.1, -0.1),
        lambda: zignal.Oklch(0.5, 0.2, 45.0),
        lambda: zignal.Xyb(0.1, 0.2, 0.3),
        lambda: zignal.Xyz(10.0, 20.0, 5.0),
        lambda: zignal.Ycbcr(128, 140, 120),
    ],
)
def test_color_invert_smoke(factory):
    color = factory()
    inverted = color.invert()
    assert isinstance(inverted, type(color))
    original_rgb = color if isinstance(color, zignal.Rgb) else color.to_rgb()
    inverted_rgb = inverted if isinstance(inverted, zignal.Rgb) else inverted.to_rgb()
    expected_rgb = original_rgb.invert()

    if isinstance(color, zignal.Ycbcr):
        assert abs(inverted_rgb.r - expected_rgb.r) <= 1
        assert abs(inverted_rgb.g - expected_rgb.g) <= 1
        assert abs(inverted_rgb.b - expected_rgb.b) <= 1
    else:
        assert inverted_rgb == expected_rgb
