import pytest

import zignal


def test_bitmap_font_default():
    """Test getting the default font."""
    font = zignal.BitmapFont.font8x8()
    assert font is not None
    assert isinstance(font, zignal.BitmapFont)


def test_bitmap_font_load_not_found():
    """Test error handling when font file is not found."""
    with pytest.raises(FileNotFoundError):
        zignal.BitmapFont.load("/path/to/nonexistent/font.bdf")


def test_draw_text_with_default_font():
    """Test drawing text with default font."""
    image = zignal.Image(100, 200)
    original = image.copy()
    canvas = image.canvas()
    canvas.draw_text("Default", (10, 90), (128, 128, 255))
    font = zignal.BitmapFont.font8x8()
    canvas.draw_text("Hello", (10, 10), 255, font)
    canvas.draw_text("Big", (10, 30), (255, 0, 0), font, scale=2.0)
    canvas.draw_text("RGB", (10, 50), (255, 0, 0), font)
    canvas.draw_text("RGBA", (50, 50), (0, 255, 0, 128), font)
    canvas.draw_text("Color", (10, 70), zignal.Rgb(0, 0, 255), font)
    assert not image == original


def test_draw_text_modes():
    """Test different drawing modes for text."""
    image = zignal.Image(50, 100, 0)
    original = image.copy()
    canvas = image.canvas()
    font = zignal.BitmapFont.font8x8()
    canvas.draw_text("Fast", (5, 5), 255, font, mode=zignal.DrawMode.FAST)
    canvas.draw_text("Soft", (5, 20), 255, font, mode=zignal.DrawMode.SOFT)
    assert not image == original


def test_draw_text_invalid_params():
    """Test error handling for invalid parameters."""
    canvas = zignal.Image(50, 50).canvas()
    font = zignal.BitmapFont.font8x8()
    # Invalid font type
    with pytest.raises(TypeError):
        canvas.draw_text("Hello", (10, 10), 255, "not a font")
    # Invalid position
    with pytest.raises(TypeError):
        canvas.draw_text("Hello", "invalid", 255, font)
    # Invalid text
    with pytest.raises(TypeError):
        canvas.draw_text(123, (10, 10), 255, font)


def test_draw_text_font_validation():
    """Test font parameter validation with improved error messages."""
    canvas = zignal.Image(50, 50).canvas()
    # Test with non-BitmapFont object should fail with clear error
    with pytest.raises(TypeError, match="font must be a BitmapFont instance or None"):
        canvas.draw_text("Test", (5, 5), 255, "not a font")

    # Test with integer should fail
    with pytest.raises(TypeError, match="font must be a BitmapFont instance or None"):
        canvas.draw_text("Test", (5, 5), 255, 123)

    # Test with dict should fail
    with pytest.raises(TypeError, match="font must be a BitmapFont instance or None"):
        canvas.draw_text("Test", (5, 5), 255, {"font": "invalid"})
