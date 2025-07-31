//! Per-glyph metadata for variable-width fonts
//!
//! This struct stores the dimensions, offsets, and bitmap location
//! for individual glyphs in variable-width fonts.

const std = @import("std");

const GlyphData = @This();

/// Width of this specific glyph in pixels
width: u8,
/// Height of this specific glyph in pixels
height: u8,
/// Horizontal offset from the cursor position
x_offset: i16,
/// Vertical offset from the baseline
y_offset: i16,
/// How far to advance the cursor after drawing this glyph
device_width: i16,
/// Offset into the bitmap data array where this glyph's bitmap starts
bitmap_offset: usize = 0,
