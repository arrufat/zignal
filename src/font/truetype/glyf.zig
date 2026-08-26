//! `loca`/`glyf` parsing: simple glyphs (quadratic on/off-curve points) and
//! composite glyphs (component references with affine transforms) into an
//! `Outline` in font units.

const std = @import("std");
const Allocator = std.mem.Allocator;

const truetype = @import("../truetype.zig");
const Error = truetype.Error;
const Reader = truetype.Reader;
const VectorFont = @import("../VectorFont.zig");
const Outline = @import("../Outline.zig");

pub const max_composite_depth = 8;
/// Component visits allowed per top-level glyph; bounds the fan-out of nested composites.
pub const max_composite_components = 1024;

pub const flag_on_curve: u8 = 0x01;
const flag_x_short: u8 = 0x02;
const flag_y_short: u8 = 0x04;
const flag_repeat: u8 = 0x08;
const flag_x_same_or_positive: u8 = 0x10;
const flag_y_same_or_positive: u8 = 0x20;

pub const comp_arg_words: u16 = 0x0001;
pub const comp_args_are_xy: u16 = 0x0002;
pub const comp_have_scale: u16 = 0x0008;
pub const comp_more: u16 = 0x0020;
pub const comp_xy_scale: u16 = 0x0040;
pub const comp_two_by_two: u16 = 0x0080;

const Range = struct { offset: u32, len: u32 };

/// Byte range of the glyph record in `glyf`; null for an empty glyph.
fn glyphRange(font: VectorFont, gid: u16) Error!?Range {
    if (gid >= font.num_glyphs) return error.InvalidGlyph;
    const tables = font.tables.outlines.glyf;
    const r: Reader = .init(font.data);
    const loca = r.table(tables.loca);
    const start: u32, const end: u32 = switch (tables.index_to_loc_format) {
        .short => .{ 2 * @as(u32, try loca.u16At(2 * @as(usize, gid))), 2 * @as(u32, try loca.u16At(2 * @as(usize, gid) + 2)) },
        .long => .{ try loca.u32At(4 * @as(usize, gid)), try loca.u32At(4 * @as(usize, gid) + 4) },
    };
    if (end < start or end > tables.glyf.len) return error.InvalidGlyph;
    if (end == start) return null;
    return .{ .offset = start, .len = end - start };
}

pub fn bounds(font: VectorFont, gid: u16) ?VectorFont.Bounds {
    const range = (glyphRange(font, gid) catch return null) orelse return null;
    const r = glyphReader(font, range) catch return null;
    return .{
        .x_min = r.i16At(2) catch return null,
        .y_min = r.i16At(4) catch return null,
        .x_max = r.i16At(6) catch return null,
        .y_max = r.i16At(8) catch return null,
    };
}

fn glyphReader(font: VectorFont, range: Range) Error!Reader {
    const r: Reader = .init(font.data);
    const glyf = r.table(font.tables.outlines.glyf.glyf);
    return .init(try glyf.slice(range.offset, range.len));
}

/// Resolves `gid` (composites included) into an owned `Outline`.
pub fn outline(font: VectorFont, gpa: Allocator, gid: u16) (Error || Allocator.Error)!Outline {
    const Glyph = struct {
        font: VectorFont,
        gid: u16,

        fn walkGlyph(self: @This(), sink: *Sink) Error!void {
            var budget: u32 = max_composite_components;
            try walk(self.font, self.gid, .identity, 0, &budget, sink);
        }
    };
    return Outline.Builder.build(gpa, Glyph{ .font = font, .gid = gid }, Glyph.walkGlyph);
}

/// Simple glyphs are sized from their header, so a counting pass never decodes them.
const Sink = Outline.Builder;

/// Component transform: x' = a·x + c·y + dx, y' = b·x + d·y + dy.
const Affine = struct {
    a: f32,
    b: f32,
    c: f32,
    d: f32,
    dx: f32,
    dy: f32,

    const identity: Affine = .{ .a = 1, .b = 0, .c = 0, .d = 1, .dx = 0, .dy = 0 };

    fn apply(t: Affine, x: f32, y: f32) [2]f32 {
        return .{ t.a * x + t.c * y + t.dx, t.b * x + t.d * y + t.dy };
    }

    /// The transform applying `local` first, then `parent`.
    fn compose(parent: Affine, local: Affine) Affine {
        return .{
            .a = parent.a * local.a + parent.c * local.b,
            .b = parent.b * local.a + parent.d * local.b,
            .c = parent.a * local.c + parent.c * local.d,
            .d = parent.b * local.c + parent.d * local.d,
            .dx = parent.a * local.dx + parent.c * local.dy + parent.dx,
            .dy = parent.b * local.dx + parent.d * local.dy + parent.dy,
        };
    }
};

fn walk(font: VectorFont, gid: u16, transform: Affine, depth: u8, budget: *u32, sink: *Sink) Error!void {
    const range = try glyphRange(font, gid) orelse return;
    if (range.len < 10) return error.InvalidGlyph;
    const r = try glyphReader(font, range);
    const num_contours = try r.i16At(0);
    if (num_contours >= 0) return simple(r, @intCast(num_contours), transform, sink);
    if (num_contours != -1) return error.InvalidGlyph;
    return composite(font, r, transform, depth, budget, sink);
}

/// Cursor over the flags array, expanding REPEAT runs.
const FlagIter = struct {
    r: Reader,
    off: usize,
    pending: u8 = 0,
    last: u8 = 0,

    fn next(self: *FlagIter) Error!u8 {
        if (self.pending > 0) {
            self.pending -= 1;
            return self.last;
        }
        const flag = try self.r.u8At(self.off);
        self.off += 1;
        if (flag & flag_repeat != 0) {
            self.pending = try self.r.u8At(self.off);
            self.off += 1;
        }
        self.last = flag;
        return flag;
    }
};

fn coordSize(flag: u8, short: u8, same: u8) usize {
    return if (flag & short != 0) 1 else if (flag & same != 0) 0 else 2;
}

/// Reads one coordinate delta and advances the cursor.
fn coordDelta(r: Reader, off: *usize, flag: u8, short: u8, same: u8) Error!i32 {
    if (flag & short != 0) {
        const v: i32 = try r.u8At(off.*);
        off.* += 1;
        return if (flag & same != 0) v else -v;
    }
    if (flag & same != 0) return 0;
    const v: i32 = try r.i16At(off.*);
    off.* += 2;
    return v;
}

fn simple(r: Reader, num_contours: u16, transform: Affine, sink: *Sink) Error!void {
    var num_points: u32 = 0;
    for (0..num_contours) |i| {
        const end = try r.u16At(10 + 2 * i);
        if (@as(u32, end) + 1 <= num_points) return error.InvalidGlyph;
        num_points = @as(u32, end) + 1;
    }
    if (sink.points == null) {
        sink.n += num_points;
        sink.c += num_contours;
        return;
    }
    const instructions_off = 10 + 2 * @as(usize, num_contours);
    const flags_off = instructions_off + 2 + try r.u16At(instructions_off);

    // The x and y arrays follow the flags, so their sizes are known only after
    // one pass over the flags.
    var x_len: usize = 0;
    var y_len: usize = 0;
    var flags: FlagIter = .{ .r = r, .off = flags_off };
    for (0..num_points) |_| {
        const flag = try flags.next();
        x_len += coordSize(flag, flag_x_short, flag_x_same_or_positive);
        y_len += coordSize(flag, flag_y_short, flag_y_same_or_positive);
    }
    var x_off = flags.off;
    var y_off = x_off + x_len;
    _ = try r.slice(y_off, y_len);

    flags = .{ .r = r, .off = flags_off };
    var x: i32 = 0;
    var y: i32 = 0;
    var contour: usize = 0;
    var contour_end: u32 = try r.u16At(10);
    for (0..num_points) |i| {
        const flag = try flags.next();
        x += try coordDelta(r, &x_off, flag, flag_x_short, flag_x_same_or_positive);
        y += try coordDelta(r, &y_off, flag, flag_y_short, flag_y_same_or_positive);
        const p = transform.apply(@floatFromInt(x), @floatFromInt(y));
        sink.emit(p[0], p[1], if (flag & flag_on_curve != 0) .on_curve else .quad_control);
        if (i == contour_end) {
            sink.endContour();
            contour += 1;
            if (contour < num_contours) contour_end = try r.u16At(10 + 2 * contour);
        }
    }
}

fn composite(font: VectorFont, r: Reader, transform: Affine, depth: u8, budget: *u32, sink: *Sink) Error!void {
    if (depth >= max_composite_depth) return error.CompositeTooDeep;
    var off: usize = 10;
    while (true) {
        if (budget.* == 0) return error.CompositeTooDeep;
        budget.* -= 1;

        const flags = try r.u16At(off);
        const child = try r.u16At(off + 2);
        off += 4;

        // Point-matching placement (ARGS_ARE_XY_VALUES clear) is treated as a zero offset.
        var local: Affine = .identity;
        if (flags & comp_arg_words != 0) {
            if (flags & comp_args_are_xy != 0) {
                local.dx = @floatFromInt(try r.i16At(off));
                local.dy = @floatFromInt(try r.i16At(off + 2));
            }
            off += 4;
        } else {
            if (flags & comp_args_are_xy != 0) {
                local.dx = @floatFromInt(@as(i8, @bitCast(try r.u8At(off))));
                local.dy = @floatFromInt(@as(i8, @bitCast(try r.u8At(off + 1))));
            }
            off += 2;
        }
        if (flags & comp_have_scale != 0) {
            local.a = try r.f2dot14At(off);
            local.d = local.a;
            off += 2;
        } else if (flags & comp_xy_scale != 0) {
            local.a = try r.f2dot14At(off);
            local.d = try r.f2dot14At(off + 2);
            off += 4;
        } else if (flags & comp_two_by_two != 0) {
            local.a = try r.f2dot14At(off);
            local.b = try r.f2dot14At(off + 2);
            local.c = try r.f2dot14At(off + 4);
            local.d = try r.f2dot14At(off + 6);
            off += 8;
        }

        try walk(font, child, transform.compose(local), depth + 1, budget, sink);
        if (flags & comp_more == 0) break;
    }
}

const synthetic = @import("synthetic.zig");
const testing = std.testing;

fn expectPoint(p: Outline.Point, x: f32, y: f32, on_curve: bool) !void {
    try testing.expectEqual(x, p.x);
    try testing.expectEqual(y, p.y);
    try testing.expectEqual(on_curve, p.kind == .on_curve);
}

test "simple glyph with a hole" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    for ([_]bool{ false, true }) |long_loca| {
        const font = synthetic.font(&buf, .{ .long_loca = long_loca });
        var o = try font.outline(testing.allocator, 1);
        defer o.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 2), o.contourCount());
        try testing.expectEqual(@as(usize, 4), o.contour(0).len);
        try testing.expectEqual(@as(usize, 4), o.contour(1).len);
        try expectPoint(o.contour(0)[0], 100, 0, true);
        try expectPoint(o.contour(0)[2], 700, 700, true);
        try expectPoint(o.contour(1)[0], 300, 200, true);
        try testing.expectEqual(VectorFont.Bounds{ .x_min = 100, .y_min = 0, .x_max = 700, .y_max = 700 }, font.glyphBounds(1).?);
        try testing.expectEqual(null, font.glyphBounds(0));
    }
}

test "empty glyph" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const font = synthetic.font(&buf, .{});
    var o = try font.outline(testing.allocator, 0);
    defer o.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), o.contourCount());
    try testing.expectEqual(@as(usize, 0), o.points.len);
    try testing.expectError(error.InvalidGlyph, font.outline(testing.allocator, 7));
}

test "all off-curve contour" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const font = synthetic.font(&buf, .{});
    var o = try font.outline(testing.allocator, 3);
    defer o.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), o.contourCount());
    for (o.contour(0)) |p| try testing.expectEqual(.quad_control, p.kind);
}

test "composite glyphs" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const font = synthetic.font(&buf, .{});
    var d = try font.outline(testing.allocator, 4);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), d.contourCount());
    try expectPoint(d.contour(0)[0], 100, 0, true);
    // gid 3 scaled by 0.5 and moved to (400, 0): (800, 350) -> (800, 175).
    try expectPoint(d.contour(2)[1], 800, 175, false);

    var e = try font.outline(testing.allocator, 5);
    defer e.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), e.contourCount());
    try testing.expectEqualSlices(u32, d.contour_ends, e.contour_ends);
    for (d.points, e.points) |a, b| try expectPoint(b, a.x, a.y, a.kind == .on_curve);
}

test "composite limits" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const looping = synthetic.font(&buf, .{ .self_referencing = true });
    try testing.expectError(error.CompositeTooDeep, looping.outline(testing.allocator, 5));

    const fanout = synthetic.font(&buf, .{ .fanout = true });
    try testing.expectError(error.CompositeTooDeep, fanout.outline(testing.allocator, 5));
}

test "truncated glyph data" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    var font = synthetic.font(&buf, .{});
    font.tables.outlines.glyf.glyf.len = 40;
    try testing.expectError(error.InvalidGlyph, font.outline(testing.allocator, 2));
    try testing.expectEqual(null, font.glyphBounds(2));
}
