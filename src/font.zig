//! Font system for zignal
//!
//! This module provides bitmap font rendering capabilities including:
//! - Default 8x8 bitmap font
//! - BDF font loading with Unicode support
//! - Variable-width font support
//!
//! The font system is organized into subdirectories for better modularity.

const std = @import("std");

// Core font types
pub const BitmapFont = @import("font/BitmapFont.zig");
pub const GlyphData = @import("font/GlyphData.zig");

/// Font loading filter
pub const LoadFilter = union(enum) {
    /// Load all characters in the font
    all,
    /// Load only specified Unicode ranges
    ranges: []const unicode.Range,
};

// Default font
const default_8x8 = @import("font/default_8x8.zig");
pub const default_font_8x8 = default_8x8.font;

// Unicode utilities
pub const unicode = @import("font/unicode.zig");

// Format detection
pub const FontFormat = @import("font/format.zig").FontFormat;

// BDF font support
pub const bdf = @import("font/bdf.zig");

test {
    _ = bdf;
}
