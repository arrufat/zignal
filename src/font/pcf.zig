//! PCF (Portable Compiled Format) font parser
//!
//! This module provides zero-dependency parsing of PCF font files,
//! a binary format used by X11 for efficient bitmap font storage.
//!
//! PCF files contain bitmap font data in an optimized binary format
//! with multiple tables containing metrics, bitmaps, encodings, and
//! optional acceleration data. This parser supports both compressed
//! and uncompressed metrics, as well as gzip-compressed PCF files.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

const native_endian = builtin.cpu.arch.endian();

const LoadFilter = @import("../font.zig").LoadFilter;
const isGzipPath = @import("../font.zig").isGzipPath;
const readFileMaybeGzip = @import("../font.zig").readFileMaybeGzip;
const writeFileMaybeGzip = @import("../font.zig").writeFileMaybeGzip;
const BitmapFont = @import("BitmapFont.zig");
const GlyphData = @import("GlyphData.zig");

/// Errors that can occur during PCF parsing
pub const PcfError = error{
    InvalidFormat,
    MissingRequired,
    InvalidTableEntry,
    InvalidBitmapData,
    TableOffsetOutOfBounds,
    InvalidGlyphCount,
    InvalidEncodingRange,
};

/// PCF format constants
const pcf_file_version = 0x70636601; // "\x01fcp" in little-endian

/// Maximum reasonable values for sanity checks
const max_table_count = 1024;
const max_glyph_count = 65536;

/// PCF table types as enum for better type safety
const TableType = enum(u32) {
    properties = (1 << 0),
    accelerators = (1 << 1),
    metrics = (1 << 2),
    bitmaps = (1 << 3),
    ink_metrics = (1 << 4),
    bdf_encodings = (1 << 5),
    swidths = (1 << 6),
    glyph_names = (1 << 7),
    bdf_accelerators = (1 << 8),
};

/// The bits of a table's format field this parser reads.
const FormatFlags = struct {
    /// Log2 of the bytes each bitmap row is padded to.
    glyph_pad: u2,
    byte_order_msb: bool,
    bit_order_msb: bool,
    compressed_metrics: bool,

    fn decode(format: u32) FormatFlags {
        return .{
            .glyph_pad = @truncate(format & 0x3),
            .byte_order_msb = format & (1 << 2) != 0,
            .bit_order_msb = format & (1 << 3) != 0,
            .compressed_metrics = format & 0x100 != 0,
        };
    }

    fn byteOrder(self: FormatFlags) std.builtin.Endian {
        return if (self.byte_order_msb) .big else .little;
    }

    /// Bytes each bitmap row is padded to.
    fn padBytes(self: FormatFlags) u32 {
        return @as(u32, 1) << self.glyph_pad;
    }
};

/// Table of contents entry for PCF files
/// Each PCF file contains multiple tables identified by type
const TableEntry = struct {
    type: u32, // Table type (see TableType enum)
    format: u32, // Format flags including byte order and padding
    size: u32, // Size of table data in bytes
    offset: u32, // Offset from start of file to table data
};

/// PCF metrics structure (unified for both compressed and uncompressed)
/// Describes the dimensions and positioning of a single glyph
const Metric = struct {
    left_sided_bearing: i16, // Distance from origin to left edge of glyph
    right_sided_bearing: i16, // Distance from origin to right edge of glyph
    character_width: i16, // Logical width for cursor advancement
    ascent: i16, // Distance from baseline to top of glyph
    descent: i16, // Distance from baseline to bottom of glyph (positive)
    attributes: u16, // Additional glyph attributes (usually 0)

    /// The fields that bound a glyph.
    const extents = .{ "left_sided_bearing", "right_sided_bearing", "character_width", "ascent", "descent" };

    fn width(self: Metric) u16 {
        return @intCast(@abs(self.right_sided_bearing - self.left_sided_bearing));
    }

    fn height(self: Metric) u16 {
        return @intCast(@abs(self.ascent + self.descent));
    }
};

/// What the accelerator table contributes: the font's vertical extent and widest glyph.
const Accelerator = struct {
    font_ascent: i32,
    font_descent: i32,
    max_bounds: Metric,
};

/// PCF encoding entry
/// Maps character codes to glyph indices using a 2D table
const EncodingEntry = struct {
    min_char_or_byte2: u16, // Minimum value for low byte of character code
    max_char_or_byte2: u16, // Maximum value for low byte of character code
    min_byte1: u16, // Minimum value for high byte of character code
    max_byte1: u16, // Maximum value for high byte of character code
    glyph_indices: []u16, // 2D array of glyph indices (0xFFFF = undefined)
};

/// PCF property entry
const Property = struct {
    name: []const u8,
    value: union(enum) {
        string: []const u8,
        integer: i32,
    },
};

/// Loads a PCF font from `path` (transparently decompressing `.pcf.gz`), keeping only characters
/// that match `filter`.
pub fn load(io: Io, allocator: std.mem.Allocator, path: []const u8, filter: LoadFilter) !BitmapFont {
    const file_contents = try readFileMaybeGzip(io, allocator, path);
    defer allocator.free(file_contents);

    // Use arena for temporary allocations
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Parse PCF file
    var reader: Io.Reader = .fixed(file_contents);

    // Read and verify header
    const header = try reader.takeVarInt(u32, .little, @sizeOf(u32));
    if (header != pcf_file_version) {
        return PcfError.InvalidFormat;
    }

    // Read table count
    const table_count = try reader.takeVarInt(u32, .little, @sizeOf(u32));
    if (table_count == 0 or table_count > max_table_count) {
        return PcfError.InvalidFormat;
    }

    // Read table of contents
    const tables = try arena_allocator.alloc(TableEntry, table_count);
    for (tables) |*table| {
        table.type = try reader.takeVarInt(u32, .little, @sizeOf(u32));
        table.format = try reader.takeVarInt(u32, .little, @sizeOf(u32));
        table.size = try reader.takeVarInt(u32, .little, @sizeOf(u32));
        table.offset = try reader.takeVarInt(u32, .little, @sizeOf(u32));
    }

    // Find required tables
    const metrics_table = findTable(tables, .metrics) orelse return PcfError.MissingRequired;
    const bitmaps_table = findTable(tables, .bitmaps) orelse return PcfError.MissingRequired;
    const encodings_table = findTable(tables, .bdf_encodings) orelse return PcfError.MissingRequired;
    const accel_table = findTable(tables, .accelerators) orelse findTable(tables, .bdf_accelerators);

    // Properties are optional, so a bad table only costs the name.
    const properties: []const Property = if (findTable(tables, .properties)) |table|
        parseProperties(arena_allocator, file_contents, table) catch &.{}
    else
        &.{};

    // Parse accelerator table for font metrics
    var font_ascent: i16 = 0;
    var max_width: u16 = 0;
    var max_height: u16 = 0;

    if (accel_table) |accel| {
        const accel_data = try parseAccelerator(file_contents, accel);
        font_ascent = std.math.cast(i16, accel_data.font_ascent) orelse std.math.maxInt(i16);
        max_width = std.math.cast(u16, @max(accel_data.max_bounds.character_width, 0)) orelse std.math.maxInt(u16);
        const total_height = @max(0, accel_data.font_ascent) + @max(0, accel_data.font_descent);
        max_height = std.math.cast(u16, total_height) orelse std.math.maxInt(u16);
    } else {
        // Default values if no accelerator table
        font_ascent = 14;
        max_width = 16;
        max_height = 16;
    }

    const encoding = try parseEncodings(arena_allocator, file_contents, encodings_table);
    const metrics = try parseMetrics(arena_allocator, file_contents, metrics_table);
    const bitmap_info = try parseBitmaps(arena_allocator, file_contents, bitmaps_table);

    const font_name = try allocator.dupe(u8, getStringProperty(properties, "FAMILY_NAME") orelse getStringProperty(properties, "FONT") orelse "PCF Font");
    errdefer allocator.free(font_name);

    // Convert to BitmapFont format
    return convertToBitmapFont(allocator, metrics, bitmap_info, encoding, filter, font_ascent, max_width, max_height, font_name);
}

/// Find a table in the table of contents
fn findTable(tables: []const TableEntry, table_type: TableType) ?TableEntry {
    const type_value = @backingInt(table_type);
    for (tables) |table| {
        if (table.type == type_value) {
            return table;
        }
    }
    return null;
}

/// Validate table bounds
fn validateTableBounds(data: []const u8, table: TableEntry) !void {
    if (table.offset > data.len) {
        return PcfError.TableOffsetOutOfBounds;
    }
    if (table.size > data.len - table.offset) {
        return PcfError.TableOffsetOutOfBounds;
    }
    if (table.size == 0) {
        return PcfError.InvalidTableEntry;
    }
}

/// A reader positioned past a table's format field, with the flags that field decoded to.
const OpenTable = struct {
    reader: Io.Reader,
    flags: FormatFlags,
    byte_order: std.builtin.Endian,
};

fn openTable(data: []const u8, table: TableEntry) !OpenTable {
    try validateTableBounds(data, table);
    var reader: Io.Reader = .fixed(data[table.offset..][0..table.size]);
    const flags = FormatFlags.decode(try reader.takeVarInt(u32, .little, @sizeOf(u32)));
    return .{ .reader = reader, .flags = flags, .byte_order = flags.byteOrder() };
}

/// Parse accelerator table
fn parseAccelerator(data: []const u8, table: TableEntry) !Accelerator {
    var t = try openTable(data, table);
    // Seven flag bytes and a pad, then the vertical metrics.
    try t.reader.discardAll(8);
    const font_ascent = try t.reader.takeVarInt(i32, t.byte_order, @sizeOf(i32));
    const font_descent = try t.reader.takeVarInt(i32, t.byte_order, @sizeOf(i32));
    try t.reader.discardAll(@sizeOf(i32)); // max_overlap
    _ = try readMetric(&t.reader, t.byte_order, false); // min_bounds
    return .{
        .font_ascent = font_ascent,
        .font_descent = font_descent,
        .max_bounds = try readMetric(&t.reader, t.byte_order, false),
    };
}

/// Parse properties table; names and string values are slices into `data`.
fn parseProperties(allocator: std.mem.Allocator, data: []const u8, table: TableEntry) ![]Property {
    var t = try openTable(data, table);

    const prop_count = try t.reader.takeVarInt(u32, t.byte_order, @sizeOf(u32));
    if (prop_count > 1000) { // Sanity check
        return PcfError.InvalidTableEntry;
    }

    // Temporary storage for property info before string resolution
    const PropertyInfo = struct {
        name_offset: u32,
        is_string: bool,
        value: i32,
    };
    const prop_infos = try allocator.alloc(PropertyInfo, prop_count);
    defer allocator.free(prop_infos);

    for (prop_infos) |*prop| {
        prop.name_offset = try t.reader.takeVarInt(u32, t.byte_order, @sizeOf(u32));
        prop.is_string = try t.reader.takeByte() != 0;
        prop.value = try t.reader.takeVarInt(i32, t.byte_order, @sizeOf(i32));
    }

    // Each property info entry is 9 bytes; the string pool starts 4-byte aligned.
    const prop_data_size = prop_count * 9;
    try t.reader.discardAll(std.mem.alignForward(usize, prop_data_size, 4) - prop_data_size);

    const string_size = try t.reader.takeVarInt(u32, t.byte_order, @sizeOf(u32));
    const string_pool = t.reader.take(string_size) catch return PcfError.InvalidTableEntry;

    const properties = try allocator.alloc(Property, prop_count);
    errdefer allocator.free(properties);
    for (prop_infos, properties) |prop_info, *property| {
        property.name = try poolString(string_pool, prop_info.name_offset);
        property.value = if (prop_info.is_string)
            .{ .string = try poolString(string_pool, @bitCast(prop_info.value)) }
        else
            .{ .integer = prop_info.value };
    }
    return properties;
}

/// The NUL-terminated string at `offset` of the pool.
fn poolString(pool: []const u8, offset: u32) ![]const u8 {
    if (offset >= pool.len) return PcfError.InvalidTableEntry;
    const rest = pool[offset..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, 0) orelse rest.len];
}

/// Get string value from properties by name
fn getStringProperty(properties: []const Property, name: []const u8) ?[]const u8 {
    for (properties) |prop| {
        if (!std.mem.eql(u8, prop.name, name)) continue;
        return switch (prop.value) {
            .string => |s| s,
            .integer => null,
        };
    }
    return null;
}

/// Read metric from stream (handles both compressed and uncompressed formats)
fn readMetric(reader: *Io.Reader, byte_order: std.builtin.Endian, compressed: bool) !Metric {
    if (compressed) {
        // Read compressed metric (5 bytes, each offset by 0x80)
        const lsb = try reader.takeByte();
        const rsb = try reader.takeByte();
        const cw = try reader.takeByte();
        const asc = try reader.takeByte();
        const desc = try reader.takeByte();

        return Metric{
            .left_sided_bearing = @as(i16, lsb) - 0x80,
            .right_sided_bearing = @as(i16, rsb) - 0x80,
            .character_width = @as(i16, cw) - 0x80,
            .ascent = @as(i16, asc) - 0x80,
            .descent = @as(i16, desc) - 0x80,
            .attributes = 0,
        };
    } else {
        // Read uncompressed metric (6 i16 values)
        return Metric{
            .left_sided_bearing = try reader.takeVarInt(i16, byte_order, 2),
            .right_sided_bearing = try reader.takeVarInt(i16, byte_order, 2),
            .character_width = try reader.takeVarInt(i16, byte_order, 2),
            .ascent = try reader.takeVarInt(i16, byte_order, 2),
            .descent = try reader.takeVarInt(i16, byte_order, 2),
            .attributes = try reader.takeVarInt(u16, byte_order, 2),
        };
    }
}

/// Writes an uncompressed metric, little-endian, as `readMetric` reads it.
fn writeMetric(writer: *Io.Writer, m: Metric) !void {
    try writer.writeInt(i16, m.left_sided_bearing, .little);
    try writer.writeInt(i16, m.right_sided_bearing, .little);
    try writer.writeInt(i16, m.character_width, .little);
    try writer.writeInt(i16, m.ascent, .little);
    try writer.writeInt(i16, m.descent, .little);
    try writer.writeInt(u16, m.attributes, .little);
}

/// Parse encodings table
fn parseEncodings(allocator: std.mem.Allocator, data: []const u8, table: TableEntry) !EncodingEntry {
    var t = try openTable(data, table);

    var encoding: EncodingEntry = undefined;
    encoding.min_char_or_byte2 = try t.reader.takeVarInt(u16, t.byte_order, @sizeOf(u16));
    encoding.max_char_or_byte2 = try t.reader.takeVarInt(u16, t.byte_order, @sizeOf(u16));
    encoding.min_byte1 = try t.reader.takeVarInt(u16, t.byte_order, @sizeOf(u16));
    encoding.max_byte1 = try t.reader.takeVarInt(u16, t.byte_order, @sizeOf(u16));
    try t.reader.discardAll(@sizeOf(u16)); // default_char

    // Calculate total encodings with overflow protection
    const cols: u32 = encoding.max_char_or_byte2 - encoding.min_char_or_byte2 + 1;
    const rows: u32 = encoding.max_byte1 - encoding.min_byte1 + 1;
    const encodings_count = cols * rows;

    // Both halves are bytes, so codepoints fit u16 and ascend with the table index.
    if (encodings_count > max_glyph_count or encoding.max_byte1 > 0xFF or encoding.max_char_or_byte2 > 0xFF) {
        return PcfError.InvalidEncodingRange;
    }

    // Read glyph indices in bulk, swapping bytes only if the file endianness differs
    encoding.glyph_indices = try allocator.alloc(u16, encodings_count);
    try t.reader.readSliceAll(std.mem.sliceAsBytes(encoding.glyph_indices));
    if (t.byte_order != native_endian) {
        for (encoding.glyph_indices) |*index| index.* = @byteSwap(index.*);
    }

    return encoding;
}

/// Parse metrics table
fn parseMetrics(allocator: std.mem.Allocator, data: []const u8, table: TableEntry) ![]Metric {
    var t = try openTable(data, table);
    const compressed = t.flags.compressed_metrics;
    // Compressed metrics come with a short count.
    const count: u32 = if (compressed) try t.reader.takeVarInt(u16, t.byte_order, 2) else try t.reader.takeVarInt(u32, t.byte_order, 4);
    if (count > max_glyph_count) return PcfError.InvalidGlyphCount;
    const metrics = try allocator.alloc(Metric, count);
    for (metrics) |*metric| metric.* = try readMetric(&t.reader, t.byte_order, compressed);
    return metrics;
}

/// Bitmap parsing result
const BitmapInfo = struct {
    /// The bitmap table's pixel data, borrowed from the file.
    bitmap_data: []const u8,
    offsets: []u32,
    flags: FormatFlags,
};

/// Parse bitmaps table
fn parseBitmaps(allocator: std.mem.Allocator, data: []const u8, table: TableEntry) !BitmapInfo {
    var t = try openTable(data, table);

    const glyph_count = try t.reader.takeVarInt(u32, t.byte_order, @sizeOf(u32));
    if (glyph_count > max_glyph_count) {
        return PcfError.InvalidGlyphCount;
    }

    // Read bitmap offsets in bulk, swapping bytes only if the file endianness differs
    const offsets = try allocator.alloc(u32, glyph_count);
    try t.reader.readSliceAll(std.mem.sliceAsBytes(offsets));
    if (t.byte_order != native_endian) {
        for (offsets) |*offset| offset.* = @byteSwap(offset.*);
    }

    // The data size for each row padding (1, 2, 4, 8 bytes); the format says which applies.
    var sizes: [4]u32 = undefined;
    for (&sizes) |*size| size.* = try t.reader.takeVarInt(u32, t.byte_order, @sizeOf(u32));
    const data_size = sizes[t.flags.glyph_pad];

    return .{
        .bitmap_data = try t.reader.take(data_size),
        .offsets = offsets,
        .flags = t.flags,
    };
}

/// Convert a single glyph bitmap from PCF format to our format.
/// The caller must have reserved capacity in `output` for the converted bytes.
fn convertGlyphBitmap(bitmap_data: []const u8, offset: u32, width: u16, height: u16, flags: FormatFlags, output: *std.ArrayList(u8)) void {
    const bytes_per_row = GlyphData.bytesForWidth(width);
    const pcf_row_bytes = std.mem.alignForward(u32, bytes_per_row, flags.padBytes());

    // Convert each row
    for (0..height) |row| {
        const src_offset = offset + row * pcf_row_bytes;

        // Convert bitmap bytes
        for (0..bytes_per_row) |byte_idx| {
            if (src_offset + byte_idx < bitmap_data.len) {
                const byte = bitmap_data[src_offset + byte_idx];
                // PCF uses MSB first by default, convert if needed
                output.appendAssumeCapacity(if (flags.bit_order_msb) @bitReverse(byte) else byte);
            } else {
                output.appendAssumeCapacity(0);
            }
        }
    }
}

/// Convert parsed PCF data to BitmapFont format
fn convertToBitmapFont(
    gpa: std.mem.Allocator,
    metrics: []const Metric,
    bitmap_info: BitmapInfo,
    encoding: EncodingEntry,
    filter: LoadFilter,
    ascent: i16,
    max_width: u16,
    max_height: u16,
    name: []u8,
) !BitmapFont {
    // Determine which glyphs to include
    var glyph_list: std.ArrayList(struct {
        codepoint: u21,
        glyph_index: u32,
        metric: Metric,
    }) = .empty;
    defer glyph_list.deinit(gpa);

    // PCF uses a 2D encoding table: rows are byte1 (high byte), columns are byte2 (low byte)
    const chars_per_row = encoding.max_char_or_byte2 - encoding.min_char_or_byte2 + 1;

    // Build glyph list based on encodings and filter
    for (encoding.glyph_indices, 0..) |glyph_index, encoding_index| {
        if (glyph_index == 0xFFFF) continue; // Skip non-existent glyphs

        const row = encoding_index / chars_per_row;
        const col = encoding_index % chars_per_row;
        const codepoint: u21 = @intCast(((encoding.min_byte1 + row) << 8) | (encoding.min_char_or_byte2 + col));

        if (!filter.matches(codepoint)) continue;
        if (glyph_index >= metrics.len) continue;
        try glyph_list.append(gpa, .{ .codepoint = codepoint, .glyph_index = glyph_index, .metric = metrics[glyph_index] });
    }

    // Pre-calculate total bitmap size needed
    var total_bitmap_size: u32 = 0;
    for (glyph_list.items) |glyph_info| {
        total_bitmap_size += GlyphData.bytesForWidth(glyph_info.metric.width()) * glyph_info.metric.height();
    }

    // Pre-allocate converted bitmap buffer
    var converted_bitmaps: std.ArrayList(u8) = .empty;
    defer converted_bitmaps.deinit(gpa);
    try converted_bitmaps.ensureTotalCapacity(gpa, total_bitmap_size);

    // The encoding table walks codepoints in ascending order, so the table comes out sorted.
    const glyphs = try gpa.alloc(BitmapFont.Entry, glyph_list.items.len);
    errdefer gpa.free(glyphs);

    for (glyph_list.items, glyphs) |glyph_info, *entry| {
        const metric = glyph_info.metric;
        const converted_offset = converted_bitmaps.items.len;

        if (glyph_info.glyph_index >= bitmap_info.offsets.len) {
            return PcfError.InvalidBitmapData;
        }
        const bitmap_offset = bitmap_info.offsets[glyph_info.glyph_index];
        if (bitmap_offset >= bitmap_info.bitmap_data.len) {
            return PcfError.InvalidBitmapData;
        }
        convertGlyphBitmap(bitmap_info.bitmap_data, bitmap_offset, metric.width(), metric.height(), bitmap_info.flags, &converted_bitmaps);

        entry.* = .{
            .codepoint = glyph_info.codepoint,
            .info = .{
                .width = @intCast(metric.width()),
                .height = @intCast(metric.height()),
                .x_offset = metric.left_sided_bearing,
                // Adjust y_offset to account for font baseline
                .y_offset = ascent - metric.ascent,
                .device_width = metric.character_width,
                .bitmap_offset = converted_offset,
            },
        };
    }

    return .{
        .name = name,
        .char_width = @intCast(@min(max_width, 255)),
        .char_height = @intCast(@min(max_height, 255)),
        .data = try converted_bitmaps.toOwnedSlice(gpa),
        .glyphs = glyphs,
    };
}

// --- PCF Writing Support ---

const TableBuffer = struct {
    table_type: TableType,
    data: []u8,
};

const GlyphEntry = struct {
    codepoint: u21,
    metrics: Metric,
    width: u8,
    height: u8,
    bitmap_offset: u32,
};

fn buildGlyphEntries(
    allocator: Allocator,
    font: BitmapFont,
) !struct {
    entries: []GlyphEntry,
    bitmap_data: []u8,
    pad_sizes: [4]u32,
} {
    const entries = try allocator.alloc(GlyphEntry, font.glyphs.len);
    errdefer allocator.free(entries);

    var bitmap_buffer: std.ArrayList(u8) = .empty;
    errdefer bitmap_buffer.deinit(allocator);

    var pad_sizes: [4]u32 = @splat(0);

    const font_ascent = font.ascent();

    for (font.glyphs, entries) |glyph, *entry| {
        const glyph_info = glyph.info;
        const width = glyph_info.width;
        const height = glyph_info.height;

        const left = glyph_info.x_offset;
        const glyph_ascent = font_ascent - glyph_info.y_offset;

        const bitmap_offset: u32 = @intCast(bitmap_buffer.items.len);
        try bitmap_buffer.appendSlice(allocator, font.bitmap(glyph_info));

        // Accumulate table sizes for each PCF padding option (1, 2, 4, 8 bytes)
        for (&pad_sizes, 0..) |*size, pad_idx| {
            const padded_row = std.mem.alignForward(u32, glyph_info.bytesPerRow(), @as(u32, 1) << @intCast(pad_idx));
            size.* += padded_row * height;
        }

        entry.* = .{
            .codepoint = glyph.codepoint,
            .metrics = .{
                .left_sided_bearing = left,
                .right_sided_bearing = @as(i16, width) + left,
                .character_width = glyph_info.device_width,
                .ascent = glyph_ascent,
                .descent = @max(@as(i16, height) - glyph_ascent, 0),
                .attributes = 0,
            },
            .width = width,
            .height = height,
            .bitmap_offset = bitmap_offset,
        };
    }

    return .{
        .entries = entries,
        .bitmap_data = try bitmap_buffer.toOwnedSlice(allocator),
        .pad_sizes = pad_sizes,
    };
}

fn writeMetricsTable(allocator: Allocator, glyphs: []const GlyphEntry) ![]u8 {
    const header_size = @sizeOf(u32) * 2;
    const metrics_size = @sizeOf(i16) * 5 + @sizeOf(u16);
    const total = header_size + glyphs.len * metrics_size;
    const buffer = try allocator.alloc(u8, total);
    var writer = Io.Writer.fixed(buffer);

    try writer.writeInt(u32, 0, .little); // Format: uncompressed metrics
    try writer.writeInt(u32, @intCast(glyphs.len), .little);
    for (glyphs) |glyph| try writeMetric(&writer, glyph.metrics);

    return buffer;
}

fn writeBitmapsTable(
    allocator: Allocator,
    glyphs: []const GlyphEntry,
    bitmap_data: []const u8,
    pad_sizes: [4]u32,
) ![]u8 {
    const glyph_count = glyphs.len;
    const header_size = @sizeOf(u32) * 2;
    const offsets_size = glyph_count * @sizeOf(u32);
    const sizes_size = 4 * @sizeOf(u32);
    const total = header_size + offsets_size + sizes_size + bitmap_data.len;

    const buffer = try allocator.alloc(u8, total);
    var writer = Io.Writer.fixed(buffer);

    try writer.writeInt(u32, 0, .little); // Format
    try writer.writeInt(u32, @intCast(glyph_count), .little);

    for (glyphs) |glyph| {
        try writer.writeInt(u32, glyph.bitmap_offset, .little);
    }

    for (pad_sizes) |sz| {
        try writer.writeInt(u32, sz, .little);
    }

    try writer.writeAll(bitmap_data);

    return buffer;
}

fn writeEncodingTable(
    allocator: Allocator,
    glyphs: []const GlyphEntry,
) ![]u8 {
    if (glyphs.len == 0) return allocator.alloc(u8, 0);

    var min_byte1: u16 = 0xFFFF;
    var max_byte1: u16 = 0;
    var min_byte2: u16 = 0xFFFF;
    var max_byte2: u16 = 0;

    for (glyphs) |g| {
        const high: u16 = @intCast(g.codepoint >> 8);
        const low: u16 = @intCast(g.codepoint & 0xFF);
        if (high < min_byte1) min_byte1 = high;
        if (high > max_byte1) max_byte1 = high;
        if (low < min_byte2) min_byte2 = low;
        if (low > max_byte2) max_byte2 = low;
    }

    // Default char (usually space or first char)
    const default_char: u16 = 0;

    const rows: usize = max_byte1 - min_byte1 + 1;
    const cols: usize = max_byte2 - min_byte2 + 1;
    const table_len = rows * cols;

    var glyph_indices = try allocator.alloc(u16, table_len);
    defer allocator.free(glyph_indices);
    @memset(glyph_indices, 0xFFFF);

    for (glyphs, 0..) |glyph, idx| {
        const high: usize = (glyph.codepoint >> 8) - min_byte1;
        const low: usize = (glyph.codepoint & 0xFF) - min_byte2;
        const pos = high * cols + low;
        if (pos < glyph_indices.len) {
            glyph_indices[pos] = @intCast(idx);
        }
    }

    const header_size = @sizeOf(u32) + 5 * @sizeOf(u16);
    const table_size = table_len * @sizeOf(u16);
    const buffer = try allocator.alloc(u8, header_size + table_size);
    var writer = Io.Writer.fixed(buffer);

    try writer.writeInt(u32, 0, .little); // Format
    try writer.writeInt(u16, min_byte2, .little);
    try writer.writeInt(u16, max_byte2, .little);
    try writer.writeInt(u16, min_byte1, .little);
    try writer.writeInt(u16, max_byte1, .little);
    try writer.writeInt(u16, default_char, .little);

    for (glyph_indices) |index| {
        try writer.writeInt(u16, index, .little);
    }

    return buffer;
}

fn writePropertiesTable(allocator: Allocator, font: BitmapFont) ![]u8 {
    var string_pool: std.ArrayList(u8) = .empty;
    defer string_pool.deinit(allocator);

    var props: std.ArrayList(Property) = .empty;
    defer props.deinit(allocator);

    try props.append(allocator, .{ .name = "FONT", .value = .{ .string = font.name } });
    try props.append(allocator, .{ .name = "PIXEL_SIZE", .value = .{ .integer = font.char_height } });
    try props.append(allocator, .{ .name = "POINT_SIZE", .value = .{ .integer = @as(i32, font.char_height) * 10 } });
    try props.append(allocator, .{ .name = "RESOLUTION_X", .value = .{ .integer = 75 } });
    try props.append(allocator, .{ .name = "RESOLUTION_Y", .value = .{ .integer = 75 } });
    try props.append(allocator, .{ .name = "SPACING", .value = .{ .string = if (font.isMonospace()) "C" else "P" } });

    if (font.font_ascent) |asc| {
        try props.append(allocator, .{ .name = "FONT_ASCENT", .value = .{ .integer = asc } });
        try props.append(allocator, .{ .name = "FONT_DESCENT", .value = .{ .integer = @as(i32, font.char_height) - asc } });
    }

    // Add strings to pool and record offsets
    const prop_entries = try allocator.alloc(struct { name_off: u32, is_string: u8, val: i32 }, props.items.len);
    defer allocator.free(prop_entries);

    for (props.items, prop_entries) |p, *entry| {
        const name_off: u32 = @intCast(string_pool.items.len);
        try string_pool.appendSlice(allocator, p.name);
        try string_pool.append(allocator, 0);

        entry.* = switch (p.value) {
            .integer => |value| .{ .name_off = name_off, .is_string = 0, .val = value },
            .string => |value| blk: {
                const val_off: u32 = @intCast(string_pool.items.len);
                try string_pool.appendSlice(allocator, value);
                try string_pool.append(allocator, 0);
                break :blk .{ .name_off = name_off, .is_string = 1, .val = @bitCast(val_off) };
            },
        };
    }

    const prop_data_size = prop_entries.len * 9;
    const padding = std.mem.alignForward(usize, prop_data_size, 4) - prop_data_size;

    const total_size = 4 + 4 + prop_data_size + padding + 4 + string_pool.items.len;
    const buffer = try allocator.alloc(u8, total_size);
    var writer = Io.Writer.fixed(buffer);

    try writer.writeInt(u32, 0, .little); // Format
    try writer.writeInt(u32, @intCast(prop_entries.len), .little);

    for (prop_entries) |pe| {
        try writer.writeInt(u32, pe.name_off, .little);
        try writer.writeByte(pe.is_string);
        try writer.writeInt(i32, pe.val, .little);
    }

    try writer.splatByteAll(0, padding);

    try writer.writeInt(u32, @intCast(string_pool.items.len), .little);
    try writer.writeAll(string_pool.items);

    return buffer;
}

fn writeAcceleratorsTable(allocator: Allocator, glyphs: []const GlyphEntry, font_ascent: i16, font_descent: i16) ![]u8 {
    // Fold global bounds over all glyphs, starting from saturated sentinels
    var min_bounds: Metric = std.mem.zeroes(Metric);
    var max_bounds: Metric = std.mem.zeroes(Metric);
    if (glyphs.len > 0) {
        inline for (Metric.extents) |field| {
            @field(min_bounds, field) = std.math.maxInt(i16);
            @field(max_bounds, field) = std.math.minInt(i16);
        }
        for (glyphs) |g| {
            inline for (Metric.extents) |field| {
                @field(min_bounds, field) = @min(@field(min_bounds, field), @field(g.metrics, field));
                @field(max_bounds, field) = @max(@field(max_bounds, field), @field(g.metrics, field));
            }
        }
    }

    // Size calculation
    // Format (4) + bools (8) + padding (1) + metrics (12) + min_bounds (12) + max_bounds (12)
    // Metric size = 6 * 2 = 12 bytes
    const size = 4 + 8 + 1 + 12 + 12 + 12;
    const buffer = try allocator.alloc(u8, size);
    var writer = Io.Writer.fixed(buffer);

    try writer.writeInt(u32, 0, .little); // Format (no accel w/ inkbounds)
    // noOverlap, constantMetrics, terminalFont, constantWidth, inkInside, inkMetrics,
    // drawDirection and padding
    try writer.splatByteAll(0, 8);

    try writer.writeInt(i32, font_ascent, .little);
    try writer.writeInt(i32, font_descent, .little);
    try writer.writeInt(i32, max_bounds.right_sided_bearing, .little); // max_overlap approximation
    try writeMetric(&writer, min_bounds);
    try writeMetric(&writer, max_bounds);

    return buffer;
}

/// Save a BitmapFont to a PCF file
pub fn save(io: Io, gpa: Allocator, font: BitmapFont, path: []const u8) !void {
    const glyph_data = try buildGlyphEntries(gpa, font);
    defer gpa.free(glyph_data.entries);
    defer gpa.free(glyph_data.bitmap_data);

    const metrics_table = try writeMetricsTable(gpa, glyph_data.entries);
    defer gpa.free(metrics_table);

    const bitmaps_table = try writeBitmapsTable(
        gpa,
        glyph_data.entries,
        glyph_data.bitmap_data,
        glyph_data.pad_sizes,
    );
    defer gpa.free(bitmaps_table);

    const encoding_table = try writeEncodingTable(gpa, glyph_data.entries);
    defer gpa.free(encoding_table);

    const properties_table = try writePropertiesTable(gpa, font);
    defer gpa.free(properties_table);

    const font_ascent = font.ascent();
    const font_descent = if (font.font_ascent) |asc| @as(i16, font.char_height) - asc else 0;
    const accel_table = try writeAcceleratorsTable(gpa, glyph_data.entries, font_ascent, font_descent);
    defer gpa.free(accel_table);

    const tables = [_]TableBuffer{
        .{ .table_type = .properties, .data = properties_table },
        .{ .table_type = .accelerators, .data = accel_table },
        .{ .table_type = .metrics, .data = metrics_table },
        .{ .table_type = .bitmaps, .data = bitmaps_table },
        .{ .table_type = .bdf_encodings, .data = encoding_table },
    };

    const header_size = 8 + tables.len * 16;
    var offsets: [tables.len]u32 = @splat(0);
    var current_offset: usize = header_size;

    for (tables, 0..) |table, idx| {
        current_offset = std.mem.alignForward(usize, current_offset, 4);
        offsets[idx] = @intCast(current_offset);
        current_offset += table.data.len;
    }

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try aw.ensureTotalCapacity(current_offset + 1024);

    try aw.writer.writeInt(u32, pcf_file_version, .little);
    try aw.writer.writeInt(u32, tables.len, .little);

    for (tables, 0..) |table, idx| {
        try aw.writer.writeInt(u32, @backingInt(table.table_type), .little);
        try aw.writer.writeInt(u32, 0, .little); // format
        try aw.writer.writeInt(u32, @intCast(table.data.len), .little);
        try aw.writer.writeInt(u32, offsets[idx], .little);
    }

    for (tables, 0..) |table, idx| {
        const target_offset = offsets[idx];
        const current_pos = aw.writer.end;
        if (current_pos < target_offset) {
            try aw.writer.splatByteAll(0, target_offset - current_pos);
        }
        try aw.writer.writeAll(table.data);
    }

    try writeFileMaybeGzip(io, gpa, path, aw.written());
}

test "FormatFlags decoding" {
    try testing.expectEqual(FormatFlags{ .glyph_pad = 0, .byte_order_msb = false, .bit_order_msb = false, .compressed_metrics = false }, FormatFlags.decode(0));
    // Typical compressed metrics format.
    try testing.expectEqual(FormatFlags{ .glyph_pad = 0, .byte_order_msb = true, .bit_order_msb = true, .compressed_metrics = true }, FormatFlags.decode(0x10C));
    // Glyph pad 1 (2-byte rows), scan unit 3 (ignored).
    const padded = FormatFlags.decode(0x31);
    try testing.expectEqual(FormatFlags{ .glyph_pad = 1, .byte_order_msb = false, .bit_order_msb = false, .compressed_metrics = false }, padded);
    try testing.expectEqual(2, padded.padBytes());
}

test "Table bounds validation" {
    const data: [100]u8 = @splat(0);

    // Valid table
    const valid_table = TableEntry{
        .type = @backingInt(TableType.metrics),
        .format = 0,
        .size = 50,
        .offset = 20,
    };
    try validateTableBounds(&data, valid_table);

    // Invalid offset
    const invalid_offset_table = TableEntry{
        .type = @backingInt(TableType.metrics),
        .format = 0,
        .size = 50,
        .offset = 200,
    };
    try testing.expectError(PcfError.TableOffsetOutOfBounds, validateTableBounds(&data, invalid_offset_table));

    // Invalid size
    const invalid_size_table = TableEntry{
        .type = @backingInt(TableType.metrics),
        .format = 0,
        .size = 100,
        .offset = 50,
    };
    try testing.expectError(PcfError.TableOffsetOutOfBounds, validateTableBounds(&data, invalid_size_table));
}

test "Metric reading" {
    var buffer: [64]u8 = undefined;
    var writer = Io.Writer.fixed(&buffer);

    // Write compressed metric
    try writer.writeByte(0x82); // LSB: 2 (0x82 - 0x80)
    try writer.writeByte(0x88); // RSB: 8 (0x88 - 0x80)
    try writer.writeByte(0x86); // Width: 6 (0x86 - 0x80)
    try writer.writeByte(0x90); // Ascent: 16 (0x90 - 0x80)
    try writer.writeByte(0x82); // Descent: 2 (0x82 - 0x80)

    var reader: Io.Reader = .fixed(buffer[0..writer.end]);

    const metric = try readMetric(&reader, .little, true);
    try testing.expectEqual(@as(i16, 2), metric.left_sided_bearing);
    try testing.expectEqual(@as(i16, 8), metric.right_sided_bearing);
    try testing.expectEqual(@as(i16, 6), metric.character_width);
    try testing.expectEqual(@as(i16, 16), metric.ascent);
    try testing.expectEqual(@as(i16, 2), metric.descent);
}

test "Properties parsing" {
    const allocator = testing.allocator;

    // Create a minimal properties table with just one integer property for simplicity
    var buffer: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);

    // Write format (little endian, no special flags)
    try writer.writeInt(u32, 0x00000000, .little);

    // Write number of properties (1)
    try writer.writeInt(u32, 1, .little);

    // Property 1: PIXEL_SIZE (integer)
    try writer.writeInt(u32, 0, .little); // name offset
    try writer.writeByte(0); // is_string = false
    try writer.writeInt(i32, 16, .little); // value = 16

    // Padding (1 property -> need 3 bytes padding to align to 4)
    try writer.writeByte(0);
    try writer.writeByte(0);
    try writer.writeByte(0);

    // String pool size
    try writer.writeInt(u32, 11, .little);

    // String pool
    try writer.writeAll("PIXEL_SIZE\x00");

    const table = TableEntry{
        .type = @backingInt(TableType.properties),
        .format = 0,
        .size = @intCast(writer.end),
        .offset = 0,
    };

    const props = try parseProperties(allocator, buffer[0..writer.end], table);
    defer allocator.free(props);

    try testing.expectEqual(@as(usize, 1), props.len);
    try testing.expectEqualStrings("PIXEL_SIZE", props[0].name);
    try testing.expectEqual(@as(i32, 16), props[0].value.integer);
}

fn expectRoundtrip(file_name: []const u8) !void {
    const font = BitmapFont.test_font;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);
    const path = try Io.Dir.path.join(testing.allocator, &.{ tmp_path, file_name });
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
    try testing.expectEqualStrings(font.name, loaded.name);
    try testing.expectEqual(font.char_width, loaded.char_width);
    try testing.expectEqual(font.char_height, loaded.char_height);
    try testing.expectEqual(font.glyphCount(), loaded.glyphCount());
    for (font.glyphs) |entry| {
        try testing.expectEqualSlices(u8, font.getCharData(entry.codepoint).?, loaded.getCharData(entry.codepoint).?);
    }
}

test "PCF save and load roundtrip" {
    try expectRoundtrip("test.pcf");
}

test "PCF save and load compressed roundtrip" {
    try expectRoundtrip("test.pcf.gz");
}
