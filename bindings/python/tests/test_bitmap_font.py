import pytest
import zignal


def test_bitmap_font_default():
    """Test getting the default font."""
    font = zignal.BitmapFont.get_default_font()
    assert font is not None
    assert isinstance(font, zignal.BitmapFont)


def test_bitmap_font_load_not_found():
    """Test error handling when font file is not found."""
    with pytest.raises(FileNotFoundError):
        zignal.BitmapFont.load("/path/to/nonexistent/font.bdf")


def test_draw_text_with_default_font():
    """Test drawing text with default font."""
    import numpy as np

    # Create an image
    img = zignal.Image.from_numpy(np.zeros((100, 200, 4), dtype=np.uint8))
    canvas = img.canvas()

    # Get default font
    font = zignal.BitmapFont.get_default_font()

    # Draw text - basic call
    canvas.draw_text("Hello", (10, 10), (255, 255, 255), font)

    # Draw text with scale
    canvas.draw_text("Big", (10, 30), (255, 0, 0), font, scale=2.0)

    # Draw text with different colors
    canvas.draw_text("RGB", (10, 50), (255, 0, 0), font)
    canvas.draw_text("RGBA", (50, 50), (0, 255, 0, 128), font)
    canvas.draw_text("Color", (10, 70), zignal.Rgb(0, 0, 255), font)

    # Test default font by omitting font parameter
    canvas.draw_text("Default", (10, 90), (128, 128, 255))

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
    canvas.draw_text("Fast", (5, 5), (255, 255, 255), font, mode=zignal.DrawMode.FAST)
    canvas.draw_text("Soft", (5, 20), (255, 255, 255), font, mode=zignal.DrawMode.SOFT)


def test_draw_text_invalid_params():
    """Test error handling for invalid parameters."""
    import numpy as np

    img = zignal.Image.from_numpy(np.zeros((50, 50, 4), dtype=np.uint8))
    canvas = img.canvas()
    font = zignal.BitmapFont.get_default_font()

    # Invalid font type
    with pytest.raises(TypeError):
        canvas.draw_text("Hello", (10, 10), (255, 255, 255), "not a font")

    # Invalid position
    with pytest.raises(TypeError):
        canvas.draw_text("Hello", "invalid", (255, 255, 255), font)

    # Invalid text
    with pytest.raises(TypeError):
        canvas.draw_text(123, (10, 10), (255, 255, 255), font)


def test_draw_text_default_font():
    """Test drawing text with default font by omitting font parameter."""
    import numpy as np

    img = zignal.Image.from_numpy(np.zeros((50, 100, 4), dtype=np.uint8))
    canvas = img.canvas()

    # Draw text without specifying font - should use default
    canvas.draw_text("No Font", (5, 5), (255, 255, 255))
    canvas.draw_text("Scaled", (5, 20), (255, 0, 0), scale=1.5)
    canvas.draw_text("Smooth", (5, 35), (0, 255, 0), mode=zignal.DrawMode.SOFT)

    # Verify image was modified
    result = img.to_numpy()
    assert np.any(result > 0)


def test_draw_text_font_validation():
    """Test font parameter validation with improved error messages."""
    import numpy as np

    img = zignal.Image.from_numpy(np.zeros((50, 50, 4), dtype=np.uint8))
    canvas = img.canvas()

    # Test with non-BitmapFont object should fail with clear error
    with pytest.raises(TypeError, match="font must be a BitmapFont instance or None"):
        canvas.draw_text("Test", (5, 5), (255, 255, 255), "not a font")

    # Test with integer should fail
    with pytest.raises(TypeError, match="font must be a BitmapFont instance or None"):
        canvas.draw_text("Test", (5, 5), (255, 255, 255), 123)

    # Test with dict should fail
    with pytest.raises(TypeError, match="font must be a BitmapFont instance or None"):
        canvas.draw_text("Test", (5, 5), (255, 255, 255), {"font": "invalid"})
