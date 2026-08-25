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

const Pt = struct { x: i16, y: i16, on: bool = true };

const square_a = [_]Pt{ .{ .x = 100, .y = 0 }, .{ .x = 100, .y = 700 }, .{ .x = 700, .y = 700 }, .{ .x = 700, .y = 0 } };
const hole_a = [_]Pt{ .{ .x = 300, .y = 200 }, .{ .x = 500, .y = 200 }, .{ .x = 500, .y = 500 }, .{ .x = 300, .y = 500 } };
const square_b1 = [_]Pt{ .{ .x = 100, .y = 100 }, .{ .x = 100, .y = 500 }, .{ .x = 500, .y = 500 }, .{ .x = 500, .y = 100 } };
const square_b2 = [_]Pt{ .{ .x = 300, .y = 300 }, .{ .x = 300, .y = 700 }, .{ .x = 700, .y = 700 }, .{ .x = 700, .y = 300 } };
const diamond_c = [_]Pt{ .{ .x = 400, .y = 0, .on = false }, .{ .x = 800, .y = 350, .on = false }, .{ .x = 400, .y = 700, .on = false }, .{ .x = 0, .y = 350, .on = false } };
const triangle_f = [_]Pt{ .{ .x = 100, .y = 0, .on = false }, .{ .x = 700, .y = 0 }, .{ .x = 400, .y = 600 } };

/// Big-endian writer over the output buffer, plus the table writers.
const Builder = struct {
    buf: []u8,
    opts: Options,
    pos: usize = 0,
    /// Start of each glyph in `glyf` plus the end offset, for `loca`.
    glyph_offsets: [8]u32 = undefined,

    fn put(b: *Builder, comptime T: type, v: T) void {
        b.patch(T, b.pos, v);
        b.pos += @sizeOf(T);
    }

    fn putAll(b: *Builder, comptime T: type, vs: []const T) void {
        for (vs) |v| b.put(T, v);
    }

    fn f2dot14(b: *Builder, v: f32) void {
        b.put(i16, @trunc(v * 16384));
    }

    fn zeros(b: *Builder, n: usize) void {
        @memset(b.buf[b.pos..][0..n], 0);
        b.pos += n;
    }

    fn pad4(b: *Builder) void {
        b.zeros((4 - b.pos % 4) % 4);
    }

    fn patch(b: *Builder, comptime T: type, at: usize, v: T) void {
        std.mem.writeInt(T, b.buf[at..][0..@sizeOf(T)], v, .big);
    }

    fn simpleGlyph(b: *Builder, bbox: [4]i16, contours: []const []const Pt) void {
        b.put(i16, @intCast(contours.len));
        b.putAll(i16, &bbox);
        var n: u16 = 0;
        for (contours) |c| {
            n += @intCast(c.len);
            b.put(u16, n - 1);
        }
        b.put(u16, 0); // no instructions
        for (contours) |c| for (c) |p| b.put(u8, if (p.on) glyf_mod.flag_on_curve else 0);
        inline for (.{ "x", "y" }) |axis| {
            var prev: i16 = 0;
            for (contours) |c| for (c) |p| {
                b.put(i16, @field(p, axis) - prev);
                prev = @field(p, axis);
            };
        }
    }

    fn component(b: *Builder, flags: u16, gid: u16, dx: i16, dy: i16) void {
        b.put(u16, flags | glyf_mod.comp_arg_words | glyf_mod.comp_args_are_xy);
        b.put(u16, gid);
        b.put(i16, dx);
        b.put(i16, dy);
    }

    fn head(b: *Builder) void {
        b.zeros(16);
        b.put(u16, if (b.opts.lsb_at_x_zero) 0x0003 else 0x0001); // flags
        b.put(u16, 1000); // unitsPerEm
        b.zeros(30);
        b.put(i16, if (b.opts.long_loca) 1 else 0); // indexToLocFormat
        b.put(i16, 0);
    }

    fn maxp(b: *Builder) void {
        b.put(u32, 0x00010000);
        b.put(u16, 7); // numGlyphs
        b.zeros(26);
    }

    fn hhea(b: *Builder) void {
        b.put(u32, 0x00010000);
        b.putAll(i16, &.{ 900, -250, 0 }); // ascender, descender, lineGap
        b.put(u16, 800); // advanceWidthMax
        b.zeros(22);
        b.put(u16, 3); // numberOfHMetrics
    }

    fn hmtx(b: *Builder) void {
        b.putAll(u16, &.{ 500, 0, 800 });
        b.put(i16, if (b.opts.lsb_at_x_zero) 100 else 60); // gid 1 lsb
        b.putAll(i16, &.{ 800, 100 });
        b.putAll(i16, &.{ 0, 50, 0, 100 }); // lsb-only tail for gids 3..6
    }

    fn os2(b: *Builder) void {
        b.zeros(26);
        b.putAll(i16, &.{ 50, 300 }); // yStrikeoutSize, yStrikeoutPosition
        b.zeros(38);
        b.putAll(i16, &.{ 800, -200, 100 }); // sTypoAscender, sTypoDescender, sTypoLineGap
        b.zeros(4);
    }

    fn post(b: *Builder) void {
        b.put(u32, 0x00030000);
        b.put(u32, 0);
        b.putAll(i16, &.{ -100, 50 }); // underlinePosition, underlineThickness
        b.zeros(20);
    }

    fn cmap4(b: *Builder) void {
        const start = b.pos;
        b.putAll(u16, &.{ 4, 0, 0, 6, 4, 1, 2 }); // format, length (patched), language, segCountX2, search fields
        b.putAll(u16, &.{ 'F', 'a', 0xFFFF }); // endCode
        b.put(u16, 0); // reservedPad
        b.putAll(u16, &.{ 'A', 'a', 0xFFFF }); // startCode
        // idDelta: A..F map to 1..6; 'a' goes through glyphIdArray with delta 0.
        b.putAll(i16, &.{ 1 - 'A', 0, 1 });
        // idRangeOffset: segment 1 points two entries ahead, at glyphIdArray[0].
        b.putAll(u16, &.{ 0, 4, 0 });
        b.put(u16, 1); // glyphIdArray[0]
        b.patch(u16, start + 2, @intCast(b.pos - start));
    }

    fn cmap12(b: *Builder) void {
        const start = b.pos;
        b.putAll(u16, &.{ 12, 0 });
        b.putAll(u32, &.{ 0, 0, 2 }); // length (patched), language, numGroups
        b.putAll(u32, &.{ 'A', 'F', 1, 0x1F600, 0x1F600, 3 });
        b.patch(u32, start + 4, @intCast(b.pos - start));
    }

    fn cmap(b: *Builder) void {
        const start = b.pos;
        const records: u16 = if (b.opts.with_format12) 2 else 1;
        b.putAll(u16, &.{ 0, records });
        var rec = b.pos;
        b.zeros(8 * @as(usize, records));
        // The format 12 record comes first to prove selection is by format, not order.
        if (b.opts.with_format12) {
            b.patch(u16, rec, 3);
            b.patch(u16, rec + 2, 10);
            b.patch(u32, rec + 4, @intCast(b.pos - start));
            b.cmap12();
            rec += 8;
        }
        b.patch(u16, rec, 3);
        b.patch(u16, rec + 2, 1);
        b.patch(u32, rec + 4, @intCast(b.pos - start));
        b.cmap4();
    }

    fn glyf(b: *Builder) void {
        const base = b.pos;
        const offsets = &b.glyph_offsets;
        offsets[0] = 0;
        offsets[1] = @intCast(b.pos - base);
        b.simpleGlyph(.{ 100, 0, 700, 700 }, &.{ &square_a, &hole_a });
        offsets[2] = @intCast(b.pos - base);
        b.simpleGlyph(.{ 100, 100, 700, 700 }, &.{ &square_b1, &square_b2 });
        offsets[3] = @intCast(b.pos - base);
        b.simpleGlyph(.{ 0, 0, 800, 700 }, &.{&diamond_c});
        offsets[4] = @intCast(b.pos - base);
        b.putAll(i16, &.{ -1, 100, 0, 800, 700 });
        b.component(glyf_mod.comp_more, 1, 0, 0);
        b.component(glyf_mod.comp_have_scale, 3, 400, 0);
        b.f2dot14(0.5);
        offsets[5] = @intCast(b.pos - base);
        b.putAll(i16, &.{ -1, 100, 0, 800, 700 });
        if (b.opts.fanout) {
            for (0..399) |_| b.component(glyf_mod.comp_more, 4, 0, 0);
            b.component(0, 4, 0, 0);
        } else {
            b.component(glyf_mod.comp_two_by_two, if (b.opts.self_referencing) 5 else 4, 0, 0);
            for ([_]f32{ 1, 0, 0, 1 }) |v| b.f2dot14(v);
        }
        offsets[6] = @intCast(b.pos - base);
        b.simpleGlyph(.{ 100, 0, 700, 600 }, &.{&triangle_f});
        b.pad4();
        offsets[7] = @intCast(b.pos - base);
    }

    fn loca(b: *Builder) void {
        for (b.glyph_offsets) |off| {
            if (b.opts.long_loca) b.put(u32, off) else b.put(u16, @intCast(off / 2));
        }
    }

    fn kern(b: *Builder) void {
        b.putAll(u16, &.{ 0, 1 }); // version, nTables
        b.putAll(u16, &.{ 0, 20, 0x0001, 1, 6, 0, 0 }); // subtable: version, length, coverage (horizontal, format 0), nPairs, search fields
        b.putAll(u16, &.{ 1, 2 });
        b.put(i16, -50);
    }

    fn gpos(b: *Builder) void {
        b.putAll(u16, &.{ 1, 0, 10, 12, 14 }); // version, ScriptList, FeatureList, LookupList offsets
        b.putAll(u16, &.{ 0, 0 }); // empty ScriptList and FeatureList

        const lookup_list = b.pos;
        b.put(u16, 3);
        const lookup_offsets = b.pos;
        b.zeros(6);

        // Lookup 0: SinglePos, must be skipped.
        b.patch(u16, lookup_offsets, @intCast(b.pos - lookup_list));
        b.putAll(u16, &.{ 1, 0, 1, 8 }); // type, flag, subtableCount, subtable right after this header
        b.putAll(u16, &.{ 1, 8, 0x0004 }); // format 1, coverage offset, valueFormat
        b.put(i16, -999);
        b.putAll(u16, &.{ 1, 1, 1 }); // coverage format 1: [1]

        // Lookup 1: PairPos format 1, glyph 1 followed by glyph 3.
        b.patch(u16, lookup_offsets + 2, @intCast(b.pos - lookup_list));
        b.putAll(u16, &.{ 2, 0, 1, 8 });
        const pair1 = b.pos;
        b.putAll(u16, &.{ 1, 0, 0x0004, 0, 1, 0 }); // format, coverage (patched), valueFormat1: XAdvance, valueFormat2, pairSetCount, pairSetOffset (patched)
        b.patch(u16, pair1 + 2, @intCast(b.pos - pair1));
        b.putAll(u16, &.{ 1, 1, 1 }); // coverage format 1: [1]
        b.patch(u16, pair1 + 10, @intCast(b.pos - pair1));
        b.putAll(u16, &.{ 1, 3 }); // pairValueCount, secondGlyph
        b.put(i16, -80);

        // Lookup 2: extension wrapping PairPos format 2, class pair (1, 1) for glyphs 1..2.
        b.patch(u16, lookup_offsets + 4, @intCast(b.pos - lookup_list));
        b.putAll(u16, &.{ 9, 0, 1, 8 });
        b.putAll(u16, &.{ 1, 2 }); // extension format, extensionLookupType
        b.put(u32, 8); // extensionOffset: the subtable follows this 8-byte header
        const pair2 = b.pos;
        // format, coverage, valueFormat1: XPlacement | XAdvance (so the advance sits after another
        // field), valueFormat2, classDef1, classDef2, class1Count, class2Count; offsets patched
        b.putAll(u16, &.{ 2, 0, 0x0005, 0, 0, 0, 2, 2 });
        b.putAll(i16, &.{ 0, 0, 0, 0, 0, 0, 0, -30 }); // (class1, class2) records; only (1, 1) kerns
        b.patch(u16, pair2 + 2, @intCast(b.pos - pair2));
        b.putAll(u16, &.{ 2, 1, 1, 2, 0 }); // coverage format 2: glyphs 1..2 from index 0
        b.patch(u16, pair2 + 8, @intCast(b.pos - pair2));
        b.putAll(u16, &.{ 2, 1, 1, 2, 1 }); // classDef format 2: glyphs 1..2 are class 1
        b.patch(u16, pair2 + 10, @intCast(b.pos - pair2));
        b.putAll(u16, &.{ 1, 2, 1, 1 }); // classDef format 1: glyph 2 is class 1
    }
};

const Table = struct { tag: *const [4]u8, write: *const fn (*Builder) void };

const tables = [_]Table{
    .{ .tag = "head", .write = Builder.head },
    .{ .tag = "maxp", .write = Builder.maxp },
    .{ .tag = "hhea", .write = Builder.hhea },
    .{ .tag = "hmtx", .write = Builder.hmtx },
    .{ .tag = "OS/2", .write = Builder.os2 },
    .{ .tag = "post", .write = Builder.post },
    .{ .tag = "cmap", .write = Builder.cmap },
    .{ .tag = "glyf", .write = Builder.glyf },
    .{ .tag = "loca", .write = Builder.loca },
    .{ .tag = "kern", .write = Builder.kern },
    .{ .tag = "GPOS", .write = Builder.gpos },
};

/// Assembles the font into `buf` (at least `buffer_size` bytes) and returns the used slice.
pub fn build(buf: []u8, opts: Options) []const u8 {
    var b: Builder = .{ .buf = buf, .opts = opts };
    const num_tables = tables.len - @intFromBool(!opts.with_kern) - @intFromBool(!opts.with_gpos);

    b.put(u32, truetype.sfnt_true_type);
    b.putAll(u16, &.{ @intCast(num_tables), 0, 0, 0 });
    var record = b.pos;
    b.zeros(16 * num_tables);

    for (tables) |table| {
        if (std.mem.eql(u8, table.tag, "kern") and !opts.with_kern) continue;
        if (std.mem.eql(u8, table.tag, "GPOS") and !opts.with_gpos) continue;
        const start = b.pos;
        table.write(&b);
        @memcpy(b.buf[record..][0..4], table.tag);
        b.patch(u32, record + 4, 0); // checksum, unverified
        b.patch(u32, record + 8, @intCast(start));
        b.patch(u32, record + 12, @intCast(b.pos - start));
        record += 16;
        b.pad4();
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
