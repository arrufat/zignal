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

    /// Device-pixel box of the glyph's ink, relative to the line's top-left corner.
    pub fn inkBounds(self: Layout, item: Item) ?Rectangle(f32) {
        const ink = item.glyph.inkBounds() orelse return null;
        return .{
            .l = item.x + @as(f32, ink.l) * self.scale,
            .t = @as(f32, ink.t) * self.scale,
            .r = item.x + @as(f32, ink.r) * self.scale,
            .b = @as(f32, ink.b) * self.scale,
        };
    }
};

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
