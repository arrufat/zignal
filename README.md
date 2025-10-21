# Zignal
[![tests](https://github.com/bfactory-ai/zignal/actions/workflows/test.yml/badge.svg)](https://github.com/bfactory-ai/zignal/actions/workflows/test.yml)
[![docs](https://github.com/bfactory-ai/zignal/actions/workflows/documentation.yml/badge.svg)](https://github.com/bfactory-ai/zignal/actions/workflows/documentation.yml)
[![PyPI version](https://badge.fury.io/py/zignal-processing.svg)](https://badge.fury.io/py/zignal-processing)

Zignal is a zero-dependency image processing library heavily inspired by the amazing [dlib](https://dlib.net).

## Status

Zignal is under active development and powers production workloads at [Ameli](https://ameli.co.kr/).
The API continues to evolve, so expect occasional breaking changes between minor releases.

## Installation

### Zig

```console
zig fetch --save git+https://github.com/bfactory-ai/zignal
```

Then, in your `build.zig`
```zig
const zignal = b.dependency("zignal", .{ .target = target, .optimize = optimize });
// And assuming that your b.addExecutable `exe`:
exe.root_module.addImport("zignal", zignal.module("zignal"));
// If you're creating a `module` using b.createModule, then:
module.addImport("zignal", zignal.module("zignal"));
```

[Examples](examples) | [Documentation](https://bfactory-ai.github.io/zignal/)

### Python

```console
pip install zignal-processing
```

Requires Python 3.10+, no external dependencies

<img src="./assets/python_print.gif" width=600>

[Bindings](bindings/python) | [PyPI Package](https://pypi.org/project/zignal-processing/) | [Documentation](https://bfactory-ai.github.io/zignal/python/zignal.html)

## Examples

[Interactive demos](https://bfactory-ai.github.io/zignal/examples) showcasing Zignal's capabilities:

- [Color space conversions](https://bfactory-ai.github.io/zignal/examples/colorspaces.html) - Convert between RGB, HSL, Lab, Oklab, and more
- [Face alignment](https://bfactory-ai.github.io/zignal/examples/face-alignment.html) - Facial landmark detection and alignment
- [Perlin noise generation](https://bfactory-ai.github.io/zignal/examples/perlin-noise.html) - Procedural texture generation
- [Seam carving](https://bfactory-ai.github.io/zignal/examples/seam-carving.html) - Content-aware image resizing
- [Feature distribution matching](https://bfactory-ai.github.io/zignal/examples/fdm.html) - Statistical color transfer
- [White balance](https://bfactory-ai.github.io/zignal/examples/white-balance.html) - Automatic color correction
- [Feature matching](https://bfactory-ai.github.io/zignal/examples/feature_matching.html) - ORB feature detection and matching between images
- [Metrics analyzer](https://bfactory-ai.github.io/zignal/examples/metrics.html) - PSNR and SSIM comparison for reference vs. distorted images

## Features

- **PCA** - Principal Component Analysis
- **Color spaces** - RGB, HSL, HSV, Lab, XYZ, Oklab, Oklch conversions
- **Matrix operations** - Linear algebra functions and SVD
- **Geometry** - Points, rectangles, transforms, convex hull
- **Image I/O** - Load and save PNG/JPEG images without in-house codecs
- **Image processing** - Resize, rotate, crop, blur, sharpen, threshold, morphology
- **Canvas API** - Lines, circles, polygons, Bézier curves with antialiasing
- **Fonts** - Bitmap font rendering, BDF/PCF loading, and Unicode range filters
- **Compression** - DEFLATE, zlib, gzip, and LZ77 bitstream primitives
- **Terminal graphics** - Kitty and sixel with capability detection utilities
- **Optimization** - Hungarian assignment solver for cost/profit matrices

## Motivation

<img src="https://github.com/bfactory-ai/zignal/blob/master/assets/liza.jpg" width=400>

This library is used by [Ameli](https://ameli.co.kr/) for their makeup virtual try on.

## Acknowledgements

First of all, this project would not have been possible without the existence of [dlib](http://dlib.net).
In fact, the first version of the virtual makeup try on was written in C++ with dlib and Emscripten.
However, we decided to give Zig a go, even if that meant rewriting everything. As a result, we have no dependencies now.

Finally, [B factory, Inc](https://www.bfactory.ai/), which is my employer and graciously agreed to release this library to the public.

<br></br>
[![Star History Chart](https://api.star-history.com/svg?repos=bfactory-ai/zignal&type=Date)](https://www.star-history.com/#bfactory-ai/zignal&Date)
