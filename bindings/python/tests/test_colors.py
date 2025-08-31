"""Bindings-level smoke tests for color types."""

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


def test_blend_mode_and_blend_smoke():
    # Enum available and usable
    assert hasattr(zignal, "Blending")
    base = zignal.Rgb(100, 100, 100)
    res = base.blend(zignal.Rgba(200, 50, 150, 128), zignal.Blending.NORMAL)
    assert isinstance(res, zignal.Rgb)

    # Tuple overlay works
    res2 = base.blend((200, 50, 150, 128), zignal.Blending.MULTIPLY)
    assert isinstance(res2, zignal.Rgb)
