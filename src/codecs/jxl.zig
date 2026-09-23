//! JPEG XL codec backed by the system libjxl, opened at runtime (see `dynlib.zig`).
//! Signature detection works in every build.

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
const parallel = @import("../parallel.zig");
const Rgb = @import("../color.zig").Rgb(u8);
const Rgba = @import("../color.zig").Rgba(u8);

/// Whether this build can load libjxl; otherwise every call returns `error.CodecNotEnabled`.
pub const enabled = dynlib.supported;

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
    max_jxl_bytes: usize = codecs.max_file_size,
    /// Maximum decoded pixel count (per frame); 0 disables the cap.
    max_pixels: u64 = 1 << 28,
    /// Maximum animation frames; 0 disables the cap.
    max_frames: u32 = 4096,
    /// Maximum pixels across all frames; 0 disables the cap.
    max_total_pixels: u64 = 1 << 30,

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
    uses_original_profile: bool,

    fn fromBasicInfo(info: BasicInfo) Header {
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
            .uses_original_profile = info.uses_original_profile != 0,
        };
    }
};

/// Reads just enough of `reader` to parse the header.
pub fn getInfo(reader: *Io.Reader, limits: DecodeLimits) !Header {
    if (!enabled) return error.CodecNotEnabled;
    _ = limits;
    const jxl = try Libjxl.get();
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
            dec_basic_info => return .fromBasicInfo(try basicInfo(jxl, dec)),
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
    if (!enabled) return error.CodecNotEnabled;
    var reader: FrameReader = undefined;
    try reader.init(io, data, limits);
    defer reader.deinit();
    const frame = try reader.next(allocator) orelse return error.InvalidJxl;
    return frame.image;
}

/// Loads every displayed frame; a still JPEG XL gives one frame.
pub fn loadAnimatedFromBytes(comptime T: type, io: Io, allocator: Allocator, data: []const u8, limits: DecodeLimits) !AnimatedImage(T) {
    if (!enabled) return error.CodecNotEnabled;
    var reader: FrameReader = undefined;
    try reader.init(io, data, limits);
    defer reader.deinit();
    var builder: animated.Builder(T) = .{};
    defer builder.deinit(allocator);
    const frame_pixels = @as(u64, reader.header.width) * reader.header.height;
    while (try reader.next(allocator)) |frame| {
        var image = frame.image;
        const count = builder.frames.items.len + 1;
        if (codecs.exceeds(limits.max_frames, count) or codecs.exceeds(limits.max_total_pixels, count * frame_pixels)) {
            image.deinit(allocator);
            return error.TooManyFrames;
        }
        try builder.append(allocator, try image.into(T, io, allocator), frame.duration_ms);
    }
    return builder.finish(allocator, reader.animation.num_loops);
}

pub fn loadAnimated(comptime T: type, io: Io, allocator: Allocator, file_path: []const u8, limits: DecodeLimits) !AnimatedImage(T) {
    if (!enabled) return error.CodecNotEnabled;
    const data = try codecs.readFile(io, allocator, file_path, limits.max_jxl_bytes);
    defer allocator.free(data);
    return loadAnimatedFromBytes(T, io, allocator, data, limits);
}

/// Walks the displayed frames of a codestream. Pinned in place once `init` hands libjxl a
/// pointer to `runner`.
const FrameReader = struct {
    jxl: *const Api,
    dec: *Decoder,
    runner: Runner,
    header: Header,
    animation: @FieldType(BasicInfo, "animation"),

    fn init(self: *FrameReader, io: Io, data: []const u8, limits: DecodeLimits) !void {
        if (!hasSignature(data)) return error.InvalidJxl;
        const jxl = try Libjxl.get();
        const dec = jxl.JxlDecoderCreate(null) orelse return error.OutOfMemory;
        errdefer jxl.JxlDecoderDestroy(dec);
        self.* = .{ .jxl = jxl, .dec = dec, .runner = .{ .io = io }, .header = undefined, .animation = undefined };
        try decCheck(jxl.JxlDecoderSetParallelRunner(dec, Runner.run, &self.runner));
        try decCheck(jxl.JxlDecoderSubscribeEvents(dec, dec_basic_info | dec_frame | dec_full_image));
        try decCheck(jxl.JxlDecoderSetInput(dec, data.ptr, data.len));
        jxl.JxlDecoderCloseInput(dec);

        switch (jxl.JxlDecoderProcessInput(dec)) {
            dec_basic_info => {},
            dec_need_more_input => return error.TruncatedData,
            else => return error.InvalidJxl,
        }
        const info = try basicInfo(jxl, dec);
        self.header = .fromBasicInfo(info);
        self.animation = info.animation;
        if (codecs.exceeds(limits.max_pixels, @as(u64, self.header.width) * self.header.height)) return error.ImageTooLarge;
        // Only honored for XYB images; others decode in their stored color space.
        const srgb: ColorEncoding = .srgb(self.header.num_color_channels == 1);
        _ = jxl.JxlDecoderSetPreferredColorProfile(dec, &srgb);
    }

    fn deinit(self: *FrameReader) void {
        self.jxl.JxlDecoderDestroy(self.dec);
    }

    /// The next displayed frame in its natural pixel type, or null after the last one.
    fn next(self: *FrameReader, allocator: Allocator) !?struct { image: NativeImage, duration_ms: u32 } {
        const jxl = self.jxl;
        var native: ?NativeImage = null;
        errdefer if (native) |*img| img.deinit(allocator);
        var duration_ms: u32 = 0;
        while (true) {
            switch (jxl.JxlDecoderProcessInput(self.dec)) {
                dec_frame => {
                    var frame: FrameHeader = undefined;
                    try decCheck(jxl.JxlDecoderGetFrameHeader(self.dec, &frame));
                    duration_ms = ticksToMs(frame.duration, self.animation.tps_numerator, self.animation.tps_denominator);
                },
                dec_need_image_out_buffer => {
                    const h = self.header;
                    // Gray with alpha widens to RGBA; libjxl replicates gray into color output.
                    native = if (h.has_alpha)
                        .{ .rgba = try .init(allocator, h.height, h.width) }
                    else if (h.num_color_channels == 1)
                        .{ .grayscale = try .init(allocator, h.height, h.width) }
                    else
                        .{ .rgb = try .init(allocator, h.height, h.width) };
                    const bytes, const channels: u32 = switch (native.?) {
                        .grayscale => |i| .{ i.asBytes(), 1 },
                        .rgb => |i| .{ i.asBytes(), 3 },
                        .rgba => |i| .{ i.asBytes(), 4 },
                    };
                    const format: PixelFormat = .{ .num_channels = channels };
                    var size: usize = undefined;
                    try decCheck(jxl.JxlDecoderImageOutBufferSize(self.dec, &format, &size));
                    if (size != bytes.len) return error.InvalidJxl;
                    try decCheck(jxl.JxlDecoderSetImageOutBuffer(self.dec, &format, bytes.ptr, bytes.len));
                },
                dec_full_image => return .{ .image = native orelse return error.InvalidJxl, .duration_ms = duration_ms },
                dec_success => return null,
                dec_need_more_input => return error.TruncatedData,
                else => return error.InvalidJxl,
            }
        }
    }
};

/// Converts animation ticks to milliseconds, saturating.
fn ticksToMs(ticks: u32, tps_numerator: u32, tps_denominator: u32) u32 {
    if (tps_numerator == 0) return 0;
    const ms = @as(u64, ticks) * 1000 * tps_denominator / tps_numerator;
    return @min(ms, std.math.maxInt(u32));
}

/// Decodes a JPEG XL byte stream into `Image(T)`, converting from the natural pixel type as needed.
pub fn loadFromBytes(comptime T: type, io: Io, allocator: Allocator, data: []const u8, limits: DecodeLimits) !Image(T) {
    var native = try decode(io, allocator, data, limits);
    return native.into(T, io, allocator);
}

pub fn load(comptime T: type, io: Io, allocator: Allocator, file_path: []const u8, limits: DecodeLimits) !Image(T) {
    if (!enabled) return error.CodecNotEnabled;
    const data = try codecs.readFile(io, allocator, file_path, limits.max_jxl_bytes);
    defer allocator.free(data);
    return loadFromBytes(T, io, allocator, data, limits);
}

/// Encodes `image` as sRGB JPEG XL. `u8`→grayscale, `Rgb`→RGB, `Rgba`→RGBA, others→RGB.
pub fn encode(comptime T: type, io: Io, allocator: Allocator, image: Image(T), options: EncodeOptions) ![]u8 {
    var frames = [_]Image(T){image};
    var durations = [_]u32{0};
    return encodeAnimated(T, io, allocator, .{ .frames = &frames, .durations_ms = &durations, .loop_count = 0 }, options);
}

pub fn save(comptime T: type, io: Io, allocator: Allocator, image: Image(T), file_path: []const u8) !void {
    const bytes = try encode(T, io, allocator, image, .default);
    defer allocator.free(bytes);
    try codecs.writeFile(io, file_path, bytes);
}

/// Encodes every frame of `anim` at its full size; pixel types map as in `encode`.
/// A one-frame animation is written as a still.
pub fn encodeAnimated(comptime T: type, io: Io, allocator: Allocator, anim: AnimatedImage(T), options: EncodeOptions) ![]u8 {
    if (!enabled) return error.CodecNotEnabled;
    try anim.validate();
    const frames = anim.frames;
    const is_animation = frames.len > 1;
    // The pixel type handed to libjxl.
    const E = switch (T) {
        u8, Rgb, Rgba => T,
        else => Rgb,
    };
    const channels: u32 = @sizeOf(E);
    const jxl = try Libjxl.get();
    const enc = jxl.JxlEncoderCreate(null) orelse return error.OutOfMemory;
    defer jxl.JxlEncoderDestroy(enc);
    var runner: Runner = .{ .io = io };
    try encCheck(jxl.JxlEncoderSetParallelRunner(enc, Runner.run, &runner));

    const lossless = options.quality >= 100;
    const has_alpha = channels % 2 == 0;
    const num_color_channels: u32 = if (channels < 3) 1 else 3;

    var info: BasicInfo = undefined;
    jxl.JxlEncoderInitBasicInfo(&info);
    info.xsize = frames[0].cols;
    info.ysize = frames[0].rows;
    info.bits_per_sample = 8;
    info.num_color_channels = num_color_channels;
    info.num_extra_channels = @intFromBool(has_alpha);
    info.alpha_bits = if (has_alpha) 8 else 0;
    // Lossless must keep the original color space; lossy is smaller in XYB.
    info.uses_original_profile = @intFromBool(lossless);
    if (is_animation) {
        info.have_animation = 1;
        // One tick per millisecond.
        info.animation = .{ .tps_numerator = 1000, .tps_denominator = 1, .num_loops = anim.loop_count, .have_timecodes = 0 };
    }
    try encCheck(jxl.JxlEncoderSetBasicInfo(enc, &info));

    const srgb: ColorEncoding = .srgb(num_color_channels == 1);
    try encCheck(jxl.JxlEncoderSetColorEncoding(enc, &srgb));

    const settings = jxl.JxlEncoderFrameSettingsCreate(enc, null) orelse return error.OutOfMemory;
    try encCheck(jxl.JxlEncoderSetFrameDistance(settings, distanceFromQuality(options.quality)));
    try encCheck(jxl.JxlEncoderSetFrameLossless(settings, @intFromBool(lossless)));
    try encCheck(jxl.JxlEncoderFrameSettingsSetOption(settings, enc_frame_setting_effort, std.math.clamp(options.effort, 1, 10)));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, @max(4096, @as(usize, frames[0].cols) * frames[0].rows * channels / 8));
    var scratch: ?Image(E) = null;
    defer if (scratch) |*img| img.deinit(allocator);

    const format: PixelFormat = .{ .num_channels = channels };
    // Frames store only their changed region, replacing it over the previous frame.
    var template: FrameHeader = undefined;
    if (is_animation) {
        jxl.JxlEncoderInitFrameHeader(&template);
        template.layer_info.blend_info.blendmode = blend_replace;
        template.layer_info.blend_info.source = previous_frame_slot;
        template.layer_info.save_as_reference = previous_frame_slot;
        // libjxl treats a full-size crop as no crop.
        template.layer_info.have_crop = 1;
        if (has_alpha) {
            var alpha_blend: BlendInfo = undefined;
            jxl.JxlEncoderInitBlendInfo(&alpha_blend);
            alpha_blend.blendmode = blend_replace;
            alpha_blend.source = previous_frame_slot;
            try encCheck(jxl.JxlEncoderSetExtraChannelBlendInfo(settings, 0, &alpha_blend));
        }
    }

    for (frames, 0..) |frame, i| {
        const region = anim.changedRegion(i);
        if (is_animation) {
            var header = template;
            header.duration = anim.durations_ms[i];
            header.layer_info.crop_x0 = @intCast(region.l);
            header.layer_info.crop_y0 = @intCast(region.t);
            header.layer_info.xsize = region.width();
            header.layer_info.ysize = region.height();
            try encCheck(jxl.JxlEncoderSetFrameHeader(settings, &header));
        }
        const part = frame.view(region);
        const pixels: Image(E) = if (T == E and part.isContiguous()) part else blk: {
            if (scratch == null) scratch = try .init(allocator, frame.rows, frame.cols);
            const packed_part: Image(E) = .initFromSlice(part.rows, part.cols, scratch.?.data[0 .. part.rows * part.cols]);
            part.convertInto(io, E, packed_part);
            break :blk packed_part;
        };
        const bytes = pixels.asBytes();
        try encCheck(jxl.JxlEncoderAddImageFrame(settings, &format, bytes.ptr, bytes.len));
        // Drain as we go so libjxl does not hold every queued frame; the last one must
        // follow `CloseInput`.
        if (i + 1 < frames.len) try drainOutput(jxl, enc, allocator, &out);
    }
    jxl.JxlEncoderCloseInput(enc);
    try drainOutput(jxl, enc, allocator, &out);
    return out.toOwnedSlice(allocator);
}

/// Appends everything libjxl has ready to `out`.
fn drainOutput(jxl: *const Api, enc: *Encoder, allocator: Allocator, out: *std.ArrayList(u8)) !void {
    while (true) {
        const free = out.unusedCapacitySlice();
        var next: [*]u8 = free.ptr;
        var avail: usize = free.len;
        const status = jxl.JxlEncoderProcessOutput(enc, &next, &avail);
        out.items.len += free.len - avail;
        switch (status) {
            enc_success => return,
            enc_need_more_output => try out.ensureUnusedCapacity(allocator, out.capacity),
            else => return error.JxlEncodeFailed,
        }
    }
}

/// libjxl's quality→Butteraugli distance mapping (`JxlEncoderDistanceFromQuality`, cjxl `-q`).
fn distanceFromQuality(quality: u8) f32 {
    const q: f32 = quality;
    if (quality >= 100) return 0;
    if (quality >= 30) return 0.1 + (100 - q) * 0.09;
    return 53.0 / 3000.0 * q * q - 23.0 / 20.0 * q + 25.0;
}

fn basicInfo(jxl: *const Api, dec: *Decoder) !BasicInfo {
    var info: BasicInfo = undefined;
    try decCheck(jxl.JxlDecoderGetBasicInfo(dec, &info));
    return info;
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
const dec_frame = 0x400;
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

const BlendInfo = extern struct { blendmode: c_int, source: u32, alpha: u32, clamp: Bool };
const blend_replace = 0;
/// Slot 3 is reserved for the encoder.
const previous_frame_slot = 1;

const FrameHeader = extern struct {
    /// In animation ticks (`BasicInfo.animation`).
    duration: u32,
    timecode: u32,
    name_length: u32,
    is_last: Bool,
    layer_info: extern struct {
        have_crop: Bool,
        crop_x0: i32,
        crop_y0: i32,
        xsize: u32,
        ysize: u32,
        blend_info: BlendInfo,
        save_as_reference: u32,
    },
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
    JxlDecoderGetFrameHeader: *const fn (dec: *const Decoder, header: *FrameHeader) callconv(.c) c_int,
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
    JxlEncoderInitFrameHeader: *const fn (header: *FrameHeader) callconv(.c) void,
    JxlEncoderSetFrameHeader: *const fn (settings: *FrameSettings, header: *const FrameHeader) callconv(.c) c_int,
    JxlEncoderInitBlendInfo: *const fn (blend_info: *BlendInfo) callconv(.c) void,
    JxlEncoderSetExtraChannelBlendInfo: *const fn (settings: *FrameSettings, index: usize, blend_info: *const BlendInfo) callconv(.c) c_int,
    JxlEncoderAddImageFrame: *const fn (settings: *const FrameSettings, format: *const PixelFormat, buffer: *const anyopaque, size: usize) callconv(.c) c_int,
    JxlEncoderCloseInput: *const fn (enc: *Encoder) callconv(.c) void,
    JxlEncoderProcessOutput: *const fn (enc: *Encoder, next_out: *[*]u8, avail_out: *usize) callconv(.c) c_int,
};

/// Newest first; the soname carries the minor version while libjxl is 0.x.
const Libjxl = dynlib.Library(Api, switch (builtin.os.tag) {
    .macos => dynlib.macosNames("libjxl.dylib"),
    else => &.{ "libjxl.so.1", "libjxl.so.0.13", "libjxl.so.0.12", "libjxl.so.0.11", "libjxl.so.0.10", "libjxl.so.0.9", "libjxl.so.0.8", "libjxl.so.0.7", "libjxl.so" },
});

test "signature detection" {
    try std.testing.expect(hasSignature(&signature));
    try std.testing.expect(hasSignature(&container_signature));
    try std.testing.expect(!hasSignature(&.{ 0xFF, 0xD8 }));
}

test "disabled build reports CodecNotEnabled" {
    if (enabled) return error.SkipZigTest;
    try std.testing.expectError(error.CodecNotEnabled, decode(std.testing.io, std.testing.allocator, &signature, .default));
}

test "ABI layout matches libjxl" {
    // sizeof/offsetof from the libjxl headers on 64-bit targets.
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    try std.testing.expectEqual(204, @sizeOf(BasicInfo));
    try std.testing.expectEqual(104, @sizeOf(ColorEncoding));
    try std.testing.expectEqual(24, @sizeOf(PixelFormat));
    try std.testing.expectEqual(56, @sizeOf(FrameHeader));
    try std.testing.expectEqual(80, @offsetOf(BasicInfo, "animation"));
    try std.testing.expectEqual(48, @offsetOf(BasicInfo, "orientation"));
    try std.testing.expectEqual(96, @offsetOf(ColorEncoding, "rendering_intent"));
}

test "animation ticks convert to milliseconds" {
    try std.testing.expectEqual(100, ticksToMs(10, 100, 1));
    try std.testing.expectEqual(40, ticksToMs(1, 25, 1));
    try std.testing.expectEqual(1001, ticksToMs(30, 30000, 1001));
    try std.testing.expectEqual(0, ticksToMs(5, 0, 1));
    try std.testing.expectEqual(std.math.maxInt(u32), ticksToMs(std.math.maxInt(u32), 1, 1000));
}

test "a still loads as a one-frame animation" {
    if (!enabled or !Libjxl.available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var img = try testImage(Rgb, allocator);
    defer img.deinit(allocator);
    const bytes = try encode(Rgb, io, allocator, img, .lossless);
    defer allocator.free(bytes);
    var anim = try loadAnimatedFromBytes(Rgb, io, allocator, bytes, .default);
    defer anim.deinit(allocator);
    try std.testing.expectEqual(1, anim.frameCount());
    try std.testing.expectEqual(0, anim.durations_ms[0]);
    try std.testing.expectEqualSlices(u8, img.asBytes(), anim.frame(0).asBytes());
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

test "lossless round trip" {
    if (!enabled or !Libjxl.available()) return error.SkipZigTest;
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
    if (!enabled or !Libjxl.available()) return error.SkipZigTest;
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

fn testAnimation(comptime T: type, allocator: Allocator, durations: []const u32, loop_count: u32) !AnimatedImage(T) {
    var builder: animated.Builder(T) = .{};
    defer builder.deinit(allocator);
    for (durations, 0..) |ms, i| {
        var img = try testImage(T, allocator);
        errdefer img.deinit(allocator);
        // Distinct frames so a dropped or repeated frame shows up.
        for (img.data) |*p| p.* = switch (T) {
            u8 => p.* +% @as(u8, @truncate(i * 40)),
            else => blk: {
                var q = p.*;
                q.r +%= @truncate(i * 40);
                break :blk q;
            },
        };
        try builder.append(allocator, img, ms);
    }
    return builder.finish(allocator, loop_count);
}

test "animated lossless round trip" {
    if (!enabled or !Libjxl.available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    inline for (.{ u8, Rgb, Rgba }) |T| {
        var anim = try testAnimation(T, allocator, &.{ 40, 100, 0 }, 3);
        defer anim.deinit(allocator);
        const bytes = try encodeAnimated(T, io, allocator, anim, .lossless);
        defer allocator.free(bytes);

        var reader: Io.Reader = .fixed(bytes);
        try std.testing.expect((try getInfo(&reader, .default)).has_animation);

        var back = try loadAnimatedFromBytes(T, io, allocator, bytes, .default);
        defer back.deinit(allocator);
        try std.testing.expectEqual(3, back.frameCount());
        try std.testing.expectEqual(3, back.loop_count);
        try std.testing.expectEqualSlices(u32, anim.durations_ms, back.durations_ms);
        for (anim.frames, back.frames) |a, b| try std.testing.expectEqualSlices(u8, a.asBytes(), b.asBytes());
    }
}

test "a one-frame animation encodes as a still" {
    if (!enabled or !Libjxl.available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var anim = try testAnimation(Rgb, allocator, &.{50}, 0);
    defer anim.deinit(allocator);
    const animated_bytes = try encodeAnimated(Rgb, io, allocator, anim, .lossless);
    defer allocator.free(animated_bytes);
    const still_bytes = try encode(Rgb, io, allocator, anim.frames[0], .lossless);
    defer allocator.free(still_bytes);
    try std.testing.expectEqualSlices(u8, still_bytes, animated_bytes);
}

test "animated encode rejects bad input" {
    if (!enabled) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const empty: AnimatedImage(Rgb) = .{ .frames = &.{}, .durations_ms = &.{}, .loop_count = 0 };
    try std.testing.expectError(error.NoFrames, encodeAnimated(Rgb, io, allocator, empty, .default));

    var a: Image(Rgb) = try .init(allocator, 4, 4);
    defer a.deinit(allocator);
    var b: Image(Rgb) = try .init(allocator, 4, 5);
    defer b.deinit(allocator);
    var frames = [_]Image(Rgb){ a, b };
    var durations = [_]u32{ 10, 10 };
    const mismatched: AnimatedImage(Rgb) = .{ .frames = &frames, .durations_ms = &durations, .loop_count = 0 };
    try std.testing.expectError(error.InconsistentFrameDimensions, encodeAnimated(Rgb, io, allocator, mismatched, .default));
}

test "changed-region frames decode to the full frames" {
    if (!enabled or !Libjxl.available()) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    // A moving square, a repeated frame, then a change everywhere.
    var anim = try testAnimation(Rgba, allocator, &.{ 30, 30, 30, 30, 30 }, 0);
    defer anim.deinit(allocator);
    for (anim.frames[1..], 1..) |frame, i| {
        frame.copy(anim.frames[0]);
        if (i < 3) for (10..20) |r| for (5 + i * 4..15 + i * 4) |c| {
            frame.at(r, c).* = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
        };
    }
    anim.frames[3].copy(anim.frames[2]);
    for (anim.frames[4].data) |*p| p.g +%= 1;

    const bytes = try encodeAnimated(Rgba, io, allocator, anim, .lossless);
    defer allocator.free(bytes);
    var back = try loadAnimatedFromBytes(Rgba, io, allocator, bytes, .default);
    defer back.deinit(allocator);
    try std.testing.expectEqual(anim.frameCount(), back.frameCount());
    for (anim.frames, back.frames) |a, b| try std.testing.expectEqualSlices(u8, a.asBytes(), b.asBytes());
}
