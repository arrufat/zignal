//! Image processing module
//!
//! This module provides a unified interface to image processing functionality.
//! The main Image struct supports generic pixel types and provides operations for:
//! - Loading and saving images (PNG, JPEG)
//! - Terminal display with multiple formats (ANSI, Braille, Sixel, Kitty)
//! - Geometric transforms (resize, rotate, crop, flip)
//! - Filters (blur, sharpen, edge detection)
//! - Views for zero-copy sub-image operations

// Re-export all public types
pub const Image = @import("image/image.zig").Image;
pub const PixelIterator = @import("image/PixelIterator.zig").PixelIterator;
pub const ImageFormat = @import("image/format.zig").ImageFormat;
pub const DisplayFormat = @import("image/display.zig").DisplayFormat;
pub const InterpolationMethod = @import("image/interpolation.zig").InterpolationMethod;

// Run all tests
test {
    _ = @import("image/image.zig");
    _ = @import("image/PixelIterator.zig");
    _ = @import("image/format.zig");
    _ = @import("image/display.zig");
    _ = @import("image/tests/integral.zig");
    _ = @import("image/tests/filters.zig");
    _ = @import("image/tests/transforms.zig");
    _ = @import("image/tests/display.zig");
    _ = @import("image/tests/interpolation.zig");
    _ = @import("image/tests/letterbox.zig");
}
