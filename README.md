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

The [interactive demos](https://arrufat.github.io/zignal/examples) run Zignal in the browser through WASM and showcase color spaces, face alignment, seam carving, feature matching, global optimization, QR codes and more.
Their sources live in the [examples](examples) directory alongside native Zig programs.

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
