"""Test BitmapFont API."""

import pytest
import zignal


def test_bitmap_font_default():
    """Test getting default font."""
    font = zignal.BitmapFont.get_default_font()
    assert isinstance(font, zignal.BitmapFont)


def test_bitmap_font_load_not_found():
    """Test loading non-existent font file."""
    with pytest.raises(FileNotFoundError, match="Font file not found"):
        zignal.BitmapFont.load("nonexistent.bdf")


def test_draw_text_with_default_font():
    """Test drawing text with default font."""
    import numpy as np

    # Create an image
    img = zignal.Image.from_numpy(np.zeros((100, 200, 4), dtype=np.uint8))
    canvas = img.canvas()

    # Get default font
    font = zignal.BitmapFont.get_default_font()

    # Draw text - basic call
    canvas.draw_text("Hello", (10, 10), font, (255, 255, 255))

    # Draw text with scale
    canvas.draw_text("Big", (10, 30), font, (255, 0, 0), scale=2.0)

    # Draw text with different colors
    canvas.draw_text("RGB", (10, 50), font, (255, 0, 0))
    canvas.draw_text("RGBA", (50, 50), font, (0, 255, 0, 128))
    canvas.draw_text("Color", (10, 70), font, zignal.Rgb(0, 0, 255))

    # Verify image was modified
    result = img.to_numpy()
    assert np.any(result > 0)


def test_draw_text_modes():
    """Test different drawing modes for text."""
    import numpy as np

    img = zignal.Image.from_numpy(np.zeros((50, 100, 4), dtype=np.uint8))
    canvas = img.canvas()
    font = zignal.BitmapFont.get_default_font()

    # Test both drawing modes
    canvas.draw_text("Fast", (5, 5), font, (255, 255, 255), mode=zignal.DrawMode.FAST)
    canvas.draw_text("Soft", (5, 20), font, (255, 255, 255), mode=zignal.DrawMode.SOFT)


def test_draw_text_invalid_params():
    """Test error handling for invalid parameters."""
    import numpy as np

    img = zignal.Image.from_numpy(np.zeros((50, 50, 4), dtype=np.uint8))
    canvas = img.canvas()
    font = zignal.BitmapFont.get_default_font()

    # Invalid font type
    with pytest.raises(TypeError):
        canvas.draw_text("Hello", (10, 10), "not a font", (255, 255, 255))

    # Invalid position
    with pytest.raises(TypeError):
        canvas.draw_text("Hello", "invalid", font, (255, 255, 255))

    # Invalid text
    with pytest.raises(TypeError):
        canvas.draw_text(123, (10, 10), font, (255, 255, 255))
