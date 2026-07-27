//! BDF (Bitmap Distribution Format) font parser for zignal
//!
//! This module provides zero-dependency parsing of BDF font files,
//! enabling support for Unicode bitmap fonts like GNU Unifont.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const LoadFilter = @import("../font.zig").LoadFilter;
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

/// BDF glyph information
const BdfGlyph = struct {
    encoding: u32,
    bbox: struct {
        width: u16,
        height: u16,
        x_offset: i16,
        y_offset: i16,
    },
    device_width: i16,
    bitmap_offset: usize,
    bitmap_size: u32,
};

/// Single-pass BDF parser state
const BdfParseState = struct {
    font: BdfFont,
    glyphs: std.ArrayList(BdfGlyph),
    bitmap_data: std.ArrayList(u8),
    all_ascii: bool = true,
    fn deinit(self: *BdfParseState, gpa: Allocator) void {
        gpa.free(self.font.name);
        self.glyphs.deinit(gpa);
        self.bitmap_data.deinit(gpa);
    }
};

/// Loads a BDF font from `path` (transparently decompressing `.bdf.gz`), keeping only characters
/// that match `filter`.
pub fn load(io: Io, gpa: std.mem.Allocator, path: []const u8, filter: LoadFilter) !BitmapFont {
    const file_contents = try readFileMaybeGzip(io, gpa, path);
    defer gpa.free(file_contents);

    // Parse BDF file in a single pass
    var lines = std.mem.tokenizeAny(u8, file_contents, "\n\r");
    var state = BdfParseState{
        .font = undefined,
        .glyphs = .empty,
        .bitmap_data = .empty,
    };
    defer state.deinit(gpa);

    // Parse header
    state.font = try parseHeader(gpa, &lines);

    // Parse glyphs
    var parsed_glyphs: u32 = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");

        if (std.mem.eql(u8, trimmed, "ENDFONT")) {
            break;
        }

        if (!std.mem.startsWith(u8, trimmed, "STARTCHAR")) {
            continue;
        }

        // Parse glyph
        if (try parseGlyph(gpa, &lines, &state, filter)) {
            parsed_glyphs += 1;
        }

        if (parsed_glyphs >= state.font.glyph_count) {
            break;
        }
    }

    // Convert to BitmapFont format
    const bitmap_data = try state.bitmap_data.toOwnedSlice(gpa);
    return convertToBitmapFont(gpa, state.font, state.glyphs.items, bitmap_data, state.all_ascii);
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
            // Extract font name
            const font_name_str = std.mem.trim(u8, trimmed[5..], " \t");
            gpa.free(font.name);

            // If it's an XLFD name (starts with -), extract just the family name
            if (font_name_str.len > 0 and font_name_str[0] == '-') {
                // XLFD format: -foundry-family-weight-slant-...
                // We want the second field (family)
                var iter = std.mem.tokenizeScalar(u8, font_name_str[1..], '-');
                _ = iter.next(); // Skip foundry
                if (iter.next()) |family| {
                    font.name = try gpa.dupe(u8, family);
                } else {
                    // Fallback to full name if parsing fails
                    font.name = try gpa.dupe(u8, font_name_str);
                }
            } else {
                // Not XLFD, use as-is
                font.name = try gpa.dupe(u8, font_name_str);
            }
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

/// Parse a single glyph and its bitmap data
fn parseGlyph(gpa: Allocator, lines: *std.mem.TokenIterator(u8, .any), state: *BdfParseState, filter: LoadFilter) !bool {
    var glyph = BdfGlyph{
        .encoding = undefined,
        .bbox = .{
            .width = 0,
            .height = 0,
            .x_offset = 0,
            .y_offset = 0,
        },
        .device_width = 0,
        .bitmap_offset = state.bitmap_data.items.len,
        .bitmap_size = 0,
    };

    var found_encoding = false;
    var found_bbx = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed, "ENCODING ")) {
            const enc_str = std.mem.trim(u8, trimmed[9..], " \t");
            // Skip negative encodings
            if (std.mem.startsWith(u8, enc_str, "-")) {
                // Skip to ENDCHAR
                while (lines.next()) |skip_line| {
                    if (std.mem.eql(u8, std.mem.trim(u8, skip_line, " \t"), "ENDCHAR")) {
                        break;
                    }
                }
                return false;
            }
            glyph.encoding = try std.fmt.parseInt(u32, enc_str, 10);
            found_encoding = true;
        } else if (std.mem.startsWith(u8, trimmed, "DWIDTH ")) {
            var parts = std.mem.tokenizeAny(u8, trimmed[7..], " \t");
            glyph.device_width = try std.fmt.parseInt(i16, parts.next() orelse "0", 10);
        } else if (std.mem.startsWith(u8, trimmed, "BBX ")) {
            var parts = std.mem.tokenizeAny(u8, trimmed[4..], " \t");
            glyph.bbox.width = try std.fmt.parseInt(u16, parts.next() orelse return BdfError.InvalidFormat, 10);
            glyph.bbox.height = try std.fmt.parseInt(u16, parts.next() orelse return BdfError.InvalidFormat, 10);
            glyph.bbox.x_offset = try std.fmt.parseInt(i16, parts.next() orelse return BdfError.InvalidFormat, 10);
            glyph.bbox.y_offset = try std.fmt.parseInt(i16, parts.next() orelse return BdfError.InvalidFormat, 10);
            found_bbx = true;

            // Default device width to glyph width if not specified
            if (glyph.device_width == 0) {
                glyph.device_width = @intCast(glyph.bbox.width);
            }
        } else if (std.mem.eql(u8, trimmed, "BITMAP")) {
            if (!found_encoding or !found_bbx) {
                return BdfError.MissingRequired;
            }

            // Check if we should include this glyph
            if (!filter.matches(glyph.encoding)) {
                // Skip bitmap data
                while (lines.next()) |skip_line| {
                    if (std.mem.eql(u8, std.mem.trim(u8, skip_line, " \t"), "ENDCHAR")) {
                        break;
                    }
                }
                return false;
            }

            // Parse and store bitmap data
            const bytes_per_row = (glyph.bbox.width + 7) / 8;
            glyph.bitmap_size = @as(u32, glyph.bbox.height) * bytes_per_row;
            try state.bitmap_data.ensureUnusedCapacity(gpa, glyph.bitmap_size);

            for (0..glyph.bbox.height) |_| {
                const bitmap_line = lines.next() orelse return BdfError.InvalidBitmapData;
                const bitmap_trimmed = std.mem.trim(u8, bitmap_line, " \t");

                if (std.mem.eql(u8, bitmap_trimmed, "ENDCHAR")) {
                    return BdfError.InvalidBitmapData;
                }

                const hex_chars = bitmap_trimmed.len;
                if (hex_chars > bytes_per_row * 2) {
                    return BdfError.InvalidBitmapData;
                }

                // Convert to our byte format
                for (0..bytes_per_row) |byte_idx| {
                    var our_byte: u8 = 0;
                    const start_bit = byte_idx * 8;
                    const end_bit = @min(start_bit + 8, glyph.bbox.width);

                    if (end_bit > start_bit) {
                        // BDF stores pixels MSB-first per byte; convert to zignal's LSB-first layout
                        const raw_byte = try parseHexByte(bitmap_trimmed, byte_idx);
                        const reversed_byte = @bitReverse(raw_byte);
                        const bits_to_take: u4 = @intCast(end_bit - start_bit);
                        const mask: u8 = @intCast((@as(u16, 1) << bits_to_take) - 1);
                        our_byte = reversed_byte & mask;
                    }

                    state.bitmap_data.appendAssumeCapacity(our_byte);
                }
            }

            // Add glyph to list
            try state.glyphs.append(gpa, glyph);

            if (glyph.encoding > 127) {
                state.all_ascii = false;
            }

            // Skip to ENDCHAR
            while (lines.next()) |end_line| {
                if (std.mem.eql(u8, std.mem.trim(u8, end_line, " \t"), "ENDCHAR")) {
                    break;
                }
            }

            return true;
        } else if (std.mem.eql(u8, trimmed, "ENDCHAR")) {
            // Glyph without bitmap?
            return false;
        }
    }

    return false;
}

/// Build a sparse (glyph-map) BitmapFont from parsed glyphs
fn buildSparseFont(
    allocator: std.mem.Allocator,
    font: BdfFont,
    glyphs: []const BdfGlyph,
    bitmap_data: []u8,
    first_char: u8,
    last_char: u8,
) !BitmapFont {
    var map: std.AutoHashMap(u32, usize) = .init(allocator);
    errdefer map.deinit();

    var glyph_data_list = try allocator.alloc(GlyphData, glyphs.len);
    errdefer allocator.free(glyph_data_list);

    for (glyphs, 0..) |glyph, idx| {
        try map.put(glyph.encoding, idx);

        const adjusted_y_offset = font.ascent - (glyph.bbox.y_offset + @as(i16, @intCast(glyph.bbox.height)));

        glyph_data_list[idx] = GlyphData{
            .width = @intCast(glyph.bbox.width),
            .height = @intCast(glyph.bbox.height),
            .x_offset = glyph.bbox.x_offset,
            .y_offset = adjusted_y_offset,
            .device_width = glyph.device_width,
            .bitmap_offset = glyph.bitmap_offset,
        };
    }

    return BitmapFont{
        .name = try allocator.dupe(u8, font.name),
        .char_width = @intCast(@abs(font.bbox_width)),
        .char_height = @intCast(@abs(font.bbox_height)),
        .first_char = first_char,
        .last_char = last_char,
        .data = bitmap_data,
        .glyph_map = map,
        .glyph_data = glyph_data_list,
        .font_ascent = font.ascent,
    };
}

/// Convert parsed glyphs to BitmapFont format
fn convertToBitmapFont(
    allocator: std.mem.Allocator,
    font: BdfFont,
    glyphs: []const BdfGlyph,
    bitmap_data: []u8,
    all_ascii: bool,
) !BitmapFont {
    const char_width: u32 = @abs(font.bbox_width);
    const char_height: u32 = @abs(font.bbox_height);

    if (all_ascii and glyphs.len > 0) {
        // ASCII font - determine range
        var min_char: u8 = 255;
        var max_char: u8 = 0;

        for (glyphs) |glyph| {
            if (glyph.encoding <= 127) {
                min_char = @min(min_char, @as(u8, @intCast(glyph.encoding)));
                max_char = @max(max_char, @as(u8, @intCast(glyph.encoding)));
            }
        }

        // Check if we need per-glyph data for variable-width fonts
        var need_glyph_data = false;
        for (glyphs) |glyph| {
            if (glyph.bbox.width != char_width) {
                need_glyph_data = true;
                break;
            }
        }

        if (need_glyph_data) {
            // Variable-width ASCII font
            return buildSparseFont(allocator, font, glyphs, bitmap_data, min_char, max_char);
        } else {
            // Fixed-width ASCII font - use simple layout
            const char_count = max_char - min_char + 1;
            const bytes_per_row = (char_width + 7) / 8;
            const char_bitmap_size = char_height * bytes_per_row;

            // Reorganize bitmap data for contiguous layout
            const contiguous_data = try allocator.alloc(u8, char_count * char_bitmap_size);
            @memset(contiguous_data, 0);

            for (glyphs) |glyph| {
                if (glyph.encoding >= min_char and glyph.encoding <= max_char) {
                    const char_idx = glyph.encoding - min_char;
                    const dest_offset = char_idx * char_bitmap_size;

                    // Copy glyph bitmap to contiguous location
                    // Handle case where glyph height might be less than font height
                    const copy_height = @min(glyph.bbox.height, char_height);
                    for (0..copy_height) |row| {
                        const src_offset = glyph.bitmap_offset + row * bytes_per_row;
                        const dst_offset = dest_offset + row * bytes_per_row;
                        const glyph_bytes_per_row = (glyph.bbox.width + 7) / 8;
                        const copy_bytes = @min(glyph_bytes_per_row, bytes_per_row);
                        @memcpy(contiguous_data[dst_offset .. dst_offset + copy_bytes], bitmap_data[src_offset .. src_offset + copy_bytes]);
                    }
                }
            }

            // Free original bitmap data and use contiguous
            allocator.free(bitmap_data);

            return BitmapFont{
                .name = try allocator.dupe(u8, font.name),
                .char_width = @intCast(char_width),
                .char_height = @intCast(char_height),
                .first_char = min_char,
                .last_char = max_char,
                .data = contiguous_data,
                .glyph_map = null,
                .glyph_data = null,
                .font_ascent = font.ascent,
            };
        }
    } else {
        // Unicode font - use sparse storage
        return buildSparseFont(allocator, font, glyphs, bitmap_data, 0, 0);
    }
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

    // Test through the full API - simulate file read
    var lines = std.mem.tokenizeAny(u8, test_bdf, "\n\r");
    var state = BdfParseState{
        .font = undefined,
        .glyphs = .empty,
        .bitmap_data = .empty,
    };
    defer state.deinit(std.testing.allocator);

    state.font = try parseHeader(testing.allocator, &lines);

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "STARTCHAR")) {
            _ = try parseGlyph(std.testing.allocator, &lines, &state, .all);
        }
    }

    const bitmap_data = try state.bitmap_data.toOwnedSlice(testing.allocator);
    var font = try convertToBitmapFont(testing.allocator, state.font, state.glyphs.items, bitmap_data, true);
    defer font.deinit(testing.allocator);

    // Test converted font
    try testing.expectEqual(@as(u8, 8), font.char_height);
    try testing.expectEqual(@as(u8, 65), font.first_char);
    try testing.expectEqual(@as(u8, 65), font.last_char);

    // Test that 'A' was converted correctly
    const char_data = font.getCharData('A');
    try testing.expect(char_data != null);
    try testing.expectEqual(@as(u32, 8), char_data.?.len);

    // Check bitmap conversion
    try testing.expectEqual(@as(u8, 0x18), char_data.?[0]);
    try testing.expectEqual(@as(u8, 0x24), char_data.?[1]);
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

test "BDF save and load compressed roundtrip" {
    // Create a simple font with a few characters
    const char_width = 8;
    const char_height = 8;
    const first_char = 65; // 'A'
    const last_char = 67; // 'C'
    const num_chars = last_char - first_char + 1;
    const bytes_per_char = char_height; // 8 pixels = 1 byte per row

    // Create test bitmap data
    var bitmap_data = try testing.allocator.alloc(u8, num_chars * bytes_per_char);
    defer testing.allocator.free(bitmap_data);

    // Character 'A' pattern
    bitmap_data[0] = 0x18; // 00011000
    bitmap_data[1] = 0x24; // 00100100
    bitmap_data[2] = 0x42; // 01000010
    bitmap_data[3] = 0x42; // 01000010
    bitmap_data[4] = 0x7E; // 01111110
    bitmap_data[5] = 0x42; // 01000010
    bitmap_data[6] = 0x42; // 01000010
    bitmap_data[7] = 0x00; // 00000000

    // Character 'B' and 'C' patterns (same as original test)
    @memcpy(bitmap_data[8..16], &[_]u8{ 0x7C, 0x42, 0x42, 0x7C, 0x42, 0x42, 0x7C, 0x00 });
    @memcpy(bitmap_data[16..24], &[_]u8{ 0x3C, 0x42, 0x40, 0x40, 0x40, 0x42, 0x3C, 0x00 });

    // Duplicate the data since BitmapFont takes ownership
    const font_data = try testing.allocator.dupe(u8, bitmap_data);
    const font_name = try testing.allocator.dupe(u8, "TestFont");
    var font = BitmapFont{
        .name = font_name,
        .char_width = char_width,
        .char_height = char_height,
        .first_char = first_char,
        .last_char = last_char,
        .data = font_data,
        .glyph_map = null,
        .glyph_data = null,
        .font_ascent = 7,
    };
    defer font.deinit(testing.allocator);

    // Save to temporary compressed file
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_filename = "test_font.bdf.gz";
    const full_path = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(full_path);

    const test_path = try Io.Dir.path.join(testing.allocator, &.{ full_path, test_filename });
    defer testing.allocator.free(test_path);

    // Save compressed
    try font.save(testing.io, testing.allocator, test_path);

    // Verify the file is compressed by checking magic number
    const file = try Io.Dir.openFileAbsolute(testing.io, test_path, .{});
    defer file.close(testing.io);
    var header: [2]u8 = undefined;
    var iov = [_][]u8{header[0..]};
    _ = try file.readStreaming(testing.io, &iov);
    try testing.expectEqual(@as(u8, 0x1f), header[0]);
    try testing.expectEqual(@as(u8, 0x8b), header[1]);

    // Load it back
    var loaded_font = try BitmapFont.load(testing.io, testing.allocator, test_path, .all);
    defer loaded_font.deinit(testing.allocator);

    // Verify metadata
    try testing.expectEqual(font.char_width, loaded_font.char_width);
    try testing.expectEqual(font.char_height, loaded_font.char_height);
    try testing.expectEqual(font.first_char, loaded_font.first_char);
    try testing.expectEqual(font.last_char, loaded_font.last_char);

    // Verify bitmap data for each character
    for (first_char..last_char + 1) |char_code| {
        const original_data = font.getCharData(@intCast(char_code));
        const loaded_data = loaded_font.getCharData(@intCast(char_code));

        try testing.expect(original_data != null);
        try testing.expect(loaded_data != null);
        try testing.expectEqualSlices(u8, original_data.?, loaded_data.?);
    }
}

test "BDF save and load roundtrip" {
    // Create a simple font with a few characters
    const char_width = 8;
    const char_height = 8;
    const first_char = 65; // 'A'
    const last_char = 67; // 'C'
    const num_chars = last_char - first_char + 1;
    const bytes_per_char = char_height; // 8 pixels = 1 byte per row

    // Create test bitmap data
    var bitmap_data = try testing.allocator.alloc(u8, num_chars * bytes_per_char);
    defer testing.allocator.free(bitmap_data);

    // Character 'A' pattern
    bitmap_data[0] = 0x18; // 00011000
    bitmap_data[1] = 0x24; // 00100100
    bitmap_data[2] = 0x42; // 01000010
    bitmap_data[3] = 0x42; // 01000010
    bitmap_data[4] = 0x7E; // 01111110
    bitmap_data[5] = 0x42; // 01000010
    bitmap_data[6] = 0x42; // 01000010
    bitmap_data[7] = 0x00; // 00000000

    // Character 'B' pattern
    bitmap_data[8] = 0x7C; // 01111100
    bitmap_data[9] = 0x42; // 01000010
    bitmap_data[10] = 0x42; // 01000010
    bitmap_data[11] = 0x7C; // 01111100
    bitmap_data[12] = 0x42; // 01000010
    bitmap_data[13] = 0x42; // 01000010
    bitmap_data[14] = 0x7C; // 01111100
    bitmap_data[15] = 0x00; // 00000000

    // Character 'C' pattern
    bitmap_data[16] = 0x3C; // 00111100
    bitmap_data[17] = 0x42; // 01000010
    bitmap_data[18] = 0x40; // 01000000
    bitmap_data[19] = 0x40; // 01000000
    bitmap_data[20] = 0x40; // 01000000
    bitmap_data[21] = 0x42; // 01000010
    bitmap_data[22] = 0x3C; // 00111100
    bitmap_data[23] = 0x00; // 00000000

    // Duplicate the data since BitmapFont takes ownership
    const font_data = try testing.allocator.dupe(u8, bitmap_data);
    const font_name = try testing.allocator.dupe(u8, "TestFont");
    var font = BitmapFont{
        .name = font_name,
        .char_width = char_width,
        .char_height = char_height,
        .first_char = first_char,
        .last_char = last_char,
        .data = font_data,
        .glyph_map = null,
        .glyph_data = null,
        .font_ascent = 7, // Test with a specific baseline
    };
    defer font.deinit(testing.allocator);

    // Save to temporary file
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create path using the dir handle
    const test_filename = "test_font.bdf";

    // Save the font using the full path through tmp_dir
    const full_path = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(full_path);

    const test_path = try Io.Dir.path.join(testing.allocator, &.{ full_path, test_filename });
    defer testing.allocator.free(test_path);

    try font.save(testing.io, testing.allocator, test_path);

    // Load it back
    var loaded_font = try BitmapFont.load(testing.io, testing.allocator, test_path, .all);
    defer loaded_font.deinit(testing.allocator);

    // Verify metadata
    try testing.expectEqual(font.char_width, loaded_font.char_width);
    try testing.expectEqual(font.char_height, loaded_font.char_height);
    try testing.expectEqual(font.first_char, loaded_font.first_char);
    try testing.expectEqual(font.last_char, loaded_font.last_char);

    // Verify bitmap data for each character
    for (first_char..last_char + 1) |char_code| {
        const original_data = font.getCharData(@intCast(char_code));
        const loaded_data = loaded_font.getCharData(@intCast(char_code));

        try testing.expect(original_data != null);
        try testing.expect(loaded_data != null);
        try testing.expectEqualSlices(u8, original_data.?, loaded_data.?);
    }
}

/// Save a BitmapFont to a BDF file
pub fn save(io: Io, gpa: Allocator, font: BitmapFont, path: []const u8) !void {
    // Create buffer for BDF content
    var bdf_content: std.ArrayList(u8) = .empty;
    defer bdf_content.deinit(gpa);

    try writeBdfHeader(gpa, &bdf_content, font);

    const codepoints = try font.collectCodepoints(gpa);
    defer gpa.free(codepoints);
    for (codepoints) |encoding| {
        try writeBdfGlyph(gpa, &bdf_content, font, encoding);
    }

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

    if (font.glyph_data) |glyphs| {
        // Calculate actual BDF coordinates using the original font_ascent
        for (glyphs) |glyph| {
            max_width = @max(max_width, glyph.width);
            max_height = @max(max_height, glyph.height);

            // Reverse the transformation: bdf_y_offset = font_ascent - (internal_y_offset + height)
            const bdf_y_offset = font_ascent - (glyph.y_offset + @as(i16, glyph.height));
            min_y_offset = @min(min_y_offset, bdf_y_offset);
            min_x_offset = @min(min_x_offset, glyph.x_offset);
        }
    }

    const font_descent = -min_y_offset;

    try list.print(allocator, "FONTBOUNDINGBOX {d} {d} {d} {d}\n", .{ max_width, max_height, min_x_offset, min_y_offset });

    // Write properties
    try list.appendSlice(allocator, "STARTPROPERTIES 2\n");
    try list.print(allocator, "FONT_ASCENT {d}\n", .{font_ascent});
    try list.print(allocator, "FONT_DESCENT {d}\n", .{font_descent});
    try list.appendSlice(allocator, "ENDPROPERTIES\n");

    // Count glyphs
    const glyph_count = if (font.glyph_map) |map| map.count() else (font.last_char - font.first_char + 1);
    try list.print(allocator, "CHARS {d}\n", .{glyph_count});
}

/// Write a single glyph
fn writeBdfGlyph(allocator: Allocator, list: *std.ArrayList(u8), font: BitmapFont, encoding: u21) !void {
    const glyph_info = font.getGlyphInfo(encoding) orelse return BdfError.MissingRequired;
    const glyph_data = font.getCharData(encoding) orelse return BdfError.InvalidBitmapData;

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
