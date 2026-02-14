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
const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;
const flate = std.compress.flate;

const max_file_size = @import("../font.zig").max_file_size;
const LoadFilter = @import("../font.zig").LoadFilter;
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
pub fn load(io: Io, allocator: std.mem.Allocator, path: []const u8, filter: LoadFilter) !BitmapFont {
    // Check if file is gzip compressed
    const is_compressed = std.mem.endsWith(u8, path, ".gz");

    // Read file into memory
    const raw_file_contents = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_size));
    defer allocator.free(raw_file_contents);

    // Decompress if needed
    var file_contents: []u8 = undefined;
    var decompressed_data: ?[]u8 = null;
    defer if (decompressed_data) |data| allocator.free(data);

    if (is_compressed) {
        var reader: Io.Reader = .fixed(raw_file_contents);

        const buffer = try allocator.alloc(u8, flate.max_window_len);
        defer allocator.free(buffer);

        var decompressor: flate.Decompress = .init(&reader, .gzip, buffer);

        var aw: Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        var remaining = Io.Limit.limited(max_file_size);
        while (remaining.nonzero()) {
            const n = decompressor.reader.stream(&aw.writer, remaining) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return PcfError.InvalidCompression,
                else => return err,
            };
            remaining = remaining.subtract(n).?;
        } else {
            var one_byte_buf: [1]u8 = undefined;
            var dummy_writer = Io.Writer.fixed(&one_byte_buf);
            if (decompressor.reader.stream(&dummy_writer, .limited(1))) |n| {
                if (n > 0) return PcfError.InvalidCompression;
            } else |err| switch (err) {
                error.EndOfStream => {},
                error.ReadFailed => return PcfError.InvalidCompression,
                else => return err,
            }
        }
        decompressed_data = try aw.toOwnedSlice();
        file_contents = decompressed_data.?;
    } else {
        file_contents = raw_file_contents;
    }

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

    var reader: Io.Reader = .fixed(data[table.offset .. table.offset + table.size]);

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

    var reader: Io.Reader = .fixed(data[table.offset .. table.offset + table.size]);

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
fn readMetric(reader: *Io.Reader, byte_order: std.builtin.Endian, compressed: bool) !Metric {
    if (compressed) {
        // Read compressed metric (5 bytes, each offset by 0x80)
        const lsb = try reader.takeVarInt(u8, .little, 1);
        const rsb = try reader.takeVarInt(u8, .little, 1);
        const cw = try reader.takeVarInt(u8, .little, 1);
        const asc = try reader.takeVarInt(u8, .little, 1);
        const desc = try reader.takeVarInt(u8, .little, 1);

        return Metric{
            .left_sided_bearing = @intCast(@as(i16, lsb) - 0x80),
            .right_sided_bearing = @intCast(@as(i16, rsb) - 0x80),
            .character_width = @intCast(@as(i16, cw) - 0x80),
            .ascent = @intCast(@as(i16, asc) - 0x80),
            .descent = @intCast(@as(i16, desc) - 0x80),
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

    var reader = Io.Reader.fixed(data[table.offset .. table.offset + table.size]);

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
    const cols = @as(u32, encoding.max_char_or_byte2 - encoding.min_char_or_byte2 + 1);
    const rows = @as(u32, encoding.max_byte1 - encoding.min_byte1 + 1);
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
    glyph_count: u32,
};

/// Parse metrics table
fn parseMetrics(allocator: std.mem.Allocator, data: []const u8, table: TableEntry, max_glyphs: usize) !MetricsInfo {
    try validateTableBounds(data, table);

    var reader = Io.Reader.fixed(data[table.offset .. table.offset + table.size]);

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

    var reader: Io.Reader = .fixed(data[table.offset .. table.offset + table.size]);

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

    // Determine correct size based on format padding
    // The 4 values in bitmap_sizes correspond to padding 1, 2, 4, 8 bytes
    const flags = FormatFlags.decode(format);
    const data_size = switch (flags.glyph_pad) {
        0 => result.bitmap_sizes.image_width,
        1 => result.bitmap_sizes.image_height,
        2 => result.bitmap_sizes.image_size,
        3 => result.bitmap_sizes.bitmap_count,
    };

    // Read bitmap data
    result.bitmap_data = try allocator.alloc(u8, data_size);
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
        glyph_index: u32,
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
        const codepoint: u32 = @intCast(((encoding.min_byte1 + row) << 8) | (encoding.min_char_or_byte2 + col));

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
    var total_bitmap_size: u32 = 0;
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
        .char_width = @intCast(@min(max_width, 255)),
        .char_height = @intCast(@min(max_height, 255)),
        .first_char = if (all_ascii) min_char else 0,
        .last_char = if (all_ascii) max_char else 0,
        .data = bitmap_data,
        .glyph_map = glyph_map,
        .glyph_data = glyph_data_list,
    };
}

// --- PCF Writing Support ---

const TableBuffer = struct {
    table_type: u32,
    format: u32,
    data: []u8,
};

const GlyphMetrics = struct {
    left: i16,
    right: i16,
    width: i16,
    ascent: i16,
    descent: i16,
    attributes: u16,
};

const GlyphEntry = struct {
    codepoint: u21,
    metrics: GlyphMetrics,
    width: u16,
    height: u16,
    bitmap_offset: u32,
};

fn alignForward(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

fn collectCodepoints(allocator: Allocator, font: BitmapFont) ![]u21 {
    var keys: []u21 = undefined;

    if (font.glyph_map) |map| {
        keys = try allocator.alloc(u21, map.count());
        var iter = map.iterator();
        var idx: usize = 0;
        while (iter.next()) |entry| : (idx += 1) {
            keys[idx] = @intCast(entry.key_ptr.*);
        }
        std.mem.sort(u21, keys, {}, std.sort.asc(u21));
    } else {
        if (font.last_char < font.first_char) {
            return allocator.alloc(u21, 0);
        }

        const count = @as(usize, font.last_char - font.first_char + 1);
        keys = try allocator.alloc(u21, count);
        for (keys, 0..) |*cp, idx| {
            cp.* = @as(u21, font.first_char) + @as(u21, @intCast(idx));
        }
    }

    return keys;
}

fn buildGlyphEntries(
    allocator: Allocator,
    font: BitmapFont,
    codepoints: []const u21,
) !struct {
    entries: []GlyphEntry,
    offsets: []u32,
    bitmap_data: []u8,
    pad_sizes: [4]u32,
} {
    var entries = try allocator.alloc(GlyphEntry, codepoints.len);
    errdefer allocator.free(entries);

    var offsets = try allocator.alloc(u32, codepoints.len);
    errdefer allocator.free(offsets);

    var bitmap_buffer: std.ArrayList(u8) = .empty;
    errdefer bitmap_buffer.deinit(allocator);

    var pad_sizes = [_]usize{ 0, 0, 0, 0 };

    const font_ascent = font.font_ascent orelse @as(i16, font.char_height);

    for (codepoints, 0..) |cp, idx| {
        const glyph_info = font.getGlyphInfo(cp) orelse return PcfError.MissingRequired;
        const width = glyph_info.width;
        const height = glyph_info.height;
        const char_data = font.getCharData(cp) orelse return PcfError.InvalidBitmapData;

        const bytes_per_row = @as(usize, (width + 7) / 8);
        const row_stride = bytes_per_row;

        const left = glyph_info.x_offset;
        const right = @as(i16, @intCast(width)) + left;
        const advance = glyph_info.device_width;
        const ascent = font_ascent - glyph_info.y_offset;
        var descent = @as(i16, @intCast(height)) - ascent;
        if (descent < 0) descent = 0;

        const metric: GlyphMetrics = .{
            .left = left,
            .right = right,
            .width = advance,
            .ascent = ascent,
            .descent = descent,
            .attributes = 0,
        };

        offsets[idx] = @intCast(bitmap_buffer.items.len);

        // Copy bitmap data
        try bitmap_buffer.appendSlice(allocator, char_data);

        // Calculate PCF padding requirements
        const pad_options = [_]usize{ 1, 2, 4, 8 };
        for (pad_options, 0..) |pad, pad_idx| {
            const padded_row = alignForward(row_stride, pad);
            pad_sizes[pad_idx] += padded_row * height;
        }

        entries[idx] = GlyphEntry{
            .codepoint = cp,
            .metrics = metric,
            .width = @intCast(width),
            .height = @intCast(height),
            .bitmap_offset = offsets[idx],
        };
    }

    return .{
        .entries = entries,
        .offsets = offsets,
        .bitmap_data = try bitmap_buffer.toOwnedSlice(allocator),
        .pad_sizes = .{
            @intCast(pad_sizes[0]),
            @intCast(pad_sizes[1]),
            @intCast(pad_sizes[2]),
            @intCast(pad_sizes[3]),
        },
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

    for (glyphs) |glyph| {
        const m = glyph.metrics;
        try writer.writeInt(i16, m.left, .little);
        try writer.writeInt(i16, m.right, .little);
        try writer.writeInt(i16, m.width, .little);
        try writer.writeInt(i16, m.ascent, .little);
        try writer.writeInt(i16, m.descent, .little);
        try writer.writeInt(u16, m.attributes, .little);
    }

    return buffer;
}

fn writeBitmapsTable(
    allocator: Allocator,
    glyphs: []const GlyphEntry,
    offsets: []const u32,
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

    for (offsets) |offset| {
        try writer.writeInt(u32, offset, .little);
    }

    const stored_sizes = [_]u32{
        pad_sizes[0],
        pad_sizes[1],
        pad_sizes[2],
        pad_sizes[3],
    };

    for (stored_sizes) |sz| {
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
        const high = @as(u16, @intCast(g.codepoint >> 8));
        const low = @as(u16, @intCast(g.codepoint & 0xFF));
        if (high < min_byte1) min_byte1 = high;
        if (high > max_byte1) max_byte1 = high;
        if (low < min_byte2) min_byte2 = low;
        if (low > max_byte2) max_byte2 = low;
    }

    // Default char (usually space or first char)
    const default_char: u16 = 0;

    const rows = @as(usize, max_byte1 - min_byte1 + 1);
    const cols = @as(usize, max_byte2 - min_byte2 + 1);
    const table_len = rows * cols;

    var glyph_indices = try allocator.alloc(u16, table_len);
    defer allocator.free(glyph_indices);
    @memset(glyph_indices, 0xFFFF);

    for (glyphs, 0..) |glyph, idx| {
        const high = @as(usize, (glyph.codepoint >> 8) - min_byte1);
        const low = @as(usize, (glyph.codepoint & 0xFF) - min_byte2);
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

    const PropVal = struct {
        name: []const u8,
        is_string: bool,
        s_val: []const u8,
        i_val: i32,
    };

    var props_list: std.ArrayList(PropVal) = .empty;
    defer props_list.deinit(allocator);

    try props_list.append(allocator, .{ .name = "FONT", .is_string = true, .s_val = font.name, .i_val = 0 });
    try props_list.append(allocator, .{ .name = "PIXEL_SIZE", .is_string = false, .s_val = "", .i_val = @intCast(font.char_height) });
    try props_list.append(allocator, .{ .name = "POINT_SIZE", .is_string = false, .s_val = "", .i_val = @as(i32, @intCast(font.char_height)) * 10 });
    try props_list.append(allocator, .{ .name = "RESOLUTION_X", .is_string = false, .s_val = "", .i_val = 75 });
    try props_list.append(allocator, .{ .name = "RESOLUTION_Y", .is_string = false, .s_val = "", .i_val = 75 });
    try props_list.append(allocator, .{ .name = "SPACING", .is_string = true, .s_val = if (font.glyph_map != null) "P" else "C", .i_val = 0 });

    if (font.font_ascent) |asc| {
        try props_list.append(allocator, .{ .name = "FONT_ASCENT", .is_string = false, .s_val = "", .i_val = asc });
        const desc = @as(i32, font.char_height) - asc;
        try props_list.append(allocator, .{ .name = "FONT_DESCENT", .is_string = false, .s_val = "", .i_val = desc });
    }

    // Add strings to pool and record offsets
    var prop_entries = try allocator.alloc(struct { name_off: u32, is_string: u8, val: i32 }, props_list.items.len);
    defer allocator.free(prop_entries);

    for (props_list.items, 0..) |p, i| {
        const name_off = @as(u32, @intCast(string_pool.items.len));
        try string_pool.appendSlice(allocator, p.name);
        try string_pool.append(allocator, 0);

        var val: i32 = p.i_val;
        if (p.is_string) {
            const val_off = @as(u32, @intCast(string_pool.items.len));
            try string_pool.appendSlice(allocator, p.s_val);
            try string_pool.append(allocator, 0);
            val = @bitCast(val_off);
        }

        prop_entries[i] = .{
            .name_off = name_off,
            .is_string = if (p.is_string) 1 else 0,
            .val = val,
        };
    }

    const prop_data_size = prop_entries.len * 9;
    const padding = if ((prop_entries.len & 3) != 0) 4 - (prop_entries.len & 3) else 0;

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

    for (0..padding) |_| {
        try writer.writeByte(0);
    }

    try writer.writeInt(u32, @intCast(string_pool.items.len), .little);
    try writer.writeAll(string_pool.items);

    return buffer;
}

fn writeAcceleratorsTable(allocator: Allocator, glyphs: []const GlyphEntry, font_ascent: i16, font_descent: i16) ![]u8 {
    // Calculate global bounds
    var min_bounds: Metric = .{
        .left_sided_bearing = 0,
        .right_sided_bearing = 0,
        .character_width = 0,
        .ascent = 0,
        .descent = 0,
        .attributes = 0,
    };
    var max_bounds = min_bounds;

    if (glyphs.len > 0) {
        min_bounds = Metric{
            .left_sided_bearing = std.math.maxInt(i16),
            .right_sided_bearing = std.math.maxInt(i16),
            .character_width = std.math.maxInt(i16),
            .ascent = std.math.maxInt(i16),
            .descent = std.math.maxInt(i16),
            .attributes = 0,
        };
        max_bounds = Metric{
            .left_sided_bearing = std.math.minInt(i16),
            .right_sided_bearing = std.math.minInt(i16),
            .character_width = std.math.minInt(i16),
            .ascent = std.math.minInt(i16),
            .descent = std.math.minInt(i16),
            .attributes = 0,
        };

        for (glyphs) |g| {
            const m = g.metrics;
            min_bounds.left_sided_bearing = @min(min_bounds.left_sided_bearing, m.left);
            min_bounds.right_sided_bearing = @min(min_bounds.right_sided_bearing, m.right);
            min_bounds.character_width = @min(min_bounds.character_width, m.width);
            min_bounds.ascent = @min(min_bounds.ascent, m.ascent);
            min_bounds.descent = @min(min_bounds.descent, m.descent);

            max_bounds.left_sided_bearing = @max(max_bounds.left_sided_bearing, m.left);
            max_bounds.right_sided_bearing = @max(max_bounds.right_sided_bearing, m.right);
            max_bounds.character_width = @max(max_bounds.character_width, m.width);
            max_bounds.ascent = @max(max_bounds.ascent, m.ascent);
            max_bounds.descent = @max(max_bounds.descent, m.descent);
        }
    }

    // Size calculation
    // Format (4) + bools (8) + padding (1) + metrics (12) + min_bounds (12) + max_bounds (12)
    // Metric size = 6 * 2 = 12 bytes
    const size = 4 + 8 + 1 + 12 + 12 + 12;
    const buffer = try allocator.alloc(u8, size);
    var writer = Io.Writer.fixed(buffer);

    try writer.writeInt(u32, 0, .little); // Format (no accel w/ inkbounds)
    try writer.writeByte(0); // noOverlap
    try writer.writeByte(0); // constantMetrics
    try writer.writeByte(0); // terminalFont
    try writer.writeByte(0); // constantWidth
    try writer.writeByte(0); // inkInside
    try writer.writeByte(0); // inkMetrics
    try writer.writeByte(0); // drawDirection
    try writer.writeByte(0); // padding

    try writer.writeInt(i32, font_ascent, .little);
    try writer.writeInt(i32, font_descent, .little);
    try writer.writeInt(i32, max_bounds.right_sided_bearing, .little); // max_overlap approximation

    // Write min bounds
    try writer.writeInt(i16, min_bounds.left_sided_bearing, .little);
    try writer.writeInt(i16, min_bounds.right_sided_bearing, .little);
    try writer.writeInt(i16, min_bounds.character_width, .little);
    try writer.writeInt(i16, min_bounds.ascent, .little);
    try writer.writeInt(i16, min_bounds.descent, .little);
    try writer.writeInt(u16, min_bounds.attributes, .little);

    // Write max bounds
    try writer.writeInt(i16, max_bounds.left_sided_bearing, .little);
    try writer.writeInt(i16, max_bounds.right_sided_bearing, .little);
    try writer.writeInt(i16, max_bounds.character_width, .little);
    try writer.writeInt(i16, max_bounds.ascent, .little);
    try writer.writeInt(i16, max_bounds.descent, .little);
    try writer.writeInt(u16, max_bounds.attributes, .little);

    return buffer;
}

/// Save a BitmapFont to a PCF file
pub fn save(io: Io, gpa: Allocator, font: BitmapFont, path: []const u8) !void {
    const codepoints = try collectCodepoints(gpa, font);
    defer gpa.free(codepoints);

    const glyph_data = try buildGlyphEntries(gpa, font, codepoints);
    defer gpa.free(glyph_data.entries);
    defer gpa.free(glyph_data.offsets);
    defer gpa.free(glyph_data.bitmap_data);

    const metrics_table = try writeMetricsTable(gpa, glyph_data.entries);
    defer gpa.free(metrics_table);

    const bitmaps_table = try writeBitmapsTable(
        gpa,
        glyph_data.entries,
        glyph_data.offsets,
        glyph_data.bitmap_data,
        glyph_data.pad_sizes,
    );
    defer gpa.free(bitmaps_table);

    const encoding_table = try writeEncodingTable(gpa, glyph_data.entries);
    defer gpa.free(encoding_table);

    const properties_table = try writePropertiesTable(gpa, font);
    defer gpa.free(properties_table);

    const font_ascent = font.font_ascent orelse @as(i16, font.char_height);
    const font_descent = if (font.font_ascent) |asc| @as(i16, font.char_height) - asc else 0;
    const accel_table = try writeAcceleratorsTable(gpa, glyph_data.entries, font_ascent, font_descent);
    defer gpa.free(accel_table);

    var tables = [_]TableBuffer{
        .{ .table_type = (1 << 0), .format = 0, .data = properties_table },
        .{ .table_type = (1 << 1), .format = 0, .data = accel_table },
        .{ .table_type = (1 << 2), .format = 0, .data = metrics_table },
        .{ .table_type = (1 << 3), .format = 0, .data = bitmaps_table },
        .{ .table_type = (1 << 5), .format = 0, .data = encoding_table },
    };

    const table_count = tables.len;
    const header_size = 8 + table_count * 16;
    var offsets = [_]u32{0} ** 5; // table_count
    var current_offset: usize = header_size;

    for (tables, 0..) |table, idx| {
        current_offset = alignForward(current_offset, 4);
        offsets[idx] = @intCast(current_offset);
        current_offset += table.data.len;
    }

    const file = if (Io.Dir.path.isAbsolute(path))
        try Io.Dir.createFileAbsolute(io, path, .{})
    else
        try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    const is_compressed = std.ascii.endsWithIgnoreCase(path, ".gz");

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try aw.ensureTotalCapacity(current_offset + 1024);

    try aw.writer.writeInt(u32, pcf_file_version, .little);
    try aw.writer.writeInt(u32, table_count, .little);

    for (tables, 0..) |table, idx| {
        try aw.writer.writeInt(u32, table.table_type, .little);
        try aw.writer.writeInt(u32, table.format, .little);
        try aw.writer.writeInt(u32, @intCast(table.data.len), .little);
        try aw.writer.writeInt(u32, offsets[idx], .little);
    }

    for (tables, 0..) |table, idx| {
        const target_offset = offsets[idx];
        const current_pos = aw.writer.end;
        if (current_pos < target_offset) {
            const padding = target_offset - current_pos;
            for (0..padding) |_| {
                try aw.writer.writeByte(0);
            }
        }
        try aw.writer.writeAll(table.data);
    }

    const final_data = try aw.toOwnedSlice();
    defer gpa.free(final_data);

    if (is_compressed) {
        const compress_buffer = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(compress_buffer);

        // We need a new AllocatingWriter for the compressed output
        var c_aw: Io.Writer.Allocating = .init(gpa);
        defer c_aw.deinit();
        try c_aw.ensureTotalCapacity(final_data.len / 2 + 64);

        var compressor = try flate.Compress.init(&c_aw.writer, compress_buffer, .gzip, .level_1);
        try compressor.writer.writeAll(final_data);
        try compressor.writer.flush(); // Ensure everything is written

        const compressed_bytes = try c_aw.toOwnedSlice();
        defer gpa.free(compressed_bytes);
        try file.writeStreamingAll(io, compressed_bytes);
    } else {
        try file.writeStreamingAll(io, final_data);
    }
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

test "PCF save and load roundtrip" {
    // Create a simple font manually
    const char_width = 8;
    const char_height = 8;

    // 3 chars: A, B, C
    const data_size = 3 * char_height; // 1 byte per row * 8 rows * 3 chars
    const bitmap_data = try testing.allocator.alloc(u8, data_size);
    defer testing.allocator.free(bitmap_data);

    // Pattern for A
    bitmap_data[0] = 0x18;
    bitmap_data[1] = 0x24;
    bitmap_data[2] = 0x42;
    bitmap_data[3] = 0x42;
    bitmap_data[4] = 0x7E;
    bitmap_data[5] = 0x42;
    bitmap_data[6] = 0x42;
    bitmap_data[7] = 0x00;

    // Pattern for B
    bitmap_data[8] = 0x7C;
    bitmap_data[9] = 0x42;
    bitmap_data[10] = 0x42;
    bitmap_data[11] = 0x7C;
    bitmap_data[12] = 0x42;
    bitmap_data[13] = 0x42;
    bitmap_data[14] = 0x7C;
    bitmap_data[15] = 0x00;

    // Pattern for C
    bitmap_data[16] = 0x3C;
    bitmap_data[17] = 0x42;
    bitmap_data[18] = 0x40;
    bitmap_data[19] = 0x40;
    bitmap_data[20] = 0x40;
    bitmap_data[21] = 0x42;
    bitmap_data[22] = 0x3C;
    bitmap_data[23] = 0x00;

    const font_data = try testing.allocator.dupe(u8, bitmap_data);
    const font_name = try testing.allocator.dupe(u8, "TestFont");

    var font: BitmapFont = .{
        .name = font_name,
        .char_width = char_width,
        .char_height = char_height,
        .first_char = 65, // 'A'
        .last_char = 67, // 'C'
        .data = font_data,
        .glyph_map = null,
        .glyph_data = null,
        .font_ascent = 7,
    };
    defer font.deinit(testing.allocator);

    // Save
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file_path = try Io.Dir.path.join(testing.allocator, &.{ ".", "test.pcf" });
    defer testing.allocator.free(file_path);

    // We need Io instance. Tests usually use std.fs or Io mock?
    // In other tests, Io seems to be used as a namespace.
    // But `save` takes `io: Io`.
    // In `bdf.zig` tests: `try font.save(testing.io, ...)`?
    // Let's check `bdf.zig` tests again.
    // `try font.save(testing.io, testing.allocator, test_path);`
    // So `testing.io` exists!

    // Wait, `tmp_dir` logic in `bdf.zig` test:
    // `const full_path = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", testing.allocator);`
    // `testing.io` must be available.

    // Path must be absolute or relative to CWD. `tmp_dir` is somewhere else.
    // We need the full path to the tmp file.
    const tmp_path = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);
    const full_path = try Io.Dir.path.join(testing.allocator, &.{ tmp_path, "test.pcf" });
    defer testing.allocator.free(full_path);

    try font.save(testing.io, testing.allocator, full_path);

    // Load back
    var loaded = try BitmapFont.load(testing.io, testing.allocator, full_path, .all);
    defer loaded.deinit(testing.allocator);

    // Verify
    try testing.expectEqualStrings(font.name, loaded.name);
    try testing.expectEqual(font.char_width, loaded.char_width);
    try testing.expectEqual(font.char_height, loaded.char_height);
    try testing.expectEqual(font.first_char, loaded.first_char);
    try testing.expectEqual(font.last_char, loaded.last_char);

    // Verify data
    for (font.first_char..font.last_char + 1) |cp| {
        const original = font.getCharData(@intCast(cp));
        const new_data = loaded.getCharData(@intCast(cp));
        try testing.expect(original != null);
        try testing.expect(new_data != null);
        try testing.expectEqualSlices(u8, original.?, new_data.?);
    }
}

test "PCF save and load compressed roundtrip" {
    // Similar to uncompressed test but with .gz extension
    const char_width = 8;
    const char_height = 8;

    const data_size = 3 * char_height;
    const bitmap_data = try testing.allocator.alloc(u8, data_size);
    defer testing.allocator.free(bitmap_data);
    @memset(bitmap_data, 0xAA); // Dummy pattern

    const font_data = try testing.allocator.dupe(u8, bitmap_data);
    const font_name = try testing.allocator.dupe(u8, "CompressedTestFont");

    var font: BitmapFont = .{
        .name = font_name,
        .char_width = char_width,
        .char_height = char_height,
        .first_char = 65,
        .last_char = 67,
        .data = font_data,
        .glyph_map = null,
        .glyph_data = null,
        .font_ascent = 7,
    };
    defer font.deinit(testing.allocator);

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmp_dir.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_path);
    const full_path = try Io.Dir.path.join(testing.allocator, &.{ tmp_path, "test.pcf.gz" });
    defer testing.allocator.free(full_path);

    try font.save(testing.io, testing.allocator, full_path);

    // Verify it is a gzip file
    {
        const file = try Io.Dir.openFileAbsolute(testing.io, full_path, .{});
        defer file.close(testing.io);
        var header: [2]u8 = undefined;
        var iov = [_][]u8{header[0..]};
        _ = try file.readStreaming(testing.io, &iov);
        try testing.expectEqual(@as(u8, 0x1f), header[0]);
        try testing.expectEqual(@as(u8, 0x8b), header[1]);
    }

    // Load back
    var loaded: BitmapFont = try .load(testing.io, testing.allocator, full_path, .all);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqualStrings(font.name, loaded.name);
    try testing.expectEqual(font.char_width, loaded.char_width);
    try testing.expectEqual(font.char_height, loaded.char_height);
}
