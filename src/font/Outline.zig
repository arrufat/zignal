//! A glyph outline: closed contours of quadratic (TrueType) or cubic (CFF)
//! segments in font units, y up, with composites already resolved. `flatten`
//! turns it into device-space polygons for `Canvas.fillPolygons`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Point2 = @import("../geometry/Point.zig").Point(2, f32);

const Outline = @This();

pub const Point = struct {
    x: f32,
    y: f32,
    kind: Kind,

    pub const Kind = enum(u2) {
        on_curve,
        /// One per quadratic segment; two in a row imply an on-curve midpoint.
        quad_control,
        /// Always in pairs.
        cubic_control,
    };
};

/// All contours back to back.
points: []Point,
/// Exclusive end index of each contour in `points`.
contour_ends: []u32,

pub const empty: Outline = .{ .points = &.{}, .contour_ends = &.{} };

/// Chord deviation allowed when flattening curves, in device pixels.
pub const flatness_tolerance: f32 = 0.1;
pub const max_curve_segments: u32 = 32;

pub fn deinit(self: *Outline, gpa: Allocator) void {
    gpa.free(self.points);
    gpa.free(self.contour_ends);
    self.* = .empty;
}

pub fn contourCount(self: Outline) usize {
    return self.contour_ends.len;
}

pub fn contour(self: Outline, i: usize) []const Point {
    const start = if (i == 0) 0 else self.contour_ends[i - 1];
    return self.points[start..self.contour_ends[i]];
}

/// Font units to device pixels, y down. `origin` is the pen position on the baseline and
/// may be fractional; `shear` synthesizes italics about the baseline (x' = x + shear·y).
pub const Transform = struct {
    /// Device pixels per font unit.
    scale: f32,
    origin: Point2,
    shear: f32 = 0,

    pub inline fn apply(t: Transform, x: f32, y: f32) Point2 {
        return .init(.{ t.origin.x() + t.scale * (x + t.shear * y), t.origin.y() - t.scale * y });
    }
};

/// Exact number of points `flatten` writes for this transform.
pub fn flattenedPointCount(self: Outline, t: Transform) usize {
    var sink: Sink = .{};
    self.walk(t, &sink);
    return sink.n;
}

/// Writes one closed polygon per contour into `points_buf` (at least `flattenedPointCount`
/// long) and returns the polygons as slices stored in `contours_buf` (at least
/// `contourCount` long).
pub fn flatten(self: Outline, t: Transform, points_buf: []Point2, contours_buf: [][]const Point2) [][]const Point2 {
    var sink: Sink = .{ .points = points_buf, .contours = contours_buf };
    self.walk(t, &sink);
    return contours_buf[0..sink.c];
}

/// Receives flattened points; counts only when the output slices are absent.
const Sink = struct {
    points: ?[]Point2 = null,
    contours: ?[][]const Point2 = null,
    n: usize = 0,
    c: usize = 0,
    start: usize = 0,

    fn emit(self: *Sink, p: Point2) void {
        if (self.points) |points| points[self.n] = p;
        self.n += 1;
    }

    fn endContour(self: *Sink) void {
        if (self.contours) |contours| contours[self.c] = self.points.?[self.start..self.n];
        self.c += 1;
        self.start = self.n;
    }
};

fn walk(self: Outline, t: Transform, sink: *Sink) void {
    for (0..self.contourCount()) |i| {
        const pts = self.contour(i);
        if (pts.len < 2) continue;

        // A contour starts on its first on-curve point; with none, on the implied
        // midpoint between the first two control points.
        const on_curve: ?usize = for (pts, 0..) |p, k| {
            if (p.kind == .on_curve) break k;
        } else null;
        const start_index = on_curve orelse 0;
        const start: Point = if (on_curve != null) pts[start_index] else midpoint(pts[0], pts[1]);
        const steps = if (on_curve != null) pts.len - 1 else pts.len;

        sink.emit(t.apply(start.x, start.y));
        var prev_on = start;
        var ctrl: [2]Point = undefined;
        var pending: usize = 0;
        for (1..steps + 1) |k| {
            const p = pts[(start_index + k) % pts.len];
            switch (p.kind) {
                .on_curve => {
                    segment(t, prev_on, ctrl[0..pending], p, false, sink);
                    prev_on = p;
                    pending = 0;
                },
                .quad_control => {
                    if (pending > 0) {
                        const m = midpoint(ctrl[0], p);
                        quad(t, prev_on, ctrl[0], m, false, sink);
                        prev_on = m;
                    }
                    ctrl[0] = p;
                    pending = 1;
                },
                // A third control in a row is malformed and dropped.
                .cubic_control => if (pending < 2) {
                    ctrl[pending] = p;
                    pending += 1;
                },
            }
        }
        segment(t, prev_on, ctrl[0..pending], start, true, sink);
        sink.endContour();
    }
}

fn midpoint(a: Point, b: Point) Point {
    return .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2, .kind = .on_curve };
}

/// Emits the segment from `p0` to `p1` through the pending controls, skipping the end
/// point when it closes the contour (the polygon closes implicitly).
fn segment(t: Transform, p0: Point, ctrl: []const Point, p1: Point, closing: bool, sink: *Sink) void {
    switch (ctrl.len) {
        0 => if (!closing) sink.emit(t.apply(p1.x, p1.y)),
        1 => quad(t, p0, ctrl[0], p1, closing, sink),
        else => cubic(t, p0, ctrl[0], ctrl[1], p1, closing, sink),
    }
}

/// Uniform chords needed so that none deviates from the curve by more than
/// `flatness_tolerance`, given a bound on |B''| in device pixels: the error of `n`
/// chords is at most max|B''| / (8n²).
fn chordCount(second_derivative_max: f32) u32 {
    const n = @ceil(@sqrt(second_derivative_max / (8 * flatness_tolerance)));
    return @intFromFloat(@min(@max(n, 1), @as(f32, max_curve_segments)));
}

fn chordLimit(n: u32, closing: bool) u32 {
    return if (closing) n - 1 else n;
}

fn quad(t: Transform, p0: Point, c: Point, p1: Point, closing: bool, sink: *Sink) void {
    const d0 = t.apply(p0.x, p0.y);
    const d1 = t.apply(c.x, c.y);
    const d2 = t.apply(p1.x, p1.y);
    // B'' is the constant 2(p0 - 2c + p1).
    const n = chordCount(2 * d0.sub(d1.scale(2)).add(d2).norm());
    for (1..chordLimit(n, closing) + 1) |s| {
        const u = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(n));
        sink.emit(d0.lerp(d1, u).lerp(d1.lerp(d2, u), u));
    }
}

fn cubic(t: Transform, p0: Point, c1: Point, c2: Point, p1: Point, closing: bool, sink: *Sink) void {
    const d0 = t.apply(p0.x, p0.y);
    const d1 = t.apply(c1.x, c1.y);
    const d2 = t.apply(c2.x, c2.y);
    const d3 = t.apply(p1.x, p1.y);
    // B'' interpolates 6(p0 - 2c1 + c2) and 6(c1 - 2c2 + p1).
    const n = chordCount(6 * @max(d0.sub(d1.scale(2)).add(d2).norm(), d1.sub(d2.scale(2)).add(d3).norm()));
    for (1..chordLimit(n, closing) + 1) |s| {
        const u = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(n));
        const a = d0.lerp(d1, u);
        const b = d1.lerp(d2, u);
        const c = d2.lerp(d3, u);
        sink.emit(a.lerp(b, u).lerp(b.lerp(c, u), u));
    }
}

const testing = std.testing;
const synthetic = @import("truetype/synthetic.zig");

test "transform" {
    const t: Transform = .{ .scale = 0.1, .origin = .init(.{ 10.25, 80 }), .shear = 0.25 };
    const above = t.apply(100, 400);
    try testing.expectEqual(@as(f32, 10.25 + 0.1 * (100 + 100)), above.x());
    try testing.expectEqual(@as(f32, 40), above.y());
    const below = t.apply(100, -400);
    try testing.expect(below.x() < above.x());
    try testing.expectEqual(@as(f32, 120), below.y());
}

test "flatten a polygonal glyph" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const font = synthetic.font(&buf, .{});
    var o = try font.outline(testing.allocator, 1);
    defer o.deinit(testing.allocator);
    const t: Transform = .{ .scale = 0.1, .origin = .init(.{ 10, 80 }) };
    try testing.expectEqual(@as(usize, 8), o.flattenedPointCount(t));
    var points: [8]Point2 = undefined;
    var contours: [2][]const Point2 = undefined;
    const polys = o.flatten(t, &points, &contours);
    try testing.expectEqual(@as(usize, 2), polys.len);
    try testing.expectEqual(@as(usize, 4), polys[0].len);
    try testing.expectEqual(Point2.init(.{ 20, 80 }), polys[0][0]);
    try testing.expectEqual(Point2.init(.{ 80, 10 }), polys[0][2]);
    try testing.expectEqual(Point2.init(.{ 40, 60 }), polys[1][0]);
}

test "flatten curves: count matches, grows with size, stays closed" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const font = synthetic.font(&buf, .{});
    var o = try font.outline(testing.allocator, 3);
    defer o.deinit(testing.allocator);
    var prev: usize = 0;
    for ([_]f32{ 8, 64, 512 }) |size| {
        const t: Transform = .{ .scale = size / 1000, .origin = .init(.{ 0, size }) };
        const count = o.flattenedPointCount(t);
        try testing.expect(count > prev);
        prev = count;
        const points = try testing.allocator.alloc(Point2, count);
        defer testing.allocator.free(points);
        var contours: [1][]const Point2 = undefined;
        const polys = o.flatten(t, points, &contours);
        try testing.expectEqual(count, polys[0].len);
        // Convex, so every point lies within the control polygon's box.
        for (polys[0]) |p| {
            try testing.expect(p.x() >= 0 and p.x() <= 0.8 * size + 0.01);
            try testing.expect(p.y() >= 0.3 * size - 0.01 and p.y() <= size + 0.01);
        }
    }
    // 4 curves * 32 chords is the ceiling.
    try testing.expect(prev <= 4 * max_curve_segments);
}

test "flatten cubics: count matches, grows with size, stays closed" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const font = synthetic.font(&buf, .{ .cff = true });
    var o = try font.outline(testing.allocator, 3);
    defer o.deinit(testing.allocator);
    var prev: usize = 0;
    for ([_]f32{ 8, 64, 512 }) |size| {
        const t: Transform = .{ .scale = size / 1000, .origin = .init(.{ 0, size }) };
        const count = o.flattenedPointCount(t);
        try testing.expect(count > prev);
        prev = count;
        const points = try testing.allocator.alloc(Point2, count);
        defer testing.allocator.free(points);
        var contours: [1][]const Point2 = undefined;
        const polys = o.flatten(t, points, &contours);
        try testing.expectEqual(count, polys[0].len);
        // The start point appears once: the closing curve stops short of it.
        try testing.expectEqual(Point2.init(.{ 0.4 * size, size }), polys[0][0]);
        for (polys[0][1..]) |p| try testing.expect(p.x() != polys[0][0].x() or p.y() != polys[0][0].y());
        // Convex, so every point lies within the control polygon's box.
        for (polys[0]) |p| {
            try testing.expect(p.x() >= 0 and p.x() <= 0.8 * size + 0.01);
            try testing.expect(p.y() >= 0.3 * size - 0.01 and p.y() <= size + 0.01);
        }
    }
    try testing.expect(prev <= 4 * max_curve_segments);
}

test "fractional origin moves the polygon exactly" {
    var buf: [synthetic.buffer_size]u8 = undefined;
    const font = synthetic.font(&buf, .{});
    var o = try font.outline(testing.allocator, 6);
    defer o.deinit(testing.allocator);
    var a: [64]Point2 = undefined;
    var b: [64]Point2 = undefined;
    var ca: [1][]const Point2 = undefined;
    var cb: [1][]const Point2 = undefined;
    const pa = o.flatten(.{ .scale = 0.05, .origin = .init(.{ 10, 40 }) }, &a, &ca);
    const pb = o.flatten(.{ .scale = 0.05, .origin = .init(.{ 10.25, 40 }) }, &b, &cb);
    try testing.expectEqual(pa[0].len, pb[0].len);
    for (pa[0], pb[0]) |p, q| {
        try testing.expectApproxEqAbs(p.x() + 0.25, q.x(), 1e-4);
        try testing.expectEqual(p.y(), q.y());
    }
    // The contour starts on its on-curve point, not the leading control point.
    try testing.expectEqual(Point2.init(.{ 45, 40 }), pa[0][0]);
}
