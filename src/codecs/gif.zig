//! Pure Zig GIF codec.
//!
//! Public surface mirrors the other codecs in this repo (`png`, `jpeg`, `bmp`):
//! `signature`, `DecodeLimits`, `Header`, `GifState` (+ `deinit`), `NativeImage`,
//! `getInfo`, `decode`, `toNativeImage`, `loadFromBytes`, `load`, `EncodeOptions`,
//! `encode`, `save`. Multi-frame access is via `loadAnimated` / `loadAnimatedFromBytes`,
//! which return an `AnimatedImage(T)` of fully-composed frames (disposal, transparency,
//! and interlace are absorbed inside the codec).
//!
//! `encodeAnimated` writes multi-frame GIFs.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const parallel = @import("../parallel.zig");
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectEqual = std.testing.expectEqual;

const codecs = @import("../codecs.zig");
const Image = @import("../image.zig").Image;
const animated = @import("../image/animated.zig");
const AnimatedImage = animated.AnimatedImage;
const convertColor = @import("../color.zig").convertColor;
const Rgb = @import("../color.zig").Rgb(u8);
const Rgba = @import("../color.zig").Rgba(u8);
const Rectangle = @import("../geometry.zig").Rectangle;

const lzw = @import("gif/lzw.zig");

test {
    _ = lzw;
}

/// 3-byte GIF magic. Followed on disk by a 3-byte version (`87a` or `89a`)
/// validated separately by `getInfo`/`decode`.
pub const signature = [_]u8{ 'G', 'I', 'F' };

/// GIF version (87a or 89a).
pub const Version = enum { gif87a, gif89a };

const max_dimensions_default: u32 = 8192;
const max_pixels_default: u64 = 67_108_864; // per frame
const max_frames_default: u32 = 4096;
const max_total_pixels_default: u64 = 1_073_741_824; // sum across frames (LZW bomb guard)

/// Resource limits applied while decoding GIF data; `.unlimited` disables one.
pub const DecodeLimits = struct {
    max_width: Io.Limit = .limited(max_dimensions_default),
    max_height: Io.Limit = .limited(max_dimensions_default),
    /// Per-frame pixel count cap.
    max_pixels: Io.Limit = .limited(max_pixels_default),
    max_frames: Io.Limit = .limited(max_frames_default),
    /// Total composed pixels across all frames (decoder-bomb guard).
    max_total_pixels: Io.Limit = .limited(max_total_pixels_default),

    pub const default: DecodeLimits = .{};
};

/// GIF metadata returned by `getInfo`. `frame_count` and `loop_count` are
/// populated by walking the entire block stream.
pub const Header = struct {
    version: Version,
    width: u32,
    height: u32,
    has_global_color_table: bool,
    /// Number of entries in the global color table (0 when absent). Always a
    /// power of two when present (2..256).
    global_color_table_size: u16,
    background_color_index: u8,
    /// Total Image Descriptor blocks encountered.
    frame_count: u32,
    /// NETSCAPE2.0 loop count. 0 = infinite (also default when absent).
    loop_count: u16,

    pub inline fn totalPixels(self: Header) u64 {
        return @as(u64, self.width) * @as(u64, self.height);
    }
};

const exceeds = codecs.exceeds;

// ---------------------------------------------------------------------------
// Block introducer constants
// ---------------------------------------------------------------------------

const block_image_descriptor: u8 = 0x2C;
const block_extension_introducer: u8 = 0x21;
const block_trailer: u8 = 0x3B;

const ext_label_graphic_control: u8 = 0xF9;
const ext_label_comment: u8 = 0xFE;
const ext_label_plain_text: u8 = 0x01;
const ext_label_application: u8 = 0xFF;

// LSD packed-byte bit masks.
const lsd_flag_global_color_table: u8 = 0x80;
const lsd_color_resolution_default: u8 = 0x70; // 8 bits per channel
const lsd_size_log_mask: u8 = 0x07;

// Image Descriptor packed-byte bit masks.
const id_flag_local_color_table: u8 = 0x80;
const id_flag_interlace: u8 = 0x40;
const id_size_log_mask: u8 = 0x07;

// Graphic Control Extension packed-byte fields.
const gce_disposal_mask: u8 = 0x07;
const gce_flag_transparent: u8 = 0x01;

const netscape_id_auth = "NETSCAPE2.0".*;

// ---------------------------------------------------------------------------
// getInfo
// ---------------------------------------------------------------------------

/// Reads GIF metadata without decoding pixel data. Walks the entire block
/// stream to populate `frame_count` and `loop_count`.
pub fn getInfo(reader: *Io.Reader, limits: DecodeLimits) !Header {
    // Signature + version: 6 bytes total ("GIF87a" or "GIF89a").
    const sig = try reader.takeArray(6);
    if (!std.mem.eql(u8, sig[0..3], &signature)) return error.InvalidGifSignature;

    const version: Version = if (std.mem.eql(u8, sig[3..6], "87a"))
        .gif87a
    else if (std.mem.eql(u8, sig[3..6], "89a"))
        .gif89a
    else
        return error.UnsupportedGifVersion;

    // Logical Screen Descriptor (7 bytes).
    const screen_w = try reader.takeInt(u16, .little);
    const screen_h = try reader.takeInt(u16, .little);
    const lsd_packed = try reader.takeByte();
    const bg_index = try reader.takeByte();
    _ = try reader.takeByte(); // pixel aspect ratio (unused)

    if (screen_w == 0 or screen_h == 0) return error.InvalidLogicalScreenDescriptor;
    if (exceeds(limits.max_width, screen_w) or exceeds(limits.max_height, screen_h)) {
        return error.ImageTooLarge;
    }
    if (exceeds(limits.max_pixels, @as(u64, screen_w) * @as(u64, screen_h))) {
        return error.ImageTooLarge;
    }

    const has_gct = (lsd_packed & lsd_flag_global_color_table) != 0;
    const gct_size_log: u3 = @intCast(lsd_packed & lsd_size_log_mask);
    const gct_size: u16 = if (has_gct) (@as(u16, 2) << gct_size_log) else 0;

    if (has_gct) {
        const gct_bytes: u32 = @as(u32, gct_size) * 3;
        _ = try reader.discard(.limited(gct_bytes));
    }

    var frame_count: u32 = 0;
    var loop_count: u16 = 0;

    while (true) {
        const introducer = try reader.takeByte();
        switch (introducer) {
            block_trailer => break,
            block_image_descriptor => {
                _ = try reader.discard(.limited(8)); // left, top, width, height
                const img_packed = try reader.takeByte();
                const has_lct = (img_packed & id_flag_local_color_table) != 0;
                if (has_lct) {
                    const lct_size_log: u3 = @intCast(img_packed & id_size_log_mask);
                    const lct_entries: u32 = @as(u32, 2) << lct_size_log;
                    _ = try reader.discard(.limited(lct_entries * 3));
                }
                _ = try reader.takeByte(); // LZW minimum code size
                try skipSubBlocks(reader);

                frame_count += 1;
                if (exceeds(limits.max_frames, frame_count)) return error.TooManyFrames;
            },
            block_extension_introducer => {
                const label = try reader.takeByte();
                switch (label) {
                    ext_label_application => try parseAppExtension(reader, &loop_count),
                    // Comment: data is just sub-blocks (no fixed header).
                    ext_label_comment => try skipSubBlocks(reader),
                    // GCE / Plain Text / unknown: first sub-block IS the fixed header,
                    // so `skipSubBlocks` walks both header and payload uniformly.
                    else => try skipSubBlocks(reader),
                }
            },
            else => return error.InvalidExtensionLabel,
        }
    }

    return .{
        .version = version,
        .width = screen_w,
        .height = screen_h,
        .has_global_color_table = has_gct,
        .global_color_table_size = gct_size,
        .background_color_index = bg_index,
        .frame_count = frame_count,
        .loop_count = loop_count,
    };
}

/// Walks an arbitrary chain of GIF data sub-blocks (each = `[size: u8][size bytes]`),
/// terminating on a 0-length sub-block.
fn skipSubBlocks(reader: *Io.Reader) !void {
    while (true) {
        const sb_size = try reader.takeByte();
        if (sb_size == 0) return;
        _ = try reader.discard(.limited(sb_size));
    }
}

/// Parses an Application Extension. If the identifier is "NETSCAPE2.0" and the
/// loop sub-block is present, writes the loop count into `loop_count_out`.
/// Other application extensions are skipped silently.
fn parseAppExtension(reader: *Io.Reader, loop_count_out: *u16) !void {
    const block_size = try reader.takeByte();
    if (block_size != 11) {
        // Non-canonical — discard the declared block then any sub-blocks.
        _ = try reader.discard(.limited(block_size));
        try skipSubBlocks(reader);
        return;
    }

    const id_auth = try reader.takeArray(11);
    if (!std.mem.eql(u8, id_auth, &netscape_id_auth)) {
        try skipSubBlocks(reader);
        return;
    }

    // NETSCAPE2.0 sub-blocks. The canonical form is:
    //   0x03 0x01 LL LL 0x00
    // but be permissive.
    while (true) {
        const sb_size = try reader.takeByte();
        if (sb_size == 0) return;
        if (sb_size >= 3) {
            const sub_id = try reader.takeByte();
            if (sub_id == 0x01) {
                loop_count_out.* = try reader.takeInt(u16, .little);
                if (sb_size > 3) _ = try reader.discard(.limited(sb_size - 3));
            } else {
                _ = try reader.discard(.limited(sb_size - 1));
            }
        } else {
            _ = try reader.discard(.limited(sb_size));
        }
    }
}

// ---------------------------------------------------------------------------
// Decode types
// ---------------------------------------------------------------------------

/// GIF disposal method controlling what happens to the canvas after a frame
/// is displayed.
pub const DisposalMethod = enum(u3) {
    unspecified = 0,
    do_not_dispose = 1,
    restore_to_background = 2,
    restore_to_previous = 3,
    _,
};

/// Per-frame metadata extracted from a Graphic Control Extension. Only
/// populated when a GCE preceded the image descriptor.
pub const GraphicControlExtension = struct {
    disposal: DisposalMethod,
    has_transparent: bool,
    delay_cs: u16,
    transparent_index: u8,
};

/// Single decoded frame: position + dimensions + per-pixel palette indices
/// in display order (de-interlaced if the source was interlaced). Each frame
/// owns its palette (a copy of the LCT, or of the global table).
pub const FrameRecord = struct {
    left: u16,
    top: u16,
    width: u16,
    height: u16,
    /// Palette in effect for this frame. Owned.
    palette: []Rgb,
    /// `width * height` palette indices in display order. Owned.
    indices: []u8,
    /// Per-frame timing/transparency from the preceding GCE, if any.
    gce: ?GraphicControlExtension,
};

/// Parsed GIF state. Frames hold raw decoded indices —
/// `loadAnimated`/`loadAnimatedFromBytes` compose them into fully-rendered images.
pub const GifState = struct {
    header: Header,
    /// Owned. Null if the file had no Global Color Table.
    global_palette: ?[]Rgb,
    /// Owned. May be empty for a malformed-but-tolerated file with no images.
    frames: []FrameRecord,

    pub fn deinit(self: *GifState, gpa: Allocator) void {
        if (self.global_palette) |p| gpa.free(p);
        for (self.frames) |*f| {
            gpa.free(f.palette);
            gpa.free(f.indices);
        }
        gpa.free(self.frames);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// decode
// ---------------------------------------------------------------------------

/// Parses a GIF byte buffer into a `GifState`. The state's frames hold raw
/// palette indices; composition into Images happens via `loadFromBytes`
/// (single-frame) or `loadAnimated*` (multi-frame).
pub fn decode(gpa: Allocator, data: []const u8, limits: DecodeLimits) !GifState {
    var reader: Io.Reader = .fixed(data);
    return parse(gpa, &reader, limits);
}

/// `decode` from a stream. The reader's buffer must hold a whole color table (768 bytes).
fn parse(gpa: Allocator, reader: *Io.Reader, limits: DecodeLimits) !GifState {
    const sig = try reader.takeArray(6);
    if (!std.mem.eql(u8, sig[0..3], &signature)) return error.InvalidGifSignature;
    const version: Version = if (std.mem.eql(u8, sig[3..6], "87a"))
        .gif87a
    else if (std.mem.eql(u8, sig[3..6], "89a"))
        .gif89a
    else
        return error.UnsupportedGifVersion;

    const screen_w = try reader.takeInt(u16, .little);
    const screen_h = try reader.takeInt(u16, .little);
    const lsd_packed = try reader.takeByte();
    const bg_index = try reader.takeByte();
    _ = try reader.takeByte(); // pixel aspect ratio

    if (screen_w == 0 or screen_h == 0) return error.InvalidLogicalScreenDescriptor;
    if (exceeds(limits.max_width, screen_w) or exceeds(limits.max_height, screen_h)) {
        return error.ImageTooLarge;
    }
    if (exceeds(limits.max_pixels, @as(u64, screen_w) * @as(u64, screen_h))) {
        return error.ImageTooLarge;
    }

    const has_gct = (lsd_packed & lsd_flag_global_color_table) != 0;
    const gct_size_log: u3 = @intCast(lsd_packed & lsd_size_log_mask);
    const gct_size: u16 = if (has_gct) (@as(u16, 2) << gct_size_log) else 0;

    var global_palette: ?[]Rgb = null;
    errdefer if (global_palette) |p| gpa.free(p);
    if (has_gct) {
        const palette = try gpa.alloc(Rgb, gct_size);
        const raw = try reader.take(@as(usize, gct_size) * 3);
        var i: usize = 0;
        while (i < gct_size) : (i += 1) {
            palette[i] = .{ .r = raw[i * 3], .g = raw[i * 3 + 1], .b = raw[i * 3 + 2] };
        }
        global_palette = palette;
    }

    var frames: std.ArrayList(FrameRecord) = .empty;
    errdefer {
        for (frames.items) |*f| {
            gpa.free(f.palette);
            gpa.free(f.indices);
        }
        frames.deinit(gpa);
    }

    var pending_gce: ?GraphicControlExtension = null;
    var loop_count: u16 = 0;
    var total_pixels: u64 = 0;

    block_loop: while (true) {
        const introducer = try reader.takeByte();
        switch (introducer) {
            block_trailer => break :block_loop,
            block_image_descriptor => {
                const frame = try parseImageBlock(gpa, reader, limits, global_palette, pending_gce, &total_pixels);
                pending_gce = null;
                try frames.append(gpa, frame);
                if (exceeds(limits.max_frames, @intCast(frames.items.len))) {
                    return error.TooManyFrames;
                }
            },
            block_extension_introducer => {
                const label = try reader.takeByte();
                switch (label) {
                    ext_label_graphic_control => pending_gce = try parseGce(reader),
                    ext_label_application => try parseAppExtension(reader, &loop_count),
                    else => try skipSubBlocks(reader),
                }
            },
            else => return error.InvalidExtensionLabel,
        }
    }

    return .{
        .header = .{
            .version = version,
            .width = screen_w,
            .height = screen_h,
            .has_global_color_table = has_gct,
            .global_color_table_size = gct_size,
            .background_color_index = bg_index,
            .frame_count = @intCast(frames.items.len),
            .loop_count = loop_count,
        },
        .global_palette = global_palette,
        .frames = try frames.toOwnedSlice(gpa),
    };
}

fn parseGce(reader: *Io.Reader) !GraphicControlExtension {
    const block_size = try reader.takeByte();
    if (block_size != 4) return error.InvalidGraphicControlExtension;
    const packed_byte = try reader.takeByte();
    const delay = try reader.takeInt(u16, .little);
    const transparent = try reader.takeByte();
    const terminator = try reader.takeByte();
    if (terminator != 0) return error.InvalidGraphicControlExtension;
    return .{
        .disposal = @fromBackingInt(@intCast((packed_byte >> 2) & gce_disposal_mask)),
        .has_transparent = (packed_byte & gce_flag_transparent) != 0,
        .delay_cs = delay,
        .transparent_index = transparent,
    };
}

fn parseImageBlock(
    gpa: Allocator,
    reader: *Io.Reader,
    limits: DecodeLimits,
    global_palette: ?[]Rgb,
    pending_gce: ?GraphicControlExtension,
    total_pixels: *u64,
) !FrameRecord {
    const left = try reader.takeInt(u16, .little);
    const top = try reader.takeInt(u16, .little);
    const width = try reader.takeInt(u16, .little);
    const height = try reader.takeInt(u16, .little);
    const img_packed = try reader.takeByte();

    if (width == 0 or height == 0) return error.InvalidImageDescriptor;
    if (exceeds(limits.max_width, width) or exceeds(limits.max_height, height)) {
        return error.ImageTooLarge;
    }
    const num_pixels: u64 = @as(u64, width) * @as(u64, height);
    if (exceeds(limits.max_pixels, num_pixels)) return error.ImageTooLarge;
    total_pixels.* +|= num_pixels;
    if (exceeds(limits.max_total_pixels, total_pixels.*)) return error.ImageTooLarge;

    const has_lct = (img_packed & id_flag_local_color_table) != 0;
    const interlaced = (img_packed & id_flag_interlace) != 0;

    const palette: []Rgb = blk: {
        if (has_lct) {
            const lct_size_log: u3 = @intCast(img_packed & id_size_log_mask);
            const lct_entries: u16 = @as(u16, 2) << lct_size_log;
            const lct = try gpa.alloc(Rgb, lct_entries);
            errdefer gpa.free(lct);
            const raw = try reader.take(@as(usize, lct_entries) * 3);
            var i: usize = 0;
            while (i < lct_entries) : (i += 1) {
                lct[i] = .{ .r = raw[i * 3], .g = raw[i * 3 + 1], .b = raw[i * 3 + 2] };
            }
            break :blk lct;
        }
        const gp = global_palette orelse return error.MissingGlobalColorTable;
        const copy = try gpa.alloc(Rgb, gp.len);
        @memcpy(copy, gp);
        break :blk copy;
    };
    errdefer gpa.free(palette);

    const min_code_size_byte = try reader.takeByte();
    if (min_code_size_byte < 2 or min_code_size_byte > 8) return error.InvalidLzwCode;
    const min_code_size: u4 = @intCast(min_code_size_byte);

    // LZW pixels go into a pass-ordered buffer first, then de-interlace into
    // display order in a fresh buffer if the descriptor's interlace bit is set.
    const num_pixels_usize: usize = @intCast(num_pixels);
    var pass_indices = try gpa.alloc(u8, num_pixels_usize);
    errdefer gpa.free(pass_indices);

    var dec = lzw.Decoder.init(min_code_size) catch return error.InvalidLzwCode;
    var written: usize = 0;

    while (true) {
        const sb_size = try reader.takeByte();
        if (sb_size == 0) break;
        const sb_data = try reader.take(sb_size);

        const r = try dec.decodeChunk(sb_data, pass_indices[written..]);
        written += r.written;

        if (dec.isDone()) {
            try skipSubBlocks(reader);
            break;
        }
    }

    if (!dec.isDone()) return error.InvalidLzwCode;
    // `written > num_pixels_usize` cannot happen here — the decoder errors out
    // with `LzwOutputOverflow` mid-stream when the output buffer would overflow.
    // So `written != num_pixels_usize` is exclusively the EOI-too-early case.
    if (written != num_pixels_usize) return error.LzwOutputUnderflow;

    // De-interlace if necessary.
    const indices_out = if (interlaced) blk: {
        const display = try gpa.alloc(u8, num_pixels_usize);
        errdefer gpa.free(display);
        lzw.deinterlace(pass_indices, display, width, height);
        gpa.free(pass_indices);
        break :blk display;
    } else pass_indices;

    return .{
        .left = left,
        .top = top,
        .width = width,
        .height = height,
        .palette = palette,
        .indices = indices_out,
        .gce = pending_gce,
    };
}

// ---------------------------------------------------------------------------
// Single-frame composition
// ---------------------------------------------------------------------------

/// Composes frame 0 onto a screen-sized canvas, returning an `Image(T)`.
/// For `T == Rgba` transparent indices preserve `alpha=0`; for any other `T`
/// the canvas starts at `palette[bg]` so transparent pixels show the GIF's
/// declared background color.
fn composeFirstFrame(comptime T: type, io: Io, allocator: Allocator, state: GifState) !Image(T) {
    if (state.frames.len == 0) return error.MissingPixelData;
    const frame = state.frames[0];

    const bg: Rgba = if (T == Rgba) .{ .r = 0, .g = 0, .b = 0, .a = 0 } else blk: {
        if (state.global_palette) |gp| {
            if (state.header.background_color_index < gp.len) {
                const c = gp[state.header.background_color_index];
                break :blk .{ .r = c.r, .g = c.g, .b = c.b, .a = 255 };
            }
        }
        break :blk .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    };

    var canvas = try Image(Rgba).init(allocator, state.header.height, state.header.width);
    errdefer canvas.deinit(allocator);
    @memset(canvas.data, bg);

    try compositeFrameOntoCanvas(&canvas, frame);

    if (T == Rgba) return canvas;
    defer canvas.deinit(allocator);
    return canvas.convert(io, allocator, T);
}

/// First-frame composition pre-converted to `Rgb`/`Rgba`. The Rgba variant is
/// chosen when frame 0 has a transparent index (matches Python's expectation
/// of `Image.dtype` reflecting the file's true color space).
pub const NativeImage = union(enum) {
    rgb: Image(Rgb),
    rgba: Image(Rgba),
};

/// Composes the first frame and returns it as `NativeImage`. Used by language
/// bindings that pick the pixel type based on file metadata.
pub fn toNativeImage(io: Io, allocator: Allocator, state: GifState) !NativeImage {
    if (state.frames.len == 0) return error.MissingPixelData;
    const has_transparency = if (state.frames[0].gce) |g| g.has_transparent else false;
    if (has_transparency) {
        return .{ .rgba = try composeFirstFrame(Rgba, io, allocator, state) };
    }
    return .{ .rgb = try composeFirstFrame(Rgb, io, allocator, state) };
}

/// Loads a GIF from in-memory bytes. Returns frame 0 only — see
/// `loadAnimatedFromBytes` for full multi-frame access.
pub fn loadFromBytes(comptime T: type, io: Io, allocator: Allocator, data: []const u8, limits: DecodeLimits) !Image(T) {
    var reader: Io.Reader = .fixed(data);
    return read(T, io, allocator, &reader, limits);
}

// ---------------------------------------------------------------------------
// Multi-frame composition
// ---------------------------------------------------------------------------

/// Composes all frames into an `AnimatedImage(T)`. Each output frame is the
/// fully-rendered canvas at that point in playback, so callers don't have to
/// know about disposal methods or transparent indices.
fn composeAnimated(comptime T: type, io: Io, allocator: Allocator, state: GifState) !AnimatedImage(T) {
    const screen_w: u32 = state.header.width;
    const screen_h: u32 = state.header.height;

    var canvas = try Image(Rgba).init(allocator, screen_h, screen_w);
    defer canvas.deinit(allocator);
    @memset(canvas.data, .{ .r = 0, .g = 0, .b = 0, .a = 0 });

    // `restore_to_previous` snapshot — only allocated if some frame needs it.
    const needs_snapshot = blk: {
        for (state.frames) |f| {
            if (f.gce) |g| if (g.disposal == .restore_to_previous) break :blk true;
        }
        break :blk false;
    };
    const snapshot: ?[]Rgba = if (needs_snapshot)
        try allocator.alloc(Rgba, @as(usize, screen_w) * @as(usize, screen_h))
    else
        null;
    defer if (snapshot) |s| allocator.free(s);

    var builder: animated.Builder(T) = .{};
    defer builder.deinit(allocator);

    var prev_disposal: DisposalMethod = .unspecified;
    var prev_rect: Rectangle(u32) = .init(0, 0, 0, 0);

    for (state.frames) |frame| {
        switch (prev_disposal) {
            .restore_to_background => canvas.view(prev_rect).fill(.{ .r = 0, .g = 0, .b = 0, .a = 0 }),
            .restore_to_previous => if (snapshot) |s| @memcpy(canvas.data, s),
            else => {},
        }

        if (frame.gce) |g| {
            if (g.disposal == .restore_to_previous) {
                @memcpy(snapshot.?, canvas.data);
            }
        }

        try compositeFrameOntoCanvas(&canvas, frame);

        const duration_ms: u32 = if (frame.gce) |g| @as(u32, g.delay_cs) * 10 else 0;
        try builder.append(allocator, if (T == Rgba) try canvas.dupe(allocator) else try canvas.convert(io, allocator, T), duration_ms);
        prev_disposal = if (frame.gce) |g| g.disposal else .unspecified;
        prev_rect = .init(frame.left, frame.top, frame.left +| frame.width, frame.top +| frame.height);
    }

    return builder.finish(allocator, state.header.loop_count);
}

fn compositeFrameOntoCanvas(canvas: *Image(Rgba), frame: FrameRecord) !void {
    const has_trans = if (frame.gce) |g| g.has_transparent else false;
    const trans_idx = if (frame.gce) |g| g.transparent_index else 0;
    const palette = frame.palette;

    const left: usize = @intCast(frame.left);
    const top: usize = @intCast(frame.top);
    if (left >= canvas.cols or top >= canvas.rows) return;

    // Clip the frame rect to the canvas once instead of per-pixel.
    const fw: usize = @intCast(frame.width);
    const fh: usize = @intCast(frame.height);
    const clip_w = @min(fw, canvas.cols - left);
    const clip_h = @min(fh, canvas.rows - top);

    var fy: usize = 0;
    while (fy < clip_h) : (fy += 1) {
        const dst_off = (top + fy) * canvas.stride + left;
        const src_off = fy * fw;
        var fx: usize = 0;
        while (fx < clip_w) : (fx += 1) {
            const idx = frame.indices[src_off + fx];
            if (has_trans and idx == trans_idx) continue;
            if (idx >= palette.len) return error.InvalidPaletteIndex;
            const c = palette[idx];
            canvas.data[dst_off + fx] = .{ .r = c.r, .g = c.g, .b = c.b, .a = 255 };
        }
    }
}

/// Loads all frames from a GIF byte buffer into an `AnimatedImage(T)`.
/// Disposal and transparency are absorbed by the decoder — every output frame
/// is fully composed.
pub fn loadAnimatedFromBytes(comptime T: type, io: Io, allocator: Allocator, data: []const u8, limits: DecodeLimits) !AnimatedImage(T) {
    var reader: Io.Reader = .fixed(data);
    return readAnimated(T, io, allocator, &reader, limits);
}

/// Reads a GIF from `reader`, returning frame 0 only; see `readAnimated`.
pub fn read(comptime T: type, io: Io, allocator: Allocator, reader: *Io.Reader, limits: DecodeLimits) !Image(T) {
    var state = try parse(allocator, reader, limits);
    defer state.deinit(allocator);
    return composeFirstFrame(T, io, allocator, state);
}

/// Reads every frame of a GIF from `reader`, fully composed.
pub fn readAnimated(comptime T: type, io: Io, allocator: Allocator, reader: *Io.Reader, limits: DecodeLimits) !AnimatedImage(T) {
    var state = try parse(allocator, reader, limits);
    defer state.deinit(allocator);
    return composeAnimated(T, io, allocator, state);
}

// ---------------------------------------------------------------------------
// Single-frame encode
// ---------------------------------------------------------------------------

const quantize = @import("../image/quantize.zig");
const dither = @import("../image/dither.zig");

/// GIF encode options used by both `encode` (single-frame) and `encodeAnimated`.
/// For animated encode, `palette` becomes the Global Color Table when set,
/// otherwise each frame gets its own LCT via per-frame median-cut.
pub const EncodeOptions = struct {
    /// Pre-computed palette. If null, the encoder runs median-cut on the input.
    /// Length must be 2..256.
    palette: ?[]const Rgb = null,
    /// Cap on auto-quantization. Ignored when `palette` is provided.
    max_colors: u16 = 256,
    /// Apply Floyd–Steinberg dithering before mapping to palette.
    dither: bool = false,

    pub const default: EncodeOptions = .{};
};

/// Smallest `s` such that `(2 << s) >= palette_len`, capped at 7. The packed
/// byte field on LSD / Image Descriptor encodes color-table size as `s`; the
/// table itself must be padded to `2 << s` entries.
fn declaredSizeLog(palette_len: usize) u3 {
    var s: u3 = 0;
    while ((@as(u16, 2) << s) < palette_len and s < 7) : (s += 1) {}
    return s;
}

/// Emits a color table to `out`, padded with `(0,0,0)` to `declared_entries`.
fn writeColorTable(writer: *Io.Writer, palette: []const Rgb, declared_entries: u16) !void {
    for (palette) |c| try writer.writeAll(&.{ c.r, c.g, c.b });
    try writer.splatByteAll(0, 3 * (declared_entries - palette.len));
}

/// Emits the LZW data section of an Image block: `min_code_size` byte +
/// LZW-compressed indices wrapped in 0xFF-max sub-blocks + terminator.
fn writeLzwImageData(encoder: *lzw.Encoder, writer: *Io.Writer, indices: []const u8, min_code_size: u4) !void {
    try writer.writeByte(min_code_size);
    try encoder.reset(min_code_size);
    try encoder.encodeAll(writer, indices);
    try writer.writeByte(0);
}

/// Encodes a single-frame GIF from `image`. Caller frees the returned slice.
pub fn encode(comptime T: type, io: Io, allocator: Allocator, image: Image(T), options: EncodeOptions) ![]u8 {
    return codecs.encodeWith(allocator, write, .{ T, io, allocator }, .{ image, options });
}

/// Writes `image` as a single-frame GIF to `writer`.
pub fn write(comptime T: type, io: Io, allocator: Allocator, writer: *Io.Writer, image: Image(T), options: EncodeOptions) !void {
    if (image.cols == 0 or image.rows == 0) return error.InvalidDimensions;
    if (image.cols > 65535 or image.rows > 65535) return error.ImageTooLarge;

    const width: u16 = @intCast(image.cols);
    const height: u16 = @intCast(image.rows);
    const num_pixels: usize = @as(usize, width) * @as(usize, height);

    // 1) Resolve palette and produce per-pixel indices. Like the animated encoder, an
    // Rgba image with transparent pixels reserves the last palette slot for them.
    var palette_buf: [256]Rgb = undefined;
    var palette: []const Rgb = palette_buf[0..0];

    const indices = try allocator.alloc(u8, num_pixels);
    defer allocator.free(indices);
    const has_transparent = T == Rgba and blk: {
        for (0..image.rows) |r| {
            for (0..image.cols) |c| if (image.at(r, c).a < 128) break :blk true;
        }
        break :blk false;
    };
    var transparent_index: u8 = 0;

    if (options.palette) |custom| {
        if (custom.len < 2 or custom.len > 256) return error.PaletteTooSmall;
        if (has_transparent) {
            if (custom.len >= 256) return error.PaletteTooLarge;
            @memcpy(palette_buf[0..custom.len], custom);
            palette_buf[custom.len] = .{ .r = 0, .g = 0, .b = 0 };
            palette = palette_buf[0 .. custom.len + 1];
            transparent_index = @intCast(custom.len);
        } else {
            palette = custom;
        }
        try mapImageToPalette(T, io, allocator, image, palette, indices, options.dither, if (has_transparent) transparent_index else null);
    } else if (T == u8) {
        // u8 → 256-entry linear gray palette; indices are the pixel values.
        @memcpy(&palette_buf, &quantize.linear_gray_256);
        palette = palette_buf[0..256];
        if (image.isContiguous()) {
            @memcpy(indices, image.data[0..num_pixels]);
        } else {
            var ri: usize = 0;
            while (ri < image.rows) : (ri += 1) {
                const src_off = ri * image.stride;
                const dst_off = ri * image.cols;
                @memcpy(indices[dst_off .. dst_off + image.cols], image.data[src_off .. src_off + image.cols]);
            }
        }
    } else {
        const reserve: u16 = if (has_transparent) 1 else 0;
        const max_colors = @max(@as(u16, 2), @min(options.max_colors, 256) -| reserve);
        var palette_size = try quantize.medianCut(T, allocator, image, &palette_buf, max_colors);
        if (palette_size < 2) {
            // GIF requires at least 2 entries (min_code_size floor).
            palette_buf[1] = palette_buf[0];
            palette_size = 2;
        }
        if (has_transparent) {
            palette_buf[palette_size] = .{ .r = 0, .g = 0, .b = 0 };
            transparent_index = @intCast(palette_size);
            palette_size += 1;
        }
        palette = palette_buf[0..palette_size];
        try mapImageToPalette(T, io, allocator, image, palette, indices, options.dither, if (has_transparent) transparent_index else null);
    }

    var min_code_size: u4 = 2;
    while ((@as(u16, 1) << min_code_size) < palette.len) min_code_size += 1;
    const size_log = declaredSizeLog(palette.len);
    const declared_entries: u16 = @as(u16, 2) << size_log;

    try writer.writeAll("GIF89a");
    try writer.writeInt(u16, width, .little);
    try writer.writeInt(u16, height, .little);
    const lsd_packed: u8 = lsd_flag_global_color_table | lsd_color_resolution_default | @as(u8, size_log);
    try writer.writeByte(lsd_packed);
    try writer.writeByte(0); // background color index
    try writer.writeByte(0); // pixel aspect ratio

    try writeColorTable(writer, palette, declared_entries);

    if (has_transparent) {
        // Graphic Control Extension naming the transparent index.
        try writer.writeByte(block_extension_introducer);
        try writer.writeByte(ext_label_graphic_control);
        try writer.writeByte(0x04);
        try writer.writeByte(gce_flag_transparent);
        try writer.writeInt(u16, 0, .little);
        try writer.writeByte(transparent_index);
        try writer.writeByte(0);
    }

    try writer.writeByte(block_image_descriptor);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, 0, .little);
    try writer.writeInt(u16, width, .little);
    try writer.writeInt(u16, height, .little);
    try writer.writeByte(0x00); // packed: no LCT, not interlaced

    var encoder = try lzw.Encoder.init(allocator, min_code_size);
    defer encoder.deinit(allocator);
    try writeLzwImageData(&encoder, writer, indices, min_code_size);

    try writer.writeByte(block_trailer);
}

/// Maps each pixel to the nearest palette index, with optional Floyd–Steinberg
/// dithering. When `transparent_index` is non-null and `T == Rgba`, pixels with
/// `alpha < 128` map to `transparent_index` instead of a color match, and the
/// last palette entry is excluded from the LUT (it's the reserved transparent
/// slot, set by the caller). The dither path round-trips through `Image(Rgb)`;
/// the no-dither path converts per-pixel.
fn mapImageToPalette(
    comptime T: type,
    io: Io,
    allocator: Allocator,
    image: Image(T),
    palette: []const Rgb,
    indices: []u8,
    use_dither: bool,
    transparent_index: ?u8,
) !void {
    const lookup_palette = if (transparent_index != null) palette[0 .. palette.len - 1] else palette;
    const lut = quantize.ColorLookupTable.init(lookup_palette);

    if (use_dither) {
        var work = try image.convert(io, allocator, Rgb);
        defer work.deinit(allocator);
        dither.applyFloydSteinberg(work, lookup_palette, lut);
        var i: usize = 0;
        while (i < image.rows) : (i += 1) {
            const dst_off = i * image.cols;
            const src_off = i * work.stride;
            var j: usize = 0;
            while (j < image.cols) : (j += 1) {
                if (T == Rgba and transparent_index != null and image.at(i, j).a < 128) {
                    indices[dst_off + j] = transparent_index.?;
                } else {
                    indices[dst_off + j] = lut.lookup(work.data[src_off + j]);
                }
            }
        }
        return;
    }

    var i: usize = 0;
    while (i < image.rows) : (i += 1) {
        const dst_off = i * image.cols;
        var j: usize = 0;
        while (j < image.cols) : (j += 1) {
            const px = image.at(i, j).*;
            if (T == Rgba and transparent_index != null and px.a < 128) {
                indices[dst_off + j] = transparent_index.?;
            } else {
                indices[dst_off + j] = lut.lookup(convertColor(Rgb, px));
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Animated encode
// ---------------------------------------------------------------------------

/// Encodes an `AnimatedImage(T)` as an animated GIF, storing only each frame's changed region.
/// For `T == Rgba`, pixels with `alpha < 128` map to a reserved transparent palette index.
pub fn encodeAnimated(comptime T: type, io: Io, gpa: Allocator, anim: AnimatedImage(T), options: EncodeOptions) ![]u8 {
    return codecs.encodeWith(gpa, writeAnimated, .{ T, io, gpa }, .{ anim, options });
}

/// Writes `anim` as an animated GIF to `writer`; see `encodeAnimated`.
pub fn writeAnimated(comptime T: type, io: Io, gpa: Allocator, writer: *Io.Writer, anim: AnimatedImage(T), options: EncodeOptions) !void {
    try anim.validate();

    const screen_w_u32 = anim.frames[0].cols;
    const screen_h_u32 = anim.frames[0].rows;
    if (screen_w_u32 == 0 or screen_h_u32 == 0) return error.InvalidDimensions;
    if (screen_w_u32 > 65535 or screen_h_u32 > 65535) return error.ImageTooLarge;
    const screen_w: u16 = @intCast(screen_w_u32);
    const screen_h: u16 = @intCast(screen_h_u32);

    try writer.writeAll("GIF89a");
    try writer.writeInt(u16, screen_w, .little);
    try writer.writeInt(u16, screen_h, .little);

    const has_global_palette = options.palette != null;
    var lsd_packed: u8 = 0;
    if (options.palette) |custom| {
        if (custom.len < 2 or custom.len > 256) return error.PaletteTooSmall;
        const size_log = declaredSizeLog(custom.len);
        lsd_packed = lsd_flag_global_color_table | lsd_color_resolution_default | @as(u8, size_log);
    }
    try writer.writeByte(lsd_packed);
    try writer.writeByte(0); // background color index
    try writer.writeByte(0); // pixel aspect ratio

    if (options.palette) |custom| {
        const declared: u16 = @as(u16, 2) << declaredSizeLog(custom.len);
        try writeColorTable(writer, custom, declared);
    }

    // NETSCAPE2.0 application extension carrying the loop count. Always emit
    // for animations so the loop_count is explicit.
    if (anim.frames.len >= 2) {
        try writer.writeByte(block_extension_introducer);
        try writer.writeByte(ext_label_application);
        try writer.writeByte(0x0B);
        try writer.writeAll("NETSCAPE2.0");
        try writer.writeByte(0x03);
        try writer.writeByte(0x01);
        try writer.writeInt(u16, @min(anim.loop_count, std.math.maxInt(u16)), .little);
        try writer.writeByte(0);
    }

    // Transparent pixels show the canvas below, so uncovering one needs a cleared canvas.
    // One encoder for every frame; `reset` keeps its dictionary's memory.
    var encoder = try lzw.Encoder.init(gpa, 2);
    defer encoder.deinit(gpa);
    var after_clear = false;
    for (anim.frames, anim.durations_ms, 0..) |frame, ms, i| {
        const clears_next = i + 1 < anim.frames.len and uncovers(T, frame, anim.frames[i + 1]);
        const region = if (after_clear or clears_next) frame.getRectangle() else anim.changedRegion(i);
        const disposal: DisposalMethod = if (clears_next) .restore_to_background else .do_not_dispose;
        // GIF delays are centiseconds.
        const delay_cs = @min((ms +| 5) / 10, std.math.maxInt(u16));
        try emitAnimatedFrame(T, io, gpa, &encoder, frame, region, disposal, delay_cs, has_global_palette, options, writer);
        after_clear = clears_next;
    }

    try writer.writeByte(block_trailer);
}

/// Whether `next` makes transparent a pixel that is opaque in `current`.
fn uncovers(comptime T: type, current: Image(T), next: Image(T)) bool {
    if (T != Rgba) return false;
    for (0..current.rows) |r| {
        for (current.data[r * current.stride ..][0..current.cols], next.data[r * next.stride ..][0..next.cols]) |a, b| {
            if (a.a >= 128 and b.a < 128) return true;
        }
    }
    return false;
}

fn emitAnimatedFrame(
    comptime T: type,
    io: Io,
    gpa: Allocator,
    encoder: *lzw.Encoder,
    full_frame: Image(T),
    region: Rectangle(u32),
    disposal: DisposalMethod,
    delay_cs: u16,
    has_global_palette: bool,
    options: EncodeOptions,
    writer: *Io.Writer,
) !void {
    const frame = full_frame.view(region);
    const num_pixels: usize = @as(usize, frame.cols) * @as(usize, frame.rows);

    // Detect alpha=0 pixels for Rgba inputs so we can map them to a reserved
    // transparent palette index (and emit the GCE flag).
    const has_transparent: bool = blk: {
        if (T != Rgba) break :blk false;
        var ri: usize = 0;
        while (ri < frame.rows) : (ri += 1) {
            const off = ri * frame.stride;
            for (frame.data[off .. off + frame.cols]) |p| {
                if (p.a < 128) break :blk true;
            }
        }
        break :blk false;
    };

    // Build the frame's palette. The transparent slot (when needed) goes at
    // the END so the LUT — which `mapImageToPalette` slices off the last
    // entry — never matches a real color to that index.
    var palette_buf: [256]Rgb = undefined;
    var palette: []const Rgb = palette_buf[0..0];
    var transparent_index: u8 = 0;

    if (has_global_palette) {
        const custom = options.palette.?;
        if (has_transparent) {
            if (custom.len >= 256) return error.PaletteTooLarge;
            @memcpy(palette_buf[0..custom.len], custom);
            palette_buf[custom.len] = .{ .r = 0, .g = 0, .b = 0 };
            palette = palette_buf[0 .. custom.len + 1];
            transparent_index = @intCast(custom.len);
        } else {
            palette = custom; // borrow — no copy needed when no slot is reserved
        }
    } else {
        const reserve: u16 = if (has_transparent) 1 else 0;
        const max_colors = @max(@as(u16, 2), @min(options.max_colors, 256) -| reserve);
        var size = try quantize.medianCut(T, gpa, frame, &palette_buf, max_colors);
        if (size < 2) {
            palette_buf[1] = palette_buf[0];
            size = 2;
        }
        if (has_transparent) {
            palette_buf[size] = .{ .r = 0, .g = 0, .b = 0 };
            transparent_index = @intCast(size);
            size += 1;
        }
        palette = palette_buf[0..size];
    }

    const indices = try gpa.alloc(u8, num_pixels);
    defer gpa.free(indices);
    try mapImageToPalette(T, io, gpa, frame, palette, indices, options.dither, if (has_transparent) transparent_index else null);

    var min_code_size: u4 = 2;
    while ((@as(u16, 1) << min_code_size) < palette.len) min_code_size += 1;
    const size_log = declaredSizeLog(palette.len);
    const declared_entries: u16 = @as(u16, 2) << size_log;

    // Graphic Control Extension (always emit so delay_cs is explicit).
    try writer.writeByte(block_extension_introducer);
    try writer.writeByte(ext_label_graphic_control);
    try writer.writeByte(0x04);
    const gce_packed: u8 = (@as(u8, @backingInt(disposal)) << 2) | if (has_transparent) gce_flag_transparent else 0;
    try writer.writeByte(gce_packed);
    try writer.writeInt(u16, delay_cs, .little);
    try writer.writeByte(transparent_index);
    try writer.writeByte(0);

    // Image Descriptor.
    try writer.writeByte(block_image_descriptor);
    try writer.writeInt(u16, @intCast(region.l), .little);
    try writer.writeInt(u16, @intCast(region.t), .little);
    try writer.writeInt(u16, @intCast(frame.cols), .little);
    try writer.writeInt(u16, @intCast(frame.rows), .little);
    var id_packed: u8 = 0;
    if (!has_global_palette) {
        id_packed |= id_flag_local_color_table;
        id_packed |= @as(u8, size_log);
    }
    try writer.writeByte(id_packed);

    if (!has_global_palette) {
        try writeColorTable(writer, palette, declared_entries);
    }

    try writeLzwImageData(encoder, writer, indices, min_code_size);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestBuilder = struct {
    aw: Io.Writer.Allocating,

    fn init(gpa: Allocator) TestBuilder {
        return .{ .aw = .init(gpa) };
    }

    fn deinit(self: *TestBuilder) void {
        self.aw.deinit();
    }

    fn written(self: *TestBuilder) []u8 {
        return self.aw.written();
    }

    fn appendByte(self: *TestBuilder, b: u8) !void {
        try self.aw.writer.writeByte(b);
    }

    fn appendBytes(self: *TestBuilder, bs: []const u8) !void {
        try self.aw.writer.writeAll(bs);
    }

    fn appendU16(self: *TestBuilder, v: u16) !void {
        try self.aw.writer.writeInt(u16, v, .little);
    }

    fn appendHeader(self: *TestBuilder, opts: HeaderOpts) !void {
        try self.appendBytes(opts.signature);
        try self.appendU16(opts.width);
        try self.appendU16(opts.height);
        var packed_byte: u8 = 0;
        if (opts.gct_size_log) |s| {
            packed_byte |= lsd_flag_global_color_table;
            packed_byte |= lsd_color_resolution_default;
            packed_byte |= s;
        }
        try self.appendByte(packed_byte);
        try self.appendByte(opts.bg_index);
        try self.appendByte(0); // pixel aspect ratio
        if (opts.gct_size_log) |s| {
            const entries: u32 = @as(u32, 2) << @intCast(s);
            // Fill with zeros — content doesn't affect getInfo.
            try self.aw.writer.splatByteAll(0, @as(usize, entries) * 3);
        }
    }

    fn appendImageDescriptor(self: *TestBuilder, opts: ImageDescOpts) !void {
        try self.appendByte(block_image_descriptor);
        try self.appendU16(opts.left);
        try self.appendU16(opts.top);
        try self.appendU16(opts.width);
        try self.appendU16(opts.height);
        try self.appendByte(opts.packed_byte);
        if (opts.lct_size_log) |s| {
            const entries: u32 = @as(u32, 2) << @intCast(s);
            try self.aw.writer.splatByteAll(0, @as(usize, entries) * 3);
        }
        try self.appendByte(opts.lzw_min_code_size);
        // Empty data: just the terminator sub-block.
        try self.appendByte(0);
    }

    fn appendImageWithLzw(self: *TestBuilder, opts: ImageDescOpts, lct: ?[]const Rgb, lzw_data: []const u8) !void {
        try self.appendByte(block_image_descriptor);
        try self.appendU16(opts.left);
        try self.appendU16(opts.top);
        try self.appendU16(opts.width);
        try self.appendU16(opts.height);
        try self.appendByte(opts.packed_byte);
        if (lct) |entries| {
            for (entries) |e| {
                try self.appendBytes(&.{ e.r, e.g, e.b });
            }
        }
        try self.appendByte(opts.lzw_min_code_size);
        var idx: usize = 0;
        while (idx < lzw_data.len) {
            const chunk_len = @min(lzw_data.len - idx, 255);
            try self.appendByte(@intCast(chunk_len));
            try self.appendBytes(lzw_data[idx .. idx + chunk_len]);
            idx += chunk_len;
        }
        try self.appendByte(0);
    }

    fn appendHeaderWithGct(self: *TestBuilder, w: u16, h: u16, gct: []const Rgb) !void {
        try self.appendBytes("GIF89a");
        try self.appendU16(w);
        try self.appendU16(h);
        const s = declaredSizeLog(gct.len);
        const declared: u16 = @as(u16, 2) << s;
        const packed_byte: u8 = lsd_flag_global_color_table | lsd_color_resolution_default | @as(u8, s);
        try self.appendByte(packed_byte);
        try self.appendByte(0); // bg
        try self.appendByte(0); // aspect
        try writeColorTable(&self.aw.writer, gct, declared);
    }

    const GceOpts = struct {
        disposal: u3 = 0,
        delay_cs: u16 = 0,
        has_transparent: bool = false,
        transparent_index: u8 = 0,
    };

    fn appendGce(self: *TestBuilder, opts: GceOpts) !void {
        try self.appendByte(block_extension_introducer);
        try self.appendByte(ext_label_graphic_control);
        try self.appendByte(0x04); // block size (always 4)
        const trans_flag: u8 = if (opts.has_transparent) gce_flag_transparent else 0;
        const packed_byte: u8 = (@as(u8, opts.disposal) << 2) | trans_flag;
        try self.appendByte(packed_byte);
        try self.appendU16(opts.delay_cs);
        try self.appendByte(opts.transparent_index);
        try self.appendByte(0); // sub-block terminator
    }

    fn appendNetscape2(self: *TestBuilder, loop_count: u16) !void {
        try self.appendByte(block_extension_introducer);
        try self.appendByte(ext_label_application);
        try self.appendByte(0x0B); // block size = 11
        try self.appendBytes("NETSCAPE2.0");
        try self.appendByte(0x03); // sub-block size = 3
        try self.appendByte(0x01); // sub-block id
        try self.appendU16(loop_count);
        try self.appendByte(0); // terminator
    }

    fn appendComment(self: *TestBuilder, text: []const u8) !void {
        try self.appendByte(block_extension_introducer);
        try self.appendByte(ext_label_comment);
        try self.appendByte(@intCast(text.len));
        try self.appendBytes(text);
        try self.appendByte(0);
    }

    fn appendTrailer(self: *TestBuilder) !void {
        try self.appendByte(block_trailer);
    }

    const HeaderOpts = struct {
        signature: []const u8 = "GIF89a",
        width: u16 = 4,
        height: u16 = 4,
        gct_size_log: ?u3 = null,
        bg_index: u8 = 0,
    };

    const ImageDescOpts = struct {
        left: u16 = 0,
        top: u16 = 0,
        width: u16 = 4,
        height: u16 = 4,
        packed_byte: u8 = 0,
        lct_size_log: ?u3 = null,
        lzw_min_code_size: u8 = 2,
    };
};

fn buildReader(data: []const u8) Io.Reader {
    return Io.Reader.fixed(data);
}

test "getInfo — minimal GIF87a, no frames" {
    const gpa = std.testing.allocator;
    var b: TestBuilder = .init(gpa);
    defer b.deinit();

    try b.appendHeader(.{ .signature = "GIF87a", .width = 16, .height = 8 });
    try b.appendTrailer();

    var reader = buildReader(b.written());
    const info = try getInfo(&reader, .{});

    try expectEqual(Version.gif87a, info.version);
    try expectEqual(@as(u32, 16), info.width);
    try expectEqual(@as(u32, 8), info.height);
    try expect(!info.has_global_color_table);
    try expectEqual(@as(u32, 0), info.frame_count);
    try expectEqual(@as(u16, 0), info.loop_count);
}

test "getInfo — GIF89a with 1 frame and GCE" {
    const gpa = std.testing.allocator;
    var b: TestBuilder = .init(gpa);
    defer b.deinit();

    try b.appendHeader(.{ .gct_size_log = 1 }); // 4-entry GCT
    try b.appendGce(.{});
    try b.appendImageDescriptor(.{});
    try b.appendTrailer();

    var reader = buildReader(b.written());
    const info = try getInfo(&reader, .{});

    try expectEqual(Version.gif89a, info.version);
    try expectEqual(@as(u32, 1), info.frame_count);
    try expect(info.has_global_color_table);
    try expectEqual(@as(u16, 4), info.global_color_table_size);
    try expectEqual(@as(u16, 0), info.loop_count);
}

test "getInfo — NETSCAPE2.0 loop count = 3" {
    const gpa = std.testing.allocator;
    var b: TestBuilder = .init(gpa);
    defer b.deinit();

    try b.appendHeader(.{});
    try b.appendNetscape2(3);
    try b.appendImageDescriptor(.{});
    try b.appendImageDescriptor(.{});
    try b.appendTrailer();

    var reader = buildReader(b.written());
    const info = try getInfo(&reader, .{});

    try expectEqual(@as(u16, 3), info.loop_count);
    try expectEqual(@as(u32, 2), info.frame_count);
}

test "getInfo — comment extension is skipped" {
    const gpa = std.testing.allocator;
    var b: TestBuilder = .init(gpa);
    defer b.deinit();

    try b.appendHeader(.{});
    try b.appendComment("made with zignal");
    try b.appendImageDescriptor(.{});
    try b.appendTrailer();

    var reader = buildReader(b.written());
    const info = try getInfo(&reader, .{});
    try expectEqual(@as(u32, 1), info.frame_count);
}

test "getInfo — bad signature rejected" {
    const data = "FOO89a" ++ @as([7]u8, @splat(0)) ++ [_]u8{block_trailer};
    var reader = buildReader(data);
    try expectError(error.InvalidGifSignature, getInfo(&reader, .{}));
}

test "getInfo — unsupported version rejected" {
    const data = "GIF99x" ++ ([_]u8{ 0x04, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00 }) ++ [_]u8{block_trailer};
    var reader = buildReader(data);
    try expectError(error.UnsupportedGifVersion, getInfo(&reader, .{}));
}

test "getInfo — width exceeds limit" {
    const gpa = std.testing.allocator;
    var b: TestBuilder = .init(gpa);
    defer b.deinit();

    try b.appendHeader(.{ .width = 2000, .height = 10 });
    try b.appendTrailer();

    var reader = buildReader(b.written());
    try expectError(error.ImageTooLarge, getInfo(&reader, .{ .max_width = .limited(1024) }));
}

test "getInfo — frame count exceeds limit" {
    const gpa = std.testing.allocator;
    var b: TestBuilder = .init(gpa);
    defer b.deinit();

    try b.appendHeader(.{});
    try b.appendImageDescriptor(.{});
    try b.appendImageDescriptor(.{});
    try b.appendImageDescriptor(.{});
    try b.appendTrailer();

    var reader = buildReader(b.written());
    try expectError(error.TooManyFrames, getInfo(&reader, .{ .max_frames = .limited(2) }));
}

// ---------------------------------------------------------------------------
// Decode tests
// ---------------------------------------------------------------------------

const test_palette_4 = [_]Rgb{
    .{ .r = 0, .g = 0, .b = 0 },
    .{ .r = 255, .g = 0, .b = 0 },
    .{ .r = 0, .g = 255, .b = 0 },
    .{ .r = 0, .g = 0, .b = 255 },
};

test "loadFromBytes — 1x1 red pixel" {
    const gpa = std.testing.allocator;
    var b: TestBuilder = .init(gpa);
    defer b.deinit();

    try b.appendHeaderWithGct(1, 1, &test_palette_4);
    // LZW for indices [1]: Clear=4, 1, EOI=5 at min_code_size=2.
    //   bits 0..2 = 100 (Clear), 3..5 = 001 (1), 6..8 = 101 (EOI)
    //   byte 0 = 0b01001100 = 0x4C, byte 1 = 0b00000001 = 0x01
    try b.appendImageWithLzw(.{ .width = 1, .height = 1 }, null, &.{ 0x4C, 0x01 });
    try b.appendTrailer();

    var img = try loadFromBytes(Rgb, parallel.inline_io, gpa, b.written(), .{});
    defer img.deinit(gpa);

    try expectEqual(@as(usize, 1), img.rows);
    try expectEqual(@as(usize, 1), img.cols);
    try expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, img.at(0, 0).*);
}

test "loadFromBytes — 2x2 with global palette" {
    const gpa = std.testing.allocator;
    var b: TestBuilder = .init(gpa);
    defer b.deinit();

    try b.appendHeaderWithGct(2, 2, &test_palette_4);
    // LZW for indices [0, 1, 2, 3]: encoder grows code_size after the third
    // user emission saturates the dict (next_code = 9 > 1<<3), so codes 0,1,2
    // are emitted at 3 bits and 3,EOI at 4 bits → bytes [0x44, 0x34, 0x05].
    try b.appendImageWithLzw(.{ .width = 2, .height = 2 }, null, &.{ 0x44, 0x34, 0x05 });
    try b.appendTrailer();

    var img = try loadFromBytes(Rgb, parallel.inline_io, gpa, b.written(), .{});
    defer img.deinit(gpa);

    try expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, img.at(0, 0).*);
    try expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, img.at(0, 1).*);
    try expectEqual(Rgb{ .r = 0, .g = 255, .b = 0 }, img.at(1, 0).*);
    try expectEqual(Rgb{ .r = 0, .g = 0, .b = 255 }, img.at(1, 1).*);
}

test "loadFromBytes — local color table overrides global" {
    const gpa = std.testing.allocator;
    var b: TestBuilder = .init(gpa);
    defer b.deinit();

    try b.appendHeaderWithGct(1, 1, &test_palette_4); // global red at idx 1

    // LCT: 4 entries, idx 1 = white (different from global red).
    const lct = [_]Rgb{
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 255, .g = 255, .b = 255 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
    };
    // packed_byte: LCT flag = 0x80, lct_size_log = 1 → 0x81.
    try b.appendImageWithLzw(
        .{ .width = 1, .height = 1, .packed_byte = 0x81, .lct_size_log = 1 },
        &lct,
        &.{ 0x4C, 0x01 },
    );
    try b.appendTrailer();

    var img = try loadFromBytes(Rgb, parallel.inline_io, gpa, b.written(), .{});
    defer img.deinit(gpa);

    try expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, img.at(0, 0).*);
}

test "loadFromBytes — frame outside screen rejected via descriptor checks" {
    const gpa = std.testing.allocator;
    var b: TestBuilder = .init(gpa);
    defer b.deinit();

    try b.appendHeaderWithGct(4, 4, &test_palette_4);
    // Frame width 6 — exceeds screen but per the LSD limit. Should be tolerated
    // by the parser (composition just clips), so this should NOT fail. Let's
    // test the actual oversize-rejection via DecodeLimits.max_width instead.
    try b.appendImageWithLzw(.{ .width = 1, .height = 1 }, null, &.{ 0x4C, 0x01 });
    try b.appendTrailer();

    try expectError(error.ImageTooLarge, loadFromBytes(Rgb, parallel.inline_io, gpa, b.written(), .{ .max_width = .limited(2) }));
}

// ---------------------------------------------------------------------------
// Multi-frame tests
// ---------------------------------------------------------------------------

test "loadAnimated — two frames, do_not_dispose, per-frame delays" {
    const gpa = std.testing.allocator;
    var b: TestBuilder = .init(gpa);
    defer b.deinit();

    try b.appendHeaderWithGct(1, 1, &test_palette_4);

    // Frame 0: red (idx 1), delay 5cs.
    try b.appendGce(.{ .disposal = 1, .delay_cs = 5 });
    try b.appendImageWithLzw(.{ .width = 1, .height = 1 }, null, &.{ 0x4C, 0x01 });

    // Frame 1: green (idx 2), delay 10cs.
    try b.appendGce(.{ .disposal = 1, .delay_cs = 10 });
    // LZW for indices [2]: Clear=4, 2, EOI=5 at min_code_size=2.
    //   bits 0..2 = 100, 3..5 = 010, 6..8 = 101
    //   byte 0 = 0,0,1, 0,1,0, 1,0 = 0b01010100 = 0x54
    //   byte 1 = bit 8 = 1, rest = 0 = 0x01
    try b.appendImageWithLzw(.{ .width = 1, .height = 1 }, null, &.{ 0x54, 0x01 });

    try b.appendTrailer();

    var anim = try loadAnimatedFromBytes(Rgba, parallel.inline_io, gpa, b.written(), .{});
    defer anim.deinit(gpa);

    try expectEqual(@as(usize, 2), anim.frameCount());
    try expectEqual(@as(u32, 50), anim.durations_ms[0]);
    try expectEqual(@as(u32, 100), anim.durations_ms[1]);
    try expectEqual(Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 }, anim.frame(0).at(0, 0).*);
    try expectEqual(Rgba{ .r = 0, .g = 255, .b = 0, .a = 255 }, anim.frame(1).at(0, 0).*);
}

test "loadAnimated — restore_to_background blanks the previous rect" {
    const gpa = std.testing.allocator;
    var b: TestBuilder = .init(gpa);
    defer b.deinit();

    // 2x1 screen: frame 0 covers full screen with red, then disposal=2 (RTB).
    // Frame 1 covers only the first column with green; column 1 should be transparent.
    try b.appendHeaderWithGct(2, 1, &test_palette_4);

    // Frame 0: 2x1 red. LZW encode indices [1, 1].
    //   Clear=4, 1, 1, EOI=5 (all 3 bits since dict_size never reaches 8).
    //   bits: 100 001 001 101
    //     byte 0 (bits 0..7) = 0,0,1,1,0,0,1,0 = 0x4C
    //     byte 1 (bits 8..11) = 0,1,0,1 + pad = 0,1,0,1,0,0,0,0 = 0x0A
    try b.appendGce(.{ .disposal = 2 });
    try b.appendImageWithLzw(.{ .width = 2, .height = 1 }, null, &.{ 0x4C, 0x0A });

    // Frame 1: 1x1 green at (0,0). LZW [2] = [0x54, 0x01].
    try b.appendGce(.{});
    try b.appendImageWithLzw(.{ .left = 0, .top = 0, .width = 1, .height = 1 }, null, &.{ 0x54, 0x01 });

    try b.appendTrailer();

    var anim = try loadAnimatedFromBytes(Rgba, parallel.inline_io, gpa, b.written(), .{});
    defer anim.deinit(gpa);

    try expectEqual(@as(usize, 2), anim.frameCount());
    // Frame 0: both pixels red.
    try expectEqual(Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 }, anim.frame(0).at(0, 0).*);
    try expectEqual(Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 }, anim.frame(0).at(0, 1).*);
    // Frame 1: pixel 0 = green (drawn on cleared canvas), pixel 1 = transparent.
    try expectEqual(Rgba{ .r = 0, .g = 255, .b = 0, .a = 255 }, anim.frame(1).at(0, 0).*);
    try expectEqual(@as(u8, 0), anim.frame(1).at(0, 1).a);
}

test "loadAnimated — transparent index → alpha=0 on Rgba" {
    const gpa = std.testing.allocator;
    var b: TestBuilder = .init(gpa);
    defer b.deinit();

    // 2x1 frame, indices [0, 1]. Mark idx 0 transparent.
    try b.appendHeaderWithGct(2, 1, &test_palette_4);

    try b.appendGce(.{ .disposal = 1, .has_transparent = true });
    // LZW for indices [0, 1]: Clear=4, 0, 1, EOI=5 (all 3 bits).
    //   bits: 100 000 001 101
    //     byte 0 = 0,0,1,0,0,0,1,0 = 0x44
    //     byte 1 = 0,1,0,1 + pad = 0x0A
    try b.appendImageWithLzw(.{ .width = 2, .height = 1 }, null, &.{ 0x44, 0x0A });

    try b.appendTrailer();

    var anim = try loadAnimatedFromBytes(Rgba, parallel.inline_io, gpa, b.written(), .{});
    defer anim.deinit(gpa);

    // Pixel 0: index 0 is transparent → alpha=0 (canvas was initialized to all transparent).
    try expectEqual(@as(u8, 0), anim.frame(0).at(0, 0).a);
    // Pixel 1: index 1 (red), opaque.
    try expectEqual(Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 }, anim.frame(0).at(0, 1).*);
}

// ---------------------------------------------------------------------------
// Encode tests
// ---------------------------------------------------------------------------

test "encode — caller-supplied palette, exact round-trip" {
    const gpa = std.testing.allocator;

    // 2x2 image where pixels exactly hit a 4-color palette.
    var img = try Image(Rgb).init(gpa, 2, 2);
    defer img.deinit(gpa);
    img.at(0, 0).* = .{ .r = 255, .g = 0, .b = 0 };
    img.at(0, 1).* = .{ .r = 0, .g = 255, .b = 0 };
    img.at(1, 0).* = .{ .r = 0, .g = 0, .b = 255 };
    img.at(1, 1).* = .{ .r = 0, .g = 0, .b = 0 };

    const palette = [_]Rgb{
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 255, .g = 0, .b = 0 },
        .{ .r = 0, .g = 255, .b = 0 },
        .{ .r = 0, .g = 0, .b = 255 },
    };

    const data = try encode(Rgb, parallel.inline_io, gpa, img, .{ .palette = &palette });
    defer gpa.free(data);

    var decoded = try loadFromBytes(Rgb, parallel.inline_io, gpa, data, .{});
    defer decoded.deinit(gpa);

    try expectEqual(@as(usize, 2), decoded.rows);
    try expectEqual(@as(usize, 2), decoded.cols);
    try expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, decoded.at(0, 0).*);
    try expectEqual(Rgb{ .r = 0, .g = 255, .b = 0 }, decoded.at(0, 1).*);
    try expectEqual(Rgb{ .r = 0, .g = 0, .b = 255 }, decoded.at(1, 0).*);
    try expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, decoded.at(1, 1).*);
}

test "encode — auto median-cut on 16x16 gradient" {
    const gpa = std.testing.allocator;
    var img = try Image(Rgb).init(gpa, 16, 16);
    defer img.deinit(gpa);
    for (0..16) |r| {
        for (0..16) |c| {
            img.at(r, c).* = .{
                .r = @intCast(r * 16),
                .g = @intCast(c * 16),
                .b = 128,
            };
        }
    }

    const data = try encode(Rgb, parallel.inline_io, gpa, img, .{});
    defer gpa.free(data);

    var decoded = try loadFromBytes(Rgb, parallel.inline_io, gpa, data, .{});
    defer decoded.deinit(gpa);

    try expectEqual(@as(usize, 16), decoded.rows);
    try expectEqual(@as(usize, 16), decoded.cols);
}

test "encode — Image(u8) gradient via linear gray palette" {
    const gpa = std.testing.allocator;
    var img = try Image(u8).init(gpa, 4, 8);
    defer img.deinit(gpa);
    for (0..4) |r| {
        for (0..8) |c| {
            img.at(r, c).* = @intCast((r * 8 + c) * 8);
        }
    }

    const data = try encode(u8, parallel.inline_io, gpa, img, .{});
    defer gpa.free(data);

    var decoded = try loadFromBytes(u8, parallel.inline_io, gpa, data, .{});
    defer decoded.deinit(gpa);

    try expectEqual(@as(usize, 4), decoded.rows);
    try expectEqual(@as(usize, 8), decoded.cols);
    for (0..4) |r| {
        for (0..8) |c| {
            try expectEqual(@as(u8, @intCast((r * 8 + c) * 8)), decoded.at(r, c).*);
        }
    }
}

test "encode — Floyd–Steinberg dithering produces valid output" {
    const gpa = std.testing.allocator;
    var img = try Image(Rgb).init(gpa, 8, 8);
    defer img.deinit(gpa);
    // Smooth gradient that quantizes poorly without dithering.
    for (0..8) |r| {
        for (0..8) |c| {
            img.at(r, c).* = .{ .r = @intCast(r * 36), .g = @intCast(c * 36), .b = 128 };
        }
    }

    const data = try encode(Rgb, parallel.inline_io, gpa, img, .{ .max_colors = 8, .dither = true });
    defer gpa.free(data);

    var decoded = try loadFromBytes(Rgb, parallel.inline_io, gpa, data, .{});
    defer decoded.deinit(gpa);

    try expectEqual(@as(usize, 8), decoded.rows);
    try expectEqual(@as(usize, 8), decoded.cols);
}

test "encode — getInfo on encoded output is consistent" {
    const gpa = std.testing.allocator;
    var img = try Image(Rgb).init(gpa, 8, 12);
    defer img.deinit(gpa);
    @memset(img.data, .{ .r = 64, .g = 128, .b = 192 });

    const data = try encode(Rgb, parallel.inline_io, gpa, img, .{});
    defer gpa.free(data);

    var reader = Io.Reader.fixed(data);
    const info = try getInfo(&reader, .{});
    try expectEqual(@as(u32, 12), info.width);
    try expectEqual(@as(u32, 8), info.height);
    try expectEqual(Version.gif89a, info.version);
    try expectEqual(@as(u32, 1), info.frame_count);
}

// ---------------------------------------------------------------------------
// Animated encode tests
// ---------------------------------------------------------------------------

fn buildAnimated(comptime T: type, gpa: Allocator, frame_data: []const Image(T), durations_ms: []const u32, loop: u32) !AnimatedImage(T) {
    const frames = try gpa.alloc(Image(T), frame_data.len);
    @memcpy(frames, frame_data);
    return .{ .frames = frames, .durations_ms = try gpa.dupe(u32, durations_ms), .loop_count = loop };
}

test "encodeAnimated — 2 Rgb frames round-trip with delays and loop count" {
    const gpa = std.testing.allocator;

    const f0 = try Image(Rgb).init(gpa, 2, 2);
    @memset(f0.data, .{ .r = 255, .g = 0, .b = 0 });
    const f1 = try Image(Rgb).init(gpa, 2, 2);
    @memset(f1.data, .{ .r = 0, .g = 255, .b = 0 });

    var anim = try buildAnimated(Rgb, gpa, &.{ f0, f1 }, &.{ 50, 100 }, 3);
    defer anim.deinit(gpa);

    const data = try encodeAnimated(Rgb, parallel.inline_io, gpa, anim, .{});
    defer gpa.free(data);

    var decoded = try loadAnimatedFromBytes(Rgba, parallel.inline_io, gpa, data, .{});
    defer decoded.deinit(gpa);

    try expectEqual(@as(usize, 2), decoded.frameCount());
    try expectEqual(@as(u32, 3), decoded.loop_count);
    try expectEqual(@as(u32, 50), decoded.durations_ms[0]);
    try expectEqual(@as(u32, 100), decoded.durations_ms[1]);
    try expectEqual(Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 }, decoded.frame(0).at(0, 0).*);
    try expectEqual(Rgba{ .r = 0, .g = 255, .b = 0, .a = 255 }, decoded.frame(1).at(0, 0).*);
}

test "encodeAnimated — Rgba transparent pixel round-trips alpha=0" {
    const gpa = std.testing.allocator;

    const f0 = try Image(Rgba).init(gpa, 1, 2);
    f0.at(0, 0).* = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    f0.at(0, 1).* = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const f1 = try Image(Rgba).init(gpa, 1, 2);
    f1.at(0, 0).* = .{ .r = 0, .g = 255, .b = 0, .a = 255 };
    f1.at(0, 1).* = .{ .r = 0, .g = 0, .b = 255, .a = 255 };

    var anim = try buildAnimated(Rgba, gpa, &.{ f0, f1 }, &.{ 0, 0 }, 0);
    defer anim.deinit(gpa);

    const data = try encodeAnimated(Rgba, parallel.inline_io, gpa, anim, .{});
    defer gpa.free(data);

    var decoded = try loadAnimatedFromBytes(Rgba, parallel.inline_io, gpa, data, .{});
    defer decoded.deinit(gpa);

    try expectEqual(@as(u8, 0), decoded.frame(0).at(0, 0).a);
    try expectEqual(@as(u8, 255), decoded.frame(0).at(0, 1).a);
    try expectEqual(Rgba{ .r = 0, .g = 255, .b = 0, .a = 255 }, decoded.frame(1).at(0, 0).*);
    try expectEqual(Rgba{ .r = 0, .g = 0, .b = 255, .a = 255 }, decoded.frame(1).at(0, 1).*);
}

test "encodeAnimated — opaque pixel turned transparent round-trips alpha=0" {
    const gpa = std.testing.allocator;

    const f0 = try Image(Rgba).init(gpa, 2, 3);
    @memset(f0.data, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
    const f1 = try Image(Rgba).init(gpa, 2, 3);
    @memset(f1.data, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
    f1.at(1, 2).a = 0;
    const f2 = try Image(Rgba).init(gpa, 2, 3);
    f1.copy(f2);
    f2.at(0, 0).* = .{ .r = 0, .g = 0, .b = 255, .a = 255 };

    var anim = try buildAnimated(Rgba, gpa, &.{ f0, f1, f2 }, &.{ 50, 50, 50 }, 0);
    defer anim.deinit(gpa);
    const data = try encodeAnimated(Rgba, parallel.inline_io, gpa, anim, .{});
    defer gpa.free(data);
    var decoded = try loadAnimatedFromBytes(Rgba, parallel.inline_io, gpa, data, .{});
    defer decoded.deinit(gpa);

    try expectEqual(@as(u8, 0), decoded.frame(1).at(1, 2).a);
    try expectEqual(@as(u8, 0), decoded.frame(2).at(1, 2).a);
    try expectEqual(Rgba{ .r = 0, .g = 0, .b = 255, .a = 255 }, decoded.frame(2).at(0, 0).*);
    try expectEqual(Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 }, decoded.frame(2).at(1, 1).*);
}

test "encodeAnimated — changed-region frames decode to the full frames" {
    const gpa = std.testing.allocator;
    const palette = [_]Rgb{ .{ .r = 10, .g = 20, .b = 30 }, .{ .r = 200, .g = 50, .b = 50 }, .{ .r = 40, .g = 220, .b = 90 } };

    // A moving square, a repeated frame, then a change everywhere.
    var frames: [5]Image(Rgb) = undefined;
    for (&frames, 0..) |*f, i| {
        f.* = try .init(gpa, 16, 24);
        @memset(f.data, palette[0]);
        if (i < 3) for (4..8) |r| for (2 + i * 5..6 + i * 5) |c| {
            f.at(r, c).* = palette[1];
        };
    }
    frames[2].copy(frames[3]);
    @memset(frames[4].data, palette[2]);

    var anim = try buildAnimated(Rgb, gpa, &frames, &.{ 30, 30, 30, 30, 30 }, 0);
    defer anim.deinit(gpa);
    const data = try encodeAnimated(Rgb, parallel.inline_io, gpa, anim, .{ .palette = &palette });
    defer gpa.free(data);
    var decoded = try loadAnimatedFromBytes(Rgb, parallel.inline_io, gpa, data, .{});
    defer decoded.deinit(gpa);

    try expectEqual(anim.frameCount(), decoded.frameCount());
    for (anim.frames, decoded.frames) |a, b| try std.testing.expectEqualSlices(Rgb, a.data, b.data);
}

test "encodeAnimated — caller-supplied global palette uses GCT, no per-frame LCT" {
    const gpa = std.testing.allocator;

    const f0 = try Image(Rgb).init(gpa, 1, 1);
    f0.at(0, 0).* = .{ .r = 255, .g = 0, .b = 0 };
    const f1 = try Image(Rgb).init(gpa, 1, 1);
    f1.at(0, 0).* = .{ .r = 0, .g = 0, .b = 255 };

    var anim = try buildAnimated(Rgb, gpa, &.{ f0, f1 }, &.{ 50, 50 }, 0);
    defer anim.deinit(gpa);

    const palette = [_]Rgb{
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 255, .g = 0, .b = 0 },
        .{ .r = 0, .g = 255, .b = 0 },
        .{ .r = 0, .g = 0, .b = 255 },
    };
    const data = try encodeAnimated(Rgb, parallel.inline_io, gpa, anim, .{ .palette = &palette });
    defer gpa.free(data);

    var reader = Io.Reader.fixed(data);
    const info = try getInfo(&reader, .{});
    try expect(info.has_global_color_table);
    try expectEqual(@as(u16, 4), info.global_color_table_size);
    try expectEqual(@as(u32, 2), info.frame_count);

    var decoded = try loadAnimatedFromBytes(Rgb, parallel.inline_io, gpa, data, .{});
    defer decoded.deinit(gpa);
    try expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, decoded.frame(0).at(0, 0).*);
    try expectEqual(Rgb{ .r = 0, .g = 0, .b = 255 }, decoded.frame(1).at(0, 0).*);
}

test "encodeAnimated — empty animation rejected" {
    const gpa = std.testing.allocator;
    const anim: AnimatedImage(Rgb) = .{ .frames = &.{}, .durations_ms = &.{}, .loop_count = 0 };
    try expectError(error.NoFrames, encodeAnimated(Rgb, parallel.inline_io, gpa, anim, .{}));
}

test "encodeAnimated — mismatched frame dimensions rejected" {
    const gpa = std.testing.allocator;
    const f0 = try Image(Rgb).init(gpa, 2, 2);
    @memset(f0.data, .{ .r = 0, .g = 0, .b = 0 });
    const f1 = try Image(Rgb).init(gpa, 3, 3);
    @memset(f1.data, .{ .r = 0, .g = 0, .b = 0 });

    var anim = try buildAnimated(Rgb, gpa, &.{ f0, f1 }, &.{ 0, 0 }, 0);
    defer anim.deinit(gpa);

    try expectError(error.InconsistentFrameDimensions, encodeAnimated(Rgb, parallel.inline_io, gpa, anim, .{}));
}

test "loadFromBytes — missing global color table without LCT" {
    const gpa = std.testing.allocator;
    var b: TestBuilder = .init(gpa);
    defer b.deinit();

    try b.appendBytes("GIF89a");
    try b.appendU16(1);
    try b.appendU16(1);
    try b.appendByte(0x00); // no GCT
    try b.appendByte(0); // bg
    try b.appendByte(0); // aspect
    try b.appendImageWithLzw(.{ .width = 1, .height = 1 }, null, &.{ 0x4C, 0x01 });
    try b.appendTrailer();

    try expectError(error.MissingGlobalColorTable, loadFromBytes(Rgb, parallel.inline_io, gpa, b.written(), .{}));
}

test "getInfo — image descriptor with local color table" {
    const gpa = std.testing.allocator;
    var b: TestBuilder = .init(gpa);
    defer b.deinit();

    try b.appendHeader(.{ .gct_size_log = 0 }); // 2-entry GCT
    // packed_byte: bit 7 = LCT flag, bit 0..2 = log2(LCT size) - 1
    // 0x80 sets LCT flag, lower 3 bits = 2 → 8 entries
    try b.appendImageDescriptor(.{ .packed_byte = 0x82, .lct_size_log = 2 });
    try b.appendTrailer();

    var reader = buildReader(b.written());
    const info = try getInfo(&reader, .{});
    try expectEqual(@as(u32, 1), info.frame_count);
    try expect(info.has_global_color_table);
    try expectEqual(@as(u16, 2), info.global_color_table_size);
}

test "GIF encode keeps the transparent pixels of an Rgba image" {
    const gpa = std.testing.allocator;
    var img: Image(Rgba) = try .init(gpa, 4, 4);
    defer img.deinit(gpa);
    for (img.data, 0..) |*p, i| {
        p.* = if (i % 3 == 0) .{ .r = 0, .g = 0, .b = 0, .a = 0 } else .{ .r = @intCast(i * 16), .g = 30, .b = 200, .a = 255 };
    }
    const bytes = try encode(Rgba, parallel.inline_io, gpa, img, .default);
    defer gpa.free(bytes);
    var decoded = try loadFromBytes(Rgba, parallel.inline_io, gpa, bytes, .{});
    defer decoded.deinit(gpa);
    for (img.data, decoded.data) |want, got| {
        try std.testing.expectEqual(want.a, got.a);
        if (want.a == 255) try std.testing.expect(@abs(@as(i32, want.r) - got.r) <= 8);
    }
}
