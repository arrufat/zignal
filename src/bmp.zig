//! Pure Zig BMP encoder and decoder.
//!
//! Decoder coverage:
//!   - BITMAPCOREHEADER (OS/2 v1, 12B), BITMAPINFOHEADER (40B), V4 (108B), V5 (124B).
//!     v2 (52B) and v3 (56B) are tolerated as extended INFOHEADER variants.
//!   - 1, 4, 8, 16, 24, 32 bpp.
//!   - BI_RGB, BI_BITFIELDS, BI_ALPHABITFIELDS, BI_RLE4, BI_RLE8.
//!   - Bottom-up and top-down row order.
//!
//! Encoder coverage (deliberately narrow for max reader compatibility):
//!   - 24bpp BI_RGB for `Image(Rgb)` and any non-supported pixel type (after color conversion).
//!   - 32bpp BI_BITFIELDS for `Image(Rgba)` with canonical RGBA masks.
//!   - 8bpp indexed with linear gray palette for `Image(u8)` when explicitly requested.
//!
//! Refused: BI_JPEG, BI_PNG, CMYK variants.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const convertColor = @import("color.zig").convertColor;
const Image = @import("image.zig").Image;
const Rgb = @import("color.zig").Rgb(u8);
const Rgba = @import("color.zig").Rgba(u8);

/// BMP file signature: "BM".
pub const signature = [_]u8{ 'B', 'M' };

const max_file_size_default: usize = 100 * 1024 * 1024;
const max_dimensions_default: u32 = 8192;
const max_pixels_default: u64 = 67_108_864; // 8K x 8K
const max_palette_entries_default: u32 = 256;

/// Resource limits applied while decoding BMP data. A zero value disables the
/// corresponding limit.
pub const DecodeLimits = struct {
    /// Maximum number of bytes accepted in the original BMP buffer.
    max_bmp_bytes: usize = max_file_size_default,
    /// Maximum allowed width in pixels.
    max_width: u32 = max_dimensions_default,
    /// Maximum allowed height in pixels.
    max_height: u32 = max_dimensions_default,
    /// Maximum allowed pixel count (width * height).
    max_pixels: u64 = max_pixels_default,
    /// Maximum number of palette entries.
    max_palette_entries: u32 = max_palette_entries_default,
};

/// DIB header variants, discriminated by the leading 4-byte size field.
pub const DibHeaderKind = enum(u32) {
    core = 12, // BITMAPCOREHEADER (OS/2 v1)
    info = 40, // BITMAPINFOHEADER (Windows 3.x, the canonical case)
    v2 = 52,
    v3 = 56,
    v4 = 108, // BITMAPV4HEADER
    v5 = 124, // BITMAPV5HEADER
    _,
};

/// BMP compression methods (numeric values from the spec).
pub const Compression = enum(u32) {
    rgb = 0, // BI_RGB - no compression
    rle8 = 1, // BI_RLE8
    rle4 = 2, // BI_RLE4
    bitfields = 3, // BI_BITFIELDS
    jpeg = 4, // BI_JPEG (refused)
    png = 5, // BI_PNG (refused)
    alphabitfields = 6, // BI_ALPHABITFIELDS
    cmyk = 11, // refused
    cmyk_rle8 = 12, // refused
    cmyk_rle4 = 13, // refused
    _,
};

/// Channel masks for BI_BITFIELDS / V4 / V5 modes. `a == 0` means no alpha.
pub const Masks = struct {
    r: u32,
    g: u32,
    b: u32,
    a: u32 = 0,
};

/// Parsed BITMAPFILEHEADER (14 bytes on disk, little-endian).
pub const FileHeader = struct {
    file_size: u32,
    pixel_data_offset: u32,
};

/// Public summary of a BMP image's metadata. Returned by `getInfo` and embedded
/// in `BmpState`.
pub const Header = struct {
    width: u32,
    /// Always positive. `top_down` records the original row direction.
    height: u32,
    bit_depth: u8,
    compression: Compression,
    dib_kind: DibHeaderKind,
    /// True when biHeight was negative (rows stored top-to-bottom on disk).
    top_down: bool,
    /// Number of palette entries actually present. 0 for non-indexed images.
    palette_entries: u32,
    /// Channel masks for BI_BITFIELDS / V4 / V5 headers.
    masks: ?Masks = null,

    pub fn totalPixels(self: Header) u64 {
        return @as(u64, self.width) * @as(u64, self.height);
    }

    pub fn isIndexed(self: Header) bool {
        return self.bit_depth <= 8;
    }

    /// True for 32bpp BI_BITFIELDS / BI_ALPHABITFIELDS / V4 / V5 with a
    /// non-zero alpha mask.
    pub fn hasAlpha(self: Header) bool {
        return if (self.masks) |m| m.a != 0 else false;
    }
};

inline fn exceeds(comptime T: type, limit: T, value: T) bool {
    return limit != 0 and value > limit;
}

fn enforceHeaderLimits(header: Header, limits: DecodeLimits) !void {
    if (exceeds(u32, limits.max_width, header.width) or
        exceeds(u32, limits.max_height, header.height))
    {
        return error.ImageTooLarge;
    }
    if (exceeds(u64, limits.max_pixels, header.totalPixels())) return error.ImageTooLarge;
    if (exceeds(u32, limits.max_palette_entries, header.palette_entries)) return error.InvalidPaletteSize;
}

/// Maximum number of bytes accepted for a DIB header (cap on the leading size
/// field). Matches V5 (124) with generous slack for vendor extensions.
const max_dib_header_size: u32 = 256;

fn defaultPaletteEntries(bit_depth: u8) u32 {
    return @as(u32, 1) << @intCast(bit_depth);
}

fn isValidBitDepth(bit_depth: u8, compression: Compression) bool {
    return switch (compression) {
        .rgb => switch (bit_depth) {
            1, 4, 8, 16, 24, 32 => true,
            else => false,
        },
        .rle8 => bit_depth == 8,
        .rle4 => bit_depth == 4,
        .bitfields, .alphabitfields => bit_depth == 16 or bit_depth == 32,
        else => false,
    };
}

/// Parses just the BITMAPFILEHEADER. Used by both `getInfo` and `decode` so
/// the two share signature/size validation.
fn readFileHeader(reader: *Io.Reader, limits: DecodeLimits) !FileHeader {
    const sig = try reader.takeArray(2);
    if (!std.mem.eql(u8, sig, &signature)) return error.InvalidBmpSignature;

    const file_size = try reader.takeInt(u32, .little);
    if (limits.max_bmp_bytes != 0 and file_size > limits.max_bmp_bytes) return error.BmpDataTooLarge;
    _ = try reader.takeInt(u16, .little); // reserved1
    _ = try reader.takeInt(u16, .little); // reserved2
    const pixel_offset = try reader.takeInt(u32, .little);

    return .{ .file_size = file_size, .pixel_data_offset = pixel_offset };
}

/// Reads the DIB header (excluding any v3 BI_BITFIELDS masks that live just
/// past the 40-byte INFOHEADER). Advances the reader to the byte immediately
/// following the DIB header. For v3 BI_BITFIELDS the caller still needs to
/// consume the trailing 12/16 mask bytes — handled by `consumeBitfieldMasks`.
fn readDibHeader(reader: *Io.Reader) !Header {
    const dib_size = try reader.takeInt(u32, .little);
    if (dib_size < 12 or dib_size > max_dib_header_size) return error.UnsupportedDibHeader;

    var header: Header = .{
        .width = 0,
        .height = 0,
        .bit_depth = 0,
        .compression = .rgb,
        .dib_kind = @enumFromInt(dib_size),
        .top_down = false,
        .palette_entries = 0,
        .masks = null,
    };

    if (dib_size == 12) {
        // BITMAPCOREHEADER: 4 (size already consumed) + 2+2+2+2 = 12 bytes.
        const w = try reader.takeInt(u16, .little);
        const h = try reader.takeInt(u16, .little);
        const planes = try reader.takeInt(u16, .little);
        const bd = try reader.takeInt(u16, .little);
        if (planes != 1) return error.InvalidDimensions;
        if (w == 0 or h == 0) return error.InvalidDimensions;
        const bit_depth: u8 = std.math.cast(u8, bd) orelse return error.UnsupportedBitDepth;
        if (!isValidBitDepth(bit_depth, .rgb)) return error.UnsupportedBitDepth;
        header.width = w;
        header.height = h;
        header.bit_depth = bit_depth;
        header.palette_entries = if (bit_depth <= 8) defaultPaletteEntries(bit_depth) else 0;
        return header;
    }

    if (dib_size < 40) return error.UnsupportedDibHeader;

    // BITMAPINFOHEADER (40 bytes total including the size field).
    const w_signed = try reader.takeInt(i32, .little);
    const h_signed = try reader.takeInt(i32, .little);
    const planes = try reader.takeInt(u16, .little);
    const bd = try reader.takeInt(u16, .little);
    const compression_raw = try reader.takeInt(u32, .little);
    _ = try reader.takeInt(u32, .little); // biSizeImage
    _ = try reader.takeInt(i32, .little); // biXPelsPerMeter
    _ = try reader.takeInt(i32, .little); // biYPelsPerMeter
    const colors_used = try reader.takeInt(u32, .little);
    _ = try reader.takeInt(u32, .little); // biClrImportant

    if (planes != 1) return error.InvalidDimensions;
    if (w_signed <= 0) return error.InvalidDimensions;
    if (h_signed == 0) return error.InvalidDimensions;
    const top_down = h_signed < 0;
    const w: u32 = @intCast(w_signed);
    const abs_h: i64 = if (top_down) -@as(i64, h_signed) else @as(i64, h_signed);
    if (abs_h > std.math.maxInt(u32)) return error.InvalidDimensions;
    const h: u32 = @intCast(abs_h);
    const bit_depth: u8 = std.math.cast(u8, bd) orelse return error.UnsupportedBitDepth;

    const compression: Compression = @enumFromInt(compression_raw);
    switch (compression) {
        .jpeg, .png, .cmyk, .cmyk_rle8, .cmyk_rle4 => return error.UnsupportedCompression,
        else => {},
    }
    if (top_down and (compression == .rle4 or compression == .rle8)) return error.UnsupportedCompression;
    if (!isValidBitDepth(bit_depth, compression)) return error.UnsupportedBitDepth;

    header.width = w;
    header.height = h;
    header.bit_depth = bit_depth;
    header.compression = compression;
    header.top_down = top_down;

    if (bit_depth <= 8) {
        const max_for_depth = defaultPaletteEntries(bit_depth);
        var entries = colors_used;
        if (entries == 0 or entries > max_for_depth) entries = max_for_depth;
        header.palette_entries = entries;
    }

    // V4/V5 embed the channel masks in the header itself. Read and skip the rest.
    if (dib_size >= 108) {
        const r = try reader.takeInt(u32, .little);
        const g = try reader.takeInt(u32, .little);
        const b = try reader.takeInt(u32, .little);
        const a = try reader.takeInt(u32, .little);
        if (compression == .bitfields or compression == .alphabitfields) {
            header.masks = .{ .r = r, .g = g, .b = b, .a = a };
        }
        // Skip the remaining V4/V5 fields (color space, gamma, intent, profile).
        const remaining = dib_size - 56;
        if (remaining > 0) _ = try reader.discard(.limited(remaining));
    } else if (dib_size > 40) {
        // v2 (52) / v3 (56): some vendors put masks here. Skip past them — we
        // re-read them as v3 BI_BITFIELDS trailing data below if relevant.
        const skip = dib_size - 40;
        _ = try reader.discard(.limited(skip));
    }

    return header;
}

/// Consumes the channel masks that v3 BI_BITFIELDS / BI_ALPHABITFIELDS files
/// store immediately after the 40-byte INFOHEADER. For BI_BITFIELDS the trailer
/// is officially 12 bytes (RGB only), but many encoders (notably GDI+) emit 16
/// bytes (RGBA) at 32bpp; when `read_alpha_mask` is set the extra mask is read.
/// No-op for any other case.
fn consumeBitfieldMasks(reader: *Io.Reader, header: *Header, read_alpha_mask: bool) !void {
    if (header.dib_kind != .info) return; // v4/v5 already absorbed masks
    switch (header.compression) {
        .bitfields => {
            const r = try reader.takeInt(u32, .little);
            const g = try reader.takeInt(u32, .little);
            const b = try reader.takeInt(u32, .little);
            const a: u32 = if (read_alpha_mask) try reader.takeInt(u32, .little) else 0;
            header.masks = .{ .r = r, .g = g, .b = b, .a = a };
        },
        .alphabitfields => {
            const r = try reader.takeInt(u32, .little);
            const g = try reader.takeInt(u32, .little);
            const b = try reader.takeInt(u32, .little);
            const a = try reader.takeInt(u32, .little);
            header.masks = .{ .r = r, .g = g, .b = b, .a = a };
        },
        else => {},
    }
}

/// Whether to read a 4th alpha mask when consuming the v3 BI_BITFIELDS trailer.
/// True when the declared pixel data offset leaves room for it AND the bit
/// depth supports alpha (32bpp).
fn shouldReadAlphaMask(file_header: FileHeader, header: Header) bool {
    if (header.dib_kind != .info) return false;
    if (header.compression != .bitfields) return false;
    if (header.bit_depth != 32) return false;
    const min_offset_with_alpha: u32 = 14 + 40 + 16;
    return file_header.pixel_data_offset >= min_offset_with_alpha;
}

/// Reads BMP metadata without decoding pixel data. Consumes the file header,
/// the DIB header, and any v3 BI_BITFIELDS mask trailer.
pub fn getInfo(reader: *Io.Reader, limits: DecodeLimits) !Header {
    const file_header = try readFileHeader(reader, limits);
    var header = try readDibHeader(reader);
    try consumeBitfieldMasks(reader, &header, shouldReadAlphaMask(file_header, header));

    // Headers (file + DIB + optional v3 BI_BITFIELDS masks) cannot be larger
    // than the declared pixel data offset.
    var min_offset: u32 = 14 + @intFromEnum(header.dib_kind);
    if (header.dib_kind == .info) {
        if (header.compression == .bitfields) {
            min_offset += if (shouldReadAlphaMask(file_header, header)) 16 else 12;
        }
        if (header.compression == .alphabitfields) min_offset += 16;
    }
    if (file_header.pixel_data_offset != 0 and file_header.pixel_data_offset < min_offset) {
        return error.InvalidPixelDataOffset;
    }

    try enforceHeaderLimits(header, limits);
    return header;
}

/// Decoded BMP state. `palette` is owned by the state; `pixel_data` is a
/// borrowed slice into the input buffer passed to `decode`.
pub const BmpState = struct {
    file_header: FileHeader,
    header: Header,
    palette: ?[]Rgba = null,
    pixel_data: []const u8,

    pub fn deinit(self: *BmpState, gpa: Allocator) void {
        if (self.palette) |p| gpa.free(p);
        self.* = undefined;
    }
};

/// Computes the byte offset where the palette begins, relative to the start of
/// the file. Accounts for any v3 BI_BITFIELDS / BI_ALPHABITFIELDS mask trailer.
fn computePostDibOffset(file_header: FileHeader, header: Header) u32 {
    var off: u32 = 14 + @intFromEnum(header.dib_kind);
    if (header.dib_kind == .info) {
        if (header.compression == .bitfields) {
            off += if (shouldReadAlphaMask(file_header, header)) 16 else 12;
        }
        if (header.compression == .alphabitfields) off += 16;
    }
    return off;
}

/// Decodes a BMP file from a byte buffer. The returned state borrows from `data`
/// for pixel data — `data` must outlive the state.
pub fn decode(gpa: Allocator, data: []const u8, limits: DecodeLimits) !BmpState {
    if (limits.max_bmp_bytes != 0 and data.len > limits.max_bmp_bytes) return error.BmpDataTooLarge;

    var reader = Io.Reader.fixed(data);
    const file_header = try readFileHeader(&reader, limits);
    var header = try readDibHeader(&reader);
    try consumeBitfieldMasks(&reader, &header, shouldReadAlphaMask(file_header, header));
    try enforceHeaderLimits(header, limits);

    const palette_offset = computePostDibOffset(file_header, header);
    const palette_entry_size: u32 = if (header.dib_kind == .core) 3 else 4;
    const palette_bytes: u32 = header.palette_entries * palette_entry_size;

    var palette: ?[]Rgba = null;
    errdefer if (palette) |p| gpa.free(p);

    if (header.palette_entries > 0) {
        if (@as(usize, palette_offset) + palette_bytes > data.len) return error.MissingPixelData;
        palette = try gpa.alloc(Rgba, header.palette_entries);
        var i: u32 = 0;
        while (i < header.palette_entries) : (i += 1) {
            const off = palette_offset + i * palette_entry_size;
            const b = data[off + 0];
            const g = data[off + 1];
            const r = data[off + 2];
            // Palette alpha byte (INFO+) is reserved per the spec; treat as opaque.
            palette.?[i] = .{ .r = r, .g = g, .b = b, .a = 255 };
        }
    }

    const min_pixel_offset = palette_offset + palette_bytes;
    const declared = file_header.pixel_data_offset;
    const pixel_offset: u32 = if (declared == 0)
        min_pixel_offset
    else if (declared < min_pixel_offset)
        return error.InvalidPixelDataOffset
    else
        declared;

    if (pixel_offset > data.len) return error.MissingPixelData;
    const pixel_data = data[pixel_offset..];

    return .{
        .file_header = file_header,
        .header = header,
        .palette = palette,
        .pixel_data = pixel_data,
    };
}

/// Returns the row stride in bytes for an uncompressed bitmap with the given
/// width and bit depth, padded to a 4-byte boundary.
inline fn paddedRowBytes(width: u32, bit_depth: u8) usize {
    const bits: u64 = @as(u64, width) * @as(u64, bit_depth);
    return @intCast(((bits + 31) / 32) * 4);
}

/// Native-format pixel container produced by `toNativeImage`. The variant
/// reflects the most natural pixel type for the decoded source.
pub const NativeImage = union(enum) {
    grayscale: Image(u8),
    rgb: Image(Rgb),
    rgba: Image(Rgba),
};

/// Decodes the pixel buffer into a native-format `Image(T)`.
pub fn toNativeImage(allocator: Allocator, state: BmpState) !NativeImage {
    const h = state.header;
    return switch (h.bit_depth) {
        1 => switch (h.compression) {
            .rgb => .{ .rgb = try decodeIndexed(allocator, state) },
            else => return error.UnsupportedCompression,
        },
        4 => switch (h.compression) {
            .rgb => .{ .rgb = try decodeIndexed(allocator, state) },
            .rle4 => .{ .rgb = try decodeRleToImage(allocator, state) },
            else => return error.UnsupportedCompression,
        },
        8 => switch (h.compression) {
            .rgb => .{ .rgb = try decodeIndexed(allocator, state) },
            .rle8 => .{ .rgb = try decodeRleToImage(allocator, state) },
            else => return error.UnsupportedCompression,
        },
        16 => switch (h.compression) {
            .rgb => .{ .rgb = try decodePackedRgb(allocator, state, default16Masks(), 16) },
            .bitfields, .alphabitfields => blk: {
                const masks = h.masks orelse return error.InvalidBitfieldsMasks;
                if (masks.a != 0) break :blk .{ .rgba = try decodePackedRgba(allocator, state, masks, 16) };
                break :blk .{ .rgb = try decodePackedRgb(allocator, state, masks, 16) };
            },
            else => return error.UnsupportedCompression,
        },
        24 => switch (h.compression) {
            .rgb => .{ .rgb = try decode24Bpp(allocator, state) },
            else => return error.UnsupportedCompression,
        },
        32 => switch (h.compression) {
            .rgb => try decode32BppRgb(allocator, state),
            .bitfields, .alphabitfields => blk: {
                const masks = h.masks orelse return error.InvalidBitfieldsMasks;
                if (masks.a != 0) break :blk .{ .rgba = try decodePackedRgba(allocator, state, masks, 32) };
                break :blk .{ .rgb = try decodePackedRgb(allocator, state, masks, 32) };
            },
            else => return error.UnsupportedCompression,
        },
        else => return error.UnsupportedBitDepth,
    };
}

fn default16Masks() Masks {
    return .{ .r = 0x7C00, .g = 0x03E0, .b = 0x001F, .a = 0 }; // 5-5-5
}

/// Per-channel mask metadata pre-computed once per image so the inner pixel
/// loop avoids the `@ctz`/`@popCount` calls and the `(1<<bits)-1` recomputation
/// per pixel. `mask == 0` means "channel absent" (extract returns 0).
const ChannelInfo = struct {
    mask: u32,
    shift: u5,
    /// 1<<bits - 1 for bits<8; the constant 255 for bits>=8 (we shift down
    /// instead of scaling). 0 marks an absent channel.
    max_val: u32,
    /// True when bits >= 8 → just shift the captured value down by (bits-8).
    shift_down: bool,
    down_shift: u5,
};

inline fn channelInfo(mask: u32) ChannelInfo {
    if (mask == 0) return .{ .mask = 0, .shift = 0, .max_val = 0, .shift_down = false, .down_shift = 0 };
    const shift: u5 = @intCast(@ctz(mask));
    const bits: u32 = @popCount(mask);
    if (bits >= 8) {
        return .{ .mask = mask, .shift = shift, .max_val = 255, .shift_down = true, .down_shift = @intCast(bits - 8) };
    }
    return .{ .mask = mask, .shift = shift, .max_val = (@as(u32, 1) << @intCast(bits)) - 1, .shift_down = false, .down_shift = 0 };
}

inline fn extractChannelFast(word: u32, info: ChannelInfo) u8 {
    if (info.max_val == 0) return 0;
    const value = (word & info.mask) >> info.shift;
    if (info.shift_down) return @intCast((value >> info.down_shift) & 0xFF);
    return @intCast((value * 255 + info.max_val / 2) / info.max_val);
}

inline fn readPixelWord(bytes: []const u8, off: usize, bit_depth: u8) u32 {
    return switch (bit_depth) {
        16 => std.mem.readInt(u16, bytes[off..][0..2], .little),
        32 => std.mem.readInt(u32, bytes[off..][0..4], .little),
        else => unreachable,
    };
}

/// Decompresses a BI_RLE4 / BI_RLE8 pixel stream directly into an `Image(Rgb)`,
/// resolving each palette index at write time. Pixels never written by the
/// stream stay zero (initial fill), matching the convention for `delta`
/// escapes and runs that fall short of `width * height`.
fn decodeRleToImage(allocator: Allocator, state: BmpState) !Image(Rgb) {
    const palette = state.palette orelse return error.MissingPalette;
    const w = state.header.width;
    const h = state.header.height;

    var image = try Image(Rgb).init(allocator, h, w);
    errdefer image.deinit(allocator);
    @memset(image.data, .{ .r = 0, .g = 0, .b = 0 });

    const writePixel = struct {
        fn call(img: Image(Rgb), pal: []const Rgba, height: u32, width: u32, x: u32, y: u32, idx: u8) !void {
            if (y >= height or x >= width) return error.RleOverflow;
            if (idx >= pal.len) return error.InvalidPaletteIndex;
            const p = pal[idx];
            img.data[(height - 1 - y) * width + x] = .{ .r = p.r, .g = p.g, .b = p.b };
        }
    }.call;

    const data = state.pixel_data;
    var pos: usize = 0;
    var x: u32 = 0;
    var y: u32 = 0; // y from the bottom (BMP RLE is bottom-up only)

    const is_rle4 = state.header.compression == .rle4;

    while (pos + 1 < data.len) {
        const b0 = data[pos];
        const b1 = data[pos + 1];
        pos += 2;

        if (b0 == 0) {
            switch (b1) {
                0x00 => { // End of line
                    x = 0;
                    y += 1;
                },
                0x01 => return image, // End of bitmap
                0x02 => { // Delta
                    if (pos + 1 >= data.len) return error.InvalidRleEscape;
                    x += data[pos];
                    y += data[pos + 1];
                    pos += 2;
                },
                else => { // Absolute mode: b1 = N (3..255) raw indices
                    const n: u32 = b1;
                    const byte_count: usize = if (is_rle4) (n + 1) / 2 else n;
                    if (pos + byte_count > data.len) return error.InvalidRleEscape;
                    var i: u32 = 0;
                    while (i < n) : (i += 1) {
                        const value: u8 = if (is_rle4) blk: {
                            const byte = data[pos + i / 2];
                            break :blk if (i % 2 == 0) (byte >> 4) else (byte & 0x0F);
                        } else data[pos + i];
                        try writePixel(image, palette, h, w, x, y, value);
                        x += 1;
                    }
                    pos += byte_count;
                    if (byte_count % 2 == 1) pos += 1; // align to 16-bit boundary
                },
            }
        } else { // Encoded run: count copies of value
            const count: u32 = b0;
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                const value: u8 = if (is_rle4)
                    (if (i % 2 == 0) (b1 >> 4) else (b1 & 0x0F))
                else
                    b1;
                try writePixel(image, palette, h, w, x, y, value);
                x += 1;
            }
        }
    }

    return image;
}

fn decodeIndexed(allocator: Allocator, state: BmpState) !Image(Rgb) {
    const bd = state.header.bit_depth;
    const w = state.header.width;
    const h = state.header.height;
    const stride = paddedRowBytes(w, bd);
    if (state.pixel_data.len < stride * h) return error.MissingPixelData;
    const palette = state.palette orelse return error.MissingPalette;

    var image = try Image(Rgb).init(allocator, h, w);
    errdefer image.deinit(allocator);

    var dst_y: u32 = 0;
    while (dst_y < h) : (dst_y += 1) {
        const src_y = if (state.header.top_down) dst_y else h - 1 - dst_y;
        const row_off = src_y * stride;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const index: u32 = switch (bd) {
                1 => blk: {
                    const byte = state.pixel_data[row_off + x / 8];
                    const bit_pos: u3 = @intCast(7 - (x % 8));
                    break :blk (byte >> bit_pos) & 1;
                },
                4 => blk: {
                    const byte = state.pixel_data[row_off + x / 2];
                    break :blk if (x % 2 == 0) (byte >> 4) else (byte & 0x0F);
                },
                8 => state.pixel_data[row_off + x],
                else => unreachable,
            };
            if (index >= palette.len) return error.InvalidPaletteIndex;
            const p = palette[@intCast(index)];
            image.data[dst_y * w + x] = .{ .r = p.r, .g = p.g, .b = p.b };
        }
    }
    return image;
}

fn decodePackedRgb(allocator: Allocator, state: BmpState, masks: Masks, bit_depth: u8) !Image(Rgb) {
    const w = state.header.width;
    const h = state.header.height;
    const bytes_per_pixel: u8 = bit_depth / 8;
    const stride = paddedRowBytes(w, bit_depth);
    if (state.pixel_data.len < stride * h) return error.MissingPixelData;

    var image = try Image(Rgb).init(allocator, h, w);
    errdefer image.deinit(allocator);

    const r_info = channelInfo(masks.r);
    const g_info = channelInfo(masks.g);
    const b_info = channelInfo(masks.b);

    var dst_y: u32 = 0;
    while (dst_y < h) : (dst_y += 1) {
        const src_y = if (state.header.top_down) dst_y else h - 1 - dst_y;
        const row_off = src_y * stride;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const word = readPixelWord(state.pixel_data, row_off + x * bytes_per_pixel, bit_depth);
            image.data[dst_y * w + x] = .{
                .r = extractChannelFast(word, r_info),
                .g = extractChannelFast(word, g_info),
                .b = extractChannelFast(word, b_info),
            };
        }
    }
    return image;
}

fn decodePackedRgba(allocator: Allocator, state: BmpState, masks: Masks, bit_depth: u8) !Image(Rgba) {
    const w = state.header.width;
    const h = state.header.height;
    const bytes_per_pixel: u8 = bit_depth / 8;
    const stride = paddedRowBytes(w, bit_depth);
    if (state.pixel_data.len < stride * h) return error.MissingPixelData;

    var image = try Image(Rgba).init(allocator, h, w);
    errdefer image.deinit(allocator);

    const r_info = channelInfo(masks.r);
    const g_info = channelInfo(masks.g);
    const b_info = channelInfo(masks.b);
    const a_info = channelInfo(masks.a);

    var dst_y: u32 = 0;
    while (dst_y < h) : (dst_y += 1) {
        const src_y = if (state.header.top_down) dst_y else h - 1 - dst_y;
        const row_off = src_y * stride;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const word = readPixelWord(state.pixel_data, row_off + x * bytes_per_pixel, bit_depth);
            image.data[dst_y * w + x] = .{
                .r = extractChannelFast(word, r_info),
                .g = extractChannelFast(word, g_info),
                .b = extractChannelFast(word, b_info),
                .a = extractChannelFast(word, a_info),
            };
        }
    }
    return image;
}

/// Decodes 32bpp BI_RGB. Alpha is officially undefined; the heuristic is to
/// promote to opaque if all alpha bytes are zero (the common writer behaviour),
/// otherwise honour the bytes. The pre-scan early-exits on the first non-zero
/// alpha, so the common case touches each pixel once.
fn decode32BppRgb(allocator: Allocator, state: BmpState) !NativeImage {
    const w = state.header.width;
    const h = state.header.height;
    const stride = paddedRowBytes(w, 32);
    if (state.pixel_data.len < stride * h) return error.MissingPixelData;

    var any_alpha_nonzero = false;
    scan: for (0..h) |y| {
        const row_off = y * stride;
        for (0..w) |x| {
            if (state.pixel_data[row_off + x * 4 + 3] != 0) {
                any_alpha_nonzero = true;
                break :scan;
            }
        }
    }

    if (!any_alpha_nonzero) {
        var image = try Image(Rgb).init(allocator, h, w);
        errdefer image.deinit(allocator);
        var dst_y: u32 = 0;
        while (dst_y < h) : (dst_y += 1) {
            const src_y = if (state.header.top_down) dst_y else h - 1 - dst_y;
            const row_off = src_y * stride;
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const off = row_off + x * 4;
                image.data[dst_y * w + x] = .{
                    .r = state.pixel_data[off + 2],
                    .g = state.pixel_data[off + 1],
                    .b = state.pixel_data[off + 0],
                };
            }
        }
        return .{ .rgb = image };
    }

    var image = try Image(Rgba).init(allocator, h, w);
    errdefer image.deinit(allocator);
    var dst_y: u32 = 0;
    while (dst_y < h) : (dst_y += 1) {
        const src_y = if (state.header.top_down) dst_y else h - 1 - dst_y;
        const row_off = src_y * stride;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const off = row_off + x * 4;
            image.data[dst_y * w + x] = .{
                .r = state.pixel_data[off + 2],
                .g = state.pixel_data[off + 1],
                .b = state.pixel_data[off + 0],
                .a = state.pixel_data[off + 3],
            };
        }
    }
    return .{ .rgba = image };
}

fn decode24Bpp(allocator: Allocator, state: BmpState) !Image(Rgb) {
    const w = state.header.width;
    const h = state.header.height;
    const stride = paddedRowBytes(w, 24);
    const required = stride * h;
    if (state.pixel_data.len < required) return error.MissingPixelData;

    var image = try Image(Rgb).init(allocator, h, w);
    errdefer image.deinit(allocator);

    var dst_y: u32 = 0;
    while (dst_y < h) : (dst_y += 1) {
        const src_y = if (state.header.top_down) dst_y else h - 1 - dst_y;
        const src_row_start = src_y * stride;
        const dst_row_start = dst_y * w;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const off = src_row_start + x * 3;
            image.data[dst_row_start + x] = .{
                .r = state.pixel_data[off + 2],
                .g = state.pixel_data[off + 1],
                .b = state.pixel_data[off + 0],
            };
        }
    }
    return image;
}

/// Loads a BMP from an in-memory byte buffer, converting to the requested pixel type.
pub fn loadFromBytes(comptime T: type, allocator: Allocator, data: []const u8, limits: DecodeLimits) !Image(T) {
    var state = try decode(allocator, data, limits);
    defer state.deinit(allocator);

    var native = try toNativeImage(allocator, state);
    switch (native) {
        .grayscale => |*img| {
            if (T == u8) return img.*;
            defer img.deinit(allocator);
            return img.convert(T, allocator);
        },
        .rgb => |*img| {
            if (T == Rgb) return img.*;
            defer img.deinit(allocator);
            return img.convert(T, allocator);
        },
        .rgba => |*img| {
            if (T == Rgba) return img.*;
            defer img.deinit(allocator);
            return img.convert(T, allocator);
        },
    }
}

/// Loads a BMP from a file path, converting to the requested pixel type.
pub fn load(comptime T: type, io: Io, allocator: Allocator, file_path: []const u8, limits: DecodeLimits) !Image(T) {
    const read_limit = if (limits.max_bmp_bytes == 0) std.math.maxInt(usize) else limits.max_bmp_bytes;
    const data = try Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(read_limit));
    defer allocator.free(data);
    return loadFromBytes(T, allocator, data, limits);
}

// ---------------------------------------------------------------------------
// Encoder
// ---------------------------------------------------------------------------

/// Options controlling BMP encoding.
pub const EncodeOptions = struct {
    /// When true, encode `Image(u8)` as 8bpp indexed BMP with a 256-entry
    /// linear grayscale palette. When false (default) `Image(u8)` is promoted
    /// to 24bpp BGR for maximum reader compatibility.
    use_palette_for_grayscale: bool = false,
    /// When true, write rows top-to-bottom (negative biHeight). Default false
    /// (bottom-up) is the historical convention and is the most widely supported.
    top_down: bool = false,

    pub const default: EncodeOptions = .{};
};

fn writeLe(comptime T: type, out: *ArrayList(u8), gpa: Allocator, value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try out.appendSlice(gpa, &buf);
}

const HeaderArgs = struct {
    width: u32,
    height: u32,
    bit_depth: u16,
    compression: Compression,
    palette_entries: u32 = 0,
    pixel_bytes: u32,
    extra_header_bytes: u32 = 0,
    top_down: bool = false,
};

/// Writes the 14-byte BITMAPFILEHEADER + 40-byte BITMAPINFOHEADER prelude.
/// `extra_header_bytes` accounts for any v3 mask trailer the caller will write
/// next; it shifts the pixel data offset accordingly.
fn writeHeaders(out: *ArrayList(u8), gpa: Allocator, args: HeaderArgs) !void {
    const palette_bytes = args.palette_entries * 4;
    const pixel_offset: u32 = 14 + 40 + args.extra_header_bytes + palette_bytes;
    const file_size: u32 = pixel_offset + args.pixel_bytes;

    // BITMAPFILEHEADER (14 bytes)
    try out.appendSlice(gpa, &signature);
    try writeLe(u32, out, gpa, file_size);
    try writeLe(u16, out, gpa, 0); // reserved1
    try writeLe(u16, out, gpa, 0); // reserved2
    try writeLe(u32, out, gpa, pixel_offset);

    // BITMAPINFOHEADER (40 bytes)
    try writeLe(u32, out, gpa, 40);
    const h_signed: i32 = if (args.top_down) -@as(i32, @intCast(args.height)) else @intCast(args.height);
    try writeLe(i32, out, gpa, @intCast(args.width));
    try writeLe(i32, out, gpa, h_signed);
    try writeLe(u16, out, gpa, 1); // planes
    try writeLe(u16, out, gpa, args.bit_depth);
    try writeLe(u32, out, gpa, @intFromEnum(args.compression));
    try writeLe(u32, out, gpa, args.pixel_bytes);
    try writeLe(i32, out, gpa, 2835); // ~72 DPI
    try writeLe(i32, out, gpa, 2835);
    try writeLe(u32, out, gpa, args.palette_entries);
    try writeLe(u32, out, gpa, 0); // colors_important
}

/// Encodes a 24bpp BI_RGB BMP from arbitrary input by converting each pixel to Rgb.
fn encode24Bpp(comptime T: type, allocator: Allocator, image: Image(T), top_down: bool) ![]u8 {
    const w = image.cols;
    const h = image.rows;
    if (w == 0 or h == 0) return error.InvalidDimensions;

    const stride: u32 = @intCast(paddedRowBytes(w, 24));
    const pixel_bytes: u32 = stride * h;

    var out: ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.ensureTotalCapacity(allocator, 14 + 40 + pixel_bytes);
    try writeHeaders(&out, allocator, .{
        .width = w,
        .height = h,
        .bit_depth = 24,
        .compression = .rgb,
        .pixel_bytes = pixel_bytes,
        .top_down = top_down,
    });

    const pixel_start = out.items.len;
    try out.appendNTimes(allocator, 0, pixel_bytes);
    const pixels = out.items[pixel_start .. pixel_start + pixel_bytes];

    var src_y: u32 = 0;
    while (src_y < h) : (src_y += 1) {
        const file_y = if (top_down) src_y else h - 1 - src_y;
        const row_off = file_y * stride;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const src = image.at(src_y, x).*;
            const rgb = if (T == Rgb) src else convertColor(Rgb, src);
            const off = row_off + x * 3;
            pixels[off + 0] = rgb.b;
            pixels[off + 1] = rgb.g;
            pixels[off + 2] = rgb.r;
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Canonical RGBA masks used when encoding 32bpp BI_BITFIELDS:
/// little-endian byte order in memory is B, G, R, A.
const canonical_rgba_masks: Masks = .{
    .r = 0x00FF0000,
    .g = 0x0000FF00,
    .b = 0x000000FF,
    .a = 0xFF000000,
};

/// Encodes an `Image(Rgba)` as 32bpp BI_BITFIELDS with a 16-byte RGBA mask
/// trailer, matching the GDI+ convention.
fn encode32BppBitfields(allocator: Allocator, image: Image(Rgba), top_down: bool) ![]u8 {
    const w = image.cols;
    const h = image.rows;
    if (w == 0 or h == 0) return error.InvalidDimensions;

    const stride: u32 = @intCast(paddedRowBytes(w, 32)); // always w*4, 4-aligned
    const pixel_bytes: u32 = stride * h;
    const extra_header_bytes: u32 = 16; // 4 RGBA masks

    var out: ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, 14 + 40 + extra_header_bytes + pixel_bytes);

    try writeHeaders(&out, allocator, .{
        .width = w,
        .height = h,
        .bit_depth = 32,
        .compression = .bitfields,
        .pixel_bytes = pixel_bytes,
        .extra_header_bytes = extra_header_bytes,
        .top_down = top_down,
    });
    // RGBA mask trailer (R, G, B, A — little-endian DWORDs).
    try writeLe(u32, &out, allocator, canonical_rgba_masks.r);
    try writeLe(u32, &out, allocator, canonical_rgba_masks.g);
    try writeLe(u32, &out, allocator, canonical_rgba_masks.b);
    try writeLe(u32, &out, allocator, canonical_rgba_masks.a);

    const pixel_start = out.items.len;
    try out.appendNTimes(allocator, 0, pixel_bytes);
    const pixels = out.items[pixel_start .. pixel_start + pixel_bytes];

    var src_y: u32 = 0;
    while (src_y < h) : (src_y += 1) {
        const file_y = if (top_down) src_y else h - 1 - src_y;
        const row_off = file_y * stride;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const px = image.at(src_y, x).*;
            const off = row_off + x * 4;
            pixels[off + 0] = px.b;
            pixels[off + 1] = px.g;
            pixels[off + 2] = px.r;
            pixels[off + 3] = px.a;
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Encodes an `Image(u8)` as 8bpp indexed BMP with a 256-entry linear gray palette.
fn encode8BppGray(allocator: Allocator, image: Image(u8), top_down: bool) ![]u8 {
    const w = image.cols;
    const h = image.rows;
    if (w == 0 or h == 0) return error.InvalidDimensions;

    const stride: u32 = @intCast(paddedRowBytes(w, 8));
    const pixel_bytes: u32 = stride * h;
    const palette_entries: u32 = 256;

    var out: ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, 14 + 40 + palette_entries * 4 + pixel_bytes);

    try writeHeaders(&out, allocator, .{
        .width = w,
        .height = h,
        .bit_depth = 8,
        .compression = .rgb,
        .palette_entries = palette_entries,
        .pixel_bytes = pixel_bytes,
        .top_down = top_down,
    });

    // Linear grayscale palette: BGRA per entry (alpha reserved=0).
    var i: u16 = 0;
    while (i < 256) : (i += 1) {
        const v: u8 = @intCast(i);
        try out.appendSlice(allocator, &.{ v, v, v, 0 });
    }

    const pixel_start = out.items.len;
    try out.appendNTimes(allocator, 0, pixel_bytes);
    const pixels = out.items[pixel_start .. pixel_start + pixel_bytes];

    var src_y: u32 = 0;
    while (src_y < h) : (src_y += 1) {
        const file_y = if (top_down) src_y else h - 1 - src_y;
        const row_off = file_y * stride;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            pixels[row_off + x] = image.at(src_y, x).*;
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Encodes an image as a BMP byte buffer. Caller owns the returned slice.
pub fn encode(comptime T: type, allocator: Allocator, image: Image(T), options: EncodeOptions) ![]u8 {
    if (T == Rgba) return encode32BppBitfields(allocator, image, options.top_down);
    if (T == u8 and options.use_palette_for_grayscale) return encode8BppGray(allocator, image, options.top_down);
    return encode24Bpp(T, allocator, image, options.top_down);
}

/// Encodes the image and writes it to `file_path`.
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

const ArrayList = std.ArrayList;

const TestFileHeaderOpts = struct {
    file_size: u32 = 0,
    pixel_offset: u32 = 0,
};

fn appendFileHeader(list: *ArrayList(u8), gpa: Allocator, opts: TestFileHeaderOpts) !void {
    try list.appendSlice(gpa, &signature);
    try writeLe(u32, list, gpa, opts.file_size);
    try writeLe(u16, list, gpa, 0); // reserved1
    try writeLe(u16, list, gpa, 0); // reserved2
    try writeLe(u32, list, gpa, opts.pixel_offset);
}

const TestInfoHeaderOpts = struct {
    width: i32,
    height: i32,
    bit_depth: u16,
    compression: Compression = .rgb,
    size_image: u32 = 0,
    colors_used: u32 = 0,
};

fn appendInfoHeader(list: *ArrayList(u8), gpa: Allocator, opts: TestInfoHeaderOpts) !void {
    try writeLe(u32, list, gpa, 40);
    try writeLe(i32, list, gpa, opts.width);
    try writeLe(i32, list, gpa, opts.height);
    try writeLe(u16, list, gpa, 1); // planes
    try writeLe(u16, list, gpa, opts.bit_depth);
    try writeLe(u32, list, gpa, @intFromEnum(opts.compression));
    try writeLe(u32, list, gpa, opts.size_image);
    try writeLe(i32, list, gpa, 2835); // x_pels_per_meter (~72 DPI)
    try writeLe(i32, list, gpa, 2835); // y_pels_per_meter
    try writeLe(u32, list, gpa, opts.colors_used);
    try writeLe(u32, list, gpa, 0); // colors_important
}

const TestCoreHeaderOpts = struct {
    width: u16,
    height: u16,
    bit_depth: u16,
};

fn appendCoreHeader(list: *ArrayList(u8), gpa: Allocator, opts: TestCoreHeaderOpts) !void {
    try writeLe(u32, list, gpa, 12);
    try writeLe(u16, list, gpa, opts.width);
    try writeLe(u16, list, gpa, opts.height);
    try writeLe(u16, list, gpa, 1); // planes
    try writeLe(u16, list, gpa, opts.bit_depth);
}

test "BMP getInfo: 24bpp BITMAPINFOHEADER" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    const pixel_offset: u32 = 14 + 40;
    try appendFileHeader(&data, gpa, .{ .file_size = pixel_offset + 100, .pixel_offset = pixel_offset });
    try appendInfoHeader(&data, gpa, .{ .width = 100, .height = 50, .bit_depth = 24 });

    var reader = Io.Reader.fixed(data.items);
    const header = try getInfo(&reader, .{});

    try std.testing.expectEqual(@as(u32, 100), header.width);
    try std.testing.expectEqual(@as(u32, 50), header.height);
    try std.testing.expectEqual(@as(u8, 24), header.bit_depth);
    try std.testing.expectEqual(Compression.rgb, header.compression);
    try std.testing.expectEqual(DibHeaderKind.info, header.dib_kind);
    try std.testing.expect(!header.top_down);
    try std.testing.expectEqual(@as(u32, 0), header.palette_entries);
    try std.testing.expect(!header.hasAlpha());
    try std.testing.expect(header.masks == null);
}

test "BMP getInfo: top-down (negative biHeight)" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    const pixel_offset: u32 = 14 + 40;
    try appendFileHeader(&data, gpa, .{ .file_size = pixel_offset + 100, .pixel_offset = pixel_offset });
    try appendInfoHeader(&data, gpa, .{ .width = 4, .height = -3, .bit_depth = 32 });

    var reader = Io.Reader.fixed(data.items);
    const header = try getInfo(&reader, .{});

    try std.testing.expectEqual(@as(u32, 4), header.width);
    try std.testing.expectEqual(@as(u32, 3), header.height);
    try std.testing.expect(header.top_down);
}

test "BMP getInfo: BITMAPCOREHEADER (OS/2 v1)" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    const pixel_offset: u32 = 14 + 12 + 256 * 3; // CORE palette is 3 bytes per entry
    try appendFileHeader(&data, gpa, .{ .file_size = pixel_offset + 100, .pixel_offset = pixel_offset });
    try appendCoreHeader(&data, gpa, .{ .width = 64, .height = 64, .bit_depth = 8 });

    var reader = Io.Reader.fixed(data.items);
    const header = try getInfo(&reader, .{});

    try std.testing.expectEqual(@as(u32, 64), header.width);
    try std.testing.expectEqual(@as(u32, 64), header.height);
    try std.testing.expectEqual(@as(u8, 8), header.bit_depth);
    try std.testing.expectEqual(DibHeaderKind.core, header.dib_kind);
    try std.testing.expectEqual(@as(u32, 256), header.palette_entries);
}

test "BMP getInfo: 32bpp BI_BITFIELDS reads masks" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    const pixel_offset: u32 = 14 + 40 + 12;
    try appendFileHeader(&data, gpa, .{ .file_size = pixel_offset + 64, .pixel_offset = pixel_offset });
    try appendInfoHeader(&data, gpa, .{ .width = 4, .height = 4, .bit_depth = 32, .compression = .bitfields });
    // RGB masks (no alpha for plain BI_BITFIELDS)
    try writeLe(u32, &data, gpa, 0x00FF0000);
    try writeLe(u32, &data, gpa, 0x0000FF00);
    try writeLe(u32, &data, gpa, 0x000000FF);

    var reader = Io.Reader.fixed(data.items);
    const header = try getInfo(&reader, .{});

    try std.testing.expectEqual(Compression.bitfields, header.compression);
    try std.testing.expect(header.masks != null);
    const m = header.masks.?;
    try std.testing.expectEqual(@as(u32, 0x00FF0000), m.r);
    try std.testing.expectEqual(@as(u32, 0x0000FF00), m.g);
    try std.testing.expectEqual(@as(u32, 0x000000FF), m.b);
    try std.testing.expectEqual(@as(u32, 0), m.a);
    try std.testing.expect(!header.hasAlpha());
}

test "BMP getInfo: BI_ALPHABITFIELDS reads RGBA masks" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    const pixel_offset: u32 = 14 + 40 + 16;
    try appendFileHeader(&data, gpa, .{ .file_size = pixel_offset + 64, .pixel_offset = pixel_offset });
    try appendInfoHeader(&data, gpa, .{ .width = 4, .height = 4, .bit_depth = 32, .compression = .alphabitfields });
    try writeLe(u32, &data, gpa, 0x00FF0000);
    try writeLe(u32, &data, gpa, 0x0000FF00);
    try writeLe(u32, &data, gpa, 0x000000FF);
    try writeLe(u32, &data, gpa, 0xFF000000);

    var reader = Io.Reader.fixed(data.items);
    const header = try getInfo(&reader, .{});

    try std.testing.expect(header.masks != null);
    try std.testing.expectEqual(@as(u32, 0xFF000000), header.masks.?.a);
    try std.testing.expect(header.hasAlpha());
}

test "BMP getInfo: BITMAPV4HEADER" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    const pixel_offset: u32 = 14 + 108;
    try appendFileHeader(&data, gpa, .{ .file_size = pixel_offset + 64, .pixel_offset = pixel_offset });
    // V4 header = 108 bytes total. Reuse the INFOHEADER shape for the first 40
    // bytes but bump the size field to 108.
    var v4_size_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &v4_size_buf, 108, .little);
    try data.appendSlice(gpa, &v4_size_buf);
    try writeLe(i32, &data, gpa, 8); // width
    try writeLe(i32, &data, gpa, 8); // height
    try writeLe(u16, &data, gpa, 1); // planes
    try writeLe(u16, &data, gpa, 32); // bit_depth
    try writeLe(u32, &data, gpa, @intFromEnum(Compression.bitfields));
    try writeLe(u32, &data, gpa, 0); // size_image
    try writeLe(i32, &data, gpa, 2835);
    try writeLe(i32, &data, gpa, 2835);
    try writeLe(u32, &data, gpa, 0); // colors_used
    try writeLe(u32, &data, gpa, 0); // colors_important
    // V4 extension: 16 bytes RGBA masks + 4 bytes color space + 36 bytes endpoints + 12 bytes gamma
    try writeLe(u32, &data, gpa, 0x00FF0000); // R
    try writeLe(u32, &data, gpa, 0x0000FF00); // G
    try writeLe(u32, &data, gpa, 0x000000FF); // B
    try writeLe(u32, &data, gpa, 0xFF000000); // A
    try writeLe(u32, &data, gpa, 0x73524742); // 'sRGB' color space
    // 36 bytes endpoints + 12 bytes gamma = 48 bytes of zeros
    try data.appendNTimes(gpa, 0, 48);

    var reader = Io.Reader.fixed(data.items);
    const header = try getInfo(&reader, .{});

    try std.testing.expectEqual(DibHeaderKind.v4, header.dib_kind);
    try std.testing.expectEqual(@as(u8, 32), header.bit_depth);
    try std.testing.expect(header.masks != null);
    try std.testing.expectEqual(@as(u32, 0xFF000000), header.masks.?.a);
    try std.testing.expect(header.hasAlpha());
}

test "BMP getInfo rejects bad signature" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    try data.appendSlice(gpa, "XX");
    try writeLe(u32, &data, gpa, 100);
    try writeLe(u16, &data, gpa, 0);
    try writeLe(u16, &data, gpa, 0);
    try writeLe(u32, &data, gpa, 54);

    var reader = Io.Reader.fixed(data.items);
    try std.testing.expectError(error.InvalidBmpSignature, getInfo(&reader, .{}));
}

test "BMP getInfo rejects BI_JPEG / BI_PNG" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    try appendFileHeader(&data, gpa, .{ .file_size = 100, .pixel_offset = 54 });
    try appendInfoHeader(&data, gpa, .{ .width = 8, .height = 8, .bit_depth = 24, .compression = .jpeg });

    var reader = Io.Reader.fixed(data.items);
    try std.testing.expectError(error.UnsupportedCompression, getInfo(&reader, .{}));
}

test "BMP getInfo rejects unsupported bit depth" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    try appendFileHeader(&data, gpa, .{ .file_size = 100, .pixel_offset = 54 });
    try appendInfoHeader(&data, gpa, .{ .width = 8, .height = 8, .bit_depth = 7 });

    var reader = Io.Reader.fixed(data.items);
    try std.testing.expectError(error.UnsupportedBitDepth, getInfo(&reader, .{}));
}

test "BMP getInfo enforces max_bmp_bytes" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    try appendFileHeader(&data, gpa, .{ .file_size = 10_000_000, .pixel_offset = 54 });
    try appendInfoHeader(&data, gpa, .{ .width = 8, .height = 8, .bit_depth = 24 });

    var reader = Io.Reader.fixed(data.items);
    try std.testing.expectError(error.BmpDataTooLarge, getInfo(&reader, .{ .max_bmp_bytes = 1024 }));
}

test "BMP getInfo enforces max_pixels" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    try appendFileHeader(&data, gpa, .{ .file_size = 1000, .pixel_offset = 54 });
    try appendInfoHeader(&data, gpa, .{ .width = 100, .height = 100, .bit_depth = 24 });

    var reader = Io.Reader.fixed(data.items);
    try std.testing.expectError(error.ImageTooLarge, getInfo(&reader, .{ .max_pixels = 1000 }));
}

test "BMP getInfo rejects pixel_offset before header end" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    try appendFileHeader(&data, gpa, .{ .file_size = 100, .pixel_offset = 20 }); // < 14+40
    try appendInfoHeader(&data, gpa, .{ .width = 8, .height = 8, .bit_depth = 24 });

    var reader = Io.Reader.fixed(data.items);
    try std.testing.expectError(error.InvalidPixelDataOffset, getInfo(&reader, .{}));
}

test "BMP decode 24bpp BI_RGB bottom-up" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    const w: u32 = 4;
    const h: u32 = 3;
    const stride: u32 = 12; // 4*3 = 12, already 4-aligned
    const pixel_offset: u32 = 14 + 40;
    const file_size: u32 = pixel_offset + stride * h;
    try appendFileHeader(&data, gpa, .{ .file_size = file_size, .pixel_offset = pixel_offset });
    try appendInfoHeader(&data, gpa, .{ .width = @intCast(w), .height = @intCast(h), .bit_depth = 24 });

    // Three rows of distinct colors (red, green, blue) — written bottom-up,
    // so file order is blue-row, green-row, red-row.
    const blue_row = [_]u8{ 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00 };
    const green_row = [_]u8{ 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00 };
    const red_row = [_]u8{ 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF };
    try data.appendSlice(gpa, &blue_row);
    try data.appendSlice(gpa, &green_row);
    try data.appendSlice(gpa, &red_row);

    var image = try loadFromBytes(Rgb, gpa, data.items, .{});
    defer image.deinit(gpa);

    try std.testing.expectEqual(@as(u32, w), image.cols);
    try std.testing.expectEqual(@as(u32, h), image.rows);
    // Top row of the resulting image should be red (because file is bottom-up).
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, image.data[0]);
    // Middle row should be green.
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 255, .b = 0 }, image.data[w]);
    // Bottom row should be blue.
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 255 }, image.data[2 * w]);
}

test "BMP decode 24bpp BI_RGB top-down" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    const w: u32 = 4;
    const h: u32 = 3;
    const stride: u32 = 12;
    const pixel_offset: u32 = 14 + 40;
    const file_size: u32 = pixel_offset + stride * h;
    try appendFileHeader(&data, gpa, .{ .file_size = file_size, .pixel_offset = pixel_offset });
    try appendInfoHeader(&data, gpa, .{ .width = @intCast(w), .height = -@as(i32, @intCast(h)), .bit_depth = 24 });

    // Top-down: file order matches Image storage order (top → bottom).
    const red_row = [_]u8{ 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF };
    const green_row = [_]u8{ 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00 };
    const blue_row = [_]u8{ 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00, 0xFF, 0x00, 0x00 };
    try data.appendSlice(gpa, &red_row);
    try data.appendSlice(gpa, &green_row);
    try data.appendSlice(gpa, &blue_row);

    var image = try loadFromBytes(Rgb, gpa, data.items, .{});
    defer image.deinit(gpa);

    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, image.data[0]);
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 255, .b = 0 }, image.data[w]);
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 255 }, image.data[2 * w]);
}

test "BMP decode 24bpp BI_RGB respects row padding" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    // width=3 → 9 bytes/row, padded to 12 (3 trailing pad bytes per row).
    const w: u32 = 3;
    const h: u32 = 2;
    const stride: u32 = 12;
    const pixel_offset: u32 = 14 + 40;
    try appendFileHeader(&data, gpa, .{ .file_size = pixel_offset + stride * h, .pixel_offset = pixel_offset });
    try appendInfoHeader(&data, gpa, .{ .width = @intCast(w), .height = @intCast(h), .bit_depth = 24 });

    // Bottom-up: row 1 first, then row 0.
    // Row 1 (top of image): RGB = (10,20,30), (40,50,60), (70,80,90)
    // Row 0 (bottom of image): RGB = (1,2,3), (4,5,6), (7,8,9)
    // Stored as BGR with 3 bytes of padding.
    const padding = [_]u8{ 0xAA, 0xAA, 0xAA }; // garbage in padding bytes
    try data.appendSlice(gpa, &.{ 3, 2, 1, 6, 5, 4, 9, 8, 7 });
    try data.appendSlice(gpa, &padding);
    try data.appendSlice(gpa, &.{ 30, 20, 10, 60, 50, 40, 90, 80, 70 });
    try data.appendSlice(gpa, &padding);

    var image = try loadFromBytes(Rgb, gpa, data.items, .{});
    defer image.deinit(gpa);

    try std.testing.expectEqual(Rgb{ .r = 10, .g = 20, .b = 30 }, image.data[0]);
    try std.testing.expectEqual(Rgb{ .r = 40, .g = 50, .b = 60 }, image.data[1]);
    try std.testing.expectEqual(Rgb{ .r = 70, .g = 80, .b = 90 }, image.data[2]);
    try std.testing.expectEqual(Rgb{ .r = 1, .g = 2, .b = 3 }, image.data[3]);
    try std.testing.expectEqual(Rgb{ .r = 4, .g = 5, .b = 6 }, image.data[4]);
    try std.testing.expectEqual(Rgb{ .r = 7, .g = 8, .b = 9 }, image.data[5]);
}

test "BMP decode 24bpp rejects truncated pixel data" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    const pixel_offset: u32 = 14 + 40;
    try appendFileHeader(&data, gpa, .{ .file_size = pixel_offset + 10, .pixel_offset = pixel_offset });
    try appendInfoHeader(&data, gpa, .{ .width = 4, .height = 4, .bit_depth = 24 });
    // Required: 4*3 = 12 bytes/row * 4 rows = 48 bytes. Provide only 24.
    try data.appendNTimes(gpa, 0, 24);

    try std.testing.expectError(error.MissingPixelData, loadFromBytes(Rgb, gpa, data.items, .{}));
}

test "BMP round-trip Rgb 24bpp gradient" {
    const gpa = std.testing.allocator;

    var src = try Image(Rgb).init(gpa, 8, 16);
    defer src.deinit(gpa);
    for (0..src.rows) |y| {
        for (0..src.cols) |x| {
            src.at(y, x).* = .{
                .r = @intCast((x * 16) & 0xFF),
                .g = @intCast((y * 32) & 0xFF),
                .b = @intCast(((x + y) * 8) & 0xFF),
            };
        }
    }

    const encoded = try encode(Rgb, gpa, src, .default);
    defer gpa.free(encoded);

    var decoded = try loadFromBytes(Rgb, gpa, encoded, .{});
    defer decoded.deinit(gpa);

    try std.testing.expectEqual(src.rows, decoded.rows);
    try std.testing.expectEqual(src.cols, decoded.cols);
    for (0..src.rows) |y| {
        for (0..src.cols) |x| {
            try std.testing.expectEqual(src.at(y, x).*, decoded.at(y, x).*);
        }
    }
}

test "BMP round-trip Rgb 24bpp top-down option" {
    const gpa = std.testing.allocator;

    var src = try Image(Rgb).init(gpa, 4, 5);
    defer src.deinit(gpa);
    for (0..src.rows) |y| {
        for (0..src.cols) |x| {
            src.at(y, x).* = .{ .r = @intCast(y * 50), .g = @intCast(x * 40), .b = 100 };
        }
    }

    const encoded = try encode(Rgb, gpa, src, .{ .top_down = true });
    defer gpa.free(encoded);

    var decoded = try loadFromBytes(Rgb, gpa, encoded, .{});
    defer decoded.deinit(gpa);

    for (0..src.rows) |y| {
        for (0..src.cols) |x| {
            try std.testing.expectEqual(src.at(y, x).*, decoded.at(y, x).*);
        }
    }

    // Verify the encoded file is actually flagged top-down.
    var reader = Io.Reader.fixed(encoded);
    const info = try getInfo(&reader, .{});
    try std.testing.expect(info.top_down);
}

test "BMP round-trip width=3 (padding required)" {
    const gpa = std.testing.allocator;

    var src = try Image(Rgb).init(gpa, 2, 3);
    defer src.deinit(gpa);
    src.at(0, 0).* = .{ .r = 10, .g = 20, .b = 30 };
    src.at(0, 1).* = .{ .r = 40, .g = 50, .b = 60 };
    src.at(0, 2).* = .{ .r = 70, .g = 80, .b = 90 };
    src.at(1, 0).* = .{ .r = 1, .g = 2, .b = 3 };
    src.at(1, 1).* = .{ .r = 4, .g = 5, .b = 6 };
    src.at(1, 2).* = .{ .r = 7, .g = 8, .b = 9 };

    const encoded = try encode(Rgb, gpa, src, .default);
    defer gpa.free(encoded);

    var decoded = try loadFromBytes(Rgb, gpa, encoded, .{});
    defer decoded.deinit(gpa);

    for (0..src.rows) |y| {
        for (0..src.cols) |x| {
            try std.testing.expectEqual(src.at(y, x).*, decoded.at(y, x).*);
        }
    }
}

test "BMP round-trip Rgba 32bpp BI_BITFIELDS preserves alpha" {
    const gpa = std.testing.allocator;

    var src = try Image(Rgba).init(gpa, 8, 8);
    defer src.deinit(gpa);
    for (0..src.rows) |y| {
        for (0..src.cols) |x| {
            src.at(y, x).* = .{
                .r = @intCast((x * 32) & 0xFF),
                .g = @intCast((y * 32) & 0xFF),
                .b = 128,
                .a = @intCast(((x + y) * 16) & 0xFF),
            };
        }
    }

    const encoded = try encode(Rgba, gpa, src, .default);
    defer gpa.free(encoded);

    var decoded = try loadFromBytes(Rgba, gpa, encoded, .{});
    defer decoded.deinit(gpa);

    try std.testing.expectEqual(src.rows, decoded.rows);
    try std.testing.expectEqual(src.cols, decoded.cols);
    for (0..src.rows) |y| {
        for (0..src.cols) |x| {
            try std.testing.expectEqual(src.at(y, x).*, decoded.at(y, x).*);
        }
    }
}

test "BMP decode 16bpp BI_BITFIELDS 5-6-5" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    const w: u32 = 4;
    const h: u32 = 1;
    const stride: u32 = 8; // 4 px * 2 bytes = 8, already aligned
    const pixel_offset: u32 = 14 + 40 + 12;
    try appendFileHeader(&data, gpa, .{ .file_size = pixel_offset + stride * h, .pixel_offset = pixel_offset });
    try appendInfoHeader(&data, gpa, .{ .width = @intCast(w), .height = @intCast(h), .bit_depth = 16, .compression = .bitfields });
    // 5-6-5 masks (RGB565)
    try writeLe(u32, &data, gpa, 0xF800); // R: 5 bits in [15..11]
    try writeLe(u32, &data, gpa, 0x07E0); // G: 6 bits in [10..5]
    try writeLe(u32, &data, gpa, 0x001F); // B: 5 bits in [4..0]

    // 4 pixels: pure red, pure green, pure blue, white
    try writeLe(u16, &data, gpa, 0xF800); // r=31,g=0,b=0
    try writeLe(u16, &data, gpa, 0x07E0); // r=0,g=63,b=0
    try writeLe(u16, &data, gpa, 0x001F); // r=0,g=0,b=31
    try writeLe(u16, &data, gpa, 0xFFFF); // r=31,g=63,b=31 → white

    var image = try loadFromBytes(Rgb, gpa, data.items, .{});
    defer image.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 255), image.data[0].r);
    try std.testing.expectEqual(@as(u8, 0), image.data[0].g);
    try std.testing.expectEqual(@as(u8, 0), image.data[0].b);

    try std.testing.expectEqual(@as(u8, 0), image.data[1].r);
    try std.testing.expectEqual(@as(u8, 255), image.data[1].g);
    try std.testing.expectEqual(@as(u8, 0), image.data[1].b);

    try std.testing.expectEqual(@as(u8, 0), image.data[2].r);
    try std.testing.expectEqual(@as(u8, 0), image.data[2].g);
    try std.testing.expectEqual(@as(u8, 255), image.data[2].b);

    try std.testing.expectEqual(@as(u8, 255), image.data[3].r);
    try std.testing.expectEqual(@as(u8, 255), image.data[3].g);
    try std.testing.expectEqual(@as(u8, 255), image.data[3].b);
}

test "BMP decode 32bpp BI_RGB heuristic: all-zero alpha → opaque Rgb" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    const w: u32 = 2;
    const h: u32 = 1;
    const stride: u32 = w * 4;
    const pixel_offset: u32 = 14 + 40;
    try appendFileHeader(&data, gpa, .{ .file_size = pixel_offset + stride, .pixel_offset = pixel_offset });
    try appendInfoHeader(&data, gpa, .{ .width = @intCast(w), .height = @intCast(h), .bit_depth = 32, .compression = .rgb });
    // BGRX: red and green pixels with alpha byte = 0
    try data.appendSlice(gpa, &.{ 0, 0, 0xFF, 0 }); // red
    try data.appendSlice(gpa, &.{ 0, 0xFF, 0, 0 }); // green

    // Should decode as Rgb (heuristic kicks in).
    var image = try loadFromBytes(Rgb, gpa, data.items, .{});
    defer image.deinit(gpa);

    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, image.data[0]);
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 255, .b = 0 }, image.data[1]);
}

test "BMP decode 32bpp BI_RGB: nonzero alpha is honoured as Rgba" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    const w: u32 = 2;
    const h: u32 = 1;
    const stride: u32 = w * 4;
    const pixel_offset: u32 = 14 + 40;
    try appendFileHeader(&data, gpa, .{ .file_size = pixel_offset + stride, .pixel_offset = pixel_offset });
    try appendInfoHeader(&data, gpa, .{ .width = @intCast(w), .height = @intCast(h), .bit_depth = 32, .compression = .rgb });
    try data.appendSlice(gpa, &.{ 0, 0, 0xFF, 0x80 }); // red, semi-transparent
    try data.appendSlice(gpa, &.{ 0, 0xFF, 0, 0xFF }); // green, opaque

    var image = try loadFromBytes(Rgba, gpa, data.items, .{});
    defer image.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0x80), image.data[0].a);
    try std.testing.expectEqual(@as(u8, 0xFF), image.data[1].a);
}

test "BMP decode 8bpp indexed (gradient palette)" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    const w: u32 = 4;
    const h: u32 = 1;
    const stride: u32 = 4; // already 4-aligned
    const palette_bytes: u32 = 256 * 4;
    const pixel_offset: u32 = 14 + 40 + palette_bytes;
    try appendFileHeader(&data, gpa, .{ .file_size = pixel_offset + stride, .pixel_offset = pixel_offset });
    try appendInfoHeader(&data, gpa, .{ .width = @intCast(w), .height = @intCast(h), .bit_depth = 8 });
    // 256-entry grayscale palette (BGRA, A reserved=0)
    var i: u16 = 0;
    while (i < 256) : (i += 1) {
        const v: u8 = @intCast(i);
        try data.appendSlice(gpa, &.{ v, v, v, 0 });
    }
    // Pixel indices
    try data.appendSlice(gpa, &.{ 0, 64, 128, 255 });

    var image = try loadFromBytes(Rgb, gpa, data.items, .{});
    defer image.deinit(gpa);

    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, image.data[0]);
    try std.testing.expectEqual(Rgb{ .r = 64, .g = 64, .b = 64 }, image.data[1]);
    try std.testing.expectEqual(Rgb{ .r = 128, .g = 128, .b = 128 }, image.data[2]);
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, image.data[3]);
}

test "BMP decode 1bpp indexed (checkerboard)" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    const w: u32 = 8;
    const h: u32 = 2;
    const stride: u32 = 4; // ceil(8/8) = 1, padded to 4
    const palette_bytes: u32 = 2 * 4;
    const pixel_offset: u32 = 14 + 40 + palette_bytes;
    try appendFileHeader(&data, gpa, .{ .file_size = pixel_offset + stride * h, .pixel_offset = pixel_offset });
    try appendInfoHeader(&data, gpa, .{ .width = @intCast(w), .height = @intCast(h), .bit_depth = 1 });
    // Palette: 0 = black, 1 = white
    try data.appendSlice(gpa, &.{ 0, 0, 0, 0 });
    try data.appendSlice(gpa, &.{ 0xFF, 0xFF, 0xFF, 0 });

    // Bottom row first (bottom-up): 10101010 → AA
    try data.appendSlice(gpa, &.{ 0xAA, 0, 0, 0 });
    // Top row: 01010101 → 55
    try data.appendSlice(gpa, &.{ 0x55, 0, 0, 0 });

    var image = try loadFromBytes(Rgb, gpa, data.items, .{});
    defer image.deinit(gpa);

    // Top row should alternate starting with black (0x55 = 0b01010101 MSB-first)
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, image.data[0]);
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, image.data[1]);
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, image.data[2]);
    // Bottom row should alternate starting with white (0xAA = 0b10101010 MSB-first)
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, image.data[w]);
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, image.data[w + 1]);
}

test "BMP decode 4bpp indexed" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    const w: u32 = 4;
    const h: u32 = 1;
    const stride: u32 = 4; // ceil(4*4/8)=2, padded to 4
    const palette_bytes: u32 = 16 * 4;
    const pixel_offset: u32 = 14 + 40 + palette_bytes;
    try appendFileHeader(&data, gpa, .{ .file_size = pixel_offset + stride, .pixel_offset = pixel_offset });
    try appendInfoHeader(&data, gpa, .{ .width = @intCast(w), .height = @intCast(h), .bit_depth = 4 });
    // 16-entry palette: index i → gray value i*17 (so 0..15 maps to 0..255)
    var idx: u8 = 0;
    while (idx < 16) : (idx += 1) {
        const v: u8 = @intCast(@as(u16, idx) * 17);
        try data.appendSlice(gpa, &.{ v, v, v, 0 });
    }
    // Pixels: indices 0, 5, 10, 15 packed as 0x05, 0xAF (high nibble first)
    try data.appendSlice(gpa, &.{ 0x05, 0xAF, 0, 0 });

    var image = try loadFromBytes(Rgb, gpa, data.items, .{});
    defer image.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0), image.data[0].r);
    try std.testing.expectEqual(@as(u8, 85), image.data[1].r); // 5*17
    try std.testing.expectEqual(@as(u8, 170), image.data[2].r); // 10*17
    try std.testing.expectEqual(@as(u8, 255), image.data[3].r); // 15*17
}

test "BMP decode 8bpp BITMAPCOREHEADER (3-byte palette entries)" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    const w: u32 = 4;
    const h: u32 = 1;
    const stride: u32 = 4;
    const palette_bytes: u32 = 256 * 3; // CORE: 3 bytes per entry
    const pixel_offset: u32 = 14 + 12 + palette_bytes;
    try appendFileHeader(&data, gpa, .{ .file_size = pixel_offset + stride, .pixel_offset = pixel_offset });
    try appendCoreHeader(&data, gpa, .{ .width = @intCast(w), .height = @intCast(h), .bit_depth = 8 });
    var i: u16 = 0;
    while (i < 256) : (i += 1) {
        const v: u8 = @intCast(i);
        try data.appendSlice(gpa, &.{ v, v, v }); // BGR (no reserved byte)
    }
    try data.appendSlice(gpa, &.{ 10, 20, 30, 40 });

    var image = try loadFromBytes(Rgb, gpa, data.items, .{});
    defer image.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 10), image.data[0].r);
    try std.testing.expectEqual(@as(u8, 20), image.data[1].g);
    try std.testing.expectEqual(@as(u8, 30), image.data[2].b);
    try std.testing.expectEqual(@as(u8, 40), image.data[3].r);
}

// Helper that builds a 4-entry indexed BMP wrapping the supplied RLE byte
// stream, then decodes it. Used by the RLE tests.
fn buildRleBmp(
    gpa: Allocator,
    out: *ArrayList(u8),
    width: u32,
    height: u32,
    bit_depth: u16,
    rle_stream: []const u8,
) !void {
    const compression: Compression = if (bit_depth == 8) .rle8 else .rle4;
    const palette_entries: u32 = if (bit_depth == 8) 256 else 16;
    const palette_bytes: u32 = palette_entries * 4;
    const pixel_offset: u32 = 14 + 40 + palette_bytes;
    try appendFileHeader(out, gpa, .{
        .file_size = pixel_offset + @as(u32, @intCast(rle_stream.len)),
        .pixel_offset = pixel_offset,
    });
    try appendInfoHeader(out, gpa, .{
        .width = @intCast(width),
        .height = @intCast(height),
        .bit_depth = bit_depth,
        .compression = compression,
        .size_image = @intCast(rle_stream.len),
    });
    // Distinct palette so we can identify each index in the decoded output.
    // Index i → grayscale i*16 (capped at 255).
    var i: u32 = 0;
    while (i < palette_entries) : (i += 1) {
        const v: u8 = @intCast(@min(i * 16, 255));
        try out.appendSlice(gpa, &.{ v, v, v, 0 });
    }
    try out.appendSlice(gpa, rle_stream);
}

test "BMP decode RLE8 with encoded + literal + EOL + EOI" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    // 4x2 image. Row 0 (top of image, second in file order):
    //   indices: 1, 1, 1, 1  (encoded run of 4 1s)
    // Row 1 (bottom of image, first in file order):
    //   indices: 5, 6, 7, 8  (literal run of 4 indices, padded to 4 bytes)
    const stream = [_]u8{
        // Bottom row first
        0x00, 0x04, 5, 6, 7, 8, // absolute: N=4, then 4 indices (4 bytes, no padding)
        0x00, 0x00, // EOL
        0x04, 0x01, // encoded: 4 copies of index 1
        0x00, 0x01, // EOI
    };
    try buildRleBmp(gpa, &data, 4, 2, 8, &stream);

    var image = try loadFromBytes(Rgb, gpa, data.items, .{});
    defer image.deinit(gpa);

    // Top row (row 0): all index 1 → gray 16
    try std.testing.expectEqual(@as(u8, 16), image.at(0, 0).*.r);
    try std.testing.expectEqual(@as(u8, 16), image.at(0, 3).*.r);
    // Bottom row (row 1): indices 5, 6, 7, 8 → gray 80, 96, 112, 128
    try std.testing.expectEqual(@as(u8, 80), image.at(1, 0).*.r);
    try std.testing.expectEqual(@as(u8, 96), image.at(1, 1).*.r);
    try std.testing.expectEqual(@as(u8, 112), image.at(1, 2).*.r);
    try std.testing.expectEqual(@as(u8, 128), image.at(1, 3).*.r);
}

test "BMP decode RLE8 absolute mode pads to 16-bit boundary" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    // 5x1 image. Absolute run of 5 indices (5 bytes) needs 1 padding byte.
    const stream = [_]u8{
        0x00, 0x05, 1, 2, 3, 4, 5, 0x00, // pad byte
        0x00, 0x01, // EOI
    };
    try buildRleBmp(gpa, &data, 5, 1, 8, &stream);

    var image = try loadFromBytes(Rgb, gpa, data.items, .{});
    defer image.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 16), image.at(0, 0).*.r);
    try std.testing.expectEqual(@as(u8, 32), image.at(0, 1).*.r);
    try std.testing.expectEqual(@as(u8, 48), image.at(0, 2).*.r);
    try std.testing.expectEqual(@as(u8, 64), image.at(0, 3).*.r);
    try std.testing.expectEqual(@as(u8, 80), image.at(0, 4).*.r);
}

test "BMP decode RLE4 alternating nibbles" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    // 4x1 image. Encoded run: 4 copies of value 0x12 → indices 1, 2, 1, 2.
    const stream = [_]u8{
        0x04, 0x12,
        0x00, 0x01, // EOI
    };
    try buildRleBmp(gpa, &data, 4, 1, 4, &stream);

    var image = try loadFromBytes(Rgb, gpa, data.items, .{});
    defer image.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 16), image.at(0, 0).*.r);
    try std.testing.expectEqual(@as(u8, 32), image.at(0, 1).*.r);
    try std.testing.expectEqual(@as(u8, 16), image.at(0, 2).*.r);
    try std.testing.expectEqual(@as(u8, 32), image.at(0, 3).*.r);
}

test "BMP decode RLE8 rejects overflow" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    // 2x1 image but the encoded run claims to write 200 pixels.
    const stream = [_]u8{
        0xC8, 0x01, // encoded: 200 copies of index 1 — would blow past width=2
        0x00, 0x01,
    };
    try buildRleBmp(gpa, &data, 2, 1, 8, &stream);

    try std.testing.expectError(error.RleOverflow, loadFromBytes(Rgb, gpa, data.items, .{}));
}

test "BMP decode RLE delta escape" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);

    // 4x2 image (bottom-up). After encoded run x advances by `count`, so:
    //   start at (x=0, y=0) [bottom-left], write index 1, x → 1
    //   delta dx=2 dy=1: x → 3, y → 1 [top-right]
    //   encoded 1x index 2: write at (x=3, y=1), x → 4
    //   EOI.
    const stream = [_]u8{
        0x01, 0x01, // encoded: 1 copy of index 1
        0x00, 0x02, 0x02, 0x01, // delta dx=2 dy=1
        0x01, 0x02, // encoded: 1 copy of index 2
        0x00, 0x01, // EOI
    };
    try buildRleBmp(gpa, &data, 4, 2, 8, &stream);

    var image = try loadFromBytes(Rgb, gpa, data.items, .{});
    defer image.deinit(gpa);

    // Bottom row x=0 should be index 1 (gray 16).
    try std.testing.expectEqual(@as(u8, 16), image.at(1, 0).*.r);
    // Top row x=3 should be index 2 (gray 32).
    try std.testing.expectEqual(@as(u8, 32), image.at(0, 3).*.r);
    // Top row x=0..2 were never written → index 0 (gray 0).
    try std.testing.expectEqual(@as(u8, 0), image.at(0, 0).*.r);
    try std.testing.expectEqual(@as(u8, 0), image.at(0, 2).*.r);
}

test "BMP round-trip Image(u8) with use_palette_for_grayscale" {
    const gpa = std.testing.allocator;

    var src = try Image(u8).init(gpa, 4, 6);
    defer src.deinit(gpa);
    for (0..src.rows) |y| {
        for (0..src.cols) |x| {
            src.at(y, x).* = @intCast((y * 50 + x * 30) & 0xFF);
        }
    }

    const encoded = try encode(u8, gpa, src, .{ .use_palette_for_grayscale = true });
    defer gpa.free(encoded);

    // Verify the encoded file is actually 8bpp indexed.
    var reader = Io.Reader.fixed(encoded);
    const info = try getInfo(&reader, .{});
    try std.testing.expectEqual(@as(u8, 8), info.bit_depth);
    try std.testing.expectEqual(@as(u32, 256), info.palette_entries);

    var decoded = try loadFromBytes(u8, gpa, encoded, .{});
    defer decoded.deinit(gpa);

    for (0..src.rows) |y| {
        for (0..src.cols) |x| {
            try std.testing.expectEqual(src.at(y, x).*, decoded.at(y, x).*);
        }
    }
}

test "BMP round-trip Image(u8) without flag → 24bpp BGR" {
    const gpa = std.testing.allocator;

    var src = try Image(u8).init(gpa, 3, 5);
    defer src.deinit(gpa);
    for (0..src.rows) |y| {
        for (0..src.cols) |x| {
            src.at(y, x).* = @intCast((y * 60 + x * 40) & 0xFF);
        }
    }

    const encoded = try encode(u8, gpa, src, .default);
    defer gpa.free(encoded);

    var reader = Io.Reader.fixed(encoded);
    const info = try getInfo(&reader, .{});
    try std.testing.expectEqual(@as(u8, 24), info.bit_depth);

    var decoded = try loadFromBytes(u8, gpa, encoded, .{});
    defer decoded.deinit(gpa);

    for (0..src.rows) |y| {
        for (0..src.cols) |x| {
            try std.testing.expectEqual(src.at(y, x).*, decoded.at(y, x).*);
        }
    }
}

test "BMP getInfo: 8bpp uses default 256 palette entries when colors_used=0" {
    const gpa = std.testing.allocator;
    var data: ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    const pixel_offset: u32 = 14 + 40 + 256 * 4;
    try appendFileHeader(&data, gpa, .{ .file_size = pixel_offset + 64, .pixel_offset = pixel_offset });
    try appendInfoHeader(&data, gpa, .{ .width = 8, .height = 8, .bit_depth = 8 });

    var reader = Io.Reader.fixed(data.items);
    const header = try getInfo(&reader, .{});
    try std.testing.expectEqual(@as(u32, 256), header.palette_entries);
}
