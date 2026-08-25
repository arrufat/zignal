//! The legacy `kern` table: horizontal format 0 subtables (sorted pair lists).

const std = @import("std");

const truetype = @import("../truetype.zig");
const Error = truetype.Error;
const Reader = truetype.Reader;

/// Sum of the horizontal kerning for the pair over all format 0 subtables; 0 when
/// absent or malformed.
pub fn lookup(r: Reader, left: u16, right: u16) i16 {
    return lookupInner(r, left, right) catch 0;
}

fn lookupInner(r: Reader, left: u16, right: u16) Error!i16 {
    // Apple's 'kern' starts with a 32-bit version 1.0; only the Microsoft layout is read.
    if (try r.u16At(0) != 0) return 0;
    const num_subtables = try r.u16At(2);
    var total: i32 = 0;
    var off: usize = 4;
    for (0..num_subtables) |_| {
        const len = try r.u16At(off + 2);
        const coverage = try r.u16At(off + 4);
        const horizontal = coverage & 0x1 != 0;
        const minimum = coverage & 0x2 != 0;
        const cross_stream = coverage & 0x4 != 0;
        const format = coverage >> 8;
        if (horizontal and !minimum and !cross_stream and format == 0) {
            total += try lookupFormat0(r, off + 6, left, right);
        }
        if (len < 6) break;
        off += len;
    }
    return std.math.lossyCast(i16, total);
}

fn lookupFormat0(r: Reader, off: usize, left: u16, right: u16) Error!i16 {
    const num_pairs = try r.u16At(off);
    const pairs = off + 8;
    const key = (@as(u32, left) << 16) | right;
    var lo: usize = 0;
    var hi: usize = num_pairs;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const rec = pairs + mid * 6;
        const pair = (@as(u32, try r.u16At(rec)) << 16) | try r.u16At(rec + 2);
        if (pair == key) return try r.i16At(rec + 4);
        if (pair < key) lo = mid + 1 else hi = mid;
    }
    return 0;
}

const synthetic = @import("synthetic.zig");

test "kern table pair" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const font = synthetic.font(&buf, .{ .with_gpos = false });
    try std.testing.expect(font.tables.gpos == null);
    try std.testing.expectEqual(@as(i16, -50), font.kern(1, 2));
    try std.testing.expectEqual(@as(i16, 0), font.kern(2, 1));
    try std.testing.expectEqual(@as(i16, 0), font.kern(1, 3));
}

test "no kern table" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const font = synthetic.font(&buf, .{ .with_gpos = false, .with_kern = false });
    try std.testing.expectEqual(@as(i16, 0), font.kern(1, 2));
}
