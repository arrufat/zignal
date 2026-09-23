//! WebP codec backed by the system libwebp, opened at runtime (see `dynlib.zig`).
//! Signature detection works in every build. The public API carries no libwebp types, so a
//! native decoder can replace the backend without changing callers.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const animated = @import("../image/animated.zig");
const AnimatedImage = animated.AnimatedImage;
const Image = @import("../image.zig").Image;
const codecs = @import("../codecs.zig");
const NativeImage = codecs.NativeImage;
const dynlib = @import("dynlib.zig");
const Rgb = @import("../color.zig").Rgb(u8);
const Rgba = @import("../color.zig").Rgba(u8);

/// Whether this build can load libwebp; otherwise every call returns `error.CodecNotEnabled`.
pub const enabled = dynlib.supported;

/// `RIFF` then the little-endian file size, then `WEBP`.
pub fn hasSignature(data: []const u8) bool {
    return data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP");
}

pub const DecodeLimits = struct {
    /// Maximum encoded size read by `load`; 0 disables the cap.
    max_webp_bytes: usize = codecs.max_file_size,
    /// Maximum decoded pixel count (per frame); 0 disables the cap.
    max_pixels: u64 = 1 << 28,
    /// Maximum animation frames; 0 disables the cap.
    max_frames: u32 = 4096,
    /// Maximum pixels across all composed frames; 0 disables the cap.
    max_total_pixels: u64 = 1 << 30,

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

/// Decodes a WebP into RGBA when it has alpha, else RGB (WebP has no grayscale). Animations
/// give their first composed frame, as RGBA.
pub fn decode(io: Io, allocator: Allocator, data: []const u8, limits: DecodeLimits) !NativeImage {
    if (!enabled) return error.CodecNotEnabled;
    _ = io;
    const webp = try Libwebp.get();
    const info = try readHeader(webp, data);
    if (!info.has_animation) return decodeStill(webp, allocator, data, info, limits);
    var reader: AnimReader = try .init(data, limits);
    defer reader.deinit();
    const first = try reader.next() orelse return error.InvalidWebp;
    return .{ .rgba = try reader.canvas(first).dupe(allocator) };
}

/// Loads every frame; a still WebP gives one frame.
pub fn loadAnimatedFromBytes(comptime T: type, io: Io, allocator: Allocator, data: []const u8, limits: DecodeLimits) !AnimatedImage(T) {
    if (!enabled) return error.CodecNotEnabled;
    const webp = try Libwebp.get();
    const info = try readHeader(webp, data);
    if (!info.has_animation) {
        var still = try decodeStill(webp, allocator, data, info, limits);
        return .fromStill(allocator, try still.into(T, io, allocator));
    }
    var reader: AnimReader = try .init(data, limits);
    defer reader.deinit();
    var builder: animated.Builder(T) = .{};
    defer builder.deinit(allocator);
    while (try reader.next()) |frame| {
        // The decoder reuses its canvas: copy it out, converting on the way when T isn't RGBA.
        const canvas = reader.canvas(frame);
        try builder.append(allocator, if (T == Rgba) try canvas.dupe(allocator) else try canvas.convert(io, allocator, T), frame.duration_ms);
    }
    return builder.finish(allocator, reader.info.loop_count);
}

pub fn loadAnimated(comptime T: type, io: Io, allocator: Allocator, file_path: []const u8, limits: DecodeLimits) !AnimatedImage(T) {
    if (!enabled) return error.CodecNotEnabled;
    const data = try codecs.readFile(io, allocator, file_path, limits.max_webp_bytes);
    defer allocator.free(data);
    return loadAnimatedFromBytes(T, io, allocator, data, limits);
}

fn decodeStill(webp: *const Api, allocator: Allocator, data: []const u8, info: Header, limits: DecodeLimits) !NativeImage {
    if (codecs.exceeds(limits.max_pixels, @as(u64, info.width) * info.height)) return error.ImageTooLarge;
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

/// Walks the composed RGBA frames of an animated WebP through libwebpdemux.
const AnimReader = struct {
    demux: *const DemuxApi,
    dec: *AnimDecoder,
    info: AnimInfo,
    read: u32 = 0,
    /// End time of the previous frame in milliseconds (libwebp timestamps are frame end times).
    previous_end: c_int = 0,

    const Frame = struct { pixels: []const u8, duration_ms: u32 };

    fn init(data: []const u8, limits: DecodeLimits) !AnimReader {
        const demux = try LibwebpDemux.get();
        var options: AnimDecoderOptions = undefined;
        if (demux.WebPAnimDecoderOptionsInitInternal(&options, demux_abi) == 0) return error.CodecUnavailable;
        options.color_mode = mode_rgba;
        options.use_threads = 1;
        const webp_data: WebPData = .{ .bytes = data.ptr, .size = data.len };
        const dec = demux.WebPAnimDecoderNewInternal(&webp_data, &options, demux_abi) orelse return error.InvalidWebp;
        errdefer demux.WebPAnimDecoderDelete(dec);
        var info: AnimInfo = undefined;
        if (demux.WebPAnimDecoderGetInfo(dec, &info) == 0) return error.InvalidWebp;
        const canvas_pixels = @as(u64, info.canvas_width) * info.canvas_height;
        if (codecs.exceeds(limits.max_frames, info.frame_count)) return error.TooManyFrames;
        if (codecs.exceeds(limits.max_pixels, canvas_pixels)) return error.ImageTooLarge;
        if (codecs.exceeds(limits.max_total_pixels, canvas_pixels * info.frame_count)) return error.ImageTooLarge;
        return .{ .demux = demux, .dec = dec, .info = info };
    }

    fn deinit(self: *AnimReader) void {
        self.demux.WebPAnimDecoderDelete(self.dec);
    }

    /// The next frame, borrowed until the following call, or null after the last one.
    fn next(self: *AnimReader) !?Frame {
        if (self.read == self.info.frame_count) return null;
        var pixels: ?[*]const u8 = null;
        var end: c_int = 0;
        if (self.demux.WebPAnimDecoderGetNext(self.dec, &pixels, &end) == 0) return error.InvalidWebp;
        self.read += 1;
        defer self.previous_end = end;
        const len = @as(usize, self.info.canvas_width) * self.info.canvas_height * 4;
        return .{ .pixels = (pixels orelse return error.InvalidWebp)[0..len], .duration_ms = @intCast(@max(0, end - self.previous_end)) };
    }

    /// Views a borrowed frame as an image (still owned by the decoder).
    fn canvas(self: AnimReader, frame: Frame) Image(Rgba) {
        return .initFromBytes(self.info.canvas_height, self.info.canvas_width, @constCast(frame.pixels));
    }
};

fn readHeader(webp: *const Api, data: []const u8) !Header {
    if (!hasSignature(data)) return error.InvalidWebp;
    var features: Features = undefined;
    if (webp.WebPGetFeaturesInternal(data.ptr, data.len, &features, decoder_abi) != status_ok) return error.InvalidWebp;
    return header(features);
}

pub fn loadFromBytes(comptime T: type, io: Io, allocator: Allocator, data: []const u8, limits: DecodeLimits) !Image(T) {
    var native = try decode(io, allocator, data, limits);
    return native.into(T, io, allocator);
}

pub fn load(comptime T: type, io: Io, allocator: Allocator, file_path: []const u8, limits: DecodeLimits) !Image(T) {
    if (!enabled) return error.CodecNotEnabled;
    const data = try codecs.readFile(io, allocator, file_path, limits.max_webp_bytes);
    defer allocator.free(data);
    return loadFromBytes(T, io, allocator, data, limits);
}

/// Encodes `image` as WebP: `Rgba`→RGBA, everything else→RGB. WebP caps each side at 16383.
/// Lossless keeps every visible pixel; the RGB of fully transparent ones may change.
pub fn encode(comptime T: type, io: Io, allocator: Allocator, image: Image(T), options: EncodeOptions) ![]u8 {
    if (!enabled) return error.CodecNotEnabled;
    switch (T) {
        // libwebp takes a row stride, so views encode without a copy.
        Rgb, Rgba => return encodeRaw(allocator, @ptrCast(image.data.ptr), image.cols, image.rows, image.stride * @sizeOf(T), T == Rgba, options),
        else => {
            var rgb = try image.convert(io, allocator, Rgb);
            defer rgb.deinit(allocator);
            return encodeRaw(allocator, @ptrCast(rgb.data.ptr), rgb.cols, rgb.rows, rgb.stride * 3, false, options);
        },
    }
}

pub fn save(comptime T: type, io: Io, allocator: Allocator, image: Image(T), file_path: []const u8) !void {
    const bytes = try encode(T, io, allocator, image, .default);
    defer allocator.free(bytes);
    try codecs.writeFile(io, file_path, bytes);
}

fn encodeRaw(allocator: Allocator, pixels: [*]const u8, width: u32, height: u32, stride: usize, alpha: bool, options: EncodeOptions) ![]u8 {
    const max_side = 16383;
    if (width == 0 or height == 0 or width > max_side or height > max_side) return error.ImageTooLarge;
    const webp = try Libwebp.get();
    const w: c_int = @intCast(width);
    const h: c_int = @intCast(height);
    const row_bytes: c_int = @intCast(stride);
    const quality: f32 = options.quality;
    var out: ?[*]u8 = null;
    const size = if (options.quality >= 100)
        (if (alpha) webp.WebPEncodeLosslessRGBA else webp.WebPEncodeLosslessRGB)(pixels, w, h, row_bytes, &out)
    else
        (if (alpha) webp.WebPEncodeRGBA else webp.WebPEncodeRGB)(pixels, w, h, row_bytes, quality, &out);
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

// libwebpdemux, for animations. Only the major byte of `WEBP_DEMUX_ABI_VERSION` must match.
const demux_abi = 0x0100;
const mode_rgba = 1;

const WebPData = extern struct { bytes: [*]const u8, size: usize };

const AnimDecoderOptions = extern struct {
    color_mode: c_int,
    use_threads: c_int,
    padding: [7]u32,
};

const AnimInfo = extern struct {
    canvas_width: u32,
    canvas_height: u32,
    loop_count: u32,
    bgcolor: u32,
    frame_count: u32,
    pad: [4]u32,
};

const AnimDecoder = opaque {};

const DemuxApi = struct {
    WebPAnimDecoderOptionsInitInternal: *const fn (options: *AnimDecoderOptions, abi: c_int) callconv(.c) c_int,
    WebPAnimDecoderNewInternal: *const fn (data: *const WebPData, options: *const AnimDecoderOptions, abi: c_int) callconv(.c) ?*AnimDecoder,
    WebPAnimDecoderGetInfo: *const fn (dec: *const AnimDecoder, info: *AnimInfo) callconv(.c) c_int,
    WebPAnimDecoderGetNext: *const fn (dec: *AnimDecoder, buf: *?[*]const u8, timestamp: *c_int) callconv(.c) c_int,
    WebPAnimDecoderDelete: *const fn (dec: *AnimDecoder) callconv(.c) void,
};

const LibwebpDemux = dynlib.Library(DemuxApi, switch (builtin.os.tag) {
    .macos => dynlib.macosNames("libwebpdemux.dylib"),
    else => &.{ "libwebpdemux.so.2", "libwebpdemux.so" },
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
    try std.testing.expectEqual(36, @sizeOf(AnimDecoderOptions));
    try std.testing.expectEqual(36, @sizeOf(AnimInfo));
    if (@sizeOf(usize) == 8) try std.testing.expectEqual(16, @sizeOf(WebPData));
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

test "lossless round trip" {
    if (!enabled or !Libwebp.available()) return error.SkipZigTest;
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

test "views encode without a copy" {
    if (!enabled or !Libwebp.available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var img = try testImage(Rgba, allocator);
    defer img.deinit(allocator);
    const view = img.view(.{ .l = 5, .t = 3, .r = 40, .b = 30 });
    const bytes = try encode(Rgba, io, allocator, view, .lossless);
    defer allocator.free(bytes);
    var back = try loadFromBytes(Rgba, io, allocator, bytes, .default);
    defer back.deinit(allocator);
    var expected = try view.dupe(allocator);
    defer expected.deinit(allocator);
    try std.testing.expectEqualSlices(u8, expected.asBytes(), back.asBytes());
}

test "a still loads as a one-frame animation" {
    if (!enabled or !Libwebp.available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var img = try testImage(Rgb, allocator);
    defer img.deinit(allocator);
    const bytes = try encode(Rgb, io, allocator, img, .lossless);
    defer allocator.free(bytes);
    var anim = try loadAnimatedFromBytes(Rgb, io, allocator, bytes, .default);
    defer anim.deinit(allocator);
    try std.testing.expectEqual(1, anim.frameCount());
    try std.testing.expectEqualSlices(u8, img.asBytes(), anim.frame(0).asBytes());
}

test "lossy round trip stays close" {
    if (!enabled or !Libwebp.available()) return error.SkipZigTest;
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
