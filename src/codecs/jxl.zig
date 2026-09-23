//! JPEG XL codec backed by the system libjxl, enabled with `zig build -fsys=jxl`.
//! Without the flag every entry point returns `error.JxlNotEnabled`; signature
//! detection works either way.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Image = @import("../image.zig").Image;
const Rgb = @import("../color.zig").Rgb(u8);
const Rgba = @import("../color.zig").Rgba(u8);

/// Whether this build links libjxl.
pub const enabled = @import("build_options").jxl;
const c = if (enabled) @import("jxl_c") else struct {};

const max_file_size: usize = 100 * 1024 * 1024;

/// Bare codestream signature.
pub const signature = [_]u8{ 0xFF, 0x0A };
/// ISOBMFF container signature (`JXL ` box).
pub const container_signature = [_]u8{ 0x00, 0x00, 0x00, 0x0C, 'J', 'X', 'L', ' ', 0x0D, 0x0A, 0x87, 0x0A };

/// Returns true if `data` starts with either JPEG XL signature.
pub fn hasSignature(data: []const u8) bool {
    return std.mem.startsWith(u8, data, &signature) or std.mem.startsWith(u8, data, &container_signature);
}

pub const DecodeLimits = struct {
    /// Maximum encoded size read by `load`; 0 disables the cap.
    max_jxl_bytes: usize = max_file_size,
    /// Maximum decoded pixel count; 0 disables the cap.
    max_pixels: u64 = 1 << 28,

    pub const default: DecodeLimits = .{};
};

pub const EncodeOptions = struct {
    /// 0-100; 100 is mathematically lossless.
    quality: u8 = 90,
    /// Encoder effort, 1 (fastest) to 10 (smallest).
    effort: u4 = 7,

    pub const default: EncodeOptions = .{};
    pub const lossless: EncodeOptions = .{ .quality = 100 };
};

/// Image properties from the codestream header, with `width`/`height` after orientation.
pub const Header = struct {
    width: u32,
    height: u32,
    bits_per_sample: u32,
    exponent_bits_per_sample: u32,
    num_color_channels: u32,
    has_alpha: bool,
    has_animation: bool,
    orientation: u32,
    uses_original_profile: bool,
};

/// Decoded first frame in its natural pixel type.
pub const NativeImage = union(enum) {
    grayscale: Image(u8),
    rgb: Image(Rgb),
    rgba: Image(Rgba),

    pub fn deinit(self: *NativeImage, allocator: Allocator) void {
        switch (self.*) {
            inline else => |*img| img.deinit(allocator),
        }
    }
};

/// Reads just enough of `reader` to parse the header.
pub fn getInfo(reader: *Io.Reader, limits: DecodeLimits) !Header {
    if (!enabled) return error.JxlNotEnabled;
    _ = limits;
    const dec = c.JxlDecoderCreate(null) orelse return error.OutOfMemory;
    defer c.JxlDecoderDestroy(dec);
    try decCheck(c.JxlDecoderSubscribeEvents(dec, c.JXL_DEC_BASIC_INFO));

    while (true) {
        const available = reader.buffered();
        try decCheck(c.JxlDecoderSetInput(dec, available.ptr, available.len));
        const status = c.JxlDecoderProcessInput(dec);
        const unconsumed = c.JxlDecoderReleaseInput(dec);
        reader.toss(available.len - unconsumed);
        switch (status) {
            c.JXL_DEC_BASIC_INFO => return header(dec),
            c.JXL_DEC_NEED_MORE_INPUT => {
                if (unconsumed == reader.buffer.len) return error.JxlHeaderTooLarge;
                reader.fillMore() catch |err| return switch (err) {
                    error.EndOfStream => error.TruncatedData,
                    else => err,
                };
            },
            else => return error.InvalidJxl,
        }
    }
}

/// Decodes the first frame of `data` into its natural pixel type, converted to sRGB when the
/// codestream allows it (XYB-encoded images).
pub fn decode(allocator: Allocator, data: []const u8, limits: DecodeLimits) !NativeImage {
    if (!enabled) return error.JxlNotEnabled;
    if (!hasSignature(data)) return error.InvalidJxl;

    const dec = c.JxlDecoderCreate(null) orelse return error.OutOfMemory;
    defer c.JxlDecoderDestroy(dec);
    const runner = c.JxlThreadParallelRunnerCreate(null, c.JxlThreadParallelRunnerDefaultNumWorkerThreads()) orelse return error.OutOfMemory;
    defer c.JxlThreadParallelRunnerDestroy(runner);
    try decCheck(c.JxlDecoderSetParallelRunner(dec, c.JxlThreadParallelRunner, runner));
    try decCheck(c.JxlDecoderSubscribeEvents(dec, c.JXL_DEC_BASIC_INFO | c.JXL_DEC_FULL_IMAGE));
    try decCheck(c.JxlDecoderSetInput(dec, data.ptr, data.len));
    c.JxlDecoderCloseInput(dec);

    var native: ?NativeImage = null;
    errdefer if (native) |*img| img.deinit(allocator);

    while (true) {
        switch (c.JxlDecoderProcessInput(dec)) {
            c.JXL_DEC_BASIC_INFO => {
                const info = try header(dec);
                if (limits.max_pixels != 0 and @as(u64, info.width) * info.height > limits.max_pixels) return error.ImageTooLarge;
                // Only honored for XYB images; others decode in their stored color space.
                var srgb: c.JxlColorEncoding = undefined;
                c.JxlColorEncodingSetToSRGB(&srgb, @intFromBool(info.num_color_channels == 1));
                _ = c.JxlDecoderSetPreferredColorProfile(dec, &srgb);
                // Gray with alpha widens to RGBA; libjxl replicates gray into color output.
                native = if (info.has_alpha)
                    .{ .rgba = try .init(allocator, info.height, info.width) }
                else if (info.num_color_channels == 1)
                    .{ .grayscale = try .init(allocator, info.height, info.width) }
                else
                    .{ .rgb = try .init(allocator, info.height, info.width) };
            },
            c.JXL_DEC_NEED_IMAGE_OUT_BUFFER => {
                const img = if (native) |*img| img else return error.InvalidJxl;
                const bytes, const channels: u32 = switch (img.*) {
                    .grayscale => |i| .{ i.asBytes(), 1 },
                    .rgb => |i| .{ i.asBytes(), 3 },
                    .rgba => |i| .{ i.asBytes(), 4 },
                };
                const format: c.JxlPixelFormat = .{
                    .num_channels = channels,
                    .data_type = c.JXL_TYPE_UINT8,
                    .endianness = c.JXL_NATIVE_ENDIAN,
                    .@"align" = 0,
                };
                var size: usize = undefined;
                try decCheck(c.JxlDecoderImageOutBufferSize(dec, &format, &size));
                if (size != bytes.len) return error.InvalidJxl;
                try decCheck(c.JxlDecoderSetImageOutBuffer(dec, &format, bytes.ptr, bytes.len));
            },
            // First frame only: animations stop here.
            c.JXL_DEC_FULL_IMAGE => return native orelse error.InvalidJxl,
            c.JXL_DEC_NEED_MORE_INPUT => return error.TruncatedData,
            else => return error.InvalidJxl,
        }
    }
}

/// Decodes a JPEG XL byte stream into `Image(T)`, converting from the natural pixel type as needed.
pub fn loadFromBytes(comptime T: type, io: Io, allocator: Allocator, data: []const u8, limits: DecodeLimits) !Image(T) {
    var native = try decode(allocator, data, limits);
    switch (native) {
        inline else => |*img| {
            const Src = @TypeOf(img.*.data[0]);
            if (Src == T) return img.*;
            defer native.deinit(allocator);
            return img.convert(io, allocator, T);
        },
    }
}

pub fn load(comptime T: type, io: Io, allocator: Allocator, file_path: []const u8, limits: DecodeLimits) !Image(T) {
    if (!enabled) return error.JxlNotEnabled;
    const read_limit = if (limits.max_jxl_bytes == 0) std.math.maxInt(usize) else limits.max_jxl_bytes;
    const data = try Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(read_limit));
    defer allocator.free(data);
    return loadFromBytes(T, io, allocator, data, limits);
}

/// Encodes `image` as sRGB JPEG XL. `u8`→grayscale, `Rgb`→RGB, `Rgba`→RGBA, others→RGB.
pub fn encode(comptime T: type, io: Io, allocator: Allocator, image: Image(T), options: EncodeOptions) ![]u8 {
    if (!enabled) return error.JxlNotEnabled;
    switch (T) {
        u8, Rgb, Rgba => {
            if (image.isContiguous()) return encodeRaw(allocator, image.asBytes(), image.cols, image.rows, @sizeOf(T), options);
            var contiguous = try image.dupe(allocator);
            defer contiguous.deinit(allocator);
            return encodeRaw(allocator, contiguous.asBytes(), image.cols, image.rows, @sizeOf(T), options);
        },
        else => {
            var rgb = try image.convert(io, allocator, Rgb);
            defer rgb.deinit(allocator);
            return encodeRaw(allocator, rgb.asBytes(), image.cols, image.rows, 3, options);
        },
    }
}

pub fn save(comptime T: type, io: Io, allocator: Allocator, image: Image(T), file_path: []const u8) !void {
    const bytes = try encode(T, io, allocator, image, .default);
    defer allocator.free(bytes);

    const file = try Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);

    try file.writeStreamingAll(io, bytes);
}

fn encodeRaw(allocator: Allocator, pixels: []const u8, width: u32, height: u32, channels: u32, options: EncodeOptions) ![]u8 {
    const enc = c.JxlEncoderCreate(null) orelse return error.OutOfMemory;
    defer c.JxlEncoderDestroy(enc);
    const runner = c.JxlThreadParallelRunnerCreate(null, c.JxlThreadParallelRunnerDefaultNumWorkerThreads()) orelse return error.OutOfMemory;
    defer c.JxlThreadParallelRunnerDestroy(runner);
    try encCheck(c.JxlEncoderSetParallelRunner(enc, c.JxlThreadParallelRunner, runner));

    const lossless = options.quality >= 100;
    const has_alpha = channels % 2 == 0;
    const num_color_channels: u32 = if (channels < 3) 1 else 3;

    var info: c.JxlBasicInfo = undefined;
    c.JxlEncoderInitBasicInfo(&info);
    info.xsize = width;
    info.ysize = height;
    info.bits_per_sample = 8;
    info.num_color_channels = num_color_channels;
    info.num_extra_channels = @intFromBool(has_alpha);
    info.alpha_bits = if (has_alpha) 8 else 0;
    // Lossless must keep the original color space; lossy is smaller in XYB.
    info.uses_original_profile = @intFromBool(lossless);
    try encCheck(c.JxlEncoderSetBasicInfo(enc, &info));

    var srgb: c.JxlColorEncoding = undefined;
    c.JxlColorEncodingSetToSRGB(&srgb, @intFromBool(num_color_channels == 1));
    try encCheck(c.JxlEncoderSetColorEncoding(enc, &srgb));

    const settings = c.JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;
    try encCheck(c.JxlEncoderSetFrameDistance(settings, c.JxlEncoderDistanceFromQuality(@floatFromInt(options.quality))));
    try encCheck(c.JxlEncoderSetFrameLossless(settings, @intFromBool(lossless)));
    try encCheck(c.JxlEncoderFrameSettingsSetOption(settings, c.JXL_ENC_FRAME_SETTING_EFFORT, std.math.clamp(options.effort, 1, 10)));

    const format: c.JxlPixelFormat = .{
        .num_channels = channels,
        .data_type = c.JXL_TYPE_UINT8,
        .endianness = c.JXL_NATIVE_ENDIAN,
        .@"align" = 0,
    };
    try encCheck(c.JxlEncoderAddImageFrame(settings, &format, pixels.ptr, pixels.len));
    c.JxlEncoderCloseInput(enc);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.resize(allocator, @max(4096, pixels.len / 8));
    var written: usize = 0;
    while (true) {
        var next: [*c]u8 = out.items.ptr + written;
        var avail: usize = out.items.len - written;
        const status = c.JxlEncoderProcessOutput(enc, &next, &avail);
        written = out.items.len - avail;
        switch (status) {
            c.JXL_ENC_SUCCESS => break,
            c.JXL_ENC_NEED_MORE_OUTPUT => try out.resize(allocator, out.items.len * 2),
            else => return error.JxlEncodeFailed,
        }
    }
    out.shrinkRetainingCapacity(written);
    return out.toOwnedSlice(allocator);
}

fn header(dec: *c.JxlDecoder) !Header {
    var info: c.JxlBasicInfo = undefined;
    try decCheck(c.JxlDecoderGetBasicInfo(dec, &info));
    // The decoder applies orientation, so 5-8 (transposed) swap the output dimensions.
    const transposed = info.orientation >= c.JXL_ORIENT_TRANSPOSE;
    return .{
        .width = if (transposed) info.ysize else info.xsize,
        .height = if (transposed) info.xsize else info.ysize,
        .bits_per_sample = info.bits_per_sample,
        .exponent_bits_per_sample = info.exponent_bits_per_sample,
        .num_color_channels = info.num_color_channels,
        .has_alpha = info.alpha_bits > 0,
        .has_animation = info.have_animation != 0,
        .orientation = info.orientation,
        .uses_original_profile = info.uses_original_profile != 0,
    };
}

fn decCheck(status: c.JxlDecoderStatus) !void {
    if (status != c.JXL_DEC_SUCCESS) return error.InvalidJxl;
}

fn encCheck(status: c.JxlEncoderStatus) !void {
    if (status != c.JXL_ENC_SUCCESS) return error.JxlEncodeFailed;
}

test "signature detection" {
    try std.testing.expect(hasSignature(&signature));
    try std.testing.expect(hasSignature(&container_signature));
    try std.testing.expect(!hasSignature(&.{ 0xFF, 0xD8 }));
}

test "disabled build reports JxlNotEnabled" {
    if (enabled) return error.SkipZigTest;
    try std.testing.expectError(error.JxlNotEnabled, decode(std.testing.allocator, &signature, .default));
}

fn testImage(comptime T: type, allocator: Allocator) !Image(T) {
    var img: Image(T) = try .init(allocator, 37, 53);
    for (0..img.rows) |r| for (0..img.cols) |col| {
        const v: u8 = @truncate(r * 7 + col * 3);
        img.at(r, col).* = switch (T) {
            u8 => v,
            Rgb => .{ .r = v, .g = 255 - v, .b = @truncate(r * col) },
            Rgba => .{ .r = v, .g = 255 - v, .b = @truncate(r * col), .a = @truncate(col * 5) },
            else => unreachable,
        };
    };
    return img;
}

test "lossless round trip" {
    if (!enabled) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    inline for (.{ u8, Rgb, Rgba }) |T| {
        var img = try testImage(T, allocator);
        defer img.deinit(allocator);
        const bytes = try encode(T, io, allocator, img, .lossless);
        defer allocator.free(bytes);
        try std.testing.expect(hasSignature(bytes));

        var reader: Io.Reader = .fixed(bytes);
        const info = try getInfo(&reader, .default);
        try std.testing.expectEqual(img.cols, info.width);
        try std.testing.expectEqual(img.rows, info.height);

        var back = try loadFromBytes(T, io, allocator, bytes, .default);
        defer back.deinit(allocator);
        try std.testing.expectEqualSlices(u8, img.asBytes(), back.asBytes());
    }
}

test "lossy round trip stays close" {
    if (!enabled) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var img = try testImage(Rgb, allocator);
    defer img.deinit(allocator);
    const bytes = try encode(Rgb, io, allocator, img, .{ .quality = 95 });
    defer allocator.free(bytes);
    var back = try loadFromBytes(Rgb, io, allocator, bytes, .default);
    defer back.deinit(allocator);
    try std.testing.expect(try img.psnr(back) > 30);
}
