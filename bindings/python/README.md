# Zignal Python Bindings

[![PyPI version](https://img.shields.io/pypi/v/zignal-processing.svg)](https://pypi.org/project/zignal-processing/) [![Python versions](https://img.shields.io/pypi/pyversions/zignal-processing.svg)](https://pypi.org/project/zignal-processing/) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/bfactory-ai/zignal/blob/main/LICENSE)

Zero-dependency image processing primitives written in Zig and packaged for Python.

## Key Features

- Image pipelines: load/save, resize/warp, crop/letterbox, extract/insert, blur/sharpen, flips
- Pixels: direct get/set, slice assignment, zero-copy NumPy views
- Colors: 12 color models (Rgb/Rgba, Hsl/Hsv, Lab/Lch, Xyz/Xyb, Oklab/Oklch, Lms, Ycbcr)
- Canvas: lines, circles, polygons, bitmap font text drawing
- Geometry: Rectangle, ConvexHull, Similarity/Affine/Projective transforms
- Terminal output: SGR, Braille, Sixel, Kitty
- All of the above backed by Zig with no dependencies

## Installation

- Python 3.10 or newer
- `pip install zignal-processing`

Prebuilt wheels are published for common platforms. If pip falls back to building from source, ensure `zig` is available on your PATH.

## Quickstart

```python
import zignal

# Load or create an image
img = zignal.Image.load("photo.jpg")                # PNG/JPEG
img = zignal.Image(480, 640, color=(30, 144, 255))  # RGB fill

# Process
img = img.gaussian_blur(1.5)
img = img.resize(0.5, zignal.InterpolationMethod.BILINEAR)

# Pixels and NumPy interop with shared memory
img[10, 20] = zignal.Hsv(60, 100, 100)
arr = img.to_numpy()                 # (rows, cols, 3) uint8 view
img2 = zignal.Image.from_numpy(arr)  # zero-copy with shared memory

# Draw
canvas = img.canvas()
canvas.draw_line((10, 10), (100, 60), zignal.Rgb(255, 0, 0))

# Terminal preview (auto: kitty -> sixel -> sgr)
print(f"{img:auto}")
print(f"{img2:auto}")  # also modified

# Save
img.save("out.png")
```

## Project Links

- Documentation: https://bfactory-ai.github.io/zignal/python/zignal.html
- Source code: https://github.com/bfactory-ai/zignal
- Issue tracker: https://github.com/bfactory-ai/zignal/issues

## Development

- Build native extension and `.pyi` stubs: `zig build python-bindings`
- Editable install: `cd bindings/python && uv venv && uv pip install -e .`
- Run tests: `uv run pytest -q`

If Python headers or libs are not auto-detected during build, set the environment variables `PYTHON_INCLUDE_DIR`, `PYTHON_LIBS_DIR`, and `PYTHON_LIB_NAME`.

## Binding New Functionality

See https://github.com/bfactory-ai/zignal/blob/main/BINDINGS_GUIDE.md for patterns and conventions to expose new Zignal APIs to Python (keyword lists, validators, enums, image wrapping, stubs).

## License

MIT
