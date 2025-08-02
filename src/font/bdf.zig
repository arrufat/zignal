//! BDF (Bitmap Distribution Format) font parser for zignal
//!
//! This module provides zero-dependency parsing of BDF font files,
//! enabling support for Unicode bitmap fonts like GNU Unifont.

const std = @import("std");
const testing = std.testing;

const max_file_size = @import("../font.zig").max_file_size;
const LoadFilter = @import("../font.zig").LoadFilter;
const compression = @import("../font.zig").compression;
const BitmapFont = @import("BitmapFont.zig");
const GlyphData = @import("GlyphData.zig");
const unicode = @import("unicode.zig");

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
    bbox_width: i16,
    bbox_height: i16,
    font_ascent: i16,
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
};

/// Load a BDF font from a file path
/// Parameters:
/// - allocator: Memory allocator
/// - path: Path to BDF file
/// - filter: Filter for which characters to load
pub fn load(allocator: std.mem.Allocator, path: []const u8, filter: LoadFilter) !BitmapFont {
    // Check if file is gzip compressed
    const is_compressed = std.mem.endsWith(u8, path, ".gz");

    // Read entire file into memory
    const raw_file_contents = try std.fs.cwd().readFileAlloc(allocator, path, max_file_size);
    defer allocator.free(raw_file_contents);

    // Decompress if needed
    var file_contents: []u8 = undefined;
    var decompressed_data: ?[]u8 = null;
    defer if (decompressed_data) |data| allocator.free(data);

    if (is_compressed) {
        decompressed_data = compression.decompressGzip(allocator, raw_file_contents) catch |err| switch (err) {
            compression.CompressionError.InvalidCompression => return BdfError.InvalidCompression,
            else => return err,
        };
        file_contents = decompressed_data.?;
        std.log.info("BDF: Decompressed {s} from {} bytes to {} bytes", .{ path, raw_file_contents.len, file_contents.len });
    } else {
        file_contents = raw_file_contents;
    }

    // Use arena for temporary allocations
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Parse BDF file in a single pass
    var lines = std.mem.tokenizeAny(u8, file_contents, "\n\r");
    var state = BdfParseState{
        .font = undefined,
        .glyphs = std.ArrayList(BdfGlyph).init(arena_allocator),
        .bitmap_data = std.ArrayList(u8).init(arena_allocator),
    };

    // Parse header
    state.font = try parseHeader(&lines);

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
        if (try parseGlyph(&lines, &state, filter)) {
            parsed_glyphs += 1;
        }

        if (parsed_glyphs >= state.font.glyph_count) {
            break;
        }
    }

    // Convert to BitmapFont format
    const bitmap_data = try allocator.alloc(u8, state.bitmap_data.items.len);
    @memcpy(bitmap_data, state.bitmap_data.items);

    return convertToBitmapFont(allocator, state.font, state.glyphs.items, bitmap_data, state.all_ascii);
}

/// Parse BDF header
fn parseHeader(lines: *std.mem.TokenIterator(u8, .any)) !BdfFont {
    var font = BdfFont{
        .bbox_width = 0,
        .bbox_height = 0,
        .font_ascent = 0,
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

        if (std.mem.startsWith(u8, trimmed, "FONTBOUNDINGBOX ")) {
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
                    font.font_ascent = try std.fmt.parseInt(i16, std.mem.trim(u8, prop_trimmed[12..], " \t\""), 10);
                }
            }
        }
    }

    if (font.glyph_count == 0) {
        return BdfError.MissingRequired;
    }

    return font;
}

/// Parse a single glyph and its bitmap data
fn parseGlyph(lines: *std.mem.TokenIterator(u8, .any), state: *BdfParseState, filter: LoadFilter) !bool {
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

                // Parse hex data
                const hex_value = try std.fmt.parseInt(u32, bitmap_trimmed, 16);
                const hex_chars = bitmap_trimmed.len;
                const shift_amount = if (hex_chars < 8) (8 - hex_chars) * 4 else 0;
                const aligned_value = hex_value << @intCast(shift_amount);

                // Convert to our byte format
                for (0..bytes_per_row) |byte_idx| {
                    var our_byte: u8 = 0;
                    const start_bit = byte_idx * 8;
                    const end_bit = @min(start_bit + 8, glyph.bbox.width);

                    if (end_bit > start_bit) {
                        for (start_bit..end_bit) |bit| {
                            if (bit < 32) {
                                if ((aligned_value >> @intCast(31 - bit)) & 1 != 0) {
                                    our_byte |= @as(u8, 1) << @intCast(bit - start_bit);
                                }
                            }
                        }
                    }

                    try state.bitmap_data.append(our_byte);
                }
            }

            // Add glyph to list
            try state.glyphs.append(glyph);

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

                const adjusted_y_offset = font.font_ascent - (glyph.bbox.y_offset + @as(i16, @intCast(glyph.bbox.height)));

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
                .char_width = @intCast(char_width),
                .char_height = @intCast(char_height),
                .first_char = min_char,
                .last_char = max_char,
                .data = bitmap_data,
                .glyph_map = map,
                .glyph_data = glyph_data_list,
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
                .char_width = @intCast(char_width),
                .char_height = @intCast(char_height),
                .first_char = min_char,
                .last_char = max_char,
                .data = contiguous_data,
                .glyph_map = null,
                .glyph_data = null,
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

            const adjusted_y_offset = font.font_ascent - (glyph.bbox.y_offset + @as(i16, @intCast(glyph.bbox.height)));

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
            .char_width = @intCast(char_width),
            .char_height = @intCast(char_height),
            .first_char = 0,
            .last_char = 0,
            .data = bitmap_data,
            .glyph_map = map,
            .glyph_data = glyph_data_list,
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
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var lines = std.mem.tokenizeAny(u8, test_bdf, "\n\r");
    var state = BdfParseState{
        .font = undefined,
        .glyphs = std.ArrayList(BdfGlyph).init(arena.allocator()),
        .bitmap_data = std.ArrayList(u8).init(arena.allocator()),
    };

    state.font = try parseHeader(&lines);

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "STARTCHAR")) {
            _ = try parseGlyph(&lines, &state, .all);
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
