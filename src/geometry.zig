//! Geometric primitives: N-dimensional points, axis-aligned rectangles,
//! 2D coordinate transforms (similarity, affine, projective), and convex hulls.

// Import points from geometry subdirectory
const points = @import("geometry/Point.zig");
pub const Point = points.Point;
pub const Orientation = points.Orientation;

// Import Rectangle
pub const Rectangle = @import("geometry/Rectangle.zig").Rectangle;

// Import all transforms
const transforms = @import("geometry/transforms.zig");
pub const SimilarityTransform = transforms.SimilarityTransform;
pub const AffineTransform = transforms.AffineTransform;
pub const ProjectiveTransform = transforms.ProjectiveTransform;

// Import ConvexHull
const convex_hull = @import("geometry/ConvexHull.zig");
pub const ConvexHull = convex_hull.ConvexHull;

// Re-export tests to ensure everything compiles
test {
    _ = points;
    _ = @import("geometry/Rectangle.zig");
    _ = transforms;
    _ = convex_hull;
}
