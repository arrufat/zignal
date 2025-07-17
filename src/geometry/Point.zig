const std = @import("std");
const assert = std.debug.assert;

/// A unified point type supporting arbitrary dimensions with SIMD acceleration.
/// Common dimensions 2D, 3D, 4D have convenient x(), y(), z(), w() accessors.
/// Higher dimensions use at(index) for access.
pub fn Point(comptime T: type, comptime dim: usize) type {
    assert(@typeInfo(T) == .float);
    comptime assert(dim >= 1);

    return struct {
        const Self = @This();
        vec: @Vector(dim, T),

        // Constants
        pub const origin = Self{ .vec = @splat(0) };
        pub const dimension = dim;

        // Common accessors (with compile-time bounds checking)
        /// Get X coordinate (first component)
        pub inline fn x(self: Self) T {
            comptime assert(dim >= 1);
            return self.vec[0];
        }

        /// Get Y coordinate (second component)
        pub inline fn y(self: Self) T {
            comptime assert(dim >= 2);
            return self.vec[1];
        }

        /// Get Z coordinate (third component)
        pub inline fn z(self: Self) T {
            comptime assert(dim >= 3);
            return self.vec[2];
        }

        /// Get W coordinate (fourth component)
        pub inline fn w(self: Self) T {
            comptime assert(dim >= 4);
            return self.vec[3];
        }

        // Generic indexed access for higher dimensions
        /// Get component at specified index (for dimensions > 4)
        pub inline fn at(self: Self, index: usize) T {
            assert(index < dim);
            return self.vec[index];
        }

        // Construction methods for common cases
        /// Create 1D point from X coordinate
        pub inline fn init1d(x_val: T) Self {
            comptime assert(dim == 1);
            return .{ .vec = .{x_val} };
        }

        /// Create 2D point from X, Y coordinates
        pub inline fn init2d(x_val: T, y_val: T) Self {
            comptime assert(dim == 2);
            return .{ .vec = .{ x_val, y_val } };
        }

        /// Create 3D point from X, Y, Z coordinates
        pub inline fn init3d(x_val: T, y_val: T, z_val: T) Self {
            comptime assert(dim == 3);
            return .{ .vec = .{ x_val, y_val, z_val } };
        }

        /// Create 4D point from X, Y, Z, W coordinates
        pub inline fn init4d(x_val: T, y_val: T, z_val: T, w_val: T) Self {
            comptime assert(dim == 4);
            return .{ .vec = .{ x_val, y_val, z_val, w_val } };
        }

        // Generic construction from array/vector (for any dimension)
        /// Create point from array of components
        pub inline fn init(components: [dim]T) Self {
            return .{ .vec = components };
        }

        /// Create point from SIMD vector
        pub inline fn fromVector(vec: @Vector(dim, T)) Self {
            return .{ .vec = vec };
        }

        /// Create point from slice of components
        pub inline fn fromSlice(components: []const T) Self {
            assert(components.len == dim);
            var result: [dim]T = undefined;
            @memcpy(&result, components[0..dim]);
            return .{ .vec = result };
        }

        // All vector operations work for any dimension (SIMD-accelerated)
        /// Add two points component-wise
        pub fn add(self: Self, other: Self) Self {
            return .{ .vec = self.vec + other.vec };
        }

        /// Subtract two points component-wise
        pub fn sub(self: Self, other: Self) Self {
            return .{ .vec = self.vec - other.vec };
        }

        /// Scale all components by same scalar value
        pub fn scale(self: Self, scalar: T) Self {
            return .{ .vec = self.vec * @as(@Vector(dim, T), @splat(scalar)) };
        }

        /// Scale each component by different values
        pub fn scaleEach(self: Self, scales: [dim]T) Self {
            return .{ .vec = self.vec * @as(@Vector(dim, T), scales) };
        }

        /// Compute dot product with another point
        pub fn dot(self: Self, other: Self) T {
            return @reduce(.Add, self.vec * other.vec);
        }

        /// Compute Euclidean norm (length) of the point
        pub fn norm(self: Self) T {
            return @sqrt(self.dot(self));
        }

        /// Compute squared norm (avoids sqrt for performance)
        pub fn normSquared(self: Self) T {
            return self.dot(self);
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
        pub fn project(self: Self, comptime new_dim: usize) Point(T, new_dim) {
            comptime assert(new_dim <= dim);
            var result: [new_dim]T = undefined;
            inline for (0..new_dim) |i| {
                result[i] = self.vec[i];
            }
            return Point(T, new_dim).init(result);
        }

        /// Extend to higher dimension by padding with fill_value
        pub fn extend(self: Self, comptime new_dim: usize, fill_value: T) Point(T, new_dim) {
            comptime assert(new_dim >= dim);
            var result: [new_dim]T = undefined;
            inline for (0..dim) |i| {
                result[i] = self.vec[i];
            }
            inline for (dim..new_dim) |i| {
                result[i] = fill_value;
            }
            return Point(T, new_dim).init(result);
        }

        // Convenient aliases for common projections
        /// Project to 2D by taking first 2 components
        pub fn to2d(self: Self) Point(T, 2) {
            return self.project(2);
        }

        /// Project to 3D by taking first 3 components
        pub fn to3d(self: Self) Point(T, 3) {
            comptime assert(dim >= 3);
            return self.project(3);
        }

        /// Convert 2D point to 3D by adding Z coordinate
        pub fn extendTo3d(self: Self, z_val: T) Point(T, 3) {
            comptime assert(dim == 2);
            return self.extend(3, z_val);
        }

        // Special methods for common dimensions
        /// Rotate 2D point around center by given angle (radians)
        pub fn rotate(self: Self, angle: T, center: Self) Self {
            comptime assert(dim == 2);
            const cos_a = @cos(angle);
            const sin_a = @sin(angle);
            const centered = self.sub(center);
            return Point(T, 2).init2d(cos_a * centered.x() - sin_a * centered.y(), sin_a * centered.x() + cos_a * centered.y()).add(center);
        }

        /// Compute 3D cross product with another point
        pub fn cross(self: Self, other: Self) Self {
            comptime assert(dim == 3);
            return Point(T, 3).init3d(self.y() * other.z() - self.z() * other.y(), self.z() * other.x() - self.x() * other.z(), self.x() * other.y() - self.y() * other.x());
        }

        // Direct vector/array access
        /// Get underlying SIMD vector
        pub fn asVector(self: Self) @Vector(dim, T) {
            return self.vec;
        }

        /// Convert to array of components
        pub fn asArray(self: Self) [dim]T {
            return self.vec;
        }

        /// Get read-only slice view of components
        pub fn asSlice(self: *const Self) []const T {
            return &self.vec;
        }

        // Type conversion
        /// Convert to point with different scalar type
        pub fn as(self: Self, comptime U: type) Point(U, dim) {
            var result: @Vector(dim, U) = undefined;
            inline for (0..dim) |i| {
                result[i] = @floatCast(self.vec[i]);
            }
            return Point(U, dim){ .vec = result };
        }

        // Homogeneous coordinate conversion for 3D points
        /// Convert 3D homogeneous point to 2D by dividing by Z
        pub fn to2dHomogeneous(self: Self) Point(T, 2) {
            comptime assert(dim == 3);
            if (self.z() == 0) {
                return self.to2d();
            } else {
                return Point(T, 2).init2d(self.x() / self.z(), self.y() / self.z());
            }
        }
    };
}

// Common type aliases for convenience
/// 1D point type alias
pub fn Point1d(comptime T: type) type {
    return Point(T, 1);
}

/// 2D point type alias
pub fn Point2d(comptime T: type) type {
    return Point(T, 2);
}

/// 3D point type alias
pub fn Point3d(comptime T: type) type {
    return Point(T, 3);
}

/// 4D point type alias
pub fn Point4d(comptime T: type) type {
    return Point(T, 4);
}

/// Helper for creating points from variadic arguments
/// Example: makePoint(.{1.0, 2.0, 3.0}) creates a 3D point
pub fn makePoint(args: anytype) Point(@TypeOf(args[0]), args.len) {
    const T = @TypeOf(args[0]);
    const dim = args.len;
    var components: [dim]T = undefined;
    inline for (args, 0..) |arg, i| {
        components[i] = arg;
    }
    return Point(T, dim).init(components);
}

// Tests
test "Point creation and accessors" {
    const Point2 = Point(f64, 2);
    const Point3 = Point(f64, 3);
    const Point5 = Point(f64, 5);

    // Test 2D point
    const p2 = Point2.init2d(1.0, 2.0);
    try std.testing.expectEqual(@as(f64, 1.0), p2.x());
    try std.testing.expectEqual(@as(f64, 2.0), p2.y());

    // Test 3D point
    const p3 = Point3.init3d(1.0, 2.0, 3.0);
    try std.testing.expectEqual(@as(f64, 1.0), p3.x());
    try std.testing.expectEqual(@as(f64, 2.0), p3.y());
    try std.testing.expectEqual(@as(f64, 3.0), p3.z());

    // Test high-dimensional point
    const p5 = Point5.init([_]f64{ 1, 2, 3, 4, 5 });
    try std.testing.expectEqual(@as(f64, 1.0), p5.x());
    try std.testing.expectEqual(@as(f64, 2.0), p5.y());
    try std.testing.expectEqual(@as(f64, 3.0), p5.z());
    try std.testing.expectEqual(@as(f64, 4.0), p5.w());
    try std.testing.expectEqual(@as(f64, 5.0), p5.at(4));
}

test "Point arithmetic operations" {
    const Point2 = Point(f64, 2);

    const p1 = Point2.init2d(1.0, 2.0);
    const p2 = Point2.init2d(3.0, 4.0);

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
    const norm = Point2.init2d(3.0, 4.0).norm();
    try std.testing.expectEqual(@as(f64, 5.0), norm); // 3-4-5 triangle
}

test "Point dimension conversion" {
    const Point2 = Point(f64, 2);

    const p2 = Point2.init2d(1.0, 2.0);
    const p3 = p2.extendTo3d(3.0);

    try std.testing.expectEqual(@as(f64, 1.0), p3.x());
    try std.testing.expectEqual(@as(f64, 2.0), p3.y());
    try std.testing.expectEqual(@as(f64, 3.0), p3.z());

    const back_to_2d = p3.to2d();
    try std.testing.expectEqual(@as(f64, 1.0), back_to_2d.x());
    try std.testing.expectEqual(@as(f64, 2.0), back_to_2d.y());
}

test "Point helper function" {
    const p = makePoint(.{ @as(f64, 1.0), @as(f64, 2.0), @as(f64, 3.0) });
    try std.testing.expectEqual(@as(usize, 3), @TypeOf(p).dimension);
    try std.testing.expectEqual(@as(f64, 1.0), p.x());
    try std.testing.expectEqual(@as(f64, 2.0), p.y());
    try std.testing.expectEqual(@as(f64, 3.0), p.z());
}

test "3D cross product" {
    const Point3 = Point(f64, 3);

    const i = Point3.init3d(1.0, 0.0, 0.0);
    const j = Point3.init3d(0.0, 1.0, 0.0);
    const k = i.cross(j);

    try std.testing.expectEqual(@as(f64, 0.0), k.x());
    try std.testing.expectEqual(@as(f64, 0.0), k.y());
    try std.testing.expectEqual(@as(f64, 1.0), k.z());
}
