//! Geometry module - All geometric types and utilities
//!
//! This module provides a unified interface to all geometric types in the system.
//! Each geometric type is implemented as a separate file using Zig's file-as-struct pattern.

// Import points from geometry subdirectory
const points = @import("geometry/Point.zig");
pub const Point = points.Point;

// Import Rectangle
pub const Rectangle = @import("geometry/Rectangle.zig").Rectangle;

// Import all transforms
const transforms = @import("geometry/transforms.zig");
pub const SimilarityTransform = transforms.SimilarityTransform;
pub const AffineTransform = transforms.AffineTransform;
pub const ProjectiveTransform = transforms.ProjectiveTransform;

// Import ConvexHull
pub const ConvexHull = @import("geometry/ConvexHull.zig").ConvexHull;

// Import primitive functions
const primitives = @import("geometry/primitives.zig");
pub const pointInTriangle = primitives.pointInTriangle;
pub const findBarycenter = primitives.findBarycenter;

// Re-export tests to ensure everything compiles
test {
    _ = points;
    _ = @import("geometry/Rectangle.zig");
    _ = transforms;
    _ = @import("geometry/ConvexHull.zig");
    _ = primitives;
}
