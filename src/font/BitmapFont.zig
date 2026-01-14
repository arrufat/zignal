//! Bitmap font type and rendering functionality
//!
//! A bitmap font containing character data and metrics.
//! Supports both fixed-width and variable-width fonts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Rectangle = @import("../geometry.zig").Rectangle;
const GlyphData = @import("GlyphData.zig");
const FontFormat = @import("format.zig").FontFormat;
const LoadFilter = @import("../font.zig").LoadFilter;

const BitmapFont = @This();

/// Name of the font (e.g., "Unifont", "Fixed", etc.)
name: []const u8,
/// Width of each character in pixels (default/maximum width)
char_width: u8,
/// Height of each character in pixels
char_height: u8,
/// First ASCII character code in the font
first_char: u8,
/// Last ASCII character code in the font
last_char: u8,
/// Raw bitmap data for all characters
/// For fonts wider than 8 pixels, multiple bytes are used per row
/// Data layout: [char_index][row][byte_in_row]
data: []const u8,
/// Optional: Map from character code to glyph data index (for variable-width fonts)
glyph_map: ?std.AutoHashMap(u32, usize) = null,
/// Optional: Per-character glyph data (width, offsets, etc.)
glyph_data: ?[]const GlyphData = null,
/// Optional: Original font ascent from BDF file (for accurate save)
font_ascent: ?i16 = null,

/// Load a font from file with automatic format detection
///
/// Supports:
/// - BDF (Bitmap Distribution Format)
/// - PCF (Portable Compiled Format) - future
///
/// Parameters:
/// - allocator: Memory allocator
/// - file_path: Path to font file
/// - filter: Filter for which characters to load
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
pub fn load(io: std.Io, allocator: Allocator, file_path: []const u8, filter: LoadFilter) !BitmapFont {
    const font_format = try FontFormat.detectFromPath(io, allocator, file_path) orelse return error.UnsupportedFontFormat;
    return switch (font_format) {
        .bdf => @import("bdf.zig").load(io, allocator, file_path, filter),
        .pcf => @import("pcf.zig").load(io, allocator, file_path, filter),
    };
}

/// Get number of bytes per row for this font
pub fn bytesPerRow(self: BitmapFont) usize {
    return (@as(usize, self.char_width) + 7) / 8;
}

/// Get the bitmap data for a specific character
/// Returns null if the character is not in the font
pub fn getCharData(self: BitmapFont, codepoint: u21) ?[]const u8 {
    // For ASCII fonts WITHOUT glyph_map, use the standard fixed-size layout
    if (self.glyph_map == null and codepoint <= 255 and codepoint >= self.first_char and codepoint <= self.last_char) {
        const index: usize = @as(u8, @intCast(codepoint)) - self.first_char;
        const bytes_per_row = self.bytesPerRow();
        const bytes_per_char = @as(usize, self.char_height) * bytes_per_row;
        const offset = index * bytes_per_char;
        return self.data[offset .. offset + bytes_per_char];
    }

    // For Unicode, check glyph map
    if (self.glyph_map) |map| {
        if (map.get(codepoint)) |idx| {
            if (self.glyph_data) |data| {
                if (idx < data.len) {
                    const glyph = data[idx];
                    const glyph_bytes_per_row = (@as(usize, glyph.width) + 7) / 8;
                    const glyph_size = @as(usize, glyph.height) * glyph_bytes_per_row;
                    return self.data[glyph.bitmap_offset .. glyph.bitmap_offset + glyph_size];
                }
            }
        }
    }

    return null;
}

/// Get bitmap data for a specific row of a character
/// Returns null if the character is not in the font
pub fn getCharRow(self: BitmapFont, codepoint: u21, row: usize) ?[]const u8 {
    // For variable-width fonts, we need to handle per-glyph dimensions
    if (self.glyph_map != null) {
        const glyph_info = self.getGlyphInfo(codepoint) orelse return null;
        if (row >= glyph_info.height) return null;

        const char_data = self.getCharData(codepoint) orelse return null;
        const glyph_bytes_per_row = (@as(usize, glyph_info.width) + 7) / 8;
        const row_offset = row * glyph_bytes_per_row;
        return char_data[row_offset .. row_offset + glyph_bytes_per_row];
    }

    // Fixed-width font path
    const char_data = self.getCharData(codepoint) orelse return null;
    if (row >= self.char_height) return null;
    const bytes_per_row = self.bytesPerRow();
    const row_offset = row * bytes_per_row;
    return char_data[row_offset .. row_offset + bytes_per_row];
}

/// Get the advance width for a character (how much to move the cursor)
/// Returns per-character width if available, otherwise the default char_width
pub fn getCharAdvanceWidth(self: BitmapFont, codepoint: u21) u16 {
    // For ASCII fonts without glyph data, use char_width
    if (self.glyph_data == null) {
        return self.char_width;
    }

    // Check for per-character width data
    if (self.glyph_map) |map| {
        if (map.get(codepoint)) |idx| {
            if (self.glyph_data) |data| {
                if (idx < data.len) {
                    // Use the device width for proper character advance
                    const glyph = data[idx];
                    // Device width can be negative in theory, but we clamp to 0
                    return if (glyph.device_width > 0) @intCast(glyph.device_width) else 0;
                }
            }
        }
    }
    // Fall back to fixed width
    return self.char_width;
}

/// Calculate the bounding rectangle for rendering text
/// Returns bounds where l,t are inclusive and r,b are exclusive
/// For example, an 8x8 character has pixels at positions 0-7, so bounds are (0,0) to (8,8)
pub fn getTextBounds(self: BitmapFont, text: []const u8, scale: f32) Rectangle(f32) {
    var width: f32 = 0;
    var height: f32 = @as(f32, @floatFromInt(self.char_height)) * scale;
    var current_line_width: f32 = 0;
    var lines: f32 = 1;

    const char_height_scaled = @as(f32, @floatFromInt(self.char_height)) * scale;

    var utf8_iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (utf8_iter.nextCodepoint()) |codepoint| {
        if (codepoint == '\n') {
            width = @max(width, current_line_width);
            current_line_width = 0;
            lines += 1;
        } else {
            const char_advance = self.getCharAdvanceWidth(codepoint);
            current_line_width += @as(f32, @floatFromInt(char_advance)) * scale;
        }
    }
    width = @max(width, current_line_width);
    height = lines * char_height_scaled;

    // Return bounds where l,t are inclusive and r,b are exclusive
    // For an 8x8 character, bounds should be (0,0) to (8,8)
    // This follows the standard rectangle convention
    return .{ .l = 0, .t = 0, .r = width, .b = height };
}

/// Calculate the tight bounding rectangle for rendering text
/// Returns bounds that exactly encompass the visible pixels
/// Unlike getTextBounds, this excludes character padding
pub fn getTextBoundsTight(self: BitmapFont, text: []const u8, scale: f32) Rectangle(f32) {
    if (text.len == 0) {
        return Rectangle(f32){ .l = 0, .t = 0, .r = 0, .b = 0 };
    }

    var min_x: f32 = std.math.floatMax(f32);
    var max_x: f32 = std.math.floatMin(f32);
    var min_y: f32 = std.math.floatMax(f32);
    var max_y: f32 = std.math.floatMin(f32);
    var has_any_pixels = false;

    var x: f32 = 0;
    var y: f32 = 0;
    const char_height_scaled = @as(f32, @floatFromInt(self.char_height)) * scale;

    var utf8_iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (utf8_iter.nextCodepoint()) |codepoint| {
        if (codepoint == '\n') {
            x = 0;
            y += char_height_scaled;
            continue;
        }

        // Get tight bounds for this character
        const tight = self.getCharTightBounds(codepoint);

        if (tight.has_pixels) {
            has_any_pixels = true;
            const left = x + @as(f32, @floatFromInt(tight.bounds.l)) * scale;
            const top = y + @as(f32, @floatFromInt(tight.bounds.t)) * scale;
            const right = x + @as(f32, @floatFromInt(tight.bounds.r)) * scale;
            const bottom = y + @as(f32, @floatFromInt(tight.bounds.b)) * scale;

            min_x = @min(min_x, left);
            max_x = @max(max_x, right);
            min_y = @min(min_y, top);
            max_y = @max(max_y, bottom);
        }

        const char_advance = self.getCharAdvanceWidth(codepoint);
        x += @as(f32, @floatFromInt(char_advance)) * scale;
    }

    if (!has_any_pixels) {
        return Rectangle(f32){ .l = 0, .t = 0, .r = 0, .b = 0 };
    }

    return .{ .l = min_x, .t = min_y, .r = max_x, .b = max_y };
}

/// Get glyph information for a character
pub fn getGlyphInfo(self: BitmapFont, codepoint: u21) ?GlyphData {
    if (self.glyph_map) |map| {
        if (map.get(codepoint)) |idx| {
            if (self.glyph_data) |data| {
                if (idx < data.len) {
                    return data[idx];
                }
            }
        }
    }
    // For ASCII fonts without glyph data, return default
    if (codepoint <= 255 and codepoint >= self.first_char and codepoint <= self.last_char) {
        return GlyphData{
            .width = self.char_width,
            .height = self.char_height,
            .x_offset = 0,
            .y_offset = 0,
            .device_width = @intCast(self.char_width),
            .bitmap_offset = 0,
        };
    }
    return null;
}

/// Get the visible bounds of a character (excluding padding)
fn getCharTightBounds(self: BitmapFont, codepoint: u21) struct { bounds: Rectangle(u8), has_pixels: bool } {
    const glyph_info = self.getGlyphInfo(codepoint) orelse return .{
        .bounds = Rectangle(u8){ .l = 0, .t = 0, .r = 0, .b = 0 },
        .has_pixels = false,
    };
    const char_data = self.getCharData(codepoint) orelse return .{
        .bounds = Rectangle(u8){ .l = 0, .t = 0, .r = 0, .b = 0 },
        .has_pixels = false,
    };

    const bytes_per_row = if (self.glyph_map != null)
        (@as(usize, glyph_info.width) + 7) / 8
    else
        self.bytesPerRow();

    var min_x: u8 = 255;
    var max_x: u8 = 0;
    var min_y: u8 = 255;
    var max_y: u8 = 0;
    var has_pixels = false;

    for (0..glyph_info.height) |row| {
        for (0..glyph_info.width) |col| {
            const byte_idx = col / 8;
            const bit_idx = col % 8;
            const row_byte_offset = row * bytes_per_row + byte_idx;
            const bit = (char_data[row_byte_offset] >> @intCast(bit_idx)) & 1;

            if (bit != 0) {
                has_pixels = true;
                min_x = @min(min_x, @as(u8, @intCast(col)));
                max_x = @max(max_x, @as(u8, @intCast(col)));
                min_y = @min(min_y, @as(u8, @intCast(row)));
                max_y = @max(max_y, @as(u8, @intCast(row)));
            }
        }
    }

    if (!has_pixels) {
        return .{
            .bounds = Rectangle(u8){ .l = 0, .t = 0, .r = 0, .b = 0 },
            .has_pixels = false,
        };
    }

    return .{
        .bounds = .{
            .l = min_x,
            .t = min_y,
            .r = max_x + 1, // Exclusive bound
            .b = max_y + 1, // Exclusive bound
        },
        .has_pixels = true,
    };
}

/// Saves the font to a file in BDF format.
/// Returns an error if the file path doesn't end in `.bdf` or `.bdf.gz` (case-insensitive).
pub fn save(self: BitmapFont, io: std.Io, allocator: Allocator, file_path: []const u8) !void {
    const valid_extension = std.ascii.endsWithIgnoreCase(file_path, ".bdf") or
        std.ascii.endsWithIgnoreCase(file_path, ".bdf.gz");

    if (!valid_extension) {
        return error.UnsupportedFontFormat;
    }
    try @import("bdf.zig").save(io, allocator, self, file_path);
}

/// Displays the font information: name, dimensions, and character range.
pub fn format(self: BitmapFont, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    // Count total glyphs if using glyph map
    const glyph_count = if (self.glyph_map) |map| map.count() else blk: {
        if (self.first_char <= self.last_char) {
            break :blk self.last_char - self.first_char + 1;
        } else {
            break :blk 0;
        }
    };

    // Determine font type
    const font_type = if (self.glyph_map != null) "variable" else "fixed";

    try writer.print("BitmapFont{{ .name = \"{s}\", .char_width = {d}, .char_height = {d}, .glyphs = {d}, .type = {s} }}", .{
        self.name,
        self.char_width,
        self.char_height,
        glyph_count,
        font_type,
    });
}

/// Free resources (if owned)
pub fn deinit(self: *BitmapFont, allocator: std.mem.Allocator) void {
    allocator.free(self.name);
    if (self.glyph_map) |*map| {
        map.deinit();
    }
    if (self.glyph_data) |data| {
        allocator.free(data);
    }
    allocator.free(self.data);
}

test "getTextBounds with Unicode" {
    const testing = std.testing;
    const font = BitmapFont{
        .name = "Test",
        .char_width = 8,
        .char_height = 8,
        .first_char = 0,
        .last_char = 255,
        .data = &([_]u8{0} ** (256 * 8)),
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
    var data = [_]u8{0} ** (2 * 8);
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
    var data = [_]u8{0} ** (256 * 8);
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
