//! font8x8 - 8x8 monospace bitmap font (public domain)
//!
//! Based on font8x8 by Daniel Hepper
//! Each character is 8 bytes, with each byte representing a row
//! Bits are left-to-right, LSB first (bit 0 = leftmost pixel)
//!
//! Usage:
//!   font8x8.basic - Static ASCII-only font (no allocation)
//!   font8x8.extended() - Create extended Latin font (requires allocation)
//!   font8x8.create(allocator, filter) - Create custom font with specific ranges

const std = @import("std");

const LoadFilter = @import("../font.zig").LoadFilter;
const BitmapFont = @import("BitmapFont.zig");
const font_data = @import("font8x8_data.zig");
const GlyphData = @import("GlyphData.zig");
const unicode = @import("unicode.zig");

/// Basic ASCII font (0x20-0x7E)
/// This font is always available and requires no allocation
/// Uses a slice of basic_latin starting at character 0x20
pub const basic = BitmapFont{
    .char_width = 8,
    .char_height = 8,
    .first_char = 0x20, // Space
    .last_char = 0x7E, // Tilde
    .data = font_data.basic_latin[0x20 * 8 .. 0x7F * 8], // Slice from 0x20 to 0x7E (inclusive)
    .glyph_map = null,
    .glyph_data = null,
};

/// Create an extended Latin font (ASCII + Latin-1 Supplement)
/// Includes characters 0x20-0xFF
/// The returned font must be freed with deinit()
pub fn extended(allocator: std.mem.Allocator) !BitmapFont {
    return create(allocator, .{ .ranges = &[_]unicode.Range{
        unicode.ranges.ascii,
        unicode.ranges.latin1_supplement,
    } });
}

/// Create a font with specific Unicode ranges
/// This requires allocation and can fail
/// The returned font must be freed with deinit()
pub fn create(allocator: std.mem.Allocator, filter: LoadFilter) !BitmapFont {
    // Build list of characters to include
    var char_list = std.ArrayList(u21).init(allocator);
    defer char_list.deinit();

    switch (filter) {
        .all => {
            // Add all available characters from all ranges
            for (font_data.ranges) |range| {
                var code = range.start;
                while (code <= range.end) : (code += 1) {
                    try char_list.append(code);
                }
            }
        },
        .ranges => |ranges| {
            // Add characters from specified ranges
            for (ranges) |req_range| {
                // Find overlapping ranges in our data
                for (font_data.ranges) |data_range| {
                    const start = @max(req_range.start, data_range.start);
                    const end = @min(req_range.end, data_range.end);
                    if (start <= end) {
                        var code = start;
                        while (code <= end) : (code += 1) {
                            try char_list.append(code);
                        }
                    }
                }
            }
        },
    }

    if (char_list.items.len == 0) {
        return error.NoCharactersFound;
    }

    // Sort characters for consistent output
    std.mem.sort(u21, char_list.items, {}, std.sort.asc(u21));

    // Remove duplicates
    var unique_chars = std.ArrayList(u21).init(allocator);
    defer unique_chars.deinit();

    var prev: ?u21 = null;
    for (char_list.items) |code| {
        if (prev == null or prev.? != code) {
            try unique_chars.append(code);
            prev = code;
        }
    }

    // Build glyph map and data
    var glyph_map = std.AutoHashMap(u32, usize).init(allocator);
    errdefer glyph_map.deinit();

    var glyph_data_list = try allocator.alloc(GlyphData, unique_chars.items.len);
    errdefer allocator.free(glyph_data_list);

    // Calculate total bitmap size needed
    const total_size = unique_chars.items.len * 8; // 8 bytes per character
    var bitmap_data = try allocator.alloc(u8, total_size);
    errdefer allocator.free(bitmap_data);

    // Copy character data
    for (unique_chars.items, 0..) |code, idx| {
        if (font_data.findCharData(code)) |char_info| {
            // Add to glyph map
            try glyph_map.put(@intCast(code), idx);

            // Set glyph data
            glyph_data_list[idx] = GlyphData{
                .width = 8,
                .height = 8,
                .x_offset = 0,
                .y_offset = 0,
                .device_width = 8,
                .bitmap_offset = idx * 8,
            };

            // Copy bitmap data
            @memcpy(bitmap_data[idx * 8 .. (idx + 1) * 8], char_info.data);
        }
    }

    return BitmapFont{
        .char_width = 8,
        .char_height = 8,
        .first_char = 0, // Not used with glyph_map
        .last_char = 0, // Not used with glyph_map
        .data = bitmap_data,
        .glyph_map = glyph_map,
        .glyph_data = glyph_data_list,
    };
}

test "static font is available" {
    const testing = std.testing;

    // Static font should be directly usable without allocation
    try testing.expectEqual(@as(u8, 8), basic.char_width);
    try testing.expectEqual(@as(u8, 8), basic.char_height);
    try testing.expectEqual(@as(u8, 0x20), basic.first_char);
    try testing.expectEqual(@as(u8, 0x7E), basic.last_char);

    // Test getting character data
    const char_data = basic.getCharData('A');
    try testing.expect(char_data != null);
    try testing.expectEqual(@as(usize, 8), char_data.?.len);
}

test "create ASCII font dynamically" {
    const testing = std.testing;

    var dynamic_font = try create(testing.allocator, .{ .ranges = &[_]unicode.Range{unicode.ranges.ascii} });
    defer dynamic_font.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 8), dynamic_font.char_width);
    try testing.expectEqual(@as(u8, 8), dynamic_font.char_height);

    // Should have glyph map since it's dynamically created
    try testing.expect(dynamic_font.glyph_map != null);
    try testing.expect(dynamic_font.glyph_data != null);

    // Test getting character data through glyph map
    const char_data = dynamic_font.getCharData('A');
    try testing.expect(char_data != null);
    try testing.expectEqual(@as(usize, 8), char_data.?.len);
}

test "create extended Latin font" {
    const testing = std.testing;

    var extended_font = try extended(testing.allocator);
    defer extended_font.deinit(testing.allocator);

    // Test ASCII character
    const ascii_char = extended_font.getCharData('A');
    try testing.expect(ascii_char != null);

    // Test extended Latin character (© copyright symbol at 0xA9)
    const extended_char = extended_font.getCharData(0xA9);
    try testing.expect(extended_char != null);
    try testing.expectEqual(@as(usize, 8), extended_char.?.len);
}

test "create box drawing font" {
    const testing = std.testing;

    var box_font = try create(testing.allocator, .{ .ranges = &[_]unicode.Range{
        unicode.ranges.ascii,
        unicode.ranges.box_drawing,
        unicode.ranges.block_elements,
    } });

    defer box_font.deinit(testing.allocator);

    // Test ASCII character
    const ascii_char = box_font.getCharData('A');
    try testing.expect(ascii_char != null);

    // Test box drawing character (╔ at 0x2554)
    const box_char = box_font.getCharData(0x2554);
    try testing.expect(box_char != null);

    // Test block element (▀ at 0x2580)
    const block_char = box_font.getCharData(0x2580);
    try testing.expect(block_char != null);
}

test "create font with all available ranges" {
    const testing = std.testing;

    var all_font = try create(testing.allocator, .all);
    defer all_font.deinit(testing.allocator);

    // Should have many characters available
    try testing.expect(all_font.glyph_map.?.count() > 200);

    // Test various ranges are included
    try testing.expect(all_font.getCharData('A') != null); // ASCII
    try testing.expect(all_font.getCharData(0xA9) != null); // Extended Latin
    try testing.expect(all_font.getCharData(0x2554) != null); // Box drawing
    try testing.expect(all_font.getCharData(0x2580) != null); // Block elements
}

test "create font with custom ranges" {
    const testing = std.testing;

    // Create font with just box drawing, no ASCII
    var custom_font = try create(testing.allocator, .{ .ranges = &[_]unicode.Range{
        unicode.ranges.box_drawing,
    } });
    defer custom_font.deinit(testing.allocator);

    // Should not have ASCII characters
    try testing.expect(custom_font.getCharData('A') == null);

    // Should have box drawing characters
    try testing.expect(custom_font.getCharData(0x2500) != null);
}
