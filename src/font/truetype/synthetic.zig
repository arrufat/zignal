//! A hand-assembled TrueType font for tests: deterministic, allocation-free, and
//! small enough to build into a stack buffer inside a draw function. Seven
//! glyphs at 1000 units per em exercise holes, overlapping contours, all-off-curve
//! contours, nested composites, the `hmtx` tail, both `cmap` formats, `kern` and
//! GPOS pair adjustment.
//!
//! | gid | char | shape |
//! |-----|------|-------|
//! | 0   |      | empty |
//! | 1   | A, a | square (100,0)-(700,700) with a reverse-winding hole (300,200)-(500,500) |
//! | 2   | B    | two same-winding overlapping squares |
//! | 3   | C    | rounded diamond, four off-curve points |
//! | 4   | D    | composite: gid 1 + gid 3 scaled 0.5 at (400, 0) |
//! | 5   | E    | composite: gid 4 through an identity 2x2 matrix |
//! | 6   | F    | triangle whose contour starts on an off-curve point |

const std = @import("std");

const truetype = @import("../truetype.zig");
const glyf_mod = @import("glyf.zig");
const VectorFont = @import("../VectorFont.zig");

pub const buffer_size = 16384;

pub const Options = struct {
    long_loca: bool = false,
    lsb_at_x_zero: bool = true,
    with_format12: bool = false,
    with_gpos: bool = true,
    with_kern: bool = true,
    /// gid 5 references itself.
    self_referencing: bool = false,
    /// gid 5 references gid 4 four hundred times, past the component budget.
    fanout: bool = false,
};

const Builder = struct {
    buf: []u8,
    pos: usize = 0,

    fn putU8(b: *Builder, v: u8) void {
        b.buf[b.pos] = v;
        b.pos += 1;
    }

    fn putU16(b: *Builder, v: u16) void {
        std.mem.writeInt(u16, b.buf[b.pos..][0..2], v, .big);
        b.pos += 2;
    }

    fn putI16(b: *Builder, v: i16) void {
        b.putU16(@bitCast(v));
    }

    fn putU32(b: *Builder, v: u32) void {
        std.mem.writeInt(u32, b.buf[b.pos..][0..4], v, .big);
        b.pos += 4;
    }

    fn f2dot14(b: *Builder, v: f32) void {
        b.putI16(@trunc(v * 16384));
    }

    fn zeros(b: *Builder, n: usize) void {
        @memset(b.buf[b.pos..][0..n], 0);
        b.pos += n;
    }

    fn pad4(b: *Builder) void {
        while (b.pos % 4 != 0) b.putU8(0);
    }

    fn patchU16(b: *Builder, at: usize, v: u16) void {
        std.mem.writeInt(u16, b.buf[at..][0..2], v, .big);
    }

    fn patchU32(b: *Builder, at: usize, v: u32) void {
        std.mem.writeInt(u32, b.buf[at..][0..4], v, .big);
    }
};

const Pt = struct { x: i16, y: i16, on: bool = true };

fn simpleGlyph(b: *Builder, bbox: [4]i16, contours: []const []const Pt) void {
    b.putI16(@intCast(contours.len));
    for (bbox) |v| b.putI16(v);
    var n: u16 = 0;
    for (contours) |c| {
        n += @intCast(c.len);
        b.putU16(n - 1);
    }
    b.putU16(0); // no instructions
    for (contours) |c| for (c) |p| b.putU8(if (p.on) glyf_mod.flag_on_curve else 0);
    var prev: i16 = 0;
    for (contours) |c| for (c) |p| {
        b.putI16(p.x - prev);
        prev = p.x;
    };
    prev = 0;
    for (contours) |c| for (c) |p| {
        b.putI16(p.y - prev);
        prev = p.y;
    };
}

fn component(b: *Builder, flags: u16, gid: u16, dx: i16, dy: i16) void {
    b.putU16(flags | glyf_mod.comp_arg_words | glyf_mod.comp_args_are_xy);
    b.putU16(gid);
    b.putI16(dx);
    b.putI16(dy);
}

const square_a = [_]Pt{ .{ .x = 100, .y = 0 }, .{ .x = 100, .y = 700 }, .{ .x = 700, .y = 700 }, .{ .x = 700, .y = 0 } };
const hole_a = [_]Pt{ .{ .x = 300, .y = 200 }, .{ .x = 500, .y = 200 }, .{ .x = 500, .y = 500 }, .{ .x = 300, .y = 500 } };
const square_b1 = [_]Pt{ .{ .x = 100, .y = 100 }, .{ .x = 100, .y = 500 }, .{ .x = 500, .y = 500 }, .{ .x = 500, .y = 100 } };
const square_b2 = [_]Pt{ .{ .x = 300, .y = 300 }, .{ .x = 300, .y = 700 }, .{ .x = 700, .y = 700 }, .{ .x = 700, .y = 300 } };
const diamond_c = [_]Pt{ .{ .x = 400, .y = 0, .on = false }, .{ .x = 800, .y = 350, .on = false }, .{ .x = 400, .y = 700, .on = false }, .{ .x = 0, .y = 350, .on = false } };
const triangle_f = [_]Pt{ .{ .x = 100, .y = 0, .on = false }, .{ .x = 700, .y = 0 }, .{ .x = 400, .y = 600 } };

/// Writes the glyphs and returns the offset of each glyph plus the end offset.
fn glyf(b: *Builder, opts: Options) [8]u32 {
    var offsets: [8]u32 = undefined;
    const base = b.pos;
    offsets[0] = 0;
    offsets[1] = @intCast(b.pos - base);
    simpleGlyph(b, .{ 100, 0, 700, 700 }, &.{ &square_a, &hole_a });
    offsets[2] = @intCast(b.pos - base);
    simpleGlyph(b, .{ 100, 100, 700, 700 }, &.{ &square_b1, &square_b2 });
    offsets[3] = @intCast(b.pos - base);
    simpleGlyph(b, .{ 0, 0, 800, 700 }, &.{&diamond_c});
    offsets[4] = @intCast(b.pos - base);
    b.putI16(-1);
    for ([_]i16{ 100, 0, 800, 700 }) |v| b.putI16(v);
    component(b, glyf_mod.comp_more, 1, 0, 0);
    component(b, glyf_mod.comp_have_scale, 3, 400, 0);
    b.f2dot14(0.5);
    offsets[5] = @intCast(b.pos - base);
    b.putI16(-1);
    for ([_]i16{ 100, 0, 800, 700 }) |v| b.putI16(v);
    if (opts.fanout) {
        for (0..399) |_| component(b, glyf_mod.comp_more, 4, 0, 0);
        component(b, 0, 4, 0, 0);
    } else {
        component(b, glyf_mod.comp_two_by_two, if (opts.self_referencing) 5 else 4, 0, 0);
        b.f2dot14(1);
        b.f2dot14(0);
        b.f2dot14(0);
        b.f2dot14(1);
    }
    offsets[6] = @intCast(b.pos - base);
    simpleGlyph(b, .{ 100, 0, 700, 600 }, &.{&triangle_f});
    b.pad4();
    offsets[7] = @intCast(b.pos - base);
    return offsets;
}

fn cmap4(b: *Builder) void {
    const start = b.pos;
    b.putU16(4);
    b.putU16(0); // length, patched
    b.putU16(0); // language
    b.putU16(6); // segCountX2
    b.putU16(4); // searchRange
    b.putU16(1); // entrySelector
    b.putU16(2); // rangeShift
    for ([_]u16{ 'F', 'a', 0xFFFF }) |v| b.putU16(v);
    b.putU16(0); // reservedPad
    for ([_]u16{ 'A', 'a', 0xFFFF }) |v| b.putU16(v);
    // idDelta: A..F map to 1..6; 'a' goes through glyphIdArray with delta 0.
    b.putI16(1 - 'A');
    b.putI16(0);
    b.putI16(1);
    // idRangeOffset: segment 1 points two entries ahead, at glyphIdArray[0].
    b.putU16(0);
    b.putU16(4);
    b.putU16(0);
    b.putU16(1); // glyphIdArray[0]
    b.patchU16(start + 2, @intCast(b.pos - start));
}

fn cmap12(b: *Builder) void {
    const start = b.pos;
    b.putU16(12);
    b.putU16(0);
    b.putU32(0); // length, patched
    b.putU32(0); // language
    b.putU32(2); // numGroups
    for ([_][3]u32{ .{ 'A', 'F', 1 }, .{ 0x1F600, 0x1F600, 3 } }) |g| for (g) |v| b.putU32(v);
    b.patchU32(start + 4, @intCast(b.pos - start));
}

fn cmap(b: *Builder, opts: Options) void {
    const start = b.pos;
    const records: u16 = if (opts.with_format12) 2 else 1;
    b.putU16(0);
    b.putU16(records);
    // The format 12 record comes first to prove selection is by format, not order.
    const first_record = b.pos;
    b.zeros(8 * @as(usize, records));
    var rec = first_record;
    if (opts.with_format12) {
        b.patchU16(rec, 3);
        b.patchU16(rec + 2, 10);
        b.patchU32(rec + 4, @intCast(b.pos - start));
        cmap12(b);
        rec += 8;
    }
    b.patchU16(rec, 3);
    b.patchU16(rec + 2, 1);
    b.patchU32(rec + 4, @intCast(b.pos - start));
    cmap4(b);
}

fn kernTable(b: *Builder) void {
    b.putU16(0); // version
    b.putU16(1); // nTables
    b.putU16(0); // subtable version
    b.putU16(20); // length
    b.putU16(0x0001); // coverage: horizontal, format 0
    b.putU16(1); // nPairs
    b.putU16(6); // searchRange
    b.putU16(0); // entrySelector
    b.putU16(0); // rangeShift
    b.putU16(1);
    b.putU16(2);
    b.putI16(-50);
}

fn gposTable(b: *Builder) void {
    b.putU16(1);
    b.putU16(0);
    b.putU16(10); // ScriptList
    b.putU16(12); // FeatureList
    b.putU16(14); // LookupList
    b.putU16(0); // empty ScriptList
    b.putU16(0); // empty FeatureList

    const lookup_list = b.pos;
    b.putU16(3);
    const lookup_offsets = b.pos;
    b.zeros(6);

    // Lookup 0: SinglePos, must be skipped.
    b.patchU16(lookup_offsets, @intCast(b.pos - lookup_list));
    var lookup = b.pos;
    b.putU16(1);
    b.putU16(0);
    b.putU16(1);
    b.putU16(8); // subtable right after this 8-byte header
    b.putU16(1); // SinglePos format 1
    b.putU16(8); // coverage offset
    b.putU16(0x0004);
    b.putI16(-999);
    b.putU16(1); // coverage format 1
    b.putU16(1);
    b.putU16(1);

    // Lookup 1: PairPos format 1, glyph 1 followed by glyph 3.
    b.patchU16(lookup_offsets + 2, @intCast(b.pos - lookup_list));
    lookup = b.pos;
    b.putU16(2);
    b.putU16(0);
    b.putU16(1);
    b.putU16(8);
    const pair1 = b.pos;
    b.putU16(1);
    b.putU16(0); // coverage, patched
    b.putU16(0x0004); // valueFormat1: XAdvance
    b.putU16(0);
    b.putU16(1); // pairSetCount
    b.putU16(0); // pairSetOffset, patched
    b.patchU16(pair1 + 2, @intCast(b.pos - pair1));
    b.putU16(1);
    b.putU16(1);
    b.putU16(1);
    b.patchU16(pair1 + 10, @intCast(b.pos - pair1));
    b.putU16(1); // pairValueCount
    b.putU16(3);
    b.putI16(-80);

    // Lookup 2: extension wrapping PairPos format 2, class pair (1, 1) for glyphs 1..2.
    b.patchU16(lookup_offsets + 4, @intCast(b.pos - lookup_list));
    lookup = b.pos;
    b.putU16(9);
    b.putU16(0);
    b.putU16(1);
    b.putU16(8);
    const ext = b.pos;
    b.putU16(1);
    b.putU16(2);
    b.putU32(8);
    const pair2 = b.pos;
    std.debug.assert(pair2 - ext == 8);
    b.putU16(2);
    b.putU16(0); // coverage, patched
    b.putU16(0x0005); // XPlacement | XAdvance, so the advance sits after another field
    b.putU16(0);
    b.putU16(0); // classDef1, patched
    b.putU16(0); // classDef2, patched
    b.putU16(2);
    b.putU16(2);
    for (0..3) |_| {
        b.putI16(0);
        b.putI16(0);
    }
    b.putI16(0);
    b.putI16(-30);
    b.patchU16(pair2 + 2, @intCast(b.pos - pair2));
    b.putU16(2); // coverage format 2
    b.putU16(1);
    b.putU16(1);
    b.putU16(2);
    b.putU16(0);
    b.patchU16(pair2 + 8, @intCast(b.pos - pair2));
    b.putU16(2); // classDef format 2
    b.putU16(1);
    b.putU16(1);
    b.putU16(2);
    b.putU16(1);
    b.patchU16(pair2 + 10, @intCast(b.pos - pair2));
    b.putU16(1); // classDef format 1
    b.putU16(2); // startGlyph
    b.putU16(1);
    b.putU16(1);
}

const TableRecord = struct { tag: *const [4]u8, offset: u32, len: u32 };

/// Assembles the font into `buf` (at least `buffer_size` bytes) and returns the used slice.
pub fn build(buf: []u8, opts: Options) []const u8 {
    var b: Builder = .{ .buf = buf };
    var records: [12]TableRecord = undefined;
    var count: usize = 0;
    const num_tables: usize = @as(usize, 9) + @intFromBool(opts.with_kern) + @intFromBool(opts.with_gpos);

    b.putU32(truetype.sfnt_true_type);
    b.putU16(@intCast(num_tables));
    b.putU16(0);
    b.putU16(0);
    b.putU16(0);
    const directory = b.pos;
    b.zeros(16 * num_tables);

    var glyph_offsets: [8]u32 = undefined;
    for (0..num_tables) |i| {
        const start = b.pos;
        const tag: *const [4]u8 = switch (i) {
            0 => "head",
            1 => "maxp",
            2 => "hhea",
            3 => "hmtx",
            4 => "OS/2",
            5 => "post",
            6 => "cmap",
            7 => "glyf",
            8 => "loca",
            9 => if (opts.with_kern) "kern" else "GPOS",
            10 => "GPOS",
            else => unreachable,
        };
        switch (i) {
            0 => {
                b.zeros(16);
                b.putU16(if (opts.lsb_at_x_zero) 0x0003 else 0x0001);
                b.putU16(1000);
                b.zeros(30);
                b.putI16(if (opts.long_loca) 1 else 0);
                b.putI16(0);
            },
            1 => {
                b.putU32(0x00010000);
                b.putU16(7);
                b.zeros(26);
            },
            2 => {
                b.putU32(0x00010000);
                b.putI16(900);
                b.putI16(-250);
                b.putI16(0);
                b.putU16(800);
                b.zeros(20);
                b.putI16(0);
                b.putU16(3);
            },
            3 => {
                b.putU16(500);
                b.putI16(0);
                b.putU16(800);
                b.putI16(if (opts.lsb_at_x_zero) 100 else 60);
                b.putU16(800);
                b.putI16(100);
                for ([_]i16{ 0, 50, 0, 100 }) |lsb| b.putI16(lsb);
            },
            4 => {
                b.zeros(26);
                b.putI16(50);
                b.putI16(300);
                b.zeros(38);
                b.putI16(800);
                b.putI16(-200);
                b.putI16(100);
                b.zeros(4);
            },
            5 => {
                b.putU32(0x00030000);
                b.putU32(0);
                b.putI16(-100);
                b.putI16(50);
                b.zeros(20);
            },
            6 => cmap(&b, opts),
            7 => glyph_offsets = glyf(&b, opts),
            8 => for (glyph_offsets) |off| {
                if (opts.long_loca) b.putU32(off) else b.putU16(@intCast(off / 2));
            },
            9, 10 => if (std.mem.eql(u8, tag, "kern")) kernTable(&b) else gposTable(&b),
            else => unreachable,
        }
        records[count] = .{ .tag = tag, .offset = @intCast(start), .len = @intCast(b.pos - start) };
        count += 1;
        b.pad4();
    }

    for (records[0..count], 0..) |rec, i| {
        const at = directory + 16 * i;
        @memcpy(b.buf[at..][0..4], rec.tag);
        b.patchU32(at + 4, 0);
        b.patchU32(at + 8, rec.offset);
        b.patchU32(at + 12, rec.len);
    }
    return b.buf[0..b.pos];
}

/// The synthetic font, parsed; `buf` must outlive it.
pub fn font(buf: *[buffer_size]u8, opts: Options) VectorFont {
    return VectorFont.loadFromBytes(build(buf, opts)) catch unreachable;
}

test "builds within the buffer" {
    var buf: [buffer_size]u8 = undefined;
    const plain = build(&buf, .{});
    try std.testing.expect(plain.len > 512 and plain.len < buffer_size);
    const big = build(&buf, .{ .fanout = true, .with_format12 = true, .long_loca = true });
    try std.testing.expect(big.len < buffer_size);
}
