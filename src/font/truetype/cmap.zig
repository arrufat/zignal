//! `cmap` subtable selection and codepoint lookup, formats 4 (BMP segments) and
//! 12 (32-bit groups).

const std = @import("std");

const truetype = @import("../truetype.zig");
const Error = truetype.Error;
const Reader = truetype.Reader;

/// In order of preference.
pub const Format = enum { format4, format12 };

pub const Subtable = struct {
    /// Offset of the subtable inside the `cmap` table.
    offset: u32,
    format: Format,
    /// Segments (format 4) or groups (format 12), validated to fit in the table.
    count: u32,
};

const platform_unicode = 0;
const platform_windows = 3;
const windows_bmp = 1;
const windows_full = 10;

/// Picks the best Unicode subtable: format 12 over format 4, regardless of record order.
pub fn select(r: Reader) Error!Subtable {
    var best: ?Subtable = null;
    const num_records = try r.u16At(2);
    for (0..num_records) |i| {
        const rec = 4 + i * 8;
        const platform = try r.u16At(rec);
        const encoding = try r.u16At(rec + 2);
        const offset = try r.u32At(rec + 4);
        const unicode = platform == platform_unicode or
            (platform == platform_windows and (encoding == windows_bmp or encoding == windows_full));
        if (!unicode) continue;
        const format: Format = switch (try r.u16At(offset)) {
            4 => .format4,
            12 => .format12,
            else => continue,
        };
        if (best) |b| if (@backingInt(format) <= @backingInt(b.format)) continue;
        best = try validate(r, offset, format);
    }
    return best orelse error.UnsupportedCmap;
}

fn validate(r: Reader, offset: u32, format: Format) Error!Subtable {
    switch (format) {
        .format4 => {
            const seg_count_x2 = try r.u16At(offset + 6);
            if (seg_count_x2 < 2 or seg_count_x2 % 2 != 0) return error.UnsupportedCmap;
            // endCode, reservedPad, startCode, idDelta, idRangeOffset
            _ = try r.slice(offset + 14, 2 + 4 * @as(usize, seg_count_x2));
            return .{ .offset = offset, .format = .format4, .count = seg_count_x2 / 2 };
        },
        .format12 => {
            const num_groups = try r.u32At(offset + 12);
            _ = try r.slice(offset + 16, 12 * @as(usize, num_groups));
            return .{ .offset = offset, .format = .format12, .count = num_groups };
        },
    }
}

/// Glyph index for `codepoint`, 0 when unmapped. Reads cannot fail after `select`,
/// but a hostile `idRangeOffset` can still point outside the table: that maps to 0.
pub fn lookup(r: Reader, st: Subtable, codepoint: u21) u16 {
    return switch (st.format) {
        .format4 => lookup4(r, st, codepoint) catch 0,
        .format12 => lookup12(r, st, codepoint) catch 0,
    };
}

fn lookup4(r: Reader, st: Subtable, codepoint: u21) Error!u16 {
    if (codepoint > 0xFFFF) return 0;
    const cp: u16 = @intCast(codepoint);
    const end_codes = st.offset + 14;
    const start_codes = end_codes + 2 + 2 * st.count;
    const id_deltas = start_codes + 2 * st.count;
    const id_range_offsets = id_deltas + 2 * st.count;

    // First segment whose endCode >= cp.
    var lo: u32 = 0;
    var hi: u32 = st.count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (try r.u16At(end_codes + 2 * mid) < cp) lo = mid + 1 else hi = mid;
    }
    if (lo == st.count) return 0;
    const start = try r.u16At(start_codes + 2 * lo);
    if (start > cp) return 0;
    const delta = try r.u16At(id_deltas + 2 * lo);
    const range_offset = try r.u16At(id_range_offsets + 2 * lo);
    if (range_offset == 0) return cp +% delta;
    const addr = id_range_offsets + 2 * lo + range_offset + 2 * @as(u32, cp - start);
    const glyph = try r.u16At(addr);
    return if (glyph == 0) 0 else glyph +% delta;
}

fn lookup12(r: Reader, st: Subtable, codepoint: u21) Error!u16 {
    const groups = st.offset + 16;
    var lo: u32 = 0;
    var hi: u32 = st.count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (try r.u32At(groups + 12 * mid + 4) < codepoint) lo = mid + 1 else hi = mid;
    }
    if (lo == st.count) return 0;
    const start = try r.u32At(groups + 12 * lo);
    if (start > codepoint) return 0;
    const glyph = @as(u64, try r.u32At(groups + 12 * lo + 8)) + (codepoint - start);
    return if (glyph > 0xFFFF) 0 else @intCast(glyph);
}

const synthetic = @import("synthetic.zig");

test "format 4: delta and glyphIdArray segments" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const font = synthetic.font(&buf, .{});
    try std.testing.expectEqual(.format4, font.cmap.format);
    try std.testing.expectEqual(@as(u16, 1), font.glyphIndex('A'));
    try std.testing.expectEqual(@as(u16, 6), font.glyphIndex('F'));
    try std.testing.expectEqual(@as(u16, 1), font.glyphIndex('a'));
    try std.testing.expectEqual(@as(u16, 0), font.glyphIndex('G'));
    try std.testing.expectEqual(@as(u16, 0), font.glyphIndex(' '));
    try std.testing.expectEqual(@as(u16, 0), font.glyphIndex(0x1F600));
}

test "format 12 is preferred and still resolves the BMP" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const font = synthetic.font(&buf, .{ .with_format12 = true });
    try std.testing.expectEqual(.format12, font.cmap.format);
    try std.testing.expectEqual(@as(u16, 3), font.glyphIndex(0x1F600));
    try std.testing.expectEqual(@as(u16, 2), font.glyphIndex('B'));
    try std.testing.expectEqual(@as(u16, 0), font.glyphIndex('a'));
}

test "glyph ids past maxp map to notdef" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    var font = synthetic.font(&buf, .{});
    font.num_glyphs = 3;
    try std.testing.expectEqual(@as(u16, 2), font.glyphIndex('B'));
    try std.testing.expectEqual(@as(u16, 0), font.glyphIndex('C'));
}
