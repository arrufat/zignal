//! Zignal is an image processing library inspired by dlib.

const std = @import("std");

pub const colorspace = @import("colorspace.zig");
pub const Rgb = colorspace.Rgb;
pub const Rgba = colorspace.Rgba;
pub const Hsl = colorspace.Hsl;
pub const Hsv = colorspace.Hsv;
pub const Lab = colorspace.Lab;

pub const Point2d = @import("point.zig").Point2d;
pub const Point3d = @import("point.zig").Point3d;

pub const Matrix = @import("matrix.zig").Matrix;

pub const Image = @import("image.zig").Image;

pub const svd = @import("svd.zig").svd;

const geometry = @import("geometry.zig");
pub const Rectangle = geometry.Rectangle;
pub const ProjectiveTransform = geometry.ProjectiveTransform;
pub const SimilarityTransform = geometry.SimilarityTransform;
pub const ConvexHull = geometry.ConvexHull;

const draw = @import("draw.zig");
pub const drawCircle = draw.drawCircle;
pub const drawCircleFast = draw.drawCircleFast;
pub const drawCross = draw.drawCross;
pub const drawLine = draw.drawLine;
pub const drawLineFast = draw.drawLineFast;
pub const drawRectangle = draw.drawRectangle;
pub const drawPolygon = draw.drawPolygon;
pub const fillPolygon = draw.fillPolygon;
pub const meta = @import("meta.zig");
