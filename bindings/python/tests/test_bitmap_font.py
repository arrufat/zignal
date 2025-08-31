"""Bindings-level smoke tests for bitmap fonts."""

import pytest

import zignal


def test_bitmap_font_default_and_draw():
    font = zignal.BitmapFont.font8x8()
    assert isinstance(font, zignal.BitmapFont)
    img = zignal.Image(40, 80, 0)
    before = img.copy()
    img.canvas().draw_text("Hi", (5, 5), (255, 255, 255), font)
    assert img != before


def test_bitmap_font_invalids():
    canvas = zignal.Image(20, 40, 0).canvas()
    with pytest.raises(TypeError):
        canvas.draw_text("Hi", (0, 0), 255, "not a font")
    with pytest.raises(FileNotFoundError):
        zignal.BitmapFont.load("/definitely/missing.bdf")
