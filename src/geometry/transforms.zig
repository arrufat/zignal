const std = @import("std");
const assert = std.debug.assert;

const SMatrix = @import("../matrix.zig").SMatrix;
const Matrix = @import("../matrix.zig").Matrix;
const Point = @import("Point.zig").Point;
const geom_utils = @import("utils.zig");

/// Applies a similarity transform to a point.  By default, it will be initialized to the identity
/// function.  Use the fit method to update the transform to map between two sets of points.
pub fn SimilarityTransform(comptime T: type) type {
    comptime assert(@typeInfo(T) == .float);
    return struct {
        const Self = @This();
        matrix: SMatrix(T, 2, 2),
        bias: SMatrix(T, 2, 1),
        pub const identity: Self = .{ .matrix = .identity(), .bias = .initAll(0) };

        /// Finds the best similarity transform that maps between the two given sets of points.
        /// Returns `error.NotConverged` when the internal SVD fails to converge or
        /// `error.RankDeficient` when the correspondences do not span a full-rank transform.
        pub fn init(from_points: []const Point(2, T), to_points: []const Point(2, T)) !Self {
            var transform: SimilarityTransform(T) = .identity;
            try transform.find(from_points, to_points);
            return transform;
        }

        /// Returns a new `SimilarityTransform` with its internal components (matrix and bias)
        /// converted to the specified scalar type `U`.
        pub fn as(self: Self, comptime U: type) SimilarityTransform(U) {
            return .{
                .matrix = self.matrix.as(U),
                .bias = self.bias.as(U),
            };
        }

        /// Projects the given point using the similarity transform.
        pub fn project(self: Self, point: Point(2, T)) Point(2, T) {
            const src: SMatrix(T, 2, 1) = .init(.{ .{point.x()}, .{point.y()} });
            return self.matrix.dot(src).add(self.bias).toPoint(2);
        }

        /// Finds the best similarity transform that maps between the two given sets of points.
        /// Returns `error.NotConverged` when the SVD fails to converge or `error.RankDeficient`
        /// if the input points lack the rank required to define a similarity transform.
        pub fn find(self: *Self, from_points: []const Point(2, T), to_points: []const Point(2, T)) !void {
            assert(from_points.len >= 2);
            assert(from_points.len == to_points.len);
            const num_points: T = @floatFromInt(from_points.len);
            var mean_from: Point(2, T) = .origin;
            var mean_to: Point(2, T) = .origin;
            var sigma_from: T = 0;
            var sigma_to: T = 0;
            var cov: SMatrix(T, 2, 2) = .initAll(0);
            self.matrix = cov;
            for (0..from_points.len) |i| {
                mean_from = mean_from.add(from_points[i]);
                mean_to = mean_to.add(to_points[i]);
            }
            mean_from = mean_from.scale(1.0 / num_points);
            mean_to = mean_to.scale(1.0 / num_points);

            for (0..from_points.len) |i| {
                const from = from_points[i].sub(mean_from);
                const to = to_points[i].sub(mean_to);

                sigma_from += from.normSquared();
                sigma_to += to.normSquared();

                const from_mat: SMatrix(T, 1, 2) = .init(.{.{ from.x(), from.y() }});
                const to_mat: SMatrix(T, 2, 1) = .init(.{ .{to.x()}, .{to.y()} });
                cov = cov.add(to_mat.dot(from_mat));
            }
            sigma_from /= num_points;
            sigma_to /= num_points;
            cov = cov.scale(1.0 / num_points);
            const det_cov = cov.at(0, 0).* * cov.at(1, 1).* - cov.at(0, 1).* * cov.at(1, 0).*;
            const result = cov.svd(.{ .with_u = true, .with_v = true, .mode = .skinny_u });
            if (result.converged != 0) {
                return error.NotConverged;
            }
            const s_values = result.s;
            const tol = s_values.at(0, 0).* * std.math.floatEps(T) * @as(T, @floatFromInt(s_values.rows));
            var effective_rank: usize = 0;
            for (0..s_values.rows) |i| {
                if (s_values.at(i, 0).* > tol) {
                    effective_rank += 1;
                }
            }
            if (effective_rank == 0) {
                return error.RankDeficient;
            }
            const u = &result.u;
            const d: SMatrix(T, 2, 2) = .init(.{ .{ result.s.at(0, 0).*, 0 }, .{ 0, result.s.at(1, 0).* } });
            const v = &result.v;
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
            const m_from: SMatrix(T, 2, 1) = .init(.{ .{mean_from.x()}, .{mean_from.y()} });
            const m_to: SMatrix(T, 2, 1) = .init(.{ .{mean_to.x()}, .{mean_to.y()} });
            self.matrix = r.scale(c);
            self.bias = m_to.add(r.dot(m_from).scale(-c));
        }
    };
}

/// Applies an affine transform to a point.  By default, it will be initialized to the identity
/// function.  Use the fit method to update the transform to map between two sets of points.
pub fn AffineTransform(comptime T: type) type {
    comptime assert(@typeInfo(T) == .float);
    return struct {
        const Self = @This();
        matrix: SMatrix(T, 2, 2),
        bias: SMatrix(T, 2, 1),
        allocator: std.mem.Allocator,

        /// Finds the best affine transform that maps between the two given sets of points.
        /// Returns `error.NotConverged` when the pseudo-inverse SVD fails to converge or
        /// `error.RankDeficient` when the correspondences do not span a full-rank affine mapping.
        pub fn init(allocator: std.mem.Allocator, from_points: []const Point(2, T), to_points: []const Point(2, T)) !Self {
            var transform: AffineTransform(T) = .{
                .matrix = SMatrix(T, 2, 2).identity(),
                .bias = SMatrix(T, 2, 1).initAll(0),
                .allocator = allocator,
            };
            try transform.find(from_points, to_points);
            return transform;
        }

        /// Returns a new `AffineTransform` with its internal components (matrix and bias)
        /// converted to the specified scalar type `U`.
        pub fn as(self: Self, comptime U: type) AffineTransform(U) {
            return .{
                .matrix = self.matrix.as(U),
                .bias = self.bias.as(U),
                .allocator = self.allocator,
            };
        }

        /// Projects the given point using the affine transform.
        pub fn project(self: Self, point: Point(2, T)) Point(2, T) {
            const src: SMatrix(T, 2, 1) = .init(.{ .{point.x()}, .{point.y()} });
            return self.matrix.dot(src).add(self.bias).toPoint(2);
        }

        /// Finds the best affine transform that maps between the two given sets of points.
        /// Returns `error.NotConverged` when the SVD inside the pseudo-inverse fails to converge or
        /// `error.RankDeficient` if the input points are degenerate.
        pub fn find(self: *Self, from_points: []const Point(2, T), to_points: []const Point(2, T)) !void {
            assert(from_points.len == to_points.len);
            assert(from_points.len >= 3);
            var p = try Matrix(T).init(self.allocator, 3, from_points.len);
            defer p.deinit();
            var q = try Matrix(T).init(self.allocator, 2, to_points.len);
            defer q.deinit();
            for (0..from_points.len) |i| {
                p.at(0, i).* = from_points[i].x();
                p.at(1, i).* = from_points[i].y();
                p.at(2, i).* = 1;

                q.at(0, i).* = to_points[i].x();
                q.at(1, i).* = to_points[i].y();
            }
            // Use Matrix operations to perform matrix operations
            // Compute the pseudo-inverse so we can support additional correspondences
            var effective_rank: usize = 0;
            var pinv_chain = p.pseudoInverse(.{ .effective_rank = &effective_rank });
            var pinv = try pinv_chain.eval();
            defer pinv.deinit();
            if (effective_rank < 3) {
                return error.RankDeficient;
            }

            // Calculate m = q * p^+
            var m = try q.dot(pinv).eval();
            defer m.deinit();

            // Extract the 2x2 matrix
            var sub_matrix = try m.subMatrix(0, 0, 2, 2).eval();
            defer sub_matrix.deinit();
            self.matrix = sub_matrix.toSMatrix(2, 2);

            // Extract the bias column
            var bias_col = try m.col(2).eval();
            defer bias_col.deinit();
            self.bias = bias_col.toSMatrix(2, 1);
        }
    };
}

/// Applies a projective transform to a point.  By default, it will be initialized to the identity
/// function.  Use the fit method to update the transform to map between two sets of points.
pub fn ProjectiveTransform(comptime T: type) type {
    comptime assert(@typeInfo(T) == .float);
    return struct {
        const Self = @This();
        matrix: SMatrix(T, 3, 3),
        pub const identity: Self = .{ .matrix = .identity() };

        /// Finds the best projective transform that maps between the two given sets of points.
        /// Returns `error.NotConverged` when the underlying SVD fails to converge or
        /// `error.RankDeficient` when the correspondences are degenerate.
        pub fn init(from_points: []const Point(2, T), to_points: []const Point(2, T)) !Self {
            var transform: ProjectiveTransform(T) = .identity;
            try transform.find(from_points, to_points);
            return transform;
        }

        /// Returns a new `ProjectiveTransform` with its internal matrix converted to the
        /// specified scalar type `U`.
        pub fn as(self: Self, comptime U: type) ProjectiveTransform(U) {
            return .{
                .matrix = self.matrix.as(U),
            };
        }

        /// Projects the given point using the projective transform
        pub fn project(self: Self, point: Point(2, T)) Point(2, T) {
            const src: SMatrix(T, 3, 1) = .init(.{ .{point.x()}, .{point.y()}, .{1} });
            var dst = self.matrix.dot(src);
            if (dst.at(2, 0).* != 0) {
                dst = dst.scale(1 / dst.at(2, 0).*);
            }
            return dst.toPoint(2);
        }

        /// Returns the inverse of the current projective transform.
        pub fn inverse(self: Self) ?Self {
            return if (self.matrix.inverse()) |inv| .{ .matrix = inv } else null;
        }

        /// Finds the best projective transform that maps between the two given sets of points.
        /// Returns `error.NotConverged` when the SVD fails to converge or `error.RankDeficient`
        /// when the system does not have enough rank to define a projective transform.
        pub fn find(self: *Self, from_points: []const Point(2, T), to_points: []const Point(2, T)) !void {
            assert(from_points.len >= 4);
            assert(from_points.len == to_points.len);
            if (!geom_utils.hasNonCollinearTriplet(T, from_points) or !geom_utils.hasNonCollinearTriplet(T, to_points)) {
                return error.RankDeficient;
            }
            var accum: SMatrix(T, 9, 9) = .initAll(0);
            var b: SMatrix(T, 2, 9) = .initAll(0);
            for (0..from_points.len) |i| {
                const f: SMatrix(T, 1, 3) = .init(.{.{ from_points[i].x(), from_points[i].y(), 1 }});
                const t: SMatrix(T, 1, 3) = .init(.{.{ to_points[i].x(), to_points[i].y(), 1 }});
                b.setSubMatrix(0, 0, f.scale(t.at(0, 1).*));
                b.setSubMatrix(1, 0, f);
                b.setSubMatrix(0, 3, f.scale(-t.at(0, 0).*));
                b.setSubMatrix(1, 6, f.scale(-t.at(0, 0).*));
                accum = accum.add(b.transpose().dot(b));
            }
            const result = accum.svd(.{ .with_u = true, .with_v = false, .mode = .full_u });
            if (result.converged != 0) {
                return error.NotConverged;
            }
            const u = &result.u;
            const s = &result.s;
            self.matrix = blk: {
                var min: T = s.at(0, 0).*;
                var idx: usize = 0;
                for (1..s.rows) |i| {
                    const val = s.at(i, 0).*;
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

test "similarity transform rejects rank deficient input" {
    const T = f64;
    const from_points: []const Point(2, T) = &.{
        Point(2, T).init(.{ 0, 0 }),
        Point(2, T).init(.{ 0, 0 }),
    };
    const to_points: []const Point(2, T) = &.{
        Point(2, T).init(.{ 1, 1 }),
        Point(2, T).init(.{ 1, 1 }),
    };
    try std.testing.expectError(error.RankDeficient, SimilarityTransform(T).init(from_points, to_points));
}

test "affine transform rejects rank deficient input" {
    const T = f64;
    const from_points: []const Point(2, T) = &.{
        .init(.{ 0, 0 }),
        .init(.{ 1, 0 }),
        .init(.{ 2, 0 }),
    };
    const to_points: []const Point(2, T) = &.{
        .init(.{ 0, 0 }),
        .init(.{ 1, 0 }),
        .init(.{ 2, 0 }),
    };
    try std.testing.expectError(error.RankDeficient, AffineTransform(T).init(std.testing.allocator, from_points, to_points));
}

test "projective transform rejects rank deficient input" {
    const T = f64;
    const from_points: []const Point(2, T) = &.{
        .init(.{ 0, 0 }),
        .init(.{ 1, 0 }),
        .init(.{ 2, 0 }),
        .init(.{ 3, 0 }),
    };
    const to_points: []const Point(2, T) = &.{
        .init(.{ 0, 0 }),
        .init(.{ 1, 0 }),
        .init(.{ 2, 0 }),
        .init(.{ 3, 0 }),
    };
    try std.testing.expectError(error.RankDeficient, ProjectiveTransform(T).init(from_points, to_points));
}

test "affine3" {
    const T = f64;
    const from_points: []const Point(2, T) = &.{
        .init(.{ 0, 0 }),
        .init(.{ 0, 1 }),
        .init(.{ 1, 1 }),
    };
    const to_points: []const Point(2, T) = &.{
        .init(.{ 0, 1 }),
        .init(.{ 1, 1 }),
        .init(.{ 1, 0 }),
    };
    const tf = try AffineTransform(f64).init(std.testing.allocator, from_points[0..3], to_points[0..3]);
    const matrix: SMatrix(T, 2, 2) = .init(.{ .{ 0, 1 }, .{ -1, 0 } });
    const bias: SMatrix(T, 2, 1) = .init(.{ .{0}, .{1} });
    for (0..matrix.rows) |r| {
        for (0..matrix.cols) |c| {
            try std.testing.expectApproxEqAbs(matrix.at(r, c).*, tf.matrix.at(r, c).*, 1e-9);
        }
    }
    for (0..bias.rows) |r| {
        try std.testing.expectApproxEqAbs(bias.at(r, 0).*, tf.bias.at(r, 0).*, 1e-9);
    }

    const itf = try AffineTransform(f64).init(std.testing.allocator, to_points[0..3], from_points[0..3]);
    for (from_points, to_points) |f, t| {
        const forward = tf.project(f);
        try std.testing.expectApproxEqAbs(forward.x(), t.x(), 1e-9);
        try std.testing.expectApproxEqAbs(forward.y(), t.y(), 1e-9);
        const back = itf.project(t);
        try std.testing.expectApproxEqAbs(back.x(), f.x(), 1e-9);
        try std.testing.expectApproxEqAbs(back.y(), f.y(), 1e-9);
    }
}

test "affine with additional correspondences" {
    const T = f64;
    const from_points: []const Point(2, T) = &.{
        .init(.{ 0, 0 }),
        .init(.{ 0, 1 }),
        .init(.{ 1, 1 }),
        .init(.{ 1, 0 }),
    };
    const to_points: []const Point(2, T) = &.{
        .init(.{ 0, 1 }),
        .init(.{ 1, 1 }),
        .init(.{ 1, 0 }),
        .init(.{ 0, 0 }),
    };
    const tf = try AffineTransform(f64).init(std.testing.allocator, from_points, to_points);
    const matrix: SMatrix(T, 2, 2) = .init(.{ .{ 0, 1 }, .{ -1, 0 } });
    const bias: SMatrix(T, 2, 1) = .init(.{ .{0}, .{1} });
    for (0..matrix.rows) |r| {
        for (0..matrix.cols) |c| {
            try std.testing.expectApproxEqAbs(matrix.at(r, c).*, tf.matrix.at(r, c).*, 1e-9);
        }
    }
    for (0..bias.rows) |r| {
        try std.testing.expectApproxEqAbs(bias.at(r, 0).*, tf.bias.at(r, 0).*, 1e-9);
    }

    for (from_points, to_points) |f, t| {
        const projected = tf.project(f);
        try std.testing.expectApproxEqAbs(projected.x(), t.x(), 1e-9);
        try std.testing.expectApproxEqAbs(projected.y(), t.y(), 1e-9);
    }
}

test "projection4" {
    const T = f64;
    const tol = 1e-5;
    const from_points: []const Point(2, T) = &.{
        .init(.{ 199.67754364, 200.17905235 }),
        .init(.{ 167.90229797, 175.55920601 }),
        .init(.{ 270.33649445, 207.96521187 }),
        .init(.{ 267.53637314, 188.24442387 }),
    };
    const to_points: []const Point(2, T) = &.{
        .init(.{ 440.68012238, 275.45248032 }),
        .init(.{ 429.62512970, 262.64307976 }),
        .init(.{ 484.23328400, 279.44332123 }),
        .init(.{ 488.08315277, 272.79547691 }),
    };
    const transform: ProjectiveTransform(T) = try .init(from_points, to_points);
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
        try std.testing.expectApproxEqRel(p.x(), t.x(), tol);
        try std.testing.expectApproxEqRel(p.y(), t.y(), tol);
    }

    const m_inv = transform.inverse().?;
    const t_inv: ProjectiveTransform(T) = try .init(to_points, from_points);
    for (from_points) |f| {
        var fp = t_inv.project(transform.project(f));
        try std.testing.expectApproxEqRel(f.x(), fp.x(), tol);
        try std.testing.expectApproxEqRel(f.y(), fp.y(), tol);

        fp = m_inv.project(transform.project(f));
        try std.testing.expectApproxEqRel(f.x(), fp.x(), tol);
        try std.testing.expectApproxEqRel(f.y(), fp.y(), tol);
    }
}

test "projection8" {
    const T = f64;
    const from_points: []const Point(2, T) = &.{
        .init(.{ 319.48406982, 240.21486282 }),
        .init(.{ 268.64367676, 210.67104721 }),
        .init(.{ 432.53839111, 249.55825424 }),
        .init(.{ 428.05819702, 225.89330864 }),
        .init(.{ 687.00787354, 240.97020721 }),
        .init(.{ 738.32287598, 208.32876205 }),
        .init(.{ 574.62890625, 250.60971451 }),
        .init(.{ 579.63378906, 225.37580109 }),
    };

    const to_points: []const Point(2, T) = &.{
        .init(.{ 330.48120117, 408.22596359 }),
        .init(.{ 317.55538940, 393.26282501 }),
        .init(.{ 356.74267578, 411.06428146 }),
        .init(.{ 349.94784546, 400.26379395 }),
        .init(.{ 438.15582275, 411.75442886 }),
        .init(.{ 452.01367188, 398.08815765 }),
        .init(.{ 398.66107178, 413.83139420 }),
        .init(.{ 395.29974365, 401.73685455 }),
    };
    const transform: ProjectiveTransform(T) = try .init(from_points, to_points);
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
        try std.testing.expectApproxEqRel(p.x(), to_points[i].x(), 1e-2);
        try std.testing.expectApproxEqRel(p.y(), to_points[i].y(), 1e-2);
    }
}
