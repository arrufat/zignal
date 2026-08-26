//! Bitmap font type and rendering functionality
//!
//! A bitmap font containing character data and metrics.
//! Supports both fixed-width and variable-width fonts.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const LoadFilter = @import("../font.zig").LoadFilter;
const Rectangle = @import("../geometry.zig").Rectangle;
const bdf = @import("bdf.zig");
const FontFormat = @import("format.zig").FontFormat;
const GlyphData = @import("GlyphData.zig");
const pcf = @import("pcf.zig");

const BitmapFont = @This();

/// Name of the font (e.g., "Unifont", "Fixed", etc.)
name: []const u8,
/// Width of each character in pixels (default/maximum width)
char_width: u8,
/// Height of each character in pixels
char_height: u8,
/// Fixed-layout fonts (no `glyphs`) store this ASCII range contiguously in `data`, one
/// `char_height` by `bytesPerRow` bitmap per character.
first_char: u8 = 0,
last_char: u8 = 0,
/// Raw bitmap data for all characters, LSB-first within each row byte.
data: []const u8,
/// Per-codepoint glyphs of a variable-width font, each locating its bitmap in `data`.
glyphs: ?std.AutoHashMap(u32, GlyphData) = null,
/// Optional: Original font ascent from the source font file (for accurate save)
font_ascent: ?i16 = null,

/// Loads a font from `file_path` with automatic format detection (BDF or PCF), keeping only
/// characters that match `filter`.
///
/// Example:
/// ```zig
/// // Load entire font:
/// const font = try BitmapFont.load(io, allocator, "unifont.bdf", .all);
/// defer font.deinit(allocator);
///
/// // Load specific ranges:
/// const font = try BitmapFont.load(io, allocator, "font.bdf", .{ .ranges = &unicode.ranges.japanese });
/// ```
pub fn load(io: Io, allocator: Allocator, file_path: []const u8, filter: LoadFilter) !BitmapFont {
    const font_format = try FontFormat.detectFromPath(io, file_path) orelse return error.UnsupportedFontFormat;
    return switch (font_format) {
        .bdf => bdf.load(io, allocator, file_path, filter),
        .pcf => pcf.load(io, allocator, file_path, filter),
        .ttf, .otf, .ttc => error.UnsupportedFontFormat,
    };
}

/// Get number of bytes per row for this font
pub fn bytesPerRow(self: BitmapFont) u32 {
    return GlyphData.bytesForWidth(self.char_width);
}

/// Font ascent, falling back to the character height when the source file didn't record one
pub fn ascent(self: BitmapFont) i16 {
    return self.font_ascent orelse self.char_height;
}

/// Scale that renders the font `size` pixels tall.
pub fn scaleFor(self: BitmapFont, size: f32) f32 {
    return size / @as(f32, @floatFromInt(self.char_height));
}

/// Glyphs in the font.
pub fn glyphCount(self: BitmapFont) u32 {
    if (self.glyphs) |map| return map.count();
    return if (self.first_char <= self.last_char) @as(u32, self.last_char) - self.first_char + 1 else 0;
}

/// A glyph resolved to its metadata and bitmap in a single lookup
pub const Glyph = struct {
    info: GlyphData,
    data: []const u8,

    /// The pixel at (`row`, `col`) of the bitmap: rows are `info.bytesPerRow()` bytes, LSB
    /// first; 0 past the data.
    pub inline fn bit(self: Glyph, row: usize, col: usize) u1 {
        const at = row * self.info.bytesPerRow() + col / 8;
        if (at >= self.data.len) return 0;
        return @intCast((self.data[at] >> @intCast(col % 8)) & 1);
    }

    /// Box of the set pixels in bitmap coordinates (`r`/`b` exclusive), null for a blank glyph.
    pub fn inkBounds(self: Glyph) ?Rectangle(u8) {
        const bytes_per_row = self.info.bytesPerRow();
        // Bits beyond the glyph width in the last byte may contain garbage; mask them off
        const last_bits: u3 = @intCast(self.info.width % 8);
        const last_mask: u8 = if (last_bits == 0) 0xFF else (@as(u8, 1) << last_bits) - 1;
        var bounds: ?Rectangle(u8) = null;
        for (0..self.info.height) |row| {
            const row_data = self.data[row * bytes_per_row ..][0..bytes_per_row];
            for (row_data, 0..) |raw, byte_idx| {
                const byte = if (byte_idx == bytes_per_row - 1) raw & last_mask else raw;
                if (byte == 0) continue;
                // Pixels are LSB-first: lowest set bit is the leftmost pixel
                const base: u8 = @intCast(byte_idx * 8);
                const box: Rectangle(u8) = .{ .l = base + @ctz(byte), .t = @intCast(row), .r = base + 8 - @clz(byte), .b = @intCast(row + 1) };
                bounds = if (bounds) |acc| acc.merge(box) else box;
            }
        }
        return bounds;
    }
};

/// Resolve a codepoint to its glyph info and bitmap data with a single map lookup.
/// Returns null if the character is not in the font.
pub fn getGlyph(self: BitmapFont, codepoint: u21) ?Glyph {
    if (self.glyphs) |map| {
        const info = map.get(codepoint) orelse return null;
        return .{ .info = info, .data = self.data[info.bitmap_offset..][0..info.bitmapSize()] };
    }
    // Fixed layout: the ASCII range, one bitmap after another.
    if (codepoint > 255 or codepoint < self.first_char or codepoint > self.last_char) return null;
    const index: u32 = @as(u8, @intCast(codepoint)) - self.first_char;
    const bytes_per_char = @as(u32, self.char_height) * self.bytesPerRow();
    return .{
        .info = .{
            .width = self.char_width,
            .height = self.char_height,
            .x_offset = 0,
            .y_offset = 0,
            .device_width = @intCast(self.char_width),
            .bitmap_offset = index * bytes_per_char,
        },
        .data = self.data[index * bytes_per_char ..][0..bytes_per_char],
    };
}

/// Get the bitmap data for a specific character
/// Returns null if the character is not in the font
pub fn getCharData(self: BitmapFont, codepoint: u21) ?[]const u8 {
    const glyph = self.getGlyph(codepoint) orelse return null;
    return glyph.data;
}

/// Get the advance width for a character (how much to move the cursor)
/// Returns per-character width if available, otherwise the default char_width
pub fn getCharAdvanceWidth(self: BitmapFont, codepoint: u21) u16 {
    const map = self.glyphs orelse return self.char_width;
    const info = map.get(codepoint) orelse return self.char_width;
    return info.advanceWidth();
}

/// Lays out one line of text at `scale`, yielding each glyph with its pen position: the
/// bitmap counterpart of `VectorFont.Layout`. Codepoints the font lacks only advance the
/// pen, by the character width.
pub const Layout = struct {
    pub const Item = struct {
        glyph: Glyph,
        /// Pen position of the glyph, before its advance.
        x: f32,
    };

    font: BitmapFont,
    scale: f32,
    iter: std.unicode.Utf8Iterator,
    /// The pen; set it before the first glyph to lay out from elsewhere than 0.
    x: f32 = 0,
    /// Extra device pixels after every glyph's advance.
    letter_spacing: f32 = 0,

    pub fn init(font: BitmapFont, text: []const u8, scale: f32) Layout {
        return .{ .font = font, .scale = scale, .iter = .{ .bytes = text, .i = 0 } };
    }

    pub fn next(self: *Layout) ?Item {
        while (self.iter.nextCodepoint()) |codepoint| {
            const x = self.x;
            if (self.place(codepoint)) |glyph| return .{ .glyph = glyph, .x = x };
        }
        return null;
    }

    /// Places `codepoint` at the pen and advances past it. Kept out of line: inlined into
    /// the canvas's glyph loops it measured 40% slower.
    pub fn place(self: *Layout, codepoint: u21) ?Glyph {
        const glyph = self.font.getGlyph(codepoint);
        const advance = if (glyph) |g| g.info.advanceWidth() else self.font.char_width;
        self.x += @as(f32, advance) * self.scale;
        self.x += self.letter_spacing;
        return glyph;
    }
};

/// Calculate the bounding rectangle for rendering text
/// Returns bounds where l,t are inclusive and r,b are exclusive
/// For example, an 8x8 character has pixels at positions 0-7, so bounds are (0,0) to (8,8)
pub fn getTextBounds(self: BitmapFont, text: []const u8, scale: f32) Rectangle(f32) {
    var width: f32 = 0;
    var x: f32 = 0;
    var lines: f32 = 1;
    var iter: std.unicode.Utf8Iterator = .{ .bytes = text, .i = 0 };
    while (iter.nextCodepoint()) |codepoint| {
        if (codepoint != '\n') {
            x += @as(f32, self.getCharAdvanceWidth(codepoint)) * scale;
            continue;
        }
        width = @max(width, x);
        x = 0;
        lines += 1;
    }
    width = @max(width, x);
    return .{ .l = 0, .t = 0, .r = width, .b = lines * (@as(f32, self.char_height) * scale) };
}

/// Calculate the tight bounding rectangle for rendering text
/// Returns bounds that exactly encompass the visible pixels
/// Unlike getTextBounds, this excludes character padding
pub fn getTextBoundsTight(self: BitmapFont, text: []const u8, scale: f32) Rectangle(f32) {
    var layout: Layout = .init(self, text, scale);
    var y: f32 = 0;
    var bounds: ?Rectangle(f32) = null;
    while (layout.iter.nextCodepoint()) |codepoint| {
        if (codepoint == '\n') {
            layout.x = 0;
            y += @as(f32, self.char_height) * scale;
            continue;
        }
        const x = layout.x;
        const glyph = layout.place(codepoint) orelse continue;
        const ink = glyph.inkBounds() orelse continue;
        const box: Rectangle(f32) = .{
            .l = x + @as(f32, ink.l) * scale,
            .t = y + @as(f32, ink.t) * scale,
            .r = x + @as(f32, ink.r) * scale,
            .b = y + @as(f32, ink.b) * scale,
        };
        bounds = if (bounds) |acc| acc.merge(box) else box;
    }
    return bounds orelse .{ .l = 0, .t = 0, .r = 0, .b = 0 };
}

/// Saves the font to a file.
/// Supports BDF (`.bdf`, `.bdf.gz`) and PCF (`.pcf`, `.pcf.gz`) formats.
/// The format is determined by the file extension.
pub fn save(self: BitmapFont, io: Io, allocator: Allocator, file_path: []const u8) !void {
    const font_format = FontFormat.detectFromExtension(file_path) orelse return error.UnsupportedFontFormat;
    return switch (font_format) {
        .bdf => bdf.save(io, allocator, self, file_path),
        .pcf => pcf.save(io, allocator, self, file_path),
        .ttf, .otf, .ttc => error.UnsupportedFontFormat,
    };
}

/// Returns the sorted list of codepoints present in this font. Caller owns the slice.
pub fn collectCodepoints(self: BitmapFont, gpa: Allocator) ![]u21 {
    const keys = try gpa.alloc(u21, self.glyphCount());
    if (self.glyphs) |map| {
        var iter = map.keyIterator();
        for (keys) |*cp| cp.* = @intCast(iter.next().?.*);
        std.mem.sort(u21, keys, {}, std.sort.asc(u21));
    } else for (keys, self.first_char..) |*cp, codepoint| {
        cp.* = @intCast(codepoint);
    }
    return keys;
}

/// Displays the font information: name, dimensions, and character range.
pub fn format(self: BitmapFont, writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("BitmapFont{{ .name = \"{s}\", .char_width = {d}, .char_height = {d}, .glyphs = {d}, .type = {s} }}", .{
        self.name,
        self.char_width,
        self.char_height,
        self.glyphCount(),
        if (self.glyphs != null) "variable" else "fixed",
    });
}

/// Free resources (if owned)
pub fn deinit(self: *BitmapFont, allocator: std.mem.Allocator) void {
    allocator.free(self.name);
    if (self.glyphs) |*map| map.deinit();
    allocator.free(self.data);
}

/// A three-glyph (`A`–`C`) 8x8 font for tests; static, so never `deinit` it.
pub const test_font: BitmapFont = .{
    .name = "TestFont",
    .char_width = 8,
    .char_height = 8,
    .first_char = 'A',
    .last_char = 'C',
    .data = &.{
        0x18, 0x24, 0x42, 0x42, 0x7E, 0x42, 0x42, 0x00,
        0x7C, 0x42, 0x42, 0x7C, 0x42, 0x42, 0x7C, 0x00,
        0x3C, 0x42, 0x40, 0x40, 0x40, 0x42, 0x3C, 0x00,
    },
    .font_ascent = 7,
};

test "getTextBounds with Unicode" {
    const testing = std.testing;
    const font = BitmapFont{
        .name = "Test",
        .char_width = 8,
        .char_height = 8,
        .first_char = 0,
        .last_char = 255,
        .data = &@as([256 * 8]u8, @splat(0)),
    };

    // "A" is 1 byte, "©" is 2 bytes in UTF-8
    const text = "A©";
    const bounds = font.getTextBounds(text, 1.0);

    // Both should be treated as 8px wide characters
    try testing.expectEqual(@as(f32, 16.0), bounds.r);
    try testing.expectEqual(@as(f32, 8.0), bounds.b);
}

test "getTextBoundsTight with Wide Font" {
    const testing = std.testing;
    // 16x8 font, 2 bytes per row
    var data: [2 * 8]u8 = @splat(0);
    // Set a pixel at (10, 2) - this is in the second byte of the 3rd row
    data[2 * 2 + 1] = 1 << 2; // (10-8) = bit 2 of the second byte

    const font = BitmapFont{
        .name = "WideTest",
        .char_width = 16,
        .char_height = 8,
        .first_char = 'A',
        .last_char = 'A',
        .data = &data,
    };

    const bounds = font.getTextBoundsTight("A", 1.0);
    // Pixel is at (10, 2), so bounds should be (10, 2) to (11, 3)
    try testing.expectEqual(@as(f32, 10.0), bounds.l);
    try testing.expectEqual(@as(f32, 2.0), bounds.t);
    try testing.expectEqual(@as(f32, 11.0), bounds.r);
    try testing.expectEqual(@as(f32, 3.0), bounds.b);
}

test "getTextBoundsTight with Unicode" {
    const testing = std.testing;
    // Create a font where '©' (codepoint 0xA9) has a specific pattern
    var data: [256 * 8]u8 = @splat(0);
    // '©' at index 0xA9
    const offset = 0xA9 * 8;
    data[offset + 2] = 0x18; // 00011000 in row 2

    const font = BitmapFont{
        .name = "Test",
        .char_width = 8,
        .char_height = 8,
        .first_char = 0,
        .last_char = 255,
        .data = &data,
    };

    // "©" is 2 bytes in UTF-8.
    // Advance for 'A' (8px) + tight bounds of '©' (bits 3,4 at row 2)
    // x position: 8 (from 'A') + 3 (min_x of '©') = 11
    const text = "A©";
    const bounds = font.getTextBoundsTight(text, 1.0);

    // 'A' has no pixels in this test font. '©' has pixels at x=3,4 in its local space.
    // 'A' is at x=0, '©' is at x=8.
    // '©' pixels are at x=11 and x=12.
    // Tight bounds: l=11, r=13, t=2, b=3.
    try testing.expectEqual(@as(f32, 11.0), bounds.l);
    try testing.expectEqual(@as(f32, 13.0), bounds.r);
    try testing.expectEqual(@as(f32, 2.0), bounds.t);
    try testing.expectEqual(@as(f32, 3.0), bounds.b);
}
