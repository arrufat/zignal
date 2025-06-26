//! Zignal is an image processing library inspired by [dlib](http://dlib.net).
//! Source code available on [GitHub](https://github.com/bfactory-ai/zignal).

pub const color = @import("color.zig");
pub const Rgb = color.Rgb;
pub const Rgba = color.Rgba;
pub const Hsl = color.Hsl;
pub const Hsv = color.Hsv;
pub const Xyz = color.Xyz;
pub const Lab = color.Lab;
pub const Lms = color.Lms;
pub const Oklab = color.Oklab;
pub const Xyb = color.Xyb;
const draw = @import("draw.zig");
pub const drawCircle = draw.drawCircle;
pub const drawCircleFast = draw.drawCircleFast;
pub const drawCross = draw.drawCross;
pub const drawLine = draw.drawLine;
pub const drawLineFast = draw.drawLineFast;
pub const drawRectangle = draw.drawRectangle;
pub const drawPolygon = draw.drawPolygon;
pub const fillPolygon = draw.fillPolygon;
pub const drawBezierCurve = draw.drawBezierCurve;
pub const drawSmoothPolygon = draw.drawSmoothPolygon;
pub const fillSmoothPolygon = draw.fillSmoothPolygon;
pub const geometry = @import("geometry.zig");
pub const Rectangle = geometry.Rectangle;
pub const AffineTransform = geometry.AffineTransform;
pub const ProjectiveTransform = geometry.ProjectiveTransform;
pub const SimilarityTransform = geometry.SimilarityTransform;
pub const ConvexHull = geometry.ConvexHull;
pub const Image = @import("image.zig").Image;
pub const Matrix = @import("matrix.zig").Matrix;
pub const meta = @import("meta.zig");
pub const perlin = @import("perlin.zig");
pub const Point2d = @import("point.zig").Point2d;
pub const Point3d = @import("point.zig").Point3d;
pub const svd = @import("svd.zig").svd;
