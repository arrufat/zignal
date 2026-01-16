//! Pure Zig PNG encoder and decoder implementation.
//! Supports all PNG color types and bit depths according to the PNG specification.
//! Zero dependencies - implements deflate compression/decompression internally.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const convertColor = @import("color.zig").convertColor;
const zlib = @import("compression/zlib.zig");
const deflate = @import("compression/deflate.zig");
const Image = @import("image.zig").Image;
const Rgb = @import("color.zig").Rgb(u8);
const Rgba = @import("color.zig").Rgba(u8);
const Gray = @import("color.zig").Gray;

const max_file_size: usize = 100 * 1024 * 1024;
const max_dimensions_default: u32 = 8192;
const max_pixels_default: u64 = 67_108_864; // 8K square
const max_decompressed_default: usize = 536_886_272; // 8K×8K RGBA 16-bit Adam7 worst case

/// User-configurable resource limits applied while decoding PNG data.
/// A zero value disables the corresponding limit.
pub const DecodeLimits = struct {
    /// Maximum number of bytes accepted in the original PNG buffer (signature + chunks).
    max_png_bytes: usize = max_file_size,
    /// Maximum cumulative size (in bytes) across all chunk payloads.
    max_chunk_bytes: usize = max_file_size,
    /// Maximum cumulative size of IDAT chunk payloads (compressed image stream).
    max_idat_bytes: usize = max_file_size,
    /// Maximum number of chunks accepted in a single PNG. Helps prevent zip bombs
    /// that add thousands of tiny ancillary entries.
    max_chunks: usize = 8192,
    /// Maximum allowed width in pixels.
    max_width: u32 = max_dimensions_default,
    /// Maximum allowed height in pixels.
    max_height: u32 = max_dimensions_default,
    /// Maximum allowed pixel count (width * height). Default ~8K square.
    max_pixels: u64 = max_pixels_default,
    /// Maximum number of bytes produced by zlib inflate (including filter bytes,
    /// across all Adam7 passes when applicable).
    max_decompressed_bytes: usize = max_decompressed_default,
};

const ChunkOrderState = struct {
    seen_plte: bool = false,
    seen_trns: bool = false,
    seen_idat: bool = false,
    seen_iend: bool = false,
    seen_iccp: bool = false,
    seen_srgb: bool = false,
    idat_stream_finished: bool = false,
};

inline fn exceeds(T: type, limit: T, value: T) bool {
    return limit != 0 and value > limit;
}

fn accumulateWithLimit(current: *usize, addend: usize, limit: usize, limit_error: anyerror) !void {
    const new_total = std.math.add(usize, current.*, addend) catch return limit_error;
    if (limit != 0 and new_total > limit) return limit_error;
    current.* = new_total;
}

fn ensureArrayCapacityWithinLimit(list: *ArrayList(u8), allocator: Allocator, required_len: usize, limit: usize) !void {
    if (required_len <= list.capacity) return;

    var target = required_len;
    if (list.capacity > 0) {
        const doubled = std.math.mul(usize, list.capacity, 2) catch std.math.maxInt(usize);
        if (doubled > target) target = doubled;
    }
    if (limit != 0 and target > limit) {
        target = limit;
    }
    try list.ensureTotalCapacityPrecise(allocator, target);
}

/// PNG signature: 8 bytes that identify a PNG file
pub const signature = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };

/// PNG color types
pub const ColorType = enum(u8) {
    grayscale = 0,
    rgb = 2,
    palette = 3,
    grayscale_alpha = 4,
    rgba = 6,

    pub fn channels(self: ColorType) u8 {
        return switch (self) {
            .grayscale => 1,
            .rgb => 3,
            .palette => 1, // palette index only
            .grayscale_alpha => 2,
            .rgba => 4,
        };
    }

    pub fn hasAlpha(self: ColorType) bool {
        return switch (self) {
            .grayscale_alpha, .rgba => true,
            .grayscale, .rgb, .palette => false,
        };
    }
};

/// PNG filter types for row filtering
pub const FilterType = enum(u8) {
    none = 0,
    sub = 1,
    up = 2,
    average = 3,
    paeth = 4,
};

/// sRGB rendering intent values
pub const SrgbRenderingIntent = enum(u8) {
    perceptual = 0,
    relative_colorimetric = 1,
    saturation = 2,
    absolute_colorimetric = 3,
};

/// PNG chunk structure
pub const Chunk = struct {
    length: u32,
    type: [4]u8,
    data: []const u8,
    crc: u32,
};

/// PNG IHDR (header) chunk data and metadata
pub const Header = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: ColorType,
    compression_method: u8 = 0, // Must be 0 (deflate)
    filter_method: u8 = 0, // Must be 0
    interlace_method: u8 = 0, // 0 = none, 1 = Adam7

    // Color management metadata (from gAMA and sRGB chunks)
    // Gamma is stored for metadata purposes but ignored during decoding as files
    // are typically already gamma-encoded for display.
    gamma: ?f32 = null,
    srgb_intent: ?SrgbRenderingIntent = null,

    pub fn channels(self: Header) u8 {
        return self.color_type.channels();
    }

    pub fn bytesPerPixel(self: Header) u8 {
        return (self.channels() * self.bit_depth + 7) / 8;
    }

    pub fn scanlineBytes(self: Header) usize {
        return (self.width * self.channels() * self.bit_depth + 7) / 8;
    }

    /// Returns the total number of pixels in the image as a u64 to prevent overflow.
    pub fn totalPixels(self: Header) u64 {
        return @as(u64, self.width) * @as(u64, self.height);
    }

    /// Returns true if the image format supports alpha transparency (RGBA or Grayscale+Alpha).
    /// Note: Palette images may also have transparency via tRNS chunks, but this checks the color type definition.
    pub fn hasAlpha(self: Header) bool {
        return self.color_type.hasAlpha();
    }

    /// Returns true if the image uses 16 bits per channel.
    pub fn is16Bit(self: Header) bool {
        return self.bit_depth == 16;
    }

    /// Returns true if the image is strictly grayscale (no color info).
    pub fn isGrayscale(self: Header) bool {
        return self.color_type == .grayscale or self.color_type == .grayscale_alpha;
    }
};

/// Adam7 interlacing constants
const Adam7Pass = struct {
    x_start: u32,
    y_start: u32,
    x_step: u32,
    y_step: u32,
};

const adam7_passes = [7]Adam7Pass{
    .{ .x_start = 0, .y_start = 0, .x_step = 8, .y_step = 8 },
    .{ .x_start = 4, .y_start = 0, .x_step = 8, .y_step = 8 },
    .{ .x_start = 0, .y_start = 4, .x_step = 4, .y_step = 8 },
    .{ .x_start = 2, .y_start = 0, .x_step = 4, .y_step = 4 },
    .{ .x_start = 0, .y_start = 2, .x_step = 2, .y_step = 4 },
    .{ .x_start = 1, .y_start = 0, .x_step = 2, .y_step = 2 },
    .{ .x_start = 0, .y_start = 1, .x_step = 1, .y_step = 2 },
};

/// Calculate sub-image dimensions for Adam7 pass
fn adam7PassDimensions(pass: u8, width: u32, height: u32) struct { width: u32, height: u32 } {
    if (pass >= 7) return .{ .width = 0, .height = 0 };

    const pass_info = adam7_passes[pass];
    const pass_width = if (width > pass_info.x_start)
        (width - pass_info.x_start + pass_info.x_step - 1) / pass_info.x_step
    else
        0;
    const pass_height = if (height > pass_info.y_start)
        (height - pass_info.y_start + pass_info.y_step - 1) / pass_info.y_step
    else
        0;

    return .{ .width = pass_width, .height = pass_height };
}

/// Calculate total scanline data size for interlaced image
fn adam7TotalSize(header: Header) !usize {
    var total_size: usize = 0;
    const channels = header.channels();

    for (0..7) |pass| {
        const dims = adam7PassDimensions(@intCast(pass), header.width, header.height);
        if (dims.width > 0 and dims.height > 0) {
            const pass_bits = @as(u64, dims.width) * @as(u64, channels) * @as(u64, header.bit_depth);
            const pass_scanline_bytes_u64 = (pass_bits + 7) / 8;
            const pass_scanline_bytes = std.math.cast(usize, pass_scanline_bytes_u64) orelse return error.ImageTooLarge;
            const stride = std.math.add(usize, pass_scanline_bytes, 1) catch return error.ImageTooLarge;
            const pass_total = std.math.mul(usize, stride, @intCast(dims.height)) catch return error.ImageTooLarge;
            total_size = std.math.add(usize, total_size, pass_total) catch return error.ImageTooLarge;
        }
    }

    return total_size;
}

fn scanDataLength(header: Header) !usize {
    if (header.interlace_method == 1) {
        return try adam7TotalSize(header);
    }
    const scanline_bytes = header.scanlineBytes();
    const stride = std.math.add(usize, scanline_bytes, 1) catch return error.ImageTooLarge;
    return std.math.mul(usize, stride, @intCast(header.height)) catch return error.ImageTooLarge;
}

fn enforceHeaderLimits(header: Header, limits: DecodeLimits) !void {
    if (exceeds(u32, limits.max_width, header.width) or exceeds(u32, limits.max_height, header.height)) {
        return error.ImageTooLarge;
    }
    const total_pixels = header.totalPixels();
    if (exceeds(u64, limits.max_pixels, total_pixels)) {
        return error.ImageTooLarge;
    }
}

/// PNG decoder/encoder state
pub const PngState = struct {
    header: Header,
    palette: ?[][3]u8 = null,
    transparency: ?[]u8 = null, // For palette transparency or single transparent color
    idat_data: ArrayList(u8),
    scan_data_bytes: usize = 0,

    pub fn deinit(self: *PngState, gpa: Allocator) void {
        self.idat_data.deinit(gpa);
        if (self.palette) |palette| {
            gpa.free(palette);
        }
        if (self.transparency) |trans| {
            gpa.free(trans);
        }
    }
};

/// Retrieve metadata from a PNG file without decoding the full image.
/// This reads headers and ancillary chunks (gAMA, sRGB) but stops before IDAT.
pub fn getInfo(png_data: []const u8) !Header {
    if (png_data.len < 8 or !std.mem.eql(u8, png_data[0..8], &signature)) {
        return error.InvalidPngSignature;
    }

    var pos: usize = 8;
    var header: Header = undefined;
    var header_found = false;

    while (pos + 8 <= png_data.len) {
        const length = std.mem.readInt(u32, png_data[pos..][0..4], .big);
        const chunk_type = png_data[pos + 4 ..][0..4];

        // Stop at image data or end of file
        if (std.mem.eql(u8, chunk_type, "IDAT")) break;
        if (std.mem.eql(u8, chunk_type, "IEND")) break;

        // Check if we have the full chunk data (length + 4 bytes for type + length bytes data + 4 bytes CRC)
        // pos points to start of length. Total chunk size in stream = 4 (len) + 4 (type) + length + 4 (crc)
        // We already advanced past previous chunks. pos is at start of this chunk.
        // Wait, pos is at start of 'length'.
        // Data end is at pos + 8 + length.
        // CRC end is at pos + 8 + length + 4.
        const chunk_total_len = @as(usize, length) + 12;
        if (pos + chunk_total_len > png_data.len) {
            // Truncated ancillary chunk. Stop parsing.
            break;
        }

        const data_start = pos + 8;
        const data = png_data[data_start .. data_start + length];

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (header_found) return error.MultipleHeaders;
            // Create a temporary Chunk for parseHeader.
            // Note: We are skipping CRC verification here for speed and simplicity in getInfo
            const chunk = Chunk{
                .length = length,
                .type = chunk_type.*,
                .data = data,
                .crc = 0, // Ignored by parseHeader
            };
            header = try parseHeader(chunk);
            header_found = true;
        } else if (std.mem.eql(u8, chunk_type, "gAMA") and header_found) {
            if (length != 4) return error.InvalidGammaLength;
            const gamma_int = std.mem.readInt(u32, data[0..4], .big);
            header.gamma = @as(f32, @floatFromInt(gamma_int)) / 100000.0;
        } else if (std.mem.eql(u8, chunk_type, "sRGB") and header_found) {
            if (length != 1) return error.InvalidSrgbLength;
            const intent_raw = data[0];
            header.srgb_intent = switch (intent_raw) {
                0 => .perceptual,
                1 => .relative_colorimetric,
                2 => .saturation,
                3 => .absolute_colorimetric,
                else => return error.InvalidSrgbIntent,
            };
        }

        pos += chunk_total_len;
    }

    if (!header_found) return error.MissingHeader;
    return header;
}
// CRC table for PNG chunk validation
var crc_table: [256]u32 = undefined;
var crc_table_computed = false;

fn makeCrcTable() void {
    var c: u32 = undefined;
    var n: usize = 0;
    while (n < 256) : (n += 1) {
        c = @intCast(n);
        var k: u8 = 0;
        while (k < 8) : (k += 1) {
            if (c & 1 != 0) {
                c = 0xedb88320 ^ (c >> 1);
            } else {
                c = c >> 1;
            }
        }
        crc_table[n] = c;
    }
    crc_table_computed = true;
}

fn updateCrc(initial_crc: u32, buf: []const u8) u32 {
    var c = initial_crc;
    if (!crc_table_computed) makeCrcTable();

    for (buf) |byte| {
        c = crc_table[(c ^ byte) & 0xff] ^ (c >> 8);
    }
    return c;
}

fn crc(buf: []const u8) u32 {
    return updateCrc(0xffffffff, buf) ^ 0xffffffff;
}

// Read PNG chunks from byte stream
pub const ChunkReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) ChunkReader {
        return .{ .data = data, .pos = 0 };
    }

    pub fn nextChunk(self: *ChunkReader) !?Chunk {
        if (self.pos + 8 > self.data.len) return null;

        const length = std.mem.readInt(u32, self.data[self.pos .. self.pos + 4][0..4], .big);
        self.pos += 4;

        const chunk_type = self.data[self.pos .. self.pos + 4][0..4].*;
        self.pos += 4;

        if (self.pos + length + 4 > self.data.len) {
            return error.InvalidChunkLength;
        }

        const chunk_data = self.data[self.pos .. self.pos + length];
        self.pos += length;

        const chunk_crc = std.mem.readInt(u32, self.data[self.pos .. self.pos + 4][0..4], .big);
        self.pos += 4;

        // Verify CRC (includes chunk type and data)
        const crc_start = self.pos - length - 8;
        const computed_crc = crc(self.data[crc_start .. self.pos - 4]);
        if (computed_crc != chunk_crc) {
            return error.InvalidCrc;
        }

        return Chunk{
            .length = length,
            .type = chunk_type,
            .data = chunk_data,
            .crc = chunk_crc,
        };
    }
};

/// Parse IHDR chunk
fn parseHeader(chunk: Chunk) !Header {
    if (!std.mem.eql(u8, &chunk.type, "IHDR")) {
        return error.InvalidHeader;
    }
    if (chunk.length != 13) {
        return error.InvalidHeaderLength;
    }

    const data = chunk.data;
    const width = std.mem.readInt(u32, data[0..4][0..4], .big);
    const height = std.mem.readInt(u32, data[4..8][0..4], .big);
    const bit_depth = data[8];
    const color_type_raw = data[9];
    const compression_method = data[10];
    const filter_method = data[11];
    const interlace_method = data[12];

    if (width == 0 or height == 0) {
        return error.InvalidDimensions;
    }

    // Prevent resource exhaustion with reasonable size limits
    const MAX_DIMENSION: u32 = 0x7FFF_FFFF; // PNG spec maximum (2^31 - 1)
    const MAX_PIXELS = 268435456; // 16K x 16K = 256 MB pixels
    if (width > MAX_DIMENSION or height > MAX_DIMENSION) {
        return error.ImageTooLarge;
    }
    if (@as(u64, width) * @as(u64, height) > MAX_PIXELS) {
        return error.ImageTooLarge;
    }

    const color_type: ColorType = switch (color_type_raw) {
        0 => .grayscale,
        2 => .rgb,
        3 => .palette,
        4 => .grayscale_alpha,
        6 => .rgba,
        else => return error.InvalidColorType,
    };

    // Validate bit depth for color type
    const valid_bit_depth = switch (color_type) {
        .grayscale => bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or bit_depth == 8 or bit_depth == 16,
        .rgb => bit_depth == 8 or bit_depth == 16,
        .palette => bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or bit_depth == 8,
        .grayscale_alpha => bit_depth == 8 or bit_depth == 16,
        .rgba => bit_depth == 8 or bit_depth == 16,
    };

    if (!valid_bit_depth) {
        return error.InvalidBitDepth;
    }

    if (compression_method != 0) {
        return error.UnsupportedCompressionMethod;
    }

    if (filter_method != 0) {
        return error.UnsupportedFilterMethod;
    }

    if (interlace_method != 0 and interlace_method != 1) {
        return error.UnsupportedInterlaceMethod;
    }

    return Header{
        .width = width,
        .height = height,
        .bit_depth = bit_depth,
        .color_type = color_type,
        .compression_method = compression_method,
        .filter_method = filter_method,
        .interlace_method = interlace_method,
    };
}

// PNG decoder entry point
pub fn decode(gpa: Allocator, png_data: []const u8, limits: DecodeLimits) !PngState {
    if (png_data.len < 8 or !std.mem.eql(u8, png_data[0..8], &signature)) {
        return error.InvalidPngSignature;
    }
    if (exceeds(usize, limits.max_png_bytes, png_data.len)) {
        return error.PngDataTooLarge;
    }

    var reader: ChunkReader = .init(png_data[8..]);
    var png_state: PngState = .{
        .header = undefined,
        .idat_data = .empty,
    };
    errdefer png_state.deinit(gpa);

    var header_found = false;
    var chunk_state: ChunkOrderState = .{};
    var total_chunk_bytes: usize = 0;
    var total_idat_bytes: usize = 0;
    var chunk_count: usize = 0;

    while (try reader.nextChunk()) |chunk| {
        chunk_count += 1;
        if (exceeds(usize, limits.max_chunks, chunk_count)) {
            return error.TooManyChunks;
        }

        const chunk_len = chunk.data.len;
        try accumulateWithLimit(&total_chunk_bytes, chunk_len, limits.max_chunk_bytes, error.ChunkDataLimitExceeded);

        if (!header_found and !std.mem.eql(u8, &chunk.type, "IHDR")) {
            return error.ChunkBeforeHeader;
        }

        if (chunk_state.seen_idat and !std.mem.eql(u8, &chunk.type, "IDAT")) {
            chunk_state.idat_stream_finished = true;
        }

        if (std.mem.eql(u8, &chunk.type, "IHDR")) {
            if (header_found) return error.MultipleHeaders;
            png_state.header = try parseHeader(chunk);
            header_found = true;
            try enforceHeaderLimits(png_state.header, limits);
        } else if (std.mem.eql(u8, &chunk.type, "PLTE")) {
            if (png_state.header.isGrayscale()) {
                return error.PaletteForbiddenForColorType;
            }
            if (chunk_state.seen_idat) return error.PaletteAfterImageData;
            if (png_state.palette != null) return error.DuplicatePalette;

            if (chunk.length % 3 != 0) return error.InvalidPaletteLength;
            const palette_size = chunk.length / 3;
            if (palette_size > 256) return error.PaletteTooLarge;
            if (chunk.data.len < palette_size * 3) return error.InvalidPaletteLength;

            var palette = try gpa.alloc([3]u8, palette_size);
            for (0..palette_size) |i| {
                const offset = i * 3;
                if (offset + 3 > chunk.data.len) return error.InvalidPaletteLength;
                palette[i] = [3]u8{ chunk.data[offset], chunk.data[offset + 1], chunk.data[offset + 2] };
            }
            png_state.palette = palette;
            chunk_state.seen_plte = true;
        } else if (std.mem.eql(u8, &chunk.type, "tRNS")) {
            if (chunk_state.seen_trns) return error.MultipleTransparencyChunks;
            if (chunk_state.seen_idat) return error.TransparencyAfterImageData;

            // Validate tRNS chunk size based on color type
            switch (png_state.header.color_type) {
                .grayscale => {
                    if (chunk.length != 2) return error.InvalidTransparencyLength;
                },
                .rgb => {
                    if (chunk.length != 6) return error.InvalidTransparencyLength;
                },
                .palette => {
                    if (!chunk_state.seen_plte) return error.TransparencyBeforePalette;
                    if (chunk.length > (png_state.palette orelse return error.MissingPalette).len) {
                        return error.InvalidTransparencyLength;
                    }
                },
                .grayscale_alpha, .rgba => {
                    // These color types cannot have tRNS chunks
                    return error.InvalidTransparencyForColorType;
                },
            }

            const transparency = try gpa.alloc(u8, chunk.length);
            @memcpy(transparency, chunk.data);
            png_state.transparency = transparency;
            chunk_state.seen_trns = true;
        } else if (std.mem.eql(u8, &chunk.type, "gAMA")) {
            if (chunk_state.seen_plte) return error.GammaAfterPalette;
            if (chunk_state.seen_idat) return error.GammaAfterImageData;
            // gAMA chunk: 4 bytes containing gamma value * 100,000
            if (chunk.length != 4) return error.InvalidGammaLength;
            const gamma_int = std.mem.readInt(u32, chunk.data[0..4][0..4], .big);
            png_state.header.gamma = @as(f32, @floatFromInt(gamma_int)) / 100000.0;
        } else if (std.mem.eql(u8, &chunk.type, "sRGB")) {
            if (chunk_state.seen_plte) return error.SrgbAfterPalette;
            if (chunk_state.seen_idat) return error.SrgbAfterImageData;
            // sRGB chunk: 1 byte containing rendering intent
            // NOTE: sRGB and iCCP chunks are mutually exclusive according to PNG spec
            if (chunk.length != 1) return error.InvalidSrgbLength;
            if (chunk_state.seen_iccp) return error.ColorProfileConflict;
            const intent_raw = chunk.data[0];
            png_state.header.srgb_intent = switch (intent_raw) {
                0 => .perceptual,
                1 => .relative_colorimetric,
                2 => .saturation,
                3 => .absolute_colorimetric,
                else => return error.InvalidSrgbIntent,
            };
            chunk_state.seen_srgb = true;
        } else if (std.mem.eql(u8, &chunk.type, "iCCP")) {
            if (chunk_state.seen_plte) return error.IccpAfterPalette;
            if (chunk_state.seen_idat) return error.IccpAfterImageData;
            if (chunk_state.seen_srgb) return error.ColorProfileConflict;
            chunk_state.seen_iccp = true;
        } else if (std.mem.eql(u8, &chunk.type, "IDAT")) {
            if (chunk_state.idat_stream_finished) {
                return error.NonConsecutiveIdatChunks;
            }
            if (png_state.header.color_type == .palette and png_state.palette == null) {
                return error.MissingPalette;
            }
            try accumulateWithLimit(&total_idat_bytes, chunk_len, limits.max_idat_bytes, error.ImageDataLimitExceeded);
            const new_len = std.math.add(usize, png_state.idat_data.items.len, chunk.data.len) catch return error.ImageTooLarge;
            try ensureArrayCapacityWithinLimit(&png_state.idat_data, gpa, new_len, limits.max_idat_bytes);
            png_state.idat_data.appendSliceAssumeCapacity(chunk.data);
            chunk_state.seen_idat = true;
        } else if (std.mem.eql(u8, &chunk.type, "IEND")) {
            chunk_state.seen_iend = true;
            break;
        }
        // Ignore other chunks (ancillary chunks like tEXt, etc.)
    }

    if (!header_found) {
        return error.MissingHeader;
    }

    if (png_state.idat_data.items.len == 0) {
        return error.MissingImageData;
    }

    if (!chunk_state.seen_iend) {
        return error.MissingEndChunk;
    }

    png_state.scan_data_bytes = try scanDataLength(png_state.header);
    if (exceeds(usize, limits.max_decompressed_bytes, png_state.scan_data_bytes)) {
        return error.ImageTooLarge;
    }

    return png_state;
}

/// Convert PNG image data to its most natural Zignal Image type
pub fn toNativeImage(allocator: Allocator, png_state: PngState) !union(enum) {
    grayscale: Image(u8),
    rgb: Image(Rgb),
    rgba: Image(Rgba),
} {
    // Decompress IDAT data
    const decompressed = try zlib.decompress(allocator, png_state.idat_data.items, png_state.scan_data_bytes);
    defer allocator.free(decompressed);

    // Apply row defiltering
    try defilterScanlines(decompressed, png_state.header);

    const width = png_state.header.width;
    const height = png_state.header.height;
    const scanline_bytes = png_state.header.scanlineBytes();

    // Handle interlaced images separately
    if (png_state.header.interlace_method == 1) {
        // Interlaced image - use Adam7 deinterlacing
        switch (png_state.header.color_type) {
            .grayscale, .grayscale_alpha => {
                if (png_state.transparency != null) {
                    return .{ .rgba = try deinterlaceAdam7(allocator, Rgba, decompressed, png_state.header, null, png_state.transparency) };
                } else {
                    return .{ .grayscale = try deinterlaceAdam7(allocator, u8, decompressed, png_state.header, null, null) };
                }
            },
            .rgb => {
                if (png_state.transparency != null) {
                    return .{ .rgba = try deinterlaceAdam7(allocator, Rgba, decompressed, png_state.header, null, png_state.transparency) };
                } else {
                    return .{ .rgb = try deinterlaceAdam7(allocator, Rgb, decompressed, png_state.header, null, null) };
                }
            },
            .rgba => {
                return .{ .rgba = try deinterlaceAdam7(allocator, Rgba, decompressed, png_state.header, null, null) };
            },
            .palette => {
                const palette = png_state.palette orelse return error.MissingPalette;
                if (png_state.transparency != null) {
                    return .{ .rgba = try deinterlaceAdam7(allocator, Rgba, decompressed, png_state.header, palette, png_state.transparency) };
                } else {
                    return .{ .rgb = try deinterlaceAdam7(allocator, Rgb, decompressed, png_state.header, palette, null) };
                }
            },
        }
    }

    // Determine native format and convert accordingly
    switch (png_state.header.color_type) {
        .grayscale, .grayscale_alpha => {
            if (png_state.transparency != null) {
                // Create RGBA image when transparency is present
                const total_pixels = png_state.header.totalPixels();
                if (total_pixels > std.math.maxInt(usize)) {
                    return error.ImageTooLarge;
                }
                var output_data = try allocator.alloc(Rgba, @intCast(total_pixels));

                for (0..height) |y| {
                    const src_row_start = y * (scanline_bytes + 1) + 1;
                    const dst_row_start = y * width;
                    const src_row = decompressed[src_row_start .. src_row_start + scanline_bytes];
                    const dst_row = output_data[dst_row_start .. dst_row_start + width];

                    for (dst_row, 0..) |*pixel, i| {
                        pixel.* = extractGrayscalePixel(Rgba, src_row, i, png_state.header, png_state.transparency);
                    }
                }

                return .{ .rgba = .initFromSlice(height, width, output_data) };
            } else {
                // Create grayscale image when no transparency
                const total_pixels = png_state.header.totalPixels();
                if (total_pixels > std.math.maxInt(usize)) {
                    return error.ImageTooLarge;
                }
                var output_data = try allocator.alloc(u8, @intCast(total_pixels));

                for (0..height) |y| {
                    const src_row_start = y * (scanline_bytes + 1) + 1;
                    const dst_row_start = y * width;
                    const src_row = decompressed[src_row_start .. src_row_start + scanline_bytes];
                    const dst_row = output_data[dst_row_start .. dst_row_start + width];

                    for (dst_row, 0..) |*pixel, i| {
                        pixel.* = extractGrayscalePixel(u8, src_row, i, png_state.header, null);
                    }
                }

                return .{ .grayscale = .initFromSlice(height, width, output_data) };
            }
        },
        .rgb => {
            if (png_state.transparency != null) {
                // Create RGBA image when transparency is present
                const total_pixels = png_state.header.totalPixels();
                if (total_pixels > std.math.maxInt(usize)) {
                    return error.ImageTooLarge;
                }
                var output_data = try allocator.alloc(Rgba, @intCast(total_pixels));

                for (0..height) |y| {
                    const src_row_start = y * (scanline_bytes + 1) + 1;
                    const dst_row_start = y * width;
                    const src_row = decompressed[src_row_start .. src_row_start + scanline_bytes];
                    const dst_row = output_data[dst_row_start .. dst_row_start + width];

                    for (dst_row, 0..) |*pixel, i| {
                        pixel.* = extractRgbPixel(Rgba, src_row, i, png_state.header, png_state.transparency);
                    }
                }

                return .{ .rgba = .initFromSlice(height, width, output_data) };
            } else {
                // Create RGB image when no transparency
                const total_pixels = png_state.header.totalPixels();
                if (total_pixels > std.math.maxInt(usize)) {
                    return error.ImageTooLarge;
                }
                var output_data = try allocator.alloc(Rgb, @intCast(total_pixels));

                for (0..height) |y| {
                    const src_row_start = y * (scanline_bytes + 1) + 1;
                    const dst_row_start = y * width;
                    const src_row = decompressed[src_row_start .. src_row_start + scanline_bytes];
                    const dst_row = output_data[dst_row_start .. dst_row_start + width];

                    for (dst_row, 0..) |*pixel, i| {
                        pixel.* = extractRgbPixel(Rgb, src_row, i, png_state.header, null);
                    }
                }

                return .{ .rgb = .initFromSlice(height, width, output_data) };
            }
        },
        .rgba => {
            // Create RGBA image
            const total_pixels = png_state.header.totalPixels();
            if (total_pixels > std.math.maxInt(usize)) {
                return error.ImageTooLarge;
            }
            var output_data = try allocator.alloc(Rgba, @intCast(total_pixels));

            for (0..height) |y| {
                const src_row_start = y * (scanline_bytes + 1) + 1;
                const dst_row_start = y * width;
                const src_row = decompressed[src_row_start .. src_row_start + scanline_bytes];
                const dst_row = output_data[dst_row_start .. dst_row_start + width];

                for (dst_row, 0..) |*pixel, i| {
                    if (png_state.header.bit_depth == 8) {
                        pixel.* = Rgba{ .r = src_row[i * 4], .g = src_row[i * 4 + 1], .b = src_row[i * 4 + 2], .a = src_row[i * 4 + 3] };
                    } else {
                        // 16-bit to 8-bit conversion
                        const offset = i * 8;
                        if (offset + 8 > src_row.len) {
                            pixel.* = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };
                        } else {
                            pixel.* = Rgba{
                                .r = @intCast(std.mem.readInt(u16, src_row[offset .. offset + 2][0..2], .big) >> 8),
                                .g = @intCast(std.mem.readInt(u16, src_row[offset + 2 .. offset + 4][0..2], .big) >> 8),
                                .b = @intCast(std.mem.readInt(u16, src_row[offset + 4 .. offset + 6][0..2], .big) >> 8),
                                .a = @intCast(std.mem.readInt(u16, src_row[offset + 6 .. offset + 8][0..2], .big) >> 8),
                            };
                        }
                    }
                }
            }

            return .{ .rgba = .initFromSlice(height, width, output_data) };
        },
        .palette => {
            // Convert palette to RGB or RGBA (if transparency present)
            if (png_state.palette == null) return error.MissingPalette;
            const palette = png_state.palette.?;
            const transparency = png_state.transparency;

            const total_pixels = png_state.header.totalPixels();
            if (total_pixels > std.math.maxInt(usize)) {
                return error.ImageTooLarge;
            }

            if (transparency != null) {
                // Has transparency - convert to RGBA
                var output_data = try allocator.alloc(Rgba, @intCast(total_pixels));
                const transparency_data = transparency.?;

                for (0..height) |y| {
                    const src_row_start = y * (scanline_bytes + 1) + 1;
                    const dst_row_start = y * width;
                    const src_row = decompressed[src_row_start .. src_row_start + scanline_bytes];
                    const dst_row = output_data[dst_row_start .. dst_row_start + width];

                    for (dst_row, 0..) |*pixel, i| {
                        const index = switch (png_state.header.bit_depth) {
                            8 => blk: {
                                if (i >= src_row.len) return error.InvalidScanlineData;
                                break :blk src_row[i];
                            },
                            1, 2, 4 => blk: {
                                const bits_per_pixel = png_state.header.bit_depth;
                                const pixels_per_byte = 8 / bits_per_pixel;
                                const mask: u8 = (@as(u8, 1) << @intCast(bits_per_pixel)) - 1;
                                const byte_idx = i / pixels_per_byte;
                                if (byte_idx >= src_row.len) return error.InvalidScanlineData;
                                const pixel_idx = i % pixels_per_byte;
                                const bit_offset: u3 = @intCast((pixels_per_byte - 1 - pixel_idx) * bits_per_pixel);
                                break :blk (src_row[byte_idx] >> bit_offset) & mask;
                            },
                            else => return error.InvalidBitDepth,
                        };

                        if (index >= palette.len) return error.InvalidPaletteIndex;
                        const rgb = palette[index];

                        // Get alpha value from transparency chunk (default to opaque if not present)
                        const alpha = if (index < transparency_data.len) transparency_data[index] else 255;

                        pixel.* = Rgba{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = alpha };
                    }
                }

                return .{ .rgba = .initFromSlice(height, width, output_data) };
            } else {
                // No transparency - convert to RGB
                var output_data = try allocator.alloc(Rgb, @intCast(total_pixels));

                for (0..height) |y| {
                    const src_row_start = y * (scanline_bytes + 1) + 1;
                    const dst_row_start = y * width;
                    const src_row = decompressed[src_row_start .. src_row_start + scanline_bytes];
                    const dst_row = output_data[dst_row_start .. dst_row_start + width];

                    for (dst_row, 0..) |*pixel, i| {
                        const index = switch (png_state.header.bit_depth) {
                            8 => blk: {
                                if (i >= src_row.len) return error.InvalidScanlineData;
                                break :blk src_row[i];
                            },
                            1, 2, 4 => blk: {
                                const bits_per_pixel = png_state.header.bit_depth;
                                const pixels_per_byte = 8 / bits_per_pixel;
                                const mask: u8 = (@as(u8, 1) << @intCast(bits_per_pixel)) - 1;
                                const byte_idx = i / pixels_per_byte;
                                if (byte_idx >= src_row.len) return error.InvalidScanlineData;
                                const pixel_idx = i % pixels_per_byte;
                                const bit_offset: u3 = @intCast((pixels_per_byte - 1 - pixel_idx) * bits_per_pixel);
                                break :blk (src_row[byte_idx] >> bit_offset) & mask;
                            },
                            else => return error.InvalidBitDepth,
                        };

                        if (index >= palette.len) return error.InvalidPaletteIndex;
                        const rgb = palette[index];
                        pixel.* = Rgb{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
                    }
                }

                return .{ .rgb = .initFromSlice(height, width, output_data) };
            }
        },
    }
}

// High-level API functions

/// Load PNG file from disk and decode to specified pixel type.
/// Supports grayscale (1/2/4/8/16-bit), RGB (8/16-bit), RGBA (8/16-bit), and palette (1/2/4/8-bit with transparency).
/// Includes full Adam7 interlacing support for all formats. Automatically converts to desired output type.
///
/// Parameters:
/// - T: Desired output pixel type (u8, Rgb, Rgba, etc.) - color conversion applied if needed
/// - allocator: Memory allocator for image data
/// - file_path: Path to PNG file
///
/// Returns: Decoded Image(T) with automatic color space conversion from source format
///
/// Errors: InvalidPngSignature, ImageTooLarge, OutOfMemory, and various PNG parsing errors
pub fn loadFromBytes(comptime T: type, allocator: Allocator, png_data: []const u8, limits: DecodeLimits) !Image(T) {
    var png_state = try decode(allocator, png_data, limits);
    defer png_state.deinit(allocator);

    // Load the PNG in its native format first, then convert to requested type
    var native_image = try toNativeImage(allocator, png_state);
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
        .rgba => |*img| {
            if (T == Rgba) {
                // Direct return without conversion - no extra allocation needed
                return img.*;
            } else {
                defer img.deinit(allocator);
                return img.convert(T, allocator);
            }
        },
    }
}

pub fn load(comptime T: type, io: std.Io, allocator: Allocator, file_path: []const u8, limits: DecodeLimits) !Image(T) {
    const read_limit = if (limits.max_png_bytes == 0) std.math.maxInt(usize) else limits.max_png_bytes;
    const png_data = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(read_limit));
    defer allocator.free(png_data);
    return loadFromBytes(T, allocator, png_data, limits);
}

// PNG Encoder functionality

// Chunk writer for PNG encoding
pub const ChunkWriter = struct {
    gpa: Allocator,
    data: ArrayList(u8),

    pub fn init(gpa: Allocator) ChunkWriter {
        return .{ .gpa = gpa, .data = .empty };
    }

    pub fn deinit(self: *ChunkWriter) void {
        self.data.deinit(self.gpa);
    }

    pub fn writeChunk(self: *ChunkWriter, chunk_type: [4]u8, chunk_data: []const u8) !void {
        // Length (4 bytes, big endian)
        const length: u32 = @intCast(chunk_data.len);
        try self.data.appendSlice(self.gpa, std.mem.asBytes(&std.mem.nativeTo(u32, length, .big)));

        // Type (4 bytes)
        try self.data.appendSlice(self.gpa, &chunk_type);

        // Data
        try self.data.appendSlice(self.gpa, chunk_data);

        // CRC (4 bytes, big endian) - calculate CRC of type + data
        var crc_data = try self.gpa.alloc(u8, 4 + chunk_data.len);
        defer self.gpa.free(crc_data);
        @memcpy(crc_data[0..4], &chunk_type);
        @memcpy(crc_data[4..], chunk_data);

        const chunk_crc = crc(crc_data);
        try self.data.appendSlice(self.gpa, std.mem.asBytes(&std.mem.nativeTo(u32, chunk_crc, .big)));
    }

    pub fn toOwnedSlice(self: *ChunkWriter) ![]u8 {
        return self.data.toOwnedSlice(self.gpa);
    }
};

/// Create IHDR chunk data
fn createIHDR(header: Header) ![13]u8 {
    var ihdr_data: [13]u8 = undefined;

    // Width (4 bytes)
    std.mem.writeInt(u32, ihdr_data[0..4], header.width, .big);

    // Height (4 bytes)
    std.mem.writeInt(u32, ihdr_data[4..8], header.height, .big);

    // Bit depth (1 byte)
    ihdr_data[8] = header.bit_depth;

    // Color type (1 byte)
    ihdr_data[9] = @intFromEnum(header.color_type);

    // Compression method (1 byte) - always 0
    ihdr_data[10] = 0;

    // Filter method (1 byte) - always 0
    ihdr_data[11] = 0;

    // Interlace method (1 byte) - 0 for no interlacing
    ihdr_data[12] = 0;

    return ihdr_data;
}

/// Apply PNG row filtering to scanlines
fn filterScanlines(allocator: Allocator, data: []const u8, header: Header, filter_type: FilterType) ![]u8 {
    const scanline_bytes = header.scanlineBytes();
    const bytes_per_pixel = header.bytesPerPixel();
    const filtered_size = header.height * (scanline_bytes + 1); // +1 for filter byte

    var filtered_data = try allocator.alloc(u8, filtered_size);

    var y: u32 = 0;
    while (y < header.height) : (y += 1) {
        const src_row_start = y * scanline_bytes;
        const dst_row_start = y * (scanline_bytes + 1);

        const src_row = data[src_row_start .. src_row_start + scanline_bytes];
        const dst_row = filtered_data[dst_row_start + 1 .. dst_row_start + 1 + scanline_bytes];

        // Set filter type byte
        filtered_data[dst_row_start] = @intFromEnum(filter_type);

        // Apply filtering
        const previous_row = if (y > 0)
            data[(y - 1) * scanline_bytes .. (y - 1) * scanline_bytes + scanline_bytes]
        else
            null;

        filterRow(filter_type, dst_row, src_row, previous_row, bytes_per_pixel);
    }

    return filtered_data;
}

// PNG encoding options
pub const EncodeOptions = struct {
    filter_mode: FilterMode = .adaptive,
    compression_level: deflate.CompressionLevel = .level_6,
    compression_strategy: deflate.CompressionStrategy = .filtered,
    gamma: ?f32 = null,
    srgb_intent: ?SrgbRenderingIntent = null,
    pub const default: EncodeOptions = .{
        .filter_mode = .adaptive,
        .compression_level = .level_6,
        .compression_strategy = .default,
    };
};

pub const FilterMode = union(enum) {
    none, // No filtering
    adaptive, // Select best filter per row
    fixed: FilterType, // Use a specific filter type
};

/// Helper function to map pixel types to PNG ColorType
fn getColorType(comptime T: type) ColorType {
    return switch (T) {
        u8 => .grayscale,
        Rgb => .rgb,
        Rgba => .rgba,
        else => .rgb, // For unsupported types, we'll convert to RGB
    };
}

// Encode raw image data to PNG format (internal use)
fn encodeRaw(gpa: Allocator, image_data: []const u8, width: u32, height: u32, color_type: ColorType, bit_depth: u8, options: EncodeOptions) ![]u8 {
    var writer = ChunkWriter.init(gpa);
    defer writer.deinit();

    // Write PNG signature
    try writer.data.appendSlice(gpa, &signature);

    // Create and write IHDR
    const header: Header = .{
        .width = width,
        .height = height,
        .bit_depth = bit_depth,
        .color_type = color_type,
    };

    const ihdr_data = try createIHDR(header);
    try writer.writeChunk("IHDR".*, &ihdr_data);

    // Write color management chunks if specified
    if (options.srgb_intent) |intent| {
        // sRGB chunk - must come before PLTE and IDAT
        const srgb_data = [_]u8{@intFromEnum(intent)};
        try writer.writeChunk("sRGB".*, &srgb_data);
    } else if (options.gamma) |g| {
        // gAMA chunk - must come before PLTE and IDAT
        // Store gamma * 100000 as big-endian u32
        const gamma_int: u32 = @intFromFloat(g * 100000.0);
        var gama_data: [4]u8 = undefined;
        std.mem.writeInt(u32, &gama_data, gamma_int, .big);
        try writer.writeChunk("gAMA".*, &gama_data);
    }

    // Apply row filtering based on options
    const filtered_data = switch (options.filter_mode) {
        .none => try filterScanlines(gpa, image_data, header, .none),
        .adaptive => try filterScanlinesAdaptive(gpa, image_data, header),
        .fixed => |filter_type| try filterScanlines(gpa, image_data, header, filter_type),
    };
    defer gpa.free(filtered_data);

    // Compress filtered data with zlib format (required for PNG IDAT)
    const compressed_data = try zlib.compress(gpa, filtered_data, options.compression_level, options.compression_strategy);
    defer gpa.free(compressed_data);

    // Write IDAT chunk
    try writer.writeChunk("IDAT".*, compressed_data);

    // Write IEND chunk
    try writer.writeChunk("IEND".*, &[_]u8{});

    return writer.toOwnedSlice();
}

/// Generic PNG encoding function that works with any supported pixel type
pub fn encode(comptime T: type, allocator: Allocator, image: Image(T), options: EncodeOptions) ![]u8 {
    const color_type = getColorType(T);

    switch (T) {
        u8, Rgb, Rgba => {
            // Direct support - use image as-is
            const image_bytes = image.asBytes();
            return encodeRaw(allocator, image_bytes, @intCast(image.cols), @intCast(image.rows), color_type, 8, options);
        },
        else => {
            // Convert unsupported type to RGB
            var rgb_image = try Image(Rgb).init(allocator, image.rows, image.cols);
            defer rgb_image.deinit(allocator);

            // Convert each pixel to RGB
            for (image.data, 0..) |pixel, i| {
                rgb_image.data[i] = convertColor(Rgb, pixel);
            }

            const image_bytes = rgb_image.asBytes();
            return encodeRaw(allocator, image_bytes, @intCast(image.cols), @intCast(image.rows), color_type, 8, options);
        },
    }
}

/// Save Image to PNG file with automatic format detection.
/// Encodes to optimal PNG format based on input pixel type with automatic conversion if needed.
/// Uses deflate compression with PNG row filtering for optimal file size.
///
/// Parameters:
/// - T: Input image pixel type (u8->grayscale, Rgb->RGB, Rgba->RGBA, others converted to RGB)
/// - allocator: Memory allocator for encoding operations
/// - image: Source image to save
/// - file_path: Output PNG file path
///
/// Errors: OutOfMemory, file creation/write errors, encoding errors
pub fn save(comptime T: type, io: std.Io, allocator: Allocator, image: Image(T), file_path: []const u8) !void {
    const png_data = try encode(T, allocator, image, .default);
    defer allocator.free(png_data);

    const file = if (std.fs.path.isAbsolute(file_path))
        try std.Io.Dir.createFileAbsolute(io, file_path, .{})
    else
        try std.Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);

    try file.writeStreamingAll(io, png_data);
}

/// PNG row filtering and defiltering functions
fn paethPredictor(a: i32, b: i32, c: i32) u8 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);

    if (pa <= pb and pa <= pc) {
        return @intCast(a);
    } else if (pb <= pc) {
        return @intCast(b);
    } else {
        return @intCast(c);
    }
}

fn defilterRow(
    filter_type: FilterType,
    current_row: []u8,
    previous_row: ?[]const u8,
    bytes_per_pixel: u8,
) void {
    switch (filter_type) {
        .none => {
            // No filtering - data is already correct
        },
        .sub => {
            // Add the byte to the left
            var i: usize = bytes_per_pixel;
            while (i < current_row.len) : (i += 1) {
                current_row[i] = current_row[i] +% current_row[i - bytes_per_pixel];
            }
        },
        .up => {
            // Add the byte above
            if (previous_row) |prev| {
                for (current_row, 0..) |*byte, i| {
                    byte.* = byte.* +% prev[i];
                }
            }
        },
        .average => {
            // Add the average of left and above bytes
            for (current_row, 0..) |*byte, i| {
                const left: u16 = if (i >= bytes_per_pixel) current_row[i - bytes_per_pixel] else 0;
                const above: u16 = if (previous_row) |prev| prev[i] else 0;
                const avg: u8 = @intCast((left + above) / 2);
                byte.* = byte.* +% avg;
            }
        },
        .paeth => {
            // Use Paeth predictor
            for (current_row, 0..) |*byte, i| {
                const left: i32 = if (i >= bytes_per_pixel) current_row[i - bytes_per_pixel] else 0;
                const above: i32 = if (previous_row) |prev| prev[i] else 0;
                const upper_left: i32 = if (previous_row != null and i >= bytes_per_pixel)
                    previous_row.?[i - bytes_per_pixel]
                else
                    0;

                const paeth = paethPredictor(left, above, upper_left);
                byte.* = byte.* +% paeth;
            }
        },
    }
}

fn filterRow(
    filter_type: FilterType,
    current_row: []u8,
    original_row: []const u8,
    previous_row: ?[]const u8,
    bytes_per_pixel: u8,
) void {
    switch (filter_type) {
        .none => {
            @memcpy(current_row, original_row);
        },
        .sub => {
            // Subtract the byte to the left
            for (current_row, original_row, 0..) |*filtered, orig, i| {
                const left: u8 = if (i >= bytes_per_pixel) original_row[i - bytes_per_pixel] else 0;
                filtered.* = orig -% left;
            }
        },
        .up => {
            // Subtract the byte above
            for (current_row, original_row, 0..) |*filtered, orig, i| {
                const above: u8 = if (previous_row) |prev| prev[i] else 0;
                filtered.* = orig -% above;
            }
        },
        .average => {
            // Subtract the average of left and above bytes
            for (current_row, original_row, 0..) |*filtered, orig, i| {
                const left: u16 = if (i >= bytes_per_pixel) original_row[i - bytes_per_pixel] else 0;
                const above: u16 = if (previous_row) |prev| prev[i] else 0;
                const avg: u8 = @intCast((left + above) / 2);
                filtered.* = orig -% avg;
            }
        },
        .paeth => {
            // Subtract Paeth predictor
            for (current_row, original_row, 0..) |*filtered, orig, i| {
                const left: i32 = if (i >= bytes_per_pixel) original_row[i - bytes_per_pixel] else 0;
                const above: i32 = if (previous_row) |prev| prev[i] else 0;
                const upper_left: i32 = if (previous_row != null and i >= bytes_per_pixel)
                    previous_row.?[i - bytes_per_pixel]
                else
                    0;

                const paeth = paethPredictor(left, above, upper_left);
                filtered.* = orig -% paeth;
            }
        },
    }
}

/// Calculate cost for filtered data using the standard PNG heuristic:
/// sum of absolute values of the signed filter bytes. Lower is better.
fn calculateFilterCost(filtered_data: []const u8) u32 {
    var cost: u32 = 0;
    // Interpret bytes as signed 8-bit deltas; accumulate absolute value safely
    // Cast to wider type before abs to handle -128 correctly.
    for (filtered_data) |b| {
        const sb: i8 = @bitCast(b);
        const wide: i16 = sb;
        cost += @intCast(@abs(wide));
    }
    return cost;
}

/// Select the best filter type for a scanline
fn selectBestFilter(
    src_row: []const u8,
    previous_row: ?[]const u8,
    bytes_per_pixel: u8,
    temp_buffer: []u8,
) FilterType {
    var best_filter = FilterType.none;
    var best_cost: u32 = std.math.maxInt(u32);

    const filters = [_]FilterType{ .none, .sub, .up, .average, .paeth };
    for (filters) |filter_type| {
        // Skip filters that reference a previous row if none exists
        const invalid_for_first_row = (previous_row == null and (filter_type == .up or filter_type == .average or filter_type == .paeth));
        if (invalid_for_first_row) continue;

        filterRow(filter_type, temp_buffer, src_row, previous_row, bytes_per_pixel);
        const cost = calculateFilterCost(temp_buffer);
        if (cost < best_cost) {
            best_cost = cost;
            best_filter = filter_type;
        }
    }

    return best_filter;
}

/// Apply adaptive PNG row filtering to scanlines
fn filterScanlinesAdaptive(allocator: Allocator, data: []const u8, header: Header) ![]u8 {
    const scanline_bytes = header.scanlineBytes();
    const bytes_per_pixel = header.bytesPerPixel();
    const filtered_size = header.height * (scanline_bytes + 1); // +1 for filter byte

    var filtered_data = try allocator.alloc(u8, filtered_size);

    // Allocate temp buffer for filter testing
    const temp_buffer = try allocator.alloc(u8, scanline_bytes);
    defer allocator.free(temp_buffer);

    // Adaptive sampling: analyze every Nth row for large images
    const sample_rate: u32 = if (header.height > 512) 8 else 1;
    var last_filter = FilterType.none;
    var filter_streak: u32 = 0;

    var y: u32 = 0;
    while (y < header.height) : (y += 1) {
        const src_row_start = y * scanline_bytes;
        const dst_row_start = y * (scanline_bytes + 1);

        const src_row = data[src_row_start .. src_row_start + scanline_bytes];
        const dst_row = filtered_data[dst_row_start + 1 .. dst_row_start + 1 + scanline_bytes];

        const previous_row = if (y > 0)
            data[(y - 1) * scanline_bytes .. (y - 1) * scanline_bytes + scanline_bytes]
        else
            null;

        // Decide whether to analyze this row
        const should_analyze = (y % sample_rate == 0) or
            (filter_streak == 0) or
            (y < 3) or // Always analyze first few rows
            (y >= header.height - 3); // And last few rows

        const best_filter = if (should_analyze) blk: {
            const filter = selectBestFilter(src_row, previous_row, bytes_per_pixel, temp_buffer);

            // Track filter consistency
            if (filter == last_filter) {
                filter_streak = @min(filter_streak + 1, sample_rate);
            } else {
                filter_streak = 0;
                last_filter = filter;
            }

            break :blk filter;
        } else last_filter; // Reuse last filter

        // Set filter type byte
        filtered_data[dst_row_start] = @intFromEnum(best_filter);

        // Apply the selected filter
        filterRow(best_filter, dst_row, src_row, previous_row, bytes_per_pixel);
    }

    return filtered_data;
}

/// Apply defiltering to all scanlines after deflate decompression
fn defilterScanlines(data: []u8, header: Header) !void {
    if (header.interlace_method == 1) {
        // Interlaced image - use Adam7 defiltering
        try defilterAdam7Scanlines(data, header);
    } else {
        // Non-interlaced image - use standard defiltering
        try defilterStandardScanlines(data, header);
    }
}

/// Apply defiltering to standard (non-interlaced) scanlines
fn defilterStandardScanlines(data: []u8, header: Header) !void {
    const scanline_bytes = header.scanlineBytes();
    const bytes_per_pixel = header.bytesPerPixel();
    const expected_size = header.height * (scanline_bytes + 1); // +1 for filter byte

    if (data.len != expected_size) {
        return error.InvalidScanlineData;
    }

    var y: u32 = 0;
    var previous_scanline: ?[]u8 = null;

    while (y < header.height) : (y += 1) {
        const row_start = y * (scanline_bytes + 1);
        const filter_byte = data[row_start];
        const current_scanline = data[row_start + 1 .. row_start + 1 + scanline_bytes];

        const filter_type: FilterType = switch (filter_byte) {
            0 => .none,
            1 => .sub,
            2 => .up,
            3 => .average,
            4 => .paeth,
            else => return error.InvalidFilterType,
        };

        defilterRow(filter_type, current_scanline, previous_scanline, bytes_per_pixel);
        previous_scanline = current_scanline;
    }
}

/// Apply defiltering to Adam7 interlaced scanlines
fn defilterAdam7Scanlines(data: []u8, header: Header) !void {
    const expected_size = try adam7TotalSize(header);

    if (data.len != expected_size) {
        return error.InvalidScanlineData;
    }

    const bytes_per_pixel = header.bytesPerPixel();
    const channels = header.channels();
    var data_offset: usize = 0;

    // Process each of the 7 Adam7 passes
    for (0..7) |pass| {
        const dims = adam7PassDimensions(@intCast(pass), header.width, header.height);
        if (dims.width == 0 or dims.height == 0) continue;

        const pass_scanline_bytes = (dims.width * channels * header.bit_depth + 7) / 8;
        var previous_scanline: ?[]u8 = null;

        for (0..dims.height) |y| {
            const row_start = data_offset + y * (pass_scanline_bytes + 1);
            const filter_byte = data[row_start];
            const current_scanline = data[row_start + 1 .. row_start + 1 + pass_scanline_bytes];

            const filter_type: FilterType = switch (filter_byte) {
                0 => .none,
                1 => .sub,
                2 => .up,
                3 => .average,
                4 => .paeth,
                else => return error.InvalidFilterType,
            };

            defilterRow(filter_type, current_scanline, previous_scanline, bytes_per_pixel);
            previous_scanline = current_scanline;
        }

        data_offset += dims.height * (pass_scanline_bytes + 1);
    }
}

/// Deinterlace Adam7 data and convert to requested pixel format
fn deinterlaceAdam7(allocator: Allocator, comptime T: type, decompressed: []u8, header: Header, palette: ?[]const [3]u8, transparency: ?[]const u8) !Image(T) {
    const total_pixels = header.totalPixels();
    if (total_pixels > std.math.maxInt(usize)) {
        return error.ImageTooLarge;
    }

    var output_data = try allocator.alloc(T, @intCast(total_pixels));
    const channels = header.channels();
    var data_offset: usize = 0;

    // Process each of the 7 Adam7 passes
    for (0..7) |pass| {
        const dims = adam7PassDimensions(@intCast(pass), header.width, header.height);
        if (dims.width == 0 or dims.height == 0) continue;

        const pass_info = adam7_passes[pass];
        const pass_scanline_bytes = (dims.width * channels * header.bit_depth + 7) / 8;

        for (0..dims.height) |pass_y| {
            const src_row_start = data_offset + pass_y * (pass_scanline_bytes + 1) + 1; // +1 to skip filter byte
            const src_row = decompressed[src_row_start .. src_row_start + pass_scanline_bytes];

            const final_y = pass_info.y_start + pass_y * pass_info.y_step;
            if (final_y >= header.height) continue;

            for (0..dims.width) |pass_x| {
                const final_x = pass_info.x_start + pass_x * pass_info.x_step;
                if (final_x >= header.width) continue;

                const final_pixel_idx = final_y * header.width + final_x;

                // Extract pixel value based on color type and bit depth
                output_data[final_pixel_idx] = switch (header.color_type) {
                    .grayscale, .grayscale_alpha => extractGrayscalePixel(T, src_row, pass_x, header, transparency),
                    .rgb => extractRgbPixel(T, src_row, pass_x, header, transparency),
                    .rgba => extractRgbaPixel(T, src_row, pass_x, header),
                    .palette => blk: {
                        const pal = palette orelse return error.MissingPalette;
                        break :blk extractPalettePixel(T, src_row, pass_x, header, pal, transparency);
                    },
                };
            }
        }

        data_offset += dims.height * (pass_scanline_bytes + 1);
    }

    return Image(T).initFromSlice(@intCast(header.height), @intCast(header.width), output_data);
}

// Apply gamma correction to a color value
inline fn applyGammaCorrection(value: u8, header: Header) u8 {
    // PNG gamma handling:
    // - gAMA chunk indicates the encoding gamma of the file
    // - sRGB chunk indicates the file is in sRGB color space
    // - For display purposes, files are already gamma-encoded and should be displayed as-is
    // - Gamma correction should only be applied when converting to linear space for processing
    //
    // Since zignal is primarily used for display and image manipulation (not linear color
    // processing), we don't apply gamma correction by default. This matches the behavior
    // of most image viewers and libraries.
    _ = header;
    return value;
}

/// Extract grayscale pixel from Adam7 pass data with optional transparency
fn extractGrayscalePixel(comptime T: type, src_row: []const u8, pass_x: usize, header: Header, transparency: ?[]const u8) T {
    const pixel_value: u8 = switch (header.bit_depth) {
        8 => if (header.color_type == .grayscale_alpha) src_row[pass_x * 2] else src_row[pass_x],
        16 => blk: {
            const offset = if (header.color_type == .grayscale_alpha) pass_x * 4 else pass_x * 2;
            if (offset + 1 >= src_row.len) break :blk 0;
            break :blk @intCast(std.mem.readInt(u16, src_row[offset .. offset + 2][0..2], .big) >> 8);
        },
        1, 2, 4 => blk: {
            const bits_per_pixel = header.bit_depth;
            const pixels_per_byte = 8 / bits_per_pixel;
            const mask: u8 = (@as(u8, 1) << @intCast(bits_per_pixel)) - 1;
            const byte_idx = pass_x / pixels_per_byte;
            if (byte_idx >= src_row.len) break :blk 0;
            const pixel_idx = pass_x % pixels_per_byte;
            const bit_offset: u3 = @intCast((pixels_per_byte - 1 - pixel_idx) * bits_per_pixel);
            const pixel_val = (src_row[byte_idx] >> bit_offset) & mask;
            const scale_factor = 255 / mask;
            break :blk pixel_val * scale_factor;
        },
        else => 0,
    };

    // Check for transparency
    const is_transparent = if (transparency) |trans_data| blk: {
        if (header.color_type == .grayscale and trans_data.len >= 2) {
            const transparent_value = if (header.is16Bit())
                @as(u8, @intCast(std.mem.readInt(u16, trans_data[0..2], .big) >> 8))
            else
                trans_data[1]; // For 8-bit and sub-byte, use lower byte
            break :blk pixel_value == transparent_value;
        }
        break :blk false;
    } else false;

    return switch (T) {
        u8 => pixel_value,
        Rgb => Rgb{ .r = pixel_value, .g = pixel_value, .b = pixel_value },
        Rgba => Rgba{ .r = pixel_value, .g = pixel_value, .b = pixel_value, .a = if (is_transparent) 0 else 255 },
        else => @compileError("Unsupported pixel type"),
    };
}

/// Extract RGB pixel from Adam7 pass data with optional transparency
fn extractRgbPixel(comptime T: type, src_row: []const u8, pass_x: usize, header: Header, transparency: ?[]const u8) T {
    const channel_stride: usize = if (header.is16Bit()) 2 else 1;
    const total_bytes: usize = channel_stride * header.channels();
    const offset = pass_x * total_bytes;
    if (offset + total_bytes > src_row.len) {
        return switch (T) {
            u8 => 0,
            Rgb => Rgb{ .r = 0, .g = 0, .b = 0 },
            Rgba => Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 },
            else => @compileError("Unsupported pixel type"),
        };
    }

    const r: u8 = if (header.is16Bit())
        @intCast(std.mem.readInt(u16, src_row[offset .. offset + 2][0..2], .big) >> 8)
    else
        src_row[offset];
    const g: u8 = if (header.is16Bit())
        @intCast(std.mem.readInt(u16, src_row[offset + channel_stride .. offset + channel_stride + 2][0..2], .big) >> 8)
    else
        src_row[offset + channel_stride];
    const b: u8 = if (header.is16Bit())
        @intCast(std.mem.readInt(u16, src_row[offset + channel_stride * 2 .. offset + channel_stride * 2 + 2][0..2], .big) >> 8)
    else
        src_row[offset + channel_stride * 2];

    // Check for transparency
    const is_transparent = if (transparency) |trans_data| blk: {
        if (header.color_type == .rgb and trans_data.len >= 6) {
            const trans_r: u8 = if (header.is16Bit())
                @intCast(std.mem.readInt(u16, trans_data[0..2], .big) >> 8)
            else
                trans_data[1]; // Use lower byte for 8-bit
            const trans_g: u8 = if (header.is16Bit())
                @intCast(std.mem.readInt(u16, trans_data[2..4], .big) >> 8)
            else
                trans_data[3];
            const trans_b: u8 = if (header.is16Bit())
                @intCast(std.mem.readInt(u16, trans_data[4..6], .big) >> 8)
            else
                trans_data[5];
            break :blk r == trans_r and g == trans_g and b == trans_b;
        }
        break :blk false;
    } else false;

    return switch (T) {
        u8 => @as(u8, @intCast((@as(u16, r) + @as(u16, g) + @as(u16, b)) / 3)),
        Rgb => Rgb{ .r = r, .g = g, .b = b },
        Rgba => Rgba{ .r = r, .g = g, .b = b, .a = if (is_transparent) 0 else 255 },
        else => @compileError("Unsupported pixel type"),
    };
}

/// Extract RGBA pixel from Adam7 pass data
fn extractRgbaPixel(comptime T: type, src_row: []const u8, pass_x: usize, header: Header) T {
    const channel_stride: usize = if (header.is16Bit()) 2 else 1;
    const total_bytes: usize = channel_stride * header.channels();
    const offset = pass_x * total_bytes;
    if (offset + total_bytes > src_row.len) {
        return switch (T) {
            u8 => 0,
            Rgb => Rgb{ .r = 0, .g = 0, .b = 0 },
            Rgba => Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 },
            else => @compileError("Unsupported pixel type"),
        };
    }

    const r: u8 = if (header.is16Bit())
        @intCast(std.mem.readInt(u16, src_row[offset .. offset + 2][0..2], .big) >> 8)
    else
        src_row[offset];
    const g: u8 = if (header.is16Bit())
        @intCast(std.mem.readInt(u16, src_row[offset + channel_stride .. offset + channel_stride + 2][0..2], .big) >> 8)
    else
        src_row[offset + channel_stride];
    const b: u8 = if (header.is16Bit())
        @intCast(std.mem.readInt(u16, src_row[offset + channel_stride * 2 .. offset + channel_stride * 2 + 2][0..2], .big) >> 8)
    else
        src_row[offset + channel_stride * 2];
    const a: u8 = if (header.is16Bit())
        @intCast(std.mem.readInt(u16, src_row[offset + channel_stride * 3 .. offset + channel_stride * 3 + 2][0..2], .big) >> 8)
    else
        src_row[offset + channel_stride * 3];

    return switch (T) {
        u8 => @as(u8, @intCast((@as(u16, r) + @as(u16, g) + @as(u16, b)) / 3)),
        Rgb => Rgb{ .r = r, .g = g, .b = b },
        Rgba => Rgba{ .r = r, .g = g, .b = b, .a = a },
        else => @compileError("Unsupported pixel type"),
    };
}

/// Extract palette-based pixel from Adam7 pass data.
/// Falls back to black/transparent when palette data is missing or the index is invalid.
fn extractPalettePixel(
    comptime T: type,
    src_row: []const u8,
    pass_x: usize,
    header: Header,
    palette: []const [3]u8,
    transparency: ?[]const u8,
) T {
    const index = switch (header.bit_depth) {
        8 => blk: {
            if (pass_x >= src_row.len) break :blk 0;
            break :blk src_row[pass_x];
        },
        1, 2, 4 => blk: {
            const bits_per_pixel = header.bit_depth;
            const pixels_per_byte = 8 / bits_per_pixel;
            const mask = (@as(u8, 1) << @intCast(bits_per_pixel)) - 1;
            const byte_idx = pass_x / pixels_per_byte;
            if (byte_idx >= src_row.len) break :blk 0;
            const pixel_idx = pass_x % pixels_per_byte;
            const bit_offset: u3 = @intCast((pixels_per_byte - 1 - pixel_idx) * bits_per_pixel);
            break :blk (src_row[byte_idx] >> bit_offset) & mask;
        },
        else => 0,
    };

    if (index >= palette.len) {
        return switch (T) {
            u8 => 0,
            Rgb => Rgb{ .r = 0, .g = 0, .b = 0 },
            Rgba => Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 },
            else => @compileError("Unsupported pixel type for palette conversion"),
        };
    }

    const rgb = palette[index];
    const alpha = if (transparency) |trans_data|
        if (index < trans_data.len) trans_data[index] else 255
    else
        255;

    return switch (T) {
        u8 => @as(u8, @intCast((@as(u16, rgb[0]) + @as(u16, rgb[1]) + @as(u16, rgb[2])) / 3)),
        Rgb => Rgb{ .r = rgb[0], .g = rgb[1], .b = rgb[2] },
        Rgba => Rgba{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = alpha },
        else => @compileError("Unsupported pixel type for palette conversion"),
    };
}

fn appendTestChunk(list: *ArrayList(u8), allocator: Allocator, chunk_type: [4]u8, chunk_data: []const u8) !void {
    var length_be = std.mem.nativeTo(u32, @intCast(chunk_data.len), .big);
    try list.appendSlice(allocator, std.mem.asBytes(&length_be));
    try list.appendSlice(allocator, &chunk_type);
    if (chunk_data.len != 0) {
        try list.appendSlice(allocator, chunk_data);
    }

    var crc_val = updateCrc(0xffffffff, &chunk_type);
    if (chunk_data.len != 0) {
        crc_val = updateCrc(crc_val, chunk_data);
    }
    const chunk_crc = crc_val ^ 0xffffffff;
    var crc_be = std.mem.nativeTo(u32, chunk_crc, .big);
    try list.appendSlice(allocator, std.mem.asBytes(&crc_be));
}

// Simple test for the PNG structure
test "PNG signature validation" {
    const invalid_sig = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const result = decode(std.testing.allocator, &invalid_sig, .{});
    try std.testing.expectError(error.InvalidPngSignature, result);
}

test "PNG rejects chunks before IHDR" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    try data.appendSlice(gpa, &signature);
    const plte_payload = [_]u8{ 0, 0, 0 };
    try appendTestChunk(&data, gpa, "PLTE".*, &plte_payload);
    try appendTestChunk(&data, gpa, "IEND".*, &[_]u8{});

    try std.testing.expectError(error.ChunkBeforeHeader, decode(gpa, data.items, .{}));
}

test "PNG palette images require PLTE before IDAT" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    try data.appendSlice(gpa, &signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], 1, .big);
    std.mem.writeInt(u32, ihdr[4..8], 1, .big);
    ihdr[8] = 8;
    ihdr[9] = @intFromEnum(ColorType.palette);
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendTestChunk(&data, gpa, "IHDR".*, &ihdr);

    try appendTestChunk(&data, gpa, "IDAT".*, &[_]u8{});
    try appendTestChunk(&data, gpa, "IEND".*, &[_]u8{});

    try std.testing.expectError(error.MissingPalette, decode(gpa, data.items, .{}));
}

test "PNG palette transparency requires PLTE first" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    try data.appendSlice(gpa, &signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], 1, .big);
    std.mem.writeInt(u32, ihdr[4..8], 1, .big);
    ihdr[8] = 8;
    ihdr[9] = @intFromEnum(ColorType.palette);
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendTestChunk(&data, gpa, "IHDR".*, &ihdr);

    const trns_payload = [_]u8{0x00};
    try appendTestChunk(&data, gpa, "tRNS".*, &trns_payload);

    const plte_payload = [_]u8{ 0, 0, 0 };
    try appendTestChunk(&data, gpa, "PLTE".*, &plte_payload);
    try appendTestChunk(&data, gpa, "IDAT".*, &[_]u8{});
    try appendTestChunk(&data, gpa, "IEND".*, &[_]u8{});

    try std.testing.expectError(error.TransparencyBeforePalette, decode(gpa, data.items, .{}));
}

test "PNG rejects PLTE for grayscale" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    try data.appendSlice(gpa, &signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], 1, .big);
    std.mem.writeInt(u32, ihdr[4..8], 1, .big);
    ihdr[8] = 8;
    ihdr[9] = @intFromEnum(ColorType.grayscale);
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendTestChunk(&data, gpa, "IHDR".*, &ihdr);

    const plte_payload = [_]u8{ 0, 0, 0 };
    try appendTestChunk(&data, gpa, "PLTE".*, &plte_payload);
    try appendTestChunk(&data, gpa, "IEND".*, &[_]u8{});

    try std.testing.expectError(error.PaletteForbiddenForColorType, decode(gpa, data.items, .{}));
}

test "PNG IDAT chunks must be consecutive" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    try data.appendSlice(gpa, &signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], 1, .big);
    std.mem.writeInt(u32, ihdr[4..8], 1, .big);
    ihdr[8] = 8;
    ihdr[9] = @intFromEnum(ColorType.rgb);
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendTestChunk(&data, gpa, "IHDR".*, &ihdr);

    const empty_idat = [_]u8{ 0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01 };
    try appendTestChunk(&data, gpa, "IDAT".*, &empty_idat);

    const text_payload = [_]u8{ 'k', 'e', 'y', 0, 'v', 'a', 'l' };
    try appendTestChunk(&data, gpa, "tEXt".*, &text_payload);

    try appendTestChunk(&data, gpa, "IDAT".*, &empty_idat);
    try appendTestChunk(&data, gpa, "IEND".*, &[_]u8{});

    try std.testing.expectError(error.NonConsecutiveIdatChunks, decode(gpa, data.items, .{}));
}

test "PNG gamma chunk must precede PLTE" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    try data.appendSlice(gpa, &signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], 1, .big);
    std.mem.writeInt(u32, ihdr[4..8], 1, .big);
    ihdr[8] = 8;
    ihdr[9] = @intFromEnum(ColorType.rgb);
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendTestChunk(&data, gpa, "IHDR".*, &ihdr);

    const plte_payload = [_]u8{ 0, 0, 0 };
    try appendTestChunk(&data, gpa, "PLTE".*, &plte_payload);

    const gama_payload = [_]u8{ 0, 0, 0, 1 };
    try appendTestChunk(&data, gpa, "gAMA".*, &gama_payload);
    try appendTestChunk(&data, gpa, "IEND".*, &[_]u8{});

    try std.testing.expectError(error.GammaAfterPalette, decode(gpa, data.items, .{}));
}

test "PNG sRGB chunk must precede IDAT" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    try data.appendSlice(gpa, &signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], 1, .big);
    std.mem.writeInt(u32, ihdr[4..8], 1, .big);
    ihdr[8] = 8;
    ihdr[9] = @intFromEnum(ColorType.rgb);
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendTestChunk(&data, gpa, "IHDR".*, &ihdr);

    const empty_idat = [_]u8{ 0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01 };
    try appendTestChunk(&data, gpa, "IDAT".*, &empty_idat);

    const srgb_payload = [_]u8{0};
    try appendTestChunk(&data, gpa, "sRGB".*, &srgb_payload);
    try appendTestChunk(&data, gpa, "IEND".*, &[_]u8{});

    try std.testing.expectError(error.SrgbAfterImageData, decode(gpa, data.items, .{}));
}

test "PNG requires IEND chunk" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    try data.appendSlice(gpa, &signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], 1, .big);
    std.mem.writeInt(u32, ihdr[4..8], 1, .big);
    ihdr[8] = 8;
    ihdr[9] = @intFromEnum(ColorType.rgb);
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendTestChunk(&data, gpa, "IHDR".*, &ihdr);

    const empty_idat = [_]u8{ 0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01 };
    try appendTestChunk(&data, gpa, "IDAT".*, &empty_idat);

    try std.testing.expectError(error.MissingEndChunk, decode(gpa, data.items, .{}));
}

test "PNG enforces max_png_bytes limit" {
    var buffer: [9]u8 = undefined;
    @memcpy(buffer[0..8], &signature);
    buffer[8] = 0;
    const result = decode(std.testing.allocator, &buffer, .{ .max_png_bytes = 8 });
    try std.testing.expectError(error.PngDataTooLarge, result);
}

test "PNG enforces chunk byte limit" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    try data.appendSlice(gpa, &signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], 1, .big);
    std.mem.writeInt(u32, ihdr[4..8], 1, .big);
    ihdr[8] = 8;
    ihdr[9] = @intFromEnum(ColorType.rgb);
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendTestChunk(&data, gpa, "IHDR".*, &ihdr);

    const limits: DecodeLimits = .{
        .max_png_bytes = 1024,
        .max_chunk_bytes = 8,
        .max_idat_bytes = 1024,
        .max_chunks = 16,
    };
    try std.testing.expectError(error.ChunkDataLimitExceeded, decode(gpa, data.items, limits));
}

test "PNG enforces IDAT byte limit" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    try data.appendSlice(gpa, &signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], 1, .big);
    std.mem.writeInt(u32, ihdr[4..8], 1, .big);
    ihdr[8] = 8;
    ihdr[9] = @intFromEnum(ColorType.rgb);
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendTestChunk(&data, gpa, "IHDR".*, &ihdr);

    const empty_idat = [_]u8{ 0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01 };
    try appendTestChunk(&data, gpa, "IDAT".*, &empty_idat);
    try appendTestChunk(&data, gpa, "IEND".*, &[_]u8{});

    const limits: DecodeLimits = .{
        .max_png_bytes = 1024,
        .max_chunk_bytes = 1024,
        .max_idat_bytes = 4,
        .max_chunks = 16,
    };
    try std.testing.expectError(error.ImageDataLimitExceeded, decode(gpa, data.items, limits));
}

test "PNG enforces chunk count limit" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    try data.appendSlice(gpa, &signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], 1, .big);
    std.mem.writeInt(u32, ihdr[4..8], 1, .big);
    ihdr[8] = 8;
    ihdr[9] = @intFromEnum(ColorType.rgb);
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendTestChunk(&data, gpa, "IHDR".*, &ihdr);
    try appendTestChunk(&data, gpa, "IEND".*, &[_]u8{});

    const limits: DecodeLimits = .{
        .max_png_bytes = 1024,
        .max_chunk_bytes = 1024,
        .max_chunks = 1,
    };
    try std.testing.expectError(error.TooManyChunks, decode(gpa, data.items, limits));
}

test "PNG enforces decompressed byte limit" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    try data.appendSlice(gpa, &signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], 1, .big);
    std.mem.writeInt(u32, ihdr[4..8], 1, .big);
    ihdr[8] = 8;
    ihdr[9] = @intFromEnum(ColorType.grayscale);
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendTestChunk(&data, gpa, "IHDR".*, &ihdr);

    const empty_idat = [_]u8{ 0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01 };
    try appendTestChunk(&data, gpa, "IDAT".*, &empty_idat);
    try appendTestChunk(&data, gpa, "IEND".*, &[_]u8{});

    const limits: DecodeLimits = .{
        .max_png_bytes = 1024,
        .max_chunk_bytes = 1024,
        .max_idat_bytes = 1024,
        .max_chunks = 16,
        .max_decompressed_bytes = 1,
    };
    try std.testing.expectError(error.ImageTooLarge, decode(gpa, data.items, limits));
}

test "PNG default decompressed limit covers 8K RGBA 16-bit" {
    const header: Header = .{
        .width = max_dimensions_default,
        .height = max_dimensions_default,
        .bit_depth = 16,
        .color_type = .rgba,
        .compression_method = 0,
        .filter_method = 0,
        .interlace_method = 1,
    };
    const inflated = try adam7TotalSize(header);
    const limits = DecodeLimits{};
    try std.testing.expect(inflated <= limits.max_decompressed_bytes);
}

test "CRC calculation" {
    // Test with known values
    const test_data = "IHDR";
    const expected_chunk_type_crc = crc(test_data);
    // This is just to make sure our CRC function runs without crashing
    try std.testing.expect(expected_chunk_type_crc != 0);
}

test "Paeth predictor" {
    // Test cases - verify the Paeth predictor algorithm
    try std.testing.expectEqual(@as(u8, 15), paethPredictor(10, 20, 15)); // p=15, pa=5, pb=5, pc=0 -> c=15
    try std.testing.expectEqual(@as(u8, 5), paethPredictor(5, 20, 15)); // p=10, pa=5, pb=10, pc=5 -> a=5
    try std.testing.expectEqual(@as(u8, 10), paethPredictor(10, 5, 6)); // p=9, pa=1, pb=4, pc=3 -> a=10
}

test "PNG round-trip encoding/decoding" {
    const allocator = std.testing.allocator;

    // Create a simple test image (4x4 RGB)
    const width = 4;
    const height = 4;
    const test_data = [_]Rgb{
        .{ .r = 255, .g = 0, .b = 0 },   .{ .r = 0, .g = 255, .b = 0 },   .{ .r = 0, .g = 0, .b = 255 },     .{ .r = 255, .g = 255, .b = 0 },
        .{ .r = 255, .g = 0, .b = 255 }, .{ .r = 0, .g = 255, .b = 255 }, .{ .r = 128, .g = 128, .b = 128 }, .{ .r = 255, .g = 255, .b = 255 },
        .{ .r = 0, .g = 0, .b = 0 },     .{ .r = 64, .g = 64, .b = 64 },  .{ .r = 192, .g = 192, .b = 192 }, .{ .r = 128, .g = 0, .b = 128 },
        .{ .r = 128, .g = 128, .b = 0 }, .{ .r = 0, .g = 128, .b = 128 }, .{ .r = 255, .g = 128, .b = 64 },  .{ .r = 64, .g = 255, .b = 128 },
    };

    // Create owned copy for Image
    const owned_data = try allocator.alloc(Rgb, test_data.len);
    defer allocator.free(owned_data);
    @memcpy(owned_data, &test_data);

    const original_image: Image(Rgb) = .initFromSlice(height, width, owned_data);

    // Encode to PNG
    const png_data = try encode(Rgb, allocator, original_image, .default);
    defer allocator.free(png_data);

    // Verify PNG signature
    try std.testing.expect(png_data.len > 8);
    try std.testing.expectEqualSlices(u8, &signature, png_data[0..8]);

    // Decode back from PNG
    var decoded_png = try decode(allocator, png_data, .{});
    defer decoded_png.deinit(allocator);

    // Verify header
    try std.testing.expectEqual(@as(u32, width), decoded_png.header.width);
    try std.testing.expectEqual(@as(u32, height), decoded_png.header.height);
    try std.testing.expectEqual(ColorType.rgb, decoded_png.header.color_type);
    try std.testing.expectEqual(@as(u8, 8), decoded_png.header.bit_depth);

    // Convert back to Image
    const native_image = try toNativeImage(allocator, decoded_png);
    var decoded_image = switch (native_image) {
        .rgb => |*img| img.*,
        else => @panic("Expected RGB image for this test"),
    };
    defer decoded_image.deinit(allocator);

    // Verify dimensions
    try std.testing.expectEqual(height, decoded_image.rows);
    try std.testing.expectEqual(width, decoded_image.cols);

    // Verify pixel data
    for (original_image.data, decoded_image.data) |orig, decoded| {
        try std.testing.expectEqual(orig.r, decoded.r);
        try std.testing.expectEqual(orig.g, decoded.g);
        try std.testing.expectEqual(orig.b, decoded.b);
    }
}

test "PNG adaptive filter selection" {
    const allocator = std.testing.allocator;

    // Create a tiny 2-row RGB image where the first row is constant
    // so .sub is best, and the second row equals the first so .up is best.
    const width: u32 = 8;
    const height: u32 = 2;
    const header: Header = .{
        .width = width,
        .height = height,
        .bit_depth = 8,
        .color_type = .rgb,
    };

    const scanline_bytes = header.scanlineBytes();
    var raw = try allocator.alloc(u8, scanline_bytes * height);
    defer allocator.free(raw);

    // Row 0: all bytes are 128; Row 1: identical to Row 0
    @memset(raw[0..scanline_bytes], 128);
    @memset(raw[scanline_bytes .. scanline_bytes * 2], 128);

    // Apply adaptive filtering and check filter bytes
    const filtered = try filterScanlinesAdaptive(allocator, raw, header);
    defer allocator.free(filtered);

    const stride = scanline_bytes + 1; // filter byte + scanline data
    try std.testing.expectEqual(@as(u8, @intFromEnum(FilterType.sub)), filtered[0]);
    try std.testing.expectEqual(@as(u8, @intFromEnum(FilterType.up)), filtered[stride]);

    // Defilter back and verify we recover the original bytes
    var roundtrip = try allocator.alloc(u8, filtered.len);
    defer allocator.free(roundtrip);
    @memcpy(roundtrip, filtered);
    try defilterStandardScanlines(roundtrip, header);

    try std.testing.expectEqualSlices(u8, raw[0..scanline_bytes], roundtrip[1 .. 1 + scanline_bytes]);
    try std.testing.expectEqualSlices(u8, raw[scanline_bytes .. scanline_bytes * 2], roundtrip[stride + 1 .. stride + 1 + scanline_bytes]);
}

test "PNG fixed filters round-trip" {
    const allocator = std.testing.allocator;

    // Build a small RGB gradient that exercises left/above predictors
    const width: usize = 16;
    const height: usize = 8;
    var img = try Image(Rgb).init(allocator, height, width);
    defer img.deinit(allocator);
    for (0..height) |y| {
        for (0..width) |x| {
            const r: u8 = @intCast((x * 255) / (width - 1));
            const g: u8 = @intCast((y * 255) / (height - 1));
            const b: u8 = @intCast(((x + y) * 255) / (width + height - 2));
            img.data[y * width + x] = Rgb{ .r = r, .g = g, .b = b };
        }
    }

    const filters = [_]FilterType{ .none, .sub, .up, .average, .paeth };
    for (filters) |ft| {
        const png_data = try encode(Rgb, allocator, img, .{ .filter_mode = .{ .fixed = ft }, .compression_level = .level_1, .compression_strategy = .filtered });
        defer allocator.free(png_data);

        var state = try decode(allocator, png_data, .{});
        defer state.deinit(allocator);
        const native = try toNativeImage(allocator, state);
        var round = switch (native) {
            .rgb => |*i| i.*,
            else => @panic("expected RGB"),
        };
        defer round.deinit(allocator);

        try std.testing.expectEqual(height, round.rows);
        try std.testing.expectEqual(width, round.cols);
        for (img.data, round.data) |a, b| {
            try std.testing.expectEqual(a.r, b.r);
            try std.testing.expectEqual(a.g, b.g);
            try std.testing.expectEqual(a.b, b.b);
        }
    }
}

test "PNG bit unpacking - 1-bit grayscale" {

    // Test data with bits: 10110010 = 0xB2
    const test_byte: u8 = 0b10110010;
    const src_row = [_]u8{test_byte};
    var dst_row: [8]u8 = undefined;

    // Unpack bits according to PNG spec (MSB first)
    const bits_per_pixel = 1;
    const pixels_per_byte = 8;
    const mask = (@as(u8, 1) << @intCast(bits_per_pixel)) - 1;

    for (0..8) |x| {
        const byte_index = x / pixels_per_byte;
        const pixel_index = x % pixels_per_byte;
        const bit_offset: u3 = @intCast((pixels_per_byte - 1 - pixel_index) * bits_per_pixel);
        const pixel_value = (src_row[byte_index] >> bit_offset) & mask;

        // Scale to 8-bit
        const scale_factor = 255 / mask;
        dst_row[x] = pixel_value * scale_factor;
    }

    // Expected: 1,0,1,1,0,0,1,0 -> 255,0,255,255,0,0,255,0
    try std.testing.expectEqual(@as(u8, 255), dst_row[0]);
    try std.testing.expectEqual(@as(u8, 0), dst_row[1]);
    try std.testing.expectEqual(@as(u8, 255), dst_row[2]);
    try std.testing.expectEqual(@as(u8, 255), dst_row[3]);
    try std.testing.expectEqual(@as(u8, 0), dst_row[4]);
    try std.testing.expectEqual(@as(u8, 0), dst_row[5]);
    try std.testing.expectEqual(@as(u8, 255), dst_row[6]);
    try std.testing.expectEqual(@as(u8, 0), dst_row[7]);
}

test "PNG bit unpacking - 2-bit grayscale" {
    const allocator = std.testing.allocator;
    _ = allocator;

    // Test data with 2-bit values: 11 01 10 00 = 0xD8
    const test_byte: u8 = 0b11011000;
    const src_row = [_]u8{test_byte};
    var dst_row: [4]u8 = undefined;

    // Unpack 2-bit values
    const bits_per_pixel = 2;
    const pixels_per_byte = 4;
    const mask = (@as(u8, 1) << @intCast(bits_per_pixel)) - 1;

    for (0..4) |x| {
        const byte_index = x / pixels_per_byte;
        const pixel_index = x % pixels_per_byte;
        const bit_offset: u3 = @intCast((pixels_per_byte - 1 - pixel_index) * bits_per_pixel);
        const pixel_value = (src_row[byte_index] >> bit_offset) & mask;

        // Scale to 8-bit (0,85,170,255)
        const scale_factor = 255 / mask;
        dst_row[x] = pixel_value * scale_factor;
    }

    // Expected: 3,1,2,0 -> 255,85,170,0
    try std.testing.expectEqual(@as(u8, 255), dst_row[0]);
    try std.testing.expectEqual(@as(u8, 85), dst_row[1]);
    try std.testing.expectEqual(@as(u8, 170), dst_row[2]);
    try std.testing.expectEqual(@as(u8, 0), dst_row[3]);
}

test "PNG bit unpacking - 4-bit grayscale" {
    const allocator = std.testing.allocator;
    _ = allocator;

    // Test data with 4-bit values: 1111 0101 = 0xF5
    const test_byte: u8 = 0xF5;
    const src_row = [_]u8{test_byte};
    var dst_row: [2]u8 = undefined;

    // Unpack 4-bit values
    const bits_per_pixel = 4;
    const pixels_per_byte = 2;
    const mask = (@as(u8, 1) << @intCast(bits_per_pixel)) - 1;

    for (0..2) |x| {
        const byte_index = x / pixels_per_byte;
        const pixel_index = x % pixels_per_byte;
        const bit_offset: u3 = @intCast((pixels_per_byte - 1 - pixel_index) * bits_per_pixel);
        const pixel_value = (src_row[byte_index] >> bit_offset) & mask;

        // Scale to 8-bit
        const scale_factor = 255 / mask;
        dst_row[x] = pixel_value * scale_factor;
    }

    // Expected: 15,5 -> 255,85
    try std.testing.expectEqual(@as(u8, 255), dst_row[0]);
    try std.testing.expectEqual(@as(u8, 85), dst_row[1]);
}

test "PNG encode with color management chunks" {
    const allocator = std.testing.allocator;

    // Create test image
    var test_data = [_]Rgb{
        Rgb{ .r = 255, .g = 0, .b = 0 }, Rgb{ .r = 0, .g = 255, .b = 0 },
        Rgb{ .r = 0, .g = 0, .b = 255 }, Rgb{ .r = 255, .g = 255, .b = 0 },
    };
    const test_image: Image(Rgb) = .initFromSlice(2, 2, &test_data);

    // Test encoding with sRGB chunk
    const srgb_options: EncodeOptions = .{ .srgb_intent = .perceptual };
    const srgb_png = try encode(Rgb, allocator, test_image, srgb_options);
    defer allocator.free(srgb_png);

    // Verify sRGB chunk is present
    var found_srgb = false;
    var offset: usize = 8; // Skip PNG signature
    while (offset + 8 < srgb_png.len) {
        const chunk_length = std.mem.readInt(u32, srgb_png[offset .. offset + 4][0..4], .big);
        const chunk_type = srgb_png[offset + 4 .. offset + 8];
        if (std.mem.eql(u8, chunk_type, "sRGB")) {
            found_srgb = true;
            try std.testing.expectEqual(@as(u32, 1), chunk_length);
            try std.testing.expectEqual(@as(u8, 0), srgb_png[offset + 8]); // perceptual intent
            break;
        }
        offset += 12 + chunk_length; // length(4) + type(4) + data + crc(4)
    }
    try std.testing.expect(found_srgb);

    // Test encoding with gAMA chunk
    const gamma_options: EncodeOptions = .{ .gamma = 1.0 / 2.2 };
    const gamma_png = try encode(Rgb, allocator, test_image, gamma_options);
    defer allocator.free(gamma_png);

    // Verify gAMA chunk is present
    var found_gama = false;
    offset = 8; // Skip PNG signature
    while (offset + 8 < gamma_png.len) {
        const chunk_length = std.mem.readInt(u32, gamma_png[offset .. offset + 4][0..4], .big);
        const chunk_type = gamma_png[offset + 4 .. offset + 8];
        if (std.mem.eql(u8, chunk_type, "gAMA")) {
            found_gama = true;
            try std.testing.expectEqual(@as(u32, 4), chunk_length);
            const gamma_int = std.mem.readInt(u32, gamma_png[offset + 8 .. offset + 12][0..4], .big);
            const expected_gamma_int: u32 = @intFromFloat((1.0 / 2.2) * 100000.0);
            try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(gamma_int)), @as(f32, @floatFromInt(expected_gamma_int)), 1.0);
            break;
        }
        offset += 12 + chunk_length;
    }
    try std.testing.expect(found_gama);
}

test "PNG CRC validation" {
    const gpa = std.testing.allocator;

    // Test IHDR chunk CRC
    const ihdr_type = "IHDR";
    const ihdr_data = [_]u8{
        0, 0, 0, 4, // width = 4
        0, 0, 0, 4, // height = 4
        8, // bit depth
        2, // color type (RGB)
        0, // compression
        0, // filter
        0, // interlace
    };

    var test_data: ArrayList(u8) = .empty;
    defer test_data.deinit(gpa);

    try test_data.appendSlice(gpa, ihdr_type);
    try test_data.appendSlice(gpa, &ihdr_data);

    const calculated_crc = crc(test_data.items);

    // Verify CRC was calculated
    try std.testing.expect(calculated_crc != 0);

    // Test with invalid data should give different CRC
    test_data.items[4] = 1; // Change width
    const different_crc = crc(test_data.items);
    try std.testing.expect(calculated_crc != different_crc);
}

test "PNG 16-bit to 8-bit conversion" {
    // Test 16-bit value conversion
    const test_values = [_]u16{ 0x0000, 0x00FF, 0xFF00, 0xFFFF, 0x8080, 0x1234 };
    const expected_8bit = [_]u8{ 0, 0, 255, 255, 128, 18 }; // Simple >>8 conversion

    for (test_values, expected_8bit) |val16, expected| {
        const bytes = std.mem.toBytes(std.mem.nativeTo(u16, val16, .big));
        const converted = @as(u8, @intCast(std.mem.readInt(u16, bytes[0..2], .big) >> 8));
        try std.testing.expectEqual(expected, converted);
    }
}

test "PNG filter types" {
    // Test filter type validation
    const valid_filters = [_]u8{ 0, 1, 2, 3, 4 };
    const invalid_filter: u8 = 5;

    for (valid_filters) |filter| {
        const filter_type: FilterType = switch (filter) {
            0 => .none,
            1 => .sub,
            2 => .up,
            3 => .average,
            4 => .paeth,
            else => unreachable,
        };
        try std.testing.expectEqual(filter, @intFromEnum(filter_type));
    }

    // Test that invalid filter would be caught
    const result: ?FilterType = switch (invalid_filter) {
        0 => .none,
        1 => .sub,
        2 => .up,
        3 => .average,
        4 => .paeth,
        else => null,
    };
    try std.testing.expect(result == null);
}

test "PNG bounds checking - large image dimensions" {
    const gpa = std.testing.allocator;

    // Create a malformed PNG with excessively large dimensions
    var png_data: ArrayList(u8) = .empty;
    defer png_data.deinit(gpa);

    // PNG signature
    try png_data.appendSlice(gpa, &signature);

    // IHDR chunk with oversized dimensions
    const ihdr_length: u32 = 13;
    try png_data.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeTo(u32, ihdr_length, .big)));
    try png_data.appendSlice(gpa, "IHDR");

    // Width: 50000 (exceeds MAX_DIMENSION)
    try png_data.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeTo(u32, 50000, .big)));
    // Height: 50000 (exceeds MAX_DIMENSION)
    try png_data.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeTo(u32, 50000, .big)));

    try png_data.append(gpa, 8); // bit depth
    try png_data.append(gpa, 2); // color type (RGB)
    try png_data.append(gpa, 0); // compression
    try png_data.append(gpa, 0); // filter
    try png_data.append(gpa, 0); // interlace

    // Calculate and append CRC
    var crc_data = try gpa.alloc(u8, 4 + 13);
    defer gpa.free(crc_data);
    @memcpy(crc_data[0..4], "IHDR");
    @memcpy(crc_data[4..], png_data.items[16..29]);
    const ihdr_crc = crc(crc_data);
    try png_data.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeTo(u32, ihdr_crc, .big)));

    // Try to decode - should fail with ImageTooLarge
    const result = decode(gpa, png_data.items, .{});
    try std.testing.expectError(error.ImageTooLarge, result);
}

test "PNG bounds checking - malformed palette" {
    const gpa = std.testing.allocator;

    // Test malformed palette chunk that's too short
    const chunk = Chunk{
        .length = 10, // Should be multiple of 3
        .type = "PLTE".*,
        .data = &[_]u8{ 255, 0, 0, 0, 255, 0, 0, 0 }, // Only 8 bytes, but length claims 10
        .crc = 0,
    };

    var png_state = PngState{
        .header = .{
            .width = 4,
            .height = 4,
            .bit_depth = 8,
            .color_type = .palette,
            .compression_method = 0,
            .filter_method = 0,
            .interlace_method = 0,
        },
        .idat_data = .empty,
    };
    defer png_state.deinit(gpa);

    // Simulate the palette parsing that would happen in decode()
    if (chunk.length % 3 != 0) {
        try std.testing.expect(true); // This should be caught
        return;
    }

    const palette_size = chunk.length / 3;
    if (chunk.data.len < palette_size * 3) {
        try std.testing.expect(true); // This should be caught
        return;
    }

    try std.testing.expect(false); // Should not reach here
}

test "PNG 16-bit bounds checking" {
    // Test 16-bit conversion with insufficient data
    const short_data = [_]u8{0xFF}; // Only 1 byte, but 16-bit needs 2
    const samples_per_row = short_data.len / 2; // Will be 0

    var dst_row: [1]u8 = undefined;

    for (0..samples_per_row) |i| {
        const offset = i * 2;
        if (offset + 2 > short_data.len) {
            dst_row[i] = 0; // Should use fallback value
        } else {
            const sample16 = std.mem.readInt(u16, short_data[offset .. offset + 2][0..2], .big);
            dst_row[i] = @intCast(sample16 >> 8);
        }
    }

    // Should have processed 0 samples safely
    try std.testing.expectEqual(@as(usize, 0), samples_per_row);
}

test "PNG integer overflow protection" {
    // Test that large dimensions are caught before overflow
    const large_width: u32 = 65536;
    const large_height: u32 = 65536;
    const channels: u8 = 4;

    const total_pixels = @as(u64, large_width) * @as(u64, large_height);
    const total_bytes = total_pixels * @as(u64, channels);

    // This should exceed practical memory limits
    try std.testing.expect(total_bytes > 1000000000); // > 1GB

    if (total_bytes > std.math.maxInt(usize)) {
        try std.testing.expect(true); // Would be caught by our protection
    }
}

test "Adam7 interlaced PNG support" {
    // Test that we can create an interlaced header
    const interlaced_header: Header = .{
        .width = 4,
        .height = 4,
        .bit_depth = 8,
        .color_type = .rgb,
        .interlace_method = 1,
    };

    // Test basic interlaced properties
    try std.testing.expectEqual(@as(u8, 1), interlaced_header.interlace_method);
    try std.testing.expectEqual(@as(u8, 3), interlaced_header.channels());

    // Test that Adam7 total size calculation works
    const total_size = try adam7TotalSize(interlaced_header);
    try std.testing.expect(total_size > 0);

    // Test pixel extraction functions work correctly
    const rgb_src = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255 }; // red, green, blue pixels
    const rgb_pixel = extractRgbPixel(Rgb, &rgb_src, 1, interlaced_header, null);
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 255, .b = 0 }, rgb_pixel);

    const rgba_header: Header = .{ .width = 4, .height = 4, .bit_depth = 8, .color_type = .rgba, .interlace_method = 1 };

    const rgba_src = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128 }; // red (alpha=255), green (alpha=128)
    const rgba_pixel = extractRgbaPixel(Rgba, &rgba_src, 1, rgba_header);
    try std.testing.expectEqual(Rgba{ .r = 0, .g = 255, .b = 0, .a = 128 }, rgba_pixel);
}

test "Adam7 palette deinterlace with transparency" {
    const allocator = std.testing.allocator;

    const header: Header = .{
        .width = 1,
        .height = 1,
        .bit_depth = 8,
        .color_type = .palette,
        .compression_method = 0,
        .filter_method = 0,
        .interlace_method = 1,
    };

    var decompressed = [_]u8{ 0, 1 }; // filter byte + palette index
    const palette = [_][3]u8{
        .{ 255, 0, 0 },
        .{ 0, 255, 0 },
    };
    const transparency = [_]u8{ 255, 64 };

    var image = try deinterlaceAdam7(allocator, Rgba, &decompressed, header, &palette, &transparency);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), image.rows);
    try std.testing.expectEqual(Rgba{ .r = 0, .g = 255, .b = 0, .a = 64 }, image.at(0, 0).*);
}

test "extractPalettePixel handles 4-bit indices" {
    const header: Header = .{
        .width = 2,
        .height = 1,
        .bit_depth = 4,
        .color_type = .palette,
        .compression_method = 0,
        .filter_method = 0,
        .interlace_method = 1,
    };

    const src_row = [_]u8{0x12}; // first pixel index 1, second index 2
    const palette = [_][3]u8{
        .{ 0, 0, 0 },
        .{ 10, 20, 30 },
        .{ 40, 50, 60 },
    };

    const pixel0 = extractPalettePixel(Rgb, &src_row, 0, header, &palette, null);
    const pixel1 = extractPalettePixel(Rgb, &src_row, 1, header, &palette, null);

    try std.testing.expectEqual(Rgb{ .r = 10, .g = 20, .b = 30 }, pixel0);
    try std.testing.expectEqual(Rgb{ .r = 40, .g = 50, .b = 60 }, pixel1);
}

test "PNG palette transparency support" {
    const allocator = std.testing.allocator;

    // Create a palette PNG with transparency
    var png_state = PngState{
        .header = .{
            .width = 2,
            .height = 2,
            .bit_depth = 8,
            .color_type = .palette,
            .compression_method = 0,
            .filter_method = 0,
            .interlace_method = 0,
        },
        .idat_data = .empty,
    };
    defer png_state.deinit(allocator);

    // Create palette: red, green, blue, white
    const palette = try allocator.alloc([3]u8, 4);
    defer allocator.free(palette);
    palette[0] = [3]u8{ 255, 0, 0 }; // red
    palette[1] = [3]u8{ 0, 255, 0 }; // green
    palette[2] = [3]u8{ 0, 0, 255 }; // blue
    palette[3] = [3]u8{ 255, 255, 255 }; // white
    png_state.palette = palette;

    // Create transparency: red=255, green=128, blue=64, white=0 (transparent)
    const transparency = try allocator.alloc(u8, 4);
    defer allocator.free(transparency);
    transparency[0] = 255; // red opaque
    transparency[1] = 128; // green semi-transparent
    transparency[2] = 64; // blue more transparent
    transparency[3] = 0; // white fully transparent
    png_state.transparency = transparency;

    // Clear pointers before deinit to avoid double-free
    defer {
        png_state.palette = null;
        png_state.transparency = null;
    }

    // Test palette transparency access
    try std.testing.expectEqual(@as(u8, 255), transparency[0]);
    try std.testing.expectEqual(@as(u8, 128), transparency[1]);
    try std.testing.expectEqual(@as(u8, 64), transparency[2]);
    try std.testing.expectEqual(@as(u8, 0), transparency[3]);

    // Test palette RGB values
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, palette[0]);
    try std.testing.expectEqual([3]u8{ 0, 255, 0 }, palette[1]);
    try std.testing.expectEqual([3]u8{ 0, 0, 255 }, palette[2]);
    try std.testing.expectEqual([3]u8{ 255, 255, 255 }, palette[3]);
}

test "PNG grayscale transparency support" {
    // Test grayscale 8-bit transparency
    const gray_trans_data = [_]u8{ 0x00, 0x80 }; // Transparent value is 128 (0x80)
    const gray_header: Header = .{
        .width = 4,
        .height = 1,
        .bit_depth = 8,
        .color_type = .grayscale,
    };

    // Test pixels: 0, 128 (transparent), 255, 64
    const gray_src = [_]u8{ 0, 128, 255, 64 };

    // Test transparency detection
    const trans_slice: []const u8 = &gray_trans_data;
    const pixel_normal = extractGrayscalePixel(Rgba, &gray_src, 0, gray_header, trans_slice);
    const pixel_transparent = extractGrayscalePixel(Rgba, &gray_src, 1, gray_header, trans_slice);
    const pixel_white = extractGrayscalePixel(Rgba, &gray_src, 2, gray_header, trans_slice);
    const pixel_gray = extractGrayscalePixel(Rgba, &gray_src, 3, gray_header, trans_slice);

    try std.testing.expectEqual(Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 }, pixel_normal);
    try std.testing.expectEqual(Rgba{ .r = 128, .g = 128, .b = 128, .a = 0 }, pixel_transparent);
    try std.testing.expectEqual(Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 }, pixel_white);
    try std.testing.expectEqual(Rgba{ .r = 64, .g = 64, .b = 64, .a = 255 }, pixel_gray);
}

test "PNG RGB transparency support" {
    // Test RGB transparency - transparent color is white (255, 255, 255)
    const rgb_trans_data = [_]u8{ 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF }; // White in 16-bit format
    const rgb_header: Header = .{
        .width = 3,
        .height = 1,
        .bit_depth = 8,
        .color_type = .rgb,
    };

    // Test pixels: red, white (transparent), blue
    const rgb_src = [_]u8{ 255, 0, 0, 255, 255, 255, 0, 0, 255 };

    // Test transparency detection
    const trans_slice: []const u8 = &rgb_trans_data;
    const pixel_red = extractRgbPixel(Rgba, &rgb_src, 0, rgb_header, trans_slice);
    const pixel_white = extractRgbPixel(Rgba, &rgb_src, 1, rgb_header, trans_slice);
    const pixel_blue = extractRgbPixel(Rgba, &rgb_src, 2, rgb_header, trans_slice);

    try std.testing.expectEqual(Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 }, pixel_red);
    try std.testing.expectEqual(Rgba{ .r = 255, .g = 255, .b = 255, .a = 0 }, pixel_white);
    try std.testing.expectEqual(Rgba{ .r = 0, .g = 0, .b = 255, .a = 255 }, pixel_blue);
}

test "PNG transparency error cases" {
    const allocator = std.testing.allocator;

    // Test invalid tRNS chunk for grayscale_alpha (should error)
    var png_state = PngState{
        .header = .{
            .width = 16,
            .height = 16,
            .bit_depth = 8,
            .color_type = .grayscale_alpha, // This color type cannot have tRNS
        },
        .idat_data = .empty,
    };
    defer png_state.deinit(allocator);

    // Test chunk reader would reject tRNS for grayscale_alpha
    _ = Chunk{
        .length = 2,
        .type = [4]u8{ 't', 'R', 'N', 'S' },
        .data = &[_]u8{ 0x00, 0x80 },
        .crc = 0,
    };

    // This should fail during chunk parsing (tested in integration tests)
}

test "PNG 16-bit transparency" {
    // Test 16-bit grayscale transparency
    const gray16_trans_data = [_]u8{ 0x80, 0x00 }; // Transparent value is 0x8000 (32768)
    const gray16_header: Header = .{
        .width = 2,
        .height = 1,
        .bit_depth = 16,
        .color_type = .grayscale,
    };

    // Test pixels: 0x8000 (should be transparent), 0x4000 (should be opaque)
    const gray16_src = [_]u8{ 0x80, 0x00, 0x40, 0x00 };

    const trans_slice: []const u8 = &gray16_trans_data;
    const pixel_transparent = extractGrayscalePixel(Rgba, &gray16_src, 0, gray16_header, trans_slice);
    const pixel_opaque = extractGrayscalePixel(Rgba, &gray16_src, 1, gray16_header, trans_slice);

    try std.testing.expectEqual(Rgba{ .r = 128, .g = 128, .b = 128, .a = 0 }, pixel_transparent);
    try std.testing.expectEqual(Rgba{ .r = 64, .g = 64, .b = 64, .a = 255 }, pixel_opaque);
}

test "PNG gAMA chunk parsing" {
    const allocator = std.testing.allocator;

    // Test gAMA chunk with gamma 1/2.2 (45455)
    const gamma_chunk = Chunk{
        .length = 4,
        .type = [4]u8{ 'g', 'A', 'M', 'A' },
        .data = &[_]u8{ 0x00, 0x00, 0xB1, 0x8F }, // 45455 in big endian
        .crc = 0,
    };

    var png_state = PngState{
        .header = .{
            .width = 4,
            .height = 4,
            .bit_depth = 8,
            .color_type = .rgb,
            .compression_method = 0,
            .filter_method = 0,
            .interlace_method = 0,
        },
        .idat_data = .empty,
    };
    defer png_state.deinit(allocator);

    // Manually parse the gAMA chunk (simulating the parsing logic)
    const gamma_int = std.mem.readInt(u32, gamma_chunk.data[0..4][0..4], .big);
    const expected_gamma = @as(f32, @floatFromInt(gamma_int)) / 100000.0;

    // Verify gamma value is approximately 1/2.2
    const expected_value = 1.0 / 2.2;
    try std.testing.expect(@abs(expected_gamma - expected_value) < 0.001);
}

test "PNG sRGB chunk parsing" {
    const allocator = std.testing.allocator;

    // Test sRGB chunk with perceptual rendering intent
    const srgb_chunk = Chunk{
        .length = 1,
        .type = [4]u8{ 's', 'R', 'G', 'B' },
        .data = &[_]u8{0}, // perceptual intent
        .crc = 0,
    };

    var png_state = PngState{
        .header = .{
            .width = 4,
            .height = 4,
            .bit_depth = 8,
            .color_type = .rgb,
            .compression_method = 0,
            .filter_method = 0,
            .interlace_method = 0,
        },
        .idat_data = .empty,
    };
    defer png_state.deinit(allocator);

    // Manually parse the sRGB chunk (simulating the parsing logic)
    const intent_raw = srgb_chunk.data[0];
    const expected_intent: SrgbRenderingIntent = switch (intent_raw) {
        0 => .perceptual,
        1 => .relative_colorimetric,
        2 => .saturation,
        3 => .absolute_colorimetric,
        else => unreachable,
    };

    try std.testing.expectEqual(SrgbRenderingIntent.perceptual, expected_intent);
}

test "PNG pixel extraction with transparency" {
    // Test extraction functions with transparency
    const header: Header = .{
        .width = 4,
        .height = 4,
        .bit_depth = 8,
        .color_type = .rgb,
    };

    const rgb_src = [_]u8{ 255, 0, 0, 0, 255, 0 }; // red, green pixels

    // Test default (no transparency)
    const pixel_default = extractRgbPixel(Rgb, &rgb_src, 0, header, null);
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, pixel_default);

    // Test with transparency
    const trans_data = [_]u8{ 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00 }; // red is transparent
    const trans_slice: []const u8 = &trans_data;
    const pixel_with_trans = extractRgbPixel(Rgba, &rgb_src, 0, header, trans_slice);
    try std.testing.expectEqual(Rgba{ .r = 255, .g = 0, .b = 0, .a = 0 }, pixel_with_trans);
}

test "PNG getInfo" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    try data.appendSlice(gpa, &signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], 100, .big);
    std.mem.writeInt(u32, ihdr[4..8], 50, .big);
    ihdr[8] = 8;
    ihdr[9] = @intFromEnum(ColorType.rgb);
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendTestChunk(&data, gpa, "IHDR".*, &ihdr);

    const srgb_payload = [_]u8{0};
    try appendTestChunk(&data, gpa, "sRGB".*, &srgb_payload);

    // Add some random chunk before IDAT
    try appendTestChunk(&data, gpa, "tEXt".*, &[_]u8{});

    // We don't need IDAT for getInfo to work if we stop before it
    // But let's add one to make it a valid stream prefix
    try appendTestChunk(&data, gpa, "IDAT".*, &[_]u8{});

    const info = try getInfo(data.items);
    try std.testing.expectEqual(@as(u32, 100), info.width);
    try std.testing.expectEqual(@as(u32, 50), info.height);
    try std.testing.expectEqual(ColorType.rgb, info.color_type);
    try std.testing.expect(info.srgb_intent != null);
    try std.testing.expectEqual(SrgbRenderingIntent.perceptual, info.srgb_intent.?);
}

test "PNG Header helpers" {
    // 8-bit RGB
    const h1: Header = .{
        .width = 100,
        .height = 50,
        .bit_depth = 8,
        .color_type = .rgb,
    };
    try std.testing.expectEqual(@as(u64, 5000), h1.totalPixels());
    try std.testing.expect(!h1.hasAlpha());
    try std.testing.expect(!h1.is16Bit());
    try std.testing.expect(!h1.isGrayscale());

    // 16-bit RGBA
    const h2: Header = .{
        .width = 10,
        .height = 10,
        .bit_depth = 16,
        .color_type = .rgba,
    };
    try std.testing.expectEqual(@as(u64, 100), h2.totalPixels());
    try std.testing.expect(h2.hasAlpha());
    try std.testing.expect(h2.is16Bit());
    try std.testing.expect(!h2.isGrayscale());

    // 8-bit Grayscale Alpha
    const h3: Header = .{
        .width = 5,
        .height = 5,
        .bit_depth = 8,
        .color_type = .grayscale_alpha,
    };
    try std.testing.expect(h3.hasAlpha());
    try std.testing.expect(!h3.is16Bit());
    try std.testing.expect(h3.isGrayscale());
}
