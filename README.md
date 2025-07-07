# Zignal
[![test](https://github.com/bfactory-ai/zignal/actions/workflows/test.yml/badge.svg)](https://github.com/bfactory-ai/zignal/actions/workflows/test.yml)
[![documentation](https://github.com/bfactory-ai/zignal/actions/workflows/documentation.yml/badge.svg)](https://github.com/bfactory-ai/zignal/actions/workflows/documentation.yml)

<img src="https://github.com/bfactory-ai/zignal/blob/master/assets/liza.jpg" width=400>

Zignal is an image processing library heavily inspired by the amazing [dlib](http://dlib.net).

## Disclaimer

This library is in early stages of development and being used internally.
As a result, the API might change often.

## Installation

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

## Motivation

This library is used by [Ameli](https://ameli.co.kr/) for their makeup virtual try on.

## Example

```zig
const std = @import("std");
const zignal = @import("zignal");
const Canvas = zignal.Canvas;
const Image = zignal.Image;
const Rgba = zignal.color.Rgba;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Create a 800x600 RGBA image
    var image: Image(Rgba) = try .initAlloc(allocator, 600, 800);
    defer image.deinit(allocator);
    @memset(image.data, Rgba.white);

    // Create a drawing canvas
    const canvas: Canvas(Rgba) = .init(image, allocator);

    // Draw shapes
    const red: Rgba = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    canvas.drawLine(.{.x = 50, .y = 50}, .{.x = 750, .y = 100}, red, 5, .soft);
    canvas.drawCircle(.{.x = 400, .y = 300}, 100, red, 3, .soft);
}
```

## Features

Initially, the features in this library are the ones required to get the virtual try on for makeup working.
However, we hope that it can be a foundation from which we can build a high quality image processing library, collaboratively.

Current features include:

- color space conversions
- simple matrix struct with common linear algebra operations
- singular value decomposition (SVD) ported from dlib
- geometry
  - points and rectangles
  - projective, affine and similarity transforms
  - convex hull
- simple image struct with common operations
  - resize
  - rotate
  - crop
  - blur
  - sharpen
  - views (called `sub_image` in dlib or `roi` in OpenCV.)
- Canvas drawing API with consistent parameter ordering
  - lines with variable width and antialiasing
  - circles (filled and outlined) with soft edges
  - polygons (filled and outlined)
  - rectangles with customizable borders
  - Bézier curves (quadratic and cubic) with adaptive subdivision
  - spline polygons with tension control for soft curved shapes
  - multiple drawing modes: fast (hard edges) and soft (antialiased edges)

## Examples

One of the greatest things about dlib is the large amount of examples illustrating how to use many of that library features.
I plan to showcase most of the features of this library as simple HTML/JS + Wasm examples, which can be accessed from [here](https://bfactory-ai.github.io/zignal/examples/).

Currently, there are examples for:
- [Color space conversions](https://bfactory-ai.github.io/zignal/examples/colorspaces.html)
- [Face alignment](https://bfactory-ai.github.io/zignal/examples/face-alignment.html)
- [Perlin noise generation](https://bfactory-ai.github.io/zignal/examples/perlin-noise.html)
- [Seam carving](https://bfactory-ai.github.io/zignal/examples/seam-carving.html)

## Acknowledgements

First of all, this project would not have been possible without the existence of [dlib](http://dlib.net).
In fact, the first version of the virtual makeup try on was written in C++ with dlib and Emscripten.
However, we decided to give Zig a go, even if that meant rewriting the world, but we have no dependencies now.

Finally, [B factory, Inc](https://www.bfactory.ai/), which is my employer and graciously agreed to release this library to the public.
