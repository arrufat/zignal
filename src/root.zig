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
//! [https://bfactory-ai.github.io/zignal/examples/](https://bfactory-ai.github.io/zignal/examples/)
//!
//! ## Source Code
//!
//! Available on [GitHub](https://github.com/bfactory-ai/zignal).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Canvas = @import("canvas.zig").Canvas;
pub const DrawMode = @import("canvas.zig").DrawMode;

const color = @import("color.zig");
pub const convertColor = color.convertColor;
pub const isColor = color.isColor;
pub const Rgb = color.Rgb;
pub const Rgba = color.Rgba;
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

const geometry = @import("geometry.zig");
pub const Rectangle = geometry.Rectangle;
pub const AffineTransform = geometry.AffineTransform;
pub const ProjectiveTransform = geometry.ProjectiveTransform;
pub const SimilarityTransform = geometry.SimilarityTransform;
pub const ConvexHull = geometry.ConvexHull;

pub const Image = @import("image.zig").Image;

/// Load an image with automatic format detection (PNG, JPEG)
pub fn loadImage(comptime T: type, allocator: Allocator, file_path: []const u8) !Image(T) {
    return Image(T).load(allocator, file_path);
}
pub const ImageFormat = @import("image.zig").ImageFormat;
pub const DisplayFormat = @import("image.zig").DisplayFormat;

// Terminal support utilities
pub const TerminalSupport = @import("TerminalSupport.zig");

// Sixel graphics support
const sixel = @import("sixel.zig");
pub const imageToSixel = sixel.imageToSixel;
pub const isSixelSupported = sixel.isSixelSupported;
pub const SixelOptions = sixel.SixelOptions;
pub const PaletteMode = sixel.PaletteMode;
pub const DitherMode = sixel.DitherMode;

// Kitty graphics protocol
const kitty = @import("kitty.zig");
pub const imageToKitty = kitty.imageToKitty;
pub const isKittySupported = kitty.isKittySupported;
pub const KittyOptions = kitty.KittyOptions;

const png = @import("png.zig");
pub const savePng = png.savePng;
pub const loadPng = png.loadPng;
pub const jpeg = @import("jpeg.zig");
pub const loadJpeg = jpeg.loadJpeg;

const matrix = @import("matrix.zig");
pub const SMatrix = matrix.SMatrix;
pub const Matrix = matrix.Matrix;
pub const OpsBuilder = matrix.OpsBuilder;
pub const meta = @import("meta.zig");

const perlin_mod = @import("perlin.zig");
pub const perlin = perlin_mod.perlin;
pub const PerlinOptions = perlin_mod.PerlinOptions;

// New unified Point system with arbitrary dimensions and SIMD acceleration
const point = @import("geometry/Point.zig");
pub const Point = point.Point;
pub const Point1d = point.Point1d;
pub const Point2d = point.Point2d;
pub const Point3d = point.Point3d;
pub const Point4d = point.Point4d;
pub const makePoint = point.makePoint;

pub const pointInTriangle = geometry.pointInTriangle;
pub const findBarycenter = geometry.findBarycenter;

pub const svd = @import("svd.zig").svd;
pub const SvdMode = @import("svd.zig").SvdMode;
pub const SvdOptions = @import("svd.zig").SvdOptions;
pub const SvdResult = @import("svd.zig").SvdResult;

pub const featureDistributionMatch = @import("fdm.zig").featureDistributionMatch;

// PCA (Principal Component Analysis) system
const pca = @import("pca.zig");
pub const PrincipalComponentAnalysis = pca.PrincipalComponentAnalysis; // Legacy alias

// Color conversion utilities
pub const colorToPoint = pca.colorToPoint;
pub const pointToColor = pca.pointToColor;

// Image-to-points conversion functions
pub const imageToColorPoints = pca.imageToColorPoints;
pub const colorPointsToImage = pca.colorPointsToImage;
pub const imageToIntensityPoints = pca.imageToIntensityPoints;
pub const intensityPointsToImage = pca.intensityPointsToImage;
