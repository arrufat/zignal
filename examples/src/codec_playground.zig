const std = @import("std");
const builtin = @import("builtin");

const zignal = @import("zignal");
const Image = zignal.Image;
const ImageFormat = zignal.ImageFormat;
const png = zignal.png;
const jpeg = zignal.jpeg;
const bmp = zignal.bmp;
const gif = zignal.gif;

const Rgba = zignal.Rgba(u8);

const js = @import("js.zig");

pub const std_options: std.Options = .{
    .logFn = if (builtin.cpu.arch.isWasm()) js.logFn else std.log.defaultLog,
    .log_level = std.log.default_level,
};

comptime {
    _ = js.alloc;
    _ = js.free;
}

pub fn panic(msg: []const u8, st: ?*std.builtin.StackTrace, addr: ?usize) noreturn {
    _ = st;
    _ = addr;
    std.log.err("panic: {s}", .{msg});
    @trap();
}

const allocator = if (builtin.cpu.arch.isWasm() and builtin.os.tag == .freestanding)
    std.heap.wasm_allocator
else
    std.heap.page_allocator;

// Single-image pipeline state; all results cross the JS boundary as JSON via json_ptr/json_len.
var g_source: ?Image(Rgba) = null;
var g_source_gray: bool = false;
var g_gray: ?Image(u8) = null; // lazy grayscale conversion of g_source
var g_encoded: ?[]u8 = null;
var g_output: ?Image(Rgba) = null;
var g_json: ?[]u8 = null;

fn setJson(json: []u8) void {
    if (g_json) |old| allocator.free(old);
    g_json = json;
}

fn fail(err_name: []const u8, message: []const u8) i32 {
    const json = std.fmt.allocPrint(
        allocator,
        "{{\"ok\":false,\"error\":\"{s}\",\"message\":\"{s}\"}}",
        .{ err_name, message },
    ) catch @panic("OOM");
    setJson(json);
    return 0;
}

fn failErr(err: anyerror) i32 {
    const message = switch (err) {
        error.ImageTooLarge, error.PngDataTooLarge => "Image exceeds the decoder size limits.",
        error.OutOfMemory => "Out of memory.",
        else => "",
    };
    return fail(@errorName(err), message);
}

pub export fn json_ptr() [*]const u8 {
    return if (g_json) |json| json.ptr else @ptrCast("");
}

pub export fn json_len() usize {
    return if (g_json) |json| json.len else 0;
}

fn isGrayscale(image: Image(Rgba)) bool {
    for (image.data) |px| {
        if (px.r != px.g or px.g != px.b or px.a != 255) return false;
    }
    return true;
}

/// Writes the info-object fields sans surrounding braces so callers can append
/// their own; enums emit raw tag names (display formatting lives in JS).
fn writeInfoFields(w: *std.Io.Writer, format: ImageFormat, data: []const u8) !void {
    switch (format) {
        inline else => |f| {
            const codec = switch (f) {
                .jpeg => jpeg,
                .png => png,
                .bmp => bmp,
                .gif => gif,
            };
            var reader: std.Io.Reader = .fixed(data);
            const h = try codec.getInfo(&reader, .{});
            try w.print("\"format\":\"{t}\",\"width\":{d},\"height\":{d},\"file_size\":{d},\"details\":{{", .{ f, h.width, h.height, data.len });
            switch (f) {
                .jpeg => {
                    try w.print("\"frame_type\":\"{t}\",\"num_components\":{d},\"precision\":{d},\"subsampling\":", .{ h.frame_type, h.num_components, h.precision });
                    if (h.subsampling) |s| try w.print("\"{t}\"", .{s}) else try w.writeAll("null");
                },
                .png => {
                    try w.print("\"bit_depth\":{d},\"color_type\":\"{t}\",\"interlaced\":{},\"gamma\":", .{ h.bit_depth, h.color_type, h.interlace_method == 1 });
                    if (h.gamma) |g| try w.print("{d:.4}", .{g}) else try w.writeAll("null");
                    try w.writeAll(",\"srgb_intent\":");
                    if (h.srgb_intent) |s| try w.print("\"{t}\"", .{s}) else try w.writeAll("null");
                },
                .bmp => {
                    // tagName over {t}: Compression and DibHeaderKind are non-exhaustive.
                    try w.print("\"bit_depth\":{d},\"compression\":\"{s}\",\"dib_header\":\"{s}\",\"top_down\":{},\"palette_entries\":{d},\"has_alpha\":{}", .{
                        h.bit_depth,
                        std.enums.tagName(bmp.Compression, h.compression) orelse "unknown",
                        std.enums.tagName(bmp.DibHeaderKind, h.dib_kind) orelse "unknown",
                        h.top_down,
                        h.palette_entries,
                        h.hasAlpha(),
                    });
                },
                .gif => {
                    try w.print("\"version\":\"{t}\",\"frame_count\":{d},\"loop_count\":{d},\"global_color_table_size\":{d}", .{ h.version, h.frame_count, h.loop_count, h.global_color_table_size });
                },
            }
            try w.writeAll("}");
        },
    }
}

/// Decodes the image (first frame for animated GIFs) and stores source-info
/// JSON. Returns 1 on success; the input bytes are not retained.
pub export fn load_image(ptr: [*]const u8, len: usize) i32 {
    const data = ptr[0..len];

    const format = ImageFormat.detectFromBytes(data) orelse
        return fail("UnsupportedFormat", "Unrecognized image format. Supported: PNG, JPEG, BMP, GIF.");

    const t0 = js.nowFn();
    const image = Image(Rgba).loadFromBytes(allocator, data) catch |err| return failErr(err);
    const decode_ms = js.nowFn() - t0;

    if (g_source) |*old| old.deinit(allocator);
    g_source = image;
    if (g_gray) |*old| old.deinit(allocator);
    g_gray = null;
    g_source_gray = isGrayscale(image);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    write: {
        w.writeAll("{\"ok\":true,") catch break :write;
        writeInfoFields(w, format, data) catch break :write;
        w.print(",\"grayscale\":{},\"decode_ms\":{d:.1}}}", .{ g_source_gray, decode_ms }) catch break :write;
        setJson(aw.toOwnedSlice() catch @panic("OOM"));
        return 1;
    }
    return fail("InfoFailed", "Failed to read image metadata.");
}

pub export fn source_width() u32 {
    return if (g_source) |image| image.cols else 0;
}

pub export fn source_height() u32 {
    return if (g_source) |image| image.rows else 0;
}

pub export fn source_pixels() [*]const u8 {
    return if (g_source) |image| @ptrCast(image.data.ptr) else @ptrCast("");
}

/// Takes ownership of `bytes`; decodes it back for the preview and builds the stats JSON.
fn finishEncode(format: ImageFormat, bytes: []u8, encode_ms: f32) i32 {
    if (g_encoded) |old| allocator.free(old);
    g_encoded = bytes;
    if (g_output) |*old| old.deinit(allocator);
    g_output = null;

    g_output = Image(Rgba).loadFromBytes(allocator, bytes) catch |err| return failErr(err);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    write: {
        w.print("{{\"ok\":true,\"size\":{d},\"encode_ms\":{d:.1},\"info\":{{", .{ bytes.len, encode_ms }) catch break :write;
        writeInfoFields(w, format, bytes) catch break :write;
        w.writeAll("}}") catch break :write;
        setJson(aw.toOwnedSlice() catch @panic("OOM"));
        return 1;
    }
    return fail("InfoFailed", "Failed to read encoded image metadata.");
}

/// Runs `codec.encode` on the source as Rgba, or as u8 via the cached grayscale conversion.
fn encodeSource(comptime codec: type, as_gray: u32, options: codec.EncodeOptions) ![]u8 {
    const source = g_source orelse return error.NoImage;
    if (as_gray != 0) {
        if (g_gray == null) g_gray = try source.convert(allocator, u8);
        return codec.encode(u8, allocator, g_gray.?, options);
    }
    return codec.encode(Rgba, allocator, source, options);
}

/// Shared tail of the encode_* exports: time the encode and finish with stats JSON.
fn encodeAndFinish(comptime codec: type, format: ImageFormat, as_gray: u32, options: codec.EncodeOptions) i32 {
    const t0 = js.nowFn();
    const bytes = encodeSource(codec, as_gray, options) catch |err| return failErr(err);
    return finishEncode(format, bytes, js.nowFn() - t0);
}

pub export fn encode_jpeg(
    as_gray: u32,
    quality: u32,
    subsampling: u32, // 0 = 4:4:4, 1 = 4:2:2, 2 = 4:2:0
    density_dpi: u32,
    comment_ptr: [*]const u8,
    comment_len: usize,
) i32 {
    return encodeAndFinish(jpeg, .jpeg, as_gray, .{
        .quality = @intCast(std.math.clamp(quality, 1, 100)),
        .subsampling = switch (subsampling) {
            0 => .yuv444,
            1 => .yuv422,
            else => .yuv420,
        },
        .density_dpi = @intCast(std.math.clamp(density_dpi, 1, 65535)),
        .comment = if (comment_len > 0) comment_ptr[0..comment_len] else null,
    });
}

pub export fn encode_png(
    as_gray: u32,
    filter_mode: u32, // 0 = adaptive, 1 = none, 2..5 = fixed sub/up/average/paeth
    compression: u32, // 0 = filtered preset (default), 1 = fastest, 2 = default, 3 = best
    gamma: f32, // <= 0 means omit
    srgb_intent: i32, // -1 = omit, 0..3 = SrgbRenderingIntent
) i32 {
    return encodeAndFinish(png, .png, as_gray, .{
        .filter = switch (filter_mode) {
            1 => .none,
            2 => .{ .fixed = .sub },
            3 => .{ .fixed = .up },
            4 => .{ .fixed = .average },
            5 => .{ .fixed = .paeth },
            else => .adaptive,
        },
        .compress_options = switch (compression) {
            1 => .fastest,
            2 => .default,
            3 => .best,
            else => png.EncodeOptions.default.compress_options,
        },
        .gamma = if (gamma > 0) gamma else null,
        .srgb_intent = if (srgb_intent >= 0 and srgb_intent <= 3) @fromBackingInt(@intCast(srgb_intent)) else null,
    });
}

pub export fn encode_bmp(as_gray: u32, use_palette_for_grayscale: u32, top_down: u32) i32 {
    return encodeAndFinish(bmp, .bmp, as_gray, .{
        .use_palette_for_grayscale = use_palette_for_grayscale != 0,
        .top_down = top_down != 0,
    });
}

pub export fn encode_gif(as_gray: u32, max_colors: u32, dither: u32) i32 {
    return encodeAndFinish(gif, .gif, as_gray, .{
        .max_colors = @intCast(std.math.clamp(max_colors, 2, 256)),
        .dither = dither != 0,
    });
}

pub export fn encoded_ptr() [*]const u8 {
    return if (g_encoded) |bytes| bytes.ptr else @ptrCast("");
}

pub export fn encoded_len() usize {
    return if (g_encoded) |bytes| bytes.len else 0;
}

pub export fn output_width() u32 {
    return if (g_output) |image| image.cols else 0;
}

pub export fn output_height() u32 {
    return if (g_output) |image| image.rows else 0;
}

pub export fn output_pixels() [*]const u8 {
    return if (g_output) |image| @ptrCast(image.data.ptr) else @ptrCast("");
}
