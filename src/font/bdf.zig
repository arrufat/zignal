//! BDF (Bitmap Distribution Format) font parser for zignal
//!
//! This module provides zero-dependency parsing of BDF font files,
//! enabling support for Unicode bitmap fonts like GNU Unifont.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const max_file_size = @import("../font.zig").max_file_size;
const LoadFilter = @import("../font.zig").LoadFilter;
const gzip = @import("../compression/gzip.zig");
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
    bitmap_size: usize,
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

/// Load a BDF font from a file path
/// Parameters:
/// - allocator: Memory allocator
/// - path: Path to BDF file
/// - filter: Filter for which characters to load
pub fn load(gpa: std.mem.Allocator, path: []const u8, filter: LoadFilter) !BitmapFont {
    // Check if file is gzip compressed
    const is_compressed = std.ascii.endsWithIgnoreCase(path, ".gz");

    // Read entire file into memory
    const raw_file_contents = try std.fs.cwd().readFileAlloc(path, gpa, .limited(max_file_size));
    defer gpa.free(raw_file_contents);

    // Decompress if needed
    var file_contents: []u8 = undefined;
    var decompressed_data: ?[]u8 = null;
    defer if (decompressed_data) |data| gpa.free(data);

    if (is_compressed) {
        decompressed_data = gzip.decompress(gpa, raw_file_contents, max_file_size) catch |err| switch (err) {
            error.InvalidGzipData,
            error.InvalidGzipHeader,
            error.OutputLimitExceeded,
            error.InvalidOutputLimit,
            => return BdfError.InvalidCompression,
            else => return err,
        };
        file_contents = decompressed_data.?;
    } else {
        file_contents = raw_file_contents;
    }

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
    var parsed_glyphs: usize = 0;
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
    const bitmap_data = try gpa.alloc(u8, state.bitmap_data.items.len);
    @memcpy(bitmap_data, state.bitmap_data.items);

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

fn hexCharToNibble(ch: u8) BdfError!u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'A'...'F' => ch - 'A' + 10,
        'a'...'f' => ch - 'a' + 10,
        else => BdfError.InvalidBitmapData,
    };
}

fn parseHexByte(hex: []const u8, byte_index: usize) BdfError!u8 {
    const pos = byte_index * 2;
    if (pos >= hex.len) {
        return 0;
    }

    const hi = try hexCharToNibble(hex[pos]);
    const lo = if (pos + 1 < hex.len) try hexCharToNibble(hex[pos + 1]) else 0;
    return (@as(u8, hi) << 4) | lo;
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
            if (!shouldIncludeGlyph(glyph.encoding, filter)) {
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
            glyph.bitmap_size = @as(usize, glyph.bbox.height) * bytes_per_row;

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

                    try state.bitmap_data.append(gpa, our_byte);
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

/// Check if a glyph should be included based on filter
fn shouldIncludeGlyph(encoding: u32, filter: LoadFilter) bool {
    switch (filter) {
        .all => return true,
        .ranges => |ranges| {
            // Check if encoding matches any range
            for (ranges) |range| {
                if (encoding >= range.start and encoding <= range.end) {
                    return true;
                }
            }
            return false;
        },
    }
}

/// Convert parsed glyphs to BitmapFont format
fn convertToBitmapFont(
    allocator: std.mem.Allocator,
    font: BdfFont,
    glyphs: []const BdfGlyph,
    bitmap_data: []u8,
    all_ascii: bool,
) !BitmapFont {
    const char_width = @as(usize, @intCast(@abs(font.bbox_width)));
    const char_height = @as(usize, @intCast(@abs(font.bbox_height)));

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
            var map = std.AutoHashMap(u32, usize).init(allocator);
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
                .char_width = @intCast(char_width),
                .char_height = @intCast(char_height),
                .first_char = min_char,
                .last_char = max_char,
                .data = bitmap_data,
                .glyph_map = map,
                .glyph_data = glyph_data_list,
                .font_ascent = font.ascent,
            };
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
        var map = std.AutoHashMap(u32, usize).init(allocator);
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
            .char_width = @intCast(char_width),
            .char_height = @intCast(char_height),
            .first_char = 0,
            .last_char = 0,
            .data = bitmap_data,
            .glyph_map = map,
            .glyph_data = glyph_data_list,
            .font_ascent = font.ascent,
        };
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

    const bitmap_data = try testing.allocator.alloc(u8, state.bitmap_data.items.len);
    @memcpy(bitmap_data, state.bitmap_data.items);

    var font = try convertToBitmapFont(testing.allocator, state.font, state.glyphs.items, bitmap_data, true);
    defer font.deinit(testing.allocator);

    // Test converted font
    try testing.expectEqual(@as(u8, 8), font.char_height);
    try testing.expectEqual(@as(u8, 65), font.first_char);
    try testing.expectEqual(@as(u8, 65), font.last_char);

    // Test that 'A' was converted correctly
    const char_data = font.getCharData('A');
    try testing.expect(char_data != null);
    try testing.expectEqual(@as(usize, 8), char_data.?.len);

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

    const dir_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);

    const file_path = try std.fs.path.join(testing.allocator, &.{ dir_path, "wide_font.bdf" });
    defer testing.allocator.free(file_path);

    try tmp_dir.dir.writeFile(.{ .sub_path = "wide_font.bdf", .data = wide_bdf });

    var font = try load(testing.allocator, file_path, .all);
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
    const full_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(full_path);

    const test_path = try std.fs.path.join(testing.allocator, &.{ full_path, test_filename });
    defer testing.allocator.free(test_path);

    // Save compressed
    try font.save(testing.allocator, test_path);

    // Verify the file is compressed by checking magic number
    const file = try std.fs.openFileAbsolute(test_path, .{});
    defer file.close();
    var header: [2]u8 = undefined;
    _ = try file.read(&header);
    try testing.expectEqual(@as(u8, 0x1f), header[0]);
    try testing.expectEqual(@as(u8, 0x8b), header[1]);

    // Load it back
    var loaded_font = try BitmapFont.load(testing.allocator, test_path, .all);
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
    const full_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(full_path);

    const test_path = try std.fs.path.join(testing.allocator, &.{ full_path, test_filename });
    defer testing.allocator.free(test_path);

    try font.save(testing.allocator, test_path);

    // Load it back
    var loaded_font = try BitmapFont.load(testing.allocator, test_path, .all);
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
pub fn save(gpa: Allocator, font: BitmapFont, path: []const u8) !void {
    // Create buffer for BDF content
    var bdf_content: std.ArrayList(u8) = .empty;
    defer bdf_content.deinit(gpa);

    // Write header
    try writeBdfHeader(gpa, &bdf_content, font);

    // Write glyphs
    if (font.glyph_map) |map| {
        // Variable-width/Unicode font - collect and sort encodings
        var encodings = try gpa.alloc(u32, map.count());
        defer gpa.free(encodings);

        var iter = map.iterator();
        var idx: usize = 0;
        while (iter.next()) |entry| : (idx += 1) {
            encodings[idx] = entry.key_ptr.*;
        }

        // Sort encodings for consistent output
        std.mem.sort(u32, encodings, {}, std.sort.asc(u32));

        // Write each glyph
        for (encodings) |encoding| {
            if (map.get(encoding)) |glyph_idx| {
                try writeBdfGlyph(gpa, &bdf_content, font, encoding, glyph_idx);
            }
        }
    } else {
        // Fixed-width ASCII font
        for (font.first_char..font.last_char + 1) |char_code| {
            const index = char_code - font.first_char;
            try writeBdfGlyph(gpa, &bdf_content, font, @intCast(char_code), index);
        }
    }

    try bdf_content.appendSlice(gpa, "ENDFONT\n");

    // Check if we should compress the output
    const is_compressed = std.ascii.endsWithIgnoreCase(path, ".gz");

    // Write to file
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    if (is_compressed) {
        // Compress the BDF content
        const compressed_data = try gzip.compress(gpa, bdf_content.items, .level_1, .default);
        defer gpa.free(compressed_data);
        try file.writeAll(compressed_data);
    } else {
        try file.writeAll(bdf_content.items);
    }
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
    if (std.mem.indexOf(u8, font_name, "-") != null) {
        try list.appendSlice(allocator, "FONT ");
        try list.appendSlice(allocator, font_name);
        try list.appendSlice(allocator, "\n");
    } else {
        // Otherwise build a simple XLFD name
        const font_line = try std.fmt.allocPrint(allocator, "FONT -{s}-{s}-Medium-R-Normal--{d}-{d}-75-75-P-{d}-ISO10646-1\n", .{ "zignal", font_name, height, @as(u32, height) * 10, @as(u32, width) * 6 });
        defer allocator.free(font_line);
        try list.appendSlice(allocator, font_line);
    }
    const size_line = try std.fmt.allocPrint(allocator, "SIZE {d} 75 75\n", .{height});
    defer allocator.free(size_line);
    try list.appendSlice(allocator, size_line);

    // Calculate font bounding box and ascent/descent
    var min_x_offset: i16 = 0;
    var min_y_offset: i16 = 0;
    var max_width: u16 = if (font.char_width == 0) width else font.char_width;
    var max_height: u16 = if (font.char_height == 0) height else font.char_height;

    // Use stored font_ascent if available, otherwise estimate
    const font_ascent = font.font_ascent orelse @as(i16, @intCast(height));

    if (font.glyph_data) |glyphs| {
        // Calculate actual BDF coordinates using the original font_ascent
        for (glyphs) |glyph| {
            max_width = @max(max_width, glyph.width);
            max_height = @max(max_height, glyph.height);

            // Reverse the transformation: bdf_y_offset = font_ascent - (internal_y_offset + height)
            const bdf_y_offset = font_ascent - (glyph.y_offset + @as(i16, @intCast(glyph.height)));
            min_y_offset = @min(min_y_offset, bdf_y_offset);
            min_x_offset = @min(min_x_offset, glyph.x_offset);
        }
    }

    const font_descent = -min_y_offset;

    const bbox_line = try std.fmt.allocPrint(allocator, "FONTBOUNDINGBOX {d} {d} {d} {d}\n", .{ max_width, max_height, min_x_offset, min_y_offset });
    defer allocator.free(bbox_line);
    try list.appendSlice(allocator, bbox_line);

    // Write properties
    try list.appendSlice(allocator, "STARTPROPERTIES 2\n");
    const ascent_line = try std.fmt.allocPrint(allocator, "FONT_ASCENT {d}\n", .{font_ascent});
    defer allocator.free(ascent_line);
    try list.appendSlice(allocator, ascent_line);
    const descent_line = try std.fmt.allocPrint(allocator, "FONT_DESCENT {d}\n", .{font_descent});
    defer allocator.free(descent_line);
    try list.appendSlice(allocator, descent_line);
    try list.appendSlice(allocator, "ENDPROPERTIES\n");

    // Count glyphs
    const glyph_count = if (font.glyph_map) |map| map.count() else (font.last_char - font.first_char + 1);
    const chars_line = try std.fmt.allocPrint(allocator, "CHARS {d}\n", .{glyph_count});
    defer allocator.free(chars_line);
    try list.appendSlice(allocator, chars_line);
}

/// Write a single glyph
fn writeBdfGlyph(allocator: Allocator, list: *std.ArrayList(u8), font: BitmapFont, encoding: u32, glyph_idx: usize) !void {
    const startchar_line = try std.fmt.allocPrint(allocator, "STARTCHAR U+{X:0>4}\n", .{encoding});
    defer allocator.free(startchar_line);
    try list.appendSlice(allocator, startchar_line);
    const encoding_line = try std.fmt.allocPrint(allocator, "ENCODING {d}\n", .{encoding});
    defer allocator.free(encoding_line);
    try list.appendSlice(allocator, encoding_line);

    // Get glyph info
    const glyph_info = if (font.glyph_data) |data| data[glyph_idx] else GlyphData{
        .width = font.char_width,
        .height = font.char_height,
        .x_offset = 0,
        .y_offset = 0,
        .device_width = @intCast(font.char_width),
        .bitmap_offset = 0,
    };

    // Use stored font_ascent if available, otherwise estimate
    const font_ascent = font.font_ascent orelse @as(i16, @intCast(font.char_height));

    // Reverse the y_offset transformation
    const bdf_y_offset = font_ascent - (glyph_info.y_offset + @as(i16, @intCast(glyph_info.height)));

    const swidth_line = try std.fmt.allocPrint(allocator, "SWIDTH {d} 0\n", .{glyph_info.device_width * 72});
    defer allocator.free(swidth_line);
    try list.appendSlice(allocator, swidth_line);
    const dwidth_line = try std.fmt.allocPrint(allocator, "DWIDTH {d} 0\n", .{glyph_info.device_width});
    defer allocator.free(dwidth_line);
    try list.appendSlice(allocator, dwidth_line);
    const bbx_line = try std.fmt.allocPrint(allocator, "BBX {d} {d} {d} {d}\n", .{ glyph_info.width, glyph_info.height, glyph_info.x_offset, bdf_y_offset });
    defer allocator.free(bbx_line);
    try list.appendSlice(allocator, bbx_line);
    try list.appendSlice(allocator, "BITMAP\n");

    // Write bitmap data
    const glyph_data = if (font.glyph_map != null) blk: {
        // Variable-width font
        const glyph_bytes_per_row = (@as(usize, glyph_info.width) + 7) / 8;
        const glyph_size = @as(usize, glyph_info.height) * glyph_bytes_per_row;
        break :blk font.data[glyph_info.bitmap_offset .. glyph_info.bitmap_offset + glyph_size];
    } else blk: {
        // Fixed-width ASCII font
        const bytes_per_row = font.bytesPerRow();
        const bytes_per_char = @as(usize, font.char_height) * bytes_per_row;
        const offset = glyph_idx * bytes_per_char;
        break :blk font.data[offset .. offset + bytes_per_char];
    };

    const glyph_bytes_per_row = (@as(usize, glyph_info.width) + 7) / 8;
    for (0..glyph_info.height) |row| {
        const row_start = row * glyph_bytes_per_row;
        const row_end = row_start + glyph_bytes_per_row;
        const row_data = glyph_data[row_start..row_end];

        // Convert to BDF hex format
        try convertBitmapToHex(allocator, list, row_data, glyph_info.width);
        try list.append(allocator, '\n');
    }

    try list.appendSlice(allocator, "ENDCHAR\n");
}

/// Convert bitmap data from LSB-first to MSB-first hex format
fn convertBitmapToHex(allocator: Allocator, list: *std.ArrayList(u8), row_data: []const u8, width: u8) !void {
    const hex_digits = "0123456789ABCDEF";
    const bytes_needed = (width + 7) / 8;

    // Process each byte
    for (0..bytes_needed) |i| {
        if (i >= row_data.len) break;

        const byte = row_data[i];

        // Reverse bit order: LSB-first to MSB-first
        const reversed = @bitReverse(byte);

        try list.append(allocator, hex_digits[reversed >> 4]);
        try list.append(allocator, hex_digits[reversed & 0xF]);
    }
}
