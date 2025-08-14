//! Canvas drawing module
//!
//! This module provides a Canvas for drawing various shapes and lines on images.
//! The Canvas supports:
//! - Lines with configurable width and antialiasing
//! - Circles and arcs (outline and filled)
//! - Rectangles and polygons
//! - Bezier curves (quadratic and cubic)
//! - Spline curves
//!
//! All drawing operations support both fast (aliased) and soft (antialiased) rendering modes.

// Re-export public types
pub const Canvas = @import("canvas/Canvas.zig").Canvas;
pub const DrawMode = @import("canvas/Canvas.zig").DrawMode;

// Run all tests
test {
    _ = @import("canvas/Canvas.zig");
    _ = @import("canvas/tests/regression.zig");
    _ = @import("canvas/tests/drawing.zig");
    _ = @import("canvas/tests/arcs.zig");
}
