# Zignal Python Bindings

[![PyPI version](https://img.shields.io/pypi/v/zignal-processing.svg)](https://pypi.org/project/zignal-processing/) [![Python versions](https://img.shields.io/pypi/pyversions/zignal-processing.svg)](https://pypi.org/project/zignal-processing/) [![Downloads](https://static.pepy.tech/badge/zignal-processing)](https://pepy.tech/project/zignal-processing) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/bfactory-ai/zignal/blob/main/LICENSE)


Zero-dependency image processing primitives written in Zig and packaged for Python.

## Feature Overview

| Area | Highlights |
| --- | --- |
| **Images** | PNG/JPEG load/save, resize & warp, crop/letterbox, insert/extract, Gaussian/median filters, motion blur |
| **Pixels & Arrays** | Direct indexing/assignment, slice updates, zero-copy NumPy interop both directions |
| **Colors** | 12 color models (Rgb/Rgba, Hsl/Hsv, Lab/Lch, Xyz/Xyb, Oklab/Oklch, Lms, Ycbcr) with automatic conversion |
| **Canvas & Fonts** | Lines, arcs, splines, polygons, flood fills, bitmap font text rendering |
| **Geometry** | Rectangle algebra, convex hulls, similarity/affine/projective transforms |
| **Terminal Output** | SGR, Braille, Sixel, and Kitty renderers with automatic format negotiation |
| **Numerics** | Matrices with rich linear algebra, PCA, optimization (Hungarian), running statistics |

All functionality is implemented in Zig with no runtime dependencies, making the wheel lightweight and easy to vendor.

## Installation

```bash
pip install zignal-processing
```

- Python **3.10 – 3.14** (CPython)
- Prebuilt wheels ship for:
  - Linux (manylinux2014) `x86_64`, `aarch64`
  - macOS `x86_64` and `arm64`
  - Windows `x86_64`
- Building from source requires [Zig](https://ziglang.org/) 0.15.0 or newer available on your `PATH`.

If CPython headers/libraries are in a non-standard location, set `PYTHON_INCLUDE_DIR`, `PYTHON_LIBS_DIR`, and `PYTHON_LIB_NAME` before installing.

## Quickstart

```python
import numpy as np
import zignal

# Load or create an image
img = zignal.Image.load("photo.jpg")                 # PNG/JPEG
canvas = zignal.Image(480, 640, color=zignal.Rgb(30, 144, 255)).canvas()

# Draw & process
canvas.draw_circle((120, 160), 60, zignal.Rgba(255, 255, 255, 180), fill=True)
img = img.gaussian_blur(1.5)
img = img.resize(0.5, zignal.Interpolation.BILINEAR)

# Pixels + NumPy (shared memory views)
img[10, 20] = zignal.Hsv(60, 100, 100)
np_view = img.to_numpy()                   # (rows, cols, 3) uint8 view
np_view[..., 0] = np.clip(np_view[..., 0] + 32, 0, 255)  # modifies img in-place
img2 = zignal.Image.from_numpy(np_view)    # zero-copy back into Zig

# Streaming stats & procedural noise
stats = zignal.RunningStats()
for value in np_view.mean(axis=-1).flat:
    stats.add(float(value))
noise = zignal.perlin(0.2, 0.4, amplitude=1.2, frequency=2.5, octaves=4)
print(f"μ={stats.mean:.3f} σ={stats.std_dev:.3f} perlin={noise:.3f}")

# Terminal preview (auto: kitty → sixel → sgr fallback)
print(f"{img:auto}")

# Save
img.save("out.png")
```

## Documentation & Support

- Docs: https://bfactory-ai.github.io/zignal/python/zignal.html
- Source: https://github.com/bfactory-ai/zignal
- Issues: https://github.com/bfactory-ai/zignal/issues

## Development

```bash
zig build python-bindings          # build extension + stubs
cd bindings/python
uv venv && uv pip install -e .     # editable install
uv run pytest -q                   # run tests
```

## Contributing Bindings

Follow the [bindings guide](BINDINGS_GUIDE.md) for argument parsing helpers, enum registration, image ownership, and stub generation.

## License

MIT
