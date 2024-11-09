const std = @import("std");
const assert = std.debug.assert;
const as = @import("meta.zig").as;
const Matrix = @import("matrix.zig").Matrix;
const Point2d = @import("point.zig").Point2d;
const svd = @import("svd.zig").svd;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;

/// A generic rectangle object with some convenience functionality.
pub fn Rectangle(comptime T: type) type {
    switch (@typeInfo(T)) {
        .int, .float => {},
        else => @compileError("Unsupported type " ++ @typeName(T) ++ " for Rectangle"),
    }
    return struct {
        const Self = @This();
        l: T,
        t: T,
        r: T,
        b: T,

        /// Initialize a rectangle by giving its four sides.
        pub fn init(l: T, t: T, r: T, b: T) Self {
            assert(r > l and b > t);
            return .{ .l = l, .t = t, .r = r, .b = b };
        }

        /// Initialize a rectangle at center x, y with the specified width and height.
        pub fn initCenter(x: T, y: T, w: T, h: T) Self {
            assert(w > 0 and h > 0);
            switch (@typeInfo(T)) {
                .int => {
                    const l = x - @divFloor(w, 2);
                    const t = y - @divFloor(h, 2);
                    const r = l + w - 1;
                    const b = t + h - 1;
                    return Self.init(l, t, r, b);
                },
                .float => {
                    const l = x - w / 2;
                    const t = y - h / 2;
                    const r = l + w;
                    const b = t + h;
                    return Self.init(l, t, r, b);
                },
                else => @compileError("Unsupported type " ++ @typeName(T) ++ " for Rectangle"),
            }
        }

        /// Casts self's underlying type to U.
        pub fn cast(self: Self, comptime U: type) Rectangle(U) {
            return .{
                .l = as(U, self.l),
                .t = as(U, self.t),
                .r = as(U, self.r),
                .b = as(U, self.b),
            };
        }

        /// Checks if a rectangle is ill-formed.
        pub fn isEmpty(self: Self) bool {
            return switch (@typeInfo(T)) {
                .int => self.t > self.b or self.l > self.r,
                .float => self.t >= self.b or self.l >= self.r,
                else => @compileError("Unsupported type " ++ @typeName(T) ++ " for Rectangle"),
            };
        }

        /// Returns the width of the rectangle.
        pub fn width(self: Self) if (@typeInfo(T) == .int) usize else T {
            return if (self.isEmpty()) 0 else switch (@typeInfo(T)) {
                .int => @intCast(self.r - self.l + 1),
                .float => self.r - self.l,
                else => @compileError("Unsupported type " ++ @typeName(T) ++ " for Rectangle"),
            };
        }

        /// Returns the height of the rectangle.
        pub fn height(self: Self) if (@typeInfo(T) == .int) usize else T {
            return if (self.isEmpty()) 0 else switch (@typeInfo(T)) {
                .int => @intCast(self.b - self.t + 1),
                .float => self.b - self.t,
                else => @compileError("Unsupported type " ++ @typeName(T) ++ " for Rectangle"),
            };
        }

        /// Returns the area of the rectangle
        pub fn area(self: Self) if (@typeInfo(T) == .int) usize else T {
            return self.height() * self.width();
        }

        /// Returns true if the point at x, y is inside the rectangle.
        pub fn contains(self: Self, x: T, y: T) bool {
            if (x < self.l or x > self.r or y < self.t or y > self.b) {
                return false;
            }
            return true;
        }
    };
}

test "Rectangle" {
    const irect = Rectangle(isize){ .l = 0, .t = 0, .r = 639, .b = 479 };
    try expectEqual(irect.width(), 640);
    try expectEqual(irect.height(), 480);
    const frect = Rectangle(f64){ .l = 0, .t = 0, .r = 639, .b = 479 };
    try expectEqual(frect.width(), 639);
    try expectEqual(frect.height(), 479);
    try expectEqual(frect.contains(640 / 2, 480 / 2), true);
    try expectEqual(irect.contains(640, 480), false);
    try expectEqualDeep(frect.cast(isize), irect);
}

/// Applies a similarity transform to a point.  By default, it will be initialized to the identity
/// function.  Use the fit method to update the transform to map between two sets of points.
pub fn SimilarityTransform(comptime T: type) type {
    return struct {
        const Self = @This();
        matrix: Matrix(T, 2, 2) = Matrix(T, 2, 2).identity(),
        bias: Matrix(T, 2, 1) = Matrix(T, 2, 1).initAll(0),

        /// Finds the best similarity transforms that maps between the two given sets of points.
        pub fn find(from_points: []const Point2d(T), to_points: []const Point2d(T)) Self {
            var transfrom = SimilarityTransform(T){};
            transfrom.fit(from_points, to_points);
            return transfrom;
        }

        /// Projects the given point using the similarity transform.
        pub fn project(self: Self, point: Point2d(T)) Point2d(T) {
            const src = Matrix(T, 2, 1){ .items = .{ .{point.x}, .{point.y} } };
            var dst = self.matrix.dot(src);
            return .{ .x = dst.at(0, 0) + self.bias.at(0, 0), .y = dst.at(1, 0) + self.bias.at(1, 0) };
        }

        /// Finds the best similarity transforms that maps between the two given sets of points.
        pub fn fit(self: *Self, from_points: []const Point2d(T), to_points: []const Point2d(T)) void {
            assert(from_points.len >= 2);
            assert(from_points.len == to_points.len);
            const num_points: T = @floatFromInt(from_points.len);
            var mean_from: Point2d(T) = .{ .x = 0, .y = 0 };
            var mean_to: Point2d(T) = .{ .x = 0, .y = 0 };
            var sigma_from: T = 0;
            var sigma_to: T = 0;
            var cov = Matrix(T, 2, 2).initAll(0);
            self.matrix = cov;
            for (0..from_points.len) |i| {
                mean_from.x += from_points[i].x;
                mean_from.y += from_points[i].y;
                mean_to.x += to_points[i].x;
                mean_to.y += to_points[i].y;
            }
            mean_from.x /= num_points;
            mean_from.y /= num_points;
            mean_to.x /= num_points;
            mean_to.y /= num_points;

            for (0..from_points.len) |i| {
                const from = Point2d(T){ .x = from_points[i].x - mean_from.x, .y = from_points[i].y - mean_from.y };
                const to = Point2d(T){ .x = to_points[i].x - mean_to.x, .y = to_points[i].y - mean_to.y };

                sigma_from += from.x * from.x + from.y * from.y;
                sigma_to += to.x * to.x + to.y * to.y;

                const from_mat = Matrix(T, 1, 2){ .items = .{.{ from.x, from.y }} };
                const to_mat = Matrix(T, 2, 1){ .items = .{ .{to.x}, .{to.y} } };
                cov = cov.add(to_mat.dot(from_mat));
            }
            sigma_from /= num_points;
            sigma_to /= num_points;
            cov = cov.scale(1.0 / num_points);
            const det_cov = cov.at(0, 0) * cov.at(1, 1) - cov.at(0, 1) * cov.at(1, 0);
            const result = svd(
                T,
                cov.rows,
                cov.cols,
                cov,
                .{ .with_u = true, .with_v = true, .mode = .skinny_u },
            );
            const u: *const Matrix(T, 2, 2) = &result[0];
            const d = Matrix(T, 2, 2){ .items = .{ .{ result[1].at(0, 0), 0 }, .{ 0, result[1].at(1, 0) } } };
            const v: *const Matrix(T, 2, 2) = &result[2];
            const det_u = u.at(0, 0) * u.at(1, 1) - u.at(0, 1) * u.at(1, 0);
            const det_v = v.at(0, 0) * v.at(1, 1) - v.at(0, 1) * v.at(1, 0);
            var s = Matrix(T, cov.rows, cov.cols).identity();
            if (det_cov < 0 or (det_cov == 0 and det_u * det_v < 0)) {
                if (d.at(1, 1) < d.at(0, 0)) {
                    s.set(1, 1, -1);
                } else {
                    s.set(0, 0, -1);
                }
            }
            const r = u.dot(s.dot(v.transpose()));
            var c: T = 1;
            if (sigma_from != 0) {
                c = 1.0 / sigma_from * d.dot(s).trace();
            }
            const m_from = Matrix(T, 2, 1){ .items = .{ .{mean_from.x}, .{mean_from.y} } };
            const m_to = Matrix(T, 2, 1){ .items = .{ .{mean_to.x}, .{mean_to.y} } };
            self.matrix = r.scale(c);
            self.bias = m_to.add(r.dot(m_from).scale(-c));
        }
    };
}

/// Applies an affine transform to a point.  By default, it will be initialized to the identity
/// function.  Use the fit method to update the transform to map between two sets of points.
pub fn AffineTransform(comptime T: type) type {
    return struct {
        const Self = @This();
        matrix: Matrix(T, 2, 2) = Matrix(T, 2, 2).identity(),
        bias: Matrix(T, 2, 1) = Matrix(T, 2, 1).initAll(0),

        /// Finds the best similarity transforms that maps between the two given sets of points.
        pub fn find(from_points: [3]Point2d(T), to_points: [3]Point2d(T)) Self {
            var transfrom = AffineTransform(T){};
            transfrom.fit(from_points, to_points);
            return transfrom;
        }

        /// Projects the given point using the similarity transform.
        pub fn project(self: Self, point: Point2d(T)) Point2d(T) {
            const src = Matrix(T, 2, 1){ .items = .{ .{point.x}, .{point.y} } };
            var dst = self.matrix.dot(src);
            return .{ .x = dst.at(0, 0) + self.bias.at(0, 0), .y = dst.at(1, 0) + self.bias.at(1, 0) };
        }

        /// Finds the best similarity transforms that maps between the two given sets of points.
        pub fn fit(self: *Self, from_points: [3]Point2d(T), to_points: [3]Point2d(T)) void {
            assert(from_points.len >= 2);
            assert(from_points.len == to_points.len);
            var p = Matrix(T, 3, from_points.len){};
            var q = Matrix(T, 2, to_points.len){};
            for (0..from_points.len) |i| {
                p.set(0, i, from_points[i].x);
                p.set(1, i, from_points[i].y);
                p.set(2, i, 1);

                q.set(0, i, to_points[i].x);
                q.set(1, i, to_points[i].y);
            }
            const m = q.dot(p.inverse().?);
            self.matrix = m.getSubMatrix(0, 0, 2, 2);
            self.bias = m.getCol(2);
        }
    };
}

test "affine3" {
    const T = f64;
    const from_points: []const Point2d(T) = &.{
        .{ .x = 0, .y = 0 },
        .{ .x = 0, .y = 1 },
        .{ .x = 1, .y = 1 },
    };
    const to_points: []const Point2d(T) = &.{
        .{ .x = 0, .y = 1 },
        .{ .x = 1, .y = 1 },
        .{ .x = 1, .y = 0 },
    };
    const tf = AffineTransform(f64).find(from_points[0..3].*, to_points[0..3].*);
    const matrix = Matrix(T, 2, 2){
        .items = .{
            .{ 0, 1 },
            .{ -1, 0 },
        },
    };
    const bias = Matrix(T, 2, 1){ .items = .{
        .{0},
        .{1},
    } };
    try std.testing.expectEqualDeep(tf.matrix, matrix);
    try std.testing.expectEqualDeep(tf.bias, bias);

    const itf = AffineTransform(f64).find(to_points[0..3].*, from_points[0..3].*);
    for (from_points, to_points) |f, t| {
        try std.testing.expectEqualDeep(tf.project(f), t);
        try std.testing.expectEqualDeep(itf.project(t), f);
    }
}

/// Applies a projective transform to a point.  By default, it will be initialized to the identity
/// function.  Use the fit method to update the transform to map between two sets of points.
pub fn ProjectiveTransform(comptime T: type) type {
    return struct {
        const Self = @This();
        matrix: Matrix(T, 3, 3) = Matrix(T, 3, 3).identity(),

        /// Finds the best projective transforms that maps between the two given sets of points.
        pub fn find(from_points: []const Point2d(T), to_points: []const Point2d(T)) Self {
            var transfrom = ProjectiveTransform(T){};
            transfrom.fit(from_points, to_points);
            return transfrom;
        }

        /// Projects the given point using the projective transform
        pub fn project(self: Self, point: Point2d(T)) Point2d(T) {
            const src = Matrix(T, 3, 1){ .items = .{ .{point.x}, .{point.y}, .{1} } };
            var dst = self.matrix.dot(src);
            if (dst.at(2, 0) != 0) {
                dst = dst.scale(1 / dst.at(2, 0));
            }
            return .{ .x = dst.at(0, 0), .y = dst.at(1, 0) };
        }

        /// Finds the best projective transforms that maps between the two given sets of points.
        pub fn fit(self: *Self, from_points: []const Point2d(T), to_points: []const Point2d(T)) void {
            assert(from_points.len >= 4);
            assert(from_points.len == to_points.len);
            var accum = Matrix(T, 9, 9).initAll(0);
            var b = Matrix(T, 2, 9).initAll(0);
            for (0..from_points.len) |i| {
                const f = Matrix(T, 1, 3){ .items = .{.{ from_points[i].x, from_points[i].y, 1 }} };
                const t = Matrix(T, 1, 3){ .items = .{.{ to_points[i].x, to_points[i].y, 1 }} };
                b.setSubMatrix(0, 0, f.scale(t.at(0, 1)));
                b.setSubMatrix(1, 0, f);
                b.setSubMatrix(0, 3, f.scale(-t.at(0, 0)));
                b.setSubMatrix(1, 6, f.scale(-t.at(0, 0)));
                accum = accum.add(b.transpose().dot(b));
            }
            const result = svd(
                T,
                accum.rows,
                accum.cols,
                accum,
                .{ .with_u = true, .with_v = false, .mode = .full_u },
            );
            const u: *const Matrix(T, 9, 9) = &result[0];
            const q: *const Matrix(T, 9, 1) = &result[1];
            self.matrix = blk: {
                var min: T = q.at(0, 0);
                var idx: usize = 0;
                for (1..q.rows) |i| {
                    const val = q.at(i, 0);
                    if (val < min) {
                        min = val;
                        idx = i;
                    }
                }
                break :blk u.getCol(idx).reshape(3, 3);
            };
        }
    };
}

test "projection4" {
    const T = f64;
    const from_points: []const Point2d(T) = &.{
        .{ .x = 199.67754364, .y = 200.17905235 },
        .{ .x = 167.90229797, .y = 175.55920601 },
        .{ .x = 270.33649445, .y = 207.96521187 },
        .{ .x = 267.53637314, .y = 188.24442387 },
    };
    const to_points: []const Point2d(T) = &.{
        .{ .x = 440.68012238, .y = 275.45248032 },
        .{ .x = 429.62512970, .y = 262.64307976 },
        .{ .x = 484.23328400, .y = 279.44332123 },
        .{ .x = 488.08315277, .y = 272.79547691 },
    };
    const transform = ProjectiveTransform(f64).find(from_points, to_points);
    const matrix = Matrix(T, 3, 3){
        .items = .{
            .{ -5.9291612941280800e-03, 7.0341614664190845e-03, -8.9922894648198459e-01 },
            .{ -2.8361695646354147e-03, 2.9060176209597761e-03, -4.3735741833190661e-01 },
            .{ -1.0156215756801098e-05, 1.3270311721030187e-05, -2.1603199531972065e-03 },
        },
    };
    for (0..transform.matrix.rows) |r| {
        for (0..transform.matrix.cols) |c| {
            try std.testing.expectApproxEqAbs(transform.matrix.at(r, c), matrix.at(r, c), 1e-3);
        }
    }
    for (0..from_points.len) |i| {
        const p = transform.project(from_points[i]);
        try std.testing.expectApproxEqRel(p.x, to_points[i].x, 1e-5);
        try std.testing.expectApproxEqRel(p.y, to_points[i].y, 1e-5);
    }
}

test "projection8" {
    const T = f64;
    const from_points: []const Point2d(T) = &.{
        .{ .x = 319.48406982, .y = 240.21486282 },
        .{ .x = 268.64367676, .y = 210.67104721 },
        .{ .x = 432.53839111, .y = 249.55825424 },
        .{ .x = 428.05819702, .y = 225.89330864 },
        .{ .x = 687.00787354, .y = 240.97020721 },
        .{ .x = 738.32287598, .y = 208.32876205 },
        .{ .x = 574.62890625, .y = 250.60971451 },
        .{ .x = 579.63378906, .y = 225.37580109 },
    };

    const to_points: []const Point2d(T) = &.{
        .{ .x = 330.48120117, .y = 408.22596359 },
        .{ .x = 317.55538940, .y = 393.26282501 },
        .{ .x = 356.74267578, .y = 411.06428146 },
        .{ .x = 349.94784546, .y = 400.26379395 },
        .{ .x = 438.15582275, .y = 411.75442886 },
        .{ .x = 452.01367188, .y = 398.08815765 },
        .{ .x = 398.66107178, .y = 413.83139420 },
        .{ .x = 395.29974365, .y = 401.73685455 },
    };
    const transform = ProjectiveTransform(T).find(from_points, to_points);
    const matrix = Matrix(T, 3, 3){ .items = .{
        .{ 7.9497770144471079e-05, 8.6315632819330035e-04, -6.3240797603906806e-01 },
        .{ 3.9739851020393160e-04, 6.4356336568222570e-04, -7.7463154396817901e-01 },
        .{ 1.0207719920241196e-06, 2.6961794891002063e-06, -2.1907681782918601e-03 },
    } };
    const tol = std.math.sqrt(std.math.floatEps(T));
    for (0..transform.matrix.rows) |r| {
        for (0..transform.matrix.cols) |c| {
            try std.testing.expectApproxEqAbs(transform.matrix.at(r, c), matrix.at(r, c), tol);
        }
    }
    for (0..from_points.len) |i| {
        const p = transform.project(from_points[i]);
        try std.testing.expectApproxEqRel(p.x, to_points[i].x, 1e-2);
        try std.testing.expectApproxEqRel(p.y, to_points[i].y, 1e-2);
    }
}

/// Struct that encapsulates all logic for a Convex Hull computation.
pub fn ConvexHull(comptime T: type) type {
    return struct {
        points: std.ArrayList(Point2d(T)),
        hull: std.ArrayList(Point2d(T)),

        const Self = @This();
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .points = std.ArrayList(Point2d(T)).init(allocator),
                .hull = std.ArrayList(Point2d(T)).init(allocator),
            };
        }

        pub fn deinit(self: Self) void {
            self.points.deinit();
            self.hull.deinit();
        }

        const Orientation = enum {
            collinear,
            clockwise,
            counter_clockwise,
        };

        /// Returns the orientation of the three points.
        fn computeOrientation(a: Point2d(T), b: Point2d(T), c: Point2d(T)) Orientation {
            const v: T = a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y);
            // Due to floating point precision errors, compute the reverse orientation, and
            // if any of those is collinear, then return collinear.
            const w: T = a.x * (c.y - b.y) + c.x * (b.y - a.y) + b.x * (a.y - c.y);
            if (v * w == 0) return .collinear;
            if (v < 0) return .clockwise;
            if (v > 0) return .counter_clockwise;
            return .collinear;
        }

        /// Compares the points by polar angle in clockwise order.
        fn clockwiseOrder(p: Point2d(T), a: Point2d(T), b: Point2d(T)) bool {
            return switch (computeOrientation(p, a, b)) {
                .clockwise => true,
                .counter_clockwise => false,
                .collinear => p.distanceSquared(a) < p.distanceSquared(b),
            };
        }

        /// Returns the convex hull of a set of points using the Graham's scan algorithm.
        pub fn find(self: *Self, points: []const Point2d(T)) !?[]Point2d(T) {
            // We need at least 3 points to compute a hull.
            if (points.len < 3) {
                return null;
            }
            self.points.clearRetainingCapacity();
            try self.points.resize(points.len);
            @memcpy(self.points.items, points);

            // Find the point with the lowest y-coordinate.
            // If there are ties, choose the one with the lowest x-coordinate.
            var lowest: Point2d(T) = .{ .x = std.math.floatMax(T), .y = std.math.floatMax(T) };
            for (self.points.items) |p| {
                if (p.y < lowest.y or (p.y == lowest.y and p.x < lowest.x)) {
                    lowest = p;
                }
            }

            // Sort the points by polar angle in clockwise order.
            std.mem.sort(Point2d(T), self.points.items, lowest, clockwiseOrder);
            self.hull.clearRetainingCapacity();
            for (self.points.items) |p| {
                while (self.hull.items.len > 1 and computeOrientation(
                    self.hull.items[self.hull.items.len - 2],
                    self.hull.items[self.hull.items.len - 1],
                    p,
                ) != .clockwise) {
                    _ = self.hull.pop();
                }
                try self.hull.append(p);
            }

            // Handle the case were all input points were collinear.
            if (self.hull.items.len < 3) {
                return null;
            }

            return self.hull.items;
        }
    };
}

test "convex hull" {
    const points: []const Point2d(f32) = &.{
        .{ .x = 0.0, .y = 0.0 },
        .{ .x = 1.0, .y = 1.0 },
        .{ .x = 2.0, .y = 2.0 },
        .{ .x = 3.0, .y = 1.0 },
        .{ .x = 4.0, .y = 0.0 },
        .{ .x = 2.0, .y = 4.0 },
        .{ .x = 1.0, .y = 3.0 },
    };
    var convex_hull = ConvexHull(f32).init(std.testing.allocator);
    defer convex_hull.deinit();
    const hull = (try convex_hull.find(points)).?;
    try expectEqual(hull.len, 4);
    try expectEqualDeep(hull[0], points[0]);
    try expectEqualDeep(hull[1], points[6]);
    try expectEqualDeep(hull[2], points[5]);
    try expectEqualDeep(hull[3], points[4]);

    // check passing an empty slice
    var empty = convex_hull.find(&.{});
    try expectEqual(empty, null);
    // check passing less than 3 points
    empty = convex_hull.find(points[3..5]);
    try expectEqual(empty, null);
    // check passing aligned points
    empty = convex_hull.find(points[0..3]);
    try expectEqual(empty, null);
}

test "computeOrientation" {
    var convex_hull = ConvexHull(f32).init(std.testing.allocator);
    defer convex_hull.deinit();
    const computeOrientation = ConvexHull(f32).computeOrientation;
    // These three points can have different orientations due to floating point precision.
    const a: Point2d(f32) = .{ .x = 4.9171928e-1, .y = 6.473901e-1 };
    const b: Point2d(f32) = .{ .x = 3.6271343e-1, .y = 9.712454e-1 };
    const c: Point2d(f32) = .{ .x = 3.9276862e-1, .y = 8.9579517e-1 };
    const orientation_abc = computeOrientation(a, b, c);
    const orientation_acb = computeOrientation(a, c, b);
    try std.testing.expectEqual(orientation_abc, orientation_acb);
}
