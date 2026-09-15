# Zignal
[![tests](https://github.com/arrufat/zignal/actions/workflows/test.yml/badge.svg)](https://github.com/arrufat/zignal/actions/workflows/test.yml)
[![docs](https://github.com/arrufat/zignal/actions/workflows/documentation.yml/badge.svg)](https://github.com/arrufat/zignal/actions/workflows/documentation.yml)
[![PyPI version](https://badge.fury.io/py/zignal-processing.svg)](https://badge.fury.io/py/zignal-processing)

Zignal is a zero-dependency image processing library inspired by [dlib](https://dlib.net).

## Features

Zignal covers the building blocks of an image processing pipeline in a single dependency:

- **Images:** pure-Zig PNG, JPEG, BMP and GIF codecs, geometric transforms, filters, color spaces, enhancement and drawing with an antialiased canvas, bitmap and vector fonts, and terminal graphics.
- **Vision:** feature detection and matching, edge detection, Hough transform, QR codes, style transfer and quality metrics.
- **Math:** matrices and decompositions, geometry, statistics, PCA, global optimization and clustering.
- **Parallelism:** heavy operations run on a thread pool through `std.Io` and give byte-identical results when run serially.
- **Platforms:** native Zig, Python bindings and WASM for the web.

See the [documentation](https://arrufat.github.io/zignal/) for the full API.

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

Zignal includes a command-line interface to display images in the terminal, inspect them, resize, blur, detect edges, tile them into a grid, apply style transfer, encode and decode QR codes, compare them with visual diffs and quality metrics, and chain operations into pipelines.

```bash
# Build the CLI
zig build

# List the available commands
zig-out/bin/zignal help

# Show the options of a specific command
zig-out/bin/zignal help <command>
```

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
- [QR code](https://arrufat.github.io/zignal/examples/qrcode.html) - Encode text into QR codes and decode them from your camera or images
- [Image codec playground](https://arrufat.github.io/zignal/examples/codec-playground.html) - Inspect how an image is encoded and re-encode it with the PNG, JPEG, BMP and GIF codecs


## Sponsors

Special thanks to **[B Factory, Inc](https://www.bfactory.ai/)**, the **Founding Sponsor** of Zignal.
I originally developed this library internally for [Ameli](https://ameli.co.kr/)'s virtual makeup try-on system,
and B Factory graciously transferred ownership to the community to ensure its long-term maintenance and growth.

## Star History

<a href="https://www.star-history.com/?type=date&repos=arrufat%2Fzignal">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=arrufat/zignal&type=date&theme=dark&legend=top-left&sealed_token=mrDU-4e_6lnlpXw5h8vK9rHyQgFuQfV6l1IPzXRzzTKwqmWrL77iYYoBkTBMZ7uSTfqkazS9hK3y6gSAaa9pLFMzORK3PjjC9A4pcRipvC49UtXf8_J5XSa2rAcuF7FeS53-HoNoXJsyv-4mBhoW7LPoS2ED93sdnA1r-7EfUfPXrKCJBBsZFJ1yEurR" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=arrufat/zignal&type=date&legend=top-left&sealed_token=mrDU-4e_6lnlpXw5h8vK9rHyQgFuQfV6l1IPzXRzzTKwqmWrL77iYYoBkTBMZ7uSTfqkazS9hK3y6gSAaa9pLFMzORK3PjjC9A4pcRipvC49UtXf8_J5XSa2rAcuF7FeS53-HoNoXJsyv-4mBhoW7LPoS2ED93sdnA1r-7EfUfPXrKCJBBsZFJ1yEurR" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=arrufat/zignal&type=date&legend=top-left&sealed_token=mrDU-4e_6lnlpXw5h8vK9rHyQgFuQfV6l1IPzXRzzTKwqmWrL77iYYoBkTBMZ7uSTfqkazS9hK3y6gSAaa9pLFMzORK3PjjC9A4pcRipvC49UtXf8_J5XSa2rAcuF7FeS53-HoNoXJsyv-4mBhoW7LPoS2ED93sdnA1r-7EfUfPXrKCJBBsZFJ1yEurR" />
 </picture>
</a>
