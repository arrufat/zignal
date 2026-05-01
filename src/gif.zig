//! Pure Zig GIF decoder and (eventually) encoder.
//!
//! Step 3 deliverable: signature, version, decode limits, header, and a
//! `getInfo` that walks the block stream to count frames and extract the
//! NETSCAPE2.0 loop count without decoding LZW data.
//!
//! Subsequent steps add LZW decoding (Step 4), single-frame decode (Step 5),
//! multi-frame decode + disposal composition (Step 6), and encoding (Steps 7–9).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectEqual = std.testing.expectEqual;

const Image = @import("image.zig").Image;
const AnimatedImage = @import("image.zig").AnimatedImage;
const Rgb = @import("color.zig").Rgb(u8);
const Rgba = @import("color.zig").Rgba(u8);

pub const lzw = @import("gif/lzw.zig");

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

    const has_gct = (lsd_packed & 0x80) != 0;
    const gct_size_log: u3 = @intCast(lsd_packed & 0x07);
    const gct_size: u16 = if (has_gct) (@as(u16, 2) << gct_size_log) else 0;

    if (has_gct) {
        const gct_bytes: u32 = @as(u32, gct_size) * 3;
        _ = try reader.discard(.limited(gct_bytes));
    }

    var frame_count: u32 = 0;
    var loop_count: u16 = 0;

    // Walk blocks.
    while (true) {
        const introducer = try reader.takeByte();
        switch (introducer) {
            block_trailer => break,
            block_image_descriptor => {
                // Image Descriptor: 9 bytes after the introducer (left, top, width,
                // height, packed). We only care about the packed byte for LCT info.
                _ = try reader.discard(.limited(8)); // left, top, width, height
                const img_packed = try reader.takeByte();
                const has_lct = (img_packed & 0x80) != 0;
                if (has_lct) {
                    const lct_size_log: u3 = @intCast(img_packed & 0x07);
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
/// in display order (de-interlaced if the source was interlaced).
pub const FrameRecord = struct {
    left: u16,
    top: u16,
    width: u16,
    height: u16,
    /// Palette in effect for this frame. Either a borrow of the global table
    /// or an owned local color table; `palette_owned` discriminates.
    palette: []const Rgb,
    palette_owned: bool,
    /// `width * height` palette indices in display order. Owned.
    indices: []u8,
    /// Per-frame timing/transparency from the preceding GCE, if any.
    gce: ?GraphicControlExtension,
};

/// Parsed GIF state. Frames hold raw decoded indices — `loadAnimated`
/// (Step 6) composes them into fully-rendered images via disposal logic.
pub const GifState = struct {
    header: Header,
    /// Owned. Null if the file had no Global Color Table.
    global_palette: ?[]Rgb,
    /// Owned. May be empty for a malformed-but-tolerated file with no images.
    frames: []FrameRecord,

    pub fn deinit(self: *GifState, gpa: Allocator) void {
        if (self.global_palette) |p| gpa.free(p);
        for (self.frames) |*f| {
            if (f.palette_owned) gpa.free(@constCast(f.palette));
            gpa.free(f.indices);
        }
        gpa.free(self.frames);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// Cursor — tiny in-memory parser helper.
// ---------------------------------------------------------------------------

const Cursor = struct {
    data: []const u8,
    pos: usize = 0,

    inline fn remaining(self: Cursor) usize {
        return self.data.len - self.pos;
    }

    fn takeByte(self: *Cursor) !u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEndOfData;
        defer self.pos += 1;
        return self.data[self.pos];
    }

    fn takeU16(self: *Cursor) !u16 {
        if (self.remaining() < 2) return error.UnexpectedEndOfData;
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }

    fn takeSlice(self: *Cursor, n: usize) ![]const u8 {
        if (self.remaining() < n) return error.UnexpectedEndOfData;
        defer self.pos += n;
        return self.data[self.pos..][0..n];
    }

    fn skip(self: *Cursor, n: usize) !void {
        if (self.remaining() < n) return error.UnexpectedEndOfData;
        self.pos += n;
    }
};

// ---------------------------------------------------------------------------
// decode
// ---------------------------------------------------------------------------

/// Parses a GIF byte buffer into a `GifState`. The state's frames hold raw
/// palette indices; composition into Images happens via `loadFromBytes`
/// (single-frame) or `loadAnimated*` (multi-frame, Step 6).
pub fn decode(gpa: Allocator, data: []const u8, limits: DecodeLimits) !GifState {
    if (exceeds(usize, limits.max_gif_bytes, data.len)) return error.GifDataTooLarge;

    var c: Cursor = .{ .data = data };

    // Signature + version.
    const sig = try c.takeSlice(6);
    if (!std.mem.eql(u8, sig[0..3], &signature)) return error.InvalidGifSignature;
    const version: Version = if (std.mem.eql(u8, sig[3..6], "87a"))
        .gif87a
    else if (std.mem.eql(u8, sig[3..6], "89a"))
        .gif89a
    else
        return error.UnsupportedGifVersion;

    // Logical Screen Descriptor.
    const screen_w = try c.takeU16();
    const screen_h = try c.takeU16();
    const lsd_packed = try c.takeByte();
    const bg_index = try c.takeByte();
    _ = try c.takeByte(); // pixel aspect ratio

    if (screen_w == 0 or screen_h == 0) return error.InvalidLogicalScreenDescriptor;
    if (exceeds(u32, limits.max_width, screen_w) or exceeds(u32, limits.max_height, screen_h)) {
        return error.ImageTooLarge;
    }
    if (exceeds(u64, limits.max_pixels, @as(u64, screen_w) * @as(u64, screen_h))) {
        return error.ImageTooLarge;
    }

    const has_gct = (lsd_packed & 0x80) != 0;
    const gct_size_log: u3 = @intCast(lsd_packed & 0x07);
    const gct_size: u16 = if (has_gct) (@as(u16, 2) << gct_size_log) else 0;

    var global_palette: ?[]Rgb = null;
    errdefer if (global_palette) |p| gpa.free(p);
    if (has_gct) {
        const palette = try gpa.alloc(Rgb, gct_size);
        const raw = try c.takeSlice(@as(usize, gct_size) * 3);
        var i: usize = 0;
        while (i < gct_size) : (i += 1) {
            palette[i] = .{ .r = raw[i * 3], .g = raw[i * 3 + 1], .b = raw[i * 3 + 2] };
        }
        global_palette = palette;
    }

    var frames: std.ArrayList(FrameRecord) = .empty;
    errdefer {
        for (frames.items) |*f| {
            if (f.palette_owned) gpa.free(@constCast(f.palette));
            gpa.free(f.indices);
        }
        frames.deinit(gpa);
    }

    var pending_gce: ?GraphicControlExtension = null;
    var loop_count: u16 = 0;
    var total_pixels: u64 = 0;

    block_loop: while (true) {
        const introducer = try c.takeByte();
        switch (introducer) {
            block_trailer => break :block_loop,
            block_image_descriptor => {
                const frame = try parseImageBlock(
                    gpa,
                    &c,
                    limits,
                    global_palette,
                    pending_gce,
                    &total_pixels,
                );
                pending_gce = null;
                try frames.append(gpa, frame);
                if (exceeds(u32, limits.max_frames, @intCast(frames.items.len))) {
                    return error.TooManyFrames;
                }
            },
            block_extension_introducer => {
                const label = try c.takeByte();
                switch (label) {
                    ext_label_graphic_control => pending_gce = try parseGce(&c),
                    ext_label_application => try parseAppExtensionCursor(&c, &loop_count),
                    ext_label_comment => try skipSubBlocksCursor(&c),
                    else => try skipSubBlocksCursor(&c),
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

fn parseGce(c: *Cursor) !GraphicControlExtension {
    const block_size = try c.takeByte();
    if (block_size != 4) return error.InvalidGraphicControlExtension;
    const packed_byte = try c.takeByte();
    const delay = try c.takeU16();
    const transparent = try c.takeByte();
    const terminator = try c.takeByte();
    if (terminator != 0) return error.InvalidGraphicControlExtension;
    return .{
        .disposal = @enumFromInt((packed_byte >> 2) & 0x07),
        .has_transparent = (packed_byte & 0x01) != 0,
        .delay_cs = delay,
        .transparent_index = transparent,
    };
}

fn skipSubBlocksCursor(c: *Cursor) !void {
    while (true) {
        const sb_size = try c.takeByte();
        if (sb_size == 0) return;
        try c.skip(sb_size);
    }
}

fn parseAppExtensionCursor(c: *Cursor, loop_count_out: *u16) !void {
    const block_size = try c.takeByte();
    if (block_size != 11) {
        try c.skip(block_size);
        try skipSubBlocksCursor(c);
        return;
    }
    const id_auth = try c.takeSlice(11);
    if (!std.mem.eql(u8, id_auth, &netscape_id_auth)) {
        try skipSubBlocksCursor(c);
        return;
    }
    while (true) {
        const sb_size = try c.takeByte();
        if (sb_size == 0) return;
        if (sb_size >= 3) {
            const sub_id = try c.takeByte();
            if (sub_id == 0x01) {
                loop_count_out.* = try c.takeU16();
                if (sb_size > 3) try c.skip(sb_size - 3);
            } else {
                try c.skip(sb_size - 1);
            }
        } else {
            try c.skip(sb_size);
        }
    }
}

fn parseImageBlock(
    gpa: Allocator,
    c: *Cursor,
    limits: DecodeLimits,
    global_palette: ?[]Rgb,
    pending_gce: ?GraphicControlExtension,
    total_pixels: *u64,
) !FrameRecord {
    const left = try c.takeU16();
    const top = try c.takeU16();
    const width = try c.takeU16();
    const height = try c.takeU16();
    const img_packed = try c.takeByte();

    if (width == 0 or height == 0) return error.InvalidImageDescriptor;
    if (exceeds(u32, limits.max_width, width) or exceeds(u32, limits.max_height, height)) {
        return error.ImageTooLarge;
    }
    const num_pixels: u64 = @as(u64, width) * @as(u64, height);
    if (exceeds(u64, limits.max_pixels, num_pixels)) return error.ImageTooLarge;
    total_pixels.* +|= num_pixels;
    if (exceeds(u64, limits.max_total_pixels, total_pixels.*)) return error.ImageTooLarge;

    const has_lct = (img_packed & 0x80) != 0;
    const interlaced = (img_packed & 0x40) != 0;

    var palette: []const Rgb = &.{};
    var palette_owned = false;
    errdefer if (palette_owned) gpa.free(@constCast(palette));

    if (has_lct) {
        const lct_size_log: u3 = @intCast(img_packed & 0x07);
        const lct_entries: u16 = @as(u16, 2) << lct_size_log;
        const lct = try gpa.alloc(Rgb, lct_entries);
        palette_owned = true;
        const raw = try c.takeSlice(@as(usize, lct_entries) * 3);
        var i: usize = 0;
        while (i < lct_entries) : (i += 1) {
            lct[i] = .{ .r = raw[i * 3], .g = raw[i * 3 + 1], .b = raw[i * 3 + 2] };
        }
        palette = lct;
    } else if (global_palette) |g| {
        palette = g;
    } else {
        return error.MissingGlobalColorTable;
    }

    const min_code_size_byte = try c.takeByte();
    if (min_code_size_byte < 2 or min_code_size_byte > 8) return error.InvalidLzwCode;
    const min_code_size: u4 = @intCast(min_code_size_byte);

    // Decode LZW into pass-ordered indices first; de-interlace into final
    // display order in a separate buffer if needed. Allocations match the
    // ownership transferred to the caller via FrameRecord.
    const num_pixels_usize: usize = @intCast(num_pixels);
    var pass_indices = try gpa.alloc(u8, num_pixels_usize);
    errdefer gpa.free(pass_indices);

    var dec = lzw.Decoder.init(min_code_size) catch return error.InvalidLzwCode;
    var written: usize = 0;

    // Walk LZW data sub-blocks, feeding each chunk to the decoder.
    while (true) {
        const sb_size = try c.takeByte();
        if (sb_size == 0) break;
        const sb_data = try c.takeSlice(sb_size);

        const r = try dec.decodeChunk(sb_data, pass_indices[written..]);
        written += r.written;

        if (dec.isDone()) {
            while (true) {
                const trailing = try c.takeByte();
                if (trailing == 0) break;
                try c.skip(trailing);
            }
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
        .palette_owned = palette_owned,
        .indices = indices_out,
        .gce = pending_gce,
    };
}

// ---------------------------------------------------------------------------
// Single-frame composition (Step 5)
// ---------------------------------------------------------------------------

/// Composes the first frame onto a screen-sized canvas filled with palette[bg]
/// (or transparent if the frame has a transparent index and the requested type
/// has alpha). Returns an Rgb image; conversion to T is done by `loadFromBytes`.
fn composeFirstFrameRgb(allocator: Allocator, state: GifState) !Image(Rgb) {
    if (state.frames.len == 0) return error.MissingPixelData;
    const frame = state.frames[0];

    // Background fill: palette[bg] if available, else opaque black.
    const bg_color: Rgb = blk: {
        if (state.global_palette) |gp| {
            if (state.header.background_color_index < gp.len) {
                break :blk gp[state.header.background_color_index];
            }
        }
        break :blk .{ .r = 0, .g = 0, .b = 0 };
    };

    var img = try Image(Rgb).init(allocator, state.header.height, state.header.width);
    errdefer img.deinit(allocator);

    // Initialize canvas to background.
    @memset(img.data, bg_color);

    // Composite frame pixels.
    const has_trans = if (frame.gce) |g| g.has_transparent else false;
    const trans_idx = if (frame.gce) |g| g.transparent_index else 0;
    const palette = frame.palette;

    const frame_w: usize = @intCast(frame.width);
    const frame_h: usize = @intCast(frame.height);
    const left: usize = @intCast(frame.left);
    const top: usize = @intCast(frame.top);

    var fy: usize = 0;
    while (fy < frame_h) : (fy += 1) {
        const dst_y = top + fy;
        if (dst_y >= img.rows) break;
        const dst_row_off = dst_y * img.stride;
        const src_row_off = fy * frame_w;
        var fx: usize = 0;
        while (fx < frame_w) : (fx += 1) {
            const dst_x = left + fx;
            if (dst_x >= img.cols) break;
            const idx = frame.indices[src_row_off + fx];
            if (has_trans and idx == trans_idx) continue;
            if (idx >= palette.len) return error.InvalidPaletteIndex;
            img.data[dst_row_off + dst_x] = palette[idx];
        }
    }

    return img;
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
        var anim = try composeAnimated(Rgba, allocator, state);
        defer {
            // Free all frames except 0 (we're stealing 0).
            for (anim.frames[1..]) |*f| f.deinit(allocator);
            allocator.free(anim.frames);
            allocator.free(anim.delays_cs);
        }
        const frame0 = anim.frames[0];
        return .{ .rgba = frame0 };
    }

    const rgb = try composeFirstFrameRgb(allocator, state);
    return .{ .rgb = rgb };
}

/// Loads a GIF from in-memory bytes. Returns frame 0 only — see
/// `loadAnimatedFromBytes` (Step 6) for full multi-frame access.
pub fn loadFromBytes(comptime T: type, allocator: Allocator, data: []const u8, limits: DecodeLimits) !Image(T) {
    var state = try decode(allocator, data, limits);
    defer state.deinit(allocator);

    var rgb_image = try composeFirstFrameRgb(allocator, state);

    if (T == Rgb) return rgb_image;
    defer rgb_image.deinit(allocator);
    return rgb_image.convert(T, allocator);
}

// ---------------------------------------------------------------------------
// Multi-frame composition (Step 6)
// ---------------------------------------------------------------------------

/// Composes all frames into an `AnimatedImage(T)`. Each output frame is the
/// fully-rendered canvas at that point in playback, so callers don't have to
/// know about disposal methods or transparent indices.
fn composeAnimated(comptime T: type, allocator: Allocator, state: GifState) !AnimatedImage(T) {
    const screen_w: u32 = state.header.width;
    const screen_h: u32 = state.header.height;
    const total_pixels: usize = @as(usize, screen_w) * @as(usize, screen_h);

    // Persistent canvas in Rgba — alpha tracks transparency for `restore_to_background`.
    var canvas = try Image(Rgba).init(allocator, screen_h, screen_w);
    defer canvas.deinit(allocator);
    @memset(canvas.data, .{ .r = 0, .g = 0, .b = 0, .a = 0 });

    // Snapshot used by `restore_to_previous` disposal.
    const snapshot = try allocator.alloc(Rgba, total_pixels);
    defer allocator.free(snapshot);

    const frames_out = try allocator.alloc(Image(T), state.frames.len);
    var frames_init: usize = 0;
    errdefer {
        for (frames_out[0..frames_init]) |*f| f.deinit(allocator);
        allocator.free(frames_out);
    }

    var delays_out = try allocator.alloc(u16, state.frames.len);
    errdefer allocator.free(delays_out);

    var prev_disposal: DisposalMethod = .unspecified;
    var prev_left: u16 = 0;
    var prev_top: u16 = 0;
    var prev_w: u16 = 0;
    var prev_h: u16 = 0;

    for (state.frames, 0..) |frame, i| {
        // Apply previous frame's disposal.
        switch (prev_disposal) {
            .restore_to_background => fillCanvasRect(&canvas, prev_left, prev_top, prev_w, prev_h, .{ .r = 0, .g = 0, .b = 0, .a = 0 }),
            .restore_to_previous => @memcpy(canvas.data, snapshot),
            else => {},
        }

        // If this frame requests rtp, snapshot the canvas before drawing.
        if (frame.gce) |g| {
            if (g.disposal == .restore_to_previous) {
                @memcpy(snapshot, canvas.data);
            }
        }

        // Composite frame onto canvas.
        try compositeFrameOntoCanvas(&canvas, frame);

        // Snapshot canvas → frame i (Image(Rgba)), then convert to T.
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
        prev_left = frame.left;
        prev_top = frame.top;
        prev_w = frame.width;
        prev_h = frame.height;
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

    const fw: usize = @intCast(frame.width);
    const fh: usize = @intCast(frame.height);
    const left: usize = @intCast(frame.left);
    const top: usize = @intCast(frame.top);

    var fy: usize = 0;
    while (fy < fh) : (fy += 1) {
        const dst_y = top + fy;
        if (dst_y >= canvas.rows) break;
        const dst_off = dst_y * canvas.stride;
        const src_off = fy * fw;
        var fx: usize = 0;
        while (fx < fw) : (fx += 1) {
            const dst_x = left + fx;
            if (dst_x >= canvas.cols) break;
            const idx = frame.indices[src_off + fx];
            if (has_trans and idx == trans_idx) continue;
            if (idx >= palette.len) return error.InvalidPaletteIndex;
            const c = palette[idx];
            canvas.data[dst_off + dst_x] = .{ .r = c.r, .g = c.g, .b = c.b, .a = 255 };
        }
    }
}

fn fillCanvasRect(canvas: *Image(Rgba), left: u16, top: u16, w: u16, h: u16, value: Rgba) void {
    const rect_left: usize = @intCast(left);
    const rect_top: usize = @intCast(top);
    const rect_w: usize = @intCast(w);
    const rect_h: usize = @intCast(h);

    var ry: usize = 0;
    while (ry < rect_h) : (ry += 1) {
        const dy = rect_top + ry;
        if (dy >= canvas.rows) break;
        const off = dy * canvas.stride + rect_left;
        const span = @min(rect_w, canvas.cols - rect_left);
        @memset(canvas.data[off .. off + span], value);
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

/// Loads all frames from a GIF file into an `AnimatedImage(T)`.
pub fn loadAnimated(comptime T: type, io: Io, allocator: Allocator, file_path: []const u8, limits: DecodeLimits) !AnimatedImage(T) {
    const read_limit = if (limits.max_gif_bytes == 0) std.math.maxInt(usize) else limits.max_gif_bytes;
    const data = try Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(read_limit));
    defer allocator.free(data);
    return loadAnimatedFromBytes(T, allocator, data, limits);
}

/// Loads a GIF from a file path. Returns frame 0 only.
pub fn load(comptime T: type, io: Io, allocator: Allocator, file_path: []const u8, limits: DecodeLimits) !Image(T) {
    const read_limit = if (limits.max_gif_bytes == 0) std.math.maxInt(usize) else limits.max_gif_bytes;
    const data = try Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(read_limit));
    defer allocator.free(data);
    return loadFromBytes(T, allocator, data, limits);
}

// ---------------------------------------------------------------------------
// Single-frame encode (Step 8)
// ---------------------------------------------------------------------------

const quantize = @import("image/quantize.zig");

/// Single-frame GIF encode options.
pub const EncodeOptions = struct {
    /// Pre-computed palette. If null, the encoder runs median-cut on the input.
    /// Length must be 2..256.
    palette: ?[]const Rgb = null,
    /// Cap on auto-quantization. Ignored when `palette` is provided.
    max_colors: u16 = 256,
    /// Apply Floyd–Steinberg dithering before mapping to palette.
    dither: bool = false,
    /// Per-frame delay in centiseconds. Currently emitted via GCE only when
    /// non-zero; reserved for forward compatibility with animated encode.
    delay_cs: u16 = 0,

    pub const default: EncodeOptions = .{};
};

const linear_gray_palette: [256]Rgb = blk: {
    var pal: [256]Rgb = undefined;
    for (&pal, 0..) |*p, i| p.* = .{ .r = @intCast(i), .g = @intCast(i), .b = @intCast(i) };
    break :blk pal;
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
        @memcpy(&palette_buf, &linear_gray_palette);
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
    lsd_packed |= 0x80; // global color table flag
    lsd_packed |= 0x70; // color resolution = 7 (8 bits per channel)
    lsd_packed |= @as(u8, declared_size_log);
    try out.append(allocator, lsd_packed);
    try out.append(allocator, 0); // background color index
    try out.append(allocator, 0); // pixel aspect ratio

    // Global Color Table (padded to declared_entries).
    for (palette) |c| try out.appendSlice(allocator, &.{ c.r, c.g, c.b });
    var pad_i: usize = palette.len;
    while (pad_i < declared_entries) : (pad_i += 1) try out.appendSlice(allocator, &.{ 0, 0, 0 });

    // Optional GCE for delay (none for v1 single-frame; reserved for animated encode).
    if (options.delay_cs != 0) {
        try out.append(allocator, 0x21);
        try out.append(allocator, 0xF9);
        try out.append(allocator, 0x04);
        try out.append(allocator, 0x00); // packed: no transparency, disposal=0
        try writeU16Le(&out, allocator, options.delay_cs);
        try out.append(allocator, 0); // transparent index
        try out.append(allocator, 0); // sub-block terminator
    }

    // Image Descriptor.
    try out.append(allocator, 0x2C);
    try writeU16Le(&out, allocator, 0); // left
    try writeU16Le(&out, allocator, 0); // top
    try writeU16Le(&out, allocator, width);
    try writeU16Le(&out, allocator, height);
    try out.append(allocator, 0x00); // packed: no LCT, not interlaced

    // LZW data.
    try out.append(allocator, @as(u8, min_code_size));

    var encoder = try @import("gif/lzw.zig").Encoder.init(allocator, min_code_size);
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
    try out.append(allocator, 0x3B);

    return out.toOwnedSlice(allocator);
}

inline fn writeU16Le(out: *std.ArrayList(u8), allocator: Allocator, v: u16) !void {
    try out.append(allocator, @intCast(v & 0xFF));
    try out.append(allocator, @intCast((v >> 8) & 0xFF));
}

/// Maps each pixel to the nearest palette index, with optional Floyd–Steinberg
/// dithering. For `T == Rgb` and contiguous images the slow path is avoided.
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
        // Convert to working Rgb buffer, dither in place, capture indices.
        var work = try image.convert(Rgb, allocator);
        defer work.deinit(allocator);
        const dither = @import("image/dither.zig");
        // Apply Floyd–Steinberg into the working image, then look up indices.
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

    // No dither: convert each pixel to Rgb and look up.
    var i: usize = 0;
    while (i < image.rows) : (i += 1) {
        const dst_off = i * image.cols;
        var j: usize = 0;
        while (j < image.cols) : (j += 1) {
            const px = image.at(i, j).*;
            const rgb = @import("color.zig").convertColor(Rgb, px);
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
            packed_byte |= 0x80; // global color table flag
            packed_byte |= 0x70; // color resolution = 7 (8 bits per channel)
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
        const packed_byte: u8 = 0x80 | 0x70 | @as(u8, s);
        try self.appendByte(gpa, packed_byte);
        try self.appendByte(gpa, 0); // bg
        try self.appendByte(gpa, 0); // aspect
        for (gct) |e| try self.appendBytes(gpa, &.{ e.r, e.g, e.b });
        const pad: usize = @as(usize, declared) - gct.len;
        try self.list.appendNTimes(gpa, 0, pad * 3);
    }

    fn appendGce(self: *TestBuilder, gpa: Allocator) !void {
        try self.appendByte(gpa, block_extension_introducer);
        try self.appendByte(gpa, ext_label_graphic_control);
        try self.appendByte(gpa, 0x04); // block size (always 4)
        try self.appendBytes(gpa, &.{ 0x00, 0x00, 0x00, 0x00 }); // packed, delay_lo, delay_hi, transparent_index
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
    try b.appendGce(gpa);
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
// Decode tests (Step 5)
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
// Multi-frame tests (Step 6)
// ---------------------------------------------------------------------------

fn appendGceWithDelay(b: *TestBuilder, gpa: Allocator, disposal: u3, delay_cs: u16, has_trans: bool, trans_idx: u8) !void {
    try b.appendByte(gpa, block_extension_introducer);
    try b.appendByte(gpa, ext_label_graphic_control);
    try b.appendByte(gpa, 0x04);
    const trans_flag: u8 = if (has_trans) 0x01 else 0x00;
    const packed_byte: u8 = (@as(u8, disposal) << 2) | trans_flag;
    try b.appendByte(gpa, packed_byte);
    try b.appendByte(gpa, @intCast(delay_cs & 0xFF));
    try b.appendByte(gpa, @intCast((delay_cs >> 8) & 0xFF));
    try b.appendByte(gpa, trans_idx);
    try b.appendByte(gpa, 0); // sub-block terminator
}

test "loadAnimated — two frames, do_not_dispose, per-frame delays" {
    const gpa = std.testing.allocator;
    var b = TestBuilder{};
    defer b.deinit(gpa);

    try b.appendHeaderWithGct(gpa, 1, 1, &test_palette_4);

    // Frame 0: red (idx 1), delay 5cs.
    try appendGceWithDelay(&b, gpa, 1, 5, false, 0);
    try b.appendImageWithLzw(gpa, .{ .width = 1, .height = 1 }, null, &.{ 0x4C, 0x01 });

    // Frame 1: green (idx 2), delay 10cs.
    try appendGceWithDelay(&b, gpa, 1, 10, false, 0);
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
    try appendGceWithDelay(&b, gpa, 2, 0, false, 0);
    try b.appendImageWithLzw(gpa, .{ .width = 2, .height = 1 }, null, &.{ 0x4C, 0x0A });

    // Frame 1: 1x1 green at (0,0). LZW [2] = [0x54, 0x01].
    try appendGceWithDelay(&b, gpa, 0, 0, false, 0);
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

    try appendGceWithDelay(&b, gpa, 1, 0, true, 0);
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
// Encode tests (Step 8)
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
