const std = @import("std");
const assert = std.debug.assert;
const meta = @import("../meta.zig");

/// Possible orientations of a triplet of 2D points.
pub const Orientation = enum {
    collinear,
    clockwise,
    counter_clockwise,
};

/// A unified point type supporting arbitrary dimensions.
/// Common dimensions 2D, 3D, 4D have convenient x(), y(), z(), w() accessors.
/// Direct access to components via .items[index].
pub fn Point(comptime dim: usize, comptime T: type) type {
    const type_info = @typeInfo(T);
    comptime assert(type_info == .float or type_info == .int);
    comptime assert(dim >= 1);

    return struct {
        const Self = @This();
        items: @Vector(dim, T),

        // Constants
        pub const origin = Self{ .items = @splat(0) };
        pub const dimension = dim;

        // Common accessors (with compile-time bounds checking)
        /// Get X coordinate (first component)
        pub inline fn x(self: Self) T {
            comptime assert(dim >= 1);
            return self.items[0];
        }

        /// Get Y coordinate (second component)
        pub inline fn y(self: Self) T {
            comptime assert(dim >= 2);
            return self.items[1];
        }

        /// Get Z coordinate (third component)
        pub inline fn z(self: Self) T {
            comptime assert(dim >= 3);
            return self.items[2];
        }

        /// Get W coordinate (fourth component)
        pub inline fn w(self: Self) T {
            comptime assert(dim >= 4);
            return self.items[3];
        }

        // Construction methods
        /// Create point from various input types: tuple literals, arrays, slices, or vectors
        /// Examples:
        ///   Point(2, f32).init(.{1.0, 2.0})     // tuple literal
        ///   Point(2, f32).init([_]f32{1, 2})    // array
        ///   Point(2, f32).init(slice)           // slice
        pub inline fn init(components: anytype) Self {
            const ComponentsType = @TypeOf(components);
            const info = @typeInfo(ComponentsType);

            return switch (info) {
                .@"struct" => |s| blk: {
                    if (s.is_tuple) {
                        comptime assert(s.field_names.len == dim);
                        var items: @Vector(dim, T) = undefined;
                        inline for (s.field_names, 0..) |_, i| {
                            items[i] = @as(T, components[i]);
                        }
                        break :blk .{ .items = items };
                    } else {
                        @compileError("Point.init expects tuple literal, array, slice, or vector");
                    }
                },
                .array => |arr| blk: {
                    comptime assert(arr.len == dim);
                    break :blk .{ .items = components };
                },
                .pointer => |ptr| blk: {
                    if (ptr.size == .slice) {
                        assert(components.len == dim);
                        break :blk .{ .items = components[0..dim].* };
                    } else {
                        @compileError("Point.init expects tuple literal, array, slice, or vector");
                    }
                },
                .vector => |vec| blk: {
                    comptime assert(vec.len == dim);
                    break :blk .{ .items = components };
                },
                else => @compileError("Point.init expects tuple literal, array, slice, or vector"),
            };
        }

        // All vector operations work for any dimension (SIMD-accelerated)
        /// Add two points component-wise
        pub fn add(self: Self, other: Self) Self {
            return .{ .items = self.items + other.items };
        }

        /// Subtract two points component-wise
        pub fn sub(self: Self, other: Self) Self {
            return .{ .items = self.items - other.items };
        }

        /// Scale all components by same scalar value
        pub fn scale(self: Self, scalar: T) Self {
            return .{ .items = self.items * @as(@Vector(dim, T), @splat(scalar)) };
        }

        /// Scale each component by different values
        pub fn scaleEach(self: Self, scales: [dim]T) Self {
            return .{ .items = self.items * @as(@Vector(dim, T), scales) };
        }

        /// Compute dot product with another point
        pub fn dot(self: Self, other: Self) T {
            return @reduce(.Add, self.items * other.items);
        }

        /// Compute Euclidean norm (length) of the point
        pub fn norm(self: Self) T {
            comptime assert(@typeInfo(T) == .float);
            return @sqrt(self.normSquared());
        }

        /// Compute squared norm (avoids sqrt for performance)
        pub fn normSquared(self: Self) T {
            return self.dot(self);
        }

        /// Normalize to unit length (requires float type)
        pub fn normalize(self: Self) Self {
            comptime assert(@typeInfo(T) == .float);
            const n = self.norm();
            return if (n == 0) self else self.scale(1.0 / n);
        }

        /// Linear interpolation between two points
        pub fn lerp(self: Self, other: Self, t: T) Self {
            comptime assert(@typeInfo(T) == .float);
            return .{ .items = std.math.lerp(self.items, other.items, @as(@Vector(dim, T), @splat(t))) };
        }

        /// Component-wise minimum with another point
        pub fn min(self: Self, other: Self) Self {
            return .{ .items = @min(self.items, other.items) };
        }

        /// Component-wise maximum with another point
        pub fn max(self: Self, other: Self) Self {
            return .{ .items = @max(self.items, other.items) };
        }

        /// Clamp each component to the range [min_point, max_point]
        pub fn clamp(self: Self, min_point: Self, max_point: Self) Self {
            return .{ .items = std.math.clamp(self.items, min_point.items, max_point.items) };
        }

        /// Compute Euclidean distance to another point
        pub fn distance(self: Self, other: Self) T {
            comptime assert(@typeInfo(T) == .float);
            return self.sub(other).norm();
        }

        /// Compute squared distance (avoids sqrt for performance)
        pub fn distanceSquared(self: Self, other: Self) T {
            return self.sub(other).normSquared();
        }

        /// Computes the shortest distance from this point to the line segment defined by endpoints `a` and `b`.
        ///
        /// This function calculates the perpendicular distance if the projection of this point onto the line
        /// containing the segment falls within the segment's boundaries. If the projection falls
        /// outside, it returns the Euclidean distance to the nearest endpoint (`a` or `b`).
        pub fn distanceToSegment(self: Self, a: Self, b: Self) T {
            comptime assert(@typeInfo(T) == .float);
            const ab = b.sub(a);
            const ap = self.sub(a);

            const ab_len_sq = ab.normSquared();

            if (ab_len_sq == 0) {
                return ap.norm();
            }

            // Project AP onto AB to find the parameter t
            // t = (AP . AB) / |AB|^2
            const t = ap.dot(ab) / ab_len_sq;

            if (t <= 0.0) return ap.norm();
            if (t >= 1.0) return self.distance(b);
            return ap.distance(ab.scale(t));
        }

        /// Computes the orientation of this point relative to points `b` and `c`.
        /// Returns clockwise, counter-clockwise, or collinear.
        /// Only available for 2D points.
        pub fn orientation(self: Self, b: Self, c: Self) Orientation {
            comptime assert(dim == 2);
            // Lexicographically sort b and c to ensure the float math is computed in a
            // symmetric order. This guarantees that orientation(b, c) and orientation(c, b)
            // have consistent float roundoff behavior and correctly match collinearity.
            const swap = (b.x() > c.x()) or (b.x() == c.x() and b.y() > c.y());
            const p1 = if (swap) c else b;
            const p2 = if (swap) b else c;

            const u = self.x() * (p1.y() - p2.y()) + p1.x() * (p2.y() - self.y()) + p2.x() * (self.y() - p1.y());
            if (u == 0) return .collinear;
            // If we swapped the inputs, the computed sign of the orientation determinant (u > 0)
            // is inverted. Correct for this by checking if swap matches the sign of u.
            return if (swap == (u > 0)) .clockwise else .counter_clockwise;
        }

        /// Returns true if, and only if, this point is inside the triangle defined by vertices `a`, `b`, and `c`.
        /// Uses the barycentric coordinate method.
        /// Only available for 2D points.
        pub fn inTriangle(self: Self, a: Self, b: Self, c: Self) bool {
            comptime assert(dim == 2);
            const s = a.sub(c).cross(self.sub(c));
            const t = b.sub(a).cross(self.sub(a));
            const d = c.sub(b).cross(self.sub(b));

            const has_neg = (s < 0) or (t < 0) or (d < 0);
            const has_pos = (s > 0) or (t > 0) or (d > 0);
            return !(has_neg and has_pos);
        }

        /// Returns true when all points in the slice are collinear.
        /// Only available for 2D points.
        pub fn areAllCollinear(points: []const Self) bool {
            comptime assert(dim == 2);
            if (points.len < 3) return true;

            const p1 = points[0];
            var i: usize = 1;
            // Find the first point distinct from p1
            while (i < points.len) : (i += 1) {
                if (!points[i].eql(p1)) break;
            }

            // If all points are identical to p1, they are collinear
            if (i == points.len) return true;

            const p2 = points[i];
            // Check if all subsequent points are collinear with p1 and p2
            return for (points[i + 1 ..]) |p| {
                if (p1.orientation(p2, p) != .collinear) {
                    break false;
                }
            } else true;
        }

        // Dimension conversion/projection methods
        /// Project to lower dimension by taking first N components
        pub fn project(self: Self, comptime new_dim: usize) Point(new_dim, T) {
            comptime assert(new_dim <= dim);
            var result: [new_dim]T = undefined;
            inline for (0..new_dim) |i| {
                result[i] = self.items[i];
            }
            return .init(result);
        }

        /// Extend to higher dimension by padding with fill_value
        pub fn extend(self: Self, comptime new_dim: usize, fill_value: T) Point(new_dim, T) {
            comptime assert(new_dim >= dim);
            var result: [new_dim]T = undefined;
            inline for (0..dim) |i| {
                result[i] = self.items[i];
            }
            inline for (dim..new_dim) |i| {
                result[i] = fill_value;
            }
            return .init(result);
        }

        // Convenient aliases for common projections
        /// Project to 2D by taking first 2 components
        pub fn to2d(self: Self) Point(2, T) {
            comptime assert(dim >= 2);
            return self.project(2);
        }

        /// Project to 3D by taking first 3 components
        pub fn to3d(self: Self) Point(3, T) {
            comptime assert(dim >= 3);
            return self.project(3);
        }

        /// Convert 2D point to 3D by adding Z coordinate
        pub fn extendTo3d(self: Self, z_val: T) Point(3, T) {
            comptime assert(dim == 2);
            return self.extend(3, z_val);
        }

        // Special methods for common dimensions
        /// Rotate 2D point around center by given angle (radians)
        pub fn rotate(self: Self, angle: T, center: Self) Self {
            comptime assert(@typeInfo(T) == .float);
            comptime assert(dim == 2);
            const cos_a = @cos(angle);
            const sin_a = @sin(angle);
            const centered = self.sub(center);
            return .init(.{ cos_a * centered.x() - sin_a * centered.y(), sin_a * centered.x() + cos_a * centered.y() }).add(center);
        }

        /// Compute the cross product. For 3D, returns a new Point(3, T). For 2D, returns the scalar (wedge) product.
        pub fn cross(self: Self, other: Self) switch (dim) {
            2 => T,
            3 => Self,
            else => @compileError("Cross product is only defined for 2D and 3D points."),
        } {
            return switch (dim) {
                2 => self.x() * other.y() - self.y() * other.x(),
                3 => .init(.{
                    self.y() * other.z() - self.z() * other.y(),
                    self.z() * other.x() - self.x() * other.z(),
                    self.x() * other.y() - self.y() * other.x(),
                }),
                else => unreachable,
            };
        }

        // Direct vector/array access
        /// Get underlying SIMD vector
        pub fn asVector(self: Self) @Vector(dim, T) {
            return self.items;
        }

        /// Convert to array of components
        pub fn asArray(self: Self) [dim]T {
            return self.items;
        }

        /// Get read-only slice view of components
        pub fn asSlice(self: *const Self) []const T {
            return &self.items;
        }

        /// Returns true if all components of the two points are equal
        pub fn eql(self: Self, other: Self) bool {
            return @reduce(.And, self.items == other.items);
        }

        // Type conversion
        /// Convert to point with different scalar type
        pub fn as(self: Self, comptime U: type) Point(dim, U) {
            var result: @Vector(dim, U) = undefined;
            inline for (0..dim) |i| {
                result[i] = meta.as(U, self.items[i]);
            }
            return .{ .items = result };
        }

        // Homogeneous coordinate conversion for 3D points
        /// Convert 3D homogeneous point to 2D by dividing by Z
        pub fn to2dHomogeneous(self: Self) Point(2, T) {
            comptime assert(dim == 3);
            return if (self.z() == 0) self.to2d() else self.scale(1 / self.z()).to2d();
        }
    };
}

// Tests
test "Point creation and accessors" {
    const Point2 = Point(2, f64);
    const Point3 = Point(3, f64);
    const Point5 = Point(5, f64);

    // Test 2D point with tuple literal
    const p2: Point2 = .init(.{ 1.0, 2.0 });
    try std.testing.expectEqual(@as(f64, 1.0), p2.x());
    try std.testing.expectEqual(@as(f64, 2.0), p2.y());

    // Test 3D point with tuple literal
    const p3: Point3 = .init(.{ 1.0, 2.0, 3.0 });
    try std.testing.expectEqual(@as(f64, 1.0), p3.x());
    try std.testing.expectEqual(@as(f64, 2.0), p3.y());
    try std.testing.expectEqual(@as(f64, 3.0), p3.z());

    // Test high-dimensional point with array
    const p5: Point5 = .init([_]f64{ 1, 2, 3, 4, 5 });
    try std.testing.expectEqual(@as(f64, 1.0), p5.x());
    try std.testing.expectEqual(@as(f64, 2.0), p5.y());
    try std.testing.expectEqual(@as(f64, 3.0), p5.z());
    try std.testing.expectEqual(@as(f64, 4.0), p5.w());
    try std.testing.expectEqual(@as(f64, 5.0), p5.items[4]);

    // Test direct item access
    var p_mut: Point2 = .init(.{ 10.0, 20.0 });
    p_mut.items[0] = 15.0;
    try std.testing.expectEqual(@as(f64, 15.0), p_mut.x());
}

test "Point with integer types" {
    const p2: Point(2, i32) = .init(.{ 10, 20 });
    try std.testing.expectEqual(@as(i32, 10), p2.x());
    try std.testing.expectEqual(@as(i32, 20), p2.y());

    const p3: Point(3, i32) = .init(.{ 1, 2, 3 });
    const sum = p3.add(.init(.{ 10, 20, 30 }));
    try std.testing.expectEqual(@as(i32, 11), sum.x());
    try std.testing.expectEqual(@as(i32, 22), sum.y());
    try std.testing.expectEqual(@as(i32, 33), sum.z());
}

test "Point arithmetic operations" {
    const p1: Point(2, f64) = .init(.{ 1.0, 2.0 });
    const p2: Point(2, f64) = .init(.{ 3.0, 4.0 });

    // Addition
    const sum = p1.add(p2);
    try std.testing.expectEqual(@as(f64, 4.0), sum.x());
    try std.testing.expectEqual(@as(f64, 6.0), sum.y());

    // Subtraction
    const diff = p2.sub(p1);
    try std.testing.expectEqual(@as(f64, 2.0), diff.x());
    try std.testing.expectEqual(@as(f64, 2.0), diff.y());

    // Scaling
    const scaled = p1.scale(2.0);
    try std.testing.expectEqual(@as(f64, 2.0), scaled.x());
    try std.testing.expectEqual(@as(f64, 4.0), scaled.y());

    // Dot product
    const dot = p1.dot(p2);
    try std.testing.expectEqual(@as(f64, 11.0), dot); // 1*3 + 2*4 = 11

    // Norm
    const norm = Point(2, f64).init(.{ 3.0, 4.0 }).norm();
    try std.testing.expectEqual(@as(f64, 5.0), norm); // 3-4-5 triangle
}

test "Point advanced operations" {

    // Normalize
    const p: Point(2, f64) = .init(.{ 3.0, 4.0 });
    const normalized = p.normalize();
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), normalized.norm(), 0.0001);

    // Lerp
    const p1: Point(2, f64) = .init(.{ 0.0, 0.0 });
    const p2: Point(2, f64) = .init(.{ 10.0, 20.0 });
    const mid = p1.lerp(p2, 0.5);
    try std.testing.expectEqual(@as(f64, 5.0), mid.x());
    try std.testing.expectEqual(@as(f64, 10.0), mid.y());

    // Min/Max
    const a: Point(2, f64) = .init(.{ 1.0, 5.0 });
    const b: Point(2, f64) = .init(.{ 3.0, 2.0 });
    const min_result = a.min(b);
    const max_result = a.max(b);
    try std.testing.expectEqual(@as(f64, 1.0), min_result.x());
    try std.testing.expectEqual(@as(f64, 2.0), min_result.y());
    try std.testing.expectEqual(@as(f64, 3.0), max_result.x());
    try std.testing.expectEqual(@as(f64, 5.0), max_result.y());

    // Clamp
    const value: Point(2, f64) = .init(.{ -5.0, 15.0 });
    const min_bound: Point(2, f64) = .init(.{ 0.0, 0.0 });
    const max_bound: Point(2, f64) = .init(.{ 10.0, 10.0 });
    const clamped = value.clamp(min_bound, max_bound);
    try std.testing.expectEqual(@as(f64, 0.0), clamped.x());
    try std.testing.expectEqual(@as(f64, 10.0), clamped.y());
}

test "Point dimension conversion" {
    const p2: Point(2, f64) = .init(.{ 1.0, 2.0 });
    const p3 = p2.extendTo3d(3.0);

    try std.testing.expectEqual(@as(f64, 1.0), p3.x());
    try std.testing.expectEqual(@as(f64, 2.0), p3.y());
    try std.testing.expectEqual(@as(f64, 3.0), p3.z());

    const back_to_2d = p3.to2d();
    try std.testing.expectEqual(@as(f64, 1.0), back_to_2d.x());
    try std.testing.expectEqual(@as(f64, 2.0), back_to_2d.y());
}

test "Point creation with tuple" {
    const p: Point(3, f64) = .init(.{ 1.0, 2.0, 3.0 });
    try std.testing.expectEqual(@as(usize, 3), @TypeOf(p).dimension);
    try std.testing.expectEqual(@as(f64, 1.0), p.x());
    try std.testing.expectEqual(@as(f64, 2.0), p.y());
    try std.testing.expectEqual(@as(f64, 3.0), p.z());
}

test "3D cross product" {
    const i: Point(3, f64) = .init(.{ 1.0, 0.0, 0.0 });
    const j: Point(3, f64) = .init(.{ 0.0, 1.0, 0.0 });
    const k = i.cross(j);

    try std.testing.expectEqual(@as(f64, 0.0), k.x());
    try std.testing.expectEqual(@as(f64, 0.0), k.y());
    try std.testing.expectEqual(@as(f64, 1.0), k.z());
}

test "Point distanceToSegment" {
    const a: Point(2, f64) = .init(.{ 0.0, 0.0 });
    const b: Point(2, f64) = .init(.{ 10.0, 0.0 });

    // Point above the segment (perpendicular)
    const p1: Point(2, f64) = .init(.{ 5.0, 5.0 });
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), p1.distanceToSegment(a, b), 1e-9);

    // Point before the segment (closest to a)
    const p2: Point(2, f64) = .init(.{ -3.0, 4.0 });
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), p2.distanceToSegment(a, b), 1e-9);

    // Point after the segment (closest to b)
    const p3: Point(2, f64) = .init(.{ 13.0, 4.0 });
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), p3.distanceToSegment(a, b), 1e-9);

    // Point on the segment
    const p4: Point(2, f64) = .init(.{ 2.0, 0.0 });
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), p4.distanceToSegment(a, b), 1e-9);

    // Zero-length segment (a == b)
    const p5: Point(2, f64) = .init(.{ 3.0, 4.0 });
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), p5.distanceToSegment(a, a), 1e-9);
}

test "Point orientation" {
    const a: Point(2, f64) = .init(.{ 0.0, 0.0 });
    const b: Point(2, f64) = .init(.{ 1.0, 0.0 });
    const c: Point(2, f64) = .init(.{ 1.0, 1.0 });
    const d: Point(2, f64) = .init(.{ 0.5, 0.0 });

    try std.testing.expectEqual(Orientation.counter_clockwise, a.orientation(b, c));
    try std.testing.expectEqual(Orientation.clockwise, a.orientation(c, b));
    try std.testing.expectEqual(Orientation.collinear, a.orientation(b, d));
}

test "Point orientation precision" {
    // These three points can have different orientations due to floating point precision.
    // The robust check ensures they are consistently treated (e.g., as collinear).
    const a: Point(2, f32) = .init(.{ 4.9171928e-1, 6.473901e-1 });
    const b: Point(2, f32) = .init(.{ 3.6271343e-1, 9.712454e-1 });
    const c: Point(2, f32) = .init(.{ 3.9276862e-1, 8.9579517e-1 });

    const orientation_abc = a.orientation(b, c);
    const orientation_acb = a.orientation(c, b);

    try std.testing.expectEqual(orientation_abc, orientation_acb);
}

test "Point inTriangle" {
    const tri = [_]Point(2, f32){
        .init(.{ 0.0, 0.0 }),
        .init(.{ 2.0, 0.0 }),
        .init(.{ 1.0, 2.0 }),
    };
    var p: Point(2, f32) = .init(.{ 1.0, 1.0 });
    try std.testing.expect(p.inTriangle(tri[0], tri[1], tri[2]));

    p = .init(.{ 3.0, 1.0 });
    try std.testing.expect(!p.inTriangle(tri[0], tri[1], tri[2]));

    p = .init(.{ 1.0, 0.0 });
    try std.testing.expect(p.inTriangle(tri[0], tri[1], tri[2]));

    p = .init(.{ 0.0, 0.0 });
    try std.testing.expect(p.inTriangle(tri[0], tri[1], tri[2]));
}

test "Point areAllCollinear" {
    const P2 = Point(2, f32);
    const pts_collinear: []const P2 = &.{
        .init(.{ 0, 0 }),
        .init(.{ 1, 1 }),
        .init(.{ 2, 2 }),
        .init(.{ 3, 3 }),
    };
    try std.testing.expect(P2.areAllCollinear(pts_collinear));

    const pts_non_collinear: []const P2 = &.{
        .init(.{ 0, 0 }),
        .init(.{ 1, 0 }),
        .init(.{ 0, 1 }),
    };
    try std.testing.expect(!P2.areAllCollinear(pts_non_collinear));
}

test "2D cross product" {
    const i: Point(2, f64) = .init(.{ 1.0, 0.0 });
    const j: Point(2, f64) = .init(.{ 0.0, 1.0 });
    try std.testing.expectEqual(@as(f64, 1.0), i.cross(j));
    try std.testing.expectEqual(@as(f64, -1.0), j.cross(i));
}
