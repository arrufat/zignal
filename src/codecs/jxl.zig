//! JPEG XL codec backed by the system libjxl, enabled with `zig build -fsys=jxl`.
//! libjxl is opened at runtime on first use, so a build with the flag still runs where
//! libjxl is missing and only JPEG XL calls fail, with `error.JxlUnavailable`. Without the
//! flag every entry point returns `error.JxlNotEnabled`; signature detection works either way.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Image = @import("../image.zig").Image;
const meta = @import("../meta.zig");
const parallel = @import("../parallel.zig");
const Rgb = @import("../color.zig").Rgb(u8);
const Rgba = @import("../color.zig").Rgba(u8);

/// Whether this build can load libjxl (never on wasm or Windows, which has no `DynLib` backend).
pub const enabled = @import("build_options").jxl;

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
    const jxl = try api();
    const dec = jxl.JxlDecoderCreate(null) orelse return error.OutOfMemory;
    defer jxl.JxlDecoderDestroy(dec);
    try decCheck(jxl.JxlDecoderSubscribeEvents(dec, dec_basic_info));

    while (true) {
        const available = reader.buffered();
        try decCheck(jxl.JxlDecoderSetInput(dec, available.ptr, available.len));
        const status = jxl.JxlDecoderProcessInput(dec);
        const unconsumed = jxl.JxlDecoderReleaseInput(dec);
        reader.toss(available.len - unconsumed);
        switch (status) {
            dec_basic_info => return header(jxl, dec),
            dec_need_more_input => {
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
/// codestream allows it (XYB-encoded images). libjxl's worker tasks run on `io`.
pub fn decode(io: Io, allocator: Allocator, data: []const u8, limits: DecodeLimits) !NativeImage {
    if (!enabled) return error.JxlNotEnabled;
    if (!hasSignature(data)) return error.InvalidJxl;
    const jxl = try api();

    const dec = jxl.JxlDecoderCreate(null) orelse return error.OutOfMemory;
    defer jxl.JxlDecoderDestroy(dec);
    var runner: Runner = .{ .io = io };
    try decCheck(jxl.JxlDecoderSetParallelRunner(dec, Runner.run, &runner));
    try decCheck(jxl.JxlDecoderSubscribeEvents(dec, dec_basic_info | dec_full_image));
    try decCheck(jxl.JxlDecoderSetInput(dec, data.ptr, data.len));
    jxl.JxlDecoderCloseInput(dec);

    var native: ?NativeImage = null;
    errdefer if (native) |*img| img.deinit(allocator);

    while (true) {
        switch (jxl.JxlDecoderProcessInput(dec)) {
            dec_basic_info => {
                const info = try header(jxl, dec);
                if (limits.max_pixels != 0 and @as(u64, info.width) * info.height > limits.max_pixels) return error.ImageTooLarge;
                // Only honored for XYB images; others decode in their stored color space.
                const srgb: ColorEncoding = .srgb(info.num_color_channels == 1);
                _ = jxl.JxlDecoderSetPreferredColorProfile(dec, &srgb);
                // Gray with alpha widens to RGBA; libjxl replicates gray into color output.
                native = if (info.has_alpha)
                    .{ .rgba = try .init(allocator, info.height, info.width) }
                else if (info.num_color_channels == 1)
                    .{ .grayscale = try .init(allocator, info.height, info.width) }
                else
                    .{ .rgb = try .init(allocator, info.height, info.width) };
            },
            dec_need_image_out_buffer => {
                const img = if (native) |*img| img else return error.InvalidJxl;
                const bytes, const channels: u32 = switch (img.*) {
                    .grayscale => |i| .{ i.asBytes(), 1 },
                    .rgb => |i| .{ i.asBytes(), 3 },
                    .rgba => |i| .{ i.asBytes(), 4 },
                };
                const format: PixelFormat = .{ .num_channels = channels };
                var size: usize = undefined;
                try decCheck(jxl.JxlDecoderImageOutBufferSize(dec, &format, &size));
                if (size != bytes.len) return error.InvalidJxl;
                try decCheck(jxl.JxlDecoderSetImageOutBuffer(dec, &format, bytes.ptr, bytes.len));
            },
            // First frame only: animations stop here.
            dec_full_image => return native orelse error.InvalidJxl,
            dec_need_more_input => return error.TruncatedData,
            else => return error.InvalidJxl,
        }
    }
}

/// Decodes a JPEG XL byte stream into `Image(T)`, converting from the natural pixel type as needed.
pub fn loadFromBytes(comptime T: type, io: Io, allocator: Allocator, data: []const u8, limits: DecodeLimits) !Image(T) {
    var native = try decode(io, allocator, data, limits);
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
            if (image.isContiguous()) return encodeRaw(io, allocator, image.asBytes(), image.cols, image.rows, @sizeOf(T), options);
            var contiguous = try image.dupe(allocator);
            defer contiguous.deinit(allocator);
            return encodeRaw(io, allocator, contiguous.asBytes(), image.cols, image.rows, @sizeOf(T), options);
        },
        else => {
            var rgb = try image.convert(io, allocator, Rgb);
            defer rgb.deinit(allocator);
            return encodeRaw(io, allocator, rgb.asBytes(), image.cols, image.rows, 3, options);
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

fn encodeRaw(io: Io, allocator: Allocator, pixels: []const u8, width: u32, height: u32, channels: u32, options: EncodeOptions) ![]u8 {
    const jxl = try api();
    const enc = jxl.JxlEncoderCreate(null) orelse return error.OutOfMemory;
    defer jxl.JxlEncoderDestroy(enc);
    var runner: Runner = .{ .io = io };
    try encCheck(jxl.JxlEncoderSetParallelRunner(enc, Runner.run, &runner));

    const lossless = options.quality >= 100;
    const has_alpha = channels % 2 == 0;
    const num_color_channels: u32 = if (channels < 3) 1 else 3;

    var info: BasicInfo = undefined;
    jxl.JxlEncoderInitBasicInfo(&info);
    info.xsize = width;
    info.ysize = height;
    info.bits_per_sample = 8;
    info.num_color_channels = num_color_channels;
    info.num_extra_channels = @intFromBool(has_alpha);
    info.alpha_bits = if (has_alpha) 8 else 0;
    // Lossless must keep the original color space; lossy is smaller in XYB.
    info.uses_original_profile = @intFromBool(lossless);
    try encCheck(jxl.JxlEncoderSetBasicInfo(enc, &info));

    const srgb: ColorEncoding = .srgb(num_color_channels == 1);
    try encCheck(jxl.JxlEncoderSetColorEncoding(enc, &srgb));

    const settings = jxl.JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;
    try encCheck(jxl.JxlEncoderSetFrameDistance(settings, distanceFromQuality(options.quality)));
    try encCheck(jxl.JxlEncoderSetFrameLossless(settings, @intFromBool(lossless)));
    try encCheck(jxl.JxlEncoderFrameSettingsSetOption(settings, enc_frame_setting_effort, std.math.clamp(options.effort, 1, 10)));

    const format: PixelFormat = .{ .num_channels = channels };
    try encCheck(jxl.JxlEncoderAddImageFrame(settings, &format, pixels.ptr, pixels.len));
    jxl.JxlEncoderCloseInput(enc);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.resize(allocator, @max(4096, pixels.len / 8));
    var written: usize = 0;
    while (true) {
        var next: [*]u8 = out.items.ptr + written;
        var avail: usize = out.items.len - written;
        const status = jxl.JxlEncoderProcessOutput(enc, &next, &avail);
        written = out.items.len - avail;
        switch (status) {
            enc_success => break,
            enc_need_more_output => try out.resize(allocator, out.items.len * 2),
            else => return error.JxlEncodeFailed,
        }
    }
    out.shrinkRetainingCapacity(written);
    return out.toOwnedSlice(allocator);
}

/// libjxl's quality→Butteraugli distance mapping (`JxlEncoderDistanceFromQuality`, cjxl `-q`).
fn distanceFromQuality(quality: u8) f32 {
    const q: f32 = @floatFromInt(quality);
    if (quality >= 100) return 0;
    if (quality >= 30) return 0.1 + (100 - q) * 0.09;
    return 53.0 / 3000.0 * q * q - 23.0 / 20.0 * q + 25.0;
}

fn header(jxl: *const Api, dec: *Decoder) !Header {
    var info: BasicInfo = undefined;
    try decCheck(jxl.JxlDecoderGetBasicInfo(dec, &info));
    // The decoder applies orientation, so 5-8 (transposed) swap the output dimensions.
    const transposed = info.orientation >= 5;
    return .{
        .width = if (transposed) info.ysize else info.xsize,
        .height = if (transposed) info.xsize else info.ysize,
        .bits_per_sample = info.bits_per_sample,
        .exponent_bits_per_sample = info.exponent_bits_per_sample,
        .num_color_channels = info.num_color_channels,
        .has_alpha = info.alpha_bits > 0,
        .has_animation = info.have_animation != 0,
        .orientation = @bitCast(info.orientation),
        .uses_original_profile = info.uses_original_profile != 0,
    };
}

fn decCheck(status: c_int) !void {
    if (status != dec_success) return error.InvalidJxl;
}

fn encCheck(status: c_int) !void {
    if (status != enc_success) return error.JxlEncodeFailed;
}

/// `JxlParallelRunner` on an `Io` pool: one task per CPU, each pulling items off a shared counter
/// (work items vary widely in cost), with the task index as libjxl's thread id.
const Runner = struct {
    io: Io,

    const Work = struct {
        opaque_ptr: ?*anyopaque,
        func: RunFn,
        next: std.atomic.Value(u32),
        end: u32,
    };

    fn run(runner_ptr: ?*anyopaque, opaque_ptr: ?*anyopaque, init: InitFn, func: RunFn, start: u32, end: u32) callconv(.c) c_int {
        const self: *const Runner = @ptrCast(@alignCast(runner_ptr));
        const count = end - start;
        const tasks = if (builtin.single_threaded) 1 else @max(1, @min(count, parallel.cpuCount()));
        const ret = init(opaque_ptr, tasks);
        if (ret != 0) return ret;
        var work: Work = .{ .opaque_ptr = opaque_ptr, .func = func, .next = .init(start), .end = end };
        parallel.forRowBands(self.io, tasks, tasks, &work, task);
        return 0;
    }

    fn task(work: *Work, thread_id: usize, _: usize, _: usize) void {
        while (true) {
            const i = work.next.fetchAdd(1, .monotonic);
            if (i >= work.end) return;
            work.func(work.opaque_ptr, i, thread_id);
        }
    }
};

// libjxl ABI, declared by hand so the build needs no libjxl headers. Stable since libjxl 0.7.

const Decoder = opaque {};
const Encoder = opaque {};
const FrameSettings = opaque {};
const Bool = c_int;

const InitFn = *const fn (opaque_ptr: ?*anyopaque, num_threads: usize) callconv(.c) c_int;
const RunFn = *const fn (opaque_ptr: ?*anyopaque, value: u32, thread_id: usize) callconv(.c) void;
const RunnerFn = *const fn (runner: ?*anyopaque, opaque_ptr: ?*anyopaque, init: InitFn, func: RunFn, start: u32, end: u32) callconv(.c) c_int;

const dec_success = 0;
const dec_need_more_input = 2;
const dec_need_image_out_buffer = 5;
const dec_basic_info = 0x40;
const dec_full_image = 0x1000;
const enc_success = 0;
const enc_need_more_output = 2;
const enc_frame_setting_effort = 0;

const PixelFormat = extern struct {
    num_channels: u32,
    data_type: c_int = 2, // JXL_TYPE_UINT8
    endianness: c_int = 0, // JXL_NATIVE_ENDIAN
    @"align": usize = 0,
};

const BasicInfo = extern struct {
    have_container: Bool,
    xsize: u32,
    ysize: u32,
    bits_per_sample: u32,
    exponent_bits_per_sample: u32,
    intensity_target: f32,
    min_nits: f32,
    relative_to_max_display: Bool,
    linear_below: f32,
    uses_original_profile: Bool,
    have_preview: Bool,
    have_animation: Bool,
    orientation: c_int,
    num_color_channels: u32,
    num_extra_channels: u32,
    alpha_bits: u32,
    alpha_exponent_bits: u32,
    alpha_premultiplied: Bool,
    preview: [2]u32,
    animation: extern struct { tps_numerator: u32, tps_denominator: u32, num_loops: u32, have_timecodes: Bool },
    intrinsic_xsize: u32,
    intrinsic_ysize: u32,
    padding: [100]u8,
};

const ColorEncoding = extern struct {
    color_space: c_int,
    white_point: c_int,
    white_point_xy: [2]f64 = @splat(0),
    primaries: c_int,
    primaries_red_xy: [2]f64 = @splat(0),
    primaries_green_xy: [2]f64 = @splat(0),
    primaries_blue_xy: [2]f64 = @splat(0),
    transfer_function: c_int,
    gamma: f64 = 0,
    rendering_intent: c_int,

    /// Same as `JxlColorEncodingSetToSRGB`.
    fn srgb(gray: bool) ColorEncoding {
        return .{
            .color_space = if (gray) 1 else 0, // GRAY / RGB
            .white_point = 1, // D65
            .primaries = 1, // SRGB
            .transfer_function = 13, // SRGB
            .rendering_intent = 1, // RELATIVE
        };
    }
};

/// The libjxl entry points used here; field names are the exported symbols.
const Api = struct {
    JxlDecoderCreate: *const fn (memory_manager: ?*const anyopaque) callconv(.c) ?*Decoder,
    JxlDecoderDestroy: *const fn (dec: *Decoder) callconv(.c) void,
    JxlDecoderSubscribeEvents: *const fn (dec: *Decoder, events: c_int) callconv(.c) c_int,
    JxlDecoderSetParallelRunner: *const fn (dec: *Decoder, runner: RunnerFn, runner_opaque: ?*anyopaque) callconv(.c) c_int,
    JxlDecoderSetInput: *const fn (dec: *Decoder, data: [*]const u8, size: usize) callconv(.c) c_int,
    JxlDecoderReleaseInput: *const fn (dec: *Decoder) callconv(.c) usize,
    JxlDecoderCloseInput: *const fn (dec: *Decoder) callconv(.c) void,
    JxlDecoderProcessInput: *const fn (dec: *Decoder) callconv(.c) c_int,
    JxlDecoderGetBasicInfo: *const fn (dec: *const Decoder, info: *BasicInfo) callconv(.c) c_int,
    JxlDecoderSetPreferredColorProfile: *const fn (dec: *Decoder, color_encoding: *const ColorEncoding) callconv(.c) c_int,
    JxlDecoderImageOutBufferSize: *const fn (dec: *const Decoder, format: *const PixelFormat, size: *usize) callconv(.c) c_int,
    JxlDecoderSetImageOutBuffer: *const fn (dec: *Decoder, format: *const PixelFormat, buffer: [*]u8, size: usize) callconv(.c) c_int,

    JxlEncoderCreate: *const fn (memory_manager: ?*const anyopaque) callconv(.c) ?*Encoder,
    JxlEncoderDestroy: *const fn (enc: *Encoder) callconv(.c) void,
    JxlEncoderSetParallelRunner: *const fn (enc: *Encoder, runner: RunnerFn, runner_opaque: ?*anyopaque) callconv(.c) c_int,
    JxlEncoderInitBasicInfo: *const fn (info: *BasicInfo) callconv(.c) void,
    JxlEncoderSetBasicInfo: *const fn (enc: *Encoder, info: *const BasicInfo) callconv(.c) c_int,
    JxlEncoderSetColorEncoding: *const fn (enc: *Encoder, color: *const ColorEncoding) callconv(.c) c_int,
    JxlEncoderFrameSettingsCreate: *const fn (enc: *Encoder, source: ?*const FrameSettings) callconv(.c) ?*FrameSettings,
    JxlEncoderSetFrameDistance: *const fn (settings: *FrameSettings, distance: f32) callconv(.c) c_int,
    JxlEncoderSetFrameLossless: *const fn (settings: *FrameSettings, lossless: Bool) callconv(.c) c_int,
    JxlEncoderFrameSettingsSetOption: *const fn (settings: *FrameSettings, option: c_int, value: i64) callconv(.c) c_int,
    JxlEncoderAddImageFrame: *const fn (settings: *const FrameSettings, format: *const PixelFormat, buffer: *const anyopaque, size: usize) callconv(.c) c_int,
    JxlEncoderCloseInput: *const fn (enc: *Encoder) callconv(.c) void,
    JxlEncoderProcessOutput: *const fn (enc: *Encoder, next_out: *[*]u8, avail_out: *usize) callconv(.c) c_int,
};

/// Newest first; the soname carries the minor version while libjxl is 0.x.
const library_names: []const []const u8 = switch (builtin.os.tag) {
    .macos => &.{ "libjxl.dylib", "/opt/homebrew/lib/libjxl.dylib", "/usr/local/lib/libjxl.dylib" },
    else => &.{ "libjxl.so.1", "libjxl.so.0.13", "libjxl.so.0.12", "libjxl.so.0.11", "libjxl.so.0.10", "libjxl.so.0.9", "libjxl.so.0.8", "libjxl.so.0.7", "libjxl.so" },
};

var loaded: std.atomic.Value(?*const Api) = .init(null);

/// Opens libjxl once per process; the library stays loaded. Racing first calls both load it
/// and the loser drops its copy (`dlopen` is reference counted).
fn api() error{JxlUnavailable}!*const Api {
    if (loaded.load(.acquire)) |ptr| return ptr;
    var lib: std.DynLib = for (library_names) |name| {
        break std.DynLib.open(name) catch continue;
    } else return error.JxlUnavailable;
    const table = std.heap.page_allocator.create(Api) catch {
        lib.close();
        return error.JxlUnavailable;
    };
    inline for (comptime meta.structFields(Api)) |field| {
        @field(table, field.name) = lib.lookup(field.type, field.name) orelse {
            std.heap.page_allocator.destroy(table);
            lib.close();
            return error.JxlUnavailable;
        };
    }
    if (loaded.cmpxchgStrong(null, table, .acq_rel, .acquire)) |winner| {
        std.heap.page_allocator.destroy(table);
        lib.close();
        return winner.?;
    }
    return table;
}

test "signature detection" {
    try std.testing.expect(hasSignature(&signature));
    try std.testing.expect(hasSignature(&container_signature));
    try std.testing.expect(!hasSignature(&.{ 0xFF, 0xD8 }));
}

test "disabled build reports JxlNotEnabled" {
    if (enabled) return error.SkipZigTest;
    try std.testing.expectError(error.JxlNotEnabled, decode(std.testing.io, std.testing.allocator, &signature, .default));
}

test "ABI layout matches libjxl" {
    // sizeof/offsetof from the libjxl headers on 64-bit targets.
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try std.testing.expectEqual(204, @sizeOf(BasicInfo));
    try std.testing.expectEqual(104, @sizeOf(ColorEncoding));
    try std.testing.expectEqual(24, @sizeOf(PixelFormat));
    try std.testing.expectEqual(48, @offsetOf(BasicInfo, "orientation"));
    try std.testing.expectEqual(96, @offsetOf(ColorEncoding, "rendering_intent"));
}

test "quality maps to libjxl distances" {
    try std.testing.expectEqual(0, distanceFromQuality(100));
    try std.testing.expectApproxEqAbs(1.0, distanceFromQuality(90), 1e-6);
    try std.testing.expectApproxEqAbs(25.0, distanceFromQuality(0), 1e-6);
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

/// Skips when this machine has no libjxl.
fn requireLibjxl() !void {
    if (!enabled) return error.SkipZigTest;
    _ = api() catch return error.SkipZigTest;
}

test "lossless round trip" {
    try requireLibjxl();
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
    try requireLibjxl();
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
