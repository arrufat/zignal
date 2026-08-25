//! Bounds-checked big-endian reads over sfnt bytes. Fonts are untrusted input:
//! every access goes through here so a truncated or hostile file yields
//! `error.UnexpectedEof` instead of a panic.

const std = @import("std");

const Error = @import("../truetype.zig").Error;

/// A table's location inside the font, validated against the buffer at load time.
pub const Table = struct {
    offset: u32,
    len: u32,
};

pub const Reader = struct {
    data: []const u8,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    /// A sub-reader whose offsets are relative to `t`. The table must have been validated
    /// against `data` when the directory was parsed.
    pub fn table(r: Reader, t: Table) Reader {
        return .{ .data = r.data[t.offset..][0..t.len] };
    }

    pub fn slice(r: Reader, off: usize, len: usize) Error![]const u8 {
        // usize is 32 bits on wasm32, so the end computation itself can overflow.
        const end = std.math.add(usize, off, len) catch return error.UnexpectedEof;
        if (end > r.data.len) return error.UnexpectedEof;
        return r.data[off..end];
    }

    pub fn u8At(r: Reader, off: usize) Error!u8 {
        return (try r.slice(off, 1))[0];
    }

    pub fn u16At(r: Reader, off: usize) Error!u16 {
        return std.mem.readInt(u16, (try r.slice(off, 2))[0..2], .big);
    }

    pub fn i16At(r: Reader, off: usize) Error!i16 {
        return std.mem.readInt(i16, (try r.slice(off, 2))[0..2], .big);
    }

    pub fn u32At(r: Reader, off: usize) Error!u32 {
        return std.mem.readInt(u32, (try r.slice(off, 4))[0..4], .big);
    }

    /// 2.14 fixed point, used by composite glyph transforms.
    pub fn f2dot14At(r: Reader, off: usize) Error!f32 {
        return @as(f32, @floatFromInt(try r.i16At(off))) / 16384.0;
    }
};

test "reads are bounds checked" {
    const bytes = [_]u8{ 0x12, 0x34, 0xff, 0xfe, 0x00, 0x00, 0x40, 0x00 };
    const r: Reader = .init(&bytes);
    try std.testing.expectEqual(@as(u16, 0x1234), try r.u16At(0));
    try std.testing.expectEqual(@as(i16, -2), try r.i16At(2));
    try std.testing.expectEqual(@as(u32, 0x0000_4000), try r.u32At(4));
    try std.testing.expectEqual(@as(f32, 1.0), try r.f2dot14At(6));
    try std.testing.expectError(error.UnexpectedEof, r.u16At(7));
    try std.testing.expectError(error.UnexpectedEof, r.u32At(std.math.maxInt(usize) - 1));
    try std.testing.expectError(error.UnexpectedEof, r.slice(4, std.math.maxInt(usize)));
}
