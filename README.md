# Zignal
[![tests](https://github.com/arrufat/zignal/actions/workflows/test.yml/badge.svg)](https://github.com/arrufat/zignal/actions/workflows/test.yml)
[![docs](https://github.com/arrufat/zignal/actions/workflows/documentation.yml/badge.svg)](https://github.com/arrufat/zignal/actions/workflows/documentation.yml)
[![PyPI version](https://badge.fury.io/py/zignal-processing.svg)](https://badge.fury.io/py/zignal-processing)

Zignal is a zero-dependency image processing library inspired by [dlib](https://dlib.net).

## Features

- **Core Math:** Matrices (`SMatrix`, `Matrix`, SVD), PCA, ND Geometry (SIMD Points, affine/projective transforms, convex hull), Statistics, Optimization.
- **Computer Vision:** Feature detection and matching (FAST, ORB), Edge detection (Shen-Castan), Hough Transform, Feature Distribution Matching (style transfer).
- **Image Processing:** Spatial transforms (resize, crop, rotate), morphology, convolution filters (blur, sharpen), thresholding, advanced Color Spaces (Lab, Oklab, Oklch, Xyb, Lms, etc.), Perlin noise generation.
- **I/O & Graphics:** Pure-Zig PNG/JPEG codecs, Canvas API (antialiasing, Bézier curves), Bitmap/PCF Fonts, Colormaps, Terminal graphics (Kitty/Sixel).
- **Platform Support:** Native Zig, first-class Python bindings, and WASM compilation for the web.

## Status

Zignal is under active development and the API continues to evolve.
Expect occasional breaking changes between minor releases.

<img src="https://github.com/arrufat/zignal/blob/master/assets/liza.jpg" width=400>

## Installation

### Zig

```console
zig fetch --save git+https://github.com/arrufat/zignal
```

Then, in your `build.zig`
```zig
const zignal = b.dependency("zignal", .{ .target = target, .optimize = optimize });
// And assuming that your b.addExecutable `exe`:
exe.root_module.addImport("zignal", zignal.module("zignal"));
// If you're creating a `module` using b.createModule, then:
module.addImport("zignal", zignal.module("zignal"));
```

[Examples](examples) | [Documentation](https://arrufat.github.io/zignal/)

### Python

```console
pip install zignal-processing
```

Requires Python 3.10+, no external dependencies

<img src="./assets/python_print.gif" width=600>

[Bindings](bindings/python) | [PyPI Package](https://pypi.org/project/zignal-processing/) | [Documentation](https://arrufat.github.io/zignal/python/zignal.html)

### CLI

Zignal includes a command-line interface for common operations.

```bash
# Build the CLI
zig build

# Run commands
zig-out/bin/zignal <command> [options]
```

**Available commands:**
- `display` - View images in the terminal (supports Kitty, Sixel, etc.)
- `resize` - Resize images with various filters
- `tile` - Combine multiple images into a grid
- `fdm` - Apply style transfer (Feature Distribution Matching)
- `info` - Show image metadata

## Examples

[Interactive demos](https://arrufat.github.io/zignal/examples) showcasing Zignal's capabilities:

- [Color space conversions](https://arrufat.github.io/zignal/examples/colorspaces.html) - Convert between RGB, HSL, Lab, Oklab, and more
- [Face alignment](https://arrufat.github.io/zignal/examples/face-alignment.html) - Facial landmark detection and alignment
- [Perlin noise generation](https://arrufat.github.io/zignal/examples/perlin-noise.html) - Procedural texture generation
- [Seam carving](https://arrufat.github.io/zignal/examples/seam-carving.html) - Content-aware image resizing
- [Feature distribution matching](https://arrufat.github.io/zignal/examples/fdm.html) - Statistical color transfer
- [Contrast enhancement](https://arrufat.github.io/zignal/examples/contrast-enhancement.html) - Autocontrast and histogram equalization side-by-side
- [White balance](https://arrufat.github.io/zignal/examples/white-balance.html) - Automatic color correction
- [Feature matching](https://arrufat.github.io/zignal/examples/feature_matching.html) - ORB feature detection and matching between images
- [Hough transform animation](https://arrufat.github.io/zignal/examples/hough-animation.html) - Real-time visualization of line detection
- [Metrics analyzer](https://arrufat.github.io/zignal/examples/metrics.html) - PSNR and SSIM comparison for reference vs. distorted images
- [Global optimization](https://arrufat.github.io/zignal/examples/global-optimization.html) - Type a JavaScript function and watch the MaxLIPO+TR optimizer search for its optimum


## Sponsors

Special thanks to **[B Factory, Inc](https://www.bfactory.ai/)**, the **Founding Sponsor** of Zignal.
I originally developed this library internally for [Ameli](https://ameli.co.kr/)'s virtual makeup try-on system,
and B Factory graciously transferred ownership to the community to ensure its long-term maintenance and growth.

<br></br>
[![Star History Chart](https://api.star-history.com/svg?repos=arrufat/zignal&type=Date)](https://www.star-history.com/#arrufat/zignal&Date)
