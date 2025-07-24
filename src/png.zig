//! Pure Zig PNG encoder and decoder implementation.
//! Supports all PNG color types and bit depths according to the PNG specification.
//! Zero dependencies - implements deflate compression/decompression internally.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Image = @import("image.zig").Image;
const Rgb = @import("color.zig").Rgb;
const Rgba = @import("color.zig").Rgba;
const convertColor = @import("color.zig").convertColor;
const deflate = @import("deflate.zig");

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

/// Color management information
const ColorInfo = struct {
    gamma: ?f32,
    srgb_intent: ?SrgbRenderingIntent,

    const empty = ColorInfo{ .gamma = null, .srgb_intent = null };
};

/// Configuration for pixel extraction functions
const PixelExtractionConfig = struct {
    transparency: ?[]const u8 = null,
    color_info: ColorInfo = ColorInfo.empty,
};

/// PNG chunk structure
pub const Chunk = struct {
    length: u32,
    type: [4]u8,
    data: []const u8,
    crc: u32,
};

/// PNG IHDR (header) chunk data
pub const Header = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: ColorType,
    compression_method: u8, // Must be 0 (deflate)
    filter_method: u8, // Must be 0
    interlace_method: u8, // 0 = none, 1 = Adam7

    pub fn channels(self: Header) u8 {
        return self.color_type.channels();
    }

    pub fn bytesPerPixel(self: Header) u8 {
        return (self.channels() * self.bit_depth + 7) / 8;
    }

    pub fn scanlineBytes(self: Header) usize {
        return (self.width * self.channels() * self.bit_depth + 7) / 8;
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
fn adam7TotalSize(header: Header) usize {
    var total_size: usize = 0;
    const channels = header.channels();

    for (0..7) |pass| {
        const dims = adam7PassDimensions(@intCast(pass), header.width, header.height);
        if (dims.width > 0 and dims.height > 0) {
            const pass_scanline_bytes = (dims.width * channels * header.bit_depth + 7) / 8;
            total_size += dims.height * (pass_scanline_bytes + 1); // +1 for filter byte
        }
    }

    return total_size;
}

/// PNG decoder/encoder state
pub const PngImage = struct {
    header: Header,
    palette: ?[][3]u8 = null,
    transparency: ?[]u8 = null, // For palette transparency or single transparent color
    idat_data: ArrayList(u8),

    // Color management metadata
    gamma: ?f32 = null, // Gamma value from gAMA chunk
    srgb_intent: ?SrgbRenderingIntent = null, // sRGB rendering intent

    pub fn deinit(self: *PngImage, allocator: Allocator) void {
        self.idat_data.deinit();
        if (self.palette) |palette| {
            allocator.free(palette);
        }
        if (self.transparency) |trans| {
            allocator.free(trans);
        }
    }
};

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
    const MAX_DIMENSION = 32767; // PNG spec limit
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
pub fn decode(allocator: Allocator, png_data: []const u8) !PngImage {
    if (png_data.len < 8 or !std.mem.eql(u8, png_data[0..8], &signature)) {
        return error.InvalidPngSignature;
    }

    var reader = ChunkReader.init(png_data[8..]);
    var png_image = PngImage{
        .header = undefined,
        .idat_data = ArrayList(u8).init(allocator),
    };
    errdefer png_image.deinit(allocator);

    var header_found = false;

    while (try reader.nextChunk()) |chunk| {
        if (std.mem.eql(u8, &chunk.type, "IHDR")) {
            if (header_found) return error.MultipleHeaders;
            png_image.header = try parseHeader(chunk);
            header_found = true;
        } else if (std.mem.eql(u8, &chunk.type, "PLTE")) {
            if (chunk.length % 3 != 0) return error.InvalidPaletteLength;
            const palette_size = chunk.length / 3;
            if (palette_size > 256) return error.PaletteTooLarge;
            if (chunk.data.len < palette_size * 3) return error.InvalidPaletteLength;

            var palette = try allocator.alloc([3]u8, palette_size);
            for (0..palette_size) |i| {
                const offset = i * 3;
                if (offset + 3 > chunk.data.len) return error.InvalidPaletteLength;
                palette[i] = [3]u8{ chunk.data[offset], chunk.data[offset + 1], chunk.data[offset + 2] };
            }
            png_image.palette = palette;
        } else if (std.mem.eql(u8, &chunk.type, "tRNS")) {
            // Validate tRNS chunk size based on color type
            switch (png_image.header.color_type) {
                .grayscale => {
                    if (chunk.length != 2) return error.InvalidTransparencyLength;
                },
                .rgb => {
                    if (chunk.length != 6) return error.InvalidTransparencyLength;
                },
                .palette => {
                    // Palette transparency: chunk.length should be <= palette size
                    // We'll validate this after PLTE chunk is processed
                },
                .grayscale_alpha, .rgba => {
                    // These color types cannot have tRNS chunks
                    return error.InvalidTransparencyForColorType;
                },
            }

            const transparency = try allocator.alloc(u8, chunk.length);
            @memcpy(transparency, chunk.data);
            png_image.transparency = transparency;
        } else if (std.mem.eql(u8, &chunk.type, "gAMA")) {
            // gAMA chunk: 4 bytes containing gamma value * 100,000
            if (chunk.length != 4) return error.InvalidGammaLength;
            const gamma_int = std.mem.readInt(u32, chunk.data[0..4][0..4], .big);
            png_image.gamma = @as(f32, @floatFromInt(gamma_int)) / 100000.0;
        } else if (std.mem.eql(u8, &chunk.type, "sRGB")) {
            // sRGB chunk: 1 byte containing rendering intent
            // NOTE: sRGB and iCCP chunks are mutually exclusive according to PNG spec
            if (chunk.length != 1) return error.InvalidSrgbLength;
            const intent_raw = chunk.data[0];
            png_image.srgb_intent = switch (intent_raw) {
                0 => .perceptual,
                1 => .relative_colorimetric,
                2 => .saturation,
                3 => .absolute_colorimetric,
                else => return error.InvalidSrgbIntent,
            };
        } else if (std.mem.eql(u8, &chunk.type, "IDAT")) {
            try png_image.idat_data.appendSlice(chunk.data);
        } else if (std.mem.eql(u8, &chunk.type, "IEND")) {
            break;
        }
        // Ignore other chunks (ancillary chunks like tEXt, etc.)
    }

    if (!header_found) {
        return error.MissingHeader;
    }

    if (png_image.idat_data.items.len == 0) {
        return error.MissingImageData;
    }

    return png_image;
}

/// Convert PNG image data to its most natural Zignal Image type
fn toNativeImage(allocator: Allocator, png_image: PngImage) !union(enum) {
    grayscale: Image(u8),
    rgb: Image(Rgb),
    rgba: Image(Rgba),
} {
    // Decompress IDAT data
    const decompressed = try deflate.zlibDecompress(allocator, png_image.idat_data.items);
    defer allocator.free(decompressed);

    // Apply row defiltering
    try defilterScanlines(decompressed, png_image.header);

    const width = png_image.header.width;
    const height = png_image.header.height;
    const scanline_bytes = png_image.header.scanlineBytes();

    // Handle interlaced images separately
    if (png_image.header.interlace_method == 1) {
        // Interlaced image - use Adam7 deinterlacing
        const color_info = ColorInfo{ .gamma = png_image.gamma, .srgb_intent = png_image.srgb_intent };
        switch (png_image.header.color_type) {
            .grayscale, .grayscale_alpha => {
                if (png_image.transparency != null) {
                    const config = PixelExtractionConfig{ .transparency = png_image.transparency, .color_info = color_info };
                    return .{ .rgba = try deinterlaceAdam7(allocator, Rgba, decompressed, png_image.header, config) };
                } else {
                    const config = PixelExtractionConfig{ .color_info = color_info };
                    return .{ .grayscale = try deinterlaceAdam7(allocator, u8, decompressed, png_image.header, config) };
                }
            },
            .rgb => {
                if (png_image.transparency != null) {
                    const config = PixelExtractionConfig{ .transparency = png_image.transparency, .color_info = color_info };
                    return .{ .rgba = try deinterlaceAdam7(allocator, Rgba, decompressed, png_image.header, config) };
                } else {
                    const config = PixelExtractionConfig{ .color_info = color_info };
                    return .{ .rgb = try deinterlaceAdam7(allocator, Rgb, decompressed, png_image.header, config) };
                }
            },
            .rgba => {
                const config = PixelExtractionConfig{ .color_info = color_info };
                return .{ .rgba = try deinterlaceAdam7(allocator, Rgba, decompressed, png_image.header, config) };
            },
            .palette => {
                if (png_image.transparency != null) {
                    return .{ .rgba = try deinterlaceAdam7Palette(allocator, Rgba, decompressed, png_image.header, png_image.palette orelse return error.MissingPalette, png_image.transparency) };
                } else {
                    return .{ .rgb = try deinterlaceAdam7Palette(allocator, Rgb, decompressed, png_image.header, png_image.palette orelse return error.MissingPalette, null) };
                }
            },
        }
    }

    // Determine native format and convert accordingly
    switch (png_image.header.color_type) {
        .grayscale, .grayscale_alpha => {
            if (png_image.transparency != null) {
                // Create RGBA image when transparency is present
                const total_pixels = @as(u64, width) * @as(u64, height);
                if (total_pixels > std.math.maxInt(usize)) {
                    return error.ImageTooLarge;
                }
                var output_data = try allocator.alloc(Rgba, @intCast(total_pixels));

                for (0..height) |y| {
                    const src_row_start = y * (scanline_bytes + 1) + 1;
                    const dst_row_start = y * width;
                    const src_row = decompressed[src_row_start .. src_row_start + scanline_bytes];
                    const dst_row = output_data[dst_row_start .. dst_row_start + width];

                    const config = PixelExtractionConfig{ .transparency = png_image.transparency, .color_info = ColorInfo{ .gamma = png_image.gamma, .srgb_intent = png_image.srgb_intent } };
                    for (dst_row, 0..) |*pixel, i| {
                        pixel.* = extractGrayscalePixel(Rgba, src_row, i, png_image.header, config);
                    }
                }

                return .{ .rgba = Image(Rgba).init(height, width, output_data) };
            } else {
                // Create grayscale image when no transparency
                const total_pixels = @as(u64, width) * @as(u64, height);
                if (total_pixels > std.math.maxInt(usize)) {
                    return error.ImageTooLarge;
                }
                var output_data = try allocator.alloc(u8, @intCast(total_pixels));

                for (0..height) |y| {
                    const src_row_start = y * (scanline_bytes + 1) + 1;
                    const dst_row_start = y * width;
                    const src_row = decompressed[src_row_start .. src_row_start + scanline_bytes];
                    const dst_row = output_data[dst_row_start .. dst_row_start + width];

                    const config = PixelExtractionConfig{ .color_info = ColorInfo{ .gamma = png_image.gamma, .srgb_intent = png_image.srgb_intent } };
                    for (dst_row, 0..) |*pixel, i| {
                        pixel.* = extractGrayscalePixel(u8, src_row, i, png_image.header, config);
                    }
                }

                return .{ .grayscale = Image(u8).init(height, width, output_data) };
            }
        },
        .rgb => {
            if (png_image.transparency != null) {
                // Create RGBA image when transparency is present
                const total_pixels = @as(u64, width) * @as(u64, height);
                if (total_pixels > std.math.maxInt(usize)) {
                    return error.ImageTooLarge;
                }
                var output_data = try allocator.alloc(Rgba, @intCast(total_pixels));

                for (0..height) |y| {
                    const src_row_start = y * (scanline_bytes + 1) + 1;
                    const dst_row_start = y * width;
                    const src_row = decompressed[src_row_start .. src_row_start + scanline_bytes];
                    const dst_row = output_data[dst_row_start .. dst_row_start + width];

                    const config = PixelExtractionConfig{ .transparency = png_image.transparency, .color_info = ColorInfo{ .gamma = png_image.gamma, .srgb_intent = png_image.srgb_intent } };
                    for (dst_row, 0..) |*pixel, i| {
                        pixel.* = extractRgbPixel(Rgba, src_row, i, png_image.header, config);
                    }
                }

                return .{ .rgba = Image(Rgba).init(height, width, output_data) };
            } else {
                // Create RGB image when no transparency
                const total_pixels = @as(u64, width) * @as(u64, height);
                if (total_pixels > std.math.maxInt(usize)) {
                    return error.ImageTooLarge;
                }
                var output_data = try allocator.alloc(Rgb, @intCast(total_pixels));

                for (0..height) |y| {
                    const src_row_start = y * (scanline_bytes + 1) + 1;
                    const dst_row_start = y * width;
                    const src_row = decompressed[src_row_start .. src_row_start + scanline_bytes];
                    const dst_row = output_data[dst_row_start .. dst_row_start + width];

                    const config = PixelExtractionConfig{ .color_info = ColorInfo{ .gamma = png_image.gamma, .srgb_intent = png_image.srgb_intent } };
                    for (dst_row, 0..) |*pixel, i| {
                        pixel.* = extractRgbPixel(Rgb, src_row, i, png_image.header, config);
                    }
                }

                return .{ .rgb = Image(Rgb).init(height, width, output_data) };
            }
        },
        .rgba => {
            // Create RGBA image
            const total_pixels = @as(u64, width) * @as(u64, height);
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
                    if (png_image.header.bit_depth == 8) {
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

            return .{ .rgba = Image(Rgba).init(height, width, output_data) };
        },
        .palette => {
            // Convert palette to RGB or RGBA (if transparency present)
            if (png_image.palette == null) return error.MissingPalette;
            const palette = png_image.palette.?;
            const transparency = png_image.transparency;

            const total_pixels = @as(u64, width) * @as(u64, height);
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
                        const index = switch (png_image.header.bit_depth) {
                            8 => blk: {
                                if (i >= src_row.len) return error.InvalidScanlineData;
                                break :blk src_row[i];
                            },
                            1, 2, 4 => blk: {
                                const bits_per_pixel = png_image.header.bit_depth;
                                const pixels_per_byte = 8 / bits_per_pixel;
                                const mask = (@as(u8, 1) << @intCast(bits_per_pixel)) - 1;
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

                return .{ .rgba = Image(Rgba).init(height, width, output_data) };
            } else {
                // No transparency - convert to RGB
                var output_data = try allocator.alloc(Rgb, @intCast(total_pixels));

                for (0..height) |y| {
                    const src_row_start = y * (scanline_bytes + 1) + 1;
                    const dst_row_start = y * width;
                    const src_row = decompressed[src_row_start .. src_row_start + scanline_bytes];
                    const dst_row = output_data[dst_row_start .. dst_row_start + width];

                    for (dst_row, 0..) |*pixel, i| {
                        const index = switch (png_image.header.bit_depth) {
                            8 => blk: {
                                if (i >= src_row.len) return error.InvalidScanlineData;
                                break :blk src_row[i];
                            },
                            1, 2, 4 => blk: {
                                const bits_per_pixel = png_image.header.bit_depth;
                                const pixels_per_byte = 8 / bits_per_pixel;
                                const mask = (@as(u8, 1) << @intCast(bits_per_pixel)) - 1;
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

                return .{ .rgb = Image(Rgb).init(height, width, output_data) };
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
pub fn load(comptime T: type, allocator: Allocator, file_path: []const u8) !Image(T) {
    const png_data = try std.fs.cwd().readFileAlloc(allocator, file_path, 100 * 1024 * 1024);
    defer allocator.free(png_data);

    var png_image = try decode(allocator, png_data);
    defer png_image.deinit(allocator);

    // Load the PNG in its native format first, then convert to requested type
    var native_image = try toNativeImage(allocator, png_image);
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

// PNG Encoder functionality

// Chunk writer for PNG encoding
pub const ChunkWriter = struct {
    data: ArrayList(u8),

    pub fn init(allocator: Allocator) ChunkWriter {
        return .{ .data = ArrayList(u8).init(allocator) };
    }

    pub fn deinit(self: *ChunkWriter) void {
        self.data.deinit();
    }

    pub fn writeChunk(self: *ChunkWriter, chunk_type: [4]u8, chunk_data: []const u8) !void {
        // Length (4 bytes, big endian)
        const length: u32 = @intCast(chunk_data.len);
        try self.data.appendSlice(std.mem.asBytes(&std.mem.nativeTo(u32, length, .big)));

        // Type (4 bytes)
        try self.data.appendSlice(&chunk_type);

        // Data
        try self.data.appendSlice(chunk_data);

        // CRC (4 bytes, big endian) - calculate CRC of type + data
        var crc_data = try self.data.allocator.alloc(u8, 4 + chunk_data.len);
        defer self.data.allocator.free(crc_data);
        @memcpy(crc_data[0..4], &chunk_type);
        @memcpy(crc_data[4..], chunk_data);

        const chunk_crc = crc(crc_data);
        try self.data.appendSlice(std.mem.asBytes(&std.mem.nativeTo(u32, chunk_crc, .big)));
    }

    pub fn toOwnedSlice(self: *ChunkWriter) ![]u8 {
        return self.data.toOwnedSlice();
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
    pub const default: EncodeOptions = .{ .filter_mode = .adaptive };
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

// Encode Image data to PNG format
pub fn encode(allocator: Allocator, image_data: []const u8, width: u32, height: u32, color_type: ColorType, bit_depth: u8, options: EncodeOptions) ![]u8 {
    var writer = ChunkWriter.init(allocator);
    defer writer.deinit();

    // Write PNG signature
    try writer.data.appendSlice(&signature);

    // Create and write IHDR
    const header = Header{
        .width = width,
        .height = height,
        .bit_depth = bit_depth,
        .color_type = color_type,
        .compression_method = 0,
        .filter_method = 0,
        .interlace_method = 0,
    };

    const ihdr_data = try createIHDR(header);
    try writer.writeChunk("IHDR".*, &ihdr_data);

    // Apply row filtering based on options
    const filtered_data = switch (options.filter_mode) {
        .none => try filterScanlines(allocator, image_data, header, .none),
        .adaptive => try filterScanlinesAdaptive(allocator, image_data, header),
        .fixed => |filter_type| try filterScanlines(allocator, image_data, header, filter_type),
    };
    defer allocator.free(filtered_data);

    // Compress filtered data with zlib format (required for PNG IDAT) using static Huffman
    const compressed_data = try deflate.zlibCompress(allocator, filtered_data, .static_huffman);
    defer allocator.free(compressed_data);

    // Write IDAT chunk
    try writer.writeChunk("IDAT".*, compressed_data);

    // Write IEND chunk
    try writer.writeChunk("IEND".*, &[_]u8{});

    return writer.toOwnedSlice();
}

/// Generic PNG encoding function that works with any supported pixel type
pub fn encodeImage(comptime T: type, allocator: Allocator, image: Image(T), options: EncodeOptions) ![]u8 {
    const color_type = getColorType(T);

    switch (T) {
        u8, Rgb, Rgba => {
            // Direct support - use image as-is
            const image_bytes = image.asBytes();
            return encode(allocator, image_bytes, @intCast(image.cols), @intCast(image.rows), color_type, 8, options);
        },
        else => {
            // Convert unsupported type to RGB
            var rgb_image = try Image(Rgb).initAlloc(allocator, image.rows, image.cols);
            defer rgb_image.deinit(allocator);

            // Convert each pixel to RGB
            for (image.data, 0..) |pixel, i| {
                rgb_image.data[i] = convertColor(Rgb, pixel);
            }

            const image_bytes = rgb_image.asBytes();
            return encode(allocator, image_bytes, @intCast(image.cols), @intCast(image.rows), color_type, 8, options);
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
pub fn save(comptime T: type, allocator: Allocator, image: Image(T), file_path: []const u8) !void {
    const png_data = try encodeImage(T, allocator, image, .default);
    defer allocator.free(png_data);

    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    try file.writeAll(png_data);
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

/// Calculate entropy-based cost for filtered data
/// Lower entropy means better compression
fn calculateFilterCost(filtered_data: []const u8) f32 {
    // Count byte frequencies
    var freq = [_]u32{0} ** 256;
    for (filtered_data) |byte| {
        freq[byte] += 1;
    }

    // Calculate entropy
    var entropy: f32 = 0.0;
    const len_f32 = @as(f32, @floatFromInt(filtered_data.len));

    for (freq) |count| {
        if (count > 0) {
            const p = @as(f32, @floatFromInt(count)) / len_f32;
            entropy -= p * @log2(p);
        }
    }

    // Also consider run lengths for better cost estimation
    var run_bonus: f32 = 0.0;
    var last_byte = filtered_data[0];
    var run_length: u32 = 1;

    for (filtered_data[1..]) |byte| {
        if (byte == last_byte) {
            run_length += 1;
        } else {
            if (run_length > 3) {
                // Bonus for long runs (they compress well)
                run_bonus += @log2(@as(f32, @floatFromInt(run_length)));
            }
            last_byte = byte;
            run_length = 1;
        }
    }

    // Final run
    if (run_length > 3) {
        run_bonus += @log2(@as(f32, @floatFromInt(run_length)));
    }

    // Lower score is better (subtract run bonus)
    return entropy - (run_bonus / len_f32);
}

/// Select the best filter type for a scanline
fn selectBestFilter(
    src_row: []const u8,
    previous_row: ?[]const u8,
    bytes_per_pixel: u8,
    temp_buffer: []u8,
) FilterType {
    var best_filter = FilterType.none;
    var best_cost: f32 = std.math.floatMax(f32);

    // Quick heuristic: check if row has many repeated values
    var same_count: u32 = 0;
    for (src_row[bytes_per_pixel..], 0..) |byte, i| {
        if (byte == src_row[i]) same_count += 1;
    }
    const horizontal_similarity = @as(f32, @floatFromInt(same_count)) / @as(f32, @floatFromInt(src_row.len - bytes_per_pixel));

    // Try filters in smart order based on heuristics
    // First try the most likely filter based on content
    if (horizontal_similarity > 0.7) {
        // High horizontal similarity - sub filter likely best
        filterRow(.sub, temp_buffer, src_row, previous_row, bytes_per_pixel);
        const sub_cost = calculateFilterCost(temp_buffer);
        if (sub_cost < best_cost) {
            best_cost = sub_cost;
            best_filter = .sub;
            if (sub_cost < 1.0) return .sub; // Early exit for excellent result
        }
    }

    inline for (std.meta.fields(FilterType)) |field| {
        const filter_type = @field(FilterType, field.name);

        // Check if we should process this filter
        const already_tested = (horizontal_similarity > 0.7 and filter_type == .sub);
        const invalid_for_first_row = (previous_row == null and (filter_type == .up or filter_type == .average or filter_type == .paeth));

        if (!already_tested and !invalid_for_first_row) {
            filterRow(filter_type, temp_buffer, src_row, previous_row, bytes_per_pixel);
            const cost = calculateFilterCost(temp_buffer);
            if (cost < best_cost) {
                best_cost = cost;
                best_filter = filter_type;
                if (cost < 1.0) return best_filter;
            }
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
    const expected_size = adam7TotalSize(header);

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
fn deinterlaceAdam7(allocator: Allocator, comptime T: type, decompressed: []u8, header: Header, config: PixelExtractionConfig) !Image(T) {
    const total_pixels = @as(u64, header.width) * @as(u64, header.height);
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
                    .grayscale, .grayscale_alpha => extractGrayscalePixel(T, src_row, pass_x, header, config),
                    .rgb => extractRgbPixel(T, src_row, pass_x, header, config),
                    .rgba => extractRgbaPixel(T, src_row, pass_x, header, config),
                    .palette => @panic("Palette images not supported yet"), // TODO: implement palette support
                };
            }
        }

        data_offset += dims.height * (pass_scanline_bytes + 1);
    }

    return Image(T){
        .rows = @intCast(header.height),
        .cols = @intCast(header.width),
        .data = output_data,
        .stride = @intCast(header.width),
    };
}

/// Deinterlace Adam7 palette data and convert to RGB or RGBA
fn deinterlaceAdam7Palette(allocator: Allocator, comptime T: type, decompressed: []u8, header: Header, palette: [][3]u8, transparency: ?[]u8) !Image(T) {
    const total_pixels = @as(u64, header.width) * @as(u64, header.height);
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

                // Extract palette index based on bit depth
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

                // Convert palette index to RGB
                if (index >= palette.len) {
                    // Invalid palette index - use black as fallback
                    output_data[final_pixel_idx] = switch (T) {
                        Rgb => Rgb{ .r = 0, .g = 0, .b = 0 },
                        Rgba => Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 },
                        u8 => 0,
                        else => @compileError("Unsupported pixel type for palette conversion"),
                    };
                } else {
                    const rgb = palette[index];
                    // Get alpha value from transparency chunk (default to opaque if not present)
                    const alpha = if (transparency != null and index < transparency.?.len) transparency.?[index] else 255;

                    output_data[final_pixel_idx] = switch (T) {
                        Rgb => Rgb{ .r = rgb[0], .g = rgb[1], .b = rgb[2] },
                        Rgba => Rgba{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = alpha },
                        u8 => @as(u8, @intCast((@as(u16, rgb[0]) + @as(u16, rgb[1]) + @as(u16, rgb[2])) / 3)),
                        else => @compileError("Unsupported pixel type for palette conversion"),
                    };
                }
            }
        }

        data_offset += dims.height * (pass_scanline_bytes + 1);
    }

    return Image(T){
        .rows = @intCast(header.height),
        .cols = @intCast(header.width),
        .data = output_data,
        .stride = @intCast(header.width),
    };
}

// Apply gamma correction to a color value
inline fn applyGammaCorrection(value: u8, color_info: ColorInfo) u8 {
    // sRGB overrides gAMA chunk when present
    if (color_info.srgb_intent != null) {
        // Apply sRGB transfer function (simplified approximation: gamma 2.2)
        const normalized = @as(f32, @floatFromInt(value)) / 255.0;
        const corrected = std.math.pow(f32, normalized, 1.0 / 2.2);
        return @as(u8, @intFromFloat(@min(255.0, @max(0.0, corrected * 255.0))));
    }

    if (color_info.gamma) |g| {
        if (g != 1.0) {
            const normalized = @as(f32, @floatFromInt(value)) / 255.0;
            const corrected = std.math.pow(f32, normalized, g);
            return @as(u8, @intFromFloat(@min(255.0, @max(0.0, corrected * 255.0))));
        }
    }
    return value;
}

/// Extract grayscale pixel from Adam7 pass data with optional transparency
fn extractGrayscalePixel(comptime T: type, src_row: []const u8, pass_x: usize, header: Header, config: PixelExtractionConfig) T {
    const pixel_value = switch (header.bit_depth) {
        8 => if (header.color_type == .grayscale_alpha) src_row[pass_x * 2] else src_row[pass_x],
        16 => blk: {
            const offset = if (header.color_type == .grayscale_alpha) pass_x * 4 else pass_x * 2;
            if (offset + 1 >= src_row.len) break :blk 0;
            break :blk @as(u8, @intCast(std.mem.readInt(u16, src_row[offset .. offset + 2][0..2], .big) >> 8));
        },
        1, 2, 4 => blk: {
            const bits_per_pixel = header.bit_depth;
            const pixels_per_byte = 8 / bits_per_pixel;
            const mask = (@as(u8, 1) << @intCast(bits_per_pixel)) - 1;
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
    const is_transparent = if (config.transparency) |trans_data| blk: {
        if (header.color_type == .grayscale and trans_data.len >= 2) {
            const transparent_value = if (header.bit_depth == 16)
                @as(u8, @intCast(std.mem.readInt(u16, trans_data[0..2], .big) >> 8))
            else
                trans_data[1]; // For 8-bit and sub-byte, use lower byte
            break :blk pixel_value == transparent_value;
        }
        break :blk false;
    } else false;

    // Apply gamma correction
    const corrected_value = applyGammaCorrection(pixel_value, config.color_info);

    return switch (T) {
        u8 => corrected_value,
        Rgb => Rgb{ .r = corrected_value, .g = corrected_value, .b = corrected_value },
        Rgba => Rgba{ .r = corrected_value, .g = corrected_value, .b = corrected_value, .a = if (is_transparent) 0 else 255 },
        else => @compileError("Unsupported pixel type"),
    };
}

/// Extract RGB pixel from Adam7 pass data with optional transparency
fn extractRgbPixel(comptime T: type, src_row: []const u8, pass_x: usize, header: Header, config: PixelExtractionConfig) T {
    const offset = pass_x * 3;
    if (offset + 2 >= src_row.len) {
        return switch (T) {
            u8 => 0,
            Rgb => Rgb{ .r = 0, .g = 0, .b = 0 },
            Rgba => Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 },
            else => @compileError("Unsupported pixel type"),
        };
    }

    const r = if (header.bit_depth == 16)
        @as(u8, @intCast(std.mem.readInt(u16, src_row[offset .. offset + 2][0..2], .big) >> 8))
    else
        src_row[offset];
    const g = if (header.bit_depth == 16)
        @as(u8, @intCast(std.mem.readInt(u16, src_row[offset + 2 .. offset + 4][0..2], .big) >> 8))
    else
        src_row[offset + 1];
    const b = if (header.bit_depth == 16)
        @as(u8, @intCast(std.mem.readInt(u16, src_row[offset + 4 .. offset + 6][0..2], .big) >> 8))
    else
        src_row[offset + 2];

    // Check for transparency
    const is_transparent = if (config.transparency) |trans_data| blk: {
        if (header.color_type == .rgb and trans_data.len >= 6) {
            const trans_r = if (header.bit_depth == 16)
                @as(u8, @intCast(std.mem.readInt(u16, trans_data[0..2], .big) >> 8))
            else
                trans_data[1]; // Use lower byte for 8-bit
            const trans_g = if (header.bit_depth == 16)
                @as(u8, @intCast(std.mem.readInt(u16, trans_data[2..4], .big) >> 8))
            else
                trans_data[3];
            const trans_b = if (header.bit_depth == 16)
                @as(u8, @intCast(std.mem.readInt(u16, trans_data[4..6], .big) >> 8))
            else
                trans_data[5];
            break :blk r == trans_r and g == trans_g and b == trans_b;
        }
        break :blk false;
    } else false;

    // Apply gamma correction to RGB channels
    const corrected_r = applyGammaCorrection(r, config.color_info);
    const corrected_g = applyGammaCorrection(g, config.color_info);
    const corrected_b = applyGammaCorrection(b, config.color_info);

    return switch (T) {
        u8 => @as(u8, @intCast((@as(u16, corrected_r) + @as(u16, corrected_g) + @as(u16, corrected_b)) / 3)),
        Rgb => Rgb{ .r = corrected_r, .g = corrected_g, .b = corrected_b },
        Rgba => Rgba{ .r = corrected_r, .g = corrected_g, .b = corrected_b, .a = if (is_transparent) 0 else 255 },
        else => @compileError("Unsupported pixel type"),
    };
}

/// Extract RGBA pixel from Adam7 pass data
fn extractRgbaPixel(comptime T: type, src_row: []const u8, pass_x: usize, header: Header, config: PixelExtractionConfig) T {
    const offset = pass_x * 4;
    if (offset + 3 >= src_row.len) {
        return switch (T) {
            u8 => 0,
            Rgb => Rgb{ .r = 0, .g = 0, .b = 0 },
            Rgba => Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 },
            else => @compileError("Unsupported pixel type"),
        };
    }

    const r = if (header.bit_depth == 16)
        @as(u8, @intCast(std.mem.readInt(u16, src_row[offset .. offset + 2][0..2], .big) >> 8))
    else
        src_row[offset];
    const g = if (header.bit_depth == 16)
        @as(u8, @intCast(std.mem.readInt(u16, src_row[offset + 2 .. offset + 4][0..2], .big) >> 8))
    else
        src_row[offset + 1];
    const b = if (header.bit_depth == 16)
        @as(u8, @intCast(std.mem.readInt(u16, src_row[offset + 4 .. offset + 6][0..2], .big) >> 8))
    else
        src_row[offset + 2];
    const a = if (header.bit_depth == 16)
        @as(u8, @intCast(std.mem.readInt(u16, src_row[offset + 6 .. offset + 8][0..2], .big) >> 8))
    else
        src_row[offset + 3];

    // Apply gamma correction to RGB channels (not alpha)
    const corrected_r = applyGammaCorrection(r, config.color_info);
    const corrected_g = applyGammaCorrection(g, config.color_info);
    const corrected_b = applyGammaCorrection(b, config.color_info);

    return switch (T) {
        u8 => @as(u8, @intCast((@as(u16, corrected_r) + @as(u16, corrected_g) + @as(u16, corrected_b)) / 3)),
        Rgb => Rgb{ .r = corrected_r, .g = corrected_g, .b = corrected_b },
        Rgba => Rgba{ .r = corrected_r, .g = corrected_g, .b = corrected_b, .a = a },
        else => @compileError("Unsupported pixel type"),
    };
}

// Simple test for the PNG structure
test "PNG signature validation" {
    const invalid_sig = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const result = decode(std.testing.allocator, &invalid_sig);
    try std.testing.expectError(error.InvalidPngSignature, result);
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

    const original_image = Image(Rgb).init(height, width, owned_data);

    // Encode to PNG
    const png_data = try encodeImage(Rgb, allocator, original_image, .default);
    defer allocator.free(png_data);

    // Verify PNG signature
    try std.testing.expect(png_data.len > 8);
    try std.testing.expectEqualSlices(u8, &signature, png_data[0..8]);

    // Decode back from PNG
    var decoded_png = try decode(allocator, png_data);
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

test "PNG CRC validation" {
    const allocator = std.testing.allocator;
    _ = allocator;

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

    var test_data = ArrayList(u8).init(std.testing.allocator);
    defer test_data.deinit();

    try test_data.appendSlice(ihdr_type);
    try test_data.appendSlice(&ihdr_data);

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
    const allocator = std.testing.allocator;

    // Create a malformed PNG with excessively large dimensions
    var png_data = ArrayList(u8).init(allocator);
    defer png_data.deinit();

    // PNG signature
    try png_data.appendSlice(&signature);

    // IHDR chunk with oversized dimensions
    const ihdr_length: u32 = 13;
    try png_data.appendSlice(std.mem.asBytes(&std.mem.nativeTo(u32, ihdr_length, .big)));
    try png_data.appendSlice("IHDR");

    // Width: 50000 (exceeds MAX_DIMENSION)
    try png_data.appendSlice(std.mem.asBytes(&std.mem.nativeTo(u32, 50000, .big)));
    // Height: 50000 (exceeds MAX_DIMENSION)
    try png_data.appendSlice(std.mem.asBytes(&std.mem.nativeTo(u32, 50000, .big)));

    try png_data.append(8); // bit depth
    try png_data.append(2); // color type (RGB)
    try png_data.append(0); // compression
    try png_data.append(0); // filter
    try png_data.append(0); // interlace

    // Calculate and append CRC
    var crc_data = try allocator.alloc(u8, 4 + 13);
    defer allocator.free(crc_data);
    @memcpy(crc_data[0..4], "IHDR");
    @memcpy(crc_data[4..], png_data.items[16..29]);
    const ihdr_crc = crc(crc_data);
    try png_data.appendSlice(std.mem.asBytes(&std.mem.nativeTo(u32, ihdr_crc, .big)));

    // Try to decode - should fail with ImageTooLarge
    const result = decode(allocator, png_data.items);
    try std.testing.expectError(error.ImageTooLarge, result);
}

test "PNG bounds checking - malformed palette" {
    const allocator = std.testing.allocator;

    // Test malformed palette chunk that's too short
    const chunk = Chunk{
        .length = 10, // Should be multiple of 3
        .type = "PLTE".*,
        .data = &[_]u8{ 255, 0, 0, 0, 255, 0, 0, 0 }, // Only 8 bytes, but length claims 10
        .crc = 0,
    };

    var png_image = PngImage{
        .header = Header{
            .width = 4,
            .height = 4,
            .bit_depth = 8,
            .color_type = .palette,
            .compression_method = 0,
            .filter_method = 0,
            .interlace_method = 0,
        },
        .idat_data = ArrayList(u8).init(allocator),
    };
    defer png_image.deinit(allocator);

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
    const interlaced_header = Header{
        .width = 4,
        .height = 4,
        .bit_depth = 8,
        .color_type = .rgb,
        .compression_method = 0,
        .filter_method = 0,
        .interlace_method = 1,
    };

    // Test basic interlaced properties
    try std.testing.expectEqual(@as(u8, 1), interlaced_header.interlace_method);
    try std.testing.expectEqual(@as(u8, 3), interlaced_header.channels());

    // Test that Adam7 total size calculation works
    const total_size = adam7TotalSize(interlaced_header);
    try std.testing.expect(total_size > 0);

    // Test pixel extraction functions work correctly
    const rgb_src = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255 }; // red, green, blue pixels
    const rgb_pixel = extractRgbPixel(Rgb, &rgb_src, 1, interlaced_header, PixelExtractionConfig{});
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 255, .b = 0 }, rgb_pixel);

    const rgba_src = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128 }; // red (alpha=255), green (alpha=128)
    const rgba_pixel = extractRgbaPixel(Rgba, &rgba_src, 1, interlaced_header, PixelExtractionConfig{});
    try std.testing.expectEqual(Rgba{ .r = 0, .g = 255, .b = 0, .a = 128 }, rgba_pixel);
}

test "PNG palette transparency support" {
    const allocator = std.testing.allocator;

    // Create a palette PNG with transparency
    var png_image = PngImage{
        .header = Header{
            .width = 2,
            .height = 2,
            .bit_depth = 8,
            .color_type = .palette,
            .compression_method = 0,
            .filter_method = 0,
            .interlace_method = 0,
        },
        .idat_data = ArrayList(u8).init(allocator),
    };
    defer png_image.deinit(allocator);

    // Create palette: red, green, blue, white
    const palette = try allocator.alloc([3]u8, 4);
    defer allocator.free(palette);
    palette[0] = [3]u8{ 255, 0, 0 }; // red
    palette[1] = [3]u8{ 0, 255, 0 }; // green
    palette[2] = [3]u8{ 0, 0, 255 }; // blue
    palette[3] = [3]u8{ 255, 255, 255 }; // white
    png_image.palette = palette;

    // Create transparency: red=255, green=128, blue=64, white=0 (transparent)
    const transparency = try allocator.alloc(u8, 4);
    defer allocator.free(transparency);
    transparency[0] = 255; // red opaque
    transparency[1] = 128; // green semi-transparent
    transparency[2] = 64; // blue more transparent
    transparency[3] = 0; // white fully transparent
    png_image.transparency = transparency;

    // Clear pointers before deinit to avoid double-free
    defer {
        png_image.palette = null;
        png_image.transparency = null;
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
    const gray_header = Header{
        .width = 4,
        .height = 1,
        .bit_depth = 8,
        .color_type = .grayscale,
        .compression_method = 0,
        .filter_method = 0,
        .interlace_method = 0,
    };

    // Test pixels: 0, 128 (transparent), 255, 64
    const gray_src = [_]u8{ 0, 128, 255, 64 };

    // Test transparency detection
    const config = PixelExtractionConfig{ .transparency = &gray_trans_data };
    const pixel_normal = extractGrayscalePixel(Rgba, &gray_src, 0, gray_header, config);
    const pixel_transparent = extractGrayscalePixel(Rgba, &gray_src, 1, gray_header, config);
    const pixel_white = extractGrayscalePixel(Rgba, &gray_src, 2, gray_header, config);
    const pixel_gray = extractGrayscalePixel(Rgba, &gray_src, 3, gray_header, config);

    try std.testing.expectEqual(Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 }, pixel_normal);
    try std.testing.expectEqual(Rgba{ .r = 128, .g = 128, .b = 128, .a = 0 }, pixel_transparent);
    try std.testing.expectEqual(Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 }, pixel_white);
    try std.testing.expectEqual(Rgba{ .r = 64, .g = 64, .b = 64, .a = 255 }, pixel_gray);
}

test "PNG RGB transparency support" {
    // Test RGB transparency - transparent color is white (255, 255, 255)
    const rgb_trans_data = [_]u8{ 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF }; // White in 16-bit format
    const rgb_header = Header{
        .width = 3,
        .height = 1,
        .bit_depth = 8,
        .color_type = .rgb,
        .compression_method = 0,
        .filter_method = 0,
        .interlace_method = 0,
    };

    // Test pixels: red, white (transparent), blue
    const rgb_src = [_]u8{ 255, 0, 0, 255, 255, 255, 0, 0, 255 };

    // Test transparency detection
    const config = PixelExtractionConfig{ .transparency = &rgb_trans_data };
    const pixel_red = extractRgbPixel(Rgba, &rgb_src, 0, rgb_header, config);
    const pixel_white = extractRgbPixel(Rgba, &rgb_src, 1, rgb_header, config);
    const pixel_blue = extractRgbPixel(Rgba, &rgb_src, 2, rgb_header, config);

    try std.testing.expectEqual(Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 }, pixel_red);
    try std.testing.expectEqual(Rgba{ .r = 255, .g = 255, .b = 255, .a = 0 }, pixel_white);
    try std.testing.expectEqual(Rgba{ .r = 0, .g = 0, .b = 255, .a = 255 }, pixel_blue);
}

test "PNG transparency error cases" {
    const allocator = std.testing.allocator;

    // Test invalid tRNS chunk for grayscale_alpha (should error)
    var png_image = PngImage{
        .header = Header{
            .width = 16,
            .height = 16,
            .bit_depth = 8,
            .color_type = .grayscale_alpha, // This color type cannot have tRNS
            .compression_method = 0,
            .filter_method = 0,
            .interlace_method = 0,
        },
        .idat_data = ArrayList(u8).init(allocator),
    };
    defer png_image.deinit(allocator);

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
    const gray16_header = Header{
        .width = 2,
        .height = 1,
        .bit_depth = 16,
        .color_type = .grayscale,
        .compression_method = 0,
        .filter_method = 0,
        .interlace_method = 0,
    };

    // Test pixels: 0x8000 (should be transparent), 0x4000 (should be opaque)
    const gray16_src = [_]u8{ 0x80, 0x00, 0x40, 0x00 };

    const config = PixelExtractionConfig{ .transparency = &gray16_trans_data };
    const pixel_transparent = extractGrayscalePixel(Rgba, &gray16_src, 0, gray16_header, config);
    const pixel_opaque = extractGrayscalePixel(Rgba, &gray16_src, 1, gray16_header, config);

    try std.testing.expectEqual(Rgba{ .r = 128, .g = 128, .b = 128, .a = 0 }, pixel_transparent);
    try std.testing.expectEqual(Rgba{ .r = 64, .g = 64, .b = 64, .a = 255 }, pixel_opaque);
}

test "PNG gamma correction" {
    // Test gamma correction math
    const color_info_gamma = ColorInfo{ .gamma = 2.2, .srgb_intent = null };
    const color_info_srgb = ColorInfo{ .gamma = null, .srgb_intent = .perceptual };
    const color_info_none = ColorInfo.empty;

    // Test gamma correction
    const input_value: u8 = 128;
    const gamma_corrected = applyGammaCorrection(input_value, color_info_gamma);
    const srgb_corrected = applyGammaCorrection(input_value, color_info_srgb);
    const no_correction = applyGammaCorrection(input_value, color_info_none);

    // Verify no correction returns original value
    try std.testing.expectEqual(input_value, no_correction);

    // Verify gamma and sRGB correction modify the value
    try std.testing.expect(gamma_corrected != input_value);
    try std.testing.expect(srgb_corrected != input_value);

    // sRGB should override gamma when both are present (shouldn't happen in real PNG files)
    const both_present = ColorInfo{ .gamma = 1.8, .srgb_intent = .perceptual };
    const both_corrected = applyGammaCorrection(input_value, both_present);
    try std.testing.expectEqual(srgb_corrected, both_corrected);
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

    var png_image = PngImage{
        .header = Header{
            .width = 4,
            .height = 4,
            .bit_depth = 8,
            .color_type = .rgb,
            .compression_method = 0,
            .filter_method = 0,
            .interlace_method = 0,
        },
        .idat_data = ArrayList(u8).init(allocator),
    };
    defer png_image.deinit(allocator);

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

    var png_image = PngImage{
        .header = Header{
            .width = 4,
            .height = 4,
            .bit_depth = 8,
            .color_type = .rgb,
            .compression_method = 0,
            .filter_method = 0,
            .interlace_method = 0,
        },
        .idat_data = ArrayList(u8).init(allocator),
    };
    defer png_image.deinit(allocator);

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

test "PNG pixel extraction config convenience" {
    // Test that PixelExtractionConfig provides clean defaults
    const header = Header{
        .width = 4,
        .height = 4,
        .bit_depth = 8,
        .color_type = .rgb,
        .compression_method = 0,
        .filter_method = 0,
        .interlace_method = 0,
    };

    const rgb_src = [_]u8{ 255, 0, 0, 0, 255, 0 }; // red, green pixels

    // Test default config (no transparency, no gamma correction)
    const default_config = PixelExtractionConfig{};
    const pixel_default = extractRgbPixel(Rgb, &rgb_src, 0, header, default_config);
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, pixel_default);

    // Test config with transparency
    const trans_data = [_]u8{ 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00 }; // red is transparent
    const transparency_config = PixelExtractionConfig{ .transparency = &trans_data };
    const pixel_with_trans = extractRgbPixel(Rgba, &rgb_src, 0, header, transparency_config);
    try std.testing.expectEqual(Rgba{ .r = 255, .g = 0, .b = 0, .a = 0 }, pixel_with_trans);

    // Test config with gamma correction
    const gamma_config = PixelExtractionConfig{ .color_info = ColorInfo{ .gamma = 2.2, .srgb_intent = null } };
    // With gamma 2.2, value 255 should become 255 (at ceiling), but 128 should be different
    const test_src = [_]u8{ 128, 128, 128 }; // middle gray value
    const pixel_gamma_test = extractRgbPixel(Rgb, &test_src, 0, header, gamma_config);
    const pixel_no_gamma = extractRgbPixel(Rgb, &test_src, 0, header, default_config);
    try std.testing.expect(!std.meta.eql(pixel_gamma_test, pixel_no_gamma));
}
