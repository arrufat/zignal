//! 2D canvas drawing system for raster images.
//!
//! Supports antialiased (.soft) and aliased (.fast) rendering of primitives:
//! lines, circles, arcs, rectangles, polygons, Bézier curves, splines, and text.

// Re-export public types
pub const Canvas = @import("canvas/Canvas.zig").Canvas;
pub const DrawMode = @import("canvas/Canvas.zig").DrawMode;
pub const DrawOptions = @import("canvas/Canvas.zig").DrawOptions;
pub const FillRule = @import("canvas/Canvas.zig").FillRule;

// Run all tests
test {
    _ = @import("canvas/Canvas.zig");
    _ = @import("canvas/tests/regression.zig");
    _ = @import("canvas/tests/drawing.zig");
    _ = @import("canvas/tests/arcs.zig");
    _ = @import("canvas/tests/blending.zig");
}
