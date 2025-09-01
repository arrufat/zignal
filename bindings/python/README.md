# Zignal Python Bindings

Zero‑dependency image processing primitives in Zig, exposed to Python.

## Install

```console
pip install zignal-processing
```

Docs: https://bfactory-ai.github.io/zignal/python/zignal.html

## Quickstart

```python
import zignal

# Load / create
img = zignal.Image.load("photo.jpg")                # PNG/JPEG
img = zignal.Image(480, 640, color=(30, 144, 255))  # RGB fill

# Process
img = img.gaussian_blur(1.5)
img = img.resize(0.5, zignal.InterpolationMethod.BILINEAR)

# Pixels and NumPy interop with shared memory
img[10, 20] = zignal.Hsv(60, 100, 100)
arr = img.to_numpy()                 # (rows, cols, 3) uint8 view
img2 = zignal.Image.from_numpy(arr)  # zero‑copy with shared memory

# Draw
canvas = img.canvas()
canvas.draw_line((10, 10), (100, 60), zignal.Rgb(255, 0, 0))

# Terminal preview (auto: kitty → sixel → sgr)
print(f"{img:auto}")
print(f"{img2:auto}")  # also modified

# Save
img.save("out.png")
```

## Highlights

- Image ops: load/save, resize/warp, crop/letterbox, extract/insert, blur/sharpen, flips
- Pixels: direct get/set; slice assignment; NumPy zero‑copy to/from
- Colors: 12 spaces (Rgb/Rgba, Hsl/Hsv, Lab/Lch, Xyz/Xyb, Oklab/Oklch, Lms, Ycbcr)
- Canvas: lines, circles, polygons, text via bitmap BDF/PCF fonts
- Geometry: Rectangle, ConvexHull, SimilarityTransform, AffineTranform, ProjectiveTransform
- Matrix: float64 matrices with NumPy bridge
- Terminal: SGR, Braille, Sixel, Kitty
- Advanced: FeatureDistributionMatching
- Core: Zig, no external dependencies

## Development

- Build native extension: `zig build python-bindings`
- Generate stubs (`.pyi`): `zig build python-stubs`
- Editable install: `cd bindings/python && uv venv && uv pip install -e .`
- Tests: `uv run pytest -q`

If Python headers/libs aren’t auto‑detected during build, set:
`PYTHON_INCLUDE_DIR`, `PYTHON_LIBS_DIR`, `PYTHON_LIB_NAME`.

## License

MIT
