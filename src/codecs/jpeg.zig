//! Pure Zig JPEG state and baseline encoder implementation.
//! Decoder supports baseline and progressive DCT JPEG images.
//! Encoder implements baseline (SOF0) JPEG with 4:4:4, 4:2:2, or 4:2:0 chroma subsampling and adjustable quality.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const parallel = @import("../parallel.zig");

const convertColor = @import("../color.zig").convertColor;
const Image = @import("../image.zig").Image;

const Rgb = @import("../color.zig").Rgb(u8);
const Ycbcr = @import("../color.zig").Ycbcr(u8);
const meta = @import("../meta.zig");

const max_file_size: usize = 100 * 1024 * 1024;

/// User-configurable resource limits for JPEG decoding. Zero disables a limit.
pub const DecodeLimits = struct {
    /// Maximum number of bytes accepted for the original JPEG buffer.
    max_jpeg_bytes: usize = max_file_size,
    /// Cap on total marker payload bytes (length-prefixed segments plus entropy data).
    max_marker_bytes: usize = max_file_size,
    /// Maximum declared image width/height in pixels.
    max_width: u32 = 8192,
    max_height: u32 = 8192,
    /// Maximum width * height before allocations.
    max_pixels: u64 = 67_108_864, // 8K square
    /// Maximum number of 8x8 blocks allocated across all components.
    max_blocks: usize = 1_048_576,
    /// Maximum number of scans (progressive JPEGs may have dozens).
    max_scans: usize = 64,

    pub const default: DecodeLimits = .{};
};

inline fn exceeds(limit: u64, value: u64) bool {
    return limit != 0 and value > limit;
}

fn accumulateWithLimit(current: *usize, addend: usize, limit: usize, limit_error: anyerror) !void {
    const new_total = std.math.add(usize, current.*, addend) catch return limit_error;
    if (limit != 0 and new_total > limit) return limit_error;
    current.* = new_total;
}

// JPEG signature: 2 bytes that identify a JPEG file (SOI marker)
pub const signature = [_]u8{ 0xFF, 0xD8 };

/// Zigzag scan order for 8x8 DCT blocks
pub const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

/// JPEG Header information extracted from SOF marker
pub const Header = struct {
    width: u32,
    height: u32,
    frame_type: FrameType,
    num_components: u8,
    precision: u8,
    /// Derived from SOF sampling factors; null for grayscale or exotic layouts.
    subsampling: ?Subsampling = null,

    pub fn totalPixels(self: Header) u64 {
        return @as(u64, self.width) * @as(u64, self.height);
    }
};

/// Retrieve metadata from a JPEG stream without decoding the full image.
/// Scans for a Start of Frame (SOF) marker.
pub fn getInfo(reader: *Io.Reader, limits: DecodeLimits) !Header {
    var bytes_read: usize = 0;
    var marker_count: usize = 0;
    const MAX_MARKERS_SCAN = 10000; // Sanity limit for markers before SOF

    const sig = try reader.takeArray(2);
    bytes_read += sig.len;
    if (!std.mem.eql(u8, sig, &signature)) {
        return error.InvalidJpegFile;
    }

    while (true) {
        // Scan for marker (0xFF)
        while (true) {
            const byte = try reader.takeByte();
            bytes_read += 1;
            if (exceeds(limits.max_jpeg_bytes, bytes_read)) return error.ImageTooLarge;
            if (byte == 0xFF) break;
        }

        var marker_byte = try reader.takeByte();
        bytes_read += 1;
        // 0xFF is valid padding
        while (marker_byte == 0xFF) {
            marker_byte = try reader.takeByte();
            bytes_read += 1;
            if (exceeds(limits.max_jpeg_bytes, bytes_read)) return error.ImageTooLarge;
        }

        if (marker_byte == 0x00) continue; // stuffed byte

        marker_count += 1;
        if (marker_count > MAX_MARKERS_SCAN) return error.ImageTooLarge;

        const marker_val = (@as(u16, 0xFF) << 8) | marker_byte;

        // Markers with no payload
        if (marker_val == 0xFF01 or // TEM
            (marker_val >= 0xFFD0 and marker_val <= 0xFFD7) or // RSTm
            marker_val == 0xFFD8) // SOI
        {
            continue;
        }

        if (marker_val == 0xFFD9) return error.MissingSOF; // EOI

        // Markers with payload: read length
        const length = try reader.takeInt(u16, .big);
        bytes_read += @sizeOf(u16);
        if (length < 2) return error.InvalidMarker;

        // Check if this is a SOF marker
        const is_sof = switch (marker_val) {
            0xFFC0, 0xFFC1, 0xFFC2, 0xFFC3, 0xFFC5, 0xFFC6, 0xFFC7, 0xFFC9, 0xFFCA, 0xFFCB, 0xFFCD, 0xFFCE, 0xFFCF => true,
            else => false,
        };

        if (is_sof) {
            const payload_len = length - 2;
            if (payload_len < 6) return error.InvalidSOF;

            // Check if reading payload would exceed limit
            if (bytes_read + payload_len > limits.max_jpeg_bytes) return error.ImageTooLarge;

            const precision = try reader.takeByte();
            const height = try reader.takeInt(u16, .big);
            const width = try reader.takeInt(u16, .big);
            const num_components = try reader.takeByte();
            bytes_read += 6; // precision(1) + height(2) + width(2) + components(1)

            var subsampling: ?Subsampling = null;
            var remaining: usize = payload_len - 6;
            if (num_components == 3 and remaining >= 9) {
                var factors: [3]u8 = undefined;
                for (&factors) |*f| f.* = (try reader.takeArray(3))[1]; // id, sampling (h << 4 | v), quant table
                bytes_read += 9;
                remaining -= 9;
                if (factors[1] == 0x11 and factors[2] == 0x11) {
                    subsampling = Subsampling.fromLumaFactors(factors[0]);
                }
            }

            // Discard remaining component info if any
            bytes_read += try reader.discard(.limited(remaining));

            return Header{
                .width = width,
                .height = height,
                .frame_type = if (marker_val == 0xFFC2) .progressive else .baseline,
                .num_components = num_components,
                .precision = precision,
                .subsampling = subsampling,
            };
        }

        // Skip payload
        const skip = length - 2;
        // Check if skipping would exceed limit (approximate, as discard might not read all if seeking)
        // But for safety, we count it against the limit.
        if (bytes_read + skip > limits.max_jpeg_bytes) return error.ImageTooLarge;

        bytes_read += try reader.discard(.limited(skip));
    }
}
test "JPEG getInfo" {
    const gpa = std.testing.allocator;

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    // SOI
    try data.appendSlice(gpa, &signature);

    // APP0
    try data.append(gpa, 0xFF);
    try data.append(gpa, 0xE0);
    try data.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeTo(u16, 16, .big))); // Length
    try data.appendSlice(gpa, "JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00");

    // SOF0
    try data.append(gpa, 0xFF);
    try data.append(gpa, 0xC0);
    try data.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeTo(u16, 17, .big))); // Length
    try data.append(gpa, 8); // Precision
    try data.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeTo(u16, 100, .big))); // Height
    try data.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeTo(u16, 200, .big))); // Width
    try data.append(gpa, 3); // Components
    // Component info (3 * 3 bytes)
    try data.appendSlice(gpa, &[_]u8{ 1, 0x11, 0, 2, 0x11, 1, 3, 0x11, 1 });

    // EOI
    try data.append(gpa, 0xFF);
    try data.append(gpa, 0xD9);

    var reader: Io.Reader = .fixed(data.items);
    const header = try getInfo(&reader, .{});

    try std.testing.expectEqual(200, header.width);
    try std.testing.expectEqual(100, header.height);
    try std.testing.expectEqual(8, header.precision);
    try std.testing.expectEqual(3, header.num_components);
    try std.testing.expectEqual(FrameType.baseline, header.frame_type);
    try std.testing.expectEqual(Subsampling.yuv444, header.subsampling);
}

test "JPEG getInfo subsampling" {
    const gpa = std.testing.allocator;

    const cases = [_]struct { luma: u8, expected: ?Subsampling }{
        .{ .luma = 0x22, .expected = .yuv420 },
        .{ .luma = 0x21, .expected = .yuv422 },
        .{ .luma = 0x11, .expected = .yuv444 },
        .{ .luma = 0x12, .expected = null },
    };

    for (cases) |case| {
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(gpa);

        try data.appendSlice(gpa, &signature);
        // SOF0
        try data.append(gpa, 0xFF);
        try data.append(gpa, 0xC0);
        try data.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeTo(u16, 17, .big))); // Length
        try data.append(gpa, 8); // Precision
        try data.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeTo(u16, 100, .big))); // Height
        try data.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeTo(u16, 200, .big))); // Width
        try data.append(gpa, 3); // Components
        try data.appendSlice(gpa, &[_]u8{ 1, case.luma, 0, 2, 0x11, 1, 3, 0x11, 1 });
        // EOI
        try data.append(gpa, 0xFF);
        try data.append(gpa, 0xD9);

        var reader: Io.Reader = .fixed(data.items);
        const header = try getInfo(&reader, .{});
        try std.testing.expectEqual(case.expected, header.subsampling);
    }
}

// -----------------------------
// Encoder: public API and types
// -----------------------------

pub const Subsampling = enum {
    yuv444,
    yuv422,
    yuv420,

    /// Packed SOF luma sampling factors (h << 4 | v); chroma is always 1x1.
    pub fn lumaFactors(self: Subsampling) u8 {
        return switch (self) {
            .yuv444 => 0x11,
            .yuv422 => 0x21,
            .yuv420 => 0x22,
        };
    }

    pub fn fromLumaFactors(factors: u8) ?Subsampling {
        return switch (factors) {
            0x11 => .yuv444,
            0x21 => .yuv422,
            0x22 => .yuv420,
            else => null,
        };
    }
};

/// Restart interval (DRI) of the scan. Markers let a decoder resume at every segment, which
/// `decodeInto` uses to decode segments in parallel; each costs a marker and a DC predictor
/// reset (one row per interval is ~0.1 % of a 4K file and ~2 % more cycles to decode serially).
pub const RestartInterval = union(enum) {
    none,
    /// Every `rows` MCU rows.
    rows: u16,
    /// Every `mcus` MCUs.
    mcus: u16,

    /// MCUs per interval for a scan `mcus_per_row` wide; 0 means no markers.
    fn mcusFor(self: RestartInterval, mcus_per_row: usize) u16 {
        return switch (self) {
            .none => 0,
            .mcus => |n| n,
            .rows => |r| @intCast(@min(std.math.maxInt(u16), @as(usize, r) * mcus_per_row)),
        };
    }
};

pub const EncodeOptions = struct {
    quality: u8 = 90,
    subsampling: Subsampling = .yuv420,
    density_dpi: u16 = 72,
    comment: ?[]const u8 = null,
    /// One MCU row per restart interval by default, so the file decodes in parallel.
    restart_interval: RestartInterval = .{ .rows = 1 },
    pub const default: EncodeOptions = .{};
};

/// Save Image to JPEG file with baseline encoding.
pub fn save(comptime T: type, io: Io, allocator: Allocator, image: Image(T), file_path: []const u8) !void {
    const bytes = try encode(T, io, allocator, image, .default);
    defer allocator.free(bytes);

    const file = try Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

/// Encode an image into baseline JPEG bytes (SOF0, 8-bit, Huffman). Supports grayscale (u8)
/// and RGB (Rgb); other types are converted to RGB. With restart intervals the scan is
/// encoded in bands on `io`, one restart segment run per band.
pub fn encode(comptime T: type, io: Io, allocator: Allocator, image: Image(T), options: EncodeOptions) ![]u8 {
    // Validate image dimensions
    if (image.rows == 0 or image.cols == 0) {
        return error.InvalidImageDimensions;
    }
    if (image.rows > 65535 or image.cols > 65535) {
        return error.ImageTooLarge;
    }

    switch (T) {
        u8 => {
            if (image.isContiguous()) return encodeGrayscale(io, allocator, image.asBytes(), @intCast(image.cols), @intCast(image.rows), options);
            var contiguous = try image.dupe(allocator);
            defer contiguous.deinit(allocator);
            return encodeGrayscale(io, allocator, contiguous.asBytes(), @intCast(image.cols), @intCast(image.rows), options);
        },
        Rgb => return encodeRgb(io, allocator, image, options),
        else => {
            var converted = try image.convert(io, allocator, Rgb);
            defer converted.deinit(allocator);
            return encodeRgb(io, allocator, converted, options);
        },
    }
}

// -----------------------------
// Encoder: internals
// -----------------------------

const StdTables = struct {
    // Base quantization tables (ITU T.81, Annex K)
    const q_luma_base: [64]u8 = .{
        16, 11, 10, 16, 24,  40,  51,  61,
        12, 12, 14, 19, 26,  58,  60,  55,
        14, 13, 16, 24, 40,  57,  69,  56,
        14, 17, 22, 29, 51,  87,  80,  62,
        18, 22, 37, 56, 68,  109, 103, 77,
        24, 35, 55, 64, 81,  104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101,
        72, 92, 95, 98, 112, 100, 103, 99,
    };
    const q_chroma_base: [64]u8 = .{
        17, 18, 24, 47, 99, 99, 99, 99,
        18, 21, 26, 66, 99, 99, 99, 99,
        24, 26, 56, 99, 99, 99, 99, 99,
        47, 66, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
    };

    // Standard Huffman tables (bits and values)
    // Luminance DC
    const bits_dc_luma: [16]u8 = .{ 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 };
    const val_dc_luma: [12]u8 = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    // Chrominance DC
    const bits_dc_chroma: [16]u8 = .{ 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 };
    const val_dc_chroma: [12]u8 = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };

    // Luminance AC
    const bits_ac_luma: [16]u8 = .{ 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125 };
    const val_ac_luma: [162]u8 = .{
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
        0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
        0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
        0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
        0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
        0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
        0xf9, 0xfa,
    };
    // Chrominance AC
    const bits_ac_chroma: [16]u8 = .{ 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 119 };
    const val_ac_chroma: [162]u8 = .{
        0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
        0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
        0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
        0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
        0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
        0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
        0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
        0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
        0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
        0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
        0xf9, 0xfa,
    };
};

/// Per symbol `code << 8 | length`, one load per coded coefficient.
const HuffmanEncoder = struct {
    entries: [256]u32 = @splat(0),

    inline fn code(self: *const HuffmanEncoder, symbol: u32) u32 {
        return self.entries[symbol] >> 8;
    }
    inline fn size(self: *const HuffmanEncoder, symbol: u32) u32 {
        return self.entries[symbol] & 0xFF;
    }
};

fn buildHuffmanEncoder(bits: []const u8, vals: []const u8) HuffmanEncoder {
    var enc = HuffmanEncoder{};
    var code: u32 = 0;
    var k: usize = 0;
    for (0..16) |i| {
        const nb = bits[i];
        for (0..nb) |_| {
            const sym = vals[k];
            enc.entries[sym] = code << 8 | @as(u32, @intCast(i + 1));
            code += 1;
            k += 1;
        }
        code = code << 1;
    }
    return enc;
}

fn writeMarker(dst: *std.ArrayList(u8), gpa: Allocator, marker: u16) !void {
    try dst.append(gpa, 0xFF);
    try dst.append(gpa, @intCast(marker & 0xFF));
}

fn writeDRI(dst: *std.ArrayList(u8), gpa: Allocator, interval: u16) !void {
    try writeSegment(dst, gpa, 0xFFDD, &std.mem.toBytes(std.mem.nativeTo(u16, interval, .big)));
}

fn writeSegment(dst: *std.ArrayList(u8), gpa: Allocator, marker: u16, payload: []const u8) !void {
    try writeMarker(dst, gpa, marker);
    const len: u16 = @intCast(payload.len + 2);
    try dst.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeTo(u16, len, .big)));
    try dst.appendSlice(gpa, payload);
}

fn scaleQuantTables(quality: u8, ql: *[64]u8, qc: *[64]u8) void {
    const q = @max(@as(u8, 1), @min(@as(u8, 100), quality));
    const scale: i32 = if (q < 50)
        @divTrunc(@as(i32, 5000), @as(i32, q))
    else
        200 - @as(i32, q) * 2;
    for (0..64) |i| {
        const l = @divTrunc((@as(i32, StdTables.q_luma_base[i]) * scale + 50), 100);
        const c = @divTrunc((@as(i32, StdTables.q_chroma_base[i]) * scale + 50), 100);
        ql[i] = @intCast(@max(1, @min(255, l)));
        qc[i] = @intCast(@max(1, @min(255, c)));
    }
}

fn writeDQT(dst: *std.ArrayList(u8), gpa: Allocator, ql: *const [64]u8, qc: *const [64]u8) !void {
    var tmp = std.ArrayList(u8).empty;
    defer tmp.deinit(gpa);

    // Luma table (8-bit precision, id 0)
    try tmp.append(gpa, 0x00);
    for (0..64) |i| try tmp.append(gpa, ql[zigzag[i]]);

    // Chroma table (8-bit precision, id 1)
    try tmp.append(gpa, 0x01);
    for (0..64) |i| try tmp.append(gpa, qc[zigzag[i]]);

    try writeSegment(dst, gpa, 0xFFDB, tmp.items);
}

fn writeSOF0(dst: *std.ArrayList(u8), gpa: Allocator, width: u16, height: u16, grayscale: bool, subsampling: Subsampling) !void {
    var tmp = std.ArrayList(u8).empty;
    defer tmp.deinit(gpa);
    try tmp.append(gpa, 8); // precision
    try tmp.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeTo(u16, height, .big)));
    try tmp.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeTo(u16, width, .big)));
    if (grayscale) {
        try tmp.append(gpa, 1);
        try tmp.append(gpa, 1); // comp id
        try tmp.append(gpa, 0x11); // sampling 1x1
        try tmp.append(gpa, 0); // quant table id 0
    } else {
        try tmp.append(gpa, 3);
        // Y
        try tmp.append(gpa, 1);
        try tmp.append(gpa, subsampling.lumaFactors());
        try tmp.append(gpa, 0);
        // Cb
        try tmp.append(gpa, 2);
        try tmp.append(gpa, 0x11);
        try tmp.append(gpa, 1);
        // Cr
        try tmp.append(gpa, 3);
        try tmp.append(gpa, 0x11);
        try tmp.append(gpa, 1);
    }
    try writeSegment(dst, gpa, 0xFFC0, tmp.items);
}

fn writeAPP0_JFIF(dst: *std.ArrayList(u8), gpa: Allocator, density_dpi: u16) !void {
    var tmp = std.ArrayList(u8).empty;
    defer tmp.deinit(gpa);
    try tmp.appendSlice(gpa, "JFIF\x00");
    try tmp.append(gpa, 1); // version major
    try tmp.append(gpa, 1); // version minor
    try tmp.append(gpa, 1); // units: dots per inch
    try tmp.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeTo(u16, density_dpi, .big)));
    try tmp.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeTo(u16, density_dpi, .big)));
    try tmp.append(gpa, 0); // x thumbnail
    try tmp.append(gpa, 0); // y thumbnail
    try writeSegment(dst, gpa, 0xFFE0, tmp.items);
}

fn writeCOM(dst: *std.ArrayList(u8), gpa: Allocator, comment: []const u8) !void {
    try writeSegment(dst, gpa, 0xFFFE, comment);
}

fn writeDHT(dst: *std.ArrayList(u8), gpa: Allocator, grayscale: bool) !void {
    var tmp = std.ArrayList(u8).empty;
    defer tmp.deinit(gpa);

    // DC Luma (class 0, id 0)
    try tmp.append(gpa, 0x00);
    try tmp.appendSlice(gpa, &StdTables.bits_dc_luma);
    try tmp.appendSlice(gpa, &StdTables.val_dc_luma);
    // AC Luma (class 1, id 0)
    try tmp.append(gpa, 0x10);
    try tmp.appendSlice(gpa, &StdTables.bits_ac_luma);
    try tmp.appendSlice(gpa, &StdTables.val_ac_luma);

    if (!grayscale) {
        // DC Chroma (class 0, id 1)
        try tmp.append(gpa, 0x01);
        try tmp.appendSlice(gpa, &StdTables.bits_dc_chroma);
        try tmp.appendSlice(gpa, &StdTables.val_dc_chroma);
        // AC Chroma (class 1, id 1)
        try tmp.append(gpa, 0x11);
        try tmp.appendSlice(gpa, &StdTables.bits_ac_chroma);
        try tmp.appendSlice(gpa, &StdTables.val_ac_chroma);
    }

    try writeSegment(dst, gpa, 0xFFC4, tmp.items);
}

fn writeSOS(dst: *std.ArrayList(u8), gpa: Allocator, grayscale: bool) !void {
    var tmp = std.ArrayList(u8).empty;
    defer tmp.deinit(gpa);
    if (grayscale) {
        try tmp.append(gpa, 1);
        try tmp.append(gpa, 1); // component id
        try tmp.append(gpa, 0x00); // DC 0, AC 0
    } else {
        try tmp.append(gpa, 3);
        try tmp.append(gpa, 1); // Y
        try tmp.append(gpa, 0x00);
        try tmp.append(gpa, 2); // Cb
        try tmp.append(gpa, 0x11);
        try tmp.append(gpa, 3); // Cr
        try tmp.append(gpa, 0x11);
    }
    try tmp.append(gpa, 0); // Ss
    try tmp.append(gpa, 63); // Se
    try tmp.append(gpa, 0); // Ah/Al
    try writeSegment(dst, gpa, 0xFFDA, tmp.items);
}

// -----------------------------
// Encoder: entropy writer
// -----------------------------

/// Big-endian bit packer; every 0xFF byte gets its stuffed zero. Callers reserve room per
/// block so the hot path never allocates, and code a block through a `Bits` register copy
/// of the pending bits.
const BitWriter = struct {
    gpa: Allocator,
    list: std.ArrayList(u8) = .empty,
    pending: Bits = .{},

    /// Right-aligned pending bits.
    const Bits = struct {
        acc: u64 = 0,
        count: u32 = 0,
    };

    /// The largest block (64 codes of up to 27 bits, every byte stuffed) plus a marker.
    const block_reserve = 512;

    fn deinit(self: *BitWriter) void {
        self.list.deinit(self.gpa);
    }

    fn reserve(self: *BitWriter) !void {
        try self.list.ensureUnusedCapacity(self.gpa, block_reserve);
    }

    /// Appends `size` (1-27) bits.
    inline fn put(self: *BitWriter, bits: *Bits, code: u32, size: u32) void {
        bits.acc = (bits.acc << @intCast(size)) | code;
        bits.count += size;
        if (bits.count >= 32) self.emitWord(bits);
    }

    /// Writes the oldest 32 pending bits, four bytes at once when none is 0xFF.
    inline fn emitWord(self: *BitWriter, bits: *Bits) void {
        bits.count -= 32;
        const word: u32 = @truncate(bits.acc >> @intCast(bits.count));
        const has_ff = (word & 0x7F7F7F7F) + 0x01010101 & word & 0x80808080;
        const bytes: [4]u8 = @bitCast(std.mem.nativeToBig(u32, word));
        if (has_ff == 0) {
            self.list.appendSliceAssumeCapacity(&bytes);
        } else {
            for (bytes) |byte| self.putByte(byte);
        }
    }

    fn putByte(self: *BitWriter, byte: u8) void {
        self.list.appendAssumeCapacity(byte);
        if (byte == 0xFF) self.list.appendAssumeCapacity(0x00);
    }

    /// Pads to a byte boundary with 1 bits and writes everything out.
    fn flush(self: *BitWriter) void {
        var bits = self.pending;
        const partial = bits.count % 8;
        if (partial != 0) self.put(&bits, (@as(u32, 1) << @intCast(8 - partial)) - 1, 8 - partial);
        while (bits.count >= 8) {
            bits.count -= 8;
            self.putByte(@truncate(bits.acc >> @intCast(bits.count)));
        }
        self.pending = bits;
    }

    /// Ends a restart interval: pads and emits RSTn (a marker, not stuffed).
    fn restart(self: *BitWriter, n: u3) void {
        self.flush();
        self.list.appendAssumeCapacity(0xFF);
        self.list.appendAssumeCapacity(0xD0 + @as(u8, n));
    }
};

inline fn magnitudeCategory(value: i32) u5 {
    return @intCast(32 - @clz(@abs(value)));
}

/// Magnitude bits of `value` (T.81 F.1.2.1): negative values are stored as their one's
/// complement, computed without a branch on the sign.
inline fn magnitudeBits(value: i32, mag: u5) u32 {
    const negative_mask = value >> 31;
    return @bitCast(value + (negative_mask & ((@as(i32, 1) << mag) - 1)));
}

/// Maps each byte of a natural-order nonzero mask to its bits in zigzag order.
const zigzag_masks: [8][256]u64 = blk: {
    @setEvalBranchQuota(20000);
    var inverse: [64]u6 = undefined;
    for (zigzag, 0..) |natural, k| inverse[natural] = k;
    var tables: [8][256]u64 = undefined;
    for (&tables, 0..) |*table, byte| {
        for (table, 0..) |*entry, pattern| {
            var m: u64 = 0;
            for (0..8) |bit| {
                if (pattern >> bit & 1 != 0) m |= @as(u64, 1) << inverse[byte * 8 + bit];
            }
            entry.* = m;
        }
    }
    break :blk tables;
};

/// Huffman-codes one quantized block (natural order) with the DC predictor. A bitmask of
/// the nonzero coefficients in zigzag order drives the loop, one step per coded coefficient,
/// so zero runs cost no branches.
fn encodeBlockCoefs(w: *BitWriter, coefs: *const [64]i16, dc: *const HuffmanEncoder, ac: *const HuffmanEncoder, prev_dc: *i32) void {
    var bits = w.pending;
    defer w.pending = bits;

    const dc_val: i32 = coefs[0];
    const diff = dc_val - prev_dc.*;
    prev_dc.* = dc_val;
    const mag = magnitudeCategory(diff);
    w.put(&bits, dc.code(mag) << mag | magnitudeBits(diff, mag), dc.size(mag) + mag);

    var natural: u64 = 0;
    inline for (0..4) |i| {
        const v: @Vector(16, i16) = coefs[i * 16 ..][0..16].*;
        const nonzero: u16 = @bitCast(v != @as(@Vector(16, i16), @splat(0)));
        natural |= @as(u64, nonzero) << (i * 16);
    }
    var mask: u64 = 0;
    inline for (0..8) |i| mask |= zigzag_masks[i][@as(u8, @truncate(natural >> (8 * i)))];
    mask &= ~@as(u64, 1);

    var last: u32 = 0;
    while (mask != 0) {
        const k: u32 = @ctz(mask);
        mask &= mask - 1;
        var run = k - last - 1;
        while (run >= 16) : (run -= 16) w.put(&bits, ac.code(0xF0), ac.size(0xF0));
        const v: i32 = coefs[zigzag[k]];
        const m = magnitudeCategory(v);
        const sym = run << 4 | m;
        w.put(&bits, ac.code(sym) << m | magnitudeBits(v, m), ac.size(sym) + m);
        last = k;
    }
    if (last != 63) w.put(&bits, ac.code(0x00), ac.size(0x00));
}

// -----------------------------
// Encoder: forward DCT and quantization
// -----------------------------

/// Quantizer for one coefficient position: `(|x| + corr) * recip >> shift` equals
/// `(|x| + d / 2) / d` for every 15-bit `|x|` (libjpeg-turbo's reciprocal construction).
const QuantDivisor = struct {
    recip: u32,
    corr: u32,
    shift: u32,

    fn init(divisor: u32) QuantDivisor {
        std.debug.assert(divisor >= 2);
        const b: u5 = @intCast(31 - @clz(divisor));
        var shift: u6 = @as(u6, 16) + b;
        var recip: u64 = (@as(u64, 1) << shift) / divisor;
        const rem = (@as(u64, 1) << shift) % divisor;
        var corr: u32 = divisor / 2;
        if (rem == 0) {
            // Power of two: the reciprocal would need 17 bits.
            recip >>= 1;
            shift -= 1;
        } else if (rem <= divisor / 2) {
            corr += 1;
        } else {
            recip += 1;
        }
        return .{ .recip = @intCast(recip), .corr = corr, .shift = shift };
    }
};

/// Per-component quantization: divisors are `8 * q`, the DCT's own scale folded in.
const Quantizer = struct {
    recip: [64]u32,
    corr: [64]u32,
    shift: [64]u32,

    fn init(table: *const [64]u8) Quantizer {
        var self: Quantizer = undefined;
        for (table, 0..) |q, i| {
            const d: QuantDivisor = .init(@as(u32, q) * 8);
            self.recip[i] = d.recip;
            self.corr[i] = d.corr;
            self.shift[i] = d.shift;
        }
        return self;
    }
};

/// Forward DCT: libjpeg's jfdctint butterflies on 16-lane vectors, two blocks side by side
/// like `Idct`, followed by quantization. Output is the quantized block in natural order.
const Fdct = struct {
    const V16 = Dct.V16;
    const V8 = Dct.V8;
    const U32 = @Vector(16, u32);

    const const_bits = 13;
    fn fix(comptime x: f32) i16 {
        return @intFromFloat(@round(x * (1 << const_bits)));
    }
    const f0298 = fix(0.298631336);
    const f0390 = fix(0.390180644);
    const f0541 = fix(0.541196100);
    const f0765 = fix(0.765366865);
    const f0899 = fix(0.899976223);
    const f1175 = fix(1.175875602);
    const f1501 = fix(1.501321110);
    const f1847 = fix(1.847759065);
    const f1961 = fix(1.961570560);
    const f2053 = fix(2.053119869);
    const f2562 = fix(2.562915447);
    const f3072 = fix(3.072711026);

    // Even outputs from (tmp13, tmp12); odd outputs as two dot products with jfdctint's z1..z5 cross terms folded into the constants.
    const c2 = Dct.pair(f0541 + f0765, f0541);
    const c6 = Dct.pair(f0541, f0541 - f1847);
    const c7a = Dct.pair(f0298 - f0899 - f1961 + f1175, f1175 - f0899);
    const c7b = Dct.pair(f1175, f1175 - f1961);
    const c5a = Dct.pair(f1175, f1175 - f0390);
    const c5b = Dct.pair(f2053 - f2562 - f0390 + f1175, f1175 - f2562);
    const c3a = Dct.pair(f1175 - f1961, f1175);
    const c3b = Dct.pair(f1175 - f2562, f3072 - f2562 - f1961 + f1175);
    const c1a = Dct.pair(f1175 - f0899, f1501 - f0899 - f0390 + f1175);
    const c1b = Dct.pair(f1175 - f0390, f1175);

    inline fn descale(l: V8, h: V8, comptime shift: u5) V16 {
        const round: V8 = @splat(@as(i32, 1) << (shift - 1));
        return Dct.packs((l + round) >> @splat(shift), (h + round) >> @splat(shift));
    }

    /// One 1-D pass. Pass 1 keeps two extra fraction bits, pass 2 removes them.
    inline fn pass(r: *[8]V16, comptime first: bool) void {
        const tmp0 = r[0] +| r[7];
        const tmp7 = r[0] -| r[7];
        const tmp1 = r[1] +| r[6];
        const tmp6 = r[1] -| r[6];
        const tmp2 = r[2] +| r[5];
        const tmp5 = r[2] -| r[5];
        const tmp3 = r[3] +| r[4];
        const tmp4 = r[3] -| r[4];
        const tmp10 = tmp0 +| tmp3;
        const tmp13 = tmp0 -| tmp3;
        const tmp11 = tmp1 +| tmp2;
        const tmp12 = tmp1 -| tmp2;
        const shift = if (first) const_bits - 2 else const_bits + 2;
        if (first) {
            r[0] = (tmp10 +| tmp11) << @splat(2);
            r[4] = (tmp10 -| tmp11) << @splat(2);
        } else {
            const two: V16 = @splat(2);
            r[0] = (tmp10 +| tmp11 +| two) >> @splat(2);
            r[4] = (tmp10 -| tmp11 +| two) >> @splat(2);
        }
        const e_lo = Dct.unpacklo(tmp13, tmp12);
        const e_hi = Dct.unpackhi(tmp13, tmp12);
        r[2] = descale(Dct.madd(e_lo, c2), Dct.madd(e_hi, c2), shift);
        r[6] = descale(Dct.madd(e_lo, c6), Dct.madd(e_hi, c6), shift);
        const a_lo = Dct.unpacklo(tmp4, tmp7);
        const a_hi = Dct.unpackhi(tmp4, tmp7);
        const b_lo = Dct.unpacklo(tmp5, tmp6);
        const b_hi = Dct.unpackhi(tmp5, tmp6);
        r[7] = descale(Dct.madd(a_lo, c7a) + Dct.madd(b_lo, c7b), Dct.madd(a_hi, c7a) + Dct.madd(b_hi, c7b), shift);
        r[5] = descale(Dct.madd(a_lo, c5a) + Dct.madd(b_lo, c5b), Dct.madd(a_hi, c5a) + Dct.madd(b_hi, c5b), shift);
        r[3] = descale(Dct.madd(a_lo, c3a) + Dct.madd(b_lo, c3b), Dct.madd(a_hi, c3a) + Dct.madd(b_hi, c3b), shift);
        r[1] = descale(Dct.madd(a_lo, c1a) + Dct.madd(b_lo, c1b), Dct.madd(a_hi, c1a) + Dct.madd(b_hi, c1b), shift);
    }

    /// Transforms and quantizes the 8x8 sample tiles at `a` and `b` (the same component),
    /// row-major with `stride`, into natural-order coefficient blocks.
    fn pairInto(a: [*]const u8, b: [*]const u8, stride: usize, quant: *const Quantizer, out_a: *[64]i16, out_b: *[64]i16) void {
        var r: [8]V16 = undefined;
        for (0..8) |i| {
            const row_a: @Vector(8, u8) = a[i * stride ..][0..8].*;
            const row_b: @Vector(8, u8) = b[i * stride ..][0..8].*;
            const samples: V16 = @intCast(@shuffle(u8, row_a, row_b, Dct.concat));
            r[i] = samples - @as(V16, @splat(128));
        }
        // Rows first (lanes are rows after a transpose), then columns.
        Dct.transpose(&r);
        pass(&r, true);
        Dct.transpose(&r);
        pass(&r, false);
        for (0..8) |i| {
            const recip: U32 = @shuffle(u32, @as(@Vector(8, u32), quant.recip[i * 8 ..][0..8].*), undefined, Dct.dup8);
            const corr: U32 = @shuffle(u32, @as(@Vector(8, u32), quant.corr[i * 8 ..][0..8].*), undefined, Dct.dup8);
            const shift: U32 = @shuffle(u32, @as(@Vector(8, u32), quant.shift[i * 8 ..][0..8].*), undefined, Dct.dup8);
            const mag: U32 = @intCast(@abs(r[i]));
            const q: V16 = @intCast(((mag + corr) * recip) >> @as(@Vector(16, u5), @intCast(shift)));
            const signed = @select(i16, r[i] < @as(V16, @splat(0)), -q, q);
            const both: [16]i16 = signed;
            out_a[i * 8 ..][0..8].* = both[0..8].*;
            out_b[i * 8 ..][0..8].* = both[8..16].*;
        }
    }
};

// -----------------------------
// Encoder: MCU-row pipeline
// -----------------------------

/// Sample planes for one MCU row: luma at full resolution, chroma at its sampling, widths
/// padded to whole MCUs (edge pixels replicated) plus vector slack, and the quantized
/// coefficient blocks of the row in plane order.
const EncodeBand = struct {
    allocator: Allocator,
    h_max: usize,
    v_max: usize,
    mcu_cols: usize,
    y_stride: usize,
    c_stride: usize,
    y: []u8,
    /// Full-resolution chroma; the subsampled planes are derived from these.
    cb_full: []u8,
    cr_full: []u8,
    cb: []u8,
    cr: []u8,
    y_coefs: [][64]i16,
    cb_coefs: [][64]i16,
    cr_coefs: [][64]i16,

    const slack = 32;

    fn init(allocator: Allocator, cols: usize, h_max: usize, v_max: usize, chroma: bool) !EncodeBand {
        const mcu_cols = (cols + 8 * h_max - 1) / (8 * h_max);
        const y_stride = mcu_cols * 8 * h_max;
        const c_stride = mcu_cols * 8;
        const rows = 8 * v_max;
        var self: EncodeBand = .{
            .allocator = allocator,
            .h_max = h_max,
            .v_max = v_max,
            .mcu_cols = mcu_cols,
            .y_stride = y_stride,
            .c_stride = c_stride,
            .y = &.{},
            .cb_full = &.{},
            .cr_full = &.{},
            .cb = &.{},
            .cr = &.{},
            .y_coefs = &.{},
            .cb_coefs = &.{},
            .cr_coefs = &.{},
        };
        errdefer self.deinit();
        self.y = try allocator.alloc(u8, y_stride * rows + slack);
        self.y_coefs = try allocator.alloc([64]i16, mcu_cols * h_max * v_max);
        if (chroma) {
            self.cb_full = try allocator.alloc(u8, y_stride * rows + slack);
            self.cr_full = try allocator.alloc(u8, y_stride * rows + slack);
            if (h_max == 1 and v_max == 1) {
                self.cb = self.cb_full;
                self.cr = self.cr_full;
            } else {
                self.cb = try allocator.alloc(u8, c_stride * 8 + slack);
                self.cr = try allocator.alloc(u8, c_stride * 8 + slack);
            }
            self.cb_coefs = try allocator.alloc([64]i16, mcu_cols);
            self.cr_coefs = try allocator.alloc([64]i16, mcu_cols);
        }
        return self;
    }

    fn deinit(self: *EncodeBand) void {
        self.allocator.free(self.y);
        self.allocator.free(self.cb_full);
        self.allocator.free(self.cr_full);
        if (self.cb.ptr != self.cb_full.ptr) {
            self.allocator.free(self.cb);
            self.allocator.free(self.cr);
        }
        self.allocator.free(self.y_coefs);
        self.allocator.free(self.cb_coefs);
        self.allocator.free(self.cr_coefs);
    }

    /// Converts the pixel rows of MCU row `mcu_y` into the planes, replicating edges.
    fn fillRgb(self: *EncodeBand, image: Image(Rgb), mcu_y: usize) void {
        const rows = 8 * self.v_max;
        for (0..rows) |r| {
            const src_row = @min(mcu_y * rows + r, image.rows - 1);
            const src = image.data[src_row * image.stride ..][0..image.cols];
            convertRow(src, self.y[r * self.y_stride ..], self.cb_full[r * self.y_stride ..], self.cr_full[r * self.y_stride ..]);
            for ([_][]u8{ self.y, self.cb_full, self.cr_full }) |plane| {
                const row = plane[r * self.y_stride ..][0..self.y_stride];
                @memset(row[image.cols..], row[image.cols - 1]);
            }
        }
        if (self.h_max == 2) {
            for ([_][2][]u8{ .{ self.cb_full, self.cb }, .{ self.cr_full, self.cr } }) |planes| {
                for (0..8) |cy| {
                    const top = planes[0][cy * self.v_max * self.y_stride ..];
                    const bottom = planes[0][(cy * self.v_max + self.v_max - 1) * self.y_stride ..];
                    downsampleRow(top, bottom, self.v_max == 2, planes[1][cy * self.c_stride ..], self.c_stride);
                }
            }
        }
    }

    /// Copies grayscale rows into the luma plane, replicating edges.
    fn fillGray(self: *EncodeBand, bytes: []const u8, cols: usize, rows_total: usize, mcu_y: usize) void {
        for (0..8) |r| {
            const src_row = @min(mcu_y * 8 + r, rows_total - 1);
            const row = self.y[r * self.y_stride ..][0..self.y_stride];
            @memcpy(row[0..cols], bytes[src_row * cols ..][0..cols]);
            @memset(row[cols..], row[cols - 1]);
        }
    }

    /// BT.601 RGB to YCbCr, 16 pixels at a time with the fixed-point constants of
    /// `convertColor`, so the result matches the scalar conversion exactly.
    fn convertRow(src: []const Rgb, y: []u8, cb: []u8, cr: []u8) void {
        const V = @Vector(16, i32);
        var px: usize = 0;
        if (RenderBand.packed_rgb) {
            while (px + 16 <= src.len) : (px += 16) {
                const bytes: @Vector(48, u8) = std.mem.sliceAsBytes(src[px..][0..16])[0..48].*;
                const r: V = @intCast(@shuffle(u8, bytes, undefined, deinterleave_r));
                const g: V = @intCast(@shuffle(u8, bytes, undefined, deinterleave_g));
                const b: V = @intCast(@shuffle(u8, bytes, undefined, deinterleave_b));
                const half: V = @splat(32768);
                const bias: V = @splat(128);
                const lo: V = @splat(0);
                const hi: V = @splat(255);
                const yv = (@as(V, @splat(19595)) * r + @as(V, @splat(38470)) * g + @as(V, @splat(7471)) * b + half) >> @splat(16);
                const cbv = ((@as(V, @splat(-11059)) * r + @as(V, @splat(-21710)) * g + @as(V, @splat(32768)) * b + half) >> @splat(16)) + bias;
                const crv = ((@as(V, @splat(32768)) * r + @as(V, @splat(-27439)) * g + @as(V, @splat(-5329)) * b + half) >> @splat(16)) + bias;
                y[px..][0..16].* = meta.narrowToBytes(std.math.clamp(yv, lo, hi));
                cb[px..][0..16].* = meta.narrowToBytes(std.math.clamp(cbv, lo, hi));
                cr[px..][0..16].* = meta.narrowToBytes(std.math.clamp(crv, lo, hi));
            }
        }
        for (src[px..], y[px..src.len], cb[px..src.len], cr[px..src.len]) |p, *yo, *cbo, *cro| {
            const ycc = convertColor(Ycbcr, p);
            yo.* = ycc.y;
            cbo.* = ycc.cb;
            cro.* = ycc.cr;
        }
    }

    const deinterleave_r = blk: {
        var m: [16]i32 = undefined;
        for (0..16) |i| m[i] = 3 * i;
        break :blk m;
    };
    const deinterleave_g = blk: {
        var m: [16]i32 = undefined;
        for (0..16) |i| m[i] = 3 * i + 1;
        break :blk m;
    };
    const deinterleave_b = blk: {
        var m: [16]i32 = undefined;
        for (0..16) |i| m[i] = 3 * i + 2;
        break :blk m;
    };
    const evens = blk: {
        var m: [16]i32 = undefined;
        for (0..16) |i| m[i] = 2 * i;
        break :blk m;
    };
    const odds = blk: {
        var m: [16]i32 = undefined;
        for (0..16) |i| m[i] = 2 * i + 1;
        break :blk m;
    };

    /// Averages horizontal pairs (and the two rows when `vertical`) into `dst`, rounding
    /// to nearest: 16 chroma samples per step from 32 (or 64) inputs.
    fn downsampleRow(top: []const u8, bottom: []const u8, vertical: bool, dst: []u8, count: usize) void {
        const W = @Vector(32, u16);
        const V = @Vector(16, u16);
        var cx: usize = 0;
        while (cx < count) : (cx += 16) {
            var sum: W = @intCast(@as(@Vector(32, u8), top[2 * cx ..][0..32].*));
            if (vertical) sum += @as(W, @intCast(@as(@Vector(32, u8), bottom[2 * cx ..][0..32].*)));
            const pairs: V = @shuffle(u16, sum, undefined, evens) + @shuffle(u16, sum, undefined, odds);
            const avg = if (vertical) (pairs + @as(V, @splat(2))) >> @splat(2) else (pairs + @as(V, @splat(1))) >> @splat(1);
            dst[cx..][0..16].* = @as(@Vector(16, u8), @intCast(avg));
        }
    }

    /// Transforms every block of a plane in adjacent pairs (an odd last block against itself).
    fn transformPlane(plane: []const u8, stride: usize, block_rows: usize, quant: *const Quantizer, coefs: [][64]i16) void {
        const blocks_per_row = stride / 8;
        for (0..block_rows) |by| {
            const row = plane[by * 8 * stride ..].ptr;
            var bx: usize = 0;
            while (bx < blocks_per_row) : (bx += 2) {
                const bx1 = @min(bx + 1, blocks_per_row - 1);
                var spare: [64]i16 = undefined;
                const out_b = if (bx1 == bx) &spare else &coefs[by * blocks_per_row + bx1];
                Fdct.pairInto(row + bx * 8, row + bx1 * 8, stride, quant, &coefs[by * blocks_per_row + bx], out_b);
            }
        }
    }
};

const ScanTables = struct {
    y_quant: Quantizer,
    c_quant: Quantizer,
    dc_luma: HuffmanEncoder,
    ac_luma: HuffmanEncoder,
    dc_chroma: HuffmanEncoder,
    ac_chroma: HuffmanEncoder,
};

/// Entropy-codes MCUs `[x0, x1)` of the band's row from its coefficient blocks in
/// interleaved order.
fn encodeBandScan(w: *BitWriter, band: *const EncodeBand, tables: *const ScanTables, chroma: bool, restart_interval: u16, mcus_in_interval: *u16, rst_index: *u3, prev_dc: *[3]i32, x0: usize, x1: usize) !void {
    const blocks_per_row = band.y_stride / 8;
    for (x0..x1) |mcu_x| {
        try w.reserve();
        if (restart_interval != 0 and mcus_in_interval.* == restart_interval) {
            w.restart(rst_index.*);
            rst_index.* +%= 1;
            mcus_in_interval.* = 0;
            prev_dc.* = @splat(0);
        }
        mcus_in_interval.* += 1;
        for (0..band.v_max) |vy| {
            for (0..band.h_max) |hx| {
                try w.reserve();
                encodeBlockCoefs(w, &band.y_coefs[vy * blocks_per_row + mcu_x * band.h_max + hx], &tables.dc_luma, &tables.ac_luma, &prev_dc[0]);
            }
        }
        if (chroma) {
            try w.reserve();
            encodeBlockCoefs(w, &band.cb_coefs[mcu_x], &tables.dc_chroma, &tables.ac_chroma, &prev_dc[1]);
            try w.reserve();
            encodeBlockCoefs(w, &band.cr_coefs[mcu_x], &tables.dc_chroma, &tables.ac_chroma, &prev_dc[2]);
        }
    }
}

fn scanTables(ql: *const [64]u8, qc: *const [64]u8) ScanTables {
    return .{
        .y_quant = .init(ql),
        .c_quant = .init(qc),
        .dc_luma = buildHuffmanEncoder(&StdTables.bits_dc_luma, &StdTables.val_dc_luma),
        .ac_luma = buildHuffmanEncoder(&StdTables.bits_ac_luma, &StdTables.val_ac_luma),
        .dc_chroma = buildHuffmanEncoder(&StdTables.bits_dc_chroma, &StdTables.val_dc_chroma),
        .ac_chroma = buildHuffmanEncoder(&StdTables.bits_ac_chroma, &StdTables.val_ac_chroma),
    };
}

fn encodeRgb(io: Io, allocator: Allocator, image: Image(Rgb), options: EncodeOptions) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    // SOI
    try out.append(allocator, 0xFF);
    try out.append(allocator, 0xD8);

    try writeAPP0_JFIF(&out, allocator, options.density_dpi);
    if (options.comment) |c| try writeCOM(&out, allocator, c);

    var ql: [64]u8 = undefined;
    var qc: [64]u8 = undefined;
    scaleQuantTables(options.quality, &ql, &qc);
    try writeDQT(&out, allocator, &ql, &qc);
    try writeSOF0(&out, allocator, @intCast(image.cols), @intCast(image.rows), false, options.subsampling);
    try writeDHT(&out, allocator, false);
    const mcu_width: usize = 8 * @as(usize, options.subsampling.lumaFactors() >> 4);
    const restart_interval = options.restart_interval.mcusFor((image.cols + mcu_width - 1) / mcu_width);
    if (restart_interval != 0) try writeDRI(&out, allocator, restart_interval);
    try writeSOS(&out, allocator, false);

    const h_max: usize = switch (options.subsampling) {
        .yuv444 => 1,
        .yuv422, .yuv420 => 2,
    };
    const v_max: usize = switch (options.subsampling) {
        .yuv444, .yuv422 => 1,
        .yuv420 => 2,
    };
    const tables = scanTables(&ql, &qc);
    try encodeScan(io, allocator, &out, .{ .rgb = image }, &tables, image.cols, image.rows, h_max, v_max, true, restart_interval);

    // EOI
    try out.append(allocator, 0xFF);
    try out.append(allocator, 0xD9);

    return out.toOwnedSlice(allocator);
}

/// Pixel source of an encode; a band fills its planes from it one MCU row at a time.
const EncodeSource = union(enum) {
    rgb: Image(Rgb),
    gray: struct { bytes: []const u8, cols: usize, rows: usize },

    fn fill(self: EncodeSource, band: *EncodeBand, mcu_y: usize) void {
        switch (self) {
            .rgb => |img| band.fillRgb(img, mcu_y),
            .gray => |g| band.fillGray(g.bytes, g.cols, g.rows, mcu_y),
        }
    }
};

/// The scan: MCU rows are filled, transformed and entropy-coded in bands on `io`. Bands
/// own balanced runs of restart segments, so each writes an independent bitstream from
/// fresh DC predictors (re-filling at most the row shared at a boundary); appended in order
/// with the RSTn markers between them, the result is byte-identical to a single sweep.
/// Without restart markers there is one band.
fn encodeScan(io: Io, allocator: Allocator, out: *std.ArrayList(u8), source: EncodeSource, tables: *const ScanTables, cols: usize, rows: usize, h_max: usize, v_max: usize, chroma: bool, restart_interval: u16) !void {
    const mcu_cols = (cols + 8 * h_max - 1) / (8 * h_max);
    const mcu_rows = (rows + 8 * v_max - 1) / (8 * v_max);
    const total = mcu_cols * mcu_rows;
    const interval: usize = restart_interval;
    const segments = if (interval == 0) 1 else (total + interval - 1) / interval;
    const bands = @min(parallel.bandCount(mcu_rows, cols * 8 * v_max), segments);

    const Band = struct {
        mcu0: usize,
        mcu1: usize,
        seg0: usize,
        w: BitWriter,
        err: ?anyerror = null,
    };
    const Ctx = struct {
        allocator: Allocator,
        source: EncodeSource,
        tables: *const ScanTables,
        cols: usize,
        h_max: usize,
        v_max: usize,
        chroma: bool,
        mcu_cols: usize,
        restart_interval: u16,
        bands: []Band,

        fn run(ctx: *const @This(), k: usize, _: usize, _: usize) void {
            ctx.bands[k].err = null;
            ctx.encodeBand(&ctx.bands[k], k + 1 == ctx.bands.len) catch |err| {
                ctx.bands[k].err = err;
            };
        }

        fn encodeBand(ctx: *const @This(), band: *Band, last: bool) !void {
            var planes: EncodeBand = try .init(ctx.allocator, ctx.cols, ctx.h_max, ctx.v_max, ctx.chroma);
            defer planes.deinit();
            var prev_dc: [3]i32 = @splat(0);
            var mcus_in_interval: u16 = 0;
            // The marker before this band's first segment is written by the previous band.
            var rst_index: u3 = @intCast(band.seg0 % 8);
            const row0 = band.mcu0 / ctx.mcu_cols;
            const row1 = (band.mcu1 - 1) / ctx.mcu_cols + 1;
            for (row0..row1) |mcu_y| {
                ctx.source.fill(&planes, mcu_y);
                EncodeBand.transformPlane(planes.y, planes.y_stride, ctx.v_max, &ctx.tables.y_quant, planes.y_coefs);
                if (ctx.chroma) {
                    EncodeBand.transformPlane(planes.cb, planes.c_stride, 1, &ctx.tables.c_quant, planes.cb_coefs);
                    EncodeBand.transformPlane(planes.cr, planes.c_stride, 1, &ctx.tables.c_quant, planes.cr_coefs);
                }
                const row_start = mcu_y * ctx.mcu_cols;
                const x0 = @max(band.mcu0, row_start) - row_start;
                const x1 = @min(band.mcu1, row_start + ctx.mcu_cols) - row_start;
                try encodeBandScan(&band.w, &planes, ctx.tables, ctx.chroma, ctx.restart_interval, &mcus_in_interval, &rst_index, &prev_dc, x0, x1);
            }
            try band.w.reserve();
            if (last) band.w.flush() else band.w.restart(rst_index);
        }
    };

    const band_list = try allocator.alloc(Band, bands);
    defer allocator.free(band_list);
    for (band_list, 0..) |*band, k| {
        const seg0 = k * segments / bands;
        const seg1 = (k + 1) * segments / bands;
        band.* = .{
            .mcu0 = seg0 * interval,
            .mcu1 = if (k + 1 == bands) total else seg1 * interval,
            .seg0 = seg0,
            .w = .{ .gpa = allocator },
        };
    }
    defer for (band_list) |*band| band.w.deinit();

    const ctx: Ctx = .{
        .allocator = allocator,
        .source = source,
        .tables = tables,
        .cols = cols,
        .h_max = h_max,
        .v_max = v_max,
        .chroma = chroma,
        .mcu_cols = mcu_cols,
        .restart_interval = restart_interval,
        .bands = band_list,
    };
    parallel.forRowBands(io, bands, bands, &ctx, Ctx.run);
    var bytes: usize = 0;
    for (band_list) |band| {
        if (band.err) |err| return err;
        bytes += band.w.list.items.len;
    }
    try out.ensureUnusedCapacity(allocator, bytes);
    for (band_list) |band| out.appendSliceAssumeCapacity(band.w.list.items);
}

fn encodeGrayscale(io: Io, allocator: Allocator, bytes: []const u8, width: u32, height: u32, options: EncodeOptions) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    // SOI
    try out.append(allocator, 0xFF);
    try out.append(allocator, 0xD8);

    try writeAPP0_JFIF(&out, allocator, options.density_dpi);
    if (options.comment) |c| try writeCOM(&out, allocator, c);

    var ql: [64]u8 = undefined;
    var qc: [64]u8 = undefined;
    scaleQuantTables(options.quality, &ql, &qc);
    // Only luma table used
    var tmp_dqt = std.ArrayList(u8).empty;
    defer tmp_dqt.deinit(allocator);
    try tmp_dqt.append(allocator, 0x00);
    for (0..64) |i| try tmp_dqt.append(allocator, ql[zigzag[i]]);
    try writeSegment(&out, allocator, 0xFFDB, tmp_dqt.items);

    try writeSOF0(&out, allocator, @intCast(width), @intCast(height), true, .yuv444);
    try writeDHT(&out, allocator, true);
    const restart_interval = options.restart_interval.mcusFor((width + 7) / 8);
    if (restart_interval != 0) try writeDRI(&out, allocator, restart_interval);
    try writeSOS(&out, allocator, true);

    const tables = scanTables(&ql, &qc);
    try encodeScan(io, allocator, &out, .{ .gray = .{ .bytes = bytes, .cols = width, .rows = height } }, &tables, width, height, 1, 1, false, restart_interval);

    // EOI
    try out.append(allocator, 0xFF);
    try out.append(allocator, 0xD9);

    return out.toOwnedSlice(allocator);
}

// JPEG markers
pub const Marker = enum(u16) {
    // Start of Frame markers
    SOF0 = 0xFFC0, // Baseline DCT
    SOF1 = 0xFFC1, // Extended sequential DCT
    SOF2 = 0xFFC2, // Progressive DCT
    SOF3 = 0xFFC3, // Lossless (sequential)
    SOF5 = 0xFFC5, // Differential sequential (hierarchical)
    SOF6 = 0xFFC6, // Differential progressive
    SOF7 = 0xFFC7, // Differential lossless
    JPG = 0xFFC8, // Reserved
    SOF9 = 0xFFC9, // Extended sequential, arithmetic
    SOF10 = 0xFFCA, // Progressive, arithmetic
    SOF11 = 0xFFCB, // Lossless, arithmetic
    SOF13 = 0xFFCD, // Differential sequential, arithmetic
    SOF14 = 0xFFCE, // Differential progressive, arithmetic
    SOF15 = 0xFFCF, // Differential lossless, arithmetic

    // Temporary private use (standalone)
    TEM = 0xFF01,

    // Huffman table
    DHT = 0xFFC4,

    // Arithmetic coding conditioning
    DAC = 0xFFCC,

    // Restart interval markers
    RST0 = 0xFFD0,
    RST1 = 0xFFD1,
    RST2 = 0xFFD2,
    RST3 = 0xFFD3,
    RST4 = 0xFFD4,
    RST5 = 0xFFD5,
    RST6 = 0xFFD6,
    RST7 = 0xFFD7,

    // Other markers
    SOI = 0xFFD8, // Start of Image
    EOI = 0xFFD9, // End of Image
    SOS = 0xFFDA, // Start of Scan
    DQT = 0xFFDB, // Quantization Table
    DNL = 0xFFDC, // Number of Lines
    DRI = 0xFFDD, // Restart Interval
    DHP = 0xFFDE, // Hierarchical Progression
    EXP = 0xFFDF, // Expand Reference Component

    // Application segments
    APP0 = 0xFFE0, // JFIF
    APP1 = 0xFFE1, // EXIF
    APP2 = 0xFFE2,
    APP3 = 0xFFE3,
    APP4 = 0xFFE4,
    APP5 = 0xFFE5,
    APP6 = 0xFFE6,
    APP7 = 0xFFE7,
    APP8 = 0xFFE8,
    APP9 = 0xFFE9,
    APP10 = 0xFFEA,
    APP11 = 0xFFEB,
    APP12 = 0xFFEC,
    APP13 = 0xFFED,
    APP14 = 0xFFEE,
    APP15 = 0xFFEF,

    // Comment
    COM = 0xFFFE,

    pub fn fromBytes(bytes: [2]u8) ?Marker {
        const value = (@as(u16, bytes[0]) << 8) | bytes[1];
        return inline for (@typeInfo(Marker).@"enum".field_values) |field_value| {
            if (value == field_value) break @fromBackingInt(value);
        } else null;
    }
};

// Component info from SOF
const Component = struct {
    id: u8,
    h_sampling: u4,
    v_sampling: u4,
    quant_table_id: u8,
};

// Scan component info from SOS
const ScanComponent = struct {
    component_id: u8,
    /// Index into `JpegState.components`, resolved by `parseSOS`.
    component_index: u8,
    dc_table_id: u4,
    ac_table_id: u4,
};

// Scan information
const ScanInfo = struct {
    components: []ScanComponent,
    start_of_spectral_selection: u8,
    end_of_spectral_selection: u8,
    approximation_high: u4,
    approximation_low: u4,
};

// Frame type to distinguish baseline vs progressive
const FrameType = enum {
    baseline, // SOF0
    progressive, // SOF2
};

// JPEG state state
pub const JpegState = struct {
    allocator: Allocator,

    // Image properties
    header: Header,
    components: [4]Component = undefined,

    // Huffman tables (0-3 for DC, 0-3 for AC)
    dc_tables: [4]?HuffmanTable = .{ null, null, null, null },
    ac_tables: [4]?HuffmanTable = .{ null, null, null, null },

    // Quantization tables
    quant_tables: [4]?[64]u16 = .{ null, null, null, null },

    // Scan data
    scan_components: []ScanComponent = undefined,
    restart_interval: u16 = 0,

    // Bit reader for entropy-coded data
    bit_reader: BitReader = undefined,

    // Block dimensions
    block_width: u16 = 0,
    block_height: u16 = 0,
    block_width_actual: u16 = 0,
    block_height_actual: u16 = 0,

    // Block storage for all components (persistent across scans)
    /// Coefficient blocks indexed `block_row * block_width_actual + block_col`, one `[64]i16`
    /// per component (natural order, before dequantization): the whole image for progressive
    /// frames, one MCU row (`max_v` block rows) for baseline frames, which stream to the
    /// output row band by row band. Blocks past the image edge are decoded too.
    block_storage: ?[][4][64]i16 = null,

    // Separate RGB storage to avoid overwriting chroma data

    // Progressive decoding state - persistent across scans
    dc_prediction_values: [4]i32 = @splat(0),

    /// True when decoding stopped early because limits.max_scans was reached.
    scan_limit_reached: bool = false,

    // Colour-model hints, resolved by `isRgbColorModel` with libjpeg's rules.
    saw_jfif: bool = false,
    adobe_transform: ?u8 = null,

    pub fn init(allocator: Allocator) JpegState {
        return .{
            .allocator = allocator,
            .header = .{
                .width = 0,
                .height = 0,
                .frame_type = .baseline,
                .num_components = 0,
                .precision = 8,
            },
            .scan_components = &[_]ScanComponent{},
        };
    }

    /// Records the colour-model hints carried by APP0 (JFIF) and APP14 (Adobe).
    fn noteAppSegment(self: *JpegState, marker: Marker, payload: []const u8) void {
        switch (marker) {
            .APP0 => if (std.mem.startsWith(u8, payload, "JFIF\x00")) {
                self.saw_jfif = true;
            },
            .APP14 => if (payload.len >= 12 and std.mem.startsWith(u8, payload, "Adobe")) {
                self.adobe_transform = payload[11];
            },
            else => {},
        }
    }

    /// True when the three components are stored as RGB rather than YCbCr: JFIF means
    /// YCbCr, otherwise the Adobe transform flag decides, otherwise ids 'R','G','B'.
    fn isRgbColorModel(self: JpegState) bool {
        if (self.header.num_components != 3 or self.saw_jfif) return false;
        if (self.adobe_transform) |transform| return transform == 0;
        return self.components[0].id == 'R' and self.components[1].id == 'G' and self.components[2].id == 'B';
    }

    fn maxSamplingFactors(self: JpegState) struct { u4, u4 } {
        var max_h: u4 = 1;
        var max_v: u4 = 1;
        for (self.components[0..self.header.num_components]) |comp| {
            max_h = @max(max_h, comp.h_sampling);
            max_v = @max(max_v, comp.v_sampling);
        }
        return .{ max_h, max_v };
    }

    /// A single-component scan walks that component's own block grid (T.81 A.2.2). For the
    /// supported layouts that grid is the MCU grid unless the component carries the maximum
    /// sampling factors, in which case it is the full block grid.
    fn isNoninterleaved(self: JpegState, scan_components: []const ScanComponent) bool {
        if (scan_components.len != 1) return false;
        const comp = self.components[scan_components[0].component_index];
        const max_h, const max_v = self.maxSamplingFactors();
        return comp.h_sampling == max_h and comp.v_sampling == max_v;
    }

    pub fn deinit(self: *JpegState) void {
        self.allocator.free(self.scan_components);
        if (self.block_storage) |storage| {
            self.allocator.free(storage);
        }
    }

    /// Progressive-scan symbol read; reports consumption past the data as truncation.
    pub fn readCode(self: *JpegState, table: *const HuffmanTable) !u8 {
        self.bit_reader.ensure(32);
        const symbol = self.bit_reader.decodeSymbol(table) catch |err| {
            return if (self.bit_reader.overrun()) error.UnexpectedEndOfData else err;
        };
        if (self.bit_reader.overrun()) return error.UnexpectedEndOfData;
        return symbol;
    }

    // Decode magnitude-coded coefficient (T.81 section F1.2.1)
    pub fn readMagnitudeCoded(self: *JpegState, magnitude: u5) !i32 {
        self.bit_reader.ensure(32);
        const value = self.bit_reader.receiveExtend(magnitude);
        if (self.bit_reader.overrun()) return error.UnexpectedEndOfData;
        return value;
    }

    // Parse Start of Frame (SOF0/SOF2) marker
    pub fn parseSOF(self: *JpegState, data: []const u8, frame_type: FrameType, limits: DecodeLimits) !void {
        // One frame header per stream; block_storage is only set by a successful parseSOF.
        if (self.block_storage != null) return error.DuplicateSOF;
        self.header.frame_type = frame_type;
        if (data.len < 6) return error.InvalidSOF;

        const precision = data[0];
        self.header.precision = precision;
        // Provide specific error messages for different precision values
        switch (precision) {
            8 => {}, // Supported
            12 => return error.Unsupported12BitPrecision,
            16 => return error.Unsupported16BitPrecision,
            else => return error.UnsupportedPrecision,
        }

        self.header.height = (@as(u16, data[1]) << 8) | data[2];
        self.header.width = (@as(u16, data[3]) << 8) | data[4];
        self.header.num_components = data[5];

        if (self.header.width == 0 or self.header.height == 0) {
            return error.InvalidSOF;
        }

        if (exceeds(limits.max_width, self.header.width) or exceeds(limits.max_height, self.header.height)) {
            return error.ImageTooLarge;
        }

        // Distinguish between invalid and unsupported component counts
        switch (self.header.num_components) {
            1, 3 => {}, // Supported: grayscale and YCbCr
            4 => return error.UnsupportedComponentCount, // CMYK - valid but unsupported
            0 => return error.InvalidComponentCount, // Invalid: no components
            else => return error.InvalidComponentCount, // Invalid: too many components
        }

        // Parse component information
        var pos: usize = 6;
        var max_h_sampling: u4 = 0;
        var max_v_sampling: u4 = 0;

        for (0..self.header.num_components) |i| {
            if (pos + 3 > data.len) return error.InvalidSOF;

            self.components[i] = .{
                .id = data[pos],
                .h_sampling = @intCast(data[pos + 1] >> 4),
                .v_sampling = @intCast(data[pos + 1] & 0x0F),
                .quant_table_id = data[pos + 2],
            };
            const comp = self.components[i];
            if (comp.h_sampling == 0 or comp.v_sampling == 0 or comp.quant_table_id > 3) return error.InvalidSOF;

            max_h_sampling = @max(max_h_sampling, self.components[i].h_sampling);
            max_v_sampling = @max(max_v_sampling, self.components[i].v_sampling);

            pos += 3;
        }

        // Validate sampling factors
        if (max_h_sampling > 4 or max_v_sampling > 4) {
            return error.UnsupportedSamplingFactor;
        }

        // Validate specific chroma subsampling combinations
        if (self.header.num_components == 3) {
            // For color images, check if we support the chroma subsampling
            const y_h = self.components[0].h_sampling;
            const y_v = self.components[0].v_sampling;
            const cb_h = self.components[1].h_sampling;
            const cb_v = self.components[1].v_sampling;
            const cr_h = self.components[2].h_sampling;
            const cr_v = self.components[2].v_sampling;

            // Cb and Cr must have same sampling factors
            if (cb_h != cr_h or cb_v != cr_v) {
                return error.InvalidComponentCount; // Inconsistent chroma sampling
            }

            // Check for supported subsampling ratios
            const is_444 = (y_h == 1 and y_v == 1 and cb_h == 1 and cb_v == 1);
            const is_420 = (y_h == 2 and y_v == 2 and cb_h == 1 and cb_v == 1);
            const is_422 = (y_h == 2 and y_v == 1 and cb_h == 1 and cb_v == 1);
            const is_411 = (y_h == 4 and y_v == 1 and cb_h == 1 and cb_v == 1);

            if (!is_444 and !is_420 and !is_422 and !is_411) {
                return error.UnsupportedSamplingFactor;
            }
        }

        // Calculate block dimensions
        const mcu_width = 8 * @as(u32, max_h_sampling);
        const mcu_height = 8 * @as(u32, max_v_sampling);
        const width_actual = ((@as(u32, self.header.width) + mcu_width - 1) / mcu_width) * mcu_width;
        const height_actual = ((@as(u32, self.header.height) + mcu_height - 1) / mcu_height) * mcu_height;

        self.block_width = @intCast((self.header.width + 7) / 8);
        self.block_height = @intCast((self.header.height + 7) / 8);
        self.block_width_actual = @intCast((width_actual + 7) / 8);
        self.block_height_actual = @intCast((height_actual + 7) / 8);

        // Allocate block storage
        const width_actual_u64 = @as(u64, width_actual);
        const height_actual_u64 = @as(u64, height_actual);
        const total_pixels_actual = std.math.mul(u64, width_actual_u64, height_actual_u64) catch return error.ImageTooLarge;
        if (exceeds(limits.max_pixels, total_pixels_actual)) {
            return error.ImageTooLarge;
        }
        const total_blocks_u64 = total_pixels_actual / 64;
        const total_blocks = std.math.cast(usize, total_blocks_u64) orelse return error.BlockMemoryLimitExceeded;
        if (exceeds(limits.max_blocks, total_blocks)) {
            return error.BlockMemoryLimitExceeded;
        }
        // Progressive scans accumulate into the whole-image store; baseline streams one MCU row.
        _, const max_v = self.maxSamplingFactors();
        const count = if (frame_type == .progressive) total_blocks else @as(usize, self.block_width_actual) * max_v;
        self.block_storage = try self.allocator.alloc([4][64]i16, count);
        @memset(std.mem.sliceAsBytes(self.block_storage.?), 0);
    }

    // Parse Define Huffman Table (DHT) marker
    pub fn parseDHT(self: *JpegState, data: []const u8) !void {
        if (data.len == 0) return error.InvalidDHT;
        var pos: usize = 0;
        const length = data.len;

        while (pos < length) {
            if (pos + 17 > length) return error.InvalidDHT;

            const table_info = data[pos];
            const table_class = (table_info >> 4) & 1; // 0 = DC, 1 = AC
            const table_id = table_info & 0b11; // 0-3 as per JPEG standard

            if (table_id > 3) return error.InvalidHuffmanTable;

            pos += 1;

            // Read 16 bytes of bit lengths
            var bits: [16]u8 = undefined;
            @memcpy(&bits, data[pos .. pos + 16]);
            pos += 16;

            // Count total number of codes
            var total_codes: u16 = 0;
            for (bits) |count| {
                total_codes += count;
            }

            // T.81 caps a table at 256 symbols
            if (total_codes > 256) return error.InvalidHuffmanTable;
            if (pos + total_codes > length) return error.InvalidDHT;

            // Read huffman values
            var huffval: [256]u8 = undefined;
            @memcpy(huffval[0..total_codes], data[pos .. pos + total_codes]);
            pos += total_codes;

            var fast: [1 << HuffmanTable.fast_bits]u16 = @splat(0);
            var max_code: [17]i32 = @splat(-1);
            var min_code: [17]u16 = @splat(0);
            var val_ptr: [17]u16 = @splat(0);

            // Build canonical codes according to JPEG standard
            var code: u16 = 0;
            var huffval_index: usize = 0;
            for (bits, 0..) |count, i| {
                const code_len: u5 = @intCast(i + 1);
                if (count > 0) {
                    val_ptr[code_len] = @intCast(huffval_index);
                    min_code[code_len] = code;
                }
                var j: usize = 0;
                while (j < count) : (j += 1) {
                    // Check for invalid code (all 1s)
                    if (code == (@as(u17, 1) << code_len) - 1) {
                        return error.InvalidHuffmanTable;
                    }

                    const byte = huffval[huffval_index];
                    huffval_index += 1;

                    if (code_len <= HuffmanTable.fast_bits) {
                        const spare: u4 = @intCast(HuffmanTable.fast_bits - code_len);
                        const first_index = @as(usize, code) << spare;
                        const num_indexes = @as(usize, 1) << spare;
                        for (0..num_indexes) |index| {
                            std.debug.assert(fast[first_index + index] == 0);
                            fast[first_index + index] = @as(u16, code_len) << 8 | byte;
                        }
                    }

                    code += 1;
                }
                if (count > 0) max_code[code_len] = @as(i32, code) - 1;
                code <<= 1;
            }

            // Fold the magnitude bits into the lookup where code + magnitude fit the lookahead.
            var fast_ac: [1 << HuffmanTable.fast_bits]i16 = @splat(0);
            for (fast, 0..) |entry, idx| {
                if (entry == 0) continue;
                const code_len: u5 = @intCast(entry >> 8);
                const symbol: u8 = @truncate(entry);
                const run: u4 = @intCast(symbol >> 4);
                const size: u4 = @intCast(symbol & 0x0F);
                if (size == 0 or code_len + size > HuffmanTable.fast_bits) continue;
                const total: u5 = code_len + size;
                const magnitude: i32 = @intCast((idx >> (HuffmanTable.fast_bits - total)) & ((@as(usize, 1) << size) - 1));
                const value = if (magnitude < @as(i32, 1) << (size - 1)) magnitude - (@as(i32, 1) << size) + 1 else magnitude;
                if (value < -128 or value > 127) continue;
                fast_ac[idx] = @intCast(value * 256 + @as(i32, run) * 16 + total);
            }

            const table = HuffmanTable{
                .fast = fast,
                .fast_ac = fast_ac,
                .max_code = max_code,
                .min_code = min_code,
                .val_ptr = val_ptr,
                .huffval = huffval,
            };

            if (table_class == 0) {
                self.dc_tables[table_id] = table;
            } else {
                self.ac_tables[table_id] = table;
            }
        }
    }

    // Parse Define Quantization Table (DQT) marker
    pub fn parseDQT(self: *JpegState, data: []const u8) !void {
        if (data.len == 0) return error.InvalidDQT;
        var pos: usize = 0;
        const length = data.len;

        while (pos < length) {
            if (pos + 1 > length) return error.InvalidDQT;

            const table_info = data[pos];
            const precision = (table_info >> 4) & 0x0F; // 0 = 8-bit, 1 = 16-bit
            const table_id = table_info & 0b11; // Only use bottom 2 bits

            if (table_id > 3) return error.InvalidQuantTable;

            pos += 1;

            const element_size: usize = if (precision == 0) 1 else 2;
            if (pos + 64 * element_size > length) return error.InvalidDQT;

            // Read quantization table and convert from zigzag to natural order
            var table: [64]u16 = undefined;

            if (precision == 0) {
                // 8-bit values - stored in zigzag order in file, convert to natural order
                for (0..64) |i| {
                    table[zigzag[i]] = data[pos + i];
                }
                pos += 64;
            } else {
                // 16-bit values - stored in zigzag order in file, convert to natural order
                for (0..64) |i| {
                    table[zigzag[i]] = (@as(u16, data[pos + i * 2]) << 8) | data[pos + i * 2 + 1];
                }
                pos += 128;
            }

            self.quant_tables[table_id] = table;
        }
    }

    // Parse Start of Scan (SOS) marker
    pub fn parseSOS(self: *JpegState, data: []const u8) !ScanInfo {
        if (data.len < 6) return error.InvalidSOS;

        const num_components = data[0];
        // For progressive JPEG, individual scans can have fewer components
        if (self.header.frame_type == .baseline and num_components != self.header.num_components) return error.InvalidSOS;
        if (self.header.frame_type == .progressive and (num_components == 0 or num_components > self.header.num_components)) return error.InvalidSOS;

        const scan_components = try self.allocator.alloc(ScanComponent, num_components);
        errdefer self.allocator.free(scan_components);

        var pos: usize = 1;
        for (0..num_components) |i| {
            if (pos + 2 > data.len) return error.InvalidSOS;

            const id = data[pos];
            const dc_table_id = data[pos + 1] >> 4;
            const ac_table_id = data[pos + 1] & 0x0F;
            if (dc_table_id > 3 or ac_table_id > 3) return error.InvalidSOS;
            const component_index = for (self.components[0..self.header.num_components], 0..) |frame_component, ci| {
                if (frame_component.id == id) break ci;
            } else return error.InvalidSOS;
            scan_components[i] = .{
                .component_id = id,
                .component_index = @intCast(component_index),
                .dc_table_id = @intCast(dc_table_id),
                .ac_table_id = @intCast(ac_table_id),
            };

            pos += 2;
        }

        // Read spectral selection and successive approximation
        if (pos + 3 > data.len) return error.InvalidSOS;

        const start_of_spectral = data[pos];
        const end_of_spectral = data[pos + 1];
        const approximation = data[pos + 2];

        // Validate spectral selection parameters
        if (self.header.frame_type == .baseline) {
            // For baseline JPEG, these should be 0, 63, 0
            if (start_of_spectral != 0 or end_of_spectral != 63 or approximation != 0) {
                return error.InvalidSOS;
            }
        } else if (self.header.frame_type == .progressive) {
            // For progressive JPEG, validate spectral selection
            if (start_of_spectral > 63 or end_of_spectral > 63) return error.InvalidSOS;
            if (end_of_spectral < start_of_spectral) return error.InvalidSOS;

            // DC-only scans have start=0, end=0; AC-only scans have start>0
            const any_zero = start_of_spectral == 0 or end_of_spectral == 0;
            const both_zero = start_of_spectral == 0 and end_of_spectral == 0;
            if (any_zero and !both_zero) return error.InvalidSOS;
        }

        return ScanInfo{
            .components = scan_components,
            .start_of_spectral_selection = start_of_spectral,
            .end_of_spectral_selection = end_of_spectral,
            .approximation_high = @intCast((approximation >> 4) & 0x0F),
            .approximation_low = @intCast(approximation & 0x0F),
        };
    }

    // Parse Define Restart Interval (DRI) marker
    pub fn parseDRI(self: *JpegState, data: []const u8) !void {
        if (data.len != 2) return error.InvalidDRI;

        self.restart_interval = (@as(u16, data[0]) << 8) | data[1];
    }
};

// Huffman table for decoding; owns no allocations
const HuffmanTable = struct {
    /// Codes of up to `fast_bits` bits indexed by the next `fast_bits` of the stream:
    /// `length << 8 | symbol`, 0 for longer codes.
    fast: [1 << fast_bits]u16,
    /// Coefficients whose code and magnitude bits both fit in the lookahead, stb_image style:
    /// `value << 8 | run << 4 | total_length`, 0 when the slow path is needed.
    fast_ac: [1 << fast_bits]i16,
    // Canonical decode arrays per ITU T.81 F.16, indexed by code length 1-16 (index 0 unused)
    max_code: [17]i32, // -1 for lengths with no codes
    min_code: [17]u16,
    val_ptr: [17]u16,
    huffval: [256]u8,

    const fast_bits = 10;
};

/// Zigzag order extended so a run can be added to the index without a bounds check; the
/// overflow entries all land on the last coefficient.
const dezigzag = zigzag ++ @as([16]u8, @splat(63));

/// Bit reader for entropy-coded segments. Past a marker or the end of the data it feeds zero
/// bits and counts them, so decoders can run without per-bit checks and detect afterwards
/// whether they consumed anything that was not there.
pub const BitReader = struct {
    data: []const u8,
    byte_pos: usize = 0,
    /// Left-aligned: the next bit of the stream is bit 63.
    bit_buffer: u64 = 0,
    bit_count: u32 = 0,
    /// Zero bits appended after the data ran out or a marker was reached.
    pad_bits: u32 = 0,
    /// Set at a marker; `consumeRestartMarker` clears it at a restart interval boundary.
    marker_hit: bool = false,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    /// Tops the buffer up to at least 57 bits.
    fn fill(self: *BitReader) void {
        // Fast path: no stuffing or marker in the next eight bytes, so load as many as fit at once.
        if (!self.marker_hit and self.byte_pos + 8 <= self.data.len) {
            const word = std.mem.readInt(u64, self.data[self.byte_pos..][0..8], .big);
            const has_ff = (word & 0x7F7F7F7F7F7F7F7F) + 0x0101010101010101 & word & 0x8080808080808080;
            if (has_ff == 0) {
                const free = 64 - self.bit_count;
                self.bit_buffer |= word >> @intCast(self.bit_count);
                self.byte_pos += free / 8;
                self.bit_count += free / 8 * 8;
                return;
            }
        }
        while (self.bit_count <= 56) {
            if (self.marker_hit or self.byte_pos >= self.data.len) {
                self.bit_count += 8;
                self.pad_bits += 8;
                continue;
            }
            const byte = self.data[self.byte_pos];
            self.byte_pos += 1;
            if (byte == 0xFF) {
                // Stuffed 0xFF 0x00, fill bytes before a marker, or the marker itself.
                var pos = self.byte_pos;
                while (pos < self.data.len and self.data[pos] == 0xFF) pos += 1;
                if (pos < self.data.len and self.data[pos] == 0x00) {
                    self.byte_pos = pos + 1;
                } else {
                    // Leave byte_pos on the marker's last 0xFF for consumeRestartMarker.
                    self.byte_pos = if (pos < self.data.len) pos - 1 else pos;
                    self.marker_hit = true;
                    continue;
                }
            }
            self.bit_buffer |= @as(u64, byte) << @intCast(56 - self.bit_count);
            self.bit_count += 8;
        }
    }

    inline fn ensure(self: *BitReader, comptime bits: u32) void {
        if (self.bit_count < bits) self.fill();
    }

    /// The next `n` bits (1-32) without consuming them; the buffer must hold them.
    inline fn peek(self: *const BitReader, n: u6) u32 {
        std.debug.assert(n >= 1 and n <= self.bit_count);
        return @truncate(self.bit_buffer >> @intCast(@as(u7, 64) - n));
    }

    inline fn consume(self: *BitReader, n: u6) void {
        std.debug.assert(n <= self.bit_count);
        self.bit_buffer <<= n;
        self.bit_count -= n;
    }

    /// True once more bits were consumed than the data held.
    inline fn overrun(self: *const BitReader) bool {
        return self.bit_count < self.pad_bits;
    }

    /// Decodes one Huffman symbol; needs 16 buffered bits.
    inline fn decodeSymbol(self: *BitReader, table: *const HuffmanTable) !u8 {
        const entry = table.fast[self.peek(HuffmanTable.fast_bits)];
        if (entry != 0) {
            self.consume(@intCast(entry >> 8));
            return @truncate(entry);
        }
        // Canonical decode per ITU T.81 F.16 for codes longer than the lookahead.
        var length: u6 = HuffmanTable.fast_bits + 1;
        while (length <= 16) : (length += 1) {
            const code: i32 = @intCast(self.peek(length));
            if (code <= table.max_code[length]) {
                self.consume(length);
                const idx = @as(usize, table.val_ptr[length]) + @as(usize, @intCast(code)) - table.min_code[length];
                return table.huffval[idx];
            }
        }
        return error.InvalidHuffmanCode;
    }

    /// Magnitude-coded value of `size` bits (T.81 F.2.2.1), branch-free sign extension.
    inline fn receiveExtend(self: *BitReader, size: u5) i32 {
        if (size == 0) return 0;
        const bits: i32 = @intCast(self.peek(size));
        self.consume(size);
        const threshold = @as(i32, 1) << (size - 1);
        return bits + (((bits - threshold) >> 31) & ((@as(i32, -1) << size) + 1));
    }

    pub fn peekBits(self: *BitReader, num_bits: u6) u32 {
        if (num_bits == 0) return 0;
        self.ensure(32);
        return self.peek(num_bits);
    }

    pub fn getBits(self: *BitReader, n: u6) u32 {
        const bits = self.peekBits(n);
        self.consume(n);
        return bits;
    }

    /// At a restart-interval boundary: drop the buffered bits, skip to the RSTn marker and
    /// consume it. Returns false when the scan data ends first (truncated file).
    pub fn consumeRestartMarker(self: *BitReader) bool {
        self.bit_buffer = 0;
        self.bit_count = 0;
        self.pad_bits = 0;
        self.marker_hit = false;
        // Resync: tolerate stray bytes before the marker, as libjpeg does.
        while (self.byte_pos + 1 < self.data.len) : (self.byte_pos += 1) {
            if (self.data[self.byte_pos] != 0xFF) continue;
            const m = self.data[self.byte_pos + 1];
            if (m >= 0xD0 and m <= 0xD7) {
                self.byte_pos += 2;
                return true;
            }
        }
        return false;
    }
};

// Perform progressive scan
fn performProgressiveScan(state: *JpegState, scan_info: ScanInfo) !void {
    if (state.block_storage == null) return error.BlockStorageNotAllocated;

    var skips: u32 = 0;

    const max_h_factor, const max_v_factor = state.maxSamplingFactors();
    const noninterleaved = state.isNoninterleaved(scan_info.components);
    const y_step = if (noninterleaved) 1 else max_v_factor;
    const x_step = if (noninterleaved) 1 else max_h_factor;

    var mcus_since_restart: u32 = 0;
    var y: usize = 0;
    while (y < state.block_height) : (y += y_step) {
        var x: usize = 0;
        while (x < state.block_width) : (x += x_step) {
            if (state.restart_interval != 0 and mcus_since_restart == state.restart_interval) {
                mcus_since_restart = 0;
                state.dc_prediction_values = @splat(0);
                skips = 0;
                // Truncated before the marker: keep what was decoded.
                if (!state.bit_reader.consumeRestartMarker()) return;
            }
            mcus_since_restart += 1;

            for (scan_info.components) |scan_comp| {
                const component_index = scan_comp.component_index;
                const frame_component = state.components[component_index];
                const v_max: usize = if (noninterleaved) 1 else frame_component.v_sampling;
                const h_max: usize = if (noninterleaved) 1 else frame_component.h_sampling;

                for (0..v_max) |v| {
                    for (0..h_max) |h| {
                        const block_id = (y + v) * state.block_width_actual + (x + h);
                        const block = &state.block_storage.?[block_id][component_index];

                        decodeBlockProgressive(state, scan_info, scan_comp, block, &state.dc_prediction_values[component_index], &skips) catch |err| switch (err) {
                            // Truncated scan: keep the coefficients decoded so far.
                            error.UnexpectedEndOfData => return,
                            else => return err,
                        };
                        // Refinement bits read past the data are zeros; stop at the first block that needed them.
                        if (state.bit_reader.overrun()) return;
                    }
                }
            }
        }
    }
}

// Decode a single block in progressive mode
fn decodeBlockProgressive(state: *JpegState, scan_info: ScanInfo, scan_comp: ScanComponent, block: *[64]i16, dc_prediction: *i32, skips: *u32) !void {
    if (scan_info.start_of_spectral_selection == 0) {
        const dc_table = if (state.dc_tables[scan_comp.dc_table_id]) |*t| t else return error.MissingHuffmanTable;
        if (scan_info.approximation_high == 0) {
            const maybe_magnitude = try state.readCode(dc_table);
            if (maybe_magnitude > 11) return error.InvalidDCCoefficient;
            const diff = try state.readMagnitudeCoded(@intCast(maybe_magnitude));
            const dc_coefficient = diff + dc_prediction.*;
            dc_prediction.* = dc_coefficient;
            block[0] = @truncate(dc_coefficient << @intCast(scan_info.approximation_low));
        } else if (scan_info.approximation_high != 0) {
            const bit: u32 = state.bit_reader.getBits(1);
            block[0] +%= @as(i16, @intCast(bit)) << @intCast(scan_info.approximation_low);
        }
    } else if (scan_info.start_of_spectral_selection != 0) {
        const ac_table = if (state.ac_tables[scan_comp.ac_table_id]) |*t| t else return error.MissingHuffmanTable;
        if (scan_info.approximation_high == 0) {
            var ac: usize = scan_info.start_of_spectral_selection;
            // Check skips == 0 first
            if (skips.* == 0) {
                while (ac <= scan_info.end_of_spectral_selection and ac < 64) {
                    var coeff: i32 = 0;
                    const zero_run_length_and_magnitude = try state.readCode(ac_table);
                    const zero_run_length = zero_run_length_and_magnitude >> 4;
                    const maybe_magnitude = zero_run_length_and_magnitude & 0x0F;

                    if (maybe_magnitude == 0) {
                        if (zero_run_length < 15) {
                            const extra_skips: u32 = state.bit_reader.getBits(@intCast(zero_run_length));
                            skips.* = (@as(u32, 1) << @intCast(zero_run_length));
                            skips.* += extra_skips;
                            break; // process skips
                        } // no special case for zrl == 15
                    } else if (maybe_magnitude != 0) {
                        if (maybe_magnitude > 10) return error.InvalidACCoefficient;
                        coeff = try state.readMagnitudeCoded(@intCast(maybe_magnitude));
                    }

                    for (0..zero_run_length) |_| {
                        if (ac >= 64) break;
                        block[zigzag[ac]] = 0;
                        ac += 1;
                    }
                    if (ac >= 64) break;
                    block[zigzag[ac]] = @truncate(coeff << @intCast(scan_info.approximation_low));
                    ac += 1;
                }
            }

            if (skips.* > 0) {
                skips.* -= 1;
                while (ac <= scan_info.end_of_spectral_selection and ac < 64) {
                    block[zigzag[ac]] = 0;
                    ac += 1;
                }
            }
        } else if (scan_info.approximation_high != 0) {
            const bit: i16 = @as(i16, 1) << @intCast(scan_info.approximation_low);
            var ac: usize = scan_info.start_of_spectral_selection;
            if (skips.* == 0) {
                while (ac <= scan_info.end_of_spectral_selection and ac < 64) {
                    var coeff: i16 = 0;
                    const zero_run_length_and_magnitude = try state.readCode(ac_table);
                    var zero_run_length = zero_run_length_and_magnitude >> 4;
                    const maybe_magnitude = zero_run_length_and_magnitude & 0x0F;

                    if (maybe_magnitude == 0) {
                        if (zero_run_length < 15) {
                            skips.* = (@as(u32, 1) << @intCast(zero_run_length));
                            const extra_skips: u32 = state.bit_reader.getBits(@intCast(zero_run_length));
                            skips.* += extra_skips;
                            break; // start processing skips
                        } // no special treatment for zero_run_length == 15
                    } else if (maybe_magnitude != 0) {
                        const sign_bit: u32 = state.bit_reader.getBits(1);
                        coeff = if (sign_bit == 1) bit else -bit;
                    }

                    // Process zero run and place coefficient
                    while (ac <= scan_info.end_of_spectral_selection and ac < 64) {
                        if (block[zigzag[ac]] == 0) {
                            if (zero_run_length > 0) {
                                zero_run_length -= 1;
                                ac += 1;
                            } else {
                                block[zigzag[ac]] = coeff;
                                ac += 1;
                                break;
                            }
                        } else {
                            const sign_bit: u32 = state.bit_reader.getBits(1);
                            if (sign_bit != 0) {
                                block[zigzag[ac]] +%= if (block[zigzag[ac]] > 0) bit else -bit;
                            }
                            ac += 1;
                        }
                    }
                }
            }

            // Process skips
            if (skips.* > 0) {
                while (ac <= scan_info.end_of_spectral_selection and ac < 64) : (ac += 1) {
                    if (block[zigzag[ac]] != 0) {
                        const sign_bit: u32 = state.bit_reader.getBits(1);
                        if (sign_bit != 0) {
                            block[zigzag[ac]] +%= if (block[zigzag[ac]] > 0) bit else -bit;
                        }
                    }
                }
                skips.* -= 1;
            }
        }
    }
}

/// Decodes one baseline block into `block` (natural order). A block that consumed bits past
/// the data reports `UnexpectedEndOfData`, whatever the padding decoded as.
/// Every symbol plus its magnitude needs at most 27 bits, so one top-up per coefficient
/// keeps the lookups check-free.
fn decodeBlockBits(br: *BitReader, dc_table: *const HuffmanTable, ac_table: *const HuffmanTable, block: *[64]i16, dc_prediction: *i32) !void {
    br.ensure(27);
    const dc_entry = dc_table.fast_ac[br.peek(HuffmanTable.fast_bits)];
    var diff: i32 = undefined;
    if (dc_entry != 0 and dc_entry & 0xF0 == 0) {
        br.consume(@intCast(dc_entry & 15));
        diff = dc_entry >> 8;
    } else {
        const symbol = try br.decodeSymbol(dc_table);
        if (symbol > 11) return error.InvalidDCCoefficient;
        diff = br.receiveExtend(@intCast(symbol));
    }
    dc_prediction.* += diff;
    block[0] = @truncate(dc_prediction.*);

    var k: usize = 1;
    while (k < 64) {
        br.ensure(27);
        const entry = ac_table.fast_ac[br.peek(HuffmanTable.fast_bits)];
        if (entry != 0) {
            br.consume(@intCast(entry & 15));
            k += @intCast((entry >> 4) & 15);
            block[dezigzag[k]] = entry >> 8;
            k += 1;
            continue;
        }
        const symbol = try br.decodeSymbol(ac_table);
        const run = symbol >> 4;
        const size: u4 = @intCast(symbol & 0x0F);
        if (size == 0) {
            if (symbol == 0) return; // EOB: the block is pre-zeroed
            if (run != 15) return error.InvalidACCoefficient;
            k += 16;
            continue;
        }
        k += run;
        block[dezigzag[k]] = @intCast(br.receiveExtend(size));
        k += 1;
    }
}

// Parse JPEG file and decode image
// Helper function to find the end of entropy-coded scan data
fn findScanEnd(data: []const u8, start_pos: usize) usize {
    if (data.len == 0) return 0;
    var pos = start_pos;
    // Only 0xFF can start a marker; stuffed zeros and RSTn stay inside the scan.
    while (pos < data.len - 1) {
        const ff = std.mem.indexOfScalarPos(u8, data, pos, 0xFF) orelse break;
        if (ff >= data.len - 1) return ff;
        const next = data[ff + 1];
        if (next == 0x00 or (next >= 0xD0 and next <= 0xD7)) {
            pos = ff + 2;
            continue;
        }
        return ff;
    }
    return @max(start_pos, data.len - 1);
}

// Helper function to read marker length from data
fn readMarkerLength(data: []const u8, pos: usize) !u16 {
    if (pos + 2 > data.len) return error.UnexpectedEndOfData;
    return (@as(u16, data[pos]) << 8) | data[pos + 1];
}

// Helper function to process a Start of Scan marker
fn processScanMarker(state: *JpegState, data: []const u8, pos: usize) !usize {
    const header_len = try readMarkerLength(data, pos + 2);
    if (header_len < 2) return error.InvalidMarker;
    const marker_end = pos + 2 + header_len;
    if (marker_end > data.len) return error.InvalidMarker;

    const payload_start = pos + 4;
    if (payload_start > marker_end) return error.InvalidMarker;
    const scan_info = try state.parseSOS(data[payload_start..marker_end]);
    const scan_start = marker_end;

    const scan_end = findScanEnd(data, scan_start);
    state.bit_reader = BitReader.init(data[scan_start..scan_end]);

    // Baseline: the single scan is decoded by performBlockScan after the marker loop
    if (state.header.frame_type == .baseline) {
        // Track allocated components for baseline
        state.scan_components = scan_info.components;
        return scan_end; // Signal that baseline processing is complete
    }

    // For progressive JPEG, perform the scan
    performProgressiveScan(state, scan_info) catch |err| {
        // Free scan components before propagating error
        state.allocator.free(scan_info.components);
        return err;
    };

    // Free scan components for progressive (don't store in state)
    state.allocator.free(scan_info.components);
    return scan_end;
}

fn readMarkerPayload(data: []const u8, pos: *usize, total_marker_bytes: *usize, limits: DecodeLimits) ![]const u8 {
    const length = try readMarkerLength(data, pos.* + 2);
    if (length < 2) return error.InvalidMarker;
    const marker_end = pos.* + 2 + length;
    if (marker_end > data.len) return error.InvalidMarker;
    try accumulateWithLimit(total_marker_bytes, length, limits.max_marker_bytes, error.MarkerDataLimitExceeded);

    const payload_start = pos.* + 4;
    if (payload_start > marker_end) return error.InvalidMarker;

    const payload = data[payload_start..marker_end];
    pos.* = marker_end;
    return payload;
}

pub fn decode(allocator: Allocator, data: []const u8, limits: DecodeLimits) !JpegState {
    var state = JpegState.init(allocator);
    errdefer state.deinit();

    // Check for JPEG SOI marker
    if (data.len < 2 or !std.mem.eql(u8, data[0..2], &signature)) {
        return error.InvalidJpegFile;
    }
    if (exceeds(limits.max_jpeg_bytes, data.len)) {
        return error.JpegDataTooLarge;
    }

    var pos: usize = 2;
    var total_marker_bytes: usize = 0;
    var scan_count: usize = 0;

    // Parse JPEG markers
    while (pos < data.len - 1) {
        if (data[pos] != 0xFF) {
            return error.InvalidMarker;
        }

        const marker_bytes = [2]u8{ data[pos], data[pos + 1] };
        const marker = Marker.fromBytes(marker_bytes) orelse {
            // 0xFF fill bytes may precede a marker
            if (marker_bytes[1] == 0xFF) {
                pos += 1;
                continue;
            }
            // Skip unknown (reserved) markers, which carry a length
            pos += 2;
            if (pos + 2 > data.len) break;
            const length = try readMarkerLength(data, pos);
            if (length < 2) return error.InvalidMarker;
            pos += length;
            continue;
        };

        switch (marker) {
            .SOI => {
                pos += 2;
                continue;
            },
            .EOI => break,

            .SOF0, .SOF2 => {
                const frame_type: FrameType = if (marker == .SOF0) .baseline else .progressive;
                const payload = try readMarkerPayload(data, &pos, &total_marker_bytes, limits);
                try state.parseSOF(payload, frame_type, limits);
            },

            .SOF1 => return error.UnsupportedExtendedSequential,
            .SOF3 => return error.UnsupportedLosslessJpeg,
            .SOF9, .SOF10, .SOF11, .SOF13, .SOF14, .SOF15, .DAC => return error.UnsupportedArithmeticCoding,
            .SOF5, .SOF6, .SOF7, .DHP => return error.UnsupportedHierarchicalJpeg,
            .JPG => return error.UnsupportedJpegVariant,

            // Standalone markers carry no length
            .TEM, .RST0, .RST1, .RST2, .RST3, .RST4, .RST5, .RST6, .RST7 => pos += 2,

            .DHT => {
                const payload = try readMarkerPayload(data, &pos, &total_marker_bytes, limits);
                try state.parseDHT(payload);
            },

            .DQT => {
                const payload = try readMarkerPayload(data, &pos, &total_marker_bytes, limits);
                try state.parseDQT(payload);
            },

            .SOS => {
                if (exceeds(limits.max_scans, scan_count + 1)) {
                    // Scan cap: keep what was decoded and ignore the rest of the stream.
                    state.scan_limit_reached = true;
                    break;
                }
                scan_count += 1;
                const scan_end = try processScanMarker(&state, data, pos);
                const scan_consumed = scan_end - pos;
                try accumulateWithLimit(&total_marker_bytes, scan_consumed, limits.max_marker_bytes, error.MarkerDataLimitExceeded);
                // For baseline JPEG, return immediately after first scan
                if (state.header.frame_type == .baseline) {
                    return state;
                }
                // For progressive JPEG, continue parsing more scans
                pos = scan_end;
            },

            .DRI => {
                const payload = try readMarkerPayload(data, &pos, &total_marker_bytes, limits);
                try state.parseDRI(payload);
            },

            .DNL => return error.UnsupportedJpegVariant,

            .APP0, .APP1, .APP2, .APP3, .APP4, .APP5, .APP6, .APP7, .APP8, .APP9, .APP10, .APP11, .APP12, .APP13, .APP14, .APP15, .COM => {
                // Skip application and comment markers, noting the colour-model hints
                if (pos + 4 > data.len) break;
                const length = try readMarkerLength(data, pos + 2);
                try accumulateWithLimit(&total_marker_bytes, length, limits.max_marker_bytes, error.MarkerDataLimitExceeded);
                if (length >= 2 and pos + 2 + length <= data.len) state.noteAppSegment(marker, data[pos + 4 .. pos + 2 + length]);
                pos += 2 + length;
            },

            .EXP => {
                if (pos + 4 > data.len) break;
                const length = try readMarkerLength(data, pos + 2);
                try accumulateWithLimit(&total_marker_bytes, length, limits.max_marker_bytes, error.MarkerDataLimitExceeded);
                pos += 2 + length;
            },
        }
    }

    // For progressive JPEG that finished all scans
    if (state.header.frame_type == .progressive) {
        return state;
    }

    return error.NoScanData;
}

/// 16-lane building blocks shared by the forward and inverse DCT: two 8x8 blocks travel side
/// by side (lanes 0-7 block A, 8-15 block B) and every 16-bit interleave stays within its
/// 128-bit lane, so the pair transposes as two independent tiles.
const Dct = struct {
    const V16 = @Vector(16, i16);
    const V8 = @Vector(8, i32);

    /// Alternating constants for the paired multiply-add.
    fn pair(comptime a: i16, comptime b: i16) V16 {
        var v: [16]i16 = undefined;
        for (0..8) |i| {
            v[2 * i] = a;
            v[2 * i + 1] = b;
        }
        return v;
    }

    const lo16 = [16]i32{ 0, -1, 1, -2, 2, -3, 3, -4, 8, -9, 9, -10, 10, -11, 11, -12 };
    const hi16 = [16]i32{ 4, -5, 5, -6, 6, -7, 7, -8, 12, -13, 13, -14, 14, -15, 15, -16 };
    const even = [8]i32{ 0, 2, 4, 6, 8, 10, 12, 14 };
    const odd = [8]i32{ 1, 3, 5, 7, 9, 11, 13, 15 };
    const low_half = [8]i32{ 0, 1, 2, 3, 8, 9, 10, 11 };
    const high_half = [8]i32{ 4, 5, 6, 7, 12, 13, 14, 15 };
    const pack_mask = [16]i32{ 0, 1, 2, 3, -1, -2, -3, -4, 4, 5, 6, 7, -5, -6, -7, -8 };
    const concat = [16]i32{ 0, 1, 2, 3, 4, 5, 6, 7, -1, -2, -3, -4, -5, -6, -7, -8 };
    const dup8 = [16]i32{ 0, 1, 2, 3, 4, 5, 6, 7, 0, 1, 2, 3, 4, 5, 6, 7 };

    inline fn unpacklo(a: V16, b: V16) V16 {
        return @shuffle(i16, a, b, lo16);
    }
    inline fn unpackhi(a: V16, b: V16) V16 {
        return @shuffle(i16, a, b, hi16);
    }
    /// `x[2i] * c[2i] + x[2i+1] * c[2i+1]` as i32 (pmaddwd).
    inline fn madd(x: V16, c: V16) V8 {
        const xe: V8 = @intCast(@shuffle(i16, x, undefined, even));
        const xo: V8 = @intCast(@shuffle(i16, x, undefined, odd));
        const ce: V8 = @intCast(@shuffle(i16, c, undefined, even));
        const co: V8 = @intCast(@shuffle(i16, c, undefined, odd));
        return xe * ce + xo * co;
    }
    /// Saturating pack of two halves (elements 0-3, 8-11 in `l`, the rest in `h`) into
    /// element order.
    inline fn packs(l: V8, h: V8) V16 {
        const wide = @shuffle(i32, l, h, pack_mask);
        return @intCast(std.math.clamp(wide, @as(@Vector(16, i32), @splat(-32768)), @as(@Vector(16, i32), @splat(32767))));
    }
    /// Transposes both 8x8 tiles in place.
    inline fn transpose(r: *[8]V16) void {
        inline for ([_][2]usize{ .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 }, .{ 0, 2 }, .{ 1, 3 }, .{ 4, 6 }, .{ 5, 7 }, .{ 0, 1 }, .{ 2, 3 }, .{ 4, 5 }, .{ 6, 7 } }) |p| {
            const a = r[p[0]];
            r[p[0]] = unpacklo(a, r[p[1]]);
            r[p[1]] = unpackhi(a, r[p[1]]);
        }
    }
};

/// Inverse DCT: the stb_image SSE2 formulation of the libjpeg "islow" transform on block
/// pairs. Bit-exact with the 32-bit scalar transform.
const Idct = struct {
    const V16 = Dct.V16;
    const V8 = Dct.V8;
    const pair = Dct.pair;
    const unpacklo = Dct.unpacklo;
    const unpackhi = Dct.unpackhi;
    const madd = Dct.madd;
    const packs = Dct.packs;
    const transpose = Dct.transpose;
    const concat = Dct.concat;

    fn f2f(comptime x: f32) i16 {
        return @intFromFloat(@round(x * 4096));
    }
    const rot0_0 = pair(f2f(0.5411961), f2f(0.5411961) + f2f(-1.847759065));
    const rot0_1 = pair(f2f(0.5411961) + f2f(0.765366865), f2f(0.5411961));
    const rot1_0 = pair(f2f(1.175875602) + f2f(-0.899976223), f2f(1.175875602));
    const rot1_1 = pair(f2f(1.175875602), f2f(1.175875602) + f2f(-2.562915447));
    const rot2_0 = pair(f2f(-1.961570560) + f2f(0.298631336), f2f(-1.961570560));
    const rot2_1 = pair(f2f(-1.961570560), f2f(-1.961570560) + f2f(3.072711026));
    const rot3_0 = pair(f2f(-0.390180644) + f2f(2.053119869), f2f(-0.390180644));
    const rot3_1 = pair(f2f(-0.390180644), f2f(-0.390180644) + f2f(1.501321110));

    /// 32-bit intermediates: `l` holds elements 0-3 and 8-11, `h` the rest, the unpack order.
    const Wide = struct { l: V8, h: V8 };
    inline fn rot(x: V16, y: V16, c0: V16, c1: V16) struct { Wide, Wide } {
        const lo = unpacklo(x, y);
        const hi = unpackhi(x, y);
        return .{ .{ .l = madd(lo, c0), .h = madd(hi, c0) }, .{ .l = madd(lo, c1), .h = madd(hi, c1) } };
    }
    inline fn widen(x: V16) Wide {
        const l: V8 = @intCast(@shuffle(i16, x, undefined, Dct.low_half));
        const h: V8 = @intCast(@shuffle(i16, x, undefined, Dct.high_half));
        return .{ .l = l << @splat(12), .h = h << @splat(12) };
    }
    inline fn wadd(a: Wide, b: Wide) Wide {
        return .{ .l = a.l + b.l, .h = a.h + b.h };
    }
    inline fn wsub(a: Wide, b: Wide) Wide {
        return .{ .l = a.l - b.l, .h = a.h - b.h };
    }
    inline fn bfly(a: Wide, b: Wide, comptime bias: i32, comptime shift: u5) struct { V16, V16 } {
        const ab: Wide = .{ .l = a.l + @as(V8, @splat(bias)), .h = a.h + @as(V8, @splat(bias)) };
        const sum = wadd(ab, b);
        const dif = wsub(ab, b);
        return .{ packs(sum.l >> @splat(shift), sum.h >> @splat(shift)), packs(dif.l >> @splat(shift), dif.h >> @splat(shift)) };
    }

    /// One 1-D pass over the eight vectors, with libjpeg's even/odd butterflies.
    inline fn pass(r: *[8]V16, comptime bias: i32, comptime shift: u5) void {
        const t2e, const t3e = rot(r[2], r[6], rot0_0, rot0_1);
        const t0e = widen(r[0] +| r[4]);
        const t1e = widen(r[0] -| r[4]);
        const x0 = wadd(t0e, t3e);
        const x3 = wsub(t0e, t3e);
        const x1 = wadd(t1e, t2e);
        const x2 = wsub(t1e, t2e);
        const y0o, const y2o = rot(r[7], r[3], rot2_0, rot2_1);
        const y1o, const y3o = rot(r[5], r[1], rot3_0, rot3_1);
        const y4o, const y5o = rot(r[1] +| r[7], r[3] +| r[5], rot1_0, rot1_1);
        const x4 = wadd(y0o, y4o);
        const x5 = wadd(y1o, y5o);
        const x6 = wadd(y2o, y5o);
        const x7 = wadd(y3o, y4o);
        r[0], r[7] = bfly(x0, x7, bias, shift);
        r[1], r[6] = bfly(x1, x6, bias, shift);
        r[2], r[5] = bfly(x2, x5, bias, shift);
        r[3], r[4] = bfly(x3, x4, bias, shift);
    }

    /// Dequantizes and inverse-transforms blocks `a` and `b` (the same component) into
    /// level-shifted samples at `dst`, block A's rows at columns 0-7 and B's at 8-15; with
    /// `single` only A is stored. Both blocks pass through the transform, so a DC-only block
    /// next to a full one comes out exactly as the shortcut would produce.
    fn pairInto(a: *const [64]i16, b: *const [64]i16, dequant: *const [64]i16, dst: [*]u8, stride: usize, single: bool) void {
        var r: [8]V16 = undefined;
        for (0..8) |i| {
            const q: @Vector(8, i16) = dequant[i * 8 ..][0..8].*;
            const scale = @shuffle(i16, q, q, concat);
            r[i] = @shuffle(i16, @as(@Vector(8, i16), a[i * 8 ..][0..8].*), @as(@Vector(8, i16), b[i * 8 ..][0..8].*), concat) *% scale;
        }
        var ac = r[0] & @as(V16, [_]i16{ 0, -1, -1, -1, -1, -1, -1, -1, 0, -1, -1, -1, -1, -1, -1, -1 });
        inline for (1..8) |i| ac |= r[i];
        if (@reduce(.Or, ac) == 0) {
            // DC only: (dc + 4) >> 3 + 128 for every sample, exactly the two-pass result.
            const dc = std.math.clamp(((r[0] + @as(V16, @splat(4))) >> @splat(3)) + @as(V16, @splat(128)), @as(V16, @splat(0)), @as(V16, @splat(255)));
            const bytes: [16]u8 = meta.narrowToBytes(@shuffle(i16, dc, undefined, [16]i32{ 0, 0, 0, 0, 0, 0, 0, 0, 8, 8, 8, 8, 8, 8, 8, 8 }));
            for (0..8) |i| {
                if (single) dst[i * stride ..][0..8].* = bytes[0..8].* else dst[i * stride ..][0..16].* = bytes;
            }
            return;
        }
        pass(&r, 512, 10);
        transpose(&r);
        pass(&r, 65536 + (128 << 17), 17);
        transpose(&r);
        for (0..8) |i| {
            const bytes: [16]u8 = meta.narrowToBytes(std.math.clamp(r[i], @as(V16, @splat(0)), @as(V16, @splat(255))));
            if (single) dst[i * stride ..][0..8].* = bytes[0..8].* else dst[i * stride ..][0..16].* = bytes;
        }
    }
};

// Decode the baseline scan into block storage
/// Baseline scan geometry shared by the serial and banded drivers.
const ScanLayout = struct {
    noninterleaved: bool,
    x_step: usize,
    y_step: usize,
    /// MCUs per MCU row and MCU rows in the image.
    mcus_per_row: usize,
    mcu_rows: usize,

    fn init(state: *const JpegState) ScanLayout {
        const max_h, const max_v = state.maxSamplingFactors();
        const noninterleaved = state.isNoninterleaved(state.scan_components);
        const x_step: usize = if (noninterleaved) 1 else max_h;
        const y_step: usize = if (noninterleaved) 1 else max_v;
        return .{
            .noninterleaved = noninterleaved,
            .x_step = x_step,
            .y_step = y_step,
            .mcus_per_row = (@as(usize, state.block_width) + x_step - 1) / x_step,
            .mcu_rows = (@as(usize, state.block_height) + y_step - 1) / y_step,
        };
    }
};

/// One MCU at block column `x` of a one-MCU-row block store; `blocks` may be null to
/// decode and discard. Truncation surfaces as `error.UnexpectedEndOfData`.
inline fn decodeMcu(state: *const JpegState, layout: ScanLayout, br: *BitReader, blocks: ?[][4][64]i16, x: usize, prediction: *[4]i32) !void {
    const bw: usize = state.block_width_actual;
    var scratch: [64]i16 = undefined;
    for (state.scan_components) |scan_comp| {
        const ci = scan_comp.component_index;
        const dc_table = if (state.dc_tables[scan_comp.dc_table_id]) |*t| t else return error.MissingHuffmanTable;
        const ac_table = if (state.ac_tables[scan_comp.ac_table_id]) |*t| t else return error.MissingHuffmanTable;
        const comp = state.components[ci];
        const v_max: usize = if (layout.noninterleaved) 1 else comp.v_sampling;
        const h_max: usize = if (layout.noninterleaved) 1 else comp.h_sampling;
        for (0..v_max) |v| {
            for (0..h_max) |h| {
                const block = if (blocks) |b| &b[v * bw + x + h][ci] else &scratch;
                @memset(block, 0);
                decodeBlockBits(br, dc_table, ac_table, block, &prediction[ci]) catch |err| {
                    return if (br.overrun()) error.UnexpectedEndOfData else err;
                };
                if (br.overrun()) return error.UnexpectedEndOfData;
            }
        }
    }
}

/// Entropy decoder position within a baseline scan: the reader plus the DC predictors and
/// the MCU count since the last restart marker. When the data of a restart segment runs
/// out, the rest of that segment is zero and decoding resumes at the next marker; without
/// markers (or once they are exhausted) everything after the failure is zero.
const McuCursor = struct {
    br: BitReader,
    prediction: [4]i32 = @splat(0),
    since_restart: u32 = 0,
    /// MCUs still to emit as zeros before the next marker resumes decoding.
    lost: u32 = 0,
    /// No data or markers left: every remaining MCU is zero.
    dead: bool = false,

    /// Whether the next MCU decoded or is zero; `blocks` may be null to discard it.
    fn next(self: *McuCursor, state: *const JpegState, layout: ScanLayout, blocks: ?[][4][64]i16, x: usize) !enum { decoded, zero } {
        const interval = state.restart_interval;
        if (interval != 0 and self.since_restart == interval) {
            self.prediction = @splat(0);
            self.since_restart = 0;
            self.lost = 0;
            if (!self.dead and !self.br.consumeRestartMarker()) self.dead = true;
        }
        self.since_restart += 1;
        if (self.dead or self.lost > 0) {
            self.lost -|= 1;
            if (blocks) |b| zeroMcu(state, layout, b, x);
            return .zero;
        }
        decodeMcu(state, layout, &self.br, blocks, x, &self.prediction) catch |err| switch (err) {
            error.UnexpectedEndOfData => {
                if (interval == 0) self.dead = true else self.lost = interval - self.since_restart;
                if (blocks) |b| zeroMcu(state, layout, b, x);
                return .zero;
            },
            else => return err,
        };
        return .decoded;
    }
};

/// Zeroes the blocks of the MCU at block column `x` (partially written on a failed decode).
fn zeroMcu(state: *const JpegState, layout: ScanLayout, blocks: [][4][64]i16, x: usize) void {
    const bw: usize = state.block_width_actual;
    for (0..layout.y_step) |v| {
        for (x..@min(x + layout.x_step, bw)) |bx| {
            for (&blocks[v * bw + bx]) |*block| @memset(block, 0);
        }
    }
}

/// Decodes MCU row `row` into `blocks` (one MCU row of blocks) and renders it.
fn decodeRenderMcuRow(comptime T: type, state: *const JpegState, layout: ScanLayout, cursor: *McuCursor, render: *RenderBand, blocks: [][4][64]i16, row: usize, img: *Image(T)) !void {
    var x: usize = 0;
    while (x < state.block_width) : (x += layout.x_step) {
        _ = try cursor.next(state, layout, blocks, x);
    }
    const y = row * layout.y_step;
    try renderBlockRows(T, state, render, blocks, y, @min(layout.y_step, state.block_height - y), img);
}

/// Baseline scan, one MCU row at a time: decode into the band store, render, repeat.
fn performBlockScan(comptime T: type, state: *JpegState, band: *RenderBand, img: *Image(T)) !void {
    const blocks = state.block_storage orelse return error.BlockStorageNotAllocated;
    const layout: ScanLayout = .init(state);
    // The reader lives in a local for the whole scan so the hot loop keeps it in registers.
    var cursor: McuCursor = .{ .br = state.bit_reader };
    defer state.bit_reader = cursor.br;
    for (0..layout.mcu_rows) |row| {
        try decodeRenderMcuRow(T, state, layout, &cursor, band, blocks, row, img);
    }
}

/// Byte offsets into the entropy data at which restart segments begin: `starts[k]` is the
/// first byte after the k-th RSTn marker (`starts[0] = 0`), so segment k holds MCUs
/// `[k * interval, (k + 1) * interval)`.
fn restartSegments(allocator: Allocator, data: []const u8) ![]usize {
    var starts: std.ArrayList(usize) = .empty;
    errdefer starts.deinit(allocator);
    try starts.append(allocator, 0);
    var pos: usize = 0;
    while (pos + 1 < data.len) {
        const ff = std.mem.indexOfScalarPos(u8, data, pos, 0xFF) orelse break;
        if (ff + 1 >= data.len) break;
        const m = data[ff + 1];
        if (m >= 0xD0 and m <= 0xD7) try starts.append(allocator, ff + 2);
        pos = ff + 1;
    }
    return starts.toOwnedSlice(allocator);
}

/// Baseline scan with restart intervals on `io`: bands own balanced runs of MCU rows, each
/// starting its entropy decoder at the restart segment holding its first MCU (discarding
/// the segment's earlier MCUs, under one MCU row) and rendering through its own scratch.
/// Every band re-derives the same DC predictors and restart cadence as a single sweep, so
/// the output is identical.
fn performBlockScanBanded(comptime T: type, io: Io, state: *JpegState, img: *Image(T), starts: []const usize, bands: usize) !void {
    const layout: ScanLayout = .init(state);
    const allocator = state.allocator;
    const interval: usize = state.restart_interval;
    const bw: usize = state.block_width_actual;

    const Band = struct {
        row0: usize,
        row1: usize,
        render: RenderBand,
        blocks: [][4][64]i16,
        err: ?anyerror = null,
    };
    const Ctx = struct {
        state: *const JpegState,
        layout: ScanLayout,
        img: *Image(T),
        starts: []const usize,
        bands: []Band,

        fn run(ctx: *const @This(), k: usize, _: usize, _: usize) void {
            const band = &ctx.bands[k];
            band.err = null;
            ctx.decodeBand(band) catch |err| {
                band.err = err;
            };
        }

        fn decodeBand(ctx: *const @This(), band: *Band) !void {
            const st = ctx.state;
            const lay = ctx.layout;
            const first_mcu = band.row0 * lay.mcus_per_row;
            const seg = first_mcu / st.restart_interval;
            // Past the last marker everything is zero, as in the single sweep.
            const has_data = seg < ctx.starts.len;
            var cursor: McuCursor = .{ .br = .init(st.bit_reader.data[if (has_data) ctx.starts[seg] else 0..]), .dead = !has_data };
            var mcu = seg * st.restart_interval;
            var x = (mcu % lay.mcus_per_row) * lay.x_step;
            while (mcu < first_mcu) : (mcu += 1) {
                _ = try cursor.next(st, lay, null, x);
                x = if ((mcu + 1) % lay.mcus_per_row == 0) 0 else x + lay.x_step;
            }
            for (band.row0..band.row1) |row| {
                try decodeRenderMcuRow(T, st, lay, &cursor, &band.render, band.blocks, row, ctx.img);
            }
        }
    };

    const band_list = try allocator.alloc(Band, bands);
    defer allocator.free(band_list);
    var made: usize = 0;
    defer for (band_list[0..made]) |*band| {
        band.render.deinit();
        allocator.free(band.blocks);
    };
    // Balance by restart segments; each band owns whole MCU rows from the first row at or after its first segment.
    const segments = (layout.mcu_rows * layout.mcus_per_row + interval - 1) / interval;
    for (band_list, 0..) |*band, k| {
        const seg0 = k * segments / bands;
        const seg1 = (k + 1) * segments / bands;
        const row0 = @min(layout.mcu_rows, (seg0 * interval + layout.mcus_per_row - 1) / layout.mcus_per_row);
        const row1 = if (k + 1 == bands) layout.mcu_rows else @min(layout.mcu_rows, (seg1 * interval + layout.mcus_per_row - 1) / layout.mcus_per_row);
        band.* = .{
            .row0 = row0,
            .row1 = row1,
            .render = try .init(allocator, state),
            .blocks = undefined,
        };
        made = k + 1;
        band.blocks = try allocator.alloc([4][64]i16, bw * layout.y_step);
    }

    const ctx: Ctx = .{ .state = state, .layout = layout, .img = img, .starts = starts, .bands = band_list };
    parallel.forRowBands(io, bands, bands, &ctx, Ctx.run);
    for (band_list) |band| if (band.err) |err| return err;
}

/// Sample planes for one MCU row plus the chroma upsampling scratch, reused for every band.
/// Rows carry `lanes` bytes of slack so the vector passes never read past an allocation.
const RenderBand = struct {
    allocator: Allocator,
    planes: [4][]u8,
    strides: [4]usize,
    /// Vertically blended chroma row at chroma resolution as `sample * 256`, with one
    /// replicated sample on each side so the horizontal taps clamp at the edges.
    vrow: []i32,
    /// Upsampled chroma rows at luma resolution.
    crows: [2][]u8,
    /// Converted row for output types other than `Rgb`.
    rgb_row: []Rgb,
    /// Each component's quantization table as `i16` for the fused dequantize-and-transform.
    dequant: [4][64]i16,

    const lanes = 16;
    const V = @Vector(lanes, i32);
    const B = @Vector(lanes, u8);

    fn init(allocator: Allocator, state: *const JpegState) !RenderBand {
        const nc: usize = state.header.num_components;
        const max_h, _ = state.maxSamplingFactors();
        const mcus_x = @as(usize, state.block_width_actual) / max_h;
        const padded = @as(usize, state.block_width_actual) * 8 + lanes;
        var self: RenderBand = .{
            .allocator = allocator,
            .planes = @splat(&.{}),
            .strides = @splat(0),
            .vrow = &.{},
            .crows = .{ &.{}, &.{} },
            .rgb_row = &.{},
            .dequant = undefined,
        };
        errdefer self.deinit();
        for (0..nc) |c| {
            const comp = state.components[c];
            const quant_table = state.quant_tables[comp.quant_table_id] orelse return error.MissingQuantTable;
            for (&self.dequant[c], quant_table) |*d, q| d.* = @intCast(@min(q, std.math.maxInt(i16)));
            self.strides[c] = mcus_x * @as(usize, comp.h_sampling) * 8;
            self.planes[c] = try allocator.alloc(u8, self.strides[c] * @as(usize, comp.v_sampling) * 8 + padded);
        }
        if (nc == 3) {
            self.vrow = try allocator.alloc(i32, padded + 2);
            for (&self.crows) |*crow| crow.* = try allocator.alloc(u8, padded);
            self.rgb_row = try allocator.alloc(Rgb, padded);
        }
        return self;
    }

    fn deinit(self: *RenderBand) void {
        for (self.planes) |plane| self.allocator.free(plane);
        self.allocator.free(self.vrow);
        for (self.crows) |crow| self.allocator.free(crow);
        self.allocator.free(self.rgb_row);
    }

    /// Plane row `r` of component `c`, running to the end of the plane's slack.
    fn row(self: *const RenderBand, c: usize, r: usize) []u8 {
        return self.planes[c][r * self.strides[c] ..];
    }

    /// Chroma component `c` for luma row `py` at luma resolution: bilinear between the two
    /// nearest chroma rows and columns with centred sample positions (T.871 upsampling),
    /// replicated at the band and image edges. Same-sampled components return their row.
    fn chromaRow(self: *RenderBand, state: *const JpegState, c: usize, py: usize, max_h: usize, max_v: usize) []const u8 {
        const comp = state.components[c];
        const vc: usize = comp.v_sampling;
        if (comp.h_sampling == max_h and vc == max_v) return self.row(c, py);
        const cw = self.strides[c];
        // Vertical blend into vrow[1..cw+1]; the position maths mirrors the horizontal taps.
        const scaled: i32 = @intCast(((2 * py + 1) * vc * 128) / max_v);
        const centred = scaled - 128;
        const lo: usize, const frac: i32 = if (centred <= 0)
            .{ 0, 0 }
        else if (@as(usize, @intCast(centred >> 8)) + 1 >= vc * 8)
            .{ vc * 8 - 1, 0 }
        else
            .{ @intCast(centred >> 8), centred & 255 };
        const hi = if (frac == 0) lo else lo + 1;
        const top = self.row(c, lo);
        const bottom = self.row(c, hi);
        const w_lo: V = @splat(256 - frac);
        const w_hi: V = @splat(frac);
        var x: usize = 0;
        while (x < cw) : (x += lanes) {
            const t: V = @intCast(@as(B, top[x..][0..lanes].*));
            const b: V = @intCast(@as(B, bottom[x..][0..lanes].*));
            self.vrow[1 + x ..][0..lanes].* = t * w_lo + b * w_hi;
        }
        self.vrow[0] = self.vrow[1];
        self.vrow[cw + 1] = self.vrow[cw];
        const crow = self.crows[c - 1];
        switch (max_h / comp.h_sampling) {
            1 => {
                var i: usize = 0;
                while (i < cw) : (i += lanes) {
                    const v: V = self.vrow[1 + i ..][0..lanes].*;
                    crow[i..][0..lanes].* = meta.narrowToBytes((v + @as(V, @splat(128))) >> @splat(8));
                }
            },
            2 => self.upsampleRow(2, crow, cw),
            4 => self.upsampleRow(4, crow, cw),
            else => unreachable,
        }
        return crow;
    }

    /// Horizontal `factor`× upsample of `vrow` into `crow`: output `factor * i + k` sits at
    /// chroma position `i + (2k + 1) / (2 factor) - 1/2`, so its two taps and weights are
    /// fixed per phase `k` and the whole chunk is two shuffles of one chroma load.
    fn upsampleRow(self: *const RenderBand, comptime factor: usize, crow: []u8, cw: usize) void {
        const taps = comptime blk: {
            var lo_mask: [lanes]i32 = undefined;
            var hi_mask: [lanes]i32 = undefined;
            var w_hi: [lanes]i32 = undefined;
            for (0..lanes) |j| {
                const k = j % factor;
                const offset: i32 = @intCast((2 * k + 1) * 128 / factor);
                // Lane 0 of the load is chroma sample `i0 - 1`.
                const lo: i32 = @intCast(j / factor);
                lo_mask[j] = if (offset < 128) lo else lo + 1;
                hi_mask[j] = lo_mask[j] + 1;
                w_hi[j] = if (offset < 128) offset + 128 else offset - 128;
            }
            break :blk .{ .lo = lo_mask, .hi = hi_mask, .w_hi = w_hi };
        };
        const w_hi: V = taps.w_hi;
        const w_lo: V = @as(V, @splat(256)) - w_hi;
        const rounding: V = @splat(32768);
        var x: usize = 0;
        while (x < cw * factor) : (x += lanes) {
            const src: V = self.vrow[x / factor ..][0..lanes].*;
            const lo = @shuffle(i32, src, undefined, taps.lo);
            const hi = @shuffle(i32, src, undefined, taps.hi);
            crow[x..][0..lanes].* = meta.narrowToBytes((lo * w_lo + hi * w_hi + rounding) >> @splat(16));
        }
    }

    /// YCbCr (or stored RGB) rows to `width` pixels of `dst`, 16 at a time.
    fn convertRow(y: []const u8, cb: []const u8, cr: []const u8, rgb_model: bool, dst: []Rgb, width: usize) void {
        const bias: V = @splat(128);
        const rounding: V = @splat(32768);
        var px: usize = 0;
        while (px < width) : (px += lanes) {
            const yv: V = @intCast(@as(B, y[px..][0..lanes].*));
            const c1: V = @intCast(@as(B, cb[px..][0..lanes].*));
            const c2: V = @intCast(@as(B, cr[px..][0..lanes].*));
            var r: B = undefined;
            var g: B = undefined;
            var b: B = undefined;
            if (rgb_model) {
                r = meta.narrowToBytes(yv);
                g = meta.narrowToBytes(c1);
                b = meta.narrowToBytes(c2);
            } else {
                const u = c1 - bias;
                const v = c2 - bias;
                const lo: V = @splat(0);
                const hi: V = @splat(255);
                r = meta.narrowToBytes(std.math.clamp(yv + ((@as(V, @splat(91881)) * v + rounding) >> @splat(16)), lo, hi));
                g = meta.narrowToBytes(std.math.clamp(yv - ((@as(V, @splat(22554)) * u + @as(V, @splat(46802)) * v + rounding) >> @splat(16)), lo, hi));
                b = meta.narrowToBytes(std.math.clamp(yv + ((@as(V, @splat(116130)) * u + rounding) >> @splat(16)), lo, hi));
            }
            const n = @min(lanes, width - px);
            const out = dst[px..][0..n];
            if (n == lanes and packed_rgb) {
                const rg = @shuffle(u8, r, g, interleave2);
                const rgb = @shuffle(u8, rg, b, interleave3);
                std.mem.sliceAsBytes(out)[0 .. 3 * lanes].* = rgb;
            } else {
                const ra: [lanes]u8 = r;
                const ga: [lanes]u8 = g;
                const ba: [lanes]u8 = b;
                for (out, ra[0..n], ga[0..n], ba[0..n]) |*px_out, pr, pg, pb| px_out.* = .{ .r = pr, .g = pg, .b = pb };
            }
        }
    }

    const packed_rgb = @sizeOf(Rgb) == 3 and @offsetOf(Rgb, "r") == 0 and @offsetOf(Rgb, "g") == 1 and @offsetOf(Rgb, "b") == 2;
    const interleave2 = blk: {
        var mask: [2 * lanes]i32 = undefined;
        for (0..lanes) |i| {
            mask[2 * i] = @intCast(i);
            mask[2 * i + 1] = ~@as(i32, @intCast(i));
        }
        break :blk mask;
    };
    const interleave3 = blk: {
        var mask: [3 * lanes]i32 = undefined;
        for (0..lanes) |i| {
            mask[3 * i] = @intCast(2 * i);
            mask[3 * i + 1] = @intCast(2 * i + 1);
            mask[3 * i + 2] = ~@as(i32, @intCast(i));
        }
        break :blk mask;
    };
};

/// Dequantizes, inverse-transforms and colour-converts block rows `[block_row0, block_row0 +
/// block_rows)` into `img`. `blocks` holds those rows from index 0, `block_width_actual` wide,
/// as whole MCU rows so chroma is upsampled within its MCU row.
fn renderBlockRows(comptime T: type, state: *const JpegState, band: *RenderBand, blocks: [][4][64]i16, block_row0: usize, block_rows: usize, img: *Image(T)) !void {
    const nc: usize = state.header.num_components;
    const bw: usize = state.block_width_actual;
    const max_h, const max_v = state.maxSamplingFactors();
    const rgb_model = nc == 3 and state.isRgbColorModel();

    // Consecutive blocks of one component are adjacent in its plane, so they transform in pairs.
    for (0..block_rows) |v| {
        for (0..nc) |c| {
            const comp = state.components[c];
            if (v >= comp.v_sampling) continue;
            const hc: usize = comp.h_sampling;
            const stride = band.strides[c];
            const count = stride / 8;
            const dst = band.planes[c][v * 8 * stride ..].ptr;
            var j: usize = 0;
            while (j < count) : (j += 2) {
                const single = j + 1 == count;
                const j1 = if (single) j else j + 1;
                const a = &blocks[v * bw + (j / hc) * max_h + j % hc][c];
                const b = &blocks[v * bw + (j1 / hc) * max_h + j1 % hc][c];
                Idct.pairInto(a, b, &band.dequant[c], dst + j * 8, stride, single);
            }
        }
    }

    const width: usize = state.header.width;
    const y0 = block_row0 * 8;
    const rows = @min(block_rows * 8, @as(usize, state.header.height) - y0);
    for (0..rows) |py| {
        const dst = img.data[(y0 + py) * img.stride ..][0..width];
        const luma = band.row(0, py);
        if (nc == 1) {
            if (T == u8) {
                @memcpy(dst, luma[0..width]);
            } else {
                for (dst, luma[0..width]) |*out, y| out.* = convertColor(T, y);
            }
            continue;
        }
        const cb = band.chromaRow(state, 1, py, max_h, max_v);
        const cr = band.chromaRow(state, 2, py, max_h, max_v);
        if (T == Rgb) {
            RenderBand.convertRow(luma, cb, cr, rgb_model, dst, width);
        } else {
            RenderBand.convertRow(luma, cb, cr, rgb_model, band.rgb_row, width);
            for (dst, band.rgb_row[0..width]) |*out, rgb| out.* = convertColor(T, rgb);
        }
    }
}

/// Baseline frames stream their scan; progressive frames render the full store band by band.
fn decodeInto(comptime T: type, io: Io, state: *JpegState, img: *Image(T)) !void {
    if (state.header.frame_type == .baseline) {
        if (state.restart_interval != 0) {
            const layout: ScanLayout = .init(state);
            const starts = try restartSegments(state.allocator, state.bit_reader.data);
            defer state.allocator.free(starts);
            // One band per CPU, never more than there are segments or MCU rows.
            const bands = @min(parallel.bandCount(layout.mcu_rows, @as(usize, state.header.width) * 8 * layout.y_step), starts.len);
            if (bands > 1) return performBlockScanBanded(T, io, state, img, starts, bands);
        }
        var band: RenderBand = try .init(state.allocator, state);
        defer band.deinit();
        return performBlockScan(T, state, &band, img);
    }
    var band: RenderBand = try .init(state.allocator, state);
    defer band.deinit();
    const full = state.block_storage orelse return error.BlockStorageNotAllocated;
    _, const max_v = state.maxSamplingFactors();
    const bw: usize = state.block_width_actual;
    var y: usize = 0;
    while (y < state.block_height) : (y += max_v) {
        try renderBlockRows(T, state, &band, full[y * bw ..], y, @min(max_v, state.block_height - y), img);
    }
}

pub fn toNativeImage(io: Io, allocator: Allocator, state: *JpegState) !union(enum) {
    grayscale: Image(u8),
    rgb: Image(Rgb),
} {
    if (state.header.num_components == 1) {
        var img: Image(u8) = try .init(allocator, state.header.height, state.header.width);
        errdefer img.deinit(allocator);
        try decodeInto(u8, io, state, &img);
        return .{ .grayscale = img };
    }
    var img: Image(Rgb) = try .init(allocator, state.header.height, state.header.width);
    errdefer img.deinit(allocator);
    try decodeInto(Rgb, io, state, &img);
    return .{ .rgb = img };
}

pub fn loadFromBytes(comptime T: type, io: Io, allocator: Allocator, data: []const u8, limits: DecodeLimits) !Image(T) {
    var state = try decode(allocator, data, limits);
    defer state.deinit();
    var img: Image(T) = try .init(allocator, state.header.height, state.header.width);
    errdefer img.deinit(allocator);
    try decodeInto(T, io, &state, &img);
    return img;
}

pub fn load(comptime T: type, io: Io, allocator: Allocator, file_path: []const u8, limits: DecodeLimits) !Image(T) {
    const read_limit = if (limits.max_jpeg_bytes == 0) std.math.maxInt(usize) else limits.max_jpeg_bytes;
    const jpeg_data = try Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(read_limit));
    defer allocator.free(jpeg_data);
    return loadFromBytes(T, io, allocator, jpeg_data, limits);
}

test "quantizer reciprocals match integer division for every table value" {
    // (|x| + corr) * recip >> shift must equal (|x| + d / 2) / d over the DCT's 15-bit range.
    for (1..256) |q| {
        const d: u32 = @intCast(q * 8);
        const div: QuantDivisor = .init(d);
        var x: u32 = 0;
        while (x < 1 << 15) : (x += 1) {
            const fast = (x + div.corr) * div.recip >> @intCast(div.shift);
            try std.testing.expectEqual((x + d / 2) / d, fast);
        }
    }
}

test "forward DCT matches a floating-point reference" {
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    var samples: [2][64]u8 = undefined;
    for (&samples) |*block| for (block) |*v| {
        v.* = rnd.int(u8);
    };
    // Unit quantizers divide the 8x-scaled integer transform by 8: the output is the DCT itself.
    const unit: [64]u8 = @splat(1);
    const quant: Quantizer = .init(&unit);
    var out: [2][64]i16 = undefined;
    Fdct.pairInto(&samples[0], &samples[1], 8, &quant, &out[0], &out[1]);
    for (samples, out) |block, coefs| {
        for (0..8) |v| for (0..8) |u| {
            var sum: f64 = 0;
            for (0..8) |y| for (0..8) |x| {
                const px = @as(f64, @floatFromInt(block[y * 8 + x])) - 128;
                sum += px * @cos((2 * @as(f64, @floatFromInt(x)) + 1) * @as(f64, @floatFromInt(u)) * std.math.pi / 16) *
                    @cos((2 * @as(f64, @floatFromInt(y)) + 1) * @as(f64, @floatFromInt(v)) * std.math.pi / 16);
            };
            const cu: f64 = if (u == 0) 1.0 / @sqrt(2.0) else 1.0;
            const cv: f64 = if (v == 0) 1.0 / @sqrt(2.0) else 1.0;
            const expected = sum * cu * cv / 4;
            try std.testing.expectApproxEqAbs(expected, @as(f64, @floatFromInt(coefs[v * 8 + u])), 1.0);
        };
    }
}

test "JPEG encode -> decode RGB roundtrip" {
    const gpa = std.testing.allocator;

    var img: Image(Rgb) = try .init(gpa, 16, 16);
    defer img.deinit(gpa);
    for (0..img.rows) |y| {
        for (0..img.cols) |x| {
            const r: u8 = @intCast((x * 255) / (img.cols - 1));
            const g: u8 = @intCast((y * 255) / (img.rows - 1));
            const b: u8 = @intCast(((x + y) * 255) / (img.cols + img.rows - 2));
            img.at(y, x).* = .{ .r = r, .g = g, .b = b };
        }
    }

    const bytes = try encode(Rgb, parallel.inline_io, gpa, img, .{ .quality = 85 });
    defer gpa.free(bytes);

    var state = try decode(gpa, bytes, .{});
    defer state.deinit();
    var out: Image(Rgb) = try .init(gpa, state.header.height, state.header.width);
    defer out.deinit(gpa);
    try decodeInto(Rgb, parallel.inline_io, &state, &out);

    // One 4:2:0 MCU at quality 85: integer chroma upsampling lands at ~38.7 dB.
    const psnr = try img.psnr(out);
    try std.testing.expect(psnr > 38.0);
}

test "JPEG encode -> decode grayscale roundtrip" {
    const gpa = std.testing.allocator;
    var img: Image(u8) = try .init(gpa, 16, 16);
    defer img.deinit(gpa);
    for (0..img.rows) |y| {
        for (0..img.cols) |x| {
            img.at(y, x).* = @intCast(((x + y) * 255) / (img.cols + img.rows - 2));
        }
    }
    const bytes = try encode(u8, parallel.inline_io, gpa, img, .{ .quality = 85 });
    defer gpa.free(bytes);

    var state = try decode(gpa, bytes, .{});
    defer state.deinit();
    var out: Image(Rgb) = try .init(gpa, state.header.height, state.header.width);
    defer out.deinit(gpa);
    try decodeInto(Rgb, parallel.inline_io, &state, &out);

    // Convert original gray to RGB for PSNR
    var gray_rgb = try img.convert(parallel.inline_io, gpa, Rgb);
    defer gray_rgb.deinit(gpa);
    const psnr = try gray_rgb.psnr(out);
    try std.testing.expect(psnr > 45);
}

test "JPEG subsampling 4:2:2 roundtrip" {
    const gpa = std.testing.allocator;

    // Non-multiple-of-MCU dimensions to exercise padding
    const rows: usize = 19;
    const cols: usize = 25;

    var img: Image(Rgb) = try .init(gpa, rows, cols);
    defer img.deinit(gpa);
    for (0..rows) |y| {
        for (0..cols) |x| {
            const r: u8 = @intCast((x * 255) / (cols - 1));
            const g: u8 = @intCast((y * 255) / (rows - 1));
            const b: u8 = @intCast(((x * y) * 255) / ((cols - 1) * (rows - 1))); // mild cross term
            img.at(y, x).* = .{ .r = r, .g = g, .b = b };
        }
    }

    const bytes = try encode(Rgb, parallel.inline_io, gpa, img, .{ .quality = 85, .subsampling = .yuv422 });
    defer gpa.free(bytes);

    var state = try decode(gpa, bytes, .{});
    defer state.deinit();
    var out: Image(Rgb) = try .init(gpa, state.header.height, state.header.width);
    defer out.deinit(gpa);
    try decodeInto(Rgb, parallel.inline_io, &state, &out);

    const psnr = try img.psnr(out);
    try std.testing.expect(psnr > 40);
}

test "JPEG subsampling 4:2:0 roundtrip" {
    const gpa = std.testing.allocator;

    // Non-multiple-of-MCU dimensions (MCU is 16x16 for 4:2:0)
    const rows: usize = 64;
    const cols: usize = 48;

    var img: Image(Rgb) = try .init(gpa, rows, cols);
    defer img.deinit(gpa);
    for (0..rows) |y| {
        for (0..cols) |x| {
            const r: u8 = @intCast((x * 255) / (cols - 1));
            const g: u8 = @intCast((y * 255) / (rows - 1));
            const b: u8 = @intCast(((x + 2 * y) * 255) / (cols - 1 + 2 * (rows - 1)));
            img.at(y, x).* = .{ .r = r, .g = g, .b = b };
        }
    }

    const bytes = try encode(Rgb, parallel.inline_io, gpa, img, .{ .quality = 92, .subsampling = .yuv420 });
    defer gpa.free(bytes);

    var state = try decode(gpa, bytes, .{});
    defer state.deinit();
    var out: Image(Rgb) = try .init(gpa, state.header.height, state.header.width);
    defer out.deinit(gpa);
    try decodeInto(Rgb, parallel.inline_io, &state, &out);

    const psnr = try img.psnr(out);
    try std.testing.expect(psnr > 45);
}

test "JPEG 4:2:0 odd-size roundtrip (non-multiple-of-MCU)" {
    const gpa = std.testing.allocator;

    // Choose dimensions that are not multiples of 16 to force partial MCUs on both axes
    const rows: usize = 37; // not multiple of 16
    const cols: usize = 53; // not multiple of 16

    var img: Image(Rgb) = try .init(gpa, rows, cols);
    defer img.deinit(gpa);

    // Fill with a smooth gradient so PSNR is meaningful
    for (0..rows) |y| {
        for (0..cols) |x| {
            const r: u8 = @intCast((x * 255) / (cols - 1));
            const g: u8 = @intCast((y * 255) / (rows - 1));
            const b: u8 = @intCast(((2 * x + 3 * y) * 255) / (2 * (cols - 1) + 3 * (rows - 1)));
            img.at(y, x).* = .{ .r = r, .g = g, .b = b };
        }
    }

    const bytes = try encode(Rgb, parallel.inline_io, gpa, img, .{ .quality = 85, .subsampling = .yuv420 });
    defer gpa.free(bytes);

    var state = try decode(gpa, bytes, .{});
    defer state.deinit();
    var out: Image(Rgb) = try .init(gpa, state.header.height, state.header.width);
    defer out.deinit(gpa);
    try decodeInto(Rgb, parallel.inline_io, &state, &out);

    // We expect a decent reconstruction quality even with 4:2:0 on odd dimensions.
    const psnr = try img.psnr(out);
    try std.testing.expect(psnr > 35.0);
}

test "JPEG max_jpeg_bytes limit" {
    const data = [_]u8{ 0xFF, 0xD8 };
    const limits: DecodeLimits = .{ .max_jpeg_bytes = 1 };
    const result = decode(std.testing.allocator, &data, limits);
    try std.testing.expectError(error.JpegDataTooLarge, result);
}

test "JPEG marker byte limit" {
    const jpeg = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, 0xFF, 0xD9 };
    const limits: DecodeLimits = .{ .max_jpeg_bytes = 0, .max_marker_bytes = 2 };
    const result = decode(std.testing.allocator, &jpeg, limits);
    try std.testing.expectError(error.MarkerDataLimitExceeded, result);
}

test "JPEG block limit prevents excessive allocation" {
    var state: JpegState = .init(std.testing.allocator);
    defer state.deinit();

    const sof_data = [_]u8{ 0x08, 0x00, 0x10, 0x00, 0x10, 0x01, 0x01, 0x11, 0x00 };
    const limits: DecodeLimits = .{ .max_blocks = 1 };
    const result = state.parseSOF(&sof_data, .baseline, limits);
    try std.testing.expectError(error.BlockMemoryLimitExceeded, result);
}

// Minimal hand-built 8x8 grayscale progressive JPEG: three DC scans (first at Al=2,
// then two successive-approximation refinements) leaving the block's DC at 15,
// which renders as a flat image of value 15 + 128 = 143 (flat quant table of 8).
const test_progressive_dqt = [_]u8{ 0xFF, 0xDB, 0x00, 0x43, 0x00 } ++ @as([64]u8, @splat(0x08));
const test_progressive_sof2 = [_]u8{ 0xFF, 0xC2, 0x00, 0x0B, 0x08, 0x00, 0x08, 0x00, 0x08, 0x01, 0x01, 0x11, 0x00 };
const test_progressive_dht = [_]u8{ 0xFF, 0xC4, 0x00, 0x14, 0x00, 0x01 } ++ @as([15]u8, @splat(0x00)) ++ [_]u8{0x02};
// Ss=0 Se=0 Ah=0 Al=2; entropy 0x7F: code '0' -> magnitude 2, bits '11' -> diff 3 -> DC = 3 << 2 = 12
const test_progressive_scan1 = [_]u8{ 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x00, 0x02, 0x7F };
// Ah=2 Al=1; refinement bit 1 -> DC += 1 << 1 -> 14 (0xFF needs the 0x00 stuffing byte)
const test_progressive_scan2 = [_]u8{ 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x00, 0x21, 0xFF, 0x00 };
// Ah=1 Al=0; refinement bit 1 -> DC += 1 -> 15
const test_progressive_scan3 = [_]u8{ 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x00, 0x10, 0xFF, 0x00 };
const test_progressive_eoi = [_]u8{ 0xFF, 0xD9 };
const test_progressive_jpeg = signature ++ test_progressive_dqt ++ test_progressive_sof2 ++
    test_progressive_dht ++ test_progressive_scan1 ++ test_progressive_scan2 ++ test_progressive_scan3 ++
    test_progressive_eoi;

test "JPEG progressive full decode of hand-built stream" {
    var img = try loadFromBytes(u8, parallel.inline_io, std.testing.allocator, &test_progressive_jpeg, .{});
    defer img.deinit(std.testing.allocator);
    try std.testing.expectEqual(8, img.rows);
    try std.testing.expectEqual(8, img.cols);
    for (img.data) |px| try std.testing.expectEqual(143, px);
}

test "JPEG progressive scan limit returns partial image" {
    // Only the first two of three DC scans are decoded: DC = 14 -> pixel 142.
    var img = try loadFromBytes(u8, parallel.inline_io, std.testing.allocator, &test_progressive_jpeg, .{ .max_scans = 2 });
    defer img.deinit(std.testing.allocator);
    for (img.data) |px| try std.testing.expectEqual(142, px);

    var state = try decode(std.testing.allocator, &test_progressive_jpeg, .{ .max_scans = 2 });
    defer state.deinit();
    try std.testing.expect(state.scan_limit_reached);
}

test "JPEG duplicate SOF is rejected" {
    const sof0 = [_]u8{ 0xFF, 0xC0 } ++ test_progressive_sof2[2..].*;
    const data = signature ++ sof0 ++ sof0 ++ test_progressive_eoi;
    try std.testing.expectError(error.DuplicateSOF, decode(std.testing.allocator, &data, .{}));
}

test "JPEG truncated progressive stream decodes partially" {
    // Scan 3 loses its entropy data (and EOI): refinement hits EOF, DC stays at 14.
    var img = try loadFromBytes(u8, parallel.inline_io, std.testing.allocator, test_progressive_jpeg[0 .. test_progressive_jpeg.len - 4], .{});
    defer img.deinit(std.testing.allocator);
    for (img.data) |px| try std.testing.expectEqual(142, px);

    // Stream ends right after the first SOS header, before any entropy data:
    // the DC-first Huffman read hits EOF, leaving all coefficients zero.
    const headers_only = signature ++ test_progressive_dqt ++ test_progressive_sof2 ++
        test_progressive_dht ++ test_progressive_scan1[0 .. test_progressive_scan1.len - 1].*;
    var img2 = try loadFromBytes(u8, parallel.inline_io, std.testing.allocator, &headers_only, .{});
    defer img2.deinit(std.testing.allocator);
    for (img2.data) |px| try std.testing.expectEqual(128, px);
}

test "JPEG DC-only progressive scan decodes" {
    // Single DC scan at Al=2: DC = 12 -> flat image of value 140.
    const dc_only = signature ++ test_progressive_dqt ++ test_progressive_sof2 ++
        test_progressive_dht ++ test_progressive_scan1 ++ test_progressive_eoi;
    var img = try loadFromBytes(u8, parallel.inline_io, std.testing.allocator, &dc_only, .{});
    defer img.deinit(std.testing.allocator);
    for (img.data) |px| try std.testing.expectEqual(140, px);
}

// Basic tests
test "JPEG marker parsing" {
    const testing = std.testing;

    // Test marker conversion
    const soi_bytes = [2]u8{ 0xFF, 0xD8 };
    const soi: ?Marker = .fromBytes(soi_bytes);
    try testing.expect(soi == .SOI);

    const sof0_bytes = [2]u8{ 0xFF, 0xC0 };
    const sof0: ?Marker = .fromBytes(sof0_bytes);
    try testing.expect(sof0 == .SOF0);
}

test "BitReader basic operations" {
    const testing = std.testing;

    const data = [_]u8{ 0b10110011, 0b01010101 };
    var reader: BitReader = .init(&data);

    // Read first 4 bits
    const bits1 = reader.getBits(4);
    try testing.expectEqual(@as(u16, 0b1011), bits1);

    // Read next 4 bits
    const bits2 = reader.getBits(4);
    try testing.expectEqual(@as(u16, 0b0011), bits2);

    // Read next 8 bits
    const bits3 = reader.getBits(8);
    try testing.expectEqual(@as(u16, 0b01010101), bits3);
}

test "Ycbcr to RGB conversion" {
    const testing = std.testing;

    // Test grayscale - standard Y=128
    const gray_ycbcr: Ycbcr = .{ .y = 128, .cb = 128, .cr = 128 };
    const gray = gray_ycbcr.to(.rgb);
    try testing.expectEqual(@as(u8, 128), gray.r);
    try testing.expectEqual(@as(u8, 128), gray.g);
    try testing.expectEqual(@as(u8, 128), gray.b);

    // Test white - standard Y=255
    const white_ycbcr: Ycbcr = .{ .y = 255, .cb = 128, .cr = 128 };
    const white = white_ycbcr.to(.rgb);
    try testing.expectEqual(@as(u8, 255), white.r);
    try testing.expectEqual(@as(u8, 255), white.g);
    try testing.expectEqual(@as(u8, 255), white.b);

    // Test black - standard Y=0
    const black_ycbcr: Ycbcr = .{ .y = 0, .cb = 128, .cr = 128 };
    const black = black_ycbcr.to(.rgb);
    try testing.expectEqual(@as(u8, 0), black.r);
    try testing.expectEqual(@as(u8, 0), black.g);
    try testing.expectEqual(@as(u8, 0), black.b);
}

fn gradientImage(gpa: Allocator, rows: u32, cols: u32) !Image(Rgb) {
    var img: Image(Rgb) = try .init(gpa, rows, cols);
    for (0..rows) |y| {
        for (0..cols) |x| {
            img.at(y, x).* = .{
                .r = @intCast((x * 255) / (cols - 1)),
                .g = @intCast((y * 255) / (rows - 1)),
                .b = @intCast(((x + y) * 255) / (cols + rows - 2)),
            };
        }
    }
    return img;
}

test "banded restart-interval decode matches the single sweep" {
    const gpa = std.testing.allocator;
    var pool: std.Io.Threaded = .init(gpa, .{});
    defer pool.deinit();
    const pool_io = pool.io();
    // 300x400 is several bands worth of MCU rows for every subsampling.
    var img = try gradientImage(gpa, 300, 400);
    defer img.deinit(gpa);
    var gray = try img.convert(parallel.inline_io, gpa, u8);
    defer gray.deinit(gpa);

    // 1 and 3 MCUs, one row (25 MCUs at 4:2:0, 50 otherwise), and a run straddling rows.
    for ([_]Subsampling{ .yuv444, .yuv422, .yuv420 }) |subsampling| {
        for ([_]u16{ 1, 3, 25, 50, 77 }) |interval| {
            const bytes = try encode(Rgb, parallel.inline_io, gpa, img, .{ .subsampling = subsampling, .restart_interval = .{ .mcus = interval } });
            defer gpa.free(bytes);
            var want = try loadFromBytes(Rgb, parallel.inline_io, gpa, bytes, .{});
            defer want.deinit(gpa);
            var got = try loadFromBytes(Rgb, pool_io, gpa, bytes, .{});
            defer got.deinit(gpa);
            try std.testing.expectEqualSlices(u8, want.asBytes(), got.asBytes());

            // Cut inside a middle segment: the damaged segments are zero and decoding resumes at the next marker on both paths.
            const second = std.mem.indexOfPos(u8, bytes, std.mem.indexOf(u8, bytes, &.{ 0xFF, 0xD0 }).? + 2, &.{ 0xFF, 0xD1 }).?;
            var want_cut = try loadFromBytes(Rgb, parallel.inline_io, gpa, bytes[0 .. second + 40], .{});
            defer want_cut.deinit(gpa);
            var got_cut = try loadFromBytes(Rgb, pool_io, gpa, bytes[0 .. second + 40], .{});
            defer got_cut.deinit(gpa);
            try std.testing.expectEqualSlices(u8, want_cut.asBytes(), got_cut.asBytes());

            const damaged = try gpa.dupe(u8, bytes);
            defer gpa.free(damaged);
            damaged[second + 1] = 0x00;
            var want_dmg = try loadFromBytes(Rgb, parallel.inline_io, gpa, damaged, .{});
            defer want_dmg.deinit(gpa);
            var got_dmg = try loadFromBytes(Rgb, pool_io, gpa, damaged, .{});
            defer got_dmg.deinit(gpa);
            try std.testing.expectEqualSlices(u8, want_dmg.asBytes(), got_dmg.asBytes());
        }
    }

    const bytes = try encode(u8, parallel.inline_io, gpa, gray, .{ .restart_interval = .{ .mcus = 7 } });
    defer gpa.free(bytes);
    var want = try loadFromBytes(u8, parallel.inline_io, gpa, bytes, .{});
    defer want.deinit(gpa);
    var got = try loadFromBytes(u8, pool_io, gpa, bytes, .{});
    defer got.deinit(gpa);
    try std.testing.expectEqualSlices(u8, want.data, got.data);
}

test "banded encode is byte-identical to the single sweep" {
    const gpa = std.testing.allocator;
    var pool: std.Io.Threaded = .init(gpa, .{});
    defer pool.deinit();
    const pool_io = pool.io();
    // 300x400 is several bands of MCU rows for every subsampling.
    var img = try gradientImage(gpa, 300, 400);
    defer img.deinit(gpa);
    var gray = try img.convert(parallel.inline_io, gpa, u8);
    defer gray.deinit(gpa);

    // One row (the default), 1 and 3 MCUs, a run straddling rows, and none (one band).
    const intervals = [_]RestartInterval{ .{ .rows = 1 }, .{ .mcus = 1 }, .{ .mcus = 3 }, .{ .mcus = 77 }, .{ .rows = 2 }, .none };
    for ([_]Subsampling{ .yuv444, .yuv422, .yuv420 }) |subsampling| {
        for (intervals) |interval| {
            const want = try encode(Rgb, parallel.inline_io, gpa, img, .{ .subsampling = subsampling, .restart_interval = interval });
            defer gpa.free(want);
            const got = try encode(Rgb, pool_io, gpa, img, .{ .subsampling = subsampling, .restart_interval = interval });
            defer gpa.free(got);
            try std.testing.expectEqualSlices(u8, want, got);
        }
    }
    for (intervals) |interval| {
        const want = try encode(u8, parallel.inline_io, gpa, gray, .{ .restart_interval = interval });
        defer gpa.free(want);
        const got = try encode(u8, pool_io, gpa, gray, .{ .restart_interval = interval });
        defer gpa.free(got);
        try std.testing.expectEqualSlices(u8, want, got);
    }
}

test "default encode writes one MCU row per restart interval" {
    const gpa = std.testing.allocator;
    // 37 columns: 5 MCUs at 4:4:4, 3 at 4:2:2 and 4:2:0 (16-wide MCUs), 5 blocks in gray.
    var img = try gradientImage(gpa, 21, 37);
    defer img.deinit(gpa);
    var gray = try img.convert(parallel.inline_io, gpa, u8);
    defer gray.deinit(gpa);

    for ([_]struct { s: Subsampling, mcus: u16 }{ .{ .s = .yuv444, .mcus = 5 }, .{ .s = .yuv422, .mcus = 3 }, .{ .s = .yuv420, .mcus = 3 } }) |case| {
        const bytes = try encode(Rgb, parallel.inline_io, gpa, img, .{ .subsampling = case.s });
        defer gpa.free(bytes);
        const dri = std.mem.indexOf(u8, bytes, &.{ 0xFF, 0xDD, 0x00, 0x04 }).?;
        try std.testing.expectEqual(case.mcus, std.mem.readInt(u16, bytes[dri + 4 ..][0..2], .big));
        // The markers change the bitstream, not the pixels.
        const plain = try encode(Rgb, parallel.inline_io, gpa, img, .{ .subsampling = case.s, .restart_interval = .none });
        defer gpa.free(plain);
        var want = try loadFromBytes(Rgb, parallel.inline_io, gpa, plain, .{});
        defer want.deinit(gpa);
        var got = try loadFromBytes(Rgb, parallel.inline_io, gpa, bytes, .{});
        defer got.deinit(gpa);
        try std.testing.expectEqualSlices(u8, want.asBytes(), got.asBytes());
    }

    const bytes = try encode(u8, parallel.inline_io, gpa, gray, .{});
    defer gpa.free(bytes);
    const dri = std.mem.indexOf(u8, bytes, &.{ 0xFF, 0xDD, 0x00, 0x04 }).?;
    try std.testing.expectEqual(5, std.mem.readInt(u16, bytes[dri + 4 ..][0..2], .big));
}

test "JPEG restart intervals decode identically to a single interval" {
    const gpa = std.testing.allocator;
    var img = try gradientImage(gpa, 37, 29);
    defer img.deinit(gpa);
    var gray = try img.convert(parallel.inline_io, gpa, u8);
    defer gray.deinit(gpa);

    for ([_]Subsampling{ .yuv444, .yuv422, .yuv420 }) |subsampling| {
        const plain = try encode(Rgb, parallel.inline_io, gpa, img, .{ .subsampling = subsampling, .restart_interval = .none });
        defer gpa.free(plain);
        try std.testing.expect(std.mem.indexOf(u8, plain, &.{ 0xFF, 0xDD }) == null);
        var want = try loadFromBytes(Rgb, parallel.inline_io, gpa, plain, .{});
        defer want.deinit(gpa);
        for ([_]u16{ 1, 3 }) |interval| {
            const bytes = try encode(Rgb, parallel.inline_io, gpa, img, .{ .subsampling = subsampling, .restart_interval = .{ .mcus = interval } });
            defer gpa.free(bytes);
            try std.testing.expect(std.mem.indexOf(u8, bytes, &.{ 0xFF, 0xDD }) != null);
            var got = try loadFromBytes(Rgb, parallel.inline_io, gpa, bytes, .{});
            defer got.deinit(gpa);
            try std.testing.expectEqualSlices(u8, want.asBytes(), got.asBytes());
        }
    }

    const plain = try encode(u8, parallel.inline_io, gpa, gray, .{ .restart_interval = .none });
    defer gpa.free(plain);
    var want = try loadFromBytes(u8, parallel.inline_io, gpa, plain, .{});
    defer want.deinit(gpa);
    const bytes = try encode(u8, parallel.inline_io, gpa, gray, .{ .restart_interval = .{ .mcus = 2 } });
    defer gpa.free(bytes);
    var got = try loadFromBytes(u8, parallel.inline_io, gpa, bytes, .{});
    defer got.deinit(gpa);
    try std.testing.expectEqualSlices(u8, want.data, got.data);

    // Truncated inside the third interval: the first MCU row (two intervals) is intact.
    const rgb = try encode(Rgb, parallel.inline_io, gpa, img, .{ .subsampling = .yuv420, .restart_interval = .{ .mcus = 1 } });
    defer gpa.free(rgb);
    var full = try loadFromBytes(Rgb, parallel.inline_io, gpa, rgb, .{});
    defer full.deinit(gpa);
    const cut = std.mem.indexOf(u8, rgb, &.{ 0xFF, 0xD1 }).? + 3;
    var partial = try loadFromBytes(Rgb, parallel.inline_io, gpa, rgb[0..cut], .{});
    defer partial.deinit(gpa);
    for (0..16) |r| {
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(full.data[r * full.cols ..][0..full.cols]), std.mem.sliceAsBytes(partial.data[r * partial.cols ..][0..partial.cols]));
    }
}

test "JPEG malformed SOS/SOF fields are rejected" {
    const gpa = std.testing.allocator;
    var img = try gradientImage(gpa, 8, 8);
    defer img.deinit(gpa);
    const bytes = try encode(Rgb, parallel.inline_io, gpa, img, .{ .subsampling = .yuv444 });
    defer gpa.free(bytes);
    const sos = std.mem.indexOf(u8, bytes, &.{ 0xFF, 0xDA }).?;
    const sof = std.mem.indexOf(u8, bytes, &.{ 0xFF, 0xC0 }).?;

    const cases = [_]struct { offset: usize, value: u8, err: anyerror }{
        .{ .offset = sos + 6, .value = 0x44, .err = error.InvalidSOS }, // Huffman table ids 4/4
        .{ .offset = sos + 5, .value = 9, .err = error.InvalidSOS }, // component id absent from the frame
        .{ .offset = sof + 11, .value = 0x00, .err = error.InvalidSOF }, // zero sampling factors
        .{ .offset = sof + 12, .value = 7, .err = error.InvalidSOF }, // quantization table id 7
    };
    for (cases) |case| {
        const corrupt = try gpa.dupe(u8, bytes);
        defer gpa.free(corrupt);
        corrupt[case.offset] = case.value;
        try std.testing.expectError(case.err, loadFromBytes(Rgb, parallel.inline_io, gpa, corrupt, .{}));
    }
}

test "JPEG Adobe APP14 transform 0 decodes the planes as RGB" {
    const gpa = std.testing.allocator;
    var img = try gradientImage(gpa, 16, 16);
    defer img.deinit(gpa);
    const bytes = try encode(Rgb, parallel.inline_io, gpa, img, .{ .subsampling = .yuv444, .quality = 100 });
    defer gpa.free(bytes);

    // Swap the JFIF APP0 segment for an Adobe APP14 segment with transform flag 0.
    const app0 = std.mem.indexOf(u8, bytes, &.{ 0xFF, 0xE0 }).?;
    const app0_len = (@as(usize, bytes[app0 + 2]) << 8) | bytes[app0 + 3];
    const adobe = [_]u8{ 0xFF, 0xEE, 0x00, 0x0E, 'A', 'd', 'o', 'b', 'e', 0x00, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00 };
    var patched: std.ArrayList(u8) = .empty;
    defer patched.deinit(gpa);
    try patched.appendSlice(gpa, bytes[0..app0]);
    try patched.appendSlice(gpa, &adobe);
    try patched.appendSlice(gpa, bytes[app0 + 2 + app0_len ..]);

    // The stored planes are the encoder's Y, Cb, Cr; they must come back untransformed.
    var want: Image(Rgb) = try .init(gpa, 16, 16);
    defer want.deinit(gpa);
    for (img.data, want.data) |px, *w| {
        const ycc = convertColor(Ycbcr, px);
        w.* = .{ .r = ycc.y, .g = ycc.cb, .b = ycc.cr };
    }
    var got = try loadFromBytes(Rgb, parallel.inline_io, gpa, patched.items, .{});
    defer got.deinit(gpa);
    try std.testing.expect(try want.psnr(got) > 40);

    // With the JFIF segment the same scan is YCbCr.
    var plain = try loadFromBytes(Rgb, parallel.inline_io, gpa, bytes, .{});
    defer plain.deinit(gpa);
    try std.testing.expect(try img.psnr(plain) > 40);
}
