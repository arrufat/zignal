import os

import numpy as np
import pytest

import zignal

# In order of preference: DejaVu Sans first (fonts-dejavu-core ships on GitHub's Ubuntu
# runners; ttf-dejavu on Arch), then fonts that keep the generic checks running elsewhere.
SYSTEM_FONTS = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/TTF/Roboto-Regular.ttf",
]
SYSTEM_FONT = next((p for p in SYSTEM_FONTS if os.path.exists(p)), None)
SYSTEM_OTF_FONTS = [
    "/usr/share/fonts/gnu-free/FreeSans.otf",
    "/usr/share/fonts/opentype/freefont/FreeSans.otf",
    "/usr/share/fonts/OTF/FreeSans.otf",
]
SYSTEM_OTF_FONT = next((p for p in SYSTEM_OTF_FONTS if os.path.exists(p)), None)


def inked(img):
    return np.count_nonzero(img.to_numpy())


def render(text, *args, rows=40, cols=80, **kwargs):
    img = zignal.Image(rows, cols, 0)
    img.canvas().draw_text(text, (5, 5), 255, *args, **kwargs)
    return img


def test_font8x8_metrics_and_draw():
    font = zignal.Font.font8x8()
    assert isinstance(font, zignal.Font)
    assert font is zignal.Font.font8x8()
    assert font.kind == "bitmap"
    assert font.name.startswith("8x8")
    assert font.height == 8
    assert font.line_height(16) == 16
    assert font.ascent(16) > 0
    assert font.has_glyph("A")
    assert font.get_text_bounds("abc", 8).width == 24
    assert font.get_text_bounds("abc", 16).width == 48
    assert 'kind="bitmap"' in repr(font)

    small = render("Hi", font)
    assert inked(small) > 0
    assert inked(render("Hi", font, size=16)) == 4 * inked(small)
    assert render("Hi") == small


def test_bitmap_font_round_trip(tmp_path):
    font = zignal.Font.font8x8()
    for name in ("f.bdf", "f.pcf.gz"):
        path = str(tmp_path / name)
        font.save(path)
        loaded = zignal.Font.load(path)
        assert loaded.kind == "bitmap"
        assert loaded.height == 8
        assert loaded.get_text_bounds("abc", 8).width == font.get_text_bounds("abc", 8).width


def test_font_errors(tmp_path):
    canvas = zignal.Image(20, 40, 0).canvas()
    with pytest.raises(TypeError):
        canvas.draw_text("Hi", (0, 0), 255, "not a font")
    with pytest.raises(FileNotFoundError):
        zignal.Font.load("/definitely/missing.bdf")
    junk = tmp_path / "junk.ttf"
    junk.write_bytes(b"\x00\x01\x00\x00" + b"\xff" * 64)
    with pytest.raises(ValueError):
        zignal.Font.load(str(junk))
    font = zignal.Font.font8x8()
    with pytest.raises(TypeError):
        font.has_glyph("ab")
    with pytest.raises(TypeError):
        font.has_glyph(65)


@pytest.mark.skipif(SYSTEM_FONT is None, reason="no TrueType font installed")
def test_truetype_font(tmp_path):
    font = zignal.Font.load(SYSTEM_FONT)
    assert font.kind == "vector"
    assert font.name is None
    assert font.height is None
    assert 'kind="vector"' in repr(font)
    assert font.ascent(24) > 0
    assert font.line_height(24) > font.ascent(24)
    assert font.has_glyph("A")
    assert not font.has_glyph("\U0010ffff")  # a noncharacter no font maps

    bounds = font.get_text_bounds("Hello", 24)
    assert bounds.width > 24 and bounds.height == pytest.approx(font.line_height(24))
    assert font.get_text_bounds("Hello", 48).width == pytest.approx(2 * bounds.width)
    # Kerning pulls "AV" closer than the two advances.
    assert (
        font.get_text_bounds("AV", 24).width
        < font.get_text_bounds("A", 24).width + font.get_text_bounds("V", 24).width
    )
    tight = font.get_text_bounds_tight("Hello", 24)
    assert 0 < tight.width <= bounds.width

    if "DejaVuSans" in SYSTEM_FONT:
        # DejaVu Sans 2.37: exact values from its tables.
        assert repr(font) == 'Font(kind="vector", units_per_em=2048, glyphs=6253)'
        assert font.ascent(24) == pytest.approx(22.277, abs=1e-3)
        assert font.line_height(24) == pytest.approx(27.9375, abs=1e-3)
        assert bounds.width == pytest.approx(60.832, abs=1e-3)
        assert font.get_text_bounds("AV", 24).width == pytest.approx(31.301, abs=1e-3)
        assert (
            font.has_glyph("\U0001f600") and font.has_glyph("\u0627") and font.has_glyph("\u03a9")
        )

    small = render("Hello", font, rows=60, cols=200, size=24, mode=zignal.DrawMode.SOFT)
    big = render("Hello", font, rows=60, cols=200, size=48, mode=zignal.DrawMode.SOFT)
    assert 0 < inked(small) < inked(big)

    with pytest.raises(ValueError):
        font.save(str(tmp_path / "out.bdf"))


@pytest.mark.skipif(SYSTEM_OTF_FONT is None, reason="no CFF OpenType font installed")
def test_cff_opentype_font():
    font = zignal.Font.load(SYSTEM_OTF_FONT)
    assert font.kind == "vector"
    assert font.has_glyph("A")
    assert font.get_text_bounds("Hello", 24).width > 24
    assert (
        font.get_text_bounds("AV", 24).width
        < font.get_text_bounds("A", 24).width + font.get_text_bounds("V", 24).width
    )
    small = render("Hello", font, rows=60, cols=200, size=24, mode=zignal.DrawMode.SOFT)
    big = render("Hello", font, rows=60, cols=200, size=48, mode=zignal.DrawMode.SOFT)
    assert 0 < inked(small) < inked(big)
