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
pub const DisplayFormat = @import("image/display.zig").DisplayFormat;
pub const BorderMode = @import("image/filtering.zig").BorderMode;
pub const ImageFormat = @import("image/format.zig").ImageFormat;
pub const Image = @import("image/Image.zig").Image;
pub const InterpolationMethod = @import("image/interpolation.zig").InterpolationMethod;
pub const PixelIterator = @import("image/PixelIterator.zig").PixelIterator;

// Run all tests
test {
    _ = @import("image/Image.zig");
    _ = @import("image/PixelIterator.zig");
    _ = @import("image/format.zig");
    _ = @import("image/display.zig");
    _ = @import("image/tests/integral.zig");
    _ = @import("image/tests/filters.zig");
    _ = @import("image/tests/transforms.zig");
    _ = @import("image/tests/display.zig");
    _ = @import("image/tests/interpolation.zig");
    _ = @import("image/tests/resize.zig");
    _ = @import("image/tests/psnr.zig");
}
