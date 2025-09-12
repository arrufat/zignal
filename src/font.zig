//! Font system for zignal
//!
//! This module provides bitmap font rendering capabilities including:
//! - Default 8x8 bitmap font
//! - BDF font loading with Unicode support
//! - Variable-width font support
//!
//! The font system is organized into subdirectories for better modularity.

/// Maximum file size for font files (50MB)
/// This limit prevents DoS attacks and accidental memory exhaustion
/// while being large enough for all known font files
pub const max_file_size = 50 * 1024 * 1024;

// Core font types
pub const BitmapFont = @import("font/BitmapFont.zig");

/// Font loading filter
pub const LoadFilter = union(enum) {
    /// Load all characters in the font
    all,
    /// Load only specified Unicode ranges
    ranges: []const unicode.Range,
};

// font8x8 - 8x8 monospace bitmap font
pub const font8x8 = @import("font/font8x8.zig");

// Unicode utilities
pub const unicode = @import("font/unicode.zig");

// Format detection
pub const FontFormat = @import("font/format.zig").FontFormat;

// BDF font support
pub const bdf = @import("font/bdf.zig");

// PCF font support
pub const pcf = @import("font/pcf.zig");

test {
    _ = font8x8;
    _ = bdf;
    _ = pcf;
}
