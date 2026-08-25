//! `CFF ` and `CFF2` table parsing for OpenType fonts with PostScript outlines: the
//! INDEX and DICT containers, then a Type 2 charstring interpreter that turns a
//! glyph into cubic contours in font units. Everything is read in place; nothing is
//! decoded at load time beyond locating the CharStrings, Subrs and (for CID-keyed
//! fonts) the FDArray/FDSelect. Accent composition (`seac`) resolves its two glyphs
//! through the charset and Standard Encoding. CFF2 fonts render their default
//! instance: `blend` keeps the default values and drops the deltas.

const std = @import("std");
const Allocator = std.mem.Allocator;

const truetype = @import("../truetype.zig");
const Error = truetype.Error;
const Reader = truetype.Reader;
const Table = truetype.Table;
const VectorFont = @import("../VectorFont.zig");
const Outline = @import("../Outline.zig");

pub const max_subr_depth = 10;
/// The CFF2 limit; CFF allows 48 and merely gets the extra room.
pub const max_stack = 513;
/// Operators executed per glyph, subrs included; bounds hostile subr fan-out.
pub const max_ops = 1 << 16;
pub const max_outline_points = 0xFFFF;
/// CFF2 Private DICTs blend their hint values, so their operand stacks are as deep as
/// charstring stacks.
const max_dict_operands = max_stack;

/// An INDEX: `count` items addressed through 1-based offsets of `off_size` bytes each.
pub const Index = struct {
    count: u32,
    off_size: u8,
    /// Position of the offset array.
    offsets: u32,
    /// Position of the object data minus one, since offsets are 1-based.
    data: u32,

    pub const empty: Index = .{ .count = 0, .off_size = 1, .offsets = 0, .data = 0 };

    const Parsed = struct { index: Index, end: u32 };

    /// Parses the INDEX at `pos`; `end` is the position just past it. CFF2 counts are
    /// four bytes wide.
    fn parse(r: Reader, pos: u32, comptime version: Version) Error!Parsed {
        const count_size: u32 = if (version == .cff2) 4 else 2;
        const count: u32 = if (version == .cff2) try r.u32At(pos) else try r.u16At(pos);
        if (count == 0) return .{ .index = .empty, .end = pos + count_size };
        const off_size = try r.u8At(pos + count_size);
        if (off_size == 0 or off_size > 4) return error.InvalidFormat;
        const offsets: u64 = pos + count_size + 1;
        const data = offsets + (@as(u64, count) + 1) * off_size - 1;
        if (data > r.data.len) return error.UnexpectedEof;
        const index: Index = .{ .count = count, .off_size = off_size, .offsets = @intCast(offsets), .data = @intCast(data) };
        const end = data + try index.offset(r, count);
        if (end > r.data.len) return error.UnexpectedEof;
        return .{ .index = index, .end = @intCast(end) };
    }

    fn offset(self: Index, r: Reader, i: u32) Error!u32 {
        const at = std.math.add(u32, self.offsets, i * self.off_size) catch return error.UnexpectedEof;
        var v: u32 = 0;
        for (try r.slice(at, self.off_size)) |b| v = (v << 8) | b;
        return v;
    }

    pub fn item(self: Index, r: Reader, i: u32) Error![]const u8 {
        if (i >= self.count) return error.InvalidFormat;
        const start = try self.offset(r, i);
        const end = try self.offset(r, i + 1);
        if (end < start) return error.InvalidFormat;
        const at = std.math.add(u32, self.data, start) catch return error.UnexpectedEof;
        return r.slice(at, end - start);
    }
};

pub const Version = enum { cff, cff2 };

/// DICT operators; two-byte ones are `0x0c00 | second byte`.
const Op = struct {
    const charset = 15;
    const char_strings = 17;
    const private = 18;
    const subrs = 19;
    const vsindex = 22;
    const vstore = 24;
    const charstring_type = 0x0c06;
    const ros = 0x0c1e;
    const fd_array = 0x0c24;
    const fd_select = 0x0c25;
};

/// The operands of the first `op` in `dict`, or null when absent. Real operands decode
/// as 0; none of the operators read here take any.
fn dictGet(dict: []const u8, comptime op: u16, comptime n: usize) Error!?[n]i32 {
    var operands: [max_dict_operands]i32 = undefined;
    var count: usize = 0;
    var i: usize = 0;
    while (i < dict.len) {
        const b0 = dict[i];
        i += 1;
        const v: i32 = switch (b0) {
            // Operators; 22–27 are reserved in CFF and CFF2's vsindex, blend and vstore.
            0...27 => {
                var found: u16 = b0;
                if (b0 == 12) {
                    if (i >= dict.len) return error.UnexpectedEof;
                    found = 0x0c00 | @as(u16, dict[i]);
                    i += 1;
                }
                if (found == op) {
                    if (count < n) return error.InvalidFormat;
                    return operands[count - n ..][0..n].*;
                }
                count = 0;
                continue;
            },
            28 => blk: {
                if (i + 2 > dict.len) return error.UnexpectedEof;
                defer i += 2;
                break :blk std.mem.readInt(i16, dict[i..][0..2], .big);
            },
            29 => blk: {
                if (i + 4 > dict.len) return error.UnexpectedEof;
                defer i += 4;
                break :blk std.mem.readInt(i32, dict[i..][0..4], .big);
            },
            30 => blk: {
                // Nibble-packed real, terminated by an 0xf nibble.
                while (true) {
                    if (i >= dict.len) return error.UnexpectedEof;
                    const b = dict[i];
                    i += 1;
                    if (b & 0x0f == 0x0f or b >> 4 == 0x0f) break;
                }
                break :blk 0;
            },
            32...246 => @as(i32, b0) - 139,
            247...250 => blk: {
                if (i >= dict.len) return error.UnexpectedEof;
                defer i += 1;
                break :blk (@as(i32, b0) - 247) * 256 + dict[i] + 108;
            },
            251...254 => blk: {
                if (i >= dict.len) return error.UnexpectedEof;
                defer i += 1;
                break :blk -(@as(i32, b0) - 251) * 256 - @as(i32, dict[i]) - 108;
            },
            else => return error.InvalidFormat,
        };
        if (count == max_dict_operands) return error.InvalidFormat;
        operands[count] = v;
        count += 1;
    }
    return null;
}

fn toOffset(v: i32) Error!u32 {
    return if (v < 0) error.InvalidFormat else @intCast(v);
}

/// What a glyph needs from its Private DICT.
const Private = struct {
    subrs: Index = .empty,
    /// CFF2: the default ItemVariationData index for `blend`.
    vsindex: u32 = 0,

    /// Reads the Private DICT described by `size, offset`.
    fn parse(r: Reader, at: [2]i32, version: Version) Error!Private {
        const size = try toOffset(at[0]);
        const offset = try toOffset(at[1]);
        const dict = try r.slice(offset, size);
        var private: Private = .{};
        if (try dictGet(dict, Op.vsindex, 1)) |v| private.vsindex = try toOffset(v[0]);
        const subrs = try dictGet(dict, Op.subrs, 1) orelse return private;
        const subrs_at = std.math.add(u32, offset, try toOffset(subrs[0])) catch return error.UnexpectedEof;
        private.subrs = switch (version) {
            .cff => (try Index.parse(r, subrs_at, .cff)).index,
            .cff2 => (try Index.parse(r, subrs_at, .cff2)).index,
        };
        return private;
    }
};

pub const Font = struct {
    /// The `CFF ` or `CFF2` table; every position in this struct is relative to it.
    table: Table,
    version: Version,
    char_strings: Index,
    global_subrs: Index,
    /// The single Private DICT; unused by CID-keyed and CFF2 fonts.
    private: Private,
    /// CID-keyed (and all CFF2) fonts select a Font DICT per glyph, each with its own
    /// Private DICT and Subrs.
    cid: ?Cid,
    /// Position of the charset (glyph → SID), or 0/1/2 for the predefined ones; only `seac`
    /// reads it.
    charset: u32,
    /// CFF2: position of the ItemVariationStore, which `blend` consults for region counts.
    vstore: ?u32,

    pub const Cid = struct {
        fd_array: Index,
        /// Position of the FDSelect table, validated for its format at load time; CFF2 may
        /// omit it, in which case every glyph uses Font DICT 0.
        fd_select: ?u32,
    };

    /// Font DICT index for `gid` from FDSelect formats 0, 3 and 4.
    fn fdIndex(self: Font, r: Reader, gid: u16) Error!u16 {
        const cid = self.cid orelse return error.InvalidFormat;
        const pos = cid.fd_select orelse return 0;
        switch (try r.u8At(pos)) {
            0 => return try r.u8At(pos + 1 + gid),
            3 => return rangeLookup(r, pos + 1, gid, .u16),
            4 => return rangeLookup(r, pos + 1, gid, .u32),
            else => return error.InvalidFormat,
        }
    }

    /// Binary search over `n` ranges of (first gid, fd) sorted by first gid, followed by a
    /// sentinel gid; format 3 stores `u16 first, u8 fd`, format 4 `u32 first, u16 fd`.
    fn rangeLookup(r: Reader, pos: u32, gid: u16, comptime width: enum { u16, u32 }) Error!u16 {
        const wide = width == .u32;
        const stride: u32 = if (wide) 6 else 3;
        const num_ranges: u32 = if (wide) try r.u32At(pos) else try r.u16At(pos);
        const ranges = pos + @as(u32, if (wide) 4 else 2);
        const first = struct {
            fn at(rr: Reader, base: u32, i: u32) Error!u32 {
                return if (wide) try rr.u32At(base + i * stride) else try rr.u16At(base + i * stride);
            }
        }.at;
        var lo: u32 = 0;
        var hi: u32 = num_ranges;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (try first(r, ranges, mid) <= gid) lo = mid else hi = mid;
        }
        if (num_ranges == 0 or try first(r, ranges, lo) > gid or gid >= try first(r, ranges, hi)) return error.InvalidGlyph;
        return if (wide) try r.u16At(ranges + lo * stride + 4) else try r.u8At(ranges + lo * stride + 2);
    }

    fn glyphPrivate(self: Font, r: Reader, gid: u16) Error!Private {
        const cid = self.cid orelse return self.private;
        const fd = try cid.fd_array.item(r, try self.fdIndex(r, gid));
        const private = try dictGet(fd, Op.private, 2) orelse return .{};
        return Private.parse(r, private, self.version);
    }

    /// Regions blended by ItemVariationData `vsindex` of the CFF2 variation store, i.e. the
    /// number of deltas per value that `blend` drops.
    fn regionCount(self: Font, r: Reader, vsindex: u32) Error!u32 {
        const vstore = self.vstore orelse return error.InvalidGlyph;
        const store = vstore + 2; // past the u16 length
        if (try r.u16At(store) != 1) return error.InvalidFormat;
        if (vsindex >= try r.u16At(store + 6)) return error.InvalidGlyph;
        const data = std.math.add(u32, store, try r.u32At(store + 8 + 4 * vsindex)) catch return error.UnexpectedEof;
        return try r.u16At(data + 4);
    }

    /// The glyph named by standard string `sid`: a walk over charset formats 0, 1 and 2.
    /// Only ISOAdobe (identity) is supported among the predefined charsets.
    fn glyphForSid(self: Font, r: Reader, sid: u16) Error!u16 {
        const count = self.char_strings.count;
        switch (self.charset) {
            0 => return if (sid < count) sid else error.InvalidGlyph,
            1, 2 => return error.InvalidGlyph,
            else => {},
        }
        const format = try r.u8At(self.charset);
        var at = self.charset + 1;
        var gid: u32 = 1; // .notdef is implicit
        while (gid < count) {
            switch (format) {
                0 => {
                    if (try r.u16At(at) == sid) return @intCast(gid);
                    at += 2;
                    gid += 1;
                },
                1, 2 => {
                    const first = try r.u16At(at);
                    const n_left: u32 = if (format == 1) try r.u8At(at + 2) else try r.u16At(at + 2);
                    at += if (format == 1) 3 else 4;
                    if (sid >= first and sid - first <= n_left) {
                        const found = gid + (sid - first);
                        return if (found < count) @intCast(found) else error.InvalidGlyph;
                    }
                    gid += n_left + 1;
                },
                else => return error.InvalidFormat,
            }
        }
        return error.InvalidGlyph;
    }
};

/// Standard Encoding: character code → standard string SID (CFF spec, Appendix B); 0 for
/// unencoded codes.
const standard_encoding: [256]u8 = blk: {
    var table: [256]u8 = @splat(0);
    // Codes 32–126 hold SIDs 1–95 in order.
    for (32..127) |code| table[code] = code - 31;
    const upper = [_]struct { u8, u8 }{
        .{ 161, 96 },  .{ 162, 97 },  .{ 163, 98 },  .{ 164, 99 },  .{ 165, 100 }, .{ 166, 101 }, .{ 167, 102 }, .{ 168, 103 },
        .{ 169, 104 }, .{ 170, 105 }, .{ 171, 106 }, .{ 172, 107 }, .{ 173, 108 }, .{ 174, 109 }, .{ 175, 110 }, .{ 177, 111 },
        .{ 178, 112 }, .{ 179, 113 }, .{ 180, 114 }, .{ 182, 115 }, .{ 183, 116 }, .{ 184, 117 }, .{ 185, 118 }, .{ 186, 119 },
        .{ 187, 120 }, .{ 188, 121 }, .{ 189, 122 }, .{ 191, 123 }, .{ 193, 124 }, .{ 194, 125 }, .{ 195, 126 }, .{ 196, 127 },
        .{ 197, 128 }, .{ 198, 129 }, .{ 199, 130 }, .{ 200, 131 }, .{ 202, 132 }, .{ 203, 133 }, .{ 205, 134 }, .{ 206, 135 },
        .{ 207, 136 }, .{ 208, 137 }, .{ 225, 138 }, .{ 227, 139 }, .{ 232, 140 }, .{ 233, 141 }, .{ 234, 142 }, .{ 235, 143 },
        .{ 241, 144 }, .{ 245, 145 }, .{ 248, 146 }, .{ 249, 147 }, .{ 250, 148 }, .{ 251, 149 },
    };
    for (upper) |entry| table[entry[0]] = entry[1];
    break :blk table;
};

/// SID of the glyph at Standard Encoding `code`, as a `seac` operand names it.
fn standardSid(code: f32) Error!u16 {
    if (!(code >= 0 and code <= 255)) return error.InvalidGlyph;
    const sid = standard_encoding[@intFromFloat(code)];
    return if (sid == 0) error.InvalidGlyph else sid;
}

/// Locates the CharStrings, Subrs and CID structures of the `CFF ` table `t` of the
/// font `font_reader` covers. Only Type 2 charstrings are accepted.
pub fn parse(t: Table, font_reader: Reader, num_glyphs: u16) Error!Font {
    const r = font_reader.table(t);
    const header_size = try r.u8At(2);
    const names = try Index.parse(r, header_size, .cff);
    const top_dicts = try Index.parse(r, names.end, .cff);
    const strings = try Index.parse(r, top_dicts.end, .cff);
    const global_subrs = try Index.parse(r, strings.end, .cff);
    const top = try top_dicts.index.item(r, 0);

    if (try dictGet(top, Op.charstring_type, 1)) |v| if (v[0] != 2) return error.UnsupportedFontFormat;
    const char_strings_at = try dictGet(top, Op.char_strings, 1) orelse return error.MissingTable;
    const char_strings = (try Index.parse(r, try toOffset(char_strings_at[0]), .cff)).index;
    if (char_strings.count != num_glyphs) return error.InvalidFormat;

    var font: Font = .{
        .table = t,
        .version = .cff,
        .char_strings = char_strings,
        .global_subrs = global_subrs.index,
        .private = .{},
        .cid = null,
        .charset = if (try dictGet(top, Op.charset, 1)) |v| try toOffset(v[0]) else 0,
        .vstore = null,
    };
    if (try dictGet(top, Op.ros, 3) != null) {
        const fd_array_at = try dictGet(top, Op.fd_array, 1) orelse return error.MissingTable;
        const fd_select_at = try dictGet(top, Op.fd_select, 1) orelse return error.MissingTable;
        font.cid = .{
            .fd_array = (try Index.parse(r, try toOffset(fd_array_at[0]), .cff)).index,
            .fd_select = try validateFdSelect(r, try toOffset(fd_select_at[0]), num_glyphs),
        };
    } else {
        const private = try dictGet(top, Op.private, 2) orelse return error.MissingTable;
        font.private = try Private.parse(r, private, .cff);
    }
    return font;
}

/// `parse` for a `CFF2` table: no Name/String INDEX or charset, the Top DICT inline
/// after the header, wide INDEX counts, and Font DICTs for every glyph.
pub fn parse2(t: Table, font_reader: Reader, num_glyphs: u16) Error!Font {
    const r = font_reader.table(t);
    if (try r.u8At(0) != 2) return error.UnsupportedFontFormat;
    const header_size = try r.u8At(2);
    const top_len = try r.u16At(3);
    const top = try r.slice(header_size, top_len);
    const global_subrs = try Index.parse(r, header_size + top_len, .cff2);

    const char_strings_at = try dictGet(top, Op.char_strings, 1) orelse return error.MissingTable;
    const char_strings = (try Index.parse(r, try toOffset(char_strings_at[0]), .cff2)).index;
    if (char_strings.count != num_glyphs) return error.InvalidFormat;
    const fd_array_at = try dictGet(top, Op.fd_array, 1) orelse return error.MissingTable;
    const fd_select: ?u32 = if (try dictGet(top, Op.fd_select, 1)) |v| try validateFdSelect(r, try toOffset(v[0]), num_glyphs) else null;

    return .{
        .table = t,
        .version = .cff2,
        .char_strings = char_strings,
        .global_subrs = global_subrs.index,
        .private = .{},
        .cid = .{
            .fd_array = (try Index.parse(r, try toOffset(fd_array_at[0]), .cff2)).index,
            .fd_select = fd_select,
        },
        .charset = 0,
        .vstore = if (try dictGet(top, Op.vstore, 1)) |v| try toOffset(v[0]) else null,
    };
}

/// Checks that the FDSelect at `pos` has a known format and fits the table.
fn validateFdSelect(r: Reader, pos: u32, num_glyphs: u16) Error!u32 {
    switch (try r.u8At(pos)) {
        0 => _ = try r.slice(pos + 1, num_glyphs),
        3 => _ = try r.slice(pos + 3, 3 * @as(usize, try r.u16At(pos + 1)) + 2),
        4 => _ = try r.slice(pos + 5, 6 * @as(usize, try r.u32At(pos + 1)) + 4),
        else => return error.InvalidFormat,
    }
    return pos;
}

/// Receives the decoded path; counts only when the output slices are absent, and
/// tracks the control box either way.
const Sink = struct {
    points: ?[]Outline.Point = null,
    contour_ends: ?[]u32 = null,
    n: u32 = 0,
    c: u32 = 0,
    contour_start: u32 = 0,
    start: [2]f32 = .{ 0, 0 },
    /// The latest on-curve point, held back until the next segment or `close` shows
    /// whether it merely returns to the contour's start.
    pending: ?[2]f32 = null,
    min: [2]f32 = .{ std.math.inf(f32), std.math.inf(f32) },
    max: [2]f32 = .{ -std.math.inf(f32), -std.math.inf(f32) },

    fn write(self: *Sink, x: f32, y: f32, kind: Outline.Point.Kind) void {
        if (self.points) |points| points[self.n] = .{ .x = x, .y = y, .kind = kind };
        self.n += 1;
        self.min = .{ @min(self.min[0], x), @min(self.min[1], y) };
        self.max = .{ @max(self.max[0], x), @max(self.max[1], y) };
    }

    fn flush(self: *Sink) void {
        if (self.pending) |p| self.write(p[0], p[1], .on_curve);
        self.pending = null;
    }

    fn moveTo(self: *Sink, x: f32, y: f32) void {
        self.close();
        self.contour_start = self.n;
        self.start = .{ x, y };
        self.write(x, y, .on_curve);
    }

    fn lineTo(self: *Sink, x: f32, y: f32) void {
        self.flush();
        self.pending = .{ x, y };
    }

    fn curveTo(self: *Sink, c1: [2]f32, c2: [2]f32, x: f32, y: f32) void {
        self.flush();
        self.write(c1[0], c1[1], .cubic_control);
        self.write(c2[0], c2[1], .cubic_control);
        self.pending = .{ x, y };
    }

    /// Ends the open contour. Contours close implicitly, so a final point back on the
    /// start is redundant and dropped. Written points are never taken back, which keeps
    /// the count and fill runs in step; a lone `moveto` stays as a one-point contour that
    /// `Outline` skips.
    fn close(self: *Sink) void {
        if (self.pending) |p| {
            if (p[0] != self.start[0] or p[1] != self.start[1]) self.write(p[0], p[1], .on_curve);
            self.pending = null;
        }
        if (self.n == self.contour_start) return;
        if (self.contour_ends) |ends| ends[self.c] = self.n;
        self.c += 1;
        self.contour_start = self.n;
    }
};

/// Type 2 charstring interpreter state for one glyph.
const Vm = struct {
    r: Reader,
    cff: Font,
    local_subrs: Index,
    sink: *Sink,
    /// Set while drawing the components of a `seac`, which may not nest.
    in_seac: bool = false,
    stack: [max_stack]f32 = undefined,
    sp: u16 = 0,
    x: f32 = 0,
    y: f32 = 0,
    num_stems: u32 = 0,
    /// CFF2 charstrings carry no width, so it starts out true for them.
    width_parsed: bool = false,
    open: bool = false,
    ops: u32 = 0,
    /// CFF2: the ItemVariationData `blend` uses, from the Private DICT until `vsindex`.
    vsindex: u32 = 0,
    region_count: ?u32 = null,

    fn push(vm: *Vm, v: f32) Error!void {
        if (vm.sp == max_stack) return error.InvalidGlyph;
        vm.stack[vm.sp] = v;
        vm.sp += 1;
    }

    /// Operands of an operator taking exactly `n`: the first stack-clearing operator may
    /// carry the advance width in front, which `hmtx` already provides.
    fn args(vm: *Vm, n: u8) Error![]const f32 {
        if (vm.sp < n) return error.InvalidGlyph;
        defer vm.width_parsed = true;
        return vm.stack[vm.sp - n .. vm.sp];
    }

    /// Operands of a stem operator: pairs, with the width in front when the count is odd.
    fn pairArgs(vm: *Vm) []const f32 {
        const skip: u16 = if (!vm.width_parsed and vm.sp % 2 == 1) 1 else 0;
        vm.width_parsed = true;
        return vm.stack[skip..vm.sp];
    }

    /// A small non-negative integer operand, popped.
    fn popIndex(vm: *Vm) Error!u32 {
        if (vm.sp == 0) return error.InvalidGlyph;
        vm.sp -= 1;
        const v = vm.stack[vm.sp];
        if (!(v >= 0 and v <= 65535)) return error.InvalidGlyph;
        return @intFromFloat(v);
    }

    /// `blend`: keeps the `n` default values and drops their `n * regions` deltas.
    fn blend(vm: *Vm) Error!void {
        if (vm.cff.version != .cff2) return error.InvalidGlyph;
        const n = try vm.popIndex();
        const regions = vm.region_count orelse blk: {
            const k = try vm.cff.regionCount(vm.r, vm.vsindex);
            vm.region_count = k;
            break :blk k;
        };
        const deltas = n * regions;
        if (vm.sp < n + deltas) return error.InvalidGlyph;
        vm.sp -= @intCast(deltas);
    }

    fn moveTo(vm: *Vm, dx: f32, dy: f32) void {
        vm.x += dx;
        vm.y += dy;
        vm.sink.moveTo(vm.x, vm.y);
        vm.open = true;
    }

    fn lineTo(vm: *Vm, dx: f32, dy: f32) void {
        if (!vm.open) vm.moveTo(0, 0);
        vm.x += dx;
        vm.y += dy;
        vm.sink.lineTo(vm.x, vm.y);
    }

    /// Cubic through relative controls; the end point is relative to the second control.
    fn curveTo(vm: *Vm, dx1: f32, dy1: f32, dx2: f32, dy2: f32, dx3: f32, dy3: f32) void {
        if (!vm.open) vm.moveTo(0, 0);
        const c1: [2]f32 = .{ vm.x + dx1, vm.y + dy1 };
        const c2: [2]f32 = .{ c1[0] + dx2, c1[1] + dy2 };
        vm.x = c2[0] + dx3;
        vm.y = c2[1] + dy3;
        vm.sink.curveTo(c1, c2, vm.x, vm.y);
    }

    /// Draws the base glyph at the origin and the accent with its origin at (adx, ady);
    /// both are Standard Encoding codes resolved through the charset.
    fn seac(vm: *Vm, adx: f32, ady: f32, bchar: f32, achar: f32) Error!void {
        if (vm.in_seac or vm.cff.cid != null) return error.InvalidGlyph;
        const base = try vm.cff.glyphForSid(vm.r, try standardSid(bchar));
        const accent = try vm.cff.glyphForSid(vm.r, try standardSid(achar));
        var ops = vm.ops;
        for ([_]struct { u16, f32, f32 }{ .{ base, 0, 0 }, .{ accent, adx, ady } }) |component| {
            var part: Vm = .{
                .r = vm.r,
                .cff = vm.cff,
                .local_subrs = vm.local_subrs,
                .sink = vm.sink,
                .in_seac = true,
                .x = component[1],
                .y = component[2],
                .ops = ops,
            };
            if (!try part.run(try vm.cff.char_strings.item(vm.r, component[0]), 0)) vm.sink.close();
            ops = part.ops;
        }
        vm.ops = ops;
    }

    fn callSubr(vm: *Vm, subrs: Index, depth: u8) Error!bool {
        if (depth >= max_subr_depth or vm.sp == 0) return error.InvalidGlyph;
        vm.sp -= 1;
        const bias: i32 = if (subrs.count < 1240) 107 else if (subrs.count < 33900) 1131 else 32768;
        const operand = vm.stack[vm.sp];
        if (!(@abs(operand) <= 65536)) return error.InvalidGlyph;
        const index = @as(i32, @intFromFloat(operand)) + bias;
        if (index < 0 or index >= subrs.count) return error.InvalidGlyph;
        return vm.run(try subrs.item(vm.r, @intCast(index)), depth + 1);
    }

    /// Pushes the operand starting with `b0`, advancing `pc` past its trailing bytes.
    fn number(vm: *Vm, code: []const u8, pc: *usize, b0: u8) Error!void {
        const rest = code[pc.*..];
        switch (b0) {
            28 => {
                if (rest.len < 2) return error.InvalidGlyph;
                pc.* += 2;
                return vm.push(@floatFromInt(std.mem.readInt(i16, rest[0..2], .big)));
            },
            32...246 => return vm.push(@floatFromInt(@as(i32, b0) - 139)),
            247...250 => {
                if (rest.len < 1) return error.InvalidGlyph;
                pc.* += 1;
                return vm.push(@floatFromInt((@as(i32, b0) - 247) * 256 + rest[0] + 108));
            },
            251...254 => {
                if (rest.len < 1) return error.InvalidGlyph;
                pc.* += 1;
                return vm.push(@floatFromInt(-(@as(i32, b0) - 251) * 256 - @as(i32, rest[0]) - 108));
            },
            255 => {
                if (rest.len < 4) return error.InvalidGlyph;
                pc.* += 4;
                return vm.push(@as(f32, @floatFromInt(std.mem.readInt(i32, rest[0..4], .big))) / 65536.0);
            },
            else => unreachable,
        }
    }

    /// Executes `code`; true once `endchar` has been reached.
    fn run(vm: *Vm, code: []const u8, depth: u8) Error!bool {
        var pc: usize = 0;
        while (pc < code.len) {
            const b0 = code[pc];
            pc += 1;
            if (b0 == 28 or b0 >= 32) {
                try vm.number(code, &pc, b0);
                continue;
            }
            vm.ops += 1;
            if (vm.ops > max_ops) return error.InvalidGlyph;
            switch (b0) {
                // hstem, vstem, hstemhm, vstemhm
                1, 3, 18, 23 => vm.num_stems += @intCast(vm.pairArgs().len / 2),
                // CFF2 only: vsindex selects the variation data, blend keeps the defaults.
                15 => {
                    if (vm.cff.version != .cff2) return error.InvalidGlyph;
                    vm.vsindex = try vm.popIndex();
                    vm.region_count = null;
                },
                16 => {
                    try vm.blend();
                    continue;
                },
                // hintmask, cntrmask: an implicit vstem list may precede the first one.
                19, 20 => {
                    vm.num_stems += @intCast(vm.pairArgs().len / 2);
                    pc += (vm.num_stems + 7) / 8;
                    if (pc > code.len) return error.InvalidGlyph;
                },
                21 => {
                    const a = try vm.args(2);
                    vm.moveTo(a[0], a[1]);
                },
                22 => vm.moveTo((try vm.args(1))[0], 0),
                4 => vm.moveTo(0, (try vm.args(1))[0]),
                5 => {
                    const a = vm.pairArgs();
                    var i: usize = 0;
                    while (i + 2 <= a.len) : (i += 2) vm.lineTo(a[i], a[i + 1]);
                },
                6, 7 => {
                    var horizontal = b0 == 6;
                    for (vm.stack[0..vm.sp]) |d| {
                        if (horizontal) vm.lineTo(d, 0) else vm.lineTo(0, d);
                        horizontal = !horizontal;
                    }
                },
                8 => {
                    const a = vm.stack[0..vm.sp];
                    var i: usize = 0;
                    while (i + 6 <= a.len) : (i += 6) vm.curveTo(a[i], a[i + 1], a[i + 2], a[i + 3], a[i + 4], a[i + 5]);
                },
                // rcurveline: curves, then one line
                24 => {
                    const a = vm.stack[0..vm.sp];
                    if (a.len < 8) return error.InvalidGlyph;
                    var i: usize = 0;
                    while (i + 8 <= a.len) : (i += 6) vm.curveTo(a[i], a[i + 1], a[i + 2], a[i + 3], a[i + 4], a[i + 5]);
                    vm.lineTo(a[i], a[i + 1]);
                },
                // rlinecurve: lines, then one curve
                25 => {
                    const a = vm.stack[0..vm.sp];
                    if (a.len < 8) return error.InvalidGlyph;
                    var i: usize = 0;
                    while (i + 8 <= a.len) : (i += 2) vm.lineTo(a[i], a[i + 1]);
                    vm.curveTo(a[i], a[i + 1], a[i + 2], a[i + 3], a[i + 4], a[i + 5]);
                },
                // vvcurveto / hhcurveto: an odd leading operand offsets the first control.
                26, 27 => {
                    const a = vm.stack[0..vm.sp];
                    var i: usize = a.len % 4;
                    var d1: f32 = if (i == 1) a[0] else 0;
                    while (i + 4 <= a.len) : (i += 4) {
                        if (b0 == 26) vm.curveTo(d1, a[i], a[i + 1], a[i + 2], 0, a[i + 3]) else vm.curveTo(a[i], d1, a[i + 1], a[i + 2], a[i + 3], 0);
                        d1 = 0;
                    }
                },
                // vhcurveto / hvcurveto: alternating, the last curve may end off-axis.
                30, 31 => {
                    const a = vm.stack[0..vm.sp];
                    var horizontal = b0 == 31;
                    var i: usize = 0;
                    while (i + 4 <= a.len) : (i += 4) {
                        const last: f32 = if (a.len - i == 5) a[i + 4] else 0;
                        if (horizontal) vm.curveTo(a[i], 0, a[i + 1], a[i + 2], last, a[i + 3]) else vm.curveTo(0, a[i], a[i + 1], a[i + 2], a[i + 3], last);
                        horizontal = !horizontal;
                    }
                },
                10 => {
                    if (try vm.callSubr(vm.local_subrs, depth)) return true;
                    continue;
                },
                29 => {
                    if (try vm.callSubr(vm.cff.global_subrs, depth)) return true;
                    continue;
                },
                11 => return false,
                14 => {
                    // Four operands (plus the width) make it an accent composition.
                    const a = try vm.args(if (vm.sp >= 4) 4 else 0);
                    if (a.len == 4) try vm.seac(a[0], a[1], a[2], a[3]);
                    vm.sink.close();
                    return true;
                },
                12 => {
                    if (pc >= code.len) return error.InvalidGlyph;
                    const b1 = code[pc];
                    pc += 1;
                    try vm.escape(b1);
                },
                else => return error.InvalidGlyph,
            }
            vm.sp = 0;
        }
        return false;
    }

    /// Two-byte operators: the flex family; `dotsection` is a no-op and the arithmetic
    /// operators are deprecated and unsupported.
    fn escape(vm: *Vm, op: u8) Error!void {
        const y0 = vm.y;
        switch (op) {
            0 => {},
            35 => {
                const a = try vm.args(13);
                vm.curveTo(a[0], a[1], a[2], a[3], a[4], a[5]);
                vm.curveTo(a[6], a[7], a[8], a[9], a[10], a[11]);
            },
            34 => {
                const a = try vm.args(7);
                vm.curveTo(a[0], 0, a[1], a[2], a[3], 0);
                vm.curveTo(a[4], 0, a[5], y0 - vm.y, a[6], 0);
            },
            36 => {
                const a = try vm.args(9);
                vm.curveTo(a[0], a[1], a[2], a[3], a[4], 0);
                vm.curveTo(a[5], 0, a[6], a[7], a[8], y0 - vm.y - a[7]);
            },
            37 => {
                const a = try vm.args(11);
                const x0 = vm.x;
                const dx = a[0] + a[2] + a[4] + a[6] + a[8];
                const dy = a[1] + a[3] + a[5] + a[7] + a[9];
                vm.curveTo(a[0], a[1], a[2], a[3], a[4], a[5]);
                // The last point returns to the start on the minor axis.
                const c1: [2]f32 = .{ vm.x + a[6], vm.y + a[7] };
                const c2: [2]f32 = .{ c1[0] + a[8], c1[1] + a[9] };
                if (@abs(dx) > @abs(dy)) vm.curveTo(a[6], a[7], a[8], a[9], a[10], y0 - c2[1]) else vm.curveTo(a[6], a[7], a[8], a[9], x0 - c2[0], a[10]);
            },
            else => return error.InvalidGlyph,
        }
    }
};

fn interpret(font: VectorFont, gid: u16, sink: *Sink) Error!void {
    const cff = font.tables.outlines.cff;
    if (gid >= cff.char_strings.count) return error.InvalidGlyph;
    const r = Reader.init(font.data).table(cff.table);
    const private = try cff.glyphPrivate(r, gid);
    var vm: Vm = .{
        .r = r,
        .cff = cff,
        .local_subrs = private.subrs,
        .sink = sink,
        .width_parsed = cff.version == .cff2,
        .vsindex = private.vsindex,
    };
    if (!try vm.run(try cff.char_strings.item(r, gid), 0)) sink.close();
}

/// Control box of the charstring's points; null for glyphs without contours.
pub fn bounds(font: VectorFont, gid: u16) ?VectorFont.Bounds {
    var sink: Sink = .{};
    interpret(font, gid, &sink) catch return null;
    if (sink.n == 0) return null;
    return .{
        .x_min = saturate(@floor(sink.min[0])),
        .y_min = saturate(@floor(sink.min[1])),
        .x_max = saturate(@ceil(sink.max[0])),
        .y_max = saturate(@ceil(sink.max[1])),
    };
}

fn saturate(v: f32) i16 {
    return @intFromFloat(@min(@max(v, -32768.0), 32767.0));
}

/// Decodes `gid` into an owned `Outline`: one run to count, one to fill, so exactly
/// two allocations.
pub fn outline(font: VectorFont, gpa: Allocator, gid: u16) (Error || Allocator.Error)!Outline {
    var sink: Sink = .{};
    try interpret(font, gid, &sink);
    if (sink.n > max_outline_points or sink.c > max_outline_points) return error.TooManyPoints;

    const points = try gpa.alloc(Outline.Point, sink.n);
    errdefer gpa.free(points);
    const contour_ends = try gpa.alloc(u32, sink.c);
    errdefer gpa.free(contour_ends);

    sink = .{ .points = points, .contour_ends = contour_ends };
    try interpret(font, gid, &sink);
    return .{ .points = points, .contour_ends = contour_ends };
}

const synthetic = @import("synthetic.zig");
const testing = std.testing;

fn expectPoint(p: Outline.Point, x: f32, y: f32, kind: Outline.Point.Kind) !void {
    try testing.expectEqual(x, p.x);
    try testing.expectEqual(y, p.y);
    try testing.expectEqual(kind, p.kind);
}

test "lines, subrs, width and hints" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const font = synthetic.font(&buf, .{ .cff = true });
    try testing.expect(font.tables.outlines == .cff);

    // Gids 1 and 2 match the glyf flavor point for point.
    var glyf_buf: [synthetic.buffer_size]u8 = undefined;
    const glyf_font = synthetic.font(&glyf_buf, .{});
    for ([_]u16{ 1, 2 }) |gid| {
        var a = try font.outline(testing.allocator, gid);
        defer a.deinit(testing.allocator);
        var b = try glyf_font.outline(testing.allocator, gid);
        defer b.deinit(testing.allocator);
        try testing.expectEqualSlices(u32, b.contour_ends, a.contour_ends);
        for (a.points, b.points) |p, q| try expectPoint(p, q.x, q.y, .on_curve);
    }

    // Gid 4 draws gid 1 through a local subr.
    var subr = try font.outline(testing.allocator, 4);
    defer subr.deinit(testing.allocator);
    var direct = try font.outline(testing.allocator, 1);
    defer direct.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, direct.contour_ends, subr.contour_ends);
    for (subr.points, direct.points) |p, q| try expectPoint(p, q.x, q.y, q.kind);

    // Gids 5 and 6: the same triangle, one behind hints, the other closed explicitly.
    for ([_]u16{ 5, 6 }) |gid| {
        var t = try font.outline(testing.allocator, gid);
        defer t.deinit(testing.allocator);
        try testing.expectEqual(1, t.contourCount());
        try testing.expectEqual(3, t.contour(0).len);
        try expectPoint(t.contour(0)[0], 100, 0, .on_curve);
        try expectPoint(t.contour(0)[1], 700, 0, .on_curve);
        try expectPoint(t.contour(0)[2], 400, 600, .on_curve);
        try testing.expectEqual(VectorFont.Bounds{ .x_min = 100, .y_min = 0, .x_max = 700, .y_max = 600 }, font.glyphBounds(gid).?);
    }

    try testing.expectEqual(VectorFont.Bounds{ .x_min = 100, .y_min = 0, .x_max = 700, .y_max = 700 }, font.glyphBounds(1).?);
    try testing.expectEqual(null, font.glyphBounds(0));
    var empty = try font.outline(testing.allocator, 0);
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(0, empty.contourCount());
    try testing.expectError(error.InvalidGlyph, font.outline(testing.allocator, 7));
}

test "cubic contour closing on its start" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const font = synthetic.font(&buf, .{ .cff = true });
    var o = try font.outline(testing.allocator, 3);
    defer o.deinit(testing.allocator);
    try testing.expectEqual(1, o.contourCount());
    const pts = o.contour(0);
    try testing.expectEqual(12, pts.len);
    for (pts, 0..) |p, i| try testing.expectEqual(if (i % 3 == 0) Outline.Point.Kind.on_curve else .cubic_control, p.kind);
    try expectPoint(pts[0], 400, 0, .on_curve);
    try expectPoint(pts[1], 600, 0, .cubic_control);
    try expectPoint(pts[2], 800, 175, .cubic_control);
    try expectPoint(pts[3], 800, 350, .on_curve);
    try expectPoint(pts[6], 400, 700, .on_curve);
    try expectPoint(pts[9], 0, 350, .on_curve);
    try expectPoint(pts[11], 200, 0, .cubic_control);
    try testing.expectEqual(VectorFont.Bounds{ .x_min = 0, .y_min = 0, .x_max = 800, .y_max = 700 }, font.glyphBounds(3).?);
}

test "seac composes a base and an accent" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const font = synthetic.font(&buf, .{ .cff = true, .cff_gid6 = .seac });
    var o = try font.outline(testing.allocator, 6);
    defer o.deinit(testing.allocator);
    var base = try font.outline(testing.allocator, 1);
    defer base.deinit(testing.allocator);
    var accent = try font.outline(testing.allocator, 3);
    defer accent.deinit(testing.allocator);
    try testing.expectEqual(base.contourCount() + accent.contourCount(), o.contourCount());
    try testing.expectEqual(base.points.len + accent.points.len, o.points.len);
    for (o.points[0..base.points.len], base.points) |p, q| try expectPoint(p, q.x, q.y, q.kind);
    for (o.points[base.points.len..], accent.points) |p, q| try expectPoint(p, q.x + 100, q.y + 200, q.kind);
    try testing.expectEqual(VectorFont.Bounds{ .x_min = 100, .y_min = 0, .x_max = 900, .y_max = 900 }, font.glyphBounds(6).?);

    const nested = synthetic.font(&buf, .{ .cff = true, .cff_gid6 = .seac_nested });
    try testing.expectError(error.InvalidGlyph, nested.outline(testing.allocator, 6));
    const unencoded = synthetic.font(&buf, .{ .cff = true, .cff_gid6 = .seac_unencoded });
    try testing.expectError(error.InvalidGlyph, unencoded.outline(testing.allocator, 6));
    try testing.expectEqual(null, unencoded.glyphBounds(6));
}

test "CFF2 default instance matches the CFF outlines" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    var cff_buf: [synthetic.buffer_size]u8 = undefined;
    const reference = synthetic.font(&cff_buf, .{ .cff = true });
    for ([_]bool{ false, true }) |fd_select| {
        const font = synthetic.font(&buf, .{ .cff2 = true, .cff2_fd_select = fd_select });
        try testing.expectEqual(.cff2, font.tables.outlines.cff.version);
        try testing.expect(font.tables.outlines.cff.cid != null);
        for (0..7) |gid| {
            var a = try font.outline(testing.allocator, @intCast(gid));
            defer a.deinit(testing.allocator);
            var b = try reference.outline(testing.allocator, @intCast(gid));
            defer b.deinit(testing.allocator);
            try testing.expectEqualSlices(u32, b.contour_ends, a.contour_ends);
            for (a.points, b.points) |p, q| try expectPoint(p, q.x, q.y, q.kind);
            try testing.expectEqual(reference.glyphBounds(@intCast(gid)), font.glyphBounds(@intCast(gid)));
        }
    }

    // `blend` without a variation store, and a wrong region count (too few operands).
    const no_store = synthetic.font(&buf, .{ .cff2 = true, .cff2_vstore = false });
    try testing.expectError(error.InvalidGlyph, no_store.outline(testing.allocator, 1));
    try testing.expectError(error.InvalidGlyph, no_store.outline(testing.allocator, 4));
    var plain = try no_store.outline(testing.allocator, 6);
    plain.deinit(testing.allocator);
    const two_regions = synthetic.font(&buf, .{ .cff2 = true, .cff2_regions = 2 });
    try testing.expectError(error.InvalidGlyph, two_regions.outline(testing.allocator, 1));

    // CFF charstrings may not use the CFF2 operators.
    const blend_in_cff = synthetic.font(&buf, .{ .cff = true, .cff_gid6 = .blend });
    try testing.expectError(error.InvalidGlyph, blend_in_cff.outline(testing.allocator, 6));

    const full = synthetic.build(&buf, .{ .cff2 = true, .cff2_fd_select = true });
    var len: usize = 0;
    while (len < full.len) : (len += 7) {
        if (VectorFont.loadFromBytes(full[0..len])) |font| {
            for (0..7) |gid| {
                _ = font.glyphBounds(@intCast(gid));
                if (font.outline(testing.allocator, @intCast(gid))) |o| {
                    var owned = o;
                    owned.deinit(testing.allocator);
                } else |_| {}
            }
        } else |_| {}
    }
}

test "rejects bad charstrings and truncation without panicking" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    try testing.expectError(error.UnsupportedFontFormat, VectorFont.loadFromBytes(synthetic.build(&buf, .{ .cff = true, .cff_charstring_type = 1 })));

    const looping = synthetic.font(&buf, .{ .cff = true, .cff_recursive_subr = true });
    try testing.expectError(error.InvalidGlyph, looping.outline(testing.allocator, 4));
    try testing.expectEqual(null, looping.glyphBounds(4));

    const full = synthetic.build(&buf, .{ .cff = true, .cff_gid6 = .seac });
    var len: usize = 0;
    while (len < full.len) : (len += 7) {
        if (VectorFont.loadFromBytes(full[0..len])) |font| {
            for (0..7) |gid| {
                _ = font.glyphBounds(@intCast(gid));
                if (font.outline(testing.allocator, @intCast(gid))) |o| {
                    var owned = o;
                    owned.deinit(testing.allocator);
                } else |_| {}
            }
        } else |_| {}
    }
}
