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
//!
//! `.collection` wraps either flavor in a two-face `ttcf` sharing one directory.
//! With `.cff`, the same header tables wrap a `CFF ` table instead of `loca`/`glyf`:
//!
//! | gid | shape |
//! |-----|-------|
//! | 0   | empty |
//! | 1   | the square and hole of gid 1, through `hlineto`/`vlineto` |
//! | 2   | the two squares of gid 2, with a leading width operand |
//! | 3   | diamond of four cubics in one `hvcurveto`, control box (0,0)-(800,700), ending on its start |
//! | 4   | gid 1 again, drawn by a local subr |
//! | 5   | triangle (100,0),(700,0),(400,600) behind a width, `hstemhm` and two `hintmask`s |
//! | 6   | the same triangle from `rlineto`, closed by an explicit line back to the start (or a `seac`, see `Options`) |
//!
//! The CFF charset names gids 1–6 `A`–`F` (SIDs 34–39).

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
    /// `OTTO` with a `CFF ` table instead of `loca`/`glyf`.
    cff: bool = false,
    /// `OTTO` with a `CFF2` table: the CFF glyphs without widths or `endchar`, gid 1 (and the
    /// subr) placing its first point through `blend`, gid 3 selecting `vsindex 0` first.
    cff2: bool = false,
    /// Add a format 4 FDSelect mapping every glyph to Font DICT 0.
    cff2_fd_select: bool = false,
    /// Write the variation store; without it `blend` cannot be interpreted.
    cff2_vstore: bool = true,
    /// Regions in the variation store; the charstrings carry deltas for one.
    cff2_regions: u16 = 1,
    /// Wrap the font in a `ttcf` header whose two faces share the table directory.
    collection: bool = false,
    /// CharstringType written to the Top DICT; only 2 is supported.
    cff_charstring_type: u8 = 2,
    /// The local subr calls itself, past the depth limit.
    cff_recursive_subr: bool = false,
    /// What gid 6 draws in the CFF variant: the triangle from lines, the same through a
    /// CFF2-only `blend`, or `seac` compositions of `A` (gid 1) and an accent `C` (gid 3) at
    /// (100, 200) — or `F` (itself) / an unencoded code.
    cff_gid6: enum { lines, blend, seac, seac_nested, seac_unencoded } = .lines,
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
    /// Positions of the Top DICT operands patched once their targets are written.
    top_dict: struct { char_strings: usize, private_size: usize, private_offset: usize, charset: usize } = undefined,

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

    /// A Type 2 charstring operand.
    fn csNum(b: *Builder, v: i16) void {
        if (v >= -107 and v <= 107) return b.put(u8, @intCast(v + 139));
        b.put(u8, 28);
        b.put(i16, v);
    }

    /// Operands followed by their operator.
    fn cs(b: *Builder, nums: []const i16, op: u8) void {
        for (nums) |v| b.csNum(v);
        b.put(u8, op);
    }

    /// An INDEX of `n` items with two-byte offsets, each written by `item`; CFF2 counts
    /// are four bytes wide.
    fn cffIndex(b: *Builder, comptime wide: bool, n: u16, item: *const fn (*Builder, usize) void) void {
        if (wide) b.put(u32, n) else b.put(u16, n);
        if (n == 0) return;
        b.put(u8, 2);
        const offsets = b.pos;
        b.zeros(2 * (@as(usize, n) + 1));
        const data = b.pos - 1;
        for (0..n) |i| {
            b.patch(u16, offsets + 2 * i, @intCast(b.pos - data));
            item(b, i);
        }
        b.patch(u16, offsets + 2 * n, @intCast(b.pos - data));
    }

    fn cffName(b: *Builder, _: usize) void {
        b.putAll(u8, "Synth");
    }

    /// Five-byte DICT integer, so it can be patched in place; returns the operand's position.
    fn dictInt(b: *Builder, v: i32) usize {
        b.put(u8, 29);
        defer b.put(i32, v);
        return b.pos;
    }

    fn cffTopDict(b: *Builder, _: usize) void {
        b.top_dict.char_strings = b.dictInt(0);
        b.put(u8, 17);
        b.top_dict.private_size = b.dictInt(0);
        b.top_dict.private_offset = b.dictInt(0);
        b.put(u8, 18);
        b.top_dict.charset = b.dictInt(0);
        b.put(u8, 15);
        b.cs(&.{b.opts.cff_charstring_type}, 12);
        b.put(u8, 6);
    }

    const rmoveto = 21;
    const rlineto = 5;
    const hlineto = 6;
    const vlineto = 7;
    const hvcurveto = 31;
    const hstemhm = 18;
    const hintmask = 19;
    const callsubr = 10;
    const cs_return = 11;
    const endchar = 14;
    const vsindex = 15;
    const blend = 16;

    /// The first point's default (100, 0) with one delta per value, which `blend` drops.
    fn blendedMove(b: *Builder) void {
        b.cs(&.{ 100, 0, 5, 7, 2 }, blend);
        b.cs(&.{}, rmoveto);
    }

    fn squareWithHole(b: *Builder) void {
        if (b.opts.cff2) b.blendedMove() else b.cs(&.{ 100, 0 }, rmoveto);
        b.cs(&.{700}, vlineto);
        b.cs(&.{600}, hlineto);
        b.cs(&.{-700}, vlineto);
        b.cs(&.{ -400, 200 }, rmoveto);
        b.cs(&.{ 200, 300, -200 }, hlineto);
    }

    fn cffCharString(b: *Builder, gid: usize) void {
        switch (gid) {
            0 => {},
            1 => b.squareWithHole(),
            2 => {
                if (!b.opts.cff2) b.csNum(500); // width
                b.cs(&.{ 100, 100 }, rmoveto);
                b.cs(&.{ 0, 400, 400, 0, 0, -400 }, rlineto);
                b.cs(&.{ -200, 200 }, rmoveto);
                b.cs(&.{ 0, 400, 400, 0, 0, -400 }, rlineto);
            },
            3 => {
                if (b.opts.cff2) b.cs(&.{0}, vsindex);
                b.cs(&.{ 400, 0 }, rmoveto);
                b.cs(&.{ 200, 200, 175, 175, 175, -200, 175, -200, -200, -200, -175, -175, -175, 200, -175, 200 }, hvcurveto);
            },
            4 => b.cs(&.{-107}, callsubr),
            5 => {
                if (!b.opts.cff2) b.csNum(500); // width
                b.cs(&.{ 20, 100 }, hstemhm);
                b.cs(&.{ 30, 100 }, hintmask);
                b.put(u8, 0xC0);
                b.cs(&.{ 100, 0 }, rmoveto);
                b.cs(&.{600}, hlineto);
                b.cs(&.{}, hintmask);
                b.put(u8, 0x80);
                b.cs(&.{ -300, 600 }, rlineto);
            },
            6 => switch (b.opts.cff_gid6) {
                .lines, .blend => {
                    if (b.opts.cff_gid6 == .blend) b.blendedMove() else b.cs(&.{ 100, 0 }, rmoveto);
                    b.cs(&.{ 600, 0, -300, 600, -300, -600 }, rlineto);
                },
                // The operands of the closing `endchar`.
                .seac => for ([_]i16{ 100, 200, 'A', 'C' }) |v| b.csNum(v),
                .seac_nested => for ([_]i16{ 100, 200, 'A', 'F' }) |v| b.csNum(v),
                .seac_unencoded => for ([_]i16{ 100, 200, 'A', 128 }) |v| b.csNum(v),
            },
            else => unreachable,
        }
        if (!b.opts.cff2) b.cs(&.{}, endchar);
    }

    fn cffSubr(b: *Builder, _: usize) void {
        if (b.opts.cff_recursive_subr) b.cs(&.{-107}, callsubr) else b.squareWithHole();
        b.cs(&.{}, cs_return);
    }

    fn cff(b: *Builder) void {
        const base = b.pos;
        b.putAll(u8, &.{ 1, 0, 4, 1 }); // major, minor, hdrSize, offSize
        b.cffIndex(false, 1, Builder.cffName);
        b.cffIndex(false, 1, Builder.cffTopDict);
        b.put(u16, 0); // String INDEX
        b.put(u16, 0); // Global Subr INDEX
        b.patch(i32, b.top_dict.char_strings, @intCast(b.pos - base));
        b.cffIndex(false, 7, Builder.cffCharString);
        b.patch(i32, b.top_dict.private_size, 2);
        b.patch(i32, b.top_dict.private_offset, @intCast(b.pos - base));
        b.cs(&.{2}, 19); // Subrs right after the Private DICT
        b.cffIndex(false, 1, Builder.cffSubr);
        b.patch(i32, b.top_dict.charset, @intCast(b.pos - base));
        b.put(u8, 0); // charset format 0: SIDs of gids 1..6
        b.putAll(u16, &.{ 34, 35, 36, 37, 38, 39 });
    }

    fn cff2FontDict(b: *Builder, _: usize) void {
        b.top_dict.private_size = b.dictInt(0);
        b.top_dict.private_offset = b.dictInt(0);
        b.put(u8, 18);
    }

    fn cff2(b: *Builder) void {
        const base = b.pos;
        b.putAll(u8, &.{ 2, 0, 5 }); // major, minor, hdrSize
        const top_len_at = b.pos;
        b.put(u16, 0); // topDictLength, patched
        const top = b.pos;
        b.top_dict.char_strings = b.dictInt(0);
        b.put(u8, 17);
        const fd_array_at = b.dictInt(0);
        b.putAll(u8, &.{ 12, 36 });
        var fd_select_at: usize = 0;
        if (b.opts.cff2_fd_select) {
            fd_select_at = b.dictInt(0);
            b.putAll(u8, &.{ 12, 37 });
        }
        var vstore_at: usize = 0;
        if (b.opts.cff2_vstore) {
            vstore_at = b.dictInt(0);
            b.put(u8, 24);
        }
        b.patch(u16, top_len_at, @intCast(b.pos - top));
        b.put(u32, 0); // Global Subr INDEX
        b.patch(i32, b.top_dict.char_strings, @intCast(b.pos - base));
        b.cffIndex(true, 7, Builder.cffCharString);
        b.patch(i32, fd_array_at, @intCast(b.pos - base));
        b.cffIndex(true, 1, Builder.cff2FontDict);
        b.patch(i32, b.top_dict.private_size, 4);
        b.patch(i32, b.top_dict.private_offset, @intCast(b.pos - base));
        b.cs(&.{0}, 22); // vsindex
        b.cs(&.{4}, 19); // Subrs right after this Private DICT
        b.cffIndex(true, 1, Builder.cffSubr);
        if (b.opts.cff2_fd_select) {
            b.patch(i32, fd_select_at, @intCast(b.pos - base));
            b.put(u8, 4); // format 4: one range covering every glyph
            b.putAll(u32, &.{ 1, 0 }); // nRanges, first
            b.put(u16, 0); // fd
            b.put(u32, 7); // sentinel
        }
        if (b.opts.cff2_vstore) {
            b.patch(i32, vstore_at, @intCast(b.pos - base));
            const len_at = b.pos;
            b.put(u16, 0); // length, patched
            const store = b.pos;
            b.put(u16, 1); // format
            b.put(u32, 0); // variationRegionListOffset, patched
            b.put(u16, 1); // itemVariationDataCount
            b.put(u32, 0); // itemVariationDataOffsets[0], patched
            b.patch(u32, store + 2, @intCast(b.pos - store));
            b.putAll(u16, &.{ 1, b.opts.cff2_regions }); // axisCount, regionCount
            for (0..b.opts.cff2_regions) |_| b.putAll(i16, &.{ 0, 16384, 16384 }); // start, peak, end
            b.patch(u32, store + 8, @intCast(b.pos - store));
            b.putAll(u16, &.{ 0, 0, b.opts.cff2_regions }); // itemCount, wordDeltaCount, regionIndexCount
            for (0..b.opts.cff2_regions) |i| b.put(u16, @intCast(i));
            b.patch(u16, len_at, @intCast(b.pos - store));
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
    .{ .tag = "CFF ", .write = Builder.cff },
    .{ .tag = "CFF2", .write = Builder.cff2 },
    .{ .tag = "kern", .write = Builder.kern },
    .{ .tag = "GPOS", .write = Builder.gpos },
};

/// Assembles the font into `buf` (at least `buffer_size` bytes) and returns the used slice.
pub fn build(buf: []u8, opts: Options) []const u8 {
    var b: Builder = .{ .buf = buf, .opts = opts };
    // Of the four outline tables, glyf/loca take two and CFF/CFF2 one.
    const postscript = opts.cff or opts.cff2;
    const num_tables = tables.len - 4 + @as(usize, if (postscript) 1 else 2) - @intFromBool(!opts.with_kern) - @intFromBool(!opts.with_gpos);

    if (opts.collection) {
        @memcpy(b.buf[0..4], "ttcf");
        b.pos = 4;
        b.putAll(u16, &.{ 1, 0 }); // version 1.0
        b.put(u32, 2); // numFonts
        b.putAll(u32, &.{ 20, 20 }); // both faces start right after this header
    }
    b.put(u32, if (postscript) truetype.sfnt_cff else truetype.sfnt_true_type);
    b.putAll(u16, &.{ @intCast(num_tables), 0, 0, 0 });
    var record = b.pos;
    b.zeros(16 * num_tables);

    for (tables) |table| {
        if (std.mem.eql(u8, table.tag, "kern") and !opts.with_kern) continue;
        if (std.mem.eql(u8, table.tag, "GPOS") and !opts.with_gpos) continue;
        const glyf_table = std.mem.eql(u8, table.tag, "glyf") or std.mem.eql(u8, table.tag, "loca");
        if (glyf_table and postscript) continue;
        if (std.mem.eql(u8, table.tag, "CFF ") and (!opts.cff or opts.cff2)) continue;
        if (std.mem.eql(u8, table.tag, "CFF2") and !opts.cff2) continue;
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
    const cff = build(&buf, .{ .cff = true });
    try std.testing.expect(cff.len > 512 and cff.len < buffer_size);
    const cff2 = build(&buf, .{ .cff2 = true, .cff2_fd_select = true, .cff2_regions = 3 });
    try std.testing.expect(cff2.len > 512 and cff2.len < buffer_size);
}
