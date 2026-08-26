//! Per-glyph metadata for variable-width fonts
//!
//! This struct stores the dimensions, offsets, and bitmap location
//! for individual glyphs in variable-width fonts.

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

/// Bytes per bitmap row for a glyph `width` pixels wide.
pub fn bytesForWidth(width: u32) u32 {
    return (width + 7) / 8;
}

/// Number of bytes per bitmap row for this glyph
pub fn bytesPerRow(self: GlyphData) u32 {
    return bytesForWidth(self.width);
}

/// Total size in bytes of this glyph's bitmap
pub fn bitmapSize(self: GlyphData) u32 {
    return @as(u32, self.height) * self.bytesPerRow();
}

/// Cursor advance for this glyph; negative device widths clamp to 0
pub fn advanceWidth(self: GlyphData) u16 {
    return if (self.device_width > 0) @intCast(self.device_width) else 0;
}
