//! BDF (Bitmap Distribution Format) font parser for zignal
//!
//! This module provides zero-dependency parsing of BDF font files,
//! enabling support for Unicode bitmap fonts like GNU Unifont.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const LoadFilter = @import("../font.zig").LoadFilter;
const isGzipPath = @import("../font.zig").isGzipPath;
const readFileMaybeGzip = @import("../font.zig").readFileMaybeGzip;
const writeFileMaybeGzip = @import("../font.zig").writeFileMaybeGzip;
const BitmapFont = @import("BitmapFont.zig");
const GlyphData = @import("GlyphData.zig");

/// Errors that can occur during BDF parsing
pub const BdfError = error{
    InvalidFormat,
    InvalidVersion,
    MissingRequired,
    InvalidBitmapData,
    AllocationFailed,
    InvalidCompression,
};

/// BDF font metadata
const BdfFont = struct {
    name: []u8,
    bbox_width: i16,
    bbox_height: i16,
    ascent: i16,
    glyph_count: u32,
};

/// Single-pass BDF parser state: the glyphs in file order, `y_offset` already counted down
/// from the top of the line.
const BdfParseState = struct {
    font: BdfFont,
    glyphs: std.ArrayList(BitmapFont.Entry),
    bitmap_data: std.ArrayList(u8),
    fn deinit(self: *BdfParseState, gpa: Allocator) void {
        self.glyphs.deinit(gpa);
        self.bitmap_data.deinit(gpa);
    }
};

/// Loads a BDF font from `path` (transparently decompressing `.bdf.gz`), keeping only characters
/// that match `filter`.
pub fn load(io: Io, gpa: std.mem.Allocator, path: []const u8, filter: LoadFilter) !BitmapFont {
    const bytes = try readFileMaybeGzip(io, gpa, path);
    defer gpa.free(bytes);
    return parse(gpa, bytes, filter);
}

/// Parses the BDF text `bytes` into a font, keeping only characters that match `filter`.
pub fn parse(gpa: Allocator, bytes: []const u8, filter: LoadFilter) !BitmapFont {
    var lines = std.mem.tokenizeAny(u8, bytes, "\n\r");
    var state: BdfParseState = .{ .font = try parseHeader(gpa, &lines), .glyphs = .empty, .bitmap_data = .empty };
    defer state.deinit(gpa);
    // The name passes to the font; until then it is ours to free.
    errdefer gpa.free(state.font.name);

    var parsed_glyphs: u32 = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.eql(u8, trimmed, "ENDFONT")) break;
        if (!std.mem.startsWith(u8, trimmed, "STARTCHAR")) continue;
        if (try parseGlyph(gpa, &lines, &state, filter)) parsed_glyphs += 1;
        if (parsed_glyphs >= state.font.glyph_count) break;
    }

    // Codepoint order, a later duplicate of an encoding replacing the earlier one.
    std.mem.sort(BitmapFont.Entry, state.glyphs.items, {}, byCodepoint);
    var kept: usize = 0;
    for (state.glyphs.items) |entry| {
        if (kept > 0 and state.glyphs.items[kept - 1].codepoint == entry.codepoint) kept -= 1;
        state.glyphs.items[kept] = entry;
        kept += 1;
    }
    state.glyphs.shrinkRetainingCapacity(kept);

    const bitmap_data = try state.bitmap_data.toOwnedSlice(gpa);
    errdefer gpa.free(bitmap_data);
    const glyphs = try state.glyphs.toOwnedSlice(gpa);
    errdefer gpa.free(glyphs);
    return .{
        .name = state.font.name,
        .char_width = std.math.cast(u8, @abs(state.font.bbox_width)) orelse return BdfError.InvalidFormat,
        .char_height = std.math.cast(u8, @abs(state.font.bbox_height)) orelse return BdfError.InvalidFormat,
        .data = bitmap_data,
        .glyphs = glyphs,
        .font_ascent = state.font.ascent,
    };
}

fn byCodepoint(_: void, a: BitmapFont.Entry, b: BitmapFont.Entry) bool {
    return a.codepoint < b.codepoint;
}

/// The family of an XLFD name (`-foundry-family-weight-...`); any other name as is.
fn familyName(name: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, name, "-")) return name;
    var fields = std.mem.tokenizeScalar(u8, name[1..], '-');
    _ = fields.next(); // foundry
    return fields.next() orelse name;
}

/// Parse BDF header
fn parseHeader(gpa: Allocator, lines: *std.mem.TokenIterator(u8, .any)) !BdfFont {
    var font = BdfFont{
        .name = try gpa.dupe(u8, "Unknown"),
        .bbox_width = 0,
        .bbox_height = 0,
        .ascent = 0,
        .glyph_count = 0,
    };
    errdefer gpa.free(font.name);

    // Check STARTFONT
    const first_line = lines.next() orelse return BdfError.InvalidFormat;
    if (!std.mem.startsWith(u8, first_line, "STARTFONT")) {
        return BdfError.InvalidFormat;
    }
    const version = std.mem.trim(u8, first_line[9..], " \t");
    if (!std.mem.eql(u8, version, "2.1") and !std.mem.eql(u8, version, "2.2")) {
        return BdfError.InvalidVersion;
    }

    // Parse header fields
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed, "FONT ")) {
            const name = try gpa.dupe(u8, familyName(std.mem.trim(u8, trimmed[5..], " \t")));
            gpa.free(font.name);
            font.name = name;
        } else if (std.mem.startsWith(u8, trimmed, "FONTBOUNDINGBOX ")) {
            var parts = std.mem.tokenizeAny(u8, trimmed[16..], " \t");
            font.bbox_width = try std.fmt.parseInt(i16, parts.next() orelse return BdfError.MissingRequired, 10);
            font.bbox_height = try std.fmt.parseInt(i16, parts.next() orelse return BdfError.MissingRequired, 10);
        } else if (std.mem.startsWith(u8, trimmed, "CHARS ")) {
            font.glyph_count = try std.fmt.parseInt(u32, std.mem.trim(u8, trimmed[6..], " \t"), 10);
            break;
        } else if (std.mem.startsWith(u8, trimmed, "STARTPROPERTIES")) {
            // Parse properties to get FONT_ASCENT
            while (lines.next()) |prop_line| {
                const prop_trimmed = std.mem.trim(u8, prop_line, " \t");
                if (std.mem.eql(u8, prop_trimmed, "ENDPROPERTIES")) {
                    break;
                }
                if (std.mem.startsWith(u8, prop_trimmed, "FONT_ASCENT ")) {
                    font.ascent = try std.fmt.parseInt(i16, std.mem.trim(u8, prop_trimmed[12..], " \t\""), 10);
                }
            }
        }
    }

    if (font.glyph_count == 0) {
        return BdfError.MissingRequired;
    }

    return font;
}

fn parseHexByte(hex: []const u8, byte_index: usize) BdfError!u8 {
    const pos = byte_index * 2;
    if (pos >= hex.len) {
        return 0;
    }

    const hi = std.fmt.charToDigit(hex[pos], 16) catch return BdfError.InvalidBitmapData;
    const lo = if (pos + 1 < hex.len) std.fmt.charToDigit(hex[pos + 1], 16) catch return BdfError.InvalidBitmapData else 0;
    return (hi << 4) | lo;
}

/// Consumes lines up to and including the glyph's `ENDCHAR`.
fn skipToEndChar(lines: *std.mem.TokenIterator(u8, .any)) void {
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "ENDCHAR")) return;
    }
}

/// Parses one glyph after its `STARTCHAR`; true when it was kept.
fn parseGlyph(gpa: Allocator, lines: *std.mem.TokenIterator(u8, .any), state: *BdfParseState, filter: LoadFilter) !bool {
    var info: GlyphData = .{ .width = 0, .height = 0, .x_offset = 0, .y_offset = 0, .device_width = 0, .bitmap_offset = state.bitmap_data.items.len };
    var encoding: ?u21 = null;
    // BDF's y offset: the bitmap's bottom edge relative to the baseline.
    var bbx_y: ?i16 = null;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed, "ENCODING ")) {
            const enc_str = std.mem.trim(u8, trimmed[9..], " \t");
            // Negative encodings are unmapped glyphs.
            if (std.mem.startsWith(u8, enc_str, "-")) {
                skipToEndChar(lines);
                return false;
            }
            encoding = try std.fmt.parseInt(u21, enc_str, 10);
        } else if (std.mem.startsWith(u8, trimmed, "DWIDTH ")) {
            var parts = std.mem.tokenizeAny(u8, trimmed[7..], " \t");
            info.device_width = try std.fmt.parseInt(i16, parts.next() orelse "0", 10);
        } else if (std.mem.startsWith(u8, trimmed, "BBX ")) {
            var parts = std.mem.tokenizeAny(u8, trimmed[4..], " \t");
            info.width = try std.fmt.parseInt(u8, parts.next() orelse return BdfError.InvalidFormat, 10);
            info.height = try std.fmt.parseInt(u8, parts.next() orelse return BdfError.InvalidFormat, 10);
            info.x_offset = try std.fmt.parseInt(i16, parts.next() orelse return BdfError.InvalidFormat, 10);
            bbx_y = try std.fmt.parseInt(i16, parts.next() orelse return BdfError.InvalidFormat, 10);
            // Default device width to glyph width if not specified
            if (info.device_width == 0) info.device_width = info.width;
        } else if (std.mem.eql(u8, trimmed, "BITMAP")) {
            const codepoint = encoding orelse return BdfError.MissingRequired;
            const bottom = bbx_y orelse return BdfError.MissingRequired;
            if (!filter.matches(codepoint)) {
                skipToEndChar(lines);
                return false;
            }
            // BDF offsets count up from the baseline; ours count down from the line's top.
            info.y_offset = std.math.cast(i16, @as(i32, state.font.ascent) - bottom - info.height) orelse return BdfError.InvalidFormat;

            const bytes_per_row = info.bytesPerRow();
            try state.bitmap_data.ensureUnusedCapacity(gpa, info.bitmapSize());
            for (0..info.height) |_| {
                const bitmap_line = lines.next() orelse return BdfError.InvalidBitmapData;
                const bitmap_trimmed = std.mem.trim(u8, bitmap_line, " \t");
                if (std.mem.eql(u8, bitmap_trimmed, "ENDCHAR")) return BdfError.InvalidBitmapData;
                if (bitmap_trimmed.len > bytes_per_row * 2) return BdfError.InvalidBitmapData;

                for (0..bytes_per_row) |byte_idx| {
                    var our_byte: u8 = 0;
                    const start_bit = byte_idx * 8;
                    const end_bit = @min(start_bit + 8, info.width);
                    if (end_bit > start_bit) {
                        // BDF stores pixels MSB-first per byte; convert to zignal's LSB-first layout
                        const reversed_byte = @bitReverse(try parseHexByte(bitmap_trimmed, byte_idx));
                        const bits_to_take: u4 = @intCast(end_bit - start_bit);
                        const mask: u8 = @intCast((@as(u16, 1) << bits_to_take) - 1);
                        our_byte = reversed_byte & mask;
                    }
                    state.bitmap_data.appendAssumeCapacity(our_byte);
                }
            }

            try state.glyphs.append(gpa, .{ .codepoint = codepoint, .info = info });
            skipToEndChar(lines);
            return true;
        } else if (std.mem.eql(u8, trimmed, "ENDCHAR")) {
            // Glyph without bitmap?
            return false;
        }
    }

    return false;
}

test "BDF to BitmapFont conversion" {
    const test_bdf =
        \\STARTFONT 2.1
        \\FONT test
        \\SIZE 8 75 75
        \\FONTBOUNDINGBOX 8 8 0 0
        \\CHARS 1
        \\STARTCHAR A
        \\ENCODING 65
        \\SWIDTH 500 0
        \\DWIDTH 8 0
        \\BBX 8 8 0 0
        \\BITMAP
        \\18
        \\24
        \\42
        \\42
        \\7E
        \\42
        \\42
        \\00
        \\ENDCHAR
        \\ENDFONT
    ;

    var font = try parse(testing.allocator, test_bdf, .all);
    defer font.deinit(testing.allocator);

    // Test converted font
    try testing.expectEqual(@as(u8, 8), font.char_height);
    try testing.expectEqual(1, font.glyphs.len);
    try testing.expectEqual('A', font.glyphs[0].codepoint);

    // Test that 'A' was converted correctly
    const char_data = font.getCharData('A');
    try testing.expect(char_data != null);
    try testing.expectEqual(@as(u32, 8), char_data.?.len);

    // Check bitmap conversion
    try testing.expectEqual(@as(u8, 0x18), char_data.?[0]);
    try testing.expectEqual(@as(u8, 0x24), char_data.?[1]);
}

test "BDF sorts glyphs by encoding, the last duplicate winning" {
    const unsorted_bdf =
        \\STARTFONT 2.1
        \\FONTBOUNDINGBOX 8 1 0 0
        \\CHARS 3
        \\STARTCHAR B
        \\ENCODING 66
        \\BBX 8 1 0 0
        \\BITMAP
        \\02
        \\ENDCHAR
        \\STARTCHAR A
        \\ENCODING 65
        \\BBX 8 1 0 0
        \\BITMAP
        \\01
        \\ENDCHAR
        \\STARTCHAR A2
        \\ENCODING 65
        \\BBX 8 1 0 0
        \\BITMAP
        \\03
        \\ENDCHAR
        \\ENDFONT
    ;

    var font = try parse(testing.allocator, unsorted_bdf, .all);
    defer font.deinit(testing.allocator);

    try testing.expectEqual(2, font.glyphs.len);
    try testing.expectEqual('A', font.glyphs[0].codepoint);
    try testing.expectEqual('B', font.glyphs[1].codepoint);
    try testing.expectEqualSlices(u8, &.{@bitReverse(@as(u8, 0x03))}, font.getCharData('A').?);
    try testing.expectEqualSlices(u8, &.{@bitReverse(@as(u8, 0x02))}, font.getCharData('B').?);
}

test "BDF parses glyph rows wider than 32 bits" {
    const wide_bdf =
        \\STARTFONT 2.1
        \\FONT wide-test
        \\SIZE 10 75 75
        \\FONTBOUNDINGBOX 40 1 0 0
        \\CHARS 1
        \\STARTCHAR WIDE
        \\ENCODING 65
        \\SWIDTH 400 0
        \\DWIDTH 40 0
        \\BBX 40 1 0 0
        \\BITMAP
        \\1234567890
        \\ENDCHAR
        \\ENDFONT
    ;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    const file_path = try Io.Dir.path.join(testing.allocator, &.{ dir_path, "wide_font.bdf" });
    defer testing.allocator.free(file_path);

    try tmp_dir.dir.writeFile(testing.io, .{ .sub_path = "wide_font.bdf", .data = wide_bdf });

    var font = try load(testing.io, testing.allocator, file_path, .all);
    defer font.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 40), font.char_width);
    try testing.expectEqual(@as(u8, 1), font.char_height);

    const maybe_data = font.getCharData(65);
    try testing.expect(maybe_data != null);
    const data = maybe_data.?;
    const expected = [_]u8{ 0x48, 0x2C, 0x6A, 0x1E, 0x09 };
    try testing.expectEqualSlices(u8, &expected, data[0..expected.len]);
}

fn expectRoundtrip(file_name: []const u8) !void {
    const font = BitmapFont.test_font;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir_path = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);
    const path = try Io.Dir.path.join(testing.allocator, &.{ dir_path, file_name });
    defer testing.allocator.free(path);

    try font.save(testing.io, testing.allocator, path);
    if (isGzipPath(path)) {
        // The file starts with the gzip magic.
        const file = try Io.Dir.openFileAbsolute(testing.io, path, .{});
        defer file.close(testing.io);
        var header: [2]u8 = undefined;
        var iov = [_][]u8{header[0..]};
        _ = try file.readStreaming(testing.io, &iov);
        try testing.expectEqualSlices(u8, &.{ 0x1f, 0x8b }, &header);
    }

    var loaded = try BitmapFont.load(testing.io, testing.allocator, path, .all);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(font.char_width, loaded.char_width);
    try testing.expectEqual(font.char_height, loaded.char_height);
    try testing.expectEqual(font.glyphs.len, loaded.glyphs.len);
    for (font.glyphs) |entry| {
        try testing.expectEqualSlices(u8, font.getCharData(entry.codepoint).?, loaded.getCharData(entry.codepoint).?);
    }
}

test "BDF save and load roundtrip" {
    try expectRoundtrip("test_font.bdf");
}

test "BDF save and load compressed roundtrip" {
    try expectRoundtrip("test_font.bdf.gz");
}

/// Save a BitmapFont to a BDF file
pub fn save(io: Io, gpa: Allocator, font: BitmapFont, path: []const u8) !void {
    // Create buffer for BDF content
    var bdf_content: std.ArrayList(u8) = .empty;
    defer bdf_content.deinit(gpa);

    try writeBdfHeader(gpa, &bdf_content, font);

    for (font.glyphs) |entry| try writeBdfGlyph(gpa, &bdf_content, font, entry);

    try bdf_content.appendSlice(gpa, "ENDFONT\n");

    try writeFileMaybeGzip(io, gpa, path, bdf_content.items);
}

/// Write BDF header
fn writeBdfHeader(allocator: Allocator, list: *std.ArrayList(u8), font: BitmapFont) !void {
    try list.appendSlice(allocator, "STARTFONT 2.1\n");
    try list.appendSlice(allocator, "COMMENT Generated by zignal\n");

    // Use safe defaults for font metrics if they're zero
    const height = if (font.char_height == 0) 16 else font.char_height;
    const width = if (font.char_width == 0) 8 else font.char_width;

    // Use font name or default
    const font_name = if (font.name.len > 0) font.name else "Unknown";

    // If the font name looks like an XLFD name (contains dashes), use it directly
    if (std.mem.find(u8, font_name, "-") != null) {
        try list.print(allocator, "FONT {s}\n", .{font_name});
    } else {
        // Otherwise build a simple XLFD name
        try list.print(allocator, "FONT -{s}-{s}-Medium-R-Normal--{d}-{d}-75-75-P-{d}-ISO10646-1\n", .{ "zignal", font_name, height, @as(u32, height) * 10, @as(u32, width) * 6 });
    }
    try list.print(allocator, "SIZE {d} 75 75\n", .{height});

    // Calculate font bounding box and ascent/descent
    var min_x_offset: i16 = 0;
    var min_y_offset: i16 = 0;
    var max_width: u16 = if (font.char_width == 0) width else font.char_width;
    var max_height: u16 = if (font.char_height == 0) height else font.char_height;

    // Use stored font_ascent if available, otherwise estimate from the defaulted height
    const font_ascent = font.font_ascent orelse @as(i16, height);

    for (font.glyphs) |entry| {
        const glyph = entry.info;
        max_width = @max(max_width, glyph.width);
        max_height = @max(max_height, glyph.height);

        // Reverse the transformation: bdf_y_offset = font_ascent - (internal_y_offset + height)
        const bdf_y_offset = font_ascent - (glyph.y_offset + @as(i16, glyph.height));
        min_y_offset = @min(min_y_offset, bdf_y_offset);
        min_x_offset = @min(min_x_offset, glyph.x_offset);
    }

    const font_descent = -min_y_offset;

    try list.print(allocator, "FONTBOUNDINGBOX {d} {d} {d} {d}\n", .{ max_width, max_height, min_x_offset, min_y_offset });

    // Write properties
    try list.appendSlice(allocator, "STARTPROPERTIES 2\n");
    try list.print(allocator, "FONT_ASCENT {d}\n", .{font_ascent});
    try list.print(allocator, "FONT_DESCENT {d}\n", .{font_descent});
    try list.appendSlice(allocator, "ENDPROPERTIES\n");

    try list.print(allocator, "CHARS {d}\n", .{font.glyphCount()});
}

/// Write a single glyph
fn writeBdfGlyph(allocator: Allocator, list: *std.ArrayList(u8), font: BitmapFont, entry: BitmapFont.Entry) !void {
    const encoding = entry.codepoint;
    const glyph_info = entry.info;
    const glyph_data = font.bitmap(glyph_info);

    try list.print(allocator, "STARTCHAR U+{X:0>4}\n", .{encoding});
    try list.print(allocator, "ENCODING {d}\n", .{encoding});

    // Reverse the y_offset transformation
    const bdf_y_offset = font.ascent() - (glyph_info.y_offset + @as(i16, glyph_info.height));

    try list.print(allocator, "SWIDTH {d} 0\n", .{glyph_info.device_width * 72});
    try list.print(allocator, "DWIDTH {d} 0\n", .{glyph_info.device_width});
    try list.print(allocator, "BBX {d} {d} {d} {d}\n", .{ glyph_info.width, glyph_info.height, glyph_info.x_offset, bdf_y_offset });
    try list.appendSlice(allocator, "BITMAP\n");

    const bytes_per_row = glyph_info.bytesPerRow();
    for (0..glyph_info.height) |row| {
        const row_data = glyph_data[row * bytes_per_row ..][0..bytes_per_row];
        // Convert LSB-first bytes to BDF's MSB-first hex format
        for (row_data) |byte| {
            try list.print(allocator, "{X:0>2}", .{@bitReverse(byte)});
        }
        try list.append(allocator, '\n');
    }

    try list.appendSlice(allocator, "ENDCHAR\n");
}
