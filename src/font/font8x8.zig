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
const unicode = @import("unicode.zig");

/// Basic ASCII font (0x20-0x7E)
/// This font is always available and requires no allocation
pub const basic: BitmapFont = .{
    .name = "8x8 Basic",
    .char_width = 8,
    .char_height = 8,
    .glyphs = &basic_glyphs,
    .data = font_data.basic_latin[0x20 * 8 .. 0x7F * 8],
};

/// One cell per printable ASCII character, in order over `basic`'s data.
const basic_glyphs: [0x7F - 0x20]BitmapFont.Entry = blk: {
    var table: [0x7F - 0x20]BitmapFont.Entry = undefined;
    for (&table, 0..) |*entry, i| entry.* = .cell(0x20 + i, 8, 8, i * 8);
    break :blk table;
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
pub fn create(gpa: std.mem.Allocator, filter: LoadFilter) !BitmapFont {
    var glyphs: std.ArrayList(BitmapFont.Entry) = .empty;
    errdefer glyphs.deinit(gpa);
    var data: std.ArrayList(u8) = .empty;
    errdefer data.deinit(gpa);

    // The data ranges are ascending and disjoint, so one pass yields the table in order.
    for (font_data.ranges) |range| {
        var code = range.start;
        while (code <= range.end) : (code += 1) {
            if (!filter.matches(code)) continue;
            try glyphs.append(gpa, .cell(code, 8, 8, data.items.len));
            try data.appendSlice(gpa, range.data[(code - range.start) * 8 ..][0..8]);
        }
    }
    if (glyphs.items.len == 0) return error.NoCharactersFound;

    const name = try gpa.dupe(u8, "8x8 Unicode");
    errdefer gpa.free(name);
    const table = try glyphs.toOwnedSlice(gpa);
    errdefer gpa.free(table);
    return .{
        .name = name,
        .char_width = 8,
        .char_height = 8,
        .data = try data.toOwnedSlice(gpa),
        .glyphs = table,
    };
}

test "static font is available" {
    const testing = std.testing;

    // Static font should be directly usable without allocation
    try testing.expectEqual(@as(u8, 8), basic.char_width);
    try testing.expectEqual(@as(u8, 8), basic.char_height);
    try testing.expectEqual(95, basic.glyphs.len);
    try testing.expectEqual(0x20, basic.glyphs[0].codepoint);
    try testing.expectEqual(0x7E, basic.glyphs[94].codepoint);

    // Test getting character data
    const char_data = basic.getCharData('A');
    try testing.expect(char_data != null);
    try testing.expectEqual(@as(u32, 8), char_data.?.len);
    try testing.expectEqualSlices(u8, font_data.basic_latin['A' * 8 ..][0..8], char_data.?);
    try testing.expectEqual(null, basic.getCharData(0x7F));
}

test "create ASCII font dynamically" {
    const testing = std.testing;

    var dynamic_font = try create(testing.allocator, .{ .ranges = &[_]unicode.Range{unicode.ranges.ascii} });
    defer dynamic_font.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 8), dynamic_font.char_width);
    try testing.expectEqual(@as(u8, 8), dynamic_font.char_height);

    // Test getting character data through the glyph table
    const char_data = dynamic_font.getCharData('A');
    try testing.expect(char_data != null);
    try testing.expectEqual(@as(u32, 8), char_data.?.len);
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
    try testing.expectEqual(@as(u32, 8), extended_char.?.len);
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
    try testing.expect(all_font.glyphs.len > 200);

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
