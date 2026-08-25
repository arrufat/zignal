//! `CFF ` table parsing for OpenType fonts with PostScript outlines: the INDEX and
//! DICT containers, then a Type 2 charstring interpreter that turns a glyph into
//! cubic contours in font units. Everything is read in place; nothing is decoded
//! at load time beyond locating the CharStrings, Subrs and (for CID-keyed fonts)
//! the FDArray/FDSelect.

const std = @import("std");
const Allocator = std.mem.Allocator;

const truetype = @import("../truetype.zig");
const Error = truetype.Error;
const Reader = truetype.Reader;
const Table = truetype.Table;
const VectorFont = @import("../VectorFont.zig");
const Outline = @import("../Outline.zig");

pub const max_subr_depth = 10;
pub const max_stack = 48;
/// Operators executed per glyph, subrs included; bounds hostile subr fan-out.
pub const max_ops = 1 << 16;
pub const max_outline_points = 0xFFFF;
const max_dict_operands = 48;

/// An INDEX: `count` items addressed through 1-based offsets of `off_size` bytes each.
pub const Index = struct {
    count: u16,
    off_size: u8,
    /// Position of the offset array.
    offsets: u32,
    /// Position of the object data minus one, since offsets are 1-based.
    data: u32,

    pub const empty: Index = .{ .count = 0, .off_size = 1, .offsets = 0, .data = 0 };

    const Parsed = struct { index: Index, end: u32 };

    /// Parses the INDEX at `pos`; `end` is the position just past it.
    fn parse(r: Reader, pos: u32) Error!Parsed {
        const count = try r.u16At(pos);
        if (count == 0) return .{ .index = .empty, .end = pos + 2 };
        const off_size = try r.u8At(pos + 2);
        if (off_size == 0 or off_size > 4) return error.InvalidFormat;
        const offsets: u64 = pos + 3;
        const data = offsets + (@as(u64, count) + 1) * off_size - 1;
        if (data > r.data.len) return error.UnexpectedEof;
        const index: Index = .{ .count = count, .off_size = off_size, .offsets = @intCast(offsets), .data = @intCast(data) };
        const end = data + try index.offset(r, count);
        if (end > r.data.len) return error.UnexpectedEof;
        return .{ .index = index, .end = @intCast(end) };
    }

    fn offset(self: Index, r: Reader, i: u32) Error!u32 {
        var v: u32 = 0;
        for (try r.slice(self.offsets + i * self.off_size, self.off_size)) |b| v = (v << 8) | b;
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

/// DICT operators; two-byte ones are `0x0c00 | second byte`.
const Op = struct {
    const char_strings = 17;
    const private = 18;
    const subrs = 19;
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
            0...21 => {
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

/// The Subrs INDEX of the Private DICT described by `size, offset`; empty when it has none.
fn privateSubrs(r: Reader, private: [2]i32) Error!Index {
    const size = try toOffset(private[0]);
    const offset = try toOffset(private[1]);
    const dict = try r.slice(offset, size);
    const subrs = try dictGet(dict, Op.subrs, 1) orelse return .empty;
    const at = std.math.add(u32, offset, try toOffset(subrs[0])) catch return error.UnexpectedEof;
    return (try Index.parse(r, at)).index;
}

pub const Font = struct {
    /// The `CFF ` table; every position in this struct is relative to it.
    table: Table,
    char_strings: Index,
    global_subrs: Index,
    /// Subrs of the single Private DICT; unused by CID-keyed fonts.
    local_subrs: Index,
    /// CID-keyed fonts select a Font DICT per glyph, each with its own Private DICT and Subrs.
    cid: ?Cid,

    pub const Cid = struct {
        fd_array: Index,
        /// Position of the FDSelect table, validated for its format at load time.
        fd_select: u32,
    };

    /// Font DICT index for `gid` from FDSelect formats 0 and 3.
    fn fdIndex(self: Font, r: Reader, gid: u16) Error!u8 {
        const cid = self.cid orelse return error.InvalidFormat;
        const pos = cid.fd_select;
        switch (try r.u8At(pos)) {
            0 => return r.u8At(pos + 1 + gid),
            3 => {
                // Ranges of (first gid, fd), sorted by first gid, then a sentinel gid.
                const num_ranges = try r.u16At(pos + 1);
                var lo: u32 = 0;
                var hi: u32 = num_ranges;
                while (hi - lo > 1) {
                    const mid = (lo + hi) / 2;
                    if (try r.u16At(pos + 3 + mid * 3) <= gid) lo = mid else hi = mid;
                }
                if (num_ranges == 0 or try r.u16At(pos + 3 + lo * 3) > gid or gid >= try r.u16At(pos + 3 + hi * 3)) return error.InvalidGlyph;
                return r.u8At(pos + 5 + lo * 3);
            },
            else => return error.InvalidFormat,
        }
    }

    fn localSubrs(self: Font, r: Reader, gid: u16) Error!Index {
        const cid = self.cid orelse return self.local_subrs;
        const fd = try cid.fd_array.item(r, try self.fdIndex(r, gid));
        const private = try dictGet(fd, Op.private, 2) orelse return .empty;
        return privateSubrs(r, private);
    }
};

/// Locates the CharStrings, Subrs and CID structures of the `CFF ` table `t` of the
/// font `font_reader` covers. Only Type 2 charstrings are accepted.
pub fn parse(t: Table, font_reader: Reader, num_glyphs: u16) Error!Font {
    const r = font_reader.table(t);
    const header_size = try r.u8At(2);
    const names = try Index.parse(r, header_size);
    const top_dicts = try Index.parse(r, names.end);
    const strings = try Index.parse(r, top_dicts.end);
    const global_subrs = try Index.parse(r, strings.end);
    const top = try top_dicts.index.item(r, 0);

    if (try dictGet(top, Op.charstring_type, 1)) |v| if (v[0] != 2) return error.UnsupportedFontFormat;
    const char_strings_at = try dictGet(top, Op.char_strings, 1) orelse return error.MissingTable;
    const char_strings = (try Index.parse(r, try toOffset(char_strings_at[0]))).index;
    if (char_strings.count != num_glyphs) return error.InvalidFormat;

    var font: Font = .{
        .table = t,
        .char_strings = char_strings,
        .global_subrs = global_subrs.index,
        .local_subrs = .empty,
        .cid = null,
    };
    if (try dictGet(top, Op.ros, 3) != null) {
        const fd_array_at = try dictGet(top, Op.fd_array, 1) orelse return error.MissingTable;
        const fd_select_at = try dictGet(top, Op.fd_select, 1) orelse return error.MissingTable;
        const fd_select = try toOffset(fd_select_at[0]);
        switch (try r.u8At(fd_select)) {
            0 => _ = try r.slice(fd_select + 1, num_glyphs),
            3 => _ = try r.slice(fd_select + 3, 3 * @as(usize, try r.u16At(fd_select + 1)) + 2),
            else => return error.InvalidFormat,
        }
        font.cid = .{
            .fd_array = (try Index.parse(r, try toOffset(fd_array_at[0]))).index,
            .fd_select = fd_select,
        };
    } else {
        const private = try dictGet(top, Op.private, 2) orelse return error.MissingTable;
        font.local_subrs = try privateSubrs(r, private);
    }
    return font;
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
    global_subrs: Index,
    local_subrs: Index,
    sink: *Sink,
    stack: [max_stack]f32 = undefined,
    sp: u8 = 0,
    x: f32 = 0,
    y: f32 = 0,
    num_stems: u32 = 0,
    width_parsed: bool = false,
    open: bool = false,
    ops: u32 = 0,

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
        const skip: u8 = if (!vm.width_parsed and vm.sp % 2 == 1) 1 else 0;
        vm.width_parsed = true;
        return vm.stack[skip..vm.sp];
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
                    if (try vm.callSubr(vm.global_subrs, depth)) return true;
                    continue;
                },
                11 => return false,
                14 => {
                    // Four operands (plus the width) would be a seac accent composition.
                    const n: u8 = if (vm.sp >= 4) 4 else 0;
                    if ((try vm.args(n)).len != 0) return error.InvalidGlyph;
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
    var vm: Vm = .{
        .r = r,
        .global_subrs = cff.global_subrs,
        .local_subrs = try cff.localSubrs(r, gid),
        .sink = sink,
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

test "rejects bad charstrings and truncation without panicking" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    try testing.expectError(error.UnsupportedFontFormat, VectorFont.loadFromBytes(synthetic.build(&buf, .{ .cff = true, .cff_charstring_type = 1 })));

    const looping = synthetic.font(&buf, .{ .cff = true, .cff_recursive_subr = true });
    try testing.expectError(error.InvalidGlyph, looping.outline(testing.allocator, 4));
    try testing.expectEqual(null, looping.glyphBounds(4));

    const full = synthetic.build(&buf, .{ .cff = true });
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
