//! WebP codec backed by the system libwebp, opened at runtime (see `dynlib.zig`).
//! Signature detection works in every build. The public API carries no libwebp types, so a
//! native decoder can replace the backend without changing callers.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Image = @import("../image.zig").Image;
const NativeImage = @import("../codecs.zig").NativeImage;
const dynlib = @import("dynlib.zig");
const Rgb = @import("../color.zig").Rgb(u8);
const Rgba = @import("../color.zig").Rgba(u8);

/// Whether this build can load libwebp; otherwise every call returns `error.CodecNotEnabled`.
pub const enabled = dynlib.supported;

const max_file_size: usize = 100 * 1024 * 1024;

/// `RIFF` then the little-endian file size, then `WEBP`.
pub fn hasSignature(data: []const u8) bool {
    return data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP");
}

pub const DecodeLimits = struct {
    /// Maximum encoded size read by `load`; 0 disables the cap.
    max_webp_bytes: usize = max_file_size,
    /// Maximum decoded pixel count; 0 disables the cap.
    max_pixels: u64 = 1 << 28,

    pub const default: DecodeLimits = .{};
};

pub const EncodeOptions = struct {
    /// 0-100; 100 selects the lossless format.
    quality: u8 = 90,

    pub const default: EncodeOptions = .{};
    pub const lossless: EncodeOptions = .{ .quality = 100 };
};

pub const Header = struct {
    width: u32,
    height: u32,
    has_alpha: bool,
    has_animation: bool,
    format: Format,

    pub const Format = enum { mixed, lossy, lossless };
};

/// Parses the header from the bytes `reader` can buffer; nothing is consumed.
pub fn getInfo(reader: *Io.Reader, limits: DecodeLimits) !Header {
    if (!enabled) return error.CodecNotEnabled;
    _ = limits;
    const webp = try Libwebp.get();
    var want: usize = 32;
    while (true) {
        const data = reader.peekGreedy(want) catch |err| switch (err) {
            error.EndOfStream => reader.buffered(),
            else => return err,
        };
        var features: Features = undefined;
        switch (webp.WebPGetFeaturesInternal(data.ptr, data.len, &features, decoder_abi)) {
            status_ok => return header(features),
            status_not_enough_data => {
                if (data.len < want) return error.TruncatedData;
                if (want >= reader.buffer.len) return error.WebpHeaderTooLarge;
                want = @min(want * 2, reader.buffer.len);
            },
            else => return error.InvalidWebp,
        }
    }
}

/// Decodes a still WebP into RGBA when it has alpha, else RGB (WebP has no grayscale).
/// Animations return `error.UnsupportedAnimation`.
pub fn decode(io: Io, allocator: Allocator, data: []const u8, limits: DecodeLimits) !NativeImage {
    if (!enabled) return error.CodecNotEnabled;
    _ = io;
    if (!hasSignature(data)) return error.InvalidWebp;
    const webp = try Libwebp.get();
    var features: Features = undefined;
    if (webp.WebPGetFeaturesInternal(data.ptr, data.len, &features, decoder_abi) != status_ok) return error.InvalidWebp;
    const info = try header(features);
    if (info.has_animation) return error.UnsupportedAnimation;
    if (limits.max_pixels != 0 and @as(u64, info.width) * info.height > limits.max_pixels) return error.ImageTooLarge;

    var native: NativeImage = if (info.has_alpha)
        .{ .rgba = try .init(allocator, info.height, info.width) }
    else
        .{ .rgb = try .init(allocator, info.height, info.width) };
    errdefer native.deinit(allocator);
    const decoded = switch (native) {
        .rgba => |img| webp.WebPDecodeRGBAInto(data.ptr, data.len, img.asBytes().ptr, img.asBytes().len, @intCast(img.cols * 4)),
        .rgb => |img| webp.WebPDecodeRGBInto(data.ptr, data.len, img.asBytes().ptr, img.asBytes().len, @intCast(img.cols * 3)),
        .grayscale => unreachable,
    };
    if (decoded == null) return error.InvalidWebp;
    return native;
}

pub fn loadFromBytes(comptime T: type, io: Io, allocator: Allocator, data: []const u8, limits: DecodeLimits) !Image(T) {
    var native = try decode(io, allocator, data, limits);
    return native.into(T, io, allocator);
}

pub fn load(comptime T: type, io: Io, allocator: Allocator, file_path: []const u8, limits: DecodeLimits) !Image(T) {
    if (!enabled) return error.CodecNotEnabled;
    const read_limit = if (limits.max_webp_bytes == 0) std.math.maxInt(usize) else limits.max_webp_bytes;
    const data = try Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(read_limit));
    defer allocator.free(data);
    return loadFromBytes(T, io, allocator, data, limits);
}

/// Encodes `image` as WebP: `Rgba`→RGBA, everything else→RGB. WebP caps each side at 16383.
/// Lossless keeps every visible pixel; the RGB of fully transparent ones may change.
pub fn encode(comptime T: type, io: Io, allocator: Allocator, image: Image(T), options: EncodeOptions) ![]u8 {
    if (!enabled) return error.CodecNotEnabled;
    switch (T) {
        Rgb, Rgba => {
            if (image.isContiguous()) return encodeRaw(allocator, image.asBytes(), image.cols, image.rows, T == Rgba, options);
            var contiguous = try image.dupe(allocator);
            defer contiguous.deinit(allocator);
            return encodeRaw(allocator, contiguous.asBytes(), image.cols, image.rows, T == Rgba, options);
        },
        else => {
            var rgb = try image.convert(io, allocator, Rgb);
            defer rgb.deinit(allocator);
            return encodeRaw(allocator, rgb.asBytes(), image.cols, image.rows, false, options);
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

fn encodeRaw(allocator: Allocator, pixels: []const u8, width: u32, height: u32, alpha: bool, options: EncodeOptions) ![]u8 {
    const max_side = 16383;
    if (width == 0 or height == 0 or width > max_side or height > max_side) return error.ImageTooLarge;
    const webp = try Libwebp.get();
    const w: c_int = @intCast(width);
    const h: c_int = @intCast(height);
    const stride: c_int = w * @as(c_int, if (alpha) 4 else 3);
    const quality: f32 = @floatFromInt(options.quality);
    var out: ?[*]u8 = null;
    const size = if (options.quality >= 100)
        (if (alpha) webp.WebPEncodeLosslessRGBA else webp.WebPEncodeLosslessRGB)(pixels.ptr, w, h, stride, &out)
    else
        (if (alpha) webp.WebPEncodeRGBA else webp.WebPEncodeRGB)(pixels.ptr, w, h, stride, quality, &out);
    const bytes = out orelse return error.WebpEncodeFailed;
    defer webp.WebPFree(bytes);
    if (size == 0) return error.WebpEncodeFailed;
    return allocator.dupe(u8, bytes[0..size]);
}

fn header(features: Features) !Header {
    return .{
        .width = std.math.cast(u32, features.width) orelse return error.InvalidWebp,
        .height = std.math.cast(u32, features.height) orelse return error.InvalidWebp,
        .has_alpha = features.has_alpha != 0,
        .has_animation = features.has_animation != 0,
        .format = switch (features.format) {
            1 => .lossy,
            2 => .lossless,
            else => .mixed,
        },
    };
}

// libwebp ABI, declared by hand so the build needs no libwebp headers.

/// Only the major byte must match the library's `WEBP_DECODER_ABI_VERSION` (0x02xx since 0.5).
const decoder_abi = 0x0200;
const status_ok = 0;
const status_not_enough_data = 7;

const Features = extern struct {
    width: c_int,
    height: c_int,
    has_alpha: c_int,
    has_animation: c_int,
    format: c_int,
    pad: [5]u32,
};

const EncodeFn = *const fn (pixels: [*]const u8, width: c_int, height: c_int, stride: c_int, quality: f32, output: *?[*]u8) callconv(.c) usize;
const EncodeLosslessFn = *const fn (pixels: [*]const u8, width: c_int, height: c_int, stride: c_int, output: *?[*]u8) callconv(.c) usize;
const DecodeIntoFn = *const fn (data: [*]const u8, size: usize, output: [*]u8, output_size: usize, stride: c_int) callconv(.c) ?[*]u8;

/// The libwebp entry points used here; field names are the exported symbols.
const Api = struct {
    WebPGetFeaturesInternal: *const fn (data: [*]const u8, size: usize, features: *Features, version: c_int) callconv(.c) c_int,
    WebPDecodeRGBInto: DecodeIntoFn,
    WebPDecodeRGBAInto: DecodeIntoFn,
    WebPEncodeRGB: EncodeFn,
    WebPEncodeRGBA: EncodeFn,
    WebPEncodeLosslessRGB: EncodeLosslessFn,
    WebPEncodeLosslessRGBA: EncodeLosslessFn,
    WebPFree: *const fn (ptr: ?*anyopaque) callconv(.c) void,
};

const Libwebp = dynlib.Library(Api, switch (builtin.os.tag) {
    .macos => dynlib.macosNames("libwebp.dylib"),
    else => &.{ "libwebp.so.7", "libwebp.so" },
});

test "signature detection" {
    try std.testing.expect(hasSignature("RIFF\x24\x00\x00\x00WEBPVP8 "));
    try std.testing.expect(!hasSignature("RIFF\x24\x00\x00\x00WAVEfmt "));
    try std.testing.expect(!hasSignature("RIFF"));
}

test "disabled build reports CodecNotEnabled" {
    if (enabled) return error.SkipZigTest;
    try std.testing.expectError(error.CodecNotEnabled, decode(std.testing.io, std.testing.allocator, "RIFF\x00\x00\x00\x00WEBP", .default));
}

test "ABI layout matches libwebp" {
    try std.testing.expectEqual(40, @sizeOf(Features));
}

/// Smooth gradients (lossy WebP subsamples chroma) and no fully transparent pixels, whose RGB
/// the simple lossless encoder may rewrite.
fn testImage(comptime T: type, allocator: Allocator) !Image(T) {
    var img: Image(T) = try .init(allocator, 37, 53);
    for (0..img.rows) |r| for (0..img.cols) |col| {
        const v: u8 = @intCast(r * 4 + col * 2);
        const b: u8 = @intCast(r * 2 + col * 3);
        img.at(r, col).* = switch (T) {
            u8 => v,
            Rgb => .{ .r = v, .g = 255 - v, .b = b },
            Rgba => .{ .r = v, .g = 255 - v, .b = b, .a = @intCast(col * 4 + 1) },
            else => unreachable,
        };
    };
    return img;
}

/// Skips when this machine has no libwebp.
fn requireLibwebp() !void {
    if (!enabled) return error.SkipZigTest;
    _ = Libwebp.get() catch return error.SkipZigTest;
}

test "lossless round trip" {
    try requireLibwebp();
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
        try std.testing.expectEqual(Header.Format.lossless, info.format);

        var back = try loadFromBytes(T, io, allocator, bytes, .default);
        defer back.deinit(allocator);
        try std.testing.expectEqualSlices(u8, img.asBytes(), back.asBytes());
    }
}

test "lossy round trip stays close" {
    try requireLibwebp();
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
