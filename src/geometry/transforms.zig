const std = @import("std");
const assert = std.debug.assert;

const SMatrix = @import("../matrix.zig").SMatrix;
const Matrix = @import("../matrix.zig").Matrix;
const OpsBuilder = @import("../matrix.zig").OpsBuilder;
const svd = @import("../svd.zig").svd;
const Point2d = @import("points.zig").Point2d;

/// Applies a similarity transform to a point.  By default, it will be initialized to the identity
/// function.  Use the fit method to update the transform to map between two sets of points.
pub fn SimilarityTransform(comptime T: type) type {
    return struct {
        const Self = @This();
        matrix: SMatrix(T, 2, 2),
        bias: SMatrix(T, 2, 1),
        pub const identity: Self = .{ .matrix = .identity(), .bias = .initAll(0) };

        /// Finds the best similarity transform that maps between the two given sets of points.
        pub fn init(from_points: []const Point2d(T), to_points: []const Point2d(T)) Self {
            var transform: SimilarityTransform(T) = .identity;
            transform.find(from_points, to_points);
            return transform;
        }

        /// Projects the given point using the similarity transform.
        pub fn project(self: Self, point: Point2d(T)) Point2d(T) {
            const src: SMatrix(T, 2, 1) = .init(.{ .{point.x}, .{point.y} });
            return self.matrix.dot(src).add(self.bias).toPoint2d();
        }

        /// Finds the best similarity transform that maps between the two given sets of points.
        pub fn find(self: *Self, from_points: []const Point2d(T), to_points: []const Point2d(T)) void {
            assert(from_points.len >= 2);
            assert(from_points.len == to_points.len);
            const num_points: T = @floatFromInt(from_points.len);
            var mean_from: Point2d(T) = .origin;
            var mean_to: Point2d(T) = .origin;
            var sigma_from: T = 0;
            var sigma_to: T = 0;
            var cov: SMatrix(T, 2, 2) = .initAll(0);
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

                const from_mat: SMatrix(T, 1, 2) = .init(.{.{ from.x, from.y }});
                const to_mat: SMatrix(T, 2, 1) = .init(.{ .{to.x}, .{to.y} });
                cov = cov.add(to_mat.dot(from_mat));
            }
            sigma_from /= num_points;
            sigma_to /= num_points;
            cov = cov.scale(1.0 / num_points);
            const det_cov = cov.at(0, 0).* * cov.at(1, 1).* - cov.at(0, 1).* * cov.at(1, 0).*;
            const result = svd(
                T,
                cov.rows,
                cov.cols,
                cov,
                .{ .with_u = true, .with_v = true, .mode = .skinny_u },
            );
            const u: *const SMatrix(T, 2, 2) = &result[0];
            const d: SMatrix(T, 2, 2) = .init(.{ .{ result[1].at(0, 0).*, 0 }, .{ 0, result[1].at(1, 0).* } });
            const v: *const SMatrix(T, 2, 2) = &result[2];
            const det_u = u.at(0, 0).* * u.at(1, 1).* - u.at(0, 1).* * u.at(1, 0).*;
            const det_v = v.at(0, 0).* * v.at(1, 1).* - v.at(0, 1).* * v.at(1, 0).*;
            var s: SMatrix(T, cov.rows, cov.cols) = .identity();
            if (det_cov < 0 or (det_cov == 0 and det_u * det_v < 0)) {
                if (d.at(1, 1).* < d.at(0, 0).*) {
                    s.at(1, 1).* = -1;
                } else {
                    s.at(0, 0).* = -1;
                }
            }
            const r = u.dot(s.dot(v.transpose()));
            var c: T = 1;
            if (sigma_from != 0) {
                c = 1.0 / sigma_from * d.dot(s).trace();
            }
            const m_from: SMatrix(T, 2, 1) = .init(.{ .{mean_from.x}, .{mean_from.y} });
            const m_to: SMatrix(T, 2, 1) = .init(.{ .{mean_to.x}, .{mean_to.y} });
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
        matrix: SMatrix(T, 2, 2),
        bias: SMatrix(T, 2, 1),
        allocator: std.mem.Allocator,

        /// Finds the best affine transform that maps between the two given sets of points.
        pub fn init(allocator: std.mem.Allocator, from_points: []const Point2d(T), to_points: []const Point2d(T)) !Self {
            var transform: AffineTransform(T) = .{
                .matrix = SMatrix(T, 2, 2).identity(),
                .bias = SMatrix(T, 2, 1).initAll(0),
                .allocator = allocator,
            };
            try transform.find(from_points, to_points);
            return transform;
        }

        /// Projects the given point using the affine transform.
        pub fn project(self: Self, point: Point2d(T)) Point2d(T) {
            const src: SMatrix(T, 2, 1) = .init(.{ .{point.x}, .{point.y} });
            return self.matrix.dot(src).add(self.bias).toPoint2d();
        }

        /// Finds the best affine transform that maps between the two given sets of points.
        pub fn find(self: *Self, from_points: []const Point2d(T), to_points: []const Point2d(T)) !void {
            assert(from_points.len == to_points.len);
            assert(from_points.len >= 3);
            var p = try Matrix(T).init(self.allocator, 3, from_points.len);
            defer p.deinit();
            var q = try Matrix(T).init(self.allocator, 2, to_points.len);
            defer q.deinit();
            for (0..from_points.len) |i| {
                p.at(0, i).* = from_points[i].x;
                p.at(1, i).* = from_points[i].y;
                p.at(2, i).* = 1;

                q.at(0, i).* = to_points[i].x;
                q.at(1, i).* = to_points[i].y;
            }
            // Use OpsBuilder to perform matrix operations
            var p_ops = try OpsBuilder(T).init(self.allocator, p);
            defer p_ops.deinit();

            // Invert p
            try p_ops.inverse();
            var p_inv = p_ops.toOwned();
            defer p_inv.deinit();

            // Calculate m = q * p^-1
            var q_ops = try OpsBuilder(T).init(self.allocator, q);
            defer q_ops.deinit();
            try q_ops.dot(p_inv);
            var m = q_ops.toOwned();
            defer m.deinit();

            // Extract the 2x2 matrix
            var m_ops1 = try OpsBuilder(T).init(self.allocator, m);
            defer m_ops1.deinit();
            try m_ops1.subMatrix(0, 0, 2, 2);
            var sub_matrix = m_ops1.toOwned();
            defer sub_matrix.deinit();
            self.matrix = sub_matrix.toSMatrix(2, 2);

            // Extract the bias column
            var m_ops2 = try OpsBuilder(T).init(self.allocator, m);
            defer m_ops2.deinit();
            try m_ops2.col(2);
            var bias_col = m_ops2.toOwned();
            defer bias_col.deinit();
            self.bias = bias_col.toSMatrix(2, 1);
        }
    };
}

/// Applies a projective transform to a point.  By default, it will be initialized to the identity
/// function.  Use the fit method to update the transform to map between two sets of points.
pub fn ProjectiveTransform(comptime T: type) type {
    return struct {
        const Self = @This();
        matrix: SMatrix(T, 3, 3),
        pub const identity: Self = .{ .matrix = .identity() };

        /// Finds the best projective transform that maps between the two given sets of points.
        pub fn init(from_points: []const Point2d(T), to_points: []const Point2d(T)) Self {
            var transform: ProjectiveTransform(T) = .identity;
            transform.find(from_points, to_points);
            return transform;
        }

        /// Projects the given point using the projective transform
        pub fn project(self: Self, point: Point2d(T)) Point2d(T) {
            const src: SMatrix(T, 3, 1) = .init(.{ .{point.x}, .{point.y}, .{1} });
            var dst = self.matrix.dot(src);
            if (dst.at(2, 0).* != 0) {
                dst = dst.scale(1 / dst.at(2, 0).*);
            }
            return dst.toPoint2d();
        }

        /// Returns the inverse of the current projective transform.
        pub fn inverse(self: Self) ?Self {
            return if (self.matrix.inverse()) |inv| .{ .matrix = inv } else null;
        }

        /// Finds the best projective transform that maps between the two given sets of points.
        pub fn find(self: *Self, from_points: []const Point2d(T), to_points: []const Point2d(T)) void {
            assert(from_points.len >= 4);
            assert(from_points.len == to_points.len);
            var accum: SMatrix(T, 9, 9) = .initAll(0);
            var b: SMatrix(T, 2, 9) = .initAll(0);
            for (0..from_points.len) |i| {
                const f: SMatrix(T, 1, 3) = .init(.{.{ from_points[i].x, from_points[i].y, 1 }});
                const t: SMatrix(T, 1, 3) = .init(.{.{ to_points[i].x, to_points[i].y, 1 }});
                b.setSubMatrix(0, 0, f.scale(t.at(0, 1).*));
                b.setSubMatrix(1, 0, f);
                b.setSubMatrix(0, 3, f.scale(-t.at(0, 0).*));
                b.setSubMatrix(1, 6, f.scale(-t.at(0, 0).*));
                accum = accum.add(b.transpose().dot(b));
            }
            const u, const q, _, _ = svd(
                T,
                accum.rows,
                accum.cols,
                accum,
                .{ .with_u = true, .with_v = false, .mode = .full_u },
            );
            // TODO: Check the retval from svd (result[3]) for convergence errors.
            // If svd fails to converge, the resulting transform matrix might be unstable.
            self.matrix = blk: {
                var min: T = q.at(0, 0).*;
                var idx: usize = 0;
                for (1..q.rows) |i| {
                    const val = q.at(i, 0).*;
                    if (val < min) {
                        min = val;
                        idx = i;
                    }
                }
                break :blk u.col(idx).reshape(3, 3);
            };
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
    const tf = try AffineTransform(f64).init(std.testing.allocator, from_points[0..3], to_points[0..3]);
    const matrix: SMatrix(T, 2, 2) = .init(.{ .{ 0, 1 }, .{ -1, 0 } });
    const bias: SMatrix(T, 2, 1) = .init(.{ .{0}, .{1} });
    try std.testing.expectEqualDeep(tf.matrix, matrix);
    try std.testing.expectEqualDeep(tf.bias, bias);

    const itf = try AffineTransform(f64).init(std.testing.allocator, to_points[0..3], from_points[0..3]);
    for (from_points, to_points) |f, t| {
        try std.testing.expectEqualDeep(tf.project(f), t);
        try std.testing.expectEqualDeep(itf.project(t), f);
    }
}

test "projection4" {
    const T = f64;
    const tol = 1e-5;
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
    const transform: ProjectiveTransform(T) = .init(from_points, to_points);
    const matrix: SMatrix(T, 3, 3) = .init(.{
        .{ -5.9291612941280800e-03, 7.0341614664190845e-03, -8.9922894648198459e-01 },
        .{ -2.8361695646354147e-03, 2.9060176209597761e-03, -4.3735741833190661e-01 },
        .{ -1.0156215756801098e-05, 1.3270311721030187e-05, -2.1603199531972065e-03 },
    });
    for (0..transform.matrix.rows) |r| {
        for (0..transform.matrix.cols) |c| {
            try std.testing.expectApproxEqAbs(transform.matrix.at(r, c).*, matrix.at(r, c).*, 1e-3);
        }
    }
    for (from_points, to_points) |f, t| {
        const p = transform.project(f);
        try std.testing.expectApproxEqRel(p.x, t.x, tol);
        try std.testing.expectApproxEqRel(p.y, t.y, tol);
    }

    const m_inv = transform.inverse().?;
    const t_inv: ProjectiveTransform(T) = .init(to_points, from_points);
    for (from_points) |f| {
        var fp = t_inv.project(transform.project(f));
        try std.testing.expectApproxEqRel(f.x, fp.x, tol);
        try std.testing.expectApproxEqRel(f.y, fp.y, tol);

        fp = m_inv.project(transform.project(f));
        try std.testing.expectApproxEqRel(f.x, fp.x, tol);
        try std.testing.expectApproxEqRel(f.y, fp.y, tol);
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
    const transform: ProjectiveTransform(T) = .init(from_points, to_points);
    const matrix: SMatrix(T, 3, 3) = .init(.{
        .{ 7.9497770144471079e-05, 8.6315632819330035e-04, -6.3240797603906806e-01 },
        .{ 3.9739851020393160e-04, 6.4356336568222570e-04, -7.7463154396817901e-01 },
        .{ 1.0207719920241196e-06, 2.6961794891002063e-06, -2.1907681782918601e-03 },
    });
    const tol = std.math.sqrt(std.math.floatEps(T));
    for (0..transform.matrix.rows) |r| {
        for (0..transform.matrix.cols) |c| {
            try std.testing.expectApproxEqAbs(transform.matrix.at(r, c).*, matrix.at(r, c).*, tol);
        }
    }
    for (0..from_points.len) |i| {
        const p = transform.project(from_points[i]);
        try std.testing.expectApproxEqRel(p.x, to_points[i].x, 1e-2);
        try std.testing.expectApproxEqRel(p.y, to_points[i].y, 1e-2);
    }
}
