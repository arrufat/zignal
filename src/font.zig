//! Bitmap font rendering system for zignal
//!
//! This module provides zero-dependency text rendering using embedded bitmap fonts.
//! The default font is an 8x8 monospace bitmap font in the public domain.

const std = @import("std");
const testing = std.testing;
const Image = @import("image.zig").Image;
const convertColor = @import("color.zig").convertColor;
const isColor = @import("color.zig").isColor;
const Rectangle = @import("geometry.zig").Rectangle;

/// A bitmap font containing character data and metrics
pub const BitmapFont = struct {
    /// Width of each character in pixels
    char_width: u8,
    /// Height of each character in pixels
    char_height: u8,
    /// First ASCII character code in the font
    first_char: u8,
    /// Last ASCII character code in the font
    last_char: u8,
    /// Raw bitmap data for all characters
    /// Each character is stored as char_height bytes, one byte per row
    data: []const u8,

    /// Get the bitmap data for a specific character
    /// Returns null if the character is not in the font
    pub fn getCharData(self: BitmapFont, char: u8) ?[]const u8 {
        if (char < self.first_char or char > self.last_char) {
            return null;
        }
        const index = @as(usize, char - self.first_char);
        const offset = index * @as(usize, self.char_height);
        return self.data[offset .. offset + @as(usize, self.char_height)];
    }

    /// Calculate the bounding rectangle for rendering text
    /// Returns bounds where l,t are inclusive and r,b are exclusive
    /// For example, an 8x8 character has pixels at positions 0-7, so bounds are (0,0) to (8,8)
    pub fn getTextBounds(self: BitmapFont, text: []const u8, scale: f32) Rectangle(f32) {
        var width: f32 = 0;
        var height: f32 = @as(f32, @floatFromInt(self.char_height)) * scale;
        var current_line_width: f32 = 0;
        var lines: f32 = 1;

        const char_width_scaled = @as(f32, @floatFromInt(self.char_width)) * scale;
        const char_height_scaled = @as(f32, @floatFromInt(self.char_height)) * scale;

        for (text) |char| {
            if (char == '\n') {
                width = @max(width, current_line_width);
                current_line_width = 0;
                lines += 1;
            } else {
                current_line_width += char_width_scaled;
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
        const char_width_scaled = @as(f32, @floatFromInt(self.char_width)) * scale;
        const char_height_scaled = @as(f32, @floatFromInt(self.char_height)) * scale;

        for (text) |char| {
            if (char == '\n') {
                x = 0;
                y += char_height_scaled;
                continue;
            }

            // Get tight bounds for this character
            const tight = self.getCharTightBounds(char);

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

            x += char_width_scaled;
        }

        if (!has_any_pixels) {
            return Rectangle(f32){ .l = 0, .t = 0, .r = 0, .b = 0 };
        }

        return .{ .l = min_x, .t = min_y, .r = max_x, .b = max_y };
    }

    /// Get the visible bounds of a character (excluding padding)
    fn getCharTightBounds(self: BitmapFont, char: u8) struct { bounds: Rectangle(u8), has_pixels: bool } {
        const char_data = self.getCharData(char) orelse return .{
            .bounds = Rectangle(u8){ .l = 0, .t = 0, .r = 0, .b = 0 },
            .has_pixels = false,
        };

        var min_x: u8 = 255;
        var max_x: u8 = 0;
        var min_y: u8 = 255;
        var max_y: u8 = 0;
        var has_pixels = false;

        for (char_data, 0..) |row_data, row| {
            var bits = row_data;
            for (0..self.char_width) |col| {
                if (bits & 1 != 0) {
                    has_pixels = true;
                    min_x = @min(min_x, @as(u8, @intCast(col)));
                    max_x = @max(max_x, @as(u8, @intCast(col)));
                    min_y = @min(min_y, @as(u8, @intCast(row)));
                    max_y = @max(max_y, @as(u8, @intCast(row)));
                }
                bits >>= 1;
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
};

/// Default 8x8 monospace bitmap font (public domain)
/// Based on font8x8 by Daniel Hepper
/// Each character is 8 bytes, with each byte representing a row
/// Bits are left-to-right, LSB first
pub const default_font_8x8 = BitmapFont{
    .char_width = 8,
    .char_height = 8,
    .first_char = 0x20, // Space
    .last_char = 0x7E, // Tilde
    .data = &font_8x8_data,
};

// Font data for ASCII characters 0x20-0x7E
// Public domain 8x8 bitmap font data
const font_8x8_data = [_]u8{
    // 0x20 ' ' (space)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // 0x21 '!'
    0x18, 0x3C, 0x3C, 0x18, 0x18, 0x00, 0x18, 0x00,
    // 0x22 '"'
    0x36, 0x36, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // 0x23 '#'
    0x36, 0x36, 0x7F, 0x36, 0x7F, 0x36, 0x36, 0x00,
    // 0x24 '$'
    0x0C, 0x3E, 0x03, 0x1E, 0x30, 0x1F, 0x0C, 0x00,
    // 0x25 '%'
    0x00, 0x63, 0x33, 0x18, 0x0C, 0x66, 0x63, 0x00,
    // 0x26 '&'
    0x1C, 0x36, 0x1C, 0x6E, 0x3B, 0x33, 0x6E, 0x00,
    // 0x27 '''
    0x06, 0x06, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00,
    // 0x28 '('
    0x18, 0x0C, 0x06, 0x06, 0x06, 0x0C, 0x18, 0x00,
    // 0x29 ')'
    0x06, 0x0C, 0x18, 0x18, 0x18, 0x0C, 0x06, 0x00,
    // 0x2A '*'
    0x00, 0x66, 0x3C, 0xFF, 0x3C, 0x66, 0x00, 0x00,
    // 0x2B '+'
    0x00, 0x0C, 0x0C, 0x3F, 0x0C, 0x0C, 0x00, 0x00,
    // 0x2C ','
    0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C, 0x06,
    // 0x2D '-'
    0x00, 0x00, 0x00, 0x3F, 0x00, 0x00, 0x00, 0x00,
    // 0x2E '.'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C, 0x00,
    // 0x2F '/'
    0x60, 0x30, 0x18, 0x0C, 0x06, 0x03, 0x01, 0x00,
    // 0x30 '0'
    0x3E, 0x63, 0x73, 0x7B, 0x6F, 0x67, 0x3E, 0x00,
    // 0x31 '1'
    0x0C, 0x0E, 0x0C, 0x0C, 0x0C, 0x0C, 0x3F, 0x00,
    // 0x32 '2'
    0x1E, 0x33, 0x30, 0x1C, 0x06, 0x33, 0x3F, 0x00,
    // 0x33 '3'
    0x1E, 0x33, 0x30, 0x1C, 0x30, 0x33, 0x1E, 0x00,
    // 0x34 '4'
    0x38, 0x3C, 0x36, 0x33, 0x7F, 0x30, 0x78, 0x00,
    // 0x35 '5'
    0x3F, 0x03, 0x1F, 0x30, 0x30, 0x33, 0x1E, 0x00,
    // 0x36 '6'
    0x1C, 0x06, 0x03, 0x1F, 0x33, 0x33, 0x1E, 0x00,
    // 0x37 '7'
    0x3F, 0x33, 0x30, 0x18, 0x0C, 0x0C, 0x0C, 0x00,
    // 0x38 '8'
    0x1E, 0x33, 0x33, 0x1E, 0x33, 0x33, 0x1E, 0x00,
    // 0x39 '9'
    0x1E, 0x33, 0x33, 0x3E, 0x30, 0x18, 0x0E, 0x00,
    // 0x3A ':'
    0x00, 0x0C, 0x0C, 0x00, 0x00, 0x0C, 0x0C, 0x00,
    // 0x3B ';'
    0x00, 0x0C, 0x0C, 0x00, 0x00, 0x0C, 0x0C, 0x06,
    // 0x3C '<'
    0x18, 0x0C, 0x06, 0x03, 0x06, 0x0C, 0x18, 0x00,
    // 0x3D '='
    0x00, 0x00, 0x3F, 0x00, 0x00, 0x3F, 0x00, 0x00,
    // 0x3E '>'
    0x06, 0x0C, 0x18, 0x30, 0x18, 0x0C, 0x06, 0x00,
    // 0x3F '?'
    0x1E, 0x33, 0x30, 0x18, 0x0C, 0x00, 0x0C, 0x00,
    // 0x40 '@'
    0x3E, 0x63, 0x7B, 0x7B, 0x7B, 0x03, 0x1E, 0x00,
    // 0x41 'A'
    0x0C, 0x1E, 0x33, 0x33, 0x3F, 0x33, 0x33, 0x00,
    // 0x42 'B'
    0x3F, 0x66, 0x66, 0x3E, 0x66, 0x66, 0x3F, 0x00,
    // 0x43 'C'
    0x3C, 0x66, 0x03, 0x03, 0x03, 0x66, 0x3C, 0x00,
    // 0x44 'D'
    0x1F, 0x36, 0x66, 0x66, 0x66, 0x36, 0x1F, 0x00,
    // 0x45 'E'
    0x7F, 0x46, 0x16, 0x1E, 0x16, 0x46, 0x7F, 0x00,
    // 0x46 'F'
    0x7F, 0x46, 0x16, 0x1E, 0x16, 0x06, 0x0F, 0x00,
    // 0x47 'G'
    0x3C, 0x66, 0x03, 0x03, 0x73, 0x66, 0x7C, 0x00,
    // 0x48 'H'
    0x33, 0x33, 0x33, 0x3F, 0x33, 0x33, 0x33, 0x00,
    // 0x49 'I'
    0x1E, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x1E, 0x00,
    // 0x4A 'J'
    0x78, 0x30, 0x30, 0x30, 0x33, 0x33, 0x1E, 0x00,
    // 0x4B 'K'
    0x67, 0x66, 0x36, 0x1E, 0x36, 0x66, 0x67, 0x00,
    // 0x4C 'L'
    0x0F, 0x06, 0x06, 0x06, 0x46, 0x66, 0x7F, 0x00,
    // 0x4D 'M'
    0x63, 0x77, 0x7F, 0x7F, 0x6B, 0x63, 0x63, 0x00,
    // 0x4E 'N'
    0x63, 0x67, 0x6F, 0x7B, 0x73, 0x63, 0x63, 0x00,
    // 0x4F 'O'
    0x1C, 0x36, 0x63, 0x63, 0x63, 0x36, 0x1C, 0x00,
    // 0x50 'P'
    0x3F, 0x66, 0x66, 0x3E, 0x06, 0x06, 0x0F, 0x00,
    // 0x51 'Q'
    0x1E, 0x33, 0x33, 0x33, 0x3B, 0x1E, 0x38, 0x00,
    // 0x52 'R'
    0x3F, 0x66, 0x66, 0x3E, 0x36, 0x66, 0x67, 0x00,
    // 0x53 'S'
    0x1E, 0x33, 0x07, 0x0E, 0x38, 0x33, 0x1E, 0x00,
    // 0x54 'T'
    0x3F, 0x2D, 0x0C, 0x0C, 0x0C, 0x0C, 0x1E, 0x00,
    // 0x55 'U'
    0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x3F, 0x00,
    // 0x56 'V'
    0x33, 0x33, 0x33, 0x33, 0x33, 0x1E, 0x0C, 0x00,
    // 0x57 'W'
    0x63, 0x63, 0x63, 0x6B, 0x7F, 0x77, 0x63, 0x00,
    // 0x58 'X'
    0x63, 0x63, 0x36, 0x1C, 0x1C, 0x36, 0x63, 0x00,
    // 0x59 'Y'
    0x33, 0x33, 0x33, 0x1E, 0x0C, 0x0C, 0x1E, 0x00,
    // 0x5A 'Z'
    0x7F, 0x63, 0x31, 0x18, 0x4C, 0x66, 0x7F, 0x00,
    // 0x5B '['
    0x1E, 0x06, 0x06, 0x06, 0x06, 0x06, 0x1E, 0x00,
    // 0x5C '\'
    0x03, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x40, 0x00,
    // 0x5D ']'
    0x1E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x1E, 0x00,
    // 0x5E '^'
    0x08, 0x1C, 0x36, 0x63, 0x00, 0x00, 0x00, 0x00,
    // 0x5F '_'
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF,
    // 0x60 '`'
    0x0C, 0x0C, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00,
    // 0x61 'a'
    0x00, 0x00, 0x1E, 0x30, 0x3E, 0x33, 0x6E, 0x00,
    // 0x62 'b'
    0x07, 0x06, 0x06, 0x3E, 0x66, 0x66, 0x3B, 0x00,
    // 0x63 'c'
    0x00, 0x00, 0x1E, 0x33, 0x03, 0x33, 0x1E, 0x00,
    // 0x64 'd'
    0x38, 0x30, 0x30, 0x3e, 0x33, 0x33, 0x6E, 0x00,
    // 0x65 'e'
    0x00, 0x00, 0x1E, 0x33, 0x3f, 0x03, 0x1E, 0x00,
    // 0x66 'f'
    0x1C, 0x36, 0x06, 0x0f, 0x06, 0x06, 0x0F, 0x00,
    // 0x67 'g'
    0x00, 0x00, 0x6E, 0x33, 0x33, 0x3E, 0x30, 0x1F,
    // 0x68 'h'
    0x07, 0x06, 0x36, 0x6E, 0x66, 0x66, 0x67, 0x00,
    // 0x69 'i'
    0x0C, 0x00, 0x0E, 0x0C, 0x0C, 0x0C, 0x1E, 0x00,
    // 0x6A 'j'
    0x30, 0x00, 0x30, 0x30, 0x30, 0x33, 0x33, 0x1E,
    // 0x6B 'k'
    0x07, 0x06, 0x66, 0x36, 0x1E, 0x36, 0x67, 0x00,
    // 0x6C 'l'
    0x0E, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x1E, 0x00,
    // 0x6D 'm'
    0x00, 0x00, 0x33, 0x7F, 0x7F, 0x6B, 0x63, 0x00,
    // 0x6E 'n'
    0x00, 0x00, 0x1F, 0x33, 0x33, 0x33, 0x33, 0x00,
    // 0x6F 'o'
    0x00, 0x00, 0x1E, 0x33, 0x33, 0x33, 0x1E, 0x00,
    // 0x70 'p'
    0x00, 0x00, 0x3B, 0x66, 0x66, 0x3E, 0x06, 0x0F,
    // 0x71 'q'
    0x00, 0x00, 0x6E, 0x33, 0x33, 0x3E, 0x30, 0x78,
    // 0x72 'r'
    0x00, 0x00, 0x3B, 0x6E, 0x66, 0x06, 0x0F, 0x00,
    // 0x73 's'
    0x00, 0x00, 0x3E, 0x03, 0x1E, 0x30, 0x1F, 0x00,
    // 0x74 't'
    0x08, 0x0C, 0x3E, 0x0C, 0x0C, 0x2C, 0x18, 0x00,
    // 0x75 'u'
    0x00, 0x00, 0x33, 0x33, 0x33, 0x33, 0x6E, 0x00,
    // 0x76 'v'
    0x00, 0x00, 0x33, 0x33, 0x33, 0x1E, 0x0C, 0x00,
    // 0x77 'w'
    0x00, 0x00, 0x63, 0x6B, 0x7F, 0x7F, 0x36, 0x00,
    // 0x78 'x'
    0x00, 0x00, 0x63, 0x36, 0x1C, 0x36, 0x63, 0x00,
    // 0x79 'y'
    0x00, 0x00, 0x33, 0x33, 0x33, 0x3E, 0x30, 0x1F,
    // 0x7A 'z'
    0x00, 0x00, 0x3F, 0x19, 0x0C, 0x26, 0x3F, 0x00,
    // 0x7B '{'
    0x38, 0x0C, 0x0C, 0x07, 0x0C, 0x0C, 0x38, 0x00,
    // 0x7C '|'
    0x18, 0x18, 0x18, 0x00, 0x18, 0x18, 0x18, 0x00,
    // 0x7D '}'
    0x07, 0x0C, 0x0C, 0x38, 0x0C, 0x0C, 0x07, 0x00,
    // 0x7E '~'
    0x6E, 0x3B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

test "BitmapFont.getCharData" {
    const font = default_font_8x8;

    // Test valid character
    const char_a = font.getCharData('A');
    try testing.expect(char_a != null);
    try testing.expectEqual(@as(usize, 8), char_a.?.len);

    // Test character data matches expected pattern for 'A'
    const expected_a = [_]u8{ 0x0C, 0x1E, 0x33, 0x33, 0x3F, 0x33, 0x33, 0x00 };
    try testing.expectEqualSlices(u8, &expected_a, char_a.?);

    // Test out of range character
    const char_invalid = font.getCharData(0x7F);
    try testing.expect(char_invalid == null);
}

test "BitmapFont.getTextBounds" {
    const font = default_font_8x8;

    // Test single line (r,b are exclusive)
    const bounds1 = font.getTextBounds("Hello", 1);
    try testing.expectEqual(@as(f32, 40), bounds1.r); // 5 chars * 8 pixels
    try testing.expectEqual(@as(f32, 8), bounds1.b); // 1 line * 8 pixels

    // Test with scaling
    const bounds2 = font.getTextBounds("Hi", 2);
    try testing.expectEqual(@as(f32, 32), bounds2.r); // 2 chars * 8 pixels * 2 scale
    try testing.expectEqual(@as(f32, 16), bounds2.b); // 1 line * 8 pixels * 2 scale

    // Test multiline
    const bounds3 = font.getTextBounds("Hello\nWorld", 1);
    try testing.expectEqual(@as(f32, 40), bounds3.r); // max line width (both 5 chars)
    try testing.expectEqual(@as(f32, 16), bounds3.b); // 2 lines * 8 pixels
}

test "BitmapFont.getTextBoundsTight" {
    const font = default_font_8x8;

    // Test single character 'A' - we know from earlier it uses columns 0-5
    const bounds1 = font.getTextBoundsTight("A", 1);
    try testing.expectEqual(@as(f32, 0), bounds1.l);
    try testing.expectEqual(@as(f32, 0), bounds1.t);
    try testing.expectEqual(@as(f32, 6), bounds1.r); // Actual width of 'A' is 6 pixels
    try testing.expectEqual(@as(f32, 7), bounds1.b); // Height is 7 pixels (no bottom padding for 'A')

    // Test with scaling
    const bounds2 = font.getTextBoundsTight("A", 2);
    try testing.expectEqual(@as(f32, 0), bounds2.l);
    try testing.expectEqual(@as(f32, 0), bounds2.t);
    try testing.expectEqual(@as(f32, 12), bounds2.r); // 6 * 2
    try testing.expectEqual(@as(f32, 14), bounds2.b); // 7 * 2

    // Test empty string
    const bounds3 = font.getTextBoundsTight("", 1);
    try testing.expectEqual(@as(f32, 0), bounds3.r);
    try testing.expectEqual(@as(f32, 0), bounds3.b);

    // Test space character (should have no pixels)
    const bounds4 = font.getTextBoundsTight(" ", 1);
    try testing.expectEqual(@as(f32, 0), bounds4.r);
    try testing.expectEqual(@as(f32, 0), bounds4.b);
}

test "Text rendering on canvas" {
    const allocator = testing.allocator;
    const Rgb = @import("color.zig").Rgb;
    const Canvas = @import("canvas.zig").Canvas;
    const Point2d = @import("geometry/Point.zig").Point2d;

    // Create a small test image
    var img = try Image(Rgb).initAlloc(allocator, 40, 80);
    defer img.deinit(allocator);

    // Create canvas and fill with black
    var canvas = Canvas(Rgb).init(allocator, img);
    canvas.fill(Rgb{ .r = 0, .g = 0, .b = 0 });

    // Draw white 'A' at position (10, 10)
    canvas.drawText("A", Point2d(f32).init2d(10, 10), default_font_8x8, Rgb{ .r = 255, .g = 255, .b = 255 });

    // Verify some pixels are white (character 'A' should have set pixels)
    var white_pixels: usize = 0;
    for (img.data) |pixel| {
        if (pixel.r == 255 and pixel.g == 255 and pixel.b == 255) {
            white_pixels += 1;
        }
    }

    // 'A' character should have multiple pixels set
    try testing.expect(white_pixels > 10);

    // Test scaled text
    canvas.fill(Rgb{ .r = 0, .g = 0, .b = 0 });
    canvas.drawTextScaled("B", Point2d(f32).init2d(10, 10), default_font_8x8, Rgb{ .r = 255, .g = 0, .b = 0 }, 2);

    var red_pixels: usize = 0;
    for (img.data) |pixel| {
        if (pixel.r == 255 and pixel.g == 0 and pixel.b == 0) {
            red_pixels += 1;
        }
    }

    // Scaled text should have more pixels
    try testing.expect(red_pixels > white_pixels);
}

test "Font data integrity" {
    const font = default_font_8x8;

    // Test font metadata
    try testing.expectEqual(@as(u8, 8), font.char_width);
    try testing.expectEqual(@as(u8, 8), font.char_height);
    try testing.expectEqual(@as(u8, 0x20), font.first_char);
    try testing.expectEqual(@as(u8, 0x7E), font.last_char);

    // Test data size matches expected range
    const expected_chars = @as(usize, font.last_char - font.first_char + 1);
    const expected_bytes = expected_chars * @as(usize, font.char_height);
    try testing.expectEqual(expected_bytes, font.data.len);

    // Test specific characters have expected patterns
    // Space should be empty
    const space_data = font.getCharData(' ').?;
    for (space_data) |byte| {
        try testing.expectEqual(@as(u8, 0x00), byte);
    }

    // Test that printable characters have some pixels set
    const chars_to_test = "ABCabc123!@#";
    for (chars_to_test) |char| {
        const char_data = font.getCharData(char).?;
        var has_pixels = false;
        for (char_data) |byte| {
            if (byte != 0) {
                has_pixels = true;
                break;
            }
        }
        try testing.expect(has_pixels);
    }
}
