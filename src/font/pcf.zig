//! PCF (Portable Compiled Format) font parser for zignal
//!
//! This module provides zero-dependency parsing of PCF font files,
//! a binary format used by X11 for efficient bitmap font storage.
//!
//! PCF files contain bitmap font data in an optimized binary format
//! with multiple tables containing metrics, bitmaps, encodings, and
//! optional acceleration data. This parser supports both compressed
//! and uncompressed metrics, as well as gzip-compressed PCF files.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const LoadFilter = @import("../font.zig").LoadFilter;
const max_file_size = @import("../font.zig").max_file_size;
const gzip = @import("../compression/gzip.zig");
const BitmapFont = @import("BitmapFont.zig");
const GlyphData = @import("GlyphData.zig");

/// Errors that can occur during PCF parsing
pub const PcfError = error{
    InvalidFormat,
    InvalidVersion,
    MissingRequired,
    InvalidTableEntry,
    InvalidBitmapData,
    AllocationFailed,
    UnsupportedFormat,
    InvalidCompression,
    TableOffsetOutOfBounds,
    InvalidGlyphCount,
    InvalidMetricsFormat,
    InvalidEncodingRange,
    BitmapSizeMismatch,
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

/// PCF format flags structure for better type safety
const FormatFlags = struct {
    const glyph_pad_mask: u32 = 0x3;
    const byte_order_mask: u32 = 1 << 2;
    const bit_order_mask: u32 = 1 << 3;
    const scan_unit_mask: u32 = 0x30;
    const scan_unit_shift: u5 = 4;
    const compressed_metrics_mask: u32 = 0x100;
    const accel_w_inkbounds_mask: u32 = 0x200;
    const ink_bounds_mask: u32 = 0x400;

    // Helper to decode format flags from u32
    pub fn decode(format: u32) FormatFlags {
        return FormatFlags{
            .glyph_pad = @as(u2, @truncate(format & glyph_pad_mask)),
            .byte_order_msb = (format & byte_order_mask) != 0,
            .bit_order_msb = (format & bit_order_mask) != 0,
            .scan_unit = @as(u2, @truncate((format & scan_unit_mask) >> scan_unit_shift)),
            .compressed_metrics = (format & compressed_metrics_mask) != 0,
            .accel_w_inkbounds = (format & accel_w_inkbounds_mask) != 0,
            .ink_bounds = (format & ink_bounds_mask) != 0,
        };
    }

    glyph_pad: u2,
    byte_order_msb: bool,
    bit_order_msb: bool,
    scan_unit: u2,
    accel_w_inkbounds: bool,
    compressed_metrics: bool,
    ink_bounds: bool,
};

/// PCF glyph padding values
const GlyphPadding = enum(u2) {
    pad_1 = 0,
    pad_2 = 1,
    pad_4 = 2,
    pad_8 = 3,

    pub fn getPadBytes(self: GlyphPadding) u32 {
        return switch (self) {
            .pad_1 => 1,
            .pad_2 => 2,
            .pad_4 => 4,
            .pad_8 => 8,
        };
    }
};

/// Get byte order from format field
fn getByteOrder(format: u32) std.builtin.Endian {
    const flags = FormatFlags.decode(format);
    return if (flags.byte_order_msb) .big else .little;
}

/// Calculate glyph dimensions from metric
fn getGlyphDimensions(metric: Metric) struct { width: u16, height: u16 } {
    return .{
        .width = @intCast(@abs(metric.right_sided_bearing - metric.left_sided_bearing)),
        .height = @intCast(@abs(metric.ascent + metric.descent)),
    };
}

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
};

/// PCF accelerator table
const Accelerator = struct {
    no_overlap: bool,
    constant_metrics: bool,
    terminal_font: bool,
    constant_width: bool,
    ink_inside: bool,
    ink_metrics: bool,
    draw_direction: bool,
    font_ascent: i32,
    font_descent: i32,
    max_overlap: i32,
    min_bounds: Metric,
    max_bounds: Metric,
    ink_min_bounds: ?Metric,
    ink_max_bounds: ?Metric,
};

/// PCF encoding entry
/// Maps character codes to glyph indices using a 2D table
const EncodingEntry = struct {
    min_char_or_byte2: u16, // Minimum value for low byte of character code
    max_char_or_byte2: u16, // Maximum value for low byte of character code
    min_byte1: u16, // Minimum value for high byte of character code
    max_byte1: u16, // Maximum value for high byte of character code
    default_char: u16, // Character to use for undefined codes
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

/// PCF properties table result
const PropertiesInfo = struct {
    properties: []Property,
    string_pool: []u8, // Owns the string data
};

/// Load a PCF font from a file path
/// Parameters:
/// - allocator: Memory allocator
/// - path: Path to PCF file
/// - filter: Filter for which characters to load
pub fn load(allocator: std.mem.Allocator, path: []const u8, filter: LoadFilter) !BitmapFont {
    // Check if file is gzip compressed
    const is_compressed = std.mem.endsWith(u8, path, ".gz");

    // Read file into memory
    const raw_file_contents = try std.fs.cwd().readFileAlloc(path, allocator, .limited(max_file_size));
    defer allocator.free(raw_file_contents);

    // Decompress if needed
    var file_contents: []u8 = undefined;
    var decompressed_data: ?[]u8 = null;
    defer if (decompressed_data) |data| allocator.free(data);

    if (is_compressed) {
        decompressed_data = gzip.decompress(allocator, raw_file_contents, max_file_size) catch |err| switch (err) {
            error.InvalidGzipData,
            error.InvalidGzipHeader,
            error.OutputLimitExceeded,
            error.InvalidOutputLimit,
            => return PcfError.InvalidCompression,
            else => return err,
        };
        file_contents = decompressed_data.?;
    } else {
        file_contents = raw_file_contents;
    }

    // Use arena for temporary allocations
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Parse PCF file
    var reader: std.Io.Reader = .fixed(file_contents);

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
    const properties_table = findTable(tables, .properties);

    // Parse properties table if present (optional)
    var properties_info: ?PropertiesInfo = null;

    if (properties_table) |props_table| {
        properties_info = parseProperties(arena_allocator, file_contents, props_table) catch |err| blk: {
            // Properties are optional, so we continue even if parsing fails
            std.log.debug("Failed to parse properties table: {}", .{err});
            break :blk null;
        };
    }

    // Parse accelerator table for font metrics
    var font_ascent: i16 = 0;
    var font_descent: i16 = 0;
    var max_width: u16 = 0;
    var max_height: u16 = 0;

    if (accel_table) |accel| {
        const accel_data = try parseAccelerator(file_contents, accel);
        font_ascent = std.math.cast(i16, accel_data.font_ascent) orelse std.math.maxInt(i16);
        font_descent = std.math.cast(i16, accel_data.font_descent) orelse std.math.maxInt(i16);
        max_width = std.math.cast(u16, @max(accel_data.max_bounds.character_width, 0)) orelse std.math.maxInt(u16);
        const total_height = @max(0, accel_data.font_ascent) + @max(0, accel_data.font_descent);
        max_height = std.math.cast(u16, total_height) orelse std.math.maxInt(u16);
    } else {
        // Default values if no accelerator table
        font_ascent = 14;
        font_descent = 2;
        max_width = 16;
        max_height = 16;
    }

    // Parse encodings to get character mappings
    const encoding = try parseEncodings(arena_allocator, file_contents, encodings_table);

    // Parse metrics
    const metrics = try parseMetrics(arena_allocator, file_contents, metrics_table, encoding.glyph_indices.len);

    // Parse bitmap data
    const bitmap_info = try parseBitmaps(arena_allocator, file_contents, bitmaps_table);

    // Extract font name while in arena scope and duplicate with main allocator
    var font_name: []u8 = undefined;
    if (properties_info) |props| {
        // Try to get FAMILY_NAME first, fall back to other properties
        if (getStringProperty(props.properties, "FAMILY_NAME")) |family| {
            font_name = try allocator.dupe(u8, family);
        } else if (getStringProperty(props.properties, "FONT")) |font| {
            font_name = try allocator.dupe(u8, font);
        } else {
            font_name = try allocator.dupe(u8, "PCF Font");
        }
    } else {
        font_name = try allocator.dupe(u8, "PCF Font");
    }
    errdefer allocator.free(font_name);

    // Convert to BitmapFont format
    return convertToBitmapFont(allocator, metrics, bitmap_info, encoding, filter, font_ascent, max_width, max_height, font_name);
}

/// Find a table in the table of contents
fn findTable(tables: []const TableEntry, table_type: TableType) ?TableEntry {
    const type_value = @intFromEnum(table_type);
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

/// Parse accelerator table
fn parseAccelerator(data: []const u8, table: TableEntry) !Accelerator {
    try validateTableBounds(data, table);

    var reader: std.Io.Reader = .fixed(data[table.offset .. table.offset + table.size]);

    // Read format field and determine byte order
    const format = try reader.takeVarInt(u32, .little, @sizeOf(u32));
    const byte_order = getByteOrder(format);

    var accel: Accelerator = undefined;

    // In PCF, we need to read fields in the correct order
    // The accelerator table has these fields after format:
    // 1. noOverlap (1 byte)
    // 2. constantMetrics (1 byte)
    // 3. terminalFont (1 byte)
    // 4. constantWidth (1 byte)
    // 5. inkInside (1 byte)
    // 6. inkMetrics (1 byte)
    // 7. drawDirection (1 byte)
    // 8. padding (1 byte)
    // 9. fontAscent (4 bytes)
    // 10. fontDescent (4 bytes)
    // etc.

    // Read the boolean flags as individual bytes
    accel.no_overlap = (try reader.takeByte()) != 0;
    accel.constant_metrics = (try reader.takeByte()) != 0;
    accel.terminal_font = (try reader.takeByte()) != 0;
    accel.constant_width = (try reader.takeByte()) != 0;
    accel.ink_inside = (try reader.takeByte()) != 0;
    accel.ink_metrics = (try reader.takeByte()) != 0;
    accel.draw_direction = (try reader.takeByte()) != 0;
    _ = try reader.takeByte(); // padding

    // Read font metrics
    accel.font_ascent = try reader.takeVarInt(i32, byte_order, @sizeOf(i32));
    accel.font_descent = try reader.takeVarInt(i32, byte_order, @sizeOf(i32));
    accel.max_overlap = try reader.takeVarInt(i32, byte_order, @sizeOf(i32));

    // Read min bounds
    accel.min_bounds = try readMetric(&reader, byte_order, false);
    accel.max_bounds = try readMetric(&reader, byte_order, false);

    // Read ink bounds if present
    const accel_flags = FormatFlags.decode(table.format);
    if (accel_flags.accel_w_inkbounds) {
        accel.ink_min_bounds = try readMetric(&reader, byte_order, false);
        accel.ink_max_bounds = try readMetric(&reader, byte_order, false);
    } else {
        accel.ink_min_bounds = null;
        accel.ink_max_bounds = null;
    }

    return accel;
}

/// Parse properties table
fn parseProperties(allocator: std.mem.Allocator, data: []const u8, table: TableEntry) !PropertiesInfo {
    try validateTableBounds(data, table);

    var reader: std.Io.Reader = .fixed(data[table.offset .. table.offset + table.size]);

    // Read format field and determine byte order
    const format = try reader.takeVarInt(u32, .little, @sizeOf(u32));
    const byte_order = getByteOrder(format);

    // Read number of properties
    const prop_count = try reader.takeVarInt(u32, byte_order, @sizeOf(u32));
    if (prop_count > 1000) { // Sanity check
        return PcfError.InvalidTableEntry;
    }

    // Allocate properties array
    var result: PropertiesInfo = undefined;
    result.properties = try allocator.alloc(Property, prop_count);
    errdefer allocator.free(result.properties);

    // Temporary storage for property info before string resolution
    const PropertyInfo = struct {
        name_offset: u32,
        is_string: bool,
        value: i32,
    };
    const prop_infos = try allocator.alloc(PropertyInfo, prop_count);
    defer allocator.free(prop_infos);

    // Read property info
    for (prop_infos) |*prop| {
        prop.name_offset = try reader.takeVarInt(u32, byte_order, @sizeOf(u32));
        const is_string_byte = try reader.takeByte();
        prop.is_string = is_string_byte != 0;
        prop.value = try reader.takeVarInt(i32, byte_order, @sizeOf(i32));
    }

    // Skip padding to align to 4 bytes if needed
    if ((prop_count & 3) != 0) {
        const padding = 4 - (prop_count & 3);
        try reader.discardAll(padding);
    }

    // Read string pool size
    const string_size = try reader.takeVarInt(u32, byte_order, @sizeOf(u32));

    // Calculate remaining bytes in the reader's buffer
    const remaining_bytes = reader.buffer.len - reader.seek;
    if (string_size > remaining_bytes) {
        return PcfError.InvalidTableEntry;
    }

    // Read string pool
    result.string_pool = try allocator.alloc(u8, string_size);
    try reader.readSliceAll(result.string_pool);

    // Resolve property names and string values
    for (prop_infos, 0..) |prop_info, i| {
        // Get property name from string pool
        if (prop_info.name_offset >= string_size) {
            return PcfError.InvalidTableEntry;
        }

        const name_start = prop_info.name_offset;
        var name_end = name_start;
        while (name_end < string_size and result.string_pool[name_end] != 0) : (name_end += 1) {}

        result.properties[i].name = result.string_pool[name_start..name_end];

        if (prop_info.is_string) {
            // Value is an offset into string pool
            const value_offset = @as(u32, @bitCast(prop_info.value));
            if (value_offset >= string_size) {
                return PcfError.InvalidTableEntry;
            }

            const value_start = value_offset;
            var value_end = value_start;
            while (value_end < string_size and result.string_pool[value_end] != 0) : (value_end += 1) {}

            result.properties[i].value = .{ .string = result.string_pool[value_start..value_end] };
        } else {
            // Value is an integer
            result.properties[i].value = .{ .integer = prop_info.value };
        }
    }

    return result;
}

/// Find a property by name
fn findProperty(properties: []const Property, name: []const u8) ?Property {
    for (properties) |prop| {
        if (std.mem.eql(u8, prop.name, name)) {
            return prop;
        }
    }
    return null;
}

/// Get string value from properties by name
fn getStringProperty(properties: []const Property, name: []const u8) ?[]const u8 {
    const prop = findProperty(properties, name) orelse return null;
    return switch (prop.value) {
        .string => |s| s,
        else => null,
    };
}

/// Read metric from stream (handles both compressed and uncompressed formats)
fn readMetric(reader: *std.Io.Reader, byte_order: std.builtin.Endian, compressed: bool) !Metric {
    if (compressed) {
        // Read compressed metric (5 bytes, each offset by 0x80)
        const lsb = try reader.takeVarInt(u8, .little, 1);
        const rsb = try reader.takeVarInt(u8, .little, 1);
        const cw = try reader.takeVarInt(u8, .little, 1);
        const asc = try reader.takeVarInt(u8, .little, 1);
        const desc = try reader.takeVarInt(u8, .little, 1);

        return Metric{
            .left_sided_bearing = @as(i16, @intCast(@as(i16, lsb) - 0x80)),
            .right_sided_bearing = @as(i16, @intCast(@as(i16, rsb) - 0x80)),
            .character_width = @as(i16, @intCast(@as(i16, cw) - 0x80)),
            .ascent = @as(i16, @intCast(@as(i16, asc) - 0x80)),
            .descent = @as(i16, @intCast(@as(i16, desc) - 0x80)),
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

/// Parse encodings table
fn parseEncodings(allocator: std.mem.Allocator, data: []const u8, table: TableEntry) !EncodingEntry {
    try validateTableBounds(data, table);

    var reader = std.Io.Reader.fixed(data[table.offset .. table.offset + table.size]);

    // Read format field and determine byte order
    const format = try reader.takeVarInt(u32, .little, @sizeOf(u32));
    const byte_order = getByteOrder(format);

    var encoding: EncodingEntry = undefined;

    // Read encoding info
    encoding.min_char_or_byte2 = try reader.takeVarInt(u16, byte_order, @sizeOf(u16));
    encoding.max_char_or_byte2 = try reader.takeVarInt(u16, byte_order, @sizeOf(u16));
    encoding.min_byte1 = try reader.takeVarInt(u16, byte_order, @sizeOf(u16));
    encoding.max_byte1 = try reader.takeVarInt(u16, byte_order, @sizeOf(u16));
    encoding.default_char = try reader.takeVarInt(u16, byte_order, @sizeOf(u16));

    // Calculate total encodings with overflow protection
    const cols = @as(usize, encoding.max_char_or_byte2 - encoding.min_char_or_byte2 + 1);
    const rows = @as(usize, encoding.max_byte1 - encoding.min_byte1 + 1);
    const encodings_count = cols * rows;

    if (encodings_count > max_glyph_count) {
        return PcfError.InvalidEncodingRange;
    }

    // Read glyph indices
    encoding.glyph_indices = try allocator.alloc(u16, encodings_count);
    for (encoding.glyph_indices) |*index| {
        index.* = try reader.takeVarInt(u16, byte_order, @sizeOf(u16));
    }

    return encoding;
}

/// Metrics parsing result
const MetricsInfo = struct {
    metrics: []Metric,
    glyph_count: usize,
};

/// Parse metrics table
fn parseMetrics(allocator: std.mem.Allocator, data: []const u8, table: TableEntry, max_glyphs: usize) !MetricsInfo {
    try validateTableBounds(data, table);

    var reader = std.Io.Reader.fixed(data[table.offset .. table.offset + table.size]);

    // Read format field and determine byte order
    const format = try reader.takeVarInt(u32, .little, @sizeOf(u32));
    const byte_order = getByteOrder(format);

    const flags = FormatFlags.decode(format);
    const compressed = flags.compressed_metrics;

    var result: MetricsInfo = undefined;

    if (compressed) {
        // Read compressed metrics count
        const metrics_count = try reader.takeVarInt(u16, byte_order, @sizeOf(u16));
        if (metrics_count > max_glyph_count) {
            return PcfError.InvalidGlyphCount;
        }
        result.glyph_count = metrics_count;

        // Allocate and read compressed metrics
        result.metrics = try allocator.alloc(Metric, metrics_count);

        for (result.metrics) |*metric| {
            metric.* = try readMetric(&reader, byte_order, true);
        }
    } else {
        // Read uncompressed metrics count
        const metrics_count = try reader.takeVarInt(u32, byte_order, @sizeOf(u32));
        if (metrics_count > max_glyph_count) {
            return PcfError.InvalidGlyphCount;
        }
        result.glyph_count = @min(metrics_count, max_glyphs);

        // Allocate and read uncompressed metrics
        result.metrics = try allocator.alloc(Metric, result.glyph_count);

        for (result.metrics) |*metric| {
            metric.* = try readMetric(&reader, byte_order, false);
        }
    }

    return result;
}

/// Bitmap parsing result
const BitmapInfo = struct {
    bitmap_data: []u8,
    offsets: []u32,
    bitmap_sizes: BitmapSizes,
    format: u32,
};

/// PCF bitmap sizes structure
const BitmapSizes = struct {
    image_width: u32, // Width of the bitmap image in pixels
    image_height: u32, // Height of the bitmap image in pixels
    image_size: u32, // Total size of bitmap data in bytes
    bitmap_count: u32, // Number of bitmaps (same as glyph count)
};

/// Parse bitmaps table
fn parseBitmaps(allocator: std.mem.Allocator, data: []const u8, table: TableEntry) !BitmapInfo {
    try validateTableBounds(data, table);

    var reader: std.Io.Reader = .fixed(data[table.offset .. table.offset + table.size]);

    // Read format field and determine byte order
    const format = try reader.takeVarInt(u32, .little, @sizeOf(u32));
    const byte_order = getByteOrder(format);

    // Read glyph count
    const glyph_count = try reader.takeVarInt(u32, byte_order, @sizeOf(u32));
    if (glyph_count > max_glyph_count) {
        return PcfError.InvalidGlyphCount;
    }

    // Allocate offset array
    var result: BitmapInfo = undefined;
    result.format = format;
    result.offsets = try allocator.alloc(u32, glyph_count);

    // Read offsets
    for (result.offsets) |*offset| {
        offset.* = try reader.takeVarInt(u32, byte_order, @sizeOf(u32));
    }

    // Read bitmap sizes array
    result.bitmap_sizes = BitmapSizes{
        .image_width = try reader.takeVarInt(u32, byte_order, @sizeOf(u32)),
        .image_height = try reader.takeVarInt(u32, byte_order, @sizeOf(u32)),
        .image_size = try reader.takeVarInt(u32, byte_order, @sizeOf(u32)),
        .bitmap_count = try reader.takeVarInt(u32, byte_order, @sizeOf(u32)),
    };

    // Note: bitmap_count might not always match glyph_count exactly in some PCF files
    // Some fonts may have padding or extra bitmap slots

    // For fixed reader, we can't easily get remaining bytes,
    // but we have already validated table bounds, so we can trust image_size

    // Read bitmap data - use the actual image size, not total remaining
    result.bitmap_data = try allocator.alloc(u8, result.bitmap_sizes.image_size);
    try reader.readSliceAll(result.bitmap_data);

    return result;
}

/// Check if a glyph should be included based on filter
fn shouldIncludeGlyph(encoding: u32, filter: LoadFilter) bool {
    switch (filter) {
        .all => return true,
        .ranges => |ranges| {
            for (ranges) |range| {
                if (encoding >= range.start and encoding <= range.end) {
                    return true;
                }
            }
            return false;
        },
    }
}

/// Convert a single glyph bitmap from PCF format to our format
fn convertGlyphBitmap(
    gpa: Allocator,
    bitmap_data: []const u8,
    offset: u32,
    width: u16,
    height: u16,
    format_flags: FormatFlags,
    glyph_pad: GlyphPadding,
    output: *std.ArrayList(u8),
) !void {
    const bytes_per_row = (width + 7) / 8;
    const pcf_pad = glyph_pad.getPadBytes();
    const pcf_row_bytes = ((bytes_per_row + pcf_pad - 1) / pcf_pad) * pcf_pad;

    // Convert each row
    for (0..height) |row| {
        const src_offset = offset + row * pcf_row_bytes;

        // Convert bitmap bytes
        for (0..bytes_per_row) |byte_idx| {
            if (src_offset + byte_idx < bitmap_data.len) {
                const byte = bitmap_data[src_offset + byte_idx];
                // PCF uses MSB first by default, convert if needed
                const converted_byte = if (format_flags.bit_order_msb)
                    @bitReverse(byte)
                else
                    byte;
                try output.append(gpa, converted_byte);
            } else {
                try output.append(gpa, 0);
            }
        }
    }
}

/// Convert parsed PCF data to BitmapFont format
fn convertToBitmapFont(
    gpa: std.mem.Allocator,
    metrics_info: MetricsInfo,
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
        codepoint: u32,
        glyph_index: usize,
        metric: Metric,
    }) = .empty;
    defer glyph_list.deinit(gpa);

    var all_ascii = true;
    var min_char: u8 = 255;
    var max_char: u8 = 0;

    // Build glyph list based on encodings and filter
    for (encoding.glyph_indices, 0..) |glyph_index, encoding_index| {
        if (glyph_index == 0xFFFF) continue; // Skip non-existent glyphs

        // Calculate codepoint from encoding index
        // PCF uses a 2D encoding table where:
        // - rows represent byte1 values (high byte)
        // - columns represent byte2 values (low byte)
        const chars_per_row = encoding.max_char_or_byte2 - encoding.min_char_or_byte2 + 1;
        const row = encoding_index / chars_per_row;
        const col = encoding_index % chars_per_row;
        const codepoint = @as(u32, @intCast(((encoding.min_byte1 + row) << 8) | (encoding.min_char_or_byte2 + col)));

        if (!shouldIncludeGlyph(codepoint, filter)) continue;

        if (glyph_index < metrics_info.glyph_count) {
            try glyph_list.append(gpa, .{
                .codepoint = codepoint,
                .glyph_index = glyph_index,
                .metric = metrics_info.metrics[glyph_index],
            });

            if (codepoint > 127) {
                all_ascii = false;
            } else {
                min_char = @min(min_char, @as(u8, @intCast(codepoint)));
                max_char = @max(max_char, @as(u8, @intCast(codepoint)));
            }
        }
    }

    // Pre-calculate total bitmap size needed
    var total_bitmap_size: usize = 0;
    for (glyph_list.items) |glyph_info| {
        const dims = getGlyphDimensions(glyph_info.metric);
        const bytes_per_row = (dims.width + 7) / 8;
        total_bitmap_size += bytes_per_row * dims.height;
    }

    // Pre-allocate converted bitmap buffer
    var converted_bitmaps: std.ArrayList(u8) = .empty;
    defer converted_bitmaps.deinit(gpa);
    try converted_bitmaps.ensureTotalCapacity(gpa, total_bitmap_size);

    var glyph_map: std.AutoHashMap(u32, usize) = .init(gpa);
    errdefer glyph_map.deinit();
    try glyph_map.ensureTotalCapacity(@intCast(glyph_list.items.len));

    var glyph_data_list = try gpa.alloc(GlyphData, glyph_list.items.len);
    errdefer gpa.free(glyph_data_list);

    for (glyph_list.items, 0..) |glyph_info, list_index| {
        const metric = glyph_info.metric;
        const dims = getGlyphDimensions(metric);

        // Store converted bitmap offset
        const converted_offset = converted_bitmaps.items.len;

        if (glyph_info.glyph_index >= bitmap_info.offsets.len) {
            return PcfError.InvalidBitmapData;
        }
        // Convert bitmap data for this glyph
        const bitmap_offset = bitmap_info.offsets[glyph_info.glyph_index];
        if (bitmap_offset >= bitmap_info.bitmap_data.len) {
            return PcfError.InvalidBitmapData;
        }
        const format_flags = FormatFlags.decode(bitmap_info.format);
        const pad_bits = @as(u2, @truncate(bitmap_info.format & 0x3));
        const glyph_pad = @as(GlyphPadding, @enumFromInt(pad_bits));

        try convertGlyphBitmap(
            gpa,
            bitmap_info.bitmap_data,
            bitmap_offset,
            dims.width,
            dims.height,
            format_flags,
            glyph_pad,
            &converted_bitmaps,
        );

        // Create glyph data entry
        try glyph_map.put(glyph_info.codepoint, list_index);

        // Adjust y_offset to account for font baseline
        const adjusted_y_offset = ascent - metric.ascent;

        glyph_data_list[list_index] = GlyphData{
            .width = @intCast(dims.width),
            .height = @intCast(dims.height),
            .x_offset = metric.left_sided_bearing,
            .y_offset = adjusted_y_offset,
            .device_width = metric.character_width,
            .bitmap_offset = converted_offset,
        };
    }

    // Create final bitmap data
    const bitmap_data = try gpa.alloc(u8, converted_bitmaps.items.len);
    @memcpy(bitmap_data, converted_bitmaps.items);

    return BitmapFont{
        .name = name,
        .char_width = @as(u8, @intCast(@min(max_width, 255))),
        .char_height = @as(u8, @intCast(@min(max_height, 255))),
        .first_char = if (all_ascii) min_char else 0,
        .last_char = if (all_ascii) max_char else 0,
        .data = bitmap_data,
        .glyph_map = glyph_map,
        .glyph_data = glyph_data_list,
    };
}

test "FormatFlags decoding" {
    // Test format flag decoding
    const test_cases = [_]struct {
        format: u32,
        expected: FormatFlags,
    }{
        .{
            .format = 0x00000000,
            .expected = .{
                .glyph_pad = 0,
                .byte_order_msb = false,
                .bit_order_msb = false,
                .scan_unit = 0,
                .accel_w_inkbounds = false,
                .compressed_metrics = false,
                .ink_bounds = false,
            },
        },
        .{
            .format = 0x00000004,
            .expected = .{
                .glyph_pad = 0,
                .byte_order_msb = true,
                .bit_order_msb = false,
                .scan_unit = 0,
                .accel_w_inkbounds = false,
                .compressed_metrics = false,
                .ink_bounds = false,
            },
        },
        .{
            .format = 0x00000008,
            .expected = .{
                .glyph_pad = 0,
                .byte_order_msb = false,
                .bit_order_msb = true,
                .scan_unit = 0,
                .accel_w_inkbounds = false,
                .compressed_metrics = false,
                .ink_bounds = false,
            },
        },
        .{
            .format = 0x0000010C, // Typical compressed metrics format
            .expected = .{
                .glyph_pad = 0,
                .byte_order_msb = true,
                .bit_order_msb = true,
                .scan_unit = 0,
                .accel_w_inkbounds = false,
                .compressed_metrics = true,
                .ink_bounds = false,
            },
        },
        .{
            .format = 0x00000031, // glyph pad 1, scan unit 3
            .expected = .{
                .glyph_pad = 1,
                .byte_order_msb = false,
                .bit_order_msb = false,
                .scan_unit = 3,
                .accel_w_inkbounds = false,
                .compressed_metrics = false,
                .ink_bounds = false,
            },
        },
        .{
            .format = 0x0000070C, // compressed + accel inkbounds + ink bounds
            .expected = .{
                .glyph_pad = 0,
                .byte_order_msb = true,
                .bit_order_msb = true,
                .scan_unit = 0,
                .accel_w_inkbounds = true,
                .compressed_metrics = true,
                .ink_bounds = true,
            },
        },
    };

    for (test_cases) |tc| {
        const flags = FormatFlags.decode(tc.format);
        try testing.expectEqualDeep(tc.expected, flags);
    }
}

test "Table bounds validation" {
    const data: [100]u8 = @splat(0);

    // Valid table
    const valid_table = TableEntry{
        .type = @intFromEnum(TableType.metrics),
        .format = 0,
        .size = 50,
        .offset = 20,
    };
    try validateTableBounds(&data, valid_table);

    // Invalid offset
    const invalid_offset_table = TableEntry{
        .type = @intFromEnum(TableType.metrics),
        .format = 0,
        .size = 50,
        .offset = 200,
    };
    try testing.expectError(PcfError.TableOffsetOutOfBounds, validateTableBounds(&data, invalid_offset_table));

    // Invalid size
    const invalid_size_table = TableEntry{
        .type = @intFromEnum(TableType.metrics),
        .format = 0,
        .size = 100,
        .offset = 50,
    };
    try testing.expectError(PcfError.TableOffsetOutOfBounds, validateTableBounds(&data, invalid_size_table));
}

test "Metric reading" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    // Write compressed metric
    try writer.writeByte(0x82); // LSB: 2 (0x82 - 0x80)
    try writer.writeByte(0x88); // RSB: 8 (0x88 - 0x80)
    try writer.writeByte(0x86); // Width: 6 (0x86 - 0x80)
    try writer.writeByte(0x90); // Ascent: 16 (0x90 - 0x80)
    try writer.writeByte(0x82); // Descent: 2 (0x82 - 0x80)

    var reader: std.Io.Reader = .fixed(buffer[0..writer.end]);

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
    var writer: std.Io.Writer = .fixed(&buffer);

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
        .type = @intFromEnum(TableType.properties),
        .format = 0,
        .size = @intCast(writer.end),
        .offset = 0,
    };

    const props = try parseProperties(allocator, buffer[0..writer.end], table);
    defer allocator.free(props.properties);
    defer allocator.free(props.string_pool);

    try testing.expectEqual(@as(usize, 1), props.properties.len);

    // Check property
    try testing.expectEqualStrings("PIXEL_SIZE", props.properties[0].name);
    try testing.expect(props.properties[0].value == .integer);
    try testing.expectEqual(@as(i32, 16), props.properties[0].value.integer);
}
