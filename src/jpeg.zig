//! Pure Zig JPEG state and baseline encoder implementation.
//! Decoder supports baseline and progressive DCT JPEG images.
//! Encoder implements baseline (SOF0) JPEG with 4:4:4 sampling and adjustable quality.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const convertColor = @import("color.zig").convertColor;
const Image = @import("image.zig").Image;
const Rgb = @import("color.zig").Rgb(u8);
const Gray = @import("color.zig").Gray;
const Ycbcr = @import("color.zig").Ycbcr(u8);

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
};

inline fn exceedsU32(limit: u32, value: u32) bool {
    return limit != 0 and value > limit;
}

inline fn exceedsU64(limit: u64, value: u64) bool {
    return limit != 0 and value > limit;
}

inline fn exceedsUsize(limit: usize, value: usize) bool {
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

// -----------------------------
// Encoder: public API and types
// -----------------------------

pub const Subsampling = enum {
    yuv444,
    yuv422,
    yuv420,
};

pub const EncodeOptions = struct {
    quality: u8 = 90,
    subsampling: Subsampling = .yuv420,
    density_dpi: u16 = 72,
    comment: ?[]const u8 = null,
    pub const default: EncodeOptions = .{};
};

/// Save Image to JPEG file with baseline encoding.
pub fn save(comptime T: type, allocator: Allocator, image: Image(T), file_path: []const u8) !void {
    const bytes = try encode(T, allocator, image, .{ .subsampling = .yuv420 });
    defer allocator.free(bytes);

    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();
    try file.writeAll(bytes);
}

/// Encode an image into baseline JPEG bytes (SOF0, 8-bit, Huffman).
/// Supports grayscale (u8) and RGB (Rgb). Other types are converted to RGB.
pub fn encode(comptime T: type, allocator: Allocator, image: Image(T), options: EncodeOptions) ![]u8 {
    // Validate image dimensions
    if (image.rows == 0 or image.cols == 0) {
        return error.InvalidImageDimensions;
    }
    if (image.rows > 65535 or image.cols > 65535) {
        return error.ImageTooLarge;
    }

    switch (T) {
        u8 => return encodeGrayscale(allocator, image.asBytes(), @intCast(image.cols), @intCast(image.rows), options),
        Rgb => return encodeRgb(allocator, image, options),
        else => {
            var converted = try image.convert(Rgb, allocator);
            defer converted.deinit(allocator);
            return encodeRgb(allocator, converted, options);
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

const HuffmanEncoder = struct {
    codes: [256]u16 = @splat(0),
    sizes: [256]u8 = @splat(0),
};

fn buildHuffmanEncoder(bits: []const u8, vals: []const u8) HuffmanEncoder {
    var enc = HuffmanEncoder{};
    var code: u16 = 0;
    var k: usize = 0;
    for (0..16) |i| {
        const nb = bits[i];
        for (0..nb) |_| {
            const sym = vals[k];
            enc.codes[sym] = code;
            enc.sizes[sym] = @intCast(i + 1);
            code += 1;
            k += 1;
        }
        code = code << 1;
    }
    return enc;
}

const EntropyWriter = struct {
    gpa: Allocator,
    data: std.ArrayList(u8),
    bit_buf: u32 = 0,
    bit_count: u5 = 0,

    pub fn init(gpa: Allocator) EntropyWriter {
        return .{ .gpa = gpa, .data = .empty };
    }
    pub fn deinit(self: *EntropyWriter) void {
        self.data.deinit(self.gpa);
    }

    fn writeByte(self: *EntropyWriter, b: u8) !void {
        try self.data.append(self.gpa, b);
        if (b == 0xFF) try self.data.append(self.gpa, 0x00);
    }
    fn writeBits(self: *EntropyWriter, code: u32, size: u5) !void {
        self.bit_buf = (self.bit_buf << size) | (code & ((@as(u32, 1) << size) - 1));
        self.bit_count += size;
        while (self.bit_count >= 8) {
            const shard = (self.bit_buf >> (self.bit_count - 8)) & 0xFF;
            const out: u8 = @intCast(shard);
            try self.writeByte(out);
            self.bit_count -= 8;
        }
    }
    fn flush(self: *EntropyWriter) !void {
        if (self.bit_count > 0) {
            const pad: u5 = 8 - self.bit_count;
            try self.writeBits((@as(u32, 1) << pad) - 1, pad);
        }
    }
};

fn writeMarker(dst: *std.ArrayList(u8), gpa: Allocator, marker: u16) !void {
    try dst.append(gpa, 0xFF);
    try dst.append(gpa, @intCast(marker & 0xFF));
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
        const y_sampling: u8 = switch (subsampling) {
            .yuv444 => 0x11,
            .yuv422 => 0x21,
            .yuv420 => 0x22,
        };
        try tmp.append(gpa, y_sampling);
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

fn magnitudeCategory(value: i32) u5 {
    if (value == 0) return 0;
    var v: u32 = @intCast(if (value < 0) -value else value);
    var c: u5 = 0;
    while (v != 0) : (v >>= 1) c += 1;
    return c;
}

fn magnitudeBits(value: i32, mag: u5) u32 {
    if (mag == 0) return 0;
    if (value >= 0) return @intCast(value);
    const base: i32 = (@as(i32, 1) << @intCast(mag)) - 1;
    return @intCast(base + value);
}

// -----------------------------
// Forward DCT - Loeffler-Ligtenberg-Moschytz (LLM) algorithm
// -----------------------------

// LLM DCT constants in 13-bit fixed point (CONST_BITS = 13)
inline fn FIX(comptime x: f32) i32 {
    return @as(i32, @intFromFloat(x * (1 << 13) + 0.5));
}

const FIX_0_298631336: i32 = FIX(0.298631336);
const FIX_0_390180644: i32 = FIX(0.390180644);
const FIX_0_541196100: i32 = FIX(0.541196100);
const FIX_0_765366865: i32 = FIX(0.765366865);
const FIX_0_899976223: i32 = FIX(0.899976223);
const FIX_1_175875602: i32 = FIX(1.175875602);
const FIX_1_501321110: i32 = FIX(1.501321110);
const FIX_1_847759065: i32 = FIX(1.847759065);
const FIX_1_961570560: i32 = FIX(1.961570560);
const FIX_2_053119869: i32 = FIX(2.053119869);
const FIX_2_562915447: i32 = FIX(2.562915447);
const FIX_3_072711026: i32 = FIX(3.072711026);

inline fn DESCALE(x: i64, n: u5) i32 {
    const add: i64 = @as(i64, 1) << (n - 1);
    return @intCast((x + add) >> n);
}

// Integer forward DCT based on libjpeg's jfdctint.c implementation
// This is an accurate integer implementation using the
// Loeffler, Ligtenberg and Moschytz algorithm with 12 multiplies and 32 adds.
fn fdct8x8_llm(src: *const [64]i32, dst: *[64]i32) void {
    const CONST_BITS: u5 = 13;
    const PASS1_BITS: u5 = 2;

    var data: [64]i32 = undefined;

    // Pass 1: process rows.
    // Note results are scaled up by sqrt(8) compared to a true DCT;
    // furthermore, we scale the results by 2**PASS1_BITS.
    for (0..8) |y| {
        const tmp0: i64 = src[y * 8 + 0] + src[y * 8 + 7];
        const tmp7: i64 = src[y * 8 + 0] - src[y * 8 + 7];
        const tmp1: i64 = src[y * 8 + 1] + src[y * 8 + 6];
        const tmp6: i64 = src[y * 8 + 1] - src[y * 8 + 6];
        const tmp2: i64 = src[y * 8 + 2] + src[y * 8 + 5];
        const tmp5: i64 = src[y * 8 + 2] - src[y * 8 + 5];
        const tmp3: i64 = src[y * 8 + 3] + src[y * 8 + 4];
        const tmp4: i64 = src[y * 8 + 3] - src[y * 8 + 4];

        // Even part per LL&M figure 1 --- note that published figure is faulty;
        // rotator "sqrt(2)*c1" should be "sqrt(2)*c6".
        const tmp10 = tmp0 + tmp3;
        const tmp13 = tmp0 - tmp3;
        const tmp11 = tmp1 + tmp2;
        const tmp12 = tmp1 - tmp2;

        data[y * 8 + 0] = @intCast((tmp10 + tmp11) << PASS1_BITS);
        data[y * 8 + 4] = @intCast((tmp10 - tmp11) << PASS1_BITS);

        const z1 = (tmp12 + tmp13) * FIX_0_541196100;
        data[y * 8 + 2] = DESCALE(z1 + tmp13 * FIX_0_765366865, CONST_BITS - PASS1_BITS);
        data[y * 8 + 6] = DESCALE(z1 + tmp12 * (-FIX_1_847759065), CONST_BITS - PASS1_BITS);

        // Odd part per figure 8 --- note paper omits factor of sqrt(2).
        // cK represents cos(K*pi/16).
        // i0..i3 in the paper are tmp4..tmp7 here.
        var z1_odd = tmp4 + tmp7;
        var z2 = tmp5 + tmp6;
        var z3 = tmp4 + tmp6;
        var z4 = tmp5 + tmp7;
        const z5 = (z3 + z4) * FIX_1_175875602; // sqrt(2) * c3

        const t4 = tmp4 * FIX_0_298631336; // sqrt(2) * (-c1+c3+c5-c7)
        const t5 = tmp5 * FIX_2_053119869; // sqrt(2) * ( c1+c3-c5+c7)
        const t6 = tmp6 * FIX_3_072711026; // sqrt(2) * ( c1+c3+c5-c7)
        const t7 = tmp7 * FIX_1_501321110; // sqrt(2) * ( c1+c3-c5-c7)
        z1_odd = z1_odd * (-FIX_0_899976223); // sqrt(2) * (c7-c3)
        z2 = z2 * (-FIX_2_562915447); // sqrt(2) * (-c1-c3)
        z3 = z3 * (-FIX_1_961570560); // sqrt(2) * (-c3-c5)
        z4 = z4 * (-FIX_0_390180644); // sqrt(2) * (c5-c3)

        z3 += z5;
        z4 += z5;

        data[y * 8 + 7] = DESCALE(t4 + z1_odd + z3, CONST_BITS - PASS1_BITS);
        data[y * 8 + 5] = DESCALE(t5 + z2 + z4, CONST_BITS - PASS1_BITS);
        data[y * 8 + 3] = DESCALE(t6 + z2 + z3, CONST_BITS - PASS1_BITS);
        data[y * 8 + 1] = DESCALE(t7 + z1_odd + z4, CONST_BITS - PASS1_BITS);
    }

    // Pass 2: process columns.
    // We remove the PASS1_BITS scaling, but leave the results scaled up
    // by an overall factor of 8.
    for (0..8) |x| {
        const tmp0: i64 = data[0 * 8 + x] + data[7 * 8 + x];
        const tmp7: i64 = data[0 * 8 + x] - data[7 * 8 + x];
        const tmp1: i64 = data[1 * 8 + x] + data[6 * 8 + x];
        const tmp6: i64 = data[1 * 8 + x] - data[6 * 8 + x];
        const tmp2: i64 = data[2 * 8 + x] + data[5 * 8 + x];
        const tmp5: i64 = data[2 * 8 + x] - data[5 * 8 + x];
        const tmp3: i64 = data[3 * 8 + x] + data[4 * 8 + x];
        const tmp4: i64 = data[3 * 8 + x] - data[4 * 8 + x];

        // Even part
        const tmp10 = tmp0 + tmp3;
        const tmp13 = tmp0 - tmp3;
        const tmp11 = tmp1 + tmp2;
        const tmp12 = tmp1 - tmp2;

        dst[0 * 8 + x] = DESCALE(tmp10 + tmp11, PASS1_BITS);
        dst[4 * 8 + x] = DESCALE(tmp10 - tmp11, PASS1_BITS);

        const z1 = (tmp12 + tmp13) * FIX_0_541196100;
        dst[2 * 8 + x] = DESCALE(z1 + tmp13 * FIX_0_765366865, CONST_BITS + PASS1_BITS);
        dst[6 * 8 + x] = DESCALE(z1 + tmp12 * (-FIX_1_847759065), CONST_BITS + PASS1_BITS);

        // Odd part
        var z1_odd = tmp4 + tmp7;
        var z2 = tmp5 + tmp6;
        var z3 = tmp4 + tmp6;
        var z4 = tmp5 + tmp7;
        const z5 = (z3 + z4) * FIX_1_175875602;

        const t4 = tmp4 * FIX_0_298631336;
        const t5 = tmp5 * FIX_2_053119869;
        const t6 = tmp6 * FIX_3_072711026;
        const t7 = tmp7 * FIX_1_501321110;
        z1_odd = z1_odd * (-FIX_0_899976223);
        z2 = z2 * (-FIX_2_562915447);
        z3 = z3 * (-FIX_1_961570560);
        z4 = z4 * (-FIX_0_390180644);

        z3 += z5;
        z4 += z5;

        dst[7 * 8 + x] = DESCALE(t4 + z1_odd + z3, CONST_BITS + PASS1_BITS);
        dst[5 * 8 + x] = DESCALE(t5 + z2 + z4, CONST_BITS + PASS1_BITS);
        dst[3 * 8 + x] = DESCALE(t6 + z2 + z3, CONST_BITS + PASS1_BITS);
        dst[1 * 8 + x] = DESCALE(t7 + z1_odd + z4, CONST_BITS + PASS1_BITS);
    }
}

// Reciprocal-based quantization (fold normalization/scaling into the divisor).
const RECIP_SHIFT: u5 = 24; // high precision for reciprocals

fn buildQuantRecipLLM(divisors_out: *[64]u32, qtbl: *const [64]u8) void {
    // For LLM DCT (libjpeg-style), the output is scaled by 8
    // We need to divide by 8 * quantization value
    for (0..64) |idx| {
        const q = @as(f64, @floatFromInt(qtbl[idx]));
        const scale = 8.0; // Overall factor of 8 from the DCT
        const recip_f = (@as(f64, @floatFromInt(1 << RECIP_SHIFT))) / (q * scale);
        const recip_u: u32 = @intFromFloat(@round(@max(0.0, @min(4_294_967_295.0, recip_f))));
        divisors_out[idx] = recip_u;
    }
}

inline fn quantizeWithRecip(val: i32, recip: u32) i32 {
    if (val == 0) return 0;
    const a: i64 = if (val < 0) -@as(i64, val) else val;
    const prod: i64 = a * @as(i64, recip);
    var q: i64 = (prod + (@as(i64, 1) << (RECIP_SHIFT - 1))) >> RECIP_SHIFT;
    if (val < 0) q = -q;
    return @intCast(q);
}

// Helper function to encode a single 8x8 block
fn encodeBlock(
    block: *const [64]i32,
    quant_recip: *const [64]u32,
    writer: *EntropyWriter,
    dc_encoder: *const HuffmanEncoder,
    ac_encoder: *const HuffmanEncoder,
    prev_dc: *i32,
) !void {
    var dct: [64]i32 = undefined;
    fdct8x8_llm(block, &dct);

    var coeffs: [64]i32 = undefined;
    // Quantization using reciprocal divisors (JPEG normalization folded in)
    for (0..64) |i| coeffs[i] = quantizeWithRecip(dct[i], quant_recip[i]);

    // Encode DC coefficient
    const dc_coeff = coeffs[0];
    const diff = dc_coeff - prev_dc.*;
    prev_dc.* = dc_coeff;

    const mag = magnitudeCategory(diff);
    try writer.writeBits(@intCast(dc_encoder.codes[mag]), @as(u5, @intCast(dc_encoder.sizes[mag])));
    if (mag > 0) try writer.writeBits(magnitudeBits(diff, mag), mag);

    // Encode AC coefficients
    var run: u8 = 0;
    for (1..64) |k| {
        const v = coeffs[zigzag[k]];
        if (v == 0) {
            run += 1;
            if (run == 16) {
                try writer.writeBits(@intCast(ac_encoder.codes[0xF0]), @as(u5, @intCast(ac_encoder.sizes[0xF0])));
                run = 0;
            }
        } else {
            while (run >= 16) : (run -= 16) {
                try writer.writeBits(@intCast(ac_encoder.codes[0xF0]), @as(u5, @intCast(ac_encoder.sizes[0xF0])));
            }
            const amag = magnitudeCategory(v);
            const sym: u8 = (run << 4) | @as(u8, amag);
            try writer.writeBits(@intCast(ac_encoder.codes[sym]), @as(u5, @intCast(ac_encoder.sizes[sym])));
            try writer.writeBits(magnitudeBits(v, amag), amag);
            run = 0;
        }
    }
    if (run > 0) try writer.writeBits(@intCast(ac_encoder.codes[0x00]), @as(u5, @intCast(ac_encoder.sizes[0x00])));
}

fn encodeBlocksRgb(
    image: Image(Rgb),
    subsampling: Subsampling,
    ql_recip: *const [64]u32,
    qc_recip: *const [64]u32,
    writer: *EntropyWriter,
    dc_luma: *const HuffmanEncoder,
    ac_luma: *const HuffmanEncoder,
    dc_chroma: *const HuffmanEncoder,
    ac_chroma: *const HuffmanEncoder,
) !void {
    const rows: usize = image.rows;
    const cols: usize = image.cols;
    const h_max: usize = switch (subsampling) {
        .yuv444 => 1,
        .yuv422 => 2,
        .yuv420 => 2,
    };
    const v_max: usize = switch (subsampling) {
        .yuv444 => 1,
        .yuv422 => 1,
        .yuv420 => 2,
    };
    const mcu_rows: usize = (rows + (8 * v_max) - 1) / (8 * v_max);
    const mcu_cols: usize = (cols + (8 * h_max) - 1) / (8 * h_max);

    var prev_dc_y: i32 = 0;
    var prev_dc_cb: i32 = 0;
    var prev_dc_cr: i32 = 0;

    var block: [64]i32 = undefined;

    // MCU buffer - sized for the largest case (16x16 for 4:2:0)
    var mcu_buffer: [16][16]Ycbcr = undefined;
    const mcu_width = 8 * h_max;
    const mcu_height = 8 * v_max;

    for (0..mcu_rows) |mcu_y| {
        for (0..mcu_cols) |mcu_x| {
            const mcu_px0 = mcu_x * mcu_width;
            const mcu_py0 = mcu_y * mcu_height;

            // Convert entire MCU to YCbCr once
            for (0..mcu_height) |y| {
                const iy = @min(rows - 1, mcu_py0 + y);
                for (0..mcu_width) |x| {
                    const ix = @min(cols - 1, mcu_px0 + x);
                    mcu_buffer[y][x] = convertColor(Ycbcr, image.at(iy, ix).*);
                }
            }

            // Encode Y blocks directly from buffer
            for (0..v_max) |vy| {
                for (0..h_max) |hx| {
                    const by0 = vy * 8;
                    const bx0 = hx * 8;
                    for (0..8) |y| {
                        for (0..8) |x| {
                            block[y * 8 + x] = @as(i32, mcu_buffer[by0 + y][bx0 + x].y) - 128;
                        }
                    }
                    try encodeBlock(&block, ql_recip, writer, dc_luma, ac_luma, &prev_dc_y);
                }
            }

            // Encode Cb block with downsampling from buffer
            for (0..8) |y| {
                for (0..8) |x| {
                    if (h_max == 1 and v_max == 1) {
                        // 4:4:4 - no downsampling
                        block[y * 8 + x] = @as(i32, mcu_buffer[y][x].cb) - 128;
                    } else {
                        // Average the corresponding pixels for downsampling
                        var sum_cb: u32 = 0;
                        for (0..v_max) |dy| {
                            for (0..h_max) |dx| {
                                sum_cb += mcu_buffer[y * v_max + dy][x * h_max + dx].cb;
                            }
                        }
                        const avg_cb = sum_cb / (h_max * v_max);
                        block[y * 8 + x] = @as(i32, @intCast(avg_cb)) - 128;
                    }
                }
            }
            try encodeBlock(&block, qc_recip, writer, dc_chroma, ac_chroma, &prev_dc_cb);

            // Encode Cr block with downsampling from buffer
            for (0..8) |y| {
                for (0..8) |x| {
                    if (h_max == 1 and v_max == 1) {
                        // 4:4:4 - no downsampling
                        block[y * 8 + x] = @as(i32, mcu_buffer[y][x].cr) - 128;
                    } else {
                        // Average the corresponding pixels for downsampling
                        var sum_cr: u32 = 0;
                        for (0..v_max) |dy| {
                            for (0..h_max) |dx| {
                                sum_cr += mcu_buffer[y * v_max + dy][x * h_max + dx].cr;
                            }
                        }
                        const avg_cr = sum_cr / (h_max * v_max);
                        block[y * 8 + x] = @as(i32, @intCast(avg_cr)) - 128;
                    }
                }
            }
            try encodeBlock(&block, qc_recip, writer, dc_chroma, ac_chroma, &prev_dc_cr);
        }
    }
}

fn encodeRgb(allocator: Allocator, image: Image(Rgb), options: EncodeOptions) ![]u8 {
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
    try writeSOS(&out, allocator, false);

    // Entropy-coded data
    var ew = EntropyWriter.init(allocator);
    defer ew.deinit();

    // Build Huffman encoders
    const dc_luma = buildHuffmanEncoder(&StdTables.bits_dc_luma, &StdTables.val_dc_luma);
    const ac_luma = buildHuffmanEncoder(&StdTables.bits_ac_luma, &StdTables.val_ac_luma);
    const dc_chroma = buildHuffmanEncoder(&StdTables.bits_dc_chroma, &StdTables.val_dc_chroma);
    const ac_chroma = buildHuffmanEncoder(&StdTables.bits_ac_chroma, &StdTables.val_ac_chroma);

    // Build reciprocal quantization tables with folded normalization/scaling
    var ql_recip: [64]u32 = undefined;
    var qc_recip: [64]u32 = undefined;
    buildQuantRecipLLM(&ql_recip, &ql);
    buildQuantRecipLLM(&qc_recip, &qc);

    try encodeBlocksRgb(image, options.subsampling, &ql_recip, &qc_recip, &ew, &dc_luma, &ac_luma, &dc_chroma, &ac_chroma);
    try ew.flush();

    // Append entropy-coded bytes into output
    try out.appendSlice(allocator, ew.data.items);

    // EOI
    try out.append(allocator, 0xFF);
    try out.append(allocator, 0xD9);

    return out.toOwnedSlice(allocator);
}

fn encodeGrayscale(allocator: Allocator, bytes: []const u8, width: u32, height: u32, options: EncodeOptions) ![]u8 {
    _ = options.subsampling; // not used for grayscale

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    // SOI
    try out.append(allocator, 0xFF);
    try out.append(allocator, 0xD8);

    try writeAPP0_JFIF(&out, allocator, options.density_dpi);
    if (options.comment) |c| try writeCOM(&out, allocator, c);

    var ql: [64]u8 = undefined;
    var dummy: [64]u8 = undefined;
    scaleQuantTables(options.quality, &ql, &dummy);
    // Only luma table used
    var tmp_dqt = std.ArrayList(u8).empty;
    defer tmp_dqt.deinit(allocator);
    try tmp_dqt.append(allocator, 0x00);
    for (0..64) |i| try tmp_dqt.append(allocator, ql[zigzag[i]]);
    try writeSegment(&out, allocator, 0xFFDB, tmp_dqt.items);

    try writeSOF0(&out, allocator, @intCast(width), @intCast(height), true, .yuv444);
    try writeDHT(&out, allocator, true);
    try writeSOS(&out, allocator, true);

    var ew = EntropyWriter.init(allocator);
    defer ew.deinit();

    const dc = buildHuffmanEncoder(&StdTables.bits_dc_luma, &StdTables.val_dc_luma);
    const ac = buildHuffmanEncoder(&StdTables.bits_ac_luma, &StdTables.val_ac_luma);

    // Build reciprocal quantization table with folded normalization/scaling
    var ql_recip: [64]u32 = undefined;
    buildQuantRecipLLM(&ql_recip, &ql);

    var prev_dc: i32 = 0;

    const rows: usize = @intCast(height);
    const cols: usize = @intCast(width);
    const block_rows: usize = (rows + 7) / 8;
    const block_cols: usize = (cols + 7) / 8;
    var block: [64]i32 = undefined;

    for (0..block_rows) |br| {
        for (0..block_cols) |bc| {
            for (0..8) |y| {
                const iy = @min(rows - 1, br * 8 + y);
                for (0..8) |x| {
                    const ix = @min(cols - 1, bc * 8 + x);
                    const v: u8 = bytes[iy * cols + ix];
                    // Convert to fixed-point, center at 128
                    block[y * 8 + x] = @as(i32, @intCast(v)) - 128;
                }
            }
            try encodeBlock(&block, &ql_recip, &ew, &dc, &ac, &prev_dc);
        }
    }

    try ew.flush();
    try out.appendSlice(allocator, ew.data.items);
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
        return std.meta.intToEnum(Marker, value) catch null;
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
    width: u16,
    height: u16,
    num_components: u8,
    components: [4]Component = undefined,
    frame_type: FrameType = .baseline,

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
    block_storage: ?[][4][64]i32 = null,

    // Separate RGB storage to avoid overwriting chroma data
    rgb_storage: ?[][3][64]u8 = null,

    // Progressive decoding state - persistent across scans
    dc_prediction_values: [4]i32 = @splat(0),
    skip_count: u32 = 0, // For progressive AC scans

    // Restart marker tracking
    expected_rst_marker: u3 = 0, // Cycles 0-7 for RST0-RST7

    pub fn init(allocator: Allocator) JpegState {
        return .{
            .allocator = allocator,
            .width = 0,
            .height = 0,
            .num_components = 0,
            .scan_components = &[_]ScanComponent{},
            .frame_type = .baseline,
        };
    }

    pub fn deinit(self: *JpegState) void {
        for (&self.dc_tables) |*table| {
            if (table.*) |*t| t.deinit();
        }
        for (&self.ac_tables) |*table| {
            if (table.*) |*t| t.deinit();
        }
        if (self.scan_components.len > 0) {
            self.allocator.free(self.scan_components);
        }
        if (self.block_storage) |storage| {
            self.allocator.free(storage);
        }
        if (self.rgb_storage) |storage| {
            self.allocator.free(storage);
        }
    }

    // Decode a Huffman symbol using the fast lookup table
    pub fn readCode(self: *JpegState, table: *const HuffmanTable) !u8 {
        const fast_bits = 9;
        const fast_index = self.bit_reader.peekBits(fast_bits) catch 0;

        if (self.bit_reader.bit_count >= fast_bits) {
            const value = table.fast_table[fast_index];
            if (value != 255) {
                const length = table.fast_size[fast_index];
                self.bit_reader.consumeBits(length);
                return value;
            }
        }

        // Slow path: read one bit at a time and probe the table
        var code: u16 = 0;
        var length: u5 = 0;
        while (length < 16) {
            const bit: u32 = self.bit_reader.getBits(1) catch return error.InvalidHuffmanCode;
            code = (code << 1) | @as(u16, @intCast(bit & 1));
            length += 1;
            if (table.code_map.get(.{ .length_minus_one = @intCast(length - 1), .code = code })) |value| {
                return value;
            }
        }

        return error.InvalidHuffmanCode;
    }

    // Legacy alias for compatibility
    pub fn decodeHuffmanSymbol(self: *JpegState, table: *const HuffmanTable) !u8 {
        return self.readCode(table);
    }

    // Decode magnitude-coded coefficient (T.81 section F1.2.1)
    pub fn readMagnitudeCoded(self: *JpegState, magnitude: u5) !i32 {
        if (magnitude == 0) return 0;

        var coeff: i32 = @intCast(try self.bit_reader.peekBits(magnitude));
        self.bit_reader.consumeBits(magnitude);

        // Convert from unsigned to signed
        if (coeff < @as(i32, 1) << @intCast(magnitude - 1)) {
            coeff -= (@as(i32, 1) << @intCast(magnitude)) - 1;
        }

        return coeff;
    }

    // Decode AC coefficients (simple baseline implementation)
    pub fn decodeAC(self: *JpegState, table: *const HuffmanTable, block: *[64]i32) !void {
        var k: usize = 1; // Start after DC coefficient

        while (k < 64) {
            const symbol = try self.readCode(table);

            if (symbol == 0) {
                // End of block - zero fill remaining coefficients
                while (k < 64) {
                    block[zigzag[k]] = 0;
                    k += 1;
                }
                return;
            }

            const run = symbol >> 4;
            const size = symbol & 0x0F;

            if (size == 0) {
                if (run == 15) {
                    // ZRL: skip 16 zeros
                    for (0..16) |_| {
                        if (k >= 64) break;
                        block[zigzag[k]] = 0;
                        k += 1;
                    }
                } else {
                    return error.InvalidACCoefficient; // invalid stream
                }
            } else {
                // Skip 'run' zeros
                for (0..run) |_| {
                    if (k >= 64) break;
                    block[zigzag[k]] = 0;
                    k += 1;
                }

                if (k >= 64) break;

                // Decode AC coefficient using magnitude state
                const value = try self.readMagnitudeCoded(@intCast(size));
                block[zigzag[k]] = value;
                k += 1;
            }
        }
    }

    // Parse Start of Frame (SOF0/SOF2) marker
    pub fn parseSOF(self: *JpegState, data: []const u8, frame_type: FrameType, limits: DecodeLimits) !void {
        self.frame_type = frame_type;
        if (data.len < 6) return error.InvalidSOF;

        const precision = data[0];
        // Provide specific error messages for different precision values
        switch (precision) {
            8 => {}, // Supported
            12 => return error.Unsupported12BitPrecision,
            16 => return error.Unsupported16BitPrecision,
            else => return error.UnsupportedPrecision,
        }

        self.height = (@as(u16, data[1]) << 8) | data[2];
        self.width = (@as(u16, data[3]) << 8) | data[4];
        self.num_components = data[5];

        if (self.width == 0 or self.height == 0) {
            return error.InvalidSOF;
        }

        if (exceedsU32(limits.max_width, self.width) or exceedsU32(limits.max_height, self.height)) {
            return error.ImageTooLarge;
        }

        // Distinguish between invalid and unsupported component counts
        switch (self.num_components) {
            1, 3 => {}, // Supported: grayscale and YCbCr
            4 => return error.UnsupportedComponentCount, // CMYK - valid but unsupported
            0 => return error.InvalidComponentCount, // Invalid: no components
            else => return error.InvalidComponentCount, // Invalid: too many components
        }

        // Parse component information
        var pos: usize = 6;
        var max_h_sampling: u4 = 0;
        var max_v_sampling: u4 = 0;

        for (0..self.num_components) |i| {
            if (pos + 3 > data.len) return error.InvalidSOF;

            self.components[i] = .{
                .id = data[pos],
                .h_sampling = @intCast(data[pos + 1] >> 4),
                .v_sampling = @intCast(data[pos + 1] & 0x0F),
                .quant_table_id = data[pos + 2],
            };

            max_h_sampling = @max(max_h_sampling, self.components[i].h_sampling);
            max_v_sampling = @max(max_v_sampling, self.components[i].v_sampling);

            pos += 3;
        }

        // Validate sampling factors
        if (max_h_sampling > 4 or max_v_sampling > 4) {
            return error.UnsupportedSamplingFactor;
        }

        // Validate specific chroma subsampling combinations
        if (self.num_components == 3) {
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
                // Note: While 4:2:2 and 4:1:1 pass validation, they use fallback processing
                // Only 4:4:4 and 4:2:0 have optimized implementations
                return error.UnsupportedSamplingFactor;
            }
        }

        // Calculate block dimensions
        const mcu_width = 8 * @as(u32, max_h_sampling);
        const mcu_height = 8 * @as(u32, max_v_sampling);
        const width_actual = ((@as(u32, self.width) + mcu_width - 1) / mcu_width) * mcu_width;
        const height_actual = ((@as(u32, self.height) + mcu_height - 1) / mcu_height) * mcu_height;

        self.block_width = (self.width + 7) / 8;
        self.block_height = (self.height + 7) / 8;
        self.block_width_actual = @intCast((width_actual + 7) / 8);
        self.block_height_actual = @intCast((height_actual + 7) / 8);

        // Allocate block storage
        const width_actual_u64 = @as(u64, width_actual);
        const height_actual_u64 = @as(u64, height_actual);
        const total_pixels_actual = std.math.mul(u64, width_actual_u64, height_actual_u64) catch return error.ImageTooLarge;
        if (exceedsU64(limits.max_pixels, total_pixels_actual)) {
            return error.ImageTooLarge;
        }
        const total_blocks_u64 = total_pixels_actual / 64;
        const total_blocks = std.math.cast(usize, total_blocks_u64) orelse return error.BlockMemoryLimitExceeded;
        if (exceedsUsize(limits.max_blocks, total_blocks)) {
            return error.BlockMemoryLimitExceeded;
        }
        self.block_storage = try self.allocator.alloc([4][64]i32, total_blocks);

        // Allocate separate RGB storage
        self.rgb_storage = try self.allocator.alloc([3][64]u8, total_blocks);

        // Initialize block storage to zero
        for (self.block_storage.?) |*block_set| {
            for (block_set) |*block| {
                @memset(block, 0);
            }
        }

        // Initialize RGB storage to zero
        for (self.rgb_storage.?) |*rgb_block| {
            for (rgb_block) |*channel| {
                @memset(channel, 0);
            }
        }
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

            if (pos + total_codes > length) return error.InvalidDHT;

            // Allocate and read huffman values
            const huffval = try self.allocator.alloc(u8, total_codes);
            @memcpy(huffval, data[pos .. pos + total_codes]);
            pos += total_codes;

            // Build Huffman table
            var code_map = std.AutoArrayHashMap(HuffmanCode, u8).init(self.allocator);
            errdefer {
                code_map.deinit();
                self.allocator.free(huffval);
            }

            var fast_table: [512]u8 = @splat(255);
            var fast_size: [512]u5 = @splat(0);

            // Build codes according to JPEG standard
            var code: u16 = 0;
            var huffval_index: usize = 0;
            for (bits, 0..) |count, i| {
                var j: usize = 0;
                while (j < count) : (j += 1) {
                    // Check for invalid code (all 1s)
                    if (code == (@as(u17, @intCast(1)) << (@as(u5, @intCast(i)) + 1)) - 1) {
                        return error.InvalidHuffmanTable;
                    }

                    const byte = huffval[huffval_index];
                    huffval_index += 1;
                    try code_map.put(.{ .length_minus_one = @as(u4, @intCast(i)), .code = code }, byte);

                    // Build fast lookup table for codes <= 9 bits
                    if (i + 1 <= 9) {
                        const first_index = code << 9 - @as(u4, @intCast(i + 1));
                        const num_indexes = @as(usize, 1) << @as(u4, @intCast(9 - (i + 1)));
                        for (0..num_indexes) |index| {
                            std.debug.assert(fast_table[first_index + index] == 255);
                            fast_table[first_index + index] = byte;
                            fast_size[first_index + index] = @as(u5, @intCast(i + 1));
                        }
                    }

                    code += 1;
                }
                code <<= 1;
            }

            const table = HuffmanTable{
                .allocator = self.allocator,
                .code_counts = bits,
                .code_map = code_map,
                .fast_table = fast_table,
                .fast_size = fast_size,
            };

            // Free huffval array - no longer needed after building code_map
            self.allocator.free(huffval);

            // Store table
            if (table_class == 0) {
                if (self.dc_tables[table_id]) |*old_table| {
                    old_table.deinit();
                }
                self.dc_tables[table_id] = table;
            } else {
                if (self.ac_tables[table_id]) |*old_table| {
                    old_table.deinit();
                }
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
        if (self.frame_type == .baseline and num_components != self.num_components) return error.InvalidSOS;
        if (self.frame_type == .progressive and (num_components == 0 or num_components > self.num_components)) return error.InvalidSOS;

        const scan_components = try self.allocator.alloc(ScanComponent, num_components);
        errdefer self.allocator.free(scan_components);

        var pos: usize = 1;
        for (0..num_components) |i| {
            if (pos + 2 > data.len) return error.InvalidSOS;

            scan_components[i] = .{
                .component_id = data[pos],
                .dc_table_id = @intCast(data[pos + 1] >> 4),
                .ac_table_id = @intCast(data[pos + 1] & 0x0F),
            };

            pos += 2;
        }

        // Read spectral selection and successive approximation
        if (pos + 3 > data.len) return error.InvalidSOS;

        const start_of_spectral = data[pos];
        const end_of_spectral = data[pos + 1];
        const approximation = data[pos + 2];

        // Validate spectral selection parameters
        if (self.frame_type == .baseline) {
            // For baseline JPEG, these should be 0, 63, 0
            if (start_of_spectral != 0 or end_of_spectral != 63 or approximation != 0) {
                return error.InvalidSOS;
            }
        } else if (self.frame_type == .progressive) {
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

// Huffman table for decoding
const HuffmanTable = struct {
    allocator: Allocator,
    // Number of codes for each bit length (1-16)
    code_counts: [16]u8,
    // Hash map for full lookup
    code_map: std.AutoArrayHashMap(HuffmanCode, u8),
    // Fast lookup table for short codes
    fast_table: [512]u8, // 2^9 entries
    fast_size: [512]u5,

    pub fn deinit(self: *HuffmanTable) void {
        self.code_map.deinit();
    }
};

const HuffmanCode = struct { length_minus_one: u4, code: u16 };

// Bit reader for entropy-coded segments
pub const BitReader = struct {
    data: []const u8,
    byte_pos: usize = 0,
    bit_buffer: u32 = 0,
    bit_count: u5 = 0,

    pub fn init(data: []const u8) BitReader {
        return .{ .data = data };
    }

    pub fn peekBits(self: *BitReader, num_bits: u5) !u32 {
        if (num_bits > 24) return error.InvalidData;
        try self.fillBits(num_bits);
        return (self.bit_buffer >> 1) >> @intCast(31 - num_bits);
    }

    pub fn fillBits(self: *BitReader, num_bits: u5) !void {
        while (self.bit_count < num_bits) {
            if (self.byte_pos >= self.data.len) {
                return error.UnexpectedEndOfData;
            }

            var byte_curr: u32 = self.data[self.byte_pos];
            self.byte_pos += 1;

            while (byte_curr == 0xFF) {
                if (self.byte_pos >= self.data.len) return error.UnexpectedEndOfData;
                const byte_next: u8 = self.data[self.byte_pos];
                self.byte_pos += 1;

                if (byte_next == 0x00) {
                    break;
                } else if (byte_next == 0xFF) {
                    continue;
                } else if (byte_next >= 0xD0 and byte_next <= 0xD7) {
                    // Restart marker found - just skip it, validation happens at scan level
                    if (self.byte_pos >= self.data.len) return error.UnexpectedEndOfData;
                    byte_curr = self.data[self.byte_pos];
                    self.byte_pos += 1;
                } else {
                    self.byte_pos -= 2;
                    return error.UnexpectedEndOfData;
                }
            }

            self.bit_buffer |= byte_curr << @intCast(24 - self.bit_count);
            self.bit_count += 8;
        }
    }

    pub fn consumeBits(self: *BitReader, num_bits: u5) void {
        std.debug.assert(num_bits <= self.bit_count and num_bits <= 16);
        self.bit_buffer <<= num_bits;
        self.bit_count -= num_bits;
    }

    pub fn getBits(self: *BitReader, n: u5) !u32 {
        const bits = try self.peekBits(n);
        self.consumeBits(n);
        return @intCast(bits);
    }

    pub fn flushBits(self: *BitReader) void {
        // On restart boundaries or explicit flush requests
        // discard any buffered bits and realign to the next byte.
        self.bit_buffer = 0;
        self.bit_count = 0;
    }
};

// Perform a scan (baseline or progressive)
fn performScan(state: *JpegState, scan_info: ScanInfo) !void {
    if (state.block_storage == null) return error.BlockStorageNotAllocated;

    if (state.frame_type == .baseline) {
        // Baseline JPEG: single scan with all data
        try performBaselineScan(state, scan_info);
    } else {
        // Progressive JPEG: accumulate data across multiple scans
        try performProgressiveScan(state, scan_info);
    }
}

// Upsample and convert a single YCbCr block to RGB
fn yCbCrToRgbBlock(_: *JpegState, y_block: *[64]i32, cb_block: *const [64]i32, cr_block: *const [64]i32, rgb_block: *[3][64]u8) void {
    // YCbCr to RGB conversion coefficients (ITU-R BT.601 standard)
    const co_1: @Vector(8, f32) = @splat(1.402); // Cr to R
    const co_2: @Vector(8, f32) = @splat(1.772); // Cb to B
    const co_3: @Vector(8, f32) = @splat(-0.344136); // Cb to G
    const co_4: @Vector(8, f32) = @splat(-0.714136); // Cr to G
    const vec_0: @Vector(8, f32) = @splat(0.0);
    const vec_255: @Vector(8, f32) = @splat(255.0);

    for (0..8) |y| {
        const y_vec_i32: @Vector(8, i32) = y_block[y * 8 ..][0..8].*;
        const y_vec: @Vector(8, f32) = @floatFromInt(y_vec_i32);

        const cb_vec_i32: @Vector(8, i32) = cb_block[y * 8 ..][0..8].*;
        const cb_vec: @Vector(8, f32) = @floatFromInt(cb_vec_i32);

        const cr_vec_i32: @Vector(8, i32) = cr_block[y * 8 ..][0..8].*;
        const cr_vec: @Vector(8, f32) = @floatFromInt(cr_vec_i32);

        var r_vec = y_vec + cr_vec * co_1;
        var g_vec = y_vec + cb_vec * co_3 + cr_vec * co_4;
        var b_vec = y_vec + cb_vec * co_2;

        r_vec = std.math.clamp(r_vec, vec_0, vec_255);
        g_vec = std.math.clamp(g_vec, vec_0, vec_255);
        b_vec = std.math.clamp(b_vec, vec_0, vec_255);

        const r_u8: @Vector(8, u8) = @intFromFloat(r_vec);
        const g_u8: @Vector(8, u8) = @intFromFloat(g_vec);
        const b_u8: @Vector(8, u8) = @intFromFloat(b_vec);

        var r_array: [8]u8 = undefined;
        var g_array: [8]u8 = undefined;
        var b_array: [8]u8 = undefined;

        for (0..8) |i| {
            r_array[i] = r_u8[i];
            g_array[i] = g_u8[i];
            b_array[i] = b_u8[i];
        }

        @memcpy(rgb_block[0][y * 8 ..][0..8], &r_array);
        @memcpy(rgb_block[1][y * 8 ..][0..8], &g_array);
        @memcpy(rgb_block[2][y * 8 ..][0..8], &b_array);
    }
}

// Perform baseline scan
fn performBaselineScan(state: *JpegState, scan_info: ScanInfo) !void {
    // Calculate maximum sampling factors
    var max_h_factor: u4 = 1;
    var max_v_factor: u4 = 1;
    for (state.components[0..state.num_components]) |comp| {
        max_h_factor = @max(max_h_factor, comp.h_sampling);
        max_v_factor = @max(max_v_factor, comp.v_sampling);
    }

    // DC prediction values for each component
    var prediction_values: [4]i32 = @splat(0);

    // Scan structure
    const noninterleaved = scan_info.components.len == 1 and scan_info.components[0].component_id == 1;
    // For non-interleaved scans (Y only), step by 1, otherwise use sampling factors
    const y_step = if (noninterleaved) 1 else max_v_factor;
    const x_step = if (noninterleaved) 1 else max_h_factor;

    var mcu_count: u32 = 0;
    var mcus_since_restart: u32 = 0;

    var y: usize = 0;
    while (y < state.block_height) : (y += y_step) {
        var x: usize = 0;
        while (x < state.block_width) : (x += x_step) {
            // Handle restart intervals for baseline scans
            if (state.restart_interval != 0 and mcus_since_restart == state.restart_interval) {
                // Reset DC predictions
                prediction_values = @splat(0);
                mcus_since_restart = 0;
                // Reset expected RST marker
                state.expected_rst_marker = 0;
                // Flush bits to byte boundary
                state.bit_reader.flushBits();
            }
            // Decode each component at this position
            for (scan_info.components) |scan_comp| {
                // Find the component index for this scan component
                var component_index: usize = 0;
                var v_max: usize = undefined;
                var h_max: usize = undefined;

                for (state.components[0..state.num_components], 0..) |frame_component, i| {
                    if (frame_component.id == scan_comp.component_id) {
                        component_index = i;
                        v_max = if (noninterleaved) 1 else frame_component.v_sampling;
                        h_max = if (noninterleaved) 1 else frame_component.h_sampling;
                        break;
                    }
                }

                // Decode all blocks for this component in this MCU
                for (0..v_max) |v| {
                    for (0..h_max) |h| {
                        // Standard coordinate calculation
                        const actual_x = x + h;
                        const actual_y = y + v;

                        // Compute storage pointer, but always decode the block to keep bitstream in sync
                        var tmp_block: [64]i32 = undefined;
                        const in_bounds = (actual_y < state.block_height and actual_x < state.block_width);
                        const block_ptr: *[64]i32 = if (in_bounds)
                            &state.block_storage.?[actual_y * state.block_width_actual + actual_x][component_index]
                        else
                            &tmp_block;

                        // Fill bit buffer before decoding
                        try state.bit_reader.fillBits(24);

                        // Decode block
                        decodeBlockBaseline(state, scan_comp, block_ptr, &prediction_values[component_index]) catch |err| {
                            if (err == error.UnexpectedEndOfData) return;
                            return err;
                        };
                    }
                }
            }

            mcu_count += 1;
            mcus_since_restart += 1;
        }
    }
}

// Perform progressive scan
fn performProgressiveScan(state: *JpegState, scan_info: ScanInfo) !void {
    var skips: u32 = 0;

    // Definition of noninterleaved
    const noninterleaved = scan_info.components.len == 1 and scan_info.components[0].component_id == 1;

    // Calculate sampling factors
    var max_h_factor: u4 = 1;
    var max_v_factor: u4 = 1;
    for (state.components[0..state.num_components]) |comp| {
        max_h_factor = @max(max_h_factor, comp.h_sampling);
        max_v_factor = @max(max_v_factor, comp.v_sampling);
    }

    const y_step = if (noninterleaved) 1 else max_v_factor;
    const x_step = if (noninterleaved) 1 else max_h_factor;

    // Scan loop structure
    var y: usize = 0;
    while (y < state.block_height) : (y += y_step) {
        var x: usize = 0;
        while (x < state.block_width) : (x += x_step) {
            const mcu_id = y * state.block_width_actual + x;

            // Handle restart intervals
            if (state.restart_interval != 0 and mcu_id % (state.restart_interval * y_step * x_step) == 0) {
                state.bit_reader.flushBits();
                state.dc_prediction_values = @splat(0);
                skips = 0;
            }

            for (0..scan_info.components.len) |index| {
                const scan_comp = scan_info.components[index];

                var component_index: usize = undefined;
                var v_max: usize = undefined;
                var h_max: usize = undefined;

                // Find the component
                for (state.components[0..state.num_components], 0..) |frame_component, i| {
                    if (frame_component.id == scan_comp.component_id) {
                        component_index = i;
                        v_max = if (noninterleaved) 1 else frame_component.v_sampling;
                        h_max = if (noninterleaved) 1 else frame_component.h_sampling;
                        break;
                    }
                }

                for (0..v_max) |v| {
                    for (0..h_max) |h| {
                        const block_id = (y + v) * state.block_width_actual + (x + h);
                        const block = &state.block_storage.?[block_id][component_index];

                        // Fill bits
                        state.bit_reader.fillBits(24) catch {};

                        try decodeBlockProgressive(state, scan_info, scan_comp, block, &state.dc_prediction_values[component_index], &skips);
                    }
                }
            }
        }
    }

    // Save skip count for next progressive AC scan
    if (scan_info.start_of_spectral_selection != 0) {
        state.skip_count = skips;
    }
}

// Decode a single block in progressive mode
fn decodeBlockProgressive(state: *JpegState, scan_info: ScanInfo, scan_comp: ScanComponent, block: *[64]i32, dc_prediction: *i32, skips: *u32) !void {
    if (scan_info.start_of_spectral_selection == 0) {
        const dc_table = state.dc_tables[scan_comp.dc_table_id] orelse return error.MissingHuffmanTable;
        if (scan_info.approximation_high == 0) {
            const maybe_magnitude = try state.readCode(&dc_table);
            if (maybe_magnitude > 11) return error.InvalidDCCoefficient;
            const diff = try state.readMagnitudeCoded(@intCast(maybe_magnitude));
            const dc_coefficient = diff + dc_prediction.*;
            dc_prediction.* = dc_coefficient;
            block[0] = dc_coefficient << @intCast(scan_info.approximation_low);
        } else if (scan_info.approximation_high != 0) {
            const bit: u32 = try state.bit_reader.getBits(1);
            block[0] += @as(i32, @intCast(bit)) << @intCast(scan_info.approximation_low);
        }
    } else if (scan_info.start_of_spectral_selection != 0) {
        const ac_table = state.ac_tables[scan_comp.ac_table_id] orelse return error.MissingHuffmanTable;
        if (scan_info.approximation_high == 0) {
            var ac: usize = scan_info.start_of_spectral_selection;
            // Check skips == 0 first
            if (skips.* == 0) {
                while (ac <= scan_info.end_of_spectral_selection and ac < 64) {
                    var coeff: i32 = 0;
                    const zero_run_length_and_magnitude = try state.readCode(&ac_table);
                    const zero_run_length = zero_run_length_and_magnitude >> 4;
                    const maybe_magnitude = zero_run_length_and_magnitude & 0x0F;

                    if (maybe_magnitude == 0) {
                        if (zero_run_length < 15) {
                            const extra_skips: u32 = try state.bit_reader.getBits(@intCast(zero_run_length));
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
                    block[zigzag[ac]] = coeff << @intCast(scan_info.approximation_low);
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
            const bit: i32 = @as(i32, 1) << @intCast(scan_info.approximation_low);
            var ac: usize = scan_info.start_of_spectral_selection;
            if (skips.* == 0) {
                while (ac <= scan_info.end_of_spectral_selection and ac < 64) {
                    var coeff: i32 = 0;
                    const zero_run_length_and_magnitude = try state.readCode(&ac_table);
                    var zero_run_length = zero_run_length_and_magnitude >> 4;
                    const maybe_magnitude = zero_run_length_and_magnitude & 0x0F;

                    if (maybe_magnitude == 0) {
                        if (zero_run_length < 15) {
                            skips.* = (@as(u32, 1) << @intCast(zero_run_length));
                            const extra_skips: u32 = try state.bit_reader.getBits(@intCast(zero_run_length));
                            skips.* += extra_skips;
                            break; // start processing skips
                        } // no special treatment for zero_run_length == 15
                    } else if (maybe_magnitude != 0) {
                        const sign_bit: u32 = try state.bit_reader.getBits(1);
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
                            const sign_bit: u32 = try state.bit_reader.getBits(1);
                            if (sign_bit != 0) {
                                block[zigzag[ac]] += if (block[zigzag[ac]] > 0) bit else -bit;
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
                        const sign_bit: u32 = try state.bit_reader.getBits(1);
                        if (sign_bit != 0) {
                            block[zigzag[ac]] += if (block[zigzag[ac]] > 0) bit else -bit;
                        }
                    }
                }
                skips.* -= 1;
            }
        }
    }
}

// Decode a single block in baseline mode
fn decodeBlockBaseline(state: *JpegState, scan_comp: ScanComponent, block: *[64]i32, dc_prediction: *i32) !void {
    // For baseline, clear the block
    @memset(block, 0);

    // Decode DC coefficient
    const dc_table = state.dc_tables[scan_comp.dc_table_id] orelse return error.MissingHuffmanTable;
    const dc_symbol = try state.readCode(&dc_table);

    if (dc_symbol > 11) return error.InvalidDCCoefficient;

    const dc_diff = try state.readMagnitudeCoded(@intCast(dc_symbol));

    dc_prediction.* += dc_diff;
    block[0] = dc_prediction.*;

    // Decode AC coefficients using the existing function
    const ac_table = state.ac_tables[scan_comp.ac_table_id] orelse return error.MissingHuffmanTable;
    try state.decodeAC(&ac_table, block);
}

// Parse JPEG file and decode image
// Helper function to find the end of entropy-coded scan data
fn findScanEnd(data: []const u8, start_pos: usize) usize {
    var scan_end = start_pos;
    while (scan_end < data.len - 1) {
        if (data[scan_end] == 0xFF) {
            if (scan_end + 1 < data.len) {
                const next_byte = data[scan_end + 1];
                // 0xFF00 is byte stuffing, not a marker
                if (next_byte == 0x00) {
                    scan_end += 2;
                    continue;
                }
                // Check if it's a restart marker (can appear in entropy data)
                if (next_byte >= 0xD0 and next_byte <= 0xD7) {
                    scan_end += 2;
                    continue;
                }
                // Any other marker ends the entropy-coded segment
                break;
            }
        }
        scan_end += 1;
    }
    return scan_end;
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

    // For baseline JPEG, don't perform scan here - loadJpeg will call performBlockScan
    if (state.frame_type == .baseline) {
        // Track allocated components for baseline
        state.scan_components = scan_info.components;
        return scan_end; // Signal that baseline processing is complete
    }

    // For progressive JPEG, perform the scan
    performScan(state, scan_info) catch |err| {
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
    if (exceedsUsize(limits.max_jpeg_bytes, data.len)) {
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
            // Skip unknown markers
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

            // Specific unsupported SOF markers
            .SOF1 => return error.UnsupportedExtendedSequential,
            .SOF3 => return error.UnsupportedLosslessJpeg,

            .DHT => {
                const payload = try readMarkerPayload(data, &pos, &total_marker_bytes, limits);
                try state.parseDHT(payload);
            },

            .DQT => {
                const payload = try readMarkerPayload(data, &pos, &total_marker_bytes, limits);
                try state.parseDQT(payload);
            },

            .SOS => {
                scan_count += 1;
                if (exceedsUsize(limits.max_scans, scan_count)) {
                    return error.TooManyScans;
                }
                const scan_end = try processScanMarker(&state, data, pos);
                const scan_consumed = scan_end - pos;
                try accumulateWithLimit(&total_marker_bytes, scan_consumed, limits.max_marker_bytes, error.MarkerDataLimitExceeded);
                // For baseline JPEG, return immediately after first scan
                if (state.frame_type == .baseline) {
                    return state;
                }
                // For progressive JPEG, continue parsing more scans
                pos = scan_end;
            },

            .DRI => {
                const payload = try readMarkerPayload(data, &pos, &total_marker_bytes, limits);
                try state.parseDRI(payload);
            },

            // Detect arithmetic coding
            .DAC => return error.UnsupportedArithmeticCoding,

            // Detect hierarchical JPEG
            .DHP => return error.UnsupportedHierarchicalJpeg,

            // Detect differential JPEG
            .DNL => return error.UnsupportedJpegVariant,

            .APP0, .APP1, .APP2, .APP3, .APP4, .APP5, .APP6, .APP7, .APP8, .APP9, .APP10, .APP11, .APP12, .APP13, .APP14, .APP15, .COM => {
                // Skip application and comment markers
                if (pos + 4 > data.len) break;
                const length = try readMarkerLength(data, pos + 2);
                try accumulateWithLimit(&total_marker_bytes, length, limits.max_marker_bytes, error.MarkerDataLimitExceeded);
                pos += 2 + length;
            },

            else => {
                // Check for other unsupported SOF markers
                const marker_value = @intFromEnum(marker);
                if (marker_value >= 0xFFC5 and marker_value <= 0xFFCF) {
                    // SOF5-SOF15 are unsupported variants
                    return error.UnsupportedJpegVariant;
                }
                // Skip other unknown markers with length
                if (pos + 4 > data.len) break;
                const length = try readMarkerLength(data, pos + 2);
                try accumulateWithLimit(&total_marker_bytes, length, limits.max_marker_bytes, error.MarkerDataLimitExceeded);
                pos += 2 + length;
            },
        }
    }

    // For progressive JPEG that finished all scans
    if (state.frame_type == .progressive) {
        return state;
    }

    return error.NoScanData;
}

// Error types
pub const JpegError = error{
    InvalidJpegFile,
    InvalidMarker,
    InvalidSOF,
    InvalidDHT,
    InvalidDQT,
    InvalidSOS,
    InvalidDRI,
    UnsupportedJpegFormat,
    // Specific unsupported format errors
    UnsupportedExtendedSequential, // SOF1
    UnsupportedLosslessJpeg, // SOF3
    UnsupportedJpegVariant, // SOF5-SOF15
    UnsupportedArithmeticCoding, // DAC marker
    Unsupported12BitPrecision, // 12-bit samples
    Unsupported16BitPrecision, // 16-bit samples
    UnsupportedPrecision, // Other precision values
    UnsupportedComponentCount, // Valid but unsupported component counts
    UnsupportedSamplingFactor, // Sampling factors > 4
    UnsupportedHierarchicalJpeg, // DHP marker
    // Invalid format errors
    InvalidComponentCount,
    InvalidHuffmanTable,
    InvalidQuantTable,
    NoScanData,
    UnexpectedEndOfData,
    InvalidByteStuffing,
    OutOfMemory,
    InvalidHuffmanCode,
    MissingHuffmanTable,
    MissingQuantTable,
    InvalidDCCoefficient,
    InvalidACCoefficient,
    InvalidACValue,
    BlockStorageNotAllocated,
    RgbStorageNotAllocated,
    // Resource limit errors
    JpegDataTooLarge,
    MarkerDataLimitExceeded,
    BlockMemoryLimitExceeded,
    TooManyScans,
};

// IDCT implementation based on stb_image
fn f2f(comptime x: f32) i32 {
    // 4096 = 1 << 12
    return @intFromFloat(x * 4096 + 0.5);
}

fn idct1D(s0: i32, s1: i32, s2: i32, s3: i32, s4: i32, s5: i32, s6: i32, s7: i32) struct { i32, i32, i32, i32, i32, i32, i32, i32 } {
    var p2 = s2;
    var p3 = s6;

    var p1 = (p2 + p3) * f2f(0.5411961);
    var t2 = p1 + p3 * f2f(-1.847759065);
    var t3 = p1 + p2 * f2f(0.765366865);
    p2 = s0;
    p3 = s4;
    var t0 = (p2 + p3) * 4096;
    var t1 = (p2 - p3) * 4096;
    const x0 = t0 + t3;
    const x3 = t0 - t3;
    const x1 = t1 + t2;
    const x2 = t1 - t2;
    t0 = s7;
    t1 = s5;
    t2 = s3;
    t3 = s1;
    p3 = t0 + t2;
    var p4 = t1 + t3;
    p1 = t0 + t3;
    p2 = t1 + t2;
    const p5 = (p3 + p4) * f2f(1.175875602);
    t0 = t0 * f2f(0.298631336);
    t1 = t1 * f2f(2.053119869);
    t2 = t2 * f2f(3.072711026);
    t3 = t3 * f2f(1.501321110);
    p1 = p5 + p1 * f2f(-0.899976223);
    p2 = p5 + p2 * f2f(-2.562915447);
    p3 = p3 * f2f(-1.961570560);
    p4 = p4 * f2f(-0.390180644);
    t3 += p1 + p4;
    t2 += p2 + p3;
    t1 += p2 + p4;
    t0 += p1 + p3;

    return .{ x0, x1, x2, x3, t0, t1, t2, t3 };
}

fn idct8x8(block: *[64]i32) void {
    // Pass 1: process columns
    for (0..8) |x| {
        const s0 = block[0 * 8 + x];
        const s1 = block[1 * 8 + x];
        const s2 = block[2 * 8 + x];
        const s3 = block[3 * 8 + x];
        const s4 = block[4 * 8 + x];
        const s5 = block[5 * 8 + x];
        const s6 = block[6 * 8 + x];
        const s7 = block[7 * 8 + x];

        var x0: i32 = 0;
        var x1: i32 = 0;
        var x2: i32 = 0;
        var x3: i32 = 0;
        var t0: i32 = 0;
        var t1: i32 = 0;
        var t2: i32 = 0;
        var t3: i32 = 0;

        x0, x1, x2, x3, t0, t1, t2, t3 = idct1D(s0, s1, s2, s3, s4, s5, s6, s7);

        x0 += 512;
        x1 += 512;
        x2 += 512;
        x3 += 512;

        block[0 * 8 + x] = (x0 + t3) >> 10;
        block[1 * 8 + x] = (x1 + t2) >> 10;
        block[2 * 8 + x] = (x2 + t1) >> 10;
        block[3 * 8 + x] = (x3 + t0) >> 10;
        block[4 * 8 + x] = (x3 - t0) >> 10;
        block[5 * 8 + x] = (x2 - t1) >> 10;
        block[6 * 8 + x] = (x1 - t2) >> 10;
        block[7 * 8 + x] = (x0 - t3) >> 10;
    }

    // Pass 2: process rows
    for (0..8) |y| {
        const s0 = block[y * 8 + 0];
        const s1 = block[y * 8 + 1];
        const s2 = block[y * 8 + 2];
        const s3 = block[y * 8 + 3];
        const s4 = block[y * 8 + 4];
        const s5 = block[y * 8 + 5];
        const s6 = block[y * 8 + 6];
        const s7 = block[y * 8 + 7];

        var x0: i32 = 0;
        var x1: i32 = 0;
        var x2: i32 = 0;
        var x3: i32 = 0;
        var t0: i32 = 0;
        var t1: i32 = 0;
        var t2: i32 = 0;
        var t3: i32 = 0;

        x0, x1, x2, x3, t0, t1, t2, t3 = idct1D(s0, s1, s2, s3, s4, s5, s6, s7);

        // add 0.5 scaled up by factor
        x0 += (1 << 17) / 2;
        x1 += (1 << 17) / 2;
        x2 += (1 << 17) / 2;
        x3 += (1 << 17) / 2;

        block[y * 8 + 0] = (x0 + t3) >> 17;
        block[y * 8 + 1] = (x1 + t2) >> 17;
        block[y * 8 + 2] = (x2 + t1) >> 17;
        block[y * 8 + 3] = (x3 + t0) >> 17;
        block[y * 8 + 4] = (x3 - t0) >> 17;
        block[y * 8 + 5] = (x2 - t1) >> 17;
        block[y * 8 + 6] = (x1 - t2) >> 17;
        block[y * 8 + 7] = (x0 - t3) >> 17;
    }
}

// Upsample chroma component for 4:2:0 subsampling using bilinear interpolation
fn upsampleChroma420(input: []const [64]i32, output: *[256]i32, h_blocks: u4, v_blocks: u4, max_h: u4, max_v: u4) void {
    // For 4:2:0, input is typically 1 block (8x8), output should be max_h*8 x max_v*8
    assert(h_blocks == 1 and v_blocks == 1);
    assert(input.len == 1);

    const src_block = &input[0];
    const dst_width = @as(usize, max_h) * 8;
    const dst_height = @as(usize, max_v) * 8;
    const scale_x = 8.0 / @as(f32, @floatFromInt(dst_width));
    const scale_y = 8.0 / @as(f32, @floatFromInt(dst_height));

    // Bilinear interpolation upsampling for better quality
    for (0..dst_height) |dst_y| {
        for (0..dst_width) |dst_x| {
            // Calculate source coordinates with sub-pixel precision
            const src_x_f = (@as(f32, @floatFromInt(dst_x)) + 0.5) * scale_x - 0.5;
            const src_y_f = (@as(f32, @floatFromInt(dst_y)) + 0.5) * scale_y - 0.5;

            // Get integer and fractional parts
            const x0 = @max(0, @min(7, @as(i32, @intFromFloat(@floor(src_x_f)))));
            const y0 = @max(0, @min(7, @as(i32, @intFromFloat(@floor(src_y_f)))));
            const x1 = @min(7, x0 + 1);
            const y1 = @min(7, y0 + 1);

            const fx = src_x_f - @as(f32, @floatFromInt(x0));
            const fy = src_y_f - @as(f32, @floatFromInt(y0));

            // Get the four surrounding pixels
            const p00 = @as(f32, @floatFromInt(src_block[@as(usize, @intCast(y0)) * 8 + @as(usize, @intCast(x0))]));
            const p10 = @as(f32, @floatFromInt(src_block[@as(usize, @intCast(y0)) * 8 + @as(usize, @intCast(x1))]));
            const p01 = @as(f32, @floatFromInt(src_block[@as(usize, @intCast(y1)) * 8 + @as(usize, @intCast(x0))]));
            const p11 = @as(f32, @floatFromInt(src_block[@as(usize, @intCast(y1)) * 8 + @as(usize, @intCast(x1))]));

            // Bilinear interpolation
            const interp_x0 = std.math.lerp(p00, p10, fx);
            const interp_x1 = std.math.lerp(p01, p11, fx);
            const result = std.math.lerp(interp_x0, interp_x1, fy);

            const dst_idx = dst_y * dst_width + dst_x;
            output[dst_idx] = @intFromFloat(@round(result));
        }
    }
}

// Block scan function that fills block storage (from master)
fn performBlockScan(state: *JpegState) !void {
    if (state.block_storage == null) return error.BlockStorageNotAllocated;

    // Calculate maximum sampling factors
    var max_h_factor: u4 = 1;
    var max_v_factor: u4 = 1;
    for (state.components[0..state.num_components]) |comp| {
        max_h_factor = @max(max_h_factor, comp.h_sampling);
        max_v_factor = @max(max_v_factor, comp.v_sampling);
    }

    // Scan structure
    const noninterleaved = state.scan_components.len == 1 and state.scan_components[0].component_id == 1;
    const y_step = if (noninterleaved) 1 else max_v_factor;
    const x_step = if (noninterleaved) 1 else max_h_factor;

    // DC prediction values for each component
    var prediction_values: [4]i32 = @splat(0);

    // Track MCUs to honor restart intervals
    var mcus_since_restart: u32 = 0;

    var y: usize = 0;
    while (y < state.block_height) : (y += y_step) {
        var x: usize = 0;
        while (x < state.block_width) : (x += x_step) {
            // Handle restart intervals for baseline scans
            if (state.restart_interval != 0 and mcus_since_restart == state.restart_interval) {
                // Reset DC predictions at restart boundary
                prediction_values = @splat(0);
                mcus_since_restart = 0;
                // Reset expected RST marker sequence number
                state.expected_rst_marker = 0;
                // Align to next byte boundary before continuing entropy decoding
                state.bit_reader.flushBits();
            }
            // Decode each component at this position
            for (state.scan_components) |scan_comp| {
                // Find the component index for this scan component
                var component_index: usize = 0;
                var v_max: usize = undefined;
                var h_max: usize = undefined;

                for (state.components[0..state.num_components], 0..) |frame_component, i| {
                    if (frame_component.id == scan_comp.component_id) {
                        component_index = i;
                        v_max = if (noninterleaved) 1 else frame_component.v_sampling;
                        h_max = if (noninterleaved) 1 else frame_component.h_sampling;
                        break;
                    }
                }

                // Decode all blocks for this component in this MCU
                for (0..v_max) |v| {
                    for (0..h_max) |h| {
                        const actual_x = x + h;
                        const actual_y = y + v;

                        var tmp_block: [64]i32 = undefined;
                        const in_bounds = (actual_y < state.block_height and actual_x < state.block_width);
                        const block_ptr: *[64]i32 = if (in_bounds)
                            &state.block_storage.?[actual_y * state.block_width_actual + actual_x][component_index]
                        else
                            &tmp_block;

                        // Ensure we have enough bits buffered; helps when resuming after markers
                        _ = state.bit_reader.fillBits(24) catch {};

                        // Decode block directly into storage using the baseline path
                        try decodeBlockBaseline(state, scan_comp, block_ptr, &prediction_values[component_index]);
                    }
                }
            }

            // Count one MCU completed (one position in interleaved grid)
            mcus_since_restart += 1;
        }
    }
}

// Decode a single block directly into block storage (from master)
fn decodeBlockToStorage(state: *JpegState, scan_comp: ScanComponent, block: *[64]i32, dc_prediction: *i32) !void {
    // Clear the block
    @memset(block, 0);

    // Decode DC coefficient
    const dc_table = state.dc_tables[scan_comp.dc_table_id] orelse return error.MissingHuffmanTable;
    const dc_symbol = try state.decodeHuffmanSymbol(&dc_table);

    if (dc_symbol > 11) return error.InvalidDCCoefficient;

    var dc_diff: i32 = 0;
    if (dc_symbol > 0) {
        const dc_bits = try state.bit_reader.getBits(@intCast(dc_symbol));
        dc_diff = @intCast(dc_bits);

        // Convert from unsigned to signed
        if (dc_bits < (@as(u32, 1) << @intCast(dc_symbol - 1))) {
            dc_diff = @as(i32, @intCast(dc_bits)) - @as(i32, @intCast((@as(u32, 1) << @intCast(dc_symbol)) - 1));
        }
    }

    dc_prediction.* += dc_diff;
    block[0] = dc_prediction.*;

    // Decode AC coefficients
    const ac_table = state.ac_tables[scan_comp.ac_table_id] orelse return error.MissingHuffmanTable;
    var k: usize = 1;

    while (k < 64) {
        const ac_symbol = try state.decodeHuffmanSymbol(&ac_table);

        if (ac_symbol == 0x00) {
            // End of block
            break;
        }

        if (ac_symbol == 0xF0) {
            // ZRL - 16 zeros
            k += 16;
            continue;
        }

        const zero_run = ac_symbol >> 4;
        const coeff_bits = ac_symbol & 0x0F;

        if (coeff_bits == 0) return error.InvalidACCoefficient;

        k += zero_run;
        if (k >= 64) break;

        const ac_bits = try state.bit_reader.getBits(@intCast(coeff_bits));
        var ac_value: i32 = @intCast(ac_bits);

        // Convert from unsigned to signed
        if (ac_bits < (@as(u32, 1) << @intCast(coeff_bits - 1))) {
            ac_value = @as(i32, @intCast(ac_bits)) - @as(i32, @intCast((@as(u32, 1) << @intCast(coeff_bits)) - 1));
        }

        block[zigzag[k]] = ac_value;
        k += 1;
    }
}

// Dequantize all blocks in storage
fn dequantizeAllBlocks(state: *JpegState) !void {
    if (state.block_storage == null) return error.BlockStorageNotAllocated;

    // Apply dequantization to all blocks
    for (state.block_storage.?) |*block_set| {
        for (state.components[0..state.num_components], 0..) |comp, comp_idx| {
            const quant_table = state.quant_tables[comp.quant_table_id] orelse return error.MissingQuantTable;

            for (0..64) |i| {
                block_set[comp_idx][i] *= @as(i32, @intCast(quant_table[i]));
            }
        }
    }
}

// Apply IDCT to all blocks in storage
fn idctAllBlocks(state: *JpegState) void {
    if (state.block_storage == null) return;

    // Apply IDCT to all blocks
    for (state.block_storage.?) |*block_set| {
        for (0..state.num_components) |comp_idx| {
            idct8x8(&block_set[comp_idx]);

            // Apply level shift (+128) only to Y component (component 0) - master's approach
            // Cb and Cr components stay centered around 0
            if (comp_idx == 0) {
                for (0..64) |i| {
                    block_set[comp_idx][i] += 128;
                }
            }
        }
    }
}

// Upsample chroma for a specific Y block within an MCU
fn upsampleChromaForBlock(state: *JpegState, mcu_col: usize, mcu_row: usize, h_offset: usize, v_offset: usize, max_h: u4, max_v: u4, cb_out: *[64]i32, cr_out: *[64]i32) void {

    // For 4:2:0, we need to interpolate from the 2x2 pixel grid at the MCU level to 8x8 for each Y block
    // The h_offset and v_offset tell us which quadrant of the MCU we're in

    // Get the chroma block for this MCU
    const chroma_y = mcu_row * max_v;
    const chroma_x = mcu_col * max_h;
    if (chroma_y >= state.block_height or chroma_x >= state.block_width) {
        @memset(cb_out, 0);
        @memset(cr_out, 0);
        return;
    }

    const chroma_block_index = chroma_y * state.block_width_actual + chroma_x;
    const cb_block = &state.block_storage.?[chroma_block_index][1];
    const cr_block = &state.block_storage.?[chroma_block_index][2];

    // For 4:2:0 with 2x2 Y blocks per MCU, we need to map the 8x8 chroma to each 8x8 Y block
    // Each Y block gets a quarter of the chroma samples, interpolated
    if (max_h == 2 and max_v == 2) {
        // Calculate which 4x4 region of the chroma block maps to this Y block
        const chroma_offset_x = h_offset * 4;
        const chroma_offset_y = v_offset * 4;

        // Simple approach: replicate the 4x4 chroma region to fill the 8x8 Y block
        for (0..8) |y| {
            for (0..8) |x| {
                // Map to the 4x4 region in the original 8x8 chroma block
                const src_y = chroma_offset_y + (y / 2);
                const src_x = chroma_offset_x + (x / 2);
                const src_idx = src_y * 8 + src_x;
                const dst_idx = y * 8 + x;

                cb_out[dst_idx] = cb_block[src_idx];
                cr_out[dst_idx] = cr_block[src_idx];
            }
        }
    } else {
        // For other subsampling ratios, just copy the chroma block
        @memcpy(cb_out, cb_block);
        @memcpy(cr_out, cr_block);
    }
}

// Convert YCbCr blocks to RGB with proper 4:2:0 chroma upsampling
fn ycbcrToRgbAllBlocks(state: *JpegState) !void {
    if (state.block_storage == null) return error.BlockStorageNotAllocated;

    if (state.num_components == 1) {
        // Grayscale - blocks already level-shifted in IDCT
        for (state.block_storage.?, 0..) |*block_set, idx| {
            for (0..64) |i| {
                const y_val = block_set[0][i];
                const rgb_val: u8 = @intCast(std.math.clamp(y_val, 0, 255));
                state.rgb_storage.?[idx][0][i] = rgb_val; // R
                state.rgb_storage.?[idx][1][i] = rgb_val; // G
                state.rgb_storage.?[idx][2][i] = rgb_val; // B
            }
        }
        return;
    }

    // Check chroma subsampling mode
    const max_h = state.components[0].h_sampling;
    const max_v = state.components[0].v_sampling;

    // 4:4:4 - no chroma subsampling, each component has same number of blocks
    if (max_h == 1 and max_v == 1) {
        for (state.block_storage.?, 0..) |*block_set, idx| {
            // Direct YCbCr to RGB conversion without upsampling
            for (0..64) |i| {
                const Y = block_set[0][i];
                const Cb = block_set[1][i];
                const Cr = block_set[2][i];

                const ycbcr: Ycbcr = .{
                    .y = @intCast(@min(255, @max(0, Y))),
                    .cb = @intCast(@min(255, @max(0, Cb + 128))),
                    .cr = @intCast(@min(255, @max(0, Cr + 128))),
                };
                const rgb = ycbcr.to(.rgb);

                state.rgb_storage.?[idx][0][i] = rgb.r;
                state.rgb_storage.?[idx][1][i] = rgb.g;
                state.rgb_storage.?[idx][2][i] = rgb.b;
            }
        }
        return;
    }

    // 4:2:2 - horizontal chroma subsampling only
    if (max_h == 2 and max_v == 1) {
        var mcu_y: usize = 0;
        while (mcu_y < state.block_height) : (mcu_y += 1) {
            var mcu_x: usize = 0;
            while (mcu_x < state.block_width) : (mcu_x += 2) {
                const chroma_block_index = mcu_y * state.block_width_actual + mcu_x;

                // Process the 2 Y blocks in this MCU
                for (0..2) |h| {
                    const y_block_x = mcu_x + h;
                    if (y_block_x >= state.block_width) continue;

                    const y_block_index = mcu_y * state.block_width_actual + y_block_x;

                    for (0..64) |pixel_idx| {
                        const py = pixel_idx / 8;
                        const px = pixel_idx % 8;

                        const Y = state.block_storage.?[y_block_index][0][pixel_idx];

                        // Horizontal interpolation for chroma
                        const chroma_x_f = (@as(f32, @floatFromInt(h * 8 + px)) + 0.5) * 0.5 - 0.5;
                        const cx0 = @max(0, @min(7, @as(i32, @intFromFloat(@floor(chroma_x_f)))));
                        const cx1 = @min(7, cx0 + 1);
                        const fx = chroma_x_f - @as(f32, @floatFromInt(cx0));

                        const chroma_idx = py * 8 + @as(usize, @intCast(cx0));
                        const chroma_idx_next = py * 8 + @as(usize, @intCast(cx1));

                        const cb0 = @as(f32, @floatFromInt(state.block_storage.?[chroma_block_index][1][chroma_idx]));
                        const cb1 = @as(f32, @floatFromInt(state.block_storage.?[chroma_block_index][1][chroma_idx_next]));
                        const Cb = @as(i32, @intFromFloat(@round(std.math.lerp(cb0, cb1, fx))));

                        const cr0 = @as(f32, @floatFromInt(state.block_storage.?[chroma_block_index][2][chroma_idx]));
                        const cr1 = @as(f32, @floatFromInt(state.block_storage.?[chroma_block_index][2][chroma_idx_next]));
                        const Cr = @as(i32, @intFromFloat(@round(std.math.lerp(cr0, cr1, fx))));

                        const ycbcr: Ycbcr = .{
                            .y = @intCast(@min(255, @max(0, Y))),
                            .cb = @intCast(@min(255, @max(0, Cb + 128))),
                            .cr = @intCast(@min(255, @max(0, Cr + 128))),
                        };
                        const rgb = ycbcr.to(.rgb);

                        state.rgb_storage.?[y_block_index][0][pixel_idx] = rgb.r;
                        state.rgb_storage.?[y_block_index][1][pixel_idx] = rgb.g;
                        state.rgb_storage.?[y_block_index][2][pixel_idx] = rgb.b;
                    }
                }
            }
        }
        return;
    }

    // 4:1:1 - 4:1 horizontal chroma subsampling
    if (max_h == 4 and max_v == 1) {
        var mcu_y: usize = 0;
        while (mcu_y < state.block_height) : (mcu_y += 1) {
            var mcu_x: usize = 0;
            while (mcu_x < state.block_width) : (mcu_x += 4) {
                const chroma_block_index = mcu_y * state.block_width_actual + mcu_x;

                // Process the 4 Y blocks in this MCU
                for (0..4) |h| {
                    const y_block_x = mcu_x + h;
                    if (y_block_x >= state.block_width) continue;

                    const y_block_index = mcu_y * state.block_width_actual + y_block_x;

                    for (0..64) |pixel_idx| {
                        const py = pixel_idx / 8;
                        const px = pixel_idx % 8;

                        const Y = state.block_storage.?[y_block_index][0][pixel_idx];

                        // Horizontal interpolation for 4:1 chroma
                        const chroma_x_f = (@as(f32, @floatFromInt(h * 8 + px)) + 0.5) * 0.25 - 0.5;
                        const cx0 = @max(0, @min(7, @as(i32, @intFromFloat(@floor(chroma_x_f)))));
                        const cx1 = @min(7, cx0 + 1);
                        const fx = chroma_x_f - @as(f32, @floatFromInt(cx0));

                        const chroma_idx = py * 8 + @as(usize, @intCast(cx0));
                        const chroma_idx_next = py * 8 + @as(usize, @intCast(cx1));

                        const cb0 = @as(f32, @floatFromInt(state.block_storage.?[chroma_block_index][1][chroma_idx]));
                        const cb1 = @as(f32, @floatFromInt(state.block_storage.?[chroma_block_index][1][chroma_idx_next]));
                        const Cb = @as(i32, @intFromFloat(@round(std.math.lerp(cb0, cb1, fx))));

                        const cr0 = @as(f32, @floatFromInt(state.block_storage.?[chroma_block_index][2][chroma_idx]));
                        const cr1 = @as(f32, @floatFromInt(state.block_storage.?[chroma_block_index][2][chroma_idx_next]));
                        const Cr = @as(i32, @intFromFloat(@round(std.math.lerp(cr0, cr1, fx))));

                        const ycbcr: Ycbcr = .{
                            .y = @intCast(@min(255, @max(0, Y))),
                            .cb = @intCast(@min(255, @max(0, Cb + 128))),
                            .cr = @intCast(@min(255, @max(0, Cr + 128))),
                        };
                        const rgb = ycbcr.to(.rgb);

                        state.rgb_storage.?[y_block_index][0][pixel_idx] = rgb.r;
                        state.rgb_storage.?[y_block_index][1][pixel_idx] = rgb.g;
                        state.rgb_storage.?[y_block_index][2][pixel_idx] = rgb.b;
                    }
                }
            }
        }
        return;
    }

    // 4:2:0 chroma subsampling (both horizontal and vertical)
    // Process in MCU units
    var mcu_y: usize = 0;
    while (mcu_y < state.block_height) : (mcu_y += max_v) {
        var mcu_x: usize = 0;
        while (mcu_x < state.block_width) : (mcu_x += max_h) {
            // Get the chroma block (stored at MCU origin)
            const chroma_block_index = mcu_y * state.block_width_actual + mcu_x;

            // Process each Y block in this MCU
            for (0..max_v) |v| {
                for (0..max_h) |h| {
                    const y_block_y = mcu_y + v;
                    const y_block_x = mcu_x + h;

                    if (y_block_y >= state.block_height or y_block_x >= state.block_width) continue;

                    const y_block_index = y_block_y * state.block_width_actual + y_block_x;

                    // Convert this Y block using upsampled chroma
                    for (0..64) |pixel_idx| {
                        const py = pixel_idx / 8;
                        const px = pixel_idx % 8;

                        const Y = state.block_storage.?[y_block_index][0][pixel_idx];

                        // Bilinear interpolation for chroma upsampling
                        const chroma_y_f = (@as(f32, @floatFromInt(v * 8 + py)) + 0.5) * 0.5 - 0.5;
                        const chroma_x_f = (@as(f32, @floatFromInt(h * 8 + px)) + 0.5) * 0.5 - 0.5;

                        const cy0 = @max(0, @min(7, @as(i32, @intFromFloat(@floor(chroma_y_f)))));
                        const cx0 = @max(0, @min(7, @as(i32, @intFromFloat(@floor(chroma_x_f)))));
                        const cy1 = @min(7, cy0 + 1);
                        const cx1 = @min(7, cx0 + 1);

                        const fy = chroma_y_f - @as(f32, @floatFromInt(cy0));
                        const fx = chroma_x_f - @as(f32, @floatFromInt(cx0));

                        // Get the four surrounding chroma values for Cb
                        const cb00 = @as(f32, @floatFromInt(state.block_storage.?[chroma_block_index][1][@as(usize, @intCast(cy0)) * 8 + @as(usize, @intCast(cx0))]));
                        const cb10 = @as(f32, @floatFromInt(state.block_storage.?[chroma_block_index][1][@as(usize, @intCast(cy0)) * 8 + @as(usize, @intCast(cx1))]));
                        const cb01 = @as(f32, @floatFromInt(state.block_storage.?[chroma_block_index][1][@as(usize, @intCast(cy1)) * 8 + @as(usize, @intCast(cx0))]));
                        const cb11 = @as(f32, @floatFromInt(state.block_storage.?[chroma_block_index][1][@as(usize, @intCast(cy1)) * 8 + @as(usize, @intCast(cx1))]));

                        // Get the four surrounding chroma values for Cr
                        const cr00 = @as(f32, @floatFromInt(state.block_storage.?[chroma_block_index][2][@as(usize, @intCast(cy0)) * 8 + @as(usize, @intCast(cx0))]));
                        const cr10 = @as(f32, @floatFromInt(state.block_storage.?[chroma_block_index][2][@as(usize, @intCast(cy0)) * 8 + @as(usize, @intCast(cx1))]));
                        const cr01 = @as(f32, @floatFromInt(state.block_storage.?[chroma_block_index][2][@as(usize, @intCast(cy1)) * 8 + @as(usize, @intCast(cx0))]));
                        const cr11 = @as(f32, @floatFromInt(state.block_storage.?[chroma_block_index][2][@as(usize, @intCast(cy1)) * 8 + @as(usize, @intCast(cx1))]));

                        // Bilinear interpolation
                        const cb_interp_x0 = std.math.lerp(cb00, cb10, fx);
                        const cb_interp_x1 = std.math.lerp(cb01, cb11, fx);
                        const Cb = @as(i32, @intFromFloat(@round(std.math.lerp(cb_interp_x0, cb_interp_x1, fy))));

                        const cr_interp_x0 = std.math.lerp(cr00, cr10, fx);
                        const cr_interp_x1 = std.math.lerp(cr01, cr11, fx);
                        const Cr = @as(i32, @intFromFloat(@round(std.math.lerp(cr_interp_x0, cr_interp_x1, fy))));

                        const ycbcr: Ycbcr = .{
                            .y = @intCast(@min(255, @max(0, Y))),
                            .cb = @intCast(@min(255, @max(0, Cb + 128))),
                            .cr = @intCast(@min(255, @max(0, Cr + 128))),
                        };
                        const rgb = ycbcr.to(.rgb);

                        // Store RGB in separate storage to avoid overwriting chroma data
                        state.rgb_storage.?[y_block_index][0][pixel_idx] = rgb.r;
                        state.rgb_storage.?[y_block_index][1][pixel_idx] = rgb.g;
                        state.rgb_storage.?[y_block_index][2][pixel_idx] = rgb.b;
                    }
                }
            }
        }
    }
}

// Render RGB blocks to pixels (simple after YCbCr conversion)
fn renderRgbBlocksToPixels(comptime T: type, state: *JpegState, img: *Image(T)) !void {
    if (state.rgb_storage == null) return error.RgbStorageNotAllocated;

    // Simple rendering - read from RGB storage
    var block_y: usize = 0;
    while (block_y < state.block_height) : (block_y += 1) {
        const pixel_y = block_y * 8;

        var block_x: usize = 0;
        while (block_x < state.block_width) : (block_x += 1) {
            const block_index = block_y * state.block_width_actual + block_x;
            const pixel_x = block_x * 8;

            for (0..8) |y| {
                for (0..8) |x| {
                    if (pixel_y + y >= state.height or pixel_x + x >= state.width) {
                        continue;
                    }

                    const pixel_idx = y * 8 + x;
                    const r = state.rgb_storage.?[block_index][0][pixel_idx];
                    const g = state.rgb_storage.?[block_index][1][pixel_idx];
                    const b = state.rgb_storage.?[block_index][2][pixel_idx];

                    const rgb = Rgb{ .r = r, .g = g, .b = b };
                    img.at(pixel_y + y, pixel_x + x).* = convertColor(T, rgb);
                }
            }
        }
    }
}

/// Load JPEG file from disk and decode to specified pixel type.
/// Supports baseline DCT (SOF0) and progressive DCT (SOF2) JPEG formats.
/// Handles grayscale (1 component) and YCbCr color (3 components) with 4:4:4, 4:2:2, 4:1:1, and 4:2:0 chroma subsampling.
///
/// Parameters:
/// - T: Desired output pixel type (u8, Rgb, etc.) - color conversion applied if needed
/// - allocator: Memory allocator for image data
/// - file_path: Path to JPEG file
/// Convert JPEG state data to its most natural Zignal Image type.
/// Returns grayscale for single-component JPEGs, RGB for color JPEGs.
pub fn toNativeImage(allocator: Allocator, state: *JpegState) !union(enum) {
    grayscale: Image(u8),
    rgb: Image(Rgb),
} {
    // Complete block-based pipeline:
    // Step 1: Decode all blocks into storage (storage allocated during parseSOF)
    // For baseline JPEG, decode blocks here. For progressive, decode() already did it.
    if (state.frame_type == .baseline) {
        try performBlockScan(state);
    }

    // Step 2: Apply dequantization to all blocks
    try dequantizeAllBlocks(state);

    // Step 3: Apply IDCT to all blocks
    idctAllBlocks(state);

    // Step 4: Convert YCbCr to RGB with proper chroma upsampling (RGB storage allocated during parseSOF)
    try ycbcrToRgbAllBlocks(state);

    // Step 5: Create appropriate image type based on component count
    if (state.num_components == 1) {
        // Grayscale
        var img = try Image(u8).init(allocator, state.height, state.width);
        errdefer img.deinit(allocator);
        try renderRgbBlocksToPixels(u8, state, &img);
        return .{ .grayscale = img };
    } else {
        // Color (RGB)
        var img = try Image(Rgb).init(allocator, state.height, state.width);
        errdefer img.deinit(allocator);
        try renderRgbBlocksToPixels(Rgb, state, &img);
        return .{ .rgb = img };
    }
}

///
/// Returns: Decoded Image(T) with automatic color space conversion from source format
///
/// Errors: InvalidJpegFile, UnsupportedJpegFormat, OutOfMemory, and various JPEG parsing errors
pub fn loadFromBytes(comptime T: type, allocator: Allocator, data: []const u8, limits: DecodeLimits) !Image(T) {
    var state = try decode(allocator, data, limits);
    defer state.deinit();

    // Load the JPEG in its native format first, then convert to requested type
    var native_image = try toNativeImage(allocator, &state);
    switch (native_image) {
        .grayscale => |*img| {
            if (T == u8) {
                // Direct return without conversion - no extra allocation needed
                return img.*;
            } else {
                defer img.deinit(allocator);
                return img.convert(T, allocator);
            }
        },
        .rgb => |*img| {
            if (T == Rgb) {
                // Direct return without conversion - no extra allocation needed
                return img.*;
            } else {
                defer img.deinit(allocator);
                return img.convert(T, allocator);
            }
        },
    }
}

pub fn load(comptime T: type, allocator: Allocator, file_path: []const u8, limits: DecodeLimits) !Image(T) {
    const read_limit = if (limits.max_jpeg_bytes == 0) std.math.maxInt(usize) else limits.max_jpeg_bytes;
    const jpeg_data = try std.fs.cwd().readFileAlloc(file_path, allocator, .limited(read_limit));
    defer allocator.free(jpeg_data);
    return loadFromBytes(T, allocator, jpeg_data, limits);
}

test "JPEG encode -> decode RGB roundtrip" {
    const gpa = std.testing.allocator;

    var img = try Image(Rgb).init(gpa, 16, 16);
    defer img.deinit(gpa);
    for (0..img.rows) |y| {
        for (0..img.cols) |x| {
            const r: u8 = @intCast((x * 255) / (img.cols - 1));
            const g: u8 = @intCast((y * 255) / (img.rows - 1));
            const b: u8 = @intCast(((x + y) * 255) / (img.cols + img.rows - 2));
            img.at(y, x).* = .{ .r = r, .g = g, .b = b };
        }
    }

    const bytes = try encode(Rgb, gpa, img, .{ .quality = 85 });
    defer gpa.free(bytes);

    var state = try decode(gpa, bytes, .{});
    defer state.deinit();
    if (state.frame_type == .baseline) try performBlockScan(&state);
    try dequantizeAllBlocks(&state);
    idctAllBlocks(&state);
    try ycbcrToRgbAllBlocks(&state);
    var out = try Image(Rgb).init(gpa, state.height, state.width);
    defer out.deinit(gpa);
    try renderRgbBlocksToPixels(Rgb, &state, &out);

    const ps = try img.psnr(out);
    try std.testing.expect(ps > 40.0);
}

test "JPEG encode -> decode grayscale roundtrip" {
    const gpa = std.testing.allocator;
    var img = try Image(u8).init(gpa, 16, 16);
    defer img.deinit(gpa);
    for (0..img.rows) |y| {
        for (0..img.cols) |x| {
            img.at(y, x).* = @intCast(((x + y) * 255) / (img.cols + img.rows - 2));
        }
    }
    const bytes = try encode(u8, gpa, img, .{ .quality = 85 });
    defer gpa.free(bytes);

    var state = try decode(gpa, bytes, .{});
    defer state.deinit();
    if (state.frame_type == .baseline) try performBlockScan(&state);
    try dequantizeAllBlocks(&state);
    idctAllBlocks(&state);
    try ycbcrToRgbAllBlocks(&state);
    var out = try Image(Rgb).init(gpa, state.height, state.width);
    defer out.deinit(gpa);
    try renderRgbBlocksToPixels(Rgb, &state, &out);

    // Convert original gray to RGB for PSNR
    var gray_rgb = try img.convert(Rgb, gpa);
    defer gray_rgb.deinit(gpa);
    const ps = try gray_rgb.psnr(out);
    try std.testing.expect(ps > 45);
}

test "JPEG subsampling 4:2:2 roundtrip" {
    const gpa = std.testing.allocator;

    // Non-multiple-of-MCU dimensions to exercise padding
    const rows: usize = 19;
    const cols: usize = 25;

    var img = try Image(Rgb).init(gpa, rows, cols);
    defer img.deinit(gpa);
    for (0..rows) |y| {
        for (0..cols) |x| {
            const r: u8 = @intCast((x * 255) / (cols - 1));
            const g: u8 = @intCast((y * 255) / (rows - 1));
            const b: u8 = @intCast(((x * y) * 255) / ((cols - 1) * (rows - 1))); // mild cross term
            img.at(y, x).* = .{ .r = r, .g = g, .b = b };
        }
    }

    const bytes = try encode(Rgb, gpa, img, .{ .quality = 85, .subsampling = .yuv422 });
    defer gpa.free(bytes);

    var state = try decode(gpa, bytes, .{});
    defer state.deinit();
    if (state.frame_type == .baseline) try performBlockScan(&state);
    try dequantizeAllBlocks(&state);
    idctAllBlocks(&state);
    try ycbcrToRgbAllBlocks(&state);
    var out = try Image(Rgb).init(gpa, state.height, state.width);
    defer out.deinit(gpa);
    try renderRgbBlocksToPixels(Rgb, &state, &out);

    const ps = try img.psnr(out);
    try std.testing.expect(ps > 40);
}

test "JPEG subsampling 4:2:0 roundtrip" {
    const gpa = std.testing.allocator;

    // Non-multiple-of-MCU dimensions (MCU is 16x16 for 4:2:0)
    const rows: usize = 64;
    const cols: usize = 48;

    var img = try Image(Rgb).init(gpa, rows, cols);
    defer img.deinit(gpa);
    for (0..rows) |y| {
        for (0..cols) |x| {
            const r: u8 = @intCast((x * 255) / (cols - 1));
            const g: u8 = @intCast((y * 255) / (rows - 1));
            const b: u8 = @intCast(((x + 2 * y) * 255) / (cols - 1 + 2 * (rows - 1)));
            img.at(y, x).* = .{ .r = r, .g = g, .b = b };
        }
    }

    const bytes = try encode(Rgb, gpa, img, .{ .quality = 92, .subsampling = .yuv420 });
    defer gpa.free(bytes);

    var state = try decode(gpa, bytes, .{});
    defer state.deinit();
    if (state.frame_type == .baseline) try performBlockScan(&state);
    try dequantizeAllBlocks(&state);
    idctAllBlocks(&state);
    try ycbcrToRgbAllBlocks(&state);
    var out = try Image(Rgb).init(gpa, state.height, state.width);
    defer out.deinit(gpa);
    try renderRgbBlocksToPixels(Rgb, &state, &out);

    const ps = try img.psnr(out);
    try std.testing.expect(ps > 45);
}

test "JPEG 4:2:0 odd-size roundtrip (non-multiple-of-MCU)" {
    const gpa = std.testing.allocator;

    // Choose dimensions that are not multiples of 16 to force partial MCUs on both axes
    const rows: usize = 37; // not multiple of 16
    const cols: usize = 53; // not multiple of 16

    var img = try Image(Rgb).init(gpa, rows, cols);
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

    const bytes = try encode(Rgb, gpa, img, .{ .quality = 85, .subsampling = .yuv420 });
    defer gpa.free(bytes);

    var state = try decode(gpa, bytes, .{});
    defer state.deinit();
    if (state.frame_type == .baseline) try performBlockScan(&state);
    try dequantizeAllBlocks(&state);
    idctAllBlocks(&state);
    try ycbcrToRgbAllBlocks(&state);
    var out = try Image(Rgb).init(gpa, state.height, state.width);
    defer out.deinit(gpa);
    try renderRgbBlocksToPixels(Rgb, &state, &out);

    // We expect a decent reconstruction quality even with 4:2:0 on odd dimensions.
    const ps = try img.psnr(out);
    try std.testing.expect(ps > 35.0);
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
    var state = JpegState.init(std.testing.allocator);
    defer state.deinit();

    const sof_data = [_]u8{ 0x08, 0x00, 0x10, 0x00, 0x10, 0x01, 0x01, 0x11, 0x00 };
    const limits: DecodeLimits = .{ .max_blocks = 1 };
    const result = state.parseSOF(&sof_data, .baseline, limits);
    try std.testing.expectError(error.BlockMemoryLimitExceeded, result);
}

// Basic tests
test "JPEG marker parsing" {
    const testing = std.testing;

    // Test marker conversion
    const soi_bytes = [2]u8{ 0xFF, 0xD8 };
    const soi = Marker.fromBytes(soi_bytes);
    try testing.expect(soi == .SOI);

    const sof0_bytes = [2]u8{ 0xFF, 0xC0 };
    const sof0 = Marker.fromBytes(sof0_bytes);
    try testing.expect(sof0 == .SOF0);
}

test "BitReader basic operations" {
    const testing = std.testing;

    const data = [_]u8{ 0b10110011, 0b01010101 };
    var reader = BitReader.init(&data);

    // Read first 4 bits
    const bits1 = try reader.getBits(4);
    try testing.expectEqual(@as(u16, 0b1011), bits1);

    // Read next 4 bits
    const bits2 = try reader.getBits(4);
    try testing.expectEqual(@as(u16, 0b0011), bits2);

    // Read next 8 bits
    const bits3 = try reader.getBits(8);
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
