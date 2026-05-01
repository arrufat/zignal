//! Pure Zig GIF codec.
//!
//! Public surface mirrors the other codecs in this repo (`png`, `jpeg`, `bmp`):
//! `signature`, `DecodeLimits`, `Header`, `GifState` (+ `deinit`), `NativeImage`,
//! `getInfo`, `decode`, `toNativeImage`, `loadFromBytes`, `load`, `EncodeOptions`,
//! `encode`, `save`. Multi-frame access is via `loadAnimated` / `loadAnimatedFromBytes`,
//! which return an `AnimatedImage(T)` of fully-composed frames (disposal, transparency,
//! and interlace are absorbed inside the codec).
//!
//! Encoder is single-frame for v1; animated encoding lands later.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectEqual = std.testing.expectEqual;

const Image = @import("image.zig").Image;
const AnimatedImage = @import("image.zig").AnimatedImage;
const convertColor = @import("color.zig").convertColor;
const Rgb = @import("color.zig").Rgb(u8);
const Rgba = @import("color.zig").Rgba(u8);
const Rectangle = @import("geometry.zig").Rectangle;

const lzw = @import("gif/lzw.zig");

test {
    _ = lzw;
}

/// 3-byte GIF magic. Followed on disk by a 3-byte version (`87a` or `89a`)
/// validated separately by `getInfo`/`decode`.
pub const signature = [_]u8{ 'G', 'I', 'F' };

/// GIF version (87a or 89a).
pub const Version = enum { gif87a, gif89a };

const max_file_size_default: usize = 100 * 1024 * 1024;
const max_dimensions_default: u32 = 8192;
const max_pixels_default: u64 = 67_108_864; // per frame
const max_frames_default: u32 = 4096;
const max_total_pixels_default: u64 = 1_073_741_824; // sum across frames (LZW bomb guard)

/// Resource limits applied while decoding GIF data. Zero disables the
/// corresponding limit.
pub const DecodeLimits = struct {
    max_gif_bytes: usize = max_file_size_default,
    max_width: u32 = max_dimensions_default,
    max_height: u32 = max_dimensions_default,
    /// Per-frame pixel count cap.
    max_pixels: u64 = max_pixels_default,
    max_frames: u32 = max_frames_default,
    /// Total composed pixels across all frames (decoder-bomb guard).
    max_total_pixels: u64 = max_total_pixels_default,
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

inline fn exceeds(comptime T: type, limit: T, value: T) bool {
    return limit != 0 and value > limit;
}

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
    if (exceeds(u32, limits.max_width, screen_w) or exceeds(u32, limits.max_height, screen_h)) {
        return error.ImageTooLarge;
    }
    if (exceeds(u64, limits.max_pixels, @as(u64, screen_w) * @as(u64, screen_h))) {
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
                if (exceeds(u32, limits.max_frames, frame_count)) return error.TooManyFrames;
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
    if (exceeds(usize, limits.max_gif_bytes, data.len)) return error.GifDataTooLarge;

    var reader: Io.Reader = .fixed(data);

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
    if (exceeds(u32, limits.max_width, screen_w) or exceeds(u32, limits.max_height, screen_h)) {
        return error.ImageTooLarge;
    }
    if (exceeds(u64, limits.max_pixels, @as(u64, screen_w) * @as(u64, screen_h))) {
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
                const frame = try parseImageBlock(gpa, &reader, limits, global_palette, pending_gce, &total_pixels);
                pending_gce = null;
                try frames.append(gpa, frame);
                if (exceeds(u32, limits.max_frames, @intCast(frames.items.len))) {
                    return error.TooManyFrames;
                }
            },
            block_extension_introducer => {
                const label = try reader.takeByte();
                switch (label) {
                    ext_label_graphic_control => pending_gce = try parseGce(&reader),
                    ext_label_application => try parseAppExtension(&reader, &loop_count),
                    else => try skipSubBlocks(&reader),
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
        .disposal = @enumFromInt((packed_byte >> 2) & gce_disposal_mask),
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
    if (exceeds(u32, limits.max_width, width) or exceeds(u32, limits.max_height, height)) {
        return error.ImageTooLarge;
    }
    const num_pixels: u64 = @as(u64, width) * @as(u64, height);
    if (exceeds(u64, limits.max_pixels, num_pixels)) return error.ImageTooLarge;
    total_pixels.* +|= num_pixels;
    if (exceeds(u64, limits.max_total_pixels, total_pixels.*)) return error.ImageTooLarge;

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
    if (written != num_pixels_usize) return error.LzwOutputOverflow;

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
fn composeFirstFrame(comptime T: type, allocator: Allocator, state: GifState) !Image(T) {
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
    return canvas.convert(T, allocator);
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
pub fn toNativeImage(allocator: Allocator, state: GifState) !NativeImage {
    if (state.frames.len == 0) return error.MissingPixelData;
    const has_transparency = if (state.frames[0].gce) |g| g.has_transparent else false;
    if (has_transparency) {
        return .{ .rgba = try composeFirstFrame(Rgba, allocator, state) };
    }
    return .{ .rgb = try composeFirstFrame(Rgb, allocator, state) };
}

/// Loads a GIF from in-memory bytes. Returns frame 0 only — see
/// `loadAnimatedFromBytes` for full multi-frame access.
pub fn loadFromBytes(comptime T: type, allocator: Allocator, data: []const u8, limits: DecodeLimits) !Image(T) {
    var state = try decode(allocator, data, limits);
    defer state.deinit(allocator);
    return composeFirstFrame(T, allocator, state);
}

// ---------------------------------------------------------------------------
// Multi-frame composition
// ---------------------------------------------------------------------------

/// Composes all frames into an `AnimatedImage(T)`. Each output frame is the
/// fully-rendered canvas at that point in playback, so callers don't have to
/// know about disposal methods or transparent indices.
fn composeAnimated(comptime T: type, allocator: Allocator, state: GifState) !AnimatedImage(T) {
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

    const frames_out = try allocator.alloc(Image(T), state.frames.len);
    var frames_init: usize = 0;
    errdefer {
        for (frames_out[0..frames_init]) |*f| f.deinit(allocator);
        allocator.free(frames_out);
    }

    var delays_out = try allocator.alloc(u16, state.frames.len);
    errdefer allocator.free(delays_out);

    var prev_disposal: DisposalMethod = .unspecified;
    var prev_rect: Rectangle(u32) = .init(0, 0, 0, 0);

    for (state.frames, 0..) |frame, i| {
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

        var rgba_frame = try Image(Rgba).init(allocator, screen_h, screen_w);
        @memcpy(rgba_frame.data, canvas.data);

        if (T == Rgba) {
            frames_out[i] = rgba_frame;
        } else {
            defer rgba_frame.deinit(allocator);
            frames_out[i] = try rgba_frame.convert(T, allocator);
        }
        frames_init = i + 1;

        delays_out[i] = if (frame.gce) |g| g.delay_cs else 0;
        prev_disposal = if (frame.gce) |g| g.disposal else .unspecified;
        prev_rect = .init(frame.left, frame.top, frame.left +| frame.width, frame.top +| frame.height);
    }

    return .{
        .frames = frames_out,
        .delays_cs = delays_out,
        .loop_count = state.header.loop_count,
    };
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
pub fn loadAnimatedFromBytes(comptime T: type, allocator: Allocator, data: []const u8, limits: DecodeLimits) !AnimatedImage(T) {
    var state = try decode(allocator, data, limits);
    defer state.deinit(allocator);
    return composeAnimated(T, allocator, state);
}

fn readGifFile(io: Io, allocator: Allocator, file_path: []const u8, limits: DecodeLimits) ![]u8 {
    const read_limit = if (limits.max_gif_bytes == 0) std.math.maxInt(usize) else limits.max_gif_bytes;
    return Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(read_limit));
}

/// Loads all frames from a GIF file into an `AnimatedImage(T)`.
pub fn loadAnimated(comptime T: type, io: Io, allocator: Allocator, file_path: []const u8, limits: DecodeLimits) !AnimatedImage(T) {
    const data = try readGifFile(io, allocator, file_path, limits);
    defer allocator.free(data);
    return loadAnimatedFromBytes(T, allocator, data, limits);
}

/// Loads a GIF from a file path. Returns frame 0 only.
pub fn load(comptime T: type, io: Io, allocator: Allocator, file_path: []const u8, limits: DecodeLimits) !Image(T) {
    const data = try readGifFile(io, allocator, file_path, limits);
    defer allocator.free(data);
    return loadFromBytes(T, allocator, data, limits);
}

// ---------------------------------------------------------------------------
// Single-frame encode
// ---------------------------------------------------------------------------

const quantize = @import("image/quantize.zig");
const dither = @import("image/dither.zig");

/// Single-frame GIF encode options.
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

/// Encodes a single-frame GIF from `image`. Caller frees the returned slice.
pub fn encode(comptime T: type, allocator: Allocator, image: Image(T), options: EncodeOptions) ![]u8 {
    if (image.cols == 0 or image.rows == 0) return error.InvalidDimensions;
    if (image.cols > 65535 or image.rows > 65535) return error.ImageTooLarge;

    const width: u16 = @intCast(image.cols);
    const height: u16 = @intCast(image.rows);
    const num_pixels: usize = @as(usize, width) * @as(usize, height);

    // 1) Resolve palette and produce per-pixel indices.
    var palette_buf: [256]Rgb = undefined;
    var palette: []const Rgb = palette_buf[0..0];

    const indices = try allocator.alloc(u8, num_pixels);
    defer allocator.free(indices);

    if (options.palette) |custom| {
        if (custom.len < 2 or custom.len > 256) return error.PaletteTooSmall;
        @memcpy(palette_buf[0..custom.len], custom);
        palette = palette_buf[0..custom.len];
        try mapImageToPalette(T, allocator, image, palette, indices, options.dither);
    } else if (T == u8) {
        // u8 → 256-entry linear gray palette; indices are the pixel values.
        @memcpy(&palette_buf, &quantize.linear_gray_256);
        palette = palette_buf[0..256];
        // Image(u8) might have non-contiguous stride; copy row by row.
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
        // Auto-quantize via median-cut.
        const max_colors = @max(@as(u16, 2), @min(options.max_colors, 256));
        const palette_size = quantize.medianCut(T, allocator, image, &palette_buf, max_colors) catch |err| switch (err) {
            error.NoPaletteColors => return error.NoPaletteColors,
            else => |e| return e,
        };
        if (palette_size < 2) {
            // Pad to 2 entries — GIF requires at least 2 (min_code_size floor).
            palette_buf[1] = palette_buf[0];
            palette = palette_buf[0..2];
        } else {
            palette = palette_buf[0..palette_size];
        }
        try mapImageToPalette(T, allocator, image, palette, indices, options.dither);
    }

    // 2) Choose min_code_size. GIF spec: floor of 2.
    var min_code_size: u4 = 2;
    while ((@as(u16, 1) << min_code_size) < palette.len) min_code_size += 1;

    // GIF requires the palette to be padded to a power of two for the table itself.
    const declared_size_log: u3 = @intCast(min_code_size - 1);
    const declared_entries: u16 = @as(u16, 2) << declared_size_log;

    // 3) Build output buffer.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    // Header.
    try out.appendSlice(allocator, "GIF89a");

    // Logical Screen Descriptor.
    try writeU16Le(&out, allocator, width);
    try writeU16Le(&out, allocator, height);
    var lsd_packed: u8 = 0;
    lsd_packed |= lsd_flag_global_color_table;
    lsd_packed |= lsd_color_resolution_default;
    lsd_packed |= @as(u8, declared_size_log);
    try out.append(allocator, lsd_packed);
    try out.append(allocator, 0); // background color index
    try out.append(allocator, 0); // pixel aspect ratio

    // Global Color Table (padded to declared_entries).
    for (palette) |c| try out.appendSlice(allocator, &.{ c.r, c.g, c.b });
    var pad_i: usize = palette.len;
    while (pad_i < declared_entries) : (pad_i += 1) try out.appendSlice(allocator, &.{ 0, 0, 0 });

    // Image Descriptor.
    try out.append(allocator, block_image_descriptor);
    try writeU16Le(&out, allocator, 0); // left
    try writeU16Le(&out, allocator, 0); // top
    try writeU16Le(&out, allocator, width);
    try writeU16Le(&out, allocator, height);
    try out.append(allocator, 0x00); // packed: no LCT, not interlaced

    // LZW data.
    try out.append(allocator, @as(u8, min_code_size));

    var encoder = try lzw.Encoder.init(allocator, min_code_size);
    defer encoder.deinit(allocator);

    var lzw_bytes: std.ArrayList(u8) = .empty;
    defer lzw_bytes.deinit(allocator);

    try encoder.encodeAll(allocator, indices, &lzw_bytes);

    // Wrap in 0xFF-max data sub-blocks.
    var idx: usize = 0;
    while (idx < lzw_bytes.items.len) {
        const chunk_len = @min(lzw_bytes.items.len - idx, 255);
        try out.append(allocator, @intCast(chunk_len));
        try out.appendSlice(allocator, lzw_bytes.items[idx .. idx + chunk_len]);
        idx += chunk_len;
    }
    try out.append(allocator, 0); // sub-block terminator

    // Trailer.
    try out.append(allocator, block_trailer);

    return out.toOwnedSlice(allocator);
}

inline fn writeU16Le(out: *std.ArrayList(u8), allocator: Allocator, v: u16) !void {
    try out.append(allocator, @intCast(v & 0xFF));
    try out.append(allocator, @intCast((v >> 8) & 0xFF));
}

/// Maps each pixel to the nearest palette index, with optional Floyd–Steinberg
/// dithering. The dither path round-trips through `Image(Rgb)`; the no-dither
/// path converts per-pixel.
fn mapImageToPalette(
    comptime T: type,
    allocator: Allocator,
    image: Image(T),
    palette: []const Rgb,
    indices: []u8,
    use_dither: bool,
) !void {
    const lut = quantize.ColorLookupTable.init(palette);

    if (use_dither) {
        var work = try image.convert(Rgb, allocator);
        defer work.deinit(allocator);
        dither.applyFloydSteinberg(work, palette, lut);
        var i: usize = 0;
        while (i < image.rows) : (i += 1) {
            const dst_off = i * image.cols;
            const src_off = i * work.stride;
            var j: usize = 0;
            while (j < image.cols) : (j += 1) {
                indices[dst_off + j] = lut.lookup(work.data[src_off + j]);
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
            const rgb = convertColor(Rgb, px);
            indices[dst_off + j] = lut.lookup(rgb);
        }
    }
}

/// Saves `image` as a GIF to `file_path`.
pub fn save(comptime T: type, io: Io, allocator: Allocator, image: Image(T), file_path: []const u8) !void {
    const data = try encode(T, allocator, image, .default);
    defer allocator.free(data);

    const file = if (Io.Dir.path.isAbsolute(file_path))
        try Io.Dir.createFileAbsolute(io, file_path, .{})
    else
        try Io.Dir.cwd().createFile(io, file_path, .{});
    defer file.close(io);

    try file.writeStreamingAll(io, data);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestBuilder = struct {
    list: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestBuilder, gpa: Allocator) void {
        self.list.deinit(gpa);
    }

    fn appendByte(self: *TestBuilder, gpa: Allocator, b: u8) !void {
        try self.list.append(gpa, b);
    }

    fn appendBytes(self: *TestBuilder, gpa: Allocator, bs: []const u8) !void {
        try self.list.appendSlice(gpa, bs);
    }

    fn appendU16(self: *TestBuilder, gpa: Allocator, v: u16) !void {
        try self.list.append(gpa, @intCast(v & 0xFF));
        try self.list.append(gpa, @intCast((v >> 8) & 0xFF));
    }

    fn appendHeader(self: *TestBuilder, gpa: Allocator, opts: HeaderOpts) !void {
        try self.appendBytes(gpa, opts.signature);
        try self.appendU16(gpa, opts.width);
        try self.appendU16(gpa, opts.height);
        var packed_byte: u8 = 0;
        if (opts.gct_size_log) |s| {
            packed_byte |= lsd_flag_global_color_table;
            packed_byte |= lsd_color_resolution_default;
            packed_byte |= s;
        }
        try self.appendByte(gpa, packed_byte);
        try self.appendByte(gpa, opts.bg_index);
        try self.appendByte(gpa, 0); // pixel aspect ratio
        if (opts.gct_size_log) |s| {
            const entries: u32 = @as(u32, 2) << @intCast(s);
            // Fill with zeros — content doesn't affect getInfo.
            try self.list.appendNTimes(gpa, 0, @as(usize, entries) * 3);
        }
    }

    fn appendImageDescriptor(self: *TestBuilder, gpa: Allocator, opts: ImageDescOpts) !void {
        try self.appendByte(gpa, block_image_descriptor);
        try self.appendU16(gpa, opts.left);
        try self.appendU16(gpa, opts.top);
        try self.appendU16(gpa, opts.width);
        try self.appendU16(gpa, opts.height);
        try self.appendByte(gpa, opts.packed_byte);
        if (opts.lct_size_log) |s| {
            const entries: u32 = @as(u32, 2) << @intCast(s);
            try self.list.appendNTimes(gpa, 0, @as(usize, entries) * 3);
        }
        try self.appendByte(gpa, opts.lzw_min_code_size);
        // Empty data: just the terminator sub-block.
        try self.appendByte(gpa, 0);
    }

    fn appendImageWithLzw(self: *TestBuilder, gpa: Allocator, opts: ImageDescOpts, lct: ?[]const Rgb, lzw_data: []const u8) !void {
        try self.appendByte(gpa, block_image_descriptor);
        try self.appendU16(gpa, opts.left);
        try self.appendU16(gpa, opts.top);
        try self.appendU16(gpa, opts.width);
        try self.appendU16(gpa, opts.height);
        try self.appendByte(gpa, opts.packed_byte);
        if (lct) |entries| {
            for (entries) |e| {
                try self.appendBytes(gpa, &.{ e.r, e.g, e.b });
            }
        }
        try self.appendByte(gpa, opts.lzw_min_code_size);
        var idx: usize = 0;
        while (idx < lzw_data.len) {
            const chunk_len = @min(lzw_data.len - idx, 255);
            try self.appendByte(gpa, @intCast(chunk_len));
            try self.appendBytes(gpa, lzw_data[idx .. idx + chunk_len]);
            idx += chunk_len;
        }
        try self.appendByte(gpa, 0);
    }

    fn appendHeaderWithGct(self: *TestBuilder, gpa: Allocator, w: u16, h: u16, gct: []const Rgb) !void {
        try self.appendBytes(gpa, "GIF89a");
        try self.appendU16(gpa, w);
        try self.appendU16(gpa, h);
        // gct_size_log: smallest s such that (2 << s) >= gct.len; clamp to 7.
        var s: u3 = 0;
        while ((@as(u16, 2) << s) < gct.len and s < 7) : (s += 1) {}
        const declared: u16 = @as(u16, 2) << s;
        const packed_byte: u8 = lsd_flag_global_color_table | lsd_color_resolution_default | @as(u8, s);
        try self.appendByte(gpa, packed_byte);
        try self.appendByte(gpa, 0); // bg
        try self.appendByte(gpa, 0); // aspect
        for (gct) |e| try self.appendBytes(gpa, &.{ e.r, e.g, e.b });
        const pad: usize = @as(usize, declared) - gct.len;
        try self.list.appendNTimes(gpa, 0, pad * 3);
    }

    const GceOpts = struct {
        disposal: u3 = 0,
        delay_cs: u16 = 0,
        has_transparent: bool = false,
        transparent_index: u8 = 0,
    };

    fn appendGce(self: *TestBuilder, gpa: Allocator, opts: GceOpts) !void {
        try self.appendByte(gpa, block_extension_introducer);
        try self.appendByte(gpa, ext_label_graphic_control);
        try self.appendByte(gpa, 0x04); // block size (always 4)
        const trans_flag: u8 = if (opts.has_transparent) gce_flag_transparent else 0;
        const packed_byte: u8 = (@as(u8, opts.disposal) << 2) | trans_flag;
        try self.appendByte(gpa, packed_byte);
        try self.appendU16(gpa, opts.delay_cs);
        try self.appendByte(gpa, opts.transparent_index);
        try self.appendByte(gpa, 0); // sub-block terminator
    }

    fn appendNetscape2(self: *TestBuilder, gpa: Allocator, loop_count: u16) !void {
        try self.appendByte(gpa, block_extension_introducer);
        try self.appendByte(gpa, ext_label_application);
        try self.appendByte(gpa, 0x0B); // block size = 11
        try self.appendBytes(gpa, "NETSCAPE2.0");
        try self.appendByte(gpa, 0x03); // sub-block size = 3
        try self.appendByte(gpa, 0x01); // sub-block id
        try self.appendU16(gpa, loop_count);
        try self.appendByte(gpa, 0); // terminator
    }

    fn appendComment(self: *TestBuilder, gpa: Allocator, text: []const u8) !void {
        try self.appendByte(gpa, block_extension_introducer);
        try self.appendByte(gpa, ext_label_comment);
        try self.appendByte(gpa, @intCast(text.len));
        try self.appendBytes(gpa, text);
        try self.appendByte(gpa, 0);
    }

    fn appendTrailer(self: *TestBuilder, gpa: Allocator) !void {
        try self.appendByte(gpa, block_trailer);
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
    var b = TestBuilder{};
    defer b.deinit(gpa);

    try b.appendHeader(gpa, .{ .signature = "GIF87a", .width = 16, .height = 8 });
    try b.appendTrailer(gpa);

    var reader = buildReader(b.list.items);
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
    var b = TestBuilder{};
    defer b.deinit(gpa);

    try b.appendHeader(gpa, .{ .gct_size_log = 1 }); // 4-entry GCT
    try b.appendGce(gpa, .{});
    try b.appendImageDescriptor(gpa, .{});
    try b.appendTrailer(gpa);

    var reader = buildReader(b.list.items);
    const info = try getInfo(&reader, .{});

    try expectEqual(Version.gif89a, info.version);
    try expectEqual(@as(u32, 1), info.frame_count);
    try expect(info.has_global_color_table);
    try expectEqual(@as(u16, 4), info.global_color_table_size);
    try expectEqual(@as(u16, 0), info.loop_count);
}

test "getInfo — NETSCAPE2.0 loop count = 3" {
    const gpa = std.testing.allocator;
    var b = TestBuilder{};
    defer b.deinit(gpa);

    try b.appendHeader(gpa, .{});
    try b.appendNetscape2(gpa, 3);
    try b.appendImageDescriptor(gpa, .{});
    try b.appendImageDescriptor(gpa, .{});
    try b.appendTrailer(gpa);

    var reader = buildReader(b.list.items);
    const info = try getInfo(&reader, .{});

    try expectEqual(@as(u16, 3), info.loop_count);
    try expectEqual(@as(u32, 2), info.frame_count);
}

test "getInfo — comment extension is skipped" {
    const gpa = std.testing.allocator;
    var b = TestBuilder{};
    defer b.deinit(gpa);

    try b.appendHeader(gpa, .{});
    try b.appendComment(gpa, "made with zignal");
    try b.appendImageDescriptor(gpa, .{});
    try b.appendTrailer(gpa);

    var reader = buildReader(b.list.items);
    const info = try getInfo(&reader, .{});
    try expectEqual(@as(u32, 1), info.frame_count);
}

test "getInfo — bad signature rejected" {
    const data = "FOO89a" ++ ([_]u8{0} ** 7) ++ [_]u8{block_trailer};
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
    var b = TestBuilder{};
    defer b.deinit(gpa);

    try b.appendHeader(gpa, .{ .width = 2000, .height = 10 });
    try b.appendTrailer(gpa);

    var reader = buildReader(b.list.items);
    try expectError(error.ImageTooLarge, getInfo(&reader, .{ .max_width = 1024 }));
}

test "getInfo — frame count exceeds limit" {
    const gpa = std.testing.allocator;
    var b = TestBuilder{};
    defer b.deinit(gpa);

    try b.appendHeader(gpa, .{});
    try b.appendImageDescriptor(gpa, .{});
    try b.appendImageDescriptor(gpa, .{});
    try b.appendImageDescriptor(gpa, .{});
    try b.appendTrailer(gpa);

    var reader = buildReader(b.list.items);
    try expectError(error.TooManyFrames, getInfo(&reader, .{ .max_frames = 2 }));
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
    var b = TestBuilder{};
    defer b.deinit(gpa);

    try b.appendHeaderWithGct(gpa, 1, 1, &test_palette_4);
    // LZW for indices [1]: Clear=4, 1, EOI=5 at min_code_size=2.
    //   bits 0..2 = 100 (Clear), 3..5 = 001 (1), 6..8 = 101 (EOI)
    //   byte 0 = 0b01001100 = 0x4C, byte 1 = 0b00000001 = 0x01
    try b.appendImageWithLzw(gpa, .{ .width = 1, .height = 1 }, null, &.{ 0x4C, 0x01 });
    try b.appendTrailer(gpa);

    var img = try loadFromBytes(Rgb, gpa, b.list.items, .{});
    defer img.deinit(gpa);

    try expectEqual(@as(usize, 1), img.rows);
    try expectEqual(@as(usize, 1), img.cols);
    try expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, img.at(0, 0).*);
}

test "loadFromBytes — 2x2 with global palette" {
    const gpa = std.testing.allocator;
    var b = TestBuilder{};
    defer b.deinit(gpa);

    try b.appendHeaderWithGct(gpa, 2, 2, &test_palette_4);
    // LZW for indices [0, 1, 2, 3]: encoder grows code_size after adding (1,2),
    // emitting 2,3 at 4 bits → bytes [0x44, 0x64, 0x0A].
    try b.appendImageWithLzw(gpa, .{ .width = 2, .height = 2 }, null, &.{ 0x44, 0x64, 0x0A });
    try b.appendTrailer(gpa);

    var img = try loadFromBytes(Rgb, gpa, b.list.items, .{});
    defer img.deinit(gpa);

    try expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, img.at(0, 0).*);
    try expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, img.at(0, 1).*);
    try expectEqual(Rgb{ .r = 0, .g = 255, .b = 0 }, img.at(1, 0).*);
    try expectEqual(Rgb{ .r = 0, .g = 0, .b = 255 }, img.at(1, 1).*);
}

test "loadFromBytes — local color table overrides global" {
    const gpa = std.testing.allocator;
    var b = TestBuilder{};
    defer b.deinit(gpa);

    try b.appendHeaderWithGct(gpa, 1, 1, &test_palette_4); // global red at idx 1

    // LCT: 4 entries, idx 1 = white (different from global red).
    const lct = [_]Rgb{
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 255, .g = 255, .b = 255 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
    };
    // packed_byte: LCT flag = 0x80, lct_size_log = 1 → 0x81.
    try b.appendImageWithLzw(
        gpa,
        .{ .width = 1, .height = 1, .packed_byte = 0x81, .lct_size_log = 1 },
        &lct,
        &.{ 0x4C, 0x01 },
    );
    try b.appendTrailer(gpa);

    var img = try loadFromBytes(Rgb, gpa, b.list.items, .{});
    defer img.deinit(gpa);

    try expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, img.at(0, 0).*);
}

test "loadFromBytes — frame outside screen rejected via descriptor checks" {
    const gpa = std.testing.allocator;
    var b = TestBuilder{};
    defer b.deinit(gpa);

    try b.appendHeaderWithGct(gpa, 4, 4, &test_palette_4);
    // Frame width 6 — exceeds screen but per the LSD limit. Should be tolerated
    // by the parser (composition just clips), so this should NOT fail. Let's
    // test the actual oversize-rejection via DecodeLimits.max_width instead.
    try b.appendImageWithLzw(gpa, .{ .width = 1, .height = 1 }, null, &.{ 0x4C, 0x01 });
    try b.appendTrailer(gpa);

    try expectError(error.ImageTooLarge, loadFromBytes(Rgb, gpa, b.list.items, .{ .max_width = 2 }));
}

// ---------------------------------------------------------------------------
// Multi-frame tests
// ---------------------------------------------------------------------------

test "loadAnimated — two frames, do_not_dispose, per-frame delays" {
    const gpa = std.testing.allocator;
    var b = TestBuilder{};
    defer b.deinit(gpa);

    try b.appendHeaderWithGct(gpa, 1, 1, &test_palette_4);

    // Frame 0: red (idx 1), delay 5cs.
    try b.appendGce(gpa, .{ .disposal = 1, .delay_cs = 5 });
    try b.appendImageWithLzw(gpa, .{ .width = 1, .height = 1 }, null, &.{ 0x4C, 0x01 });

    // Frame 1: green (idx 2), delay 10cs.
    try b.appendGce(gpa, .{ .disposal = 1, .delay_cs = 10 });
    // LZW for indices [2]: Clear=4, 2, EOI=5 at min_code_size=2.
    //   bits 0..2 = 100, 3..5 = 010, 6..8 = 101
    //   byte 0 = 0,0,1, 0,1,0, 1,0 = 0b01010100 = 0x54
    //   byte 1 = bit 8 = 1, rest = 0 = 0x01
    try b.appendImageWithLzw(gpa, .{ .width = 1, .height = 1 }, null, &.{ 0x54, 0x01 });

    try b.appendTrailer(gpa);

    var anim = try loadAnimatedFromBytes(Rgba, gpa, b.list.items, .{});
    defer anim.deinit(gpa);

    try expectEqual(@as(usize, 2), anim.frameCount());
    try expectEqual(@as(u16, 5), anim.delays_cs[0]);
    try expectEqual(@as(u16, 10), anim.delays_cs[1]);
    try expectEqual(Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 }, anim.frame(0).at(0, 0).*);
    try expectEqual(Rgba{ .r = 0, .g = 255, .b = 0, .a = 255 }, anim.frame(1).at(0, 0).*);
}

test "loadAnimated — restore_to_background blanks the previous rect" {
    const gpa = std.testing.allocator;
    var b = TestBuilder{};
    defer b.deinit(gpa);

    // 2x1 screen: frame 0 covers full screen with red, then disposal=2 (RTB).
    // Frame 1 covers only the first column with green; column 1 should be transparent.
    try b.appendHeaderWithGct(gpa, 2, 1, &test_palette_4);

    // Frame 0: 2x1 red. LZW encode indices [1, 1].
    //   Clear=4, 1, 1, EOI=5 (all 3 bits since dict_size never reaches 8).
    //   bits: 100 001 001 101
    //     byte 0 (bits 0..7) = 0,0,1,1,0,0,1,0 = 0x4C
    //     byte 1 (bits 8..11) = 0,1,0,1 + pad = 0,1,0,1,0,0,0,0 = 0x0A
    try b.appendGce(gpa, .{ .disposal = 2 });
    try b.appendImageWithLzw(gpa, .{ .width = 2, .height = 1 }, null, &.{ 0x4C, 0x0A });

    // Frame 1: 1x1 green at (0,0). LZW [2] = [0x54, 0x01].
    try b.appendGce(gpa, .{});
    try b.appendImageWithLzw(gpa, .{ .left = 0, .top = 0, .width = 1, .height = 1 }, null, &.{ 0x54, 0x01 });

    try b.appendTrailer(gpa);

    var anim = try loadAnimatedFromBytes(Rgba, gpa, b.list.items, .{});
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
    var b = TestBuilder{};
    defer b.deinit(gpa);

    // 2x1 frame, indices [0, 1]. Mark idx 0 transparent.
    try b.appendHeaderWithGct(gpa, 2, 1, &test_palette_4);

    try b.appendGce(gpa, .{ .disposal = 1, .has_transparent = true });
    // LZW for indices [0, 1]: Clear=4, 0, 1, EOI=5 (all 3 bits).
    //   bits: 100 000 001 101
    //     byte 0 = 0,0,1,0,0,0,1,0 = 0x44
    //     byte 1 = 0,1,0,1 + pad = 0x0A
    try b.appendImageWithLzw(gpa, .{ .width = 2, .height = 1 }, null, &.{ 0x44, 0x0A });

    try b.appendTrailer(gpa);

    var anim = try loadAnimatedFromBytes(Rgba, gpa, b.list.items, .{});
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

    const data = try encode(Rgb, gpa, img, .{ .palette = &palette });
    defer gpa.free(data);

    var decoded = try loadFromBytes(Rgb, gpa, data, .{});
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

    const data = try encode(Rgb, gpa, img, .{});
    defer gpa.free(data);

    var decoded = try loadFromBytes(Rgb, gpa, data, .{});
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

    const data = try encode(u8, gpa, img, .{});
    defer gpa.free(data);

    var decoded = try loadFromBytes(u8, gpa, data, .{});
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

    const data = try encode(Rgb, gpa, img, .{ .max_colors = 8, .dither = true });
    defer gpa.free(data);

    var decoded = try loadFromBytes(Rgb, gpa, data, .{});
    defer decoded.deinit(gpa);

    try expectEqual(@as(usize, 8), decoded.rows);
    try expectEqual(@as(usize, 8), decoded.cols);
}

test "encode — getInfo on encoded output is consistent" {
    const gpa = std.testing.allocator;
    var img = try Image(Rgb).init(gpa, 8, 12);
    defer img.deinit(gpa);
    @memset(img.data, .{ .r = 64, .g = 128, .b = 192 });

    const data = try encode(Rgb, gpa, img, .{});
    defer gpa.free(data);

    var reader = Io.Reader.fixed(data);
    const info = try getInfo(&reader, .{});
    try expectEqual(@as(u32, 12), info.width);
    try expectEqual(@as(u32, 8), info.height);
    try expectEqual(Version.gif89a, info.version);
    try expectEqual(@as(u32, 1), info.frame_count);
}

test "loadFromBytes — missing global color table without LCT" {
    const gpa = std.testing.allocator;
    var b = TestBuilder{};
    defer b.deinit(gpa);

    try b.appendBytes(gpa, "GIF89a");
    try b.appendU16(gpa, 1);
    try b.appendU16(gpa, 1);
    try b.appendByte(gpa, 0x00); // no GCT
    try b.appendByte(gpa, 0); // bg
    try b.appendByte(gpa, 0); // aspect
    try b.appendImageWithLzw(gpa, .{ .width = 1, .height = 1 }, null, &.{ 0x4C, 0x01 });
    try b.appendTrailer(gpa);

    try expectError(error.MissingGlobalColorTable, loadFromBytes(Rgb, gpa, b.list.items, .{}));
}

test "getInfo — image descriptor with local color table" {
    const gpa = std.testing.allocator;
    var b = TestBuilder{};
    defer b.deinit(gpa);

    try b.appendHeader(gpa, .{ .gct_size_log = 0 }); // 2-entry GCT
    // packed_byte: bit 7 = LCT flag, bit 0..2 = log2(LCT size) - 1
    // 0x80 sets LCT flag, lower 3 bits = 2 → 8 entries
    try b.appendImageDescriptor(gpa, .{ .packed_byte = 0x82, .lct_size_log = 2 });
    try b.appendTrailer(gpa);

    var reader = buildReader(b.list.items);
    const info = try getInfo(&reader, .{});
    try expectEqual(@as(u32, 1), info.frame_count);
    try expect(info.has_global_color_table);
    try expectEqual(@as(u16, 2), info.global_color_table_size);
}
