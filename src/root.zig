//! Zignal is an image processing library inspired by [dlib](http://dlib.net).
//! Source code available on [GitHub](https://github.com/bfactory-ai/zignal).

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
pub const Lms = color.Lms;
pub const Oklab = color.Oklab;
pub const Xyb = color.Xyb;

const geometry = @import("geometry.zig");
pub const Rectangle = geometry.Rectangle;
pub const AffineTransform = geometry.AffineTransform;
pub const ProjectiveTransform = geometry.ProjectiveTransform;
pub const SimilarityTransform = geometry.SimilarityTransform;
pub const ConvexHull = geometry.ConvexHull;
pub const Image = @import("image.zig").Image;

const matrix = @import("matrix.zig");
pub const SMatrix = matrix.SMatrix;
pub const Matrix = matrix.Matrix;
pub const OpsBuilder = matrix.OpsBuilder;
pub const meta = @import("meta.zig");
pub const perlin = @import("perlin.zig");

const png = @import("png.zig");
pub const savePng = png.savePng;
pub const loadPng = png.loadPng;

pub const Point2d = geometry.Point2d;
pub const Point3d = geometry.Point3d;
pub const pointInTriangle = geometry.pointInTriangle;
pub const findBarycenter = geometry.findBarycenter;

pub const svd = @import("svd.zig").svd;
