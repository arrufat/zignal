const std = @import("std");
const assert = std.debug.assert;
const meta = @import("../meta.zig");

/// A unified point type supporting arbitrary dimensions with SIMD acceleration.
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
                        comptime assert(s.fields.len == dim);
                        var items: @Vector(dim, T) = undefined;
                        inline for (s.fields, 0..) |_, i| {
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
                        var result: [dim]T = undefined;
                        @memcpy(&result, components[0..dim]);
                        break :blk .{ .items = result };
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
            return @sqrt(self.dot(self));
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
            var result: @Vector(dim, T) = undefined;
            inline for (0..dim) |i| {
                result[i] = std.math.lerp(self.items[i], other.items[i], t);
            }
            return .{ .items = result };
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
            return self.max(min_point).min(max_point);
        }

        /// Compute Euclidean distance to another point
        pub fn distance(self: Self, other: Self) T {
            return self.sub(other).norm();
        }

        /// Compute squared distance (avoids sqrt for performance)
        pub fn distanceSquared(self: Self, other: Self) T {
            return self.sub(other).normSquared();
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

        /// Compute 3D cross product with another point
        pub fn cross(self: Self, other: Self) Self {
            comptime assert(dim == 3);
            return .init(.{
                self.y() * other.z() - self.z() * other.y(),
                self.z() * other.x() - self.x() * other.z(),
                self.x() * other.y() - self.y() * other.x(),
            });
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

        // Type conversion
        /// Convert to point with different scalar type
        pub fn as(self: Self, comptime U: type) Point(dim, U) {
            var result: @Vector(dim, U) = undefined;
            inline for (0..dim) |i| {
                result[i] = meta.as(U, self.items[i]);
            }
            return Point(dim, U){ .items = result };
        }

        // Homogeneous coordinate conversion for 3D points
        /// Convert 3D homogeneous point to 2D by dividing by Z
        pub fn to2dHomogeneous(self: Self) Point(2, T) {
            comptime assert(dim == 3);
            if (self.z() == 0) {
                return self.to2d();
            } else {
                return .init(.{ self.x() / self.z(), self.y() / self.z() });
            }
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
    const Point2i = Point(2, i32);
    const Point3i = Point(3, i32);

    const p2: Point2i = .init(.{ 10, 20 });
    try std.testing.expectEqual(@as(i32, 10), p2.x());
    try std.testing.expectEqual(@as(i32, 20), p2.y());

    const p3: Point3i = .init(.{ 1, 2, 3 });
    const sum = p3.add(Point3i.init(.{ 10, 20, 30 }));
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
