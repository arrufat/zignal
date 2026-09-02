//! # Zignal - Zero-Dependency Image Processing Library
//!
//! Zignal is a comprehensive image processing library written in Zig, heavily inspired by
//! [dlib](https://dlib.net). It's designed to be fast, memory-efficient, and suitable for
//! production use in computer vision applications.
//!
//! ## Features
//!
//! - **Image Operations**: Load, save, manipulate, and transform images
//! - **Drawing & Canvas**: Lines, circles, polygons, Bézier curves with antialiasing
//! - **Color Spaces**: RGB, HSL, HSV, XYZ, Lab, LCh, LMS, Oklab, Oklch, XYB conversions
//! - **Geometry**: 2D/3D points, rectangles, transforms (affine, projective, similarity)
//! - **Matrix Operations**: Linear algebra with SVD decomposition support
//! - **Computer Vision**: Feature distribution matching, convex hull algorithms, PCA
//! - **Procedural Generation**: Perlin noise for textures and effects
//!
//! ## Architecture
//!
//! The library follows a zero-allocation philosophy where possible, with most operations
//! working in-place or with pre-allocated buffers. All major components support custom
//! allocators for fine-grained memory control.
//!
//! ## Examples
//!
//! Interactive examples and demos are available at:
//! [https://arrufat.github.io/zignal/examples/](https://arrufat.github.io/zignal/examples/)
//!
//! ## Source Code
//!
//! Available on [GitHub](https://github.com/arrufat/zignal).

pub const version = @import("build_options").version;

pub const Canvas = @import("canvas.zig").Canvas;
/// Drawing options, modes and fill rules for `Canvas`.
pub const canvas = @import("canvas.zig");

const color = @import("color.zig");
pub const convertColor = color.convertColor;
pub const isColor = color.isColor;
pub const Blending = color.Blending;
pub const ColorSpace = color.ColorSpace;
pub const Rgb = color.Rgb;
pub const Rgba = color.Rgba;
pub const Gray = color.Gray;
pub const Hsl = color.Hsl;
pub const Hsv = color.Hsv;
pub const Xyz = color.Xyz;
pub const Lab = color.Lab;
pub const Lch = color.Lch;
pub const Lms = color.Lms;
pub const Oklab = color.Oklab;
pub const Oklch = color.Oklch;
pub const Xyb = color.Xyb;
pub const Ycbcr = color.Ycbcr;

/// Points, rectangles, transforms (similarity, affine, projective) and convex hulls.
pub const geometry = @import("geometry.zig");
pub const Point = geometry.Point;
pub const Rectangle = geometry.Rectangle;

pub const Image = @import("image.zig").Image;
pub const Animation = @import("image.zig").Animation;
/// Image options, formats, filters, colormaps, quantization and dithering.
pub const image = @import("image.zig");

/// Terminal graphics detection and protocol encoders (Sixel, Kitty, iTerm2).
pub const terminal = @import("terminal.zig");

const codecs = @import("codecs.zig");
pub const png = codecs.png;
pub const jpeg = codecs.jpeg;
pub const bmp = codecs.bmp;
pub const gif = codecs.gif;
pub const jxl = codecs.jxl;
pub const webp = codecs.webp;

/// QR code encoding and decoding (ISO/IEC 18004).
pub const qrcode = @import("qrcode.zig");

/// Dynamic and compile-time sized matrices, decompositions and `Error`.
pub const matrix = @import("matrix.zig");
pub const SMatrix = matrix.SMatrix;
pub const Matrix = matrix.Matrix;
pub const gpu = @import("gpu.zig");
pub const meta = @import("meta.zig");

/// 3D Perlin noise.
pub const perlin = @import("perlin.zig");

pub const FeatureDistributionMatching = @import("fdm.zig").FeatureDistributionMatching;

/// Font loading, text layout, and typography rendering.
pub const font = @import("font.zig");
pub const Font = font.Font;

/// Principal Component Analysis (PCA) for dimensionality reduction.
pub const Pca = @import("pca.zig").Pca;

/// Feature detection, description, and matching (FAST, ORB, brute-force matcher).
pub const features = @import("features.zig");

/// Unsupervised graph-based clustering (Chinese Whispers algorithm).
pub const clustering = @import("clustering.zig");

/// Optimization algorithms (assignment problem, MaxLIPO global optimization).
pub const optimization = @import("optimization.zig");

/// Running and covariance statistics for streaming data.
pub const stats = @import("stats.zig");

test {
    _ = @import("color.zig");
    _ = @import("image.zig");
    _ = @import("geometry.zig");
    _ = @import("matrix.zig");
    _ = @import("perlin.zig");
    _ = @import("canvas.zig");
    _ = @import("codecs.zig");
    _ = @import("fdm.zig");
    _ = @import("pca.zig");
    _ = @import("terminal.zig");
    _ = @import("font.zig");
    _ = @import("features.zig");
    _ = @import("clustering.zig");
    _ = @import("optimization.zig");
    _ = @import("qrcode.zig");
    _ = @import("meta.zig");
    _ = @import("stats.zig");
    _ = @import("dynlib.zig");
    if (@import("build_options").gpu) _ = @import("gpu.zig");
}
