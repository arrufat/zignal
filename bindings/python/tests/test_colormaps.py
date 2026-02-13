import pytest
from zignal import Image, Colormap
import zignal


def test_colormap_factories():
    # Test all factory methods with default params
    c1 = Colormap.jet()
    assert c1.type == "jet"
    assert c1.min is None
    assert c1.max is None

    c2 = Colormap.heat()
    assert c2.type == "heat"

    c3 = Colormap.turbo()
    assert c3.type == "turbo"

    c4 = Colormap.viridis()
    assert c4.type == "viridis"


def test_colormap_params():
    # Test with custom ranges
    c = Colormap.jet(min=0.0, max=255.0)
    assert c.type == "jet"
    assert c.min == 0.0
    assert c.max == 255.0

    c = Colormap.heat(min=-1.0)
    assert c.min == -1.0
    assert c.max is None


def test_apply_colormap():
    # Create a grayscale gradient image
    width, height = 256, 1
    img = Image(height, width, dtype=zignal.Gray)

    # Fill with gradient 0..255
    for i in range(width):
        img[0, i] = i

    # Create Colormap explicitly
    cmap = Colormap.jet(min=0.0, max=255.0)

    # Apply JET
    colored = img.apply_colormap(cmap)
    assert colored.cols == width
    assert colored.rows == height

    # Check key points for Jet:
    # 0 -> Dark Blue (0, 0, 128)
    p0 = colored[0, 0].item()
    assert p0.r == 0 and p0.g == 0 and abs(p0.b - 128) <= 1

    # 128 -> Greenish (roughly)
    p128 = colored[0, 128].item()
    assert p128.g > 200

    # 255 -> Dark Red (128, 0, 0)
    p255 = colored[0, 255].item()
    assert abs(p255.r - 128) <= 1 and p255.g == 0 and p255.b == 0


def test_apply_colormap_auto_range():
    # Image with small range 10..20
    img = Image(1, 2, dtype=zignal.Gray)
    img[0, 0] = 10
    img[0, 1] = 20

    # Auto-range should map 10->min (Blue) and 20->max (Red) in Jet
    colored = img.apply_colormap(Colormap.jet())

    p0 = colored[0, 0].item()  # Should be lowest color (dark blue)
    p1 = colored[0, 1].item()  # Should be highest color (dark red)

    assert p0.b > 100
    assert p1.r > 100
