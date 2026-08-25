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
SYSTEM_TTC_FONTS = [
    "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/OTF/NotoSansCJK-Regular.ttc",
]
SYSTEM_TTC_FONT = next((p for p in SYSTEM_TTC_FONTS if os.path.exists(p)), None)


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


@pytest.mark.skipif(SYSTEM_TTC_FONT is None, reason="no font collection installed")
def test_font_collection():
    first = zignal.Font.load(SYSTEM_TTC_FONT)
    second = zignal.Font.load(SYSTEM_TTC_FONT, face=1)
    assert first.kind == "vector" and second.kind == "vector"
    assert first.has_glyph("\u4e2d") and second.has_glyph("\u4e2d")
    assert inked(render("\u6f22\u5b57", first, rows=60, cols=120, size=40, mode=zignal.DrawMode.SOFT)) > 0
    with pytest.raises(ValueError):
        zignal.Font.load(SYSTEM_TTC_FONT, face=1000)
    with pytest.raises(ValueError):
        zignal.Font.load(SYSTEM_TTC_FONT, face=-1)


def test_face_on_a_bitmap_font(tmp_path):
    path = str(tmp_path / "f.bdf")
    zignal.Font.font8x8().save(path)
    assert zignal.Font.load(path, face=0).kind == "bitmap"
    with pytest.raises(ValueError):
        zignal.Font.load(path, face=1)


def test_text_box_layout():
    font = zignal.Font.font8x8()

    def drawn_at(x, y):
        img = zignal.Image(60, 100, 0)
        img.canvas().draw_text("AB", (x, y), 255, font)
        return img.to_numpy()

    # "AB" is 16 x 8 px; the box variants land exactly where draw_text would.
    box = (10, 10, 90, 50)
    centered = zignal.Image(60, 100, 0)
    centered.canvas().draw_text_box(
        "AB", box, 255, font, halign=zignal.TextAlign.CENTER, valign=zignal.VerticalAlign.MIDDLE
    )
    np.testing.assert_array_equal(centered.to_numpy(), drawn_at(10 + 32, 10 + 16))
    corner = zignal.Image(60, 100, 0)
    corner.canvas().draw_text_box(
        "AB", zignal.Rectangle(10, 10, 90, 50), 255, font,
        halign=zignal.TextAlign.RIGHT, valign=zignal.VerticalAlign.BOTTOM,
    )
    np.testing.assert_array_equal(corner.to_numpy(), drawn_at(90 - 16, 50 - 8))

    # Wrapping at spaces matches an explicit newline; measure_text agrees.
    wrapped = zignal.Image(60, 100, 0)
    wrapped.canvas().draw_text_box("AB AB", (10, 10, 27, 60), 255, font, wrap=True, line_spacing=1.5)
    twoline = zignal.Image(60, 100, 0)
    twoline.canvas().draw_text("AB", (10, 10), 255, font)
    twoline.canvas().draw_text("AB", (10, 22), 255, font)
    np.testing.assert_array_equal(wrapped.to_numpy(), twoline.to_numpy())
    measured = font.measure_text("AB AB", 8, wrap_width=17, line_spacing=1.5)
    assert (measured.width, measured.height) == (16, 24)
    assert font.measure_text("AB AB", 8).width == 40
    assert font.measure_text("AB", 8, letter_spacing=3).width == 19

    with pytest.raises(TypeError):
        centered.canvas().draw_text_box("AB", "not a rect", 255, font)
    with pytest.raises(ValueError):
        centered.canvas().draw_text_outline("AB", (0, 0), 255, -1.0, font)


def test_text_outline_and_halo():
    # Bitmap fonts get a halo: a strict superset of the glyph's own pixels.
    plain = render("H", size=None)
    halo = zignal.Image(40, 80, 0)
    halo.canvas().draw_text_outline("H", (5, 5), 255, 4.0)
    assert inked(halo) > inked(plain)
    assert np.all(halo.to_numpy()[plain.to_numpy() > 0] > 0)

    if SYSTEM_FONT is None:
        return
    font = zignal.Font.load(SYSTEM_FONT)
    fill = zignal.Image(100, 100, 0)
    fill.canvas().draw_text("I", (10, 10), 255, font, size=72, mode=zignal.DrawMode.SOFT)
    hollow = zignal.Image(100, 100, 0)
    hollow.canvas().draw_text_outline("I", (10, 10), 255, 2.0, font, size=72, mode=zignal.DrawMode.SOFT)
    tight = font.get_text_bounds_tight("I", 72)
    row = int(10 + (tight.top + tight.bottom) / 2)
    col = int(10 + (tight.left + tight.right) / 2)
    assert fill.to_numpy()[row, col] > 0
    assert hollow.to_numpy()[row, col] == 0
    assert 0 < inked(hollow) < inked(fill)
    boxed = zignal.Image(100, 100, 0)
    boxed.canvas().draw_text_box_outline(
        "I", (10, 10, 100, 100), 255, 2.0, font, size=72, mode=zignal.DrawMode.SOFT
    )
    np.testing.assert_array_equal(boxed.to_numpy(), hollow.to_numpy())
