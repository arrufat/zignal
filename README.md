# Zignal
[![tests](https://github.com/arrufat/zignal/actions/workflows/test.yml/badge.svg)](https://github.com/arrufat/zignal/actions/workflows/test.yml)
[![docs](https://github.com/arrufat/zignal/actions/workflows/documentation.yml/badge.svg)](https://github.com/arrufat/zignal/actions/workflows/documentation.yml)
[![PyPI version](https://badge.fury.io/py/zignal-processing.svg)](https://badge.fury.io/py/zignal-processing)

Zignal is a zero-dependency image processing library heavily inspired by the amazing [dlib](https://dlib.net).
**Originally developed at [B Factory, Inc](https://www.bfactory.ai/), it is now an independent open-source project.**

## Status

Zignal is under active development and powers production workloads at [Ameli](https://ameli.co.kr/).
The API continues to evolve, so expect occasional breaking changes between minor releases.

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

## Features

- **PCA** - Principal Component Analysis
- **Color spaces** - RGB, HSL, HSV, Lab, XYZ, Oklab, Oklch conversions
- **Matrix operations** - Linear algebra functions and SVD
- **Geometry** - Points, rectangles, transforms, convex hull
- **Image I/O** - Load and save PNG/JPEG images with in-house codecs
- **Image processing** - Resize, rotate, crop, blur, sharpen, threshold, morphology
- **Canvas API** - Lines, circles, polygons, Bézier curves with antialiasing
- **Fonts** - Bitmap font rendering, BDF/PCF loading, and Unicode range filters
- **Compression** - DEFLATE, zlib, gzip, and LZ77 bitstream primitives
- **Terminal graphics** - Kitty and sixel with capability detection utilities
- **Optimization** - Hungarian assignment solver for cost/profit matrices

## Motivation

<img src="https://github.com/arrufat/zignal/blob/master/assets/liza.jpg" width=400>

This library is used by [Ameli](https://ameli.co.kr/) for their makeup virtual try on.

## Sponsors

Special thanks to **[B Factory, Inc](https://www.bfactory.ai/)**, the **Founding Sponsor** of Zignal.
They originally developed this library and graciously transferred ownership to the community to ensure its long-term maintenance and growth.

<br></br>
[![Star History Chart](https://api.star-history.com/svg?repos=arrufat/zignal&type=Date)](https://www.star-history.com/#arrufat/zignal&Date)
