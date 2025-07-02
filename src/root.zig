//! Zignal is an image processing library inspired by [dlib](http://dlib.net).
//! Source code available on [GitHub](https://github.com/bfactory-ai/zignal).

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

pub const Canvas = @import("canvas.zig").Canvas;
pub const point = @import("point.zig");
const geometry = @import("geometry.zig");
pub const Rectangle = geometry.Rectangle;
pub const AffineTransform = geometry.AffineTransform;
pub const ProjectiveTransform = geometry.ProjectiveTransform;
pub const SimilarityTransform = geometry.SimilarityTransform;
pub const ConvexHull = geometry.ConvexHull;
pub const Image = @import("image.zig").Image;
pub const Matrix = @import("matrix.zig").Matrix;
pub const meta = @import("meta.zig");
pub const perlin = @import("perlin.zig");
pub const Point2d = point.Point2d;
pub const Point3d = point.Point3d;
pub const svd = @import("svd.zig").svd;

const png = @import("png.zig");
pub const savePng = png.savePng;
pub const loadPng = png.loadPng;
