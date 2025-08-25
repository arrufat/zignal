const std = @import("std");
const assert = std.debug.assert;

const isColor = @import("../color.zig").isColor;

/// A unified point type supporting arbitrary dimensions with SIMD acceleration.
/// Common dimensions 2D, 3D, 4D have convenient x(), y(), z(), w() accessors.
/// Higher dimensions use at(index) for access.
pub fn Point(comptime dim: usize, comptime T: type) type {
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

        // Construction methods
        /// Create point from tuple literal
        /// Example: .point(.{1, 2})
        pub inline fn point(components: anytype) Self {
            const info = @typeInfo(@TypeOf(components));
            comptime assert(info == .@"struct");
            comptime assert(info.@"struct".fields.len == dim);

            var vec: @Vector(dim, T) = undefined;
            inline for (info.@"struct".fields, 0..) |_, i| {
                vec[i] = @as(T, components[i]);
            }
            return .{ .vec = vec };
        }

        /// Create point from array of components
        pub inline fn fromArray(components: [dim]T) Self {
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
        pub fn project(self: Self, comptime new_dim: usize) Point(new_dim, T) {
            comptime assert(new_dim <= dim);
            var result: [new_dim]T = undefined;
            inline for (0..new_dim) |i| {
                result[i] = self.vec[i];
            }
            return Point(new_dim, T).fromArray(result);
        }

        /// Extend to higher dimension by padding with fill_value
        pub fn extend(self: Self, comptime new_dim: usize, fill_value: T) Point(new_dim, T) {
            comptime assert(new_dim >= dim);
            var result: [new_dim]T = undefined;
            inline for (0..dim) |i| {
                result[i] = self.vec[i];
            }
            inline for (dim..new_dim) |i| {
                result[i] = fill_value;
            }
            return Point(new_dim, T).fromArray(result);
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
            comptime assert(dim == 2);
            const cos_a = @cos(angle);
            const sin_a = @sin(angle);
            const centered = self.sub(center);
            return .point(.{ cos_a * centered.x() - sin_a * centered.y(), sin_a * centered.x() + cos_a * centered.y() }).add(center);
        }

        /// Compute 3D cross product with another point
        pub fn cross(self: Self, other: Self) Self {
            comptime assert(dim == 3);
            return .point(.{
                self.y() * other.z() - self.z() * other.y(),
                self.z() * other.x() - self.x() * other.z(),
                self.x() * other.y() - self.y() * other.x(),
            });
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
        pub fn as(self: Self, comptime U: type) Point(dim, U) {
            var result: @Vector(dim, U) = undefined;
            inline for (0..dim) |i| {
                result[i] = @floatCast(self.vec[i]);
            }
            return Point(dim, U){ .vec = result };
        }

        // Color conversion methods
        /// Create a Point from any color type using reflection.
        /// Works with any color type recognized by isColor.
        /// The number of fields must match the Point dimension.
        pub fn fromColor(color: anytype) Self {
            const ColorType = @TypeOf(color);
            comptime assert(isColor(ColorType));

            const fields = std.meta.fields(ColorType);
            comptime assert(fields.len == dim);

            var vec: @Vector(dim, T) = undefined;
            inline for (fields, 0..) |field, i| {
                const value = @field(color, field.name);
                const field_type = @TypeOf(value);

                // Convert to T based on field type
                vec[i] = switch (@typeInfo(field_type)) {
                    .int => blk: {
                        // Assume u8 values are 0-255, normalize to 0-1 for float Points
                        if (@typeInfo(T) == .float) {
                            break :blk @as(T, @floatFromInt(value)) / 255.0;
                        } else {
                            break :blk @as(T, @intCast(value));
                        }
                    },
                    .float => blk: {
                        if (@typeInfo(T) == .float) {
                            break :blk @as(T, @floatCast(value));
                        } else {
                            // Convert float to int by scaling and rounding
                            break :blk @as(T, @intFromFloat(@round(value * 255.0)));
                        }
                    },
                    else => @compileError("Unsupported color field type: " ++ @typeName(field_type)),
                };
            }

            return .{ .vec = vec };
        }

        /// Convert this Point to any color type using reflection.
        /// Works with any struct with numeric fields (u8, f32, etc.).
        /// The number of fields must match the Point dimension.
        pub fn toColor(self: Self, comptime ColorType: type) ColorType {
            const fields = std.meta.fields(ColorType);
            comptime assert(fields.len == dim);

            var color: ColorType = undefined;
            inline for (fields, 0..) |field, i| {
                const field_type = field.type;
                const value = self.vec[i];

                // Convert from T based on field type
                @field(color, field.name) = switch (@typeInfo(field_type)) {
                    .int => blk: {
                        if (@typeInfo(T) == .float) {
                            // Assume we're converting from normalized 0-1 to 0-255
                            const clamped = std.math.clamp(value, 0, 1);
                            break :blk @as(field_type, @intFromFloat(@round(clamped * 255.0)));
                        } else {
                            break :blk @as(field_type, @intCast(std.math.clamp(value, 0, 255)));
                        }
                    },
                    .float => blk: {
                        if (@typeInfo(T) == .float) {
                            break :blk @as(field_type, @floatCast(value));
                        } else {
                            // Convert int to normalized float
                            const float_val: field_type = @as(field_type, @floatFromInt(value)) / 255.0;
                            break :blk float_val;
                        }
                    },
                    else => @compileError("Unsupported color field type: " ++ @typeName(field_type)),
                };
            }

            return color;
        }

        // Homogeneous coordinate conversion for 3D points
        /// Convert 3D homogeneous point to 2D by dividing by Z
        pub fn to2dHomogeneous(self: Self) Point(2, T) {
            comptime assert(dim == 3);
            if (self.z() == 0) {
                return self.to2d();
            } else {
                return .point(.{ self.x() / self.z(), self.y() / self.z() });
            }
        }
    };
}

// Tests
test "Point creation and accessors" {
    const Point2 = Point(2, f64);
    const Point3 = Point(3, f64);
    const Point5 = Point(5, f64);

    // Test 2D point
    const p2 = Point2.point(.{ 1.0, 2.0 });
    try std.testing.expectEqual(@as(f64, 1.0), p2.x());
    try std.testing.expectEqual(@as(f64, 2.0), p2.y());

    // Test 3D point
    const p3 = Point3.point(.{ 1.0, 2.0, 3.0 });
    try std.testing.expectEqual(@as(f64, 1.0), p3.x());
    try std.testing.expectEqual(@as(f64, 2.0), p3.y());
    try std.testing.expectEqual(@as(f64, 3.0), p3.z());

    // Test high-dimensional point
    const p5 = Point5.fromArray([_]f64{ 1, 2, 3, 4, 5 });
    try std.testing.expectEqual(@as(f64, 1.0), p5.x());
    try std.testing.expectEqual(@as(f64, 2.0), p5.y());
    try std.testing.expectEqual(@as(f64, 3.0), p5.z());
    try std.testing.expectEqual(@as(f64, 4.0), p5.w());
    try std.testing.expectEqual(@as(f64, 5.0), p5.at(4));
}

test "Point arithmetic operations" {
    const Point2 = Point(2, f64);

    const p1 = Point2.point(.{ 1.0, 2.0 });
    const p2 = Point2.point(.{ 3.0, 4.0 });

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
    const norm = Point2.point(.{ 3.0, 4.0 }).norm();
    try std.testing.expectEqual(@as(f64, 5.0), norm); // 3-4-5 triangle
}

test "Point dimension conversion" {
    const Point2 = Point(2, f64);

    const p2 = Point2.point(.{ 1.0, 2.0 });
    const p3 = p2.extendTo3d(3.0);

    try std.testing.expectEqual(@as(f64, 1.0), p3.x());
    try std.testing.expectEqual(@as(f64, 2.0), p3.y());
    try std.testing.expectEqual(@as(f64, 3.0), p3.z());

    const back_to_2d = p3.to2d();
    try std.testing.expectEqual(@as(f64, 1.0), back_to_2d.x());
    try std.testing.expectEqual(@as(f64, 2.0), back_to_2d.y());
}

test "Point creation with tuple" {
    const p = Point(3, f64).point(.{ 1.0, 2.0, 3.0 });
    try std.testing.expectEqual(@as(usize, 3), @TypeOf(p).dimension);
    try std.testing.expectEqual(@as(f64, 1.0), p.x());
    try std.testing.expectEqual(@as(f64, 2.0), p.y());
    try std.testing.expectEqual(@as(f64, 3.0), p.z());
}

test "3D cross product" {
    const Point3 = Point(3, f64);

    const i = Point3.point(.{ 1.0, 0.0, 0.0 });
    const j = Point3.point(.{ 0.0, 1.0, 0.0 });
    const k = i.cross(j);

    try std.testing.expectEqual(@as(f64, 0.0), k.x());
    try std.testing.expectEqual(@as(f64, 0.0), k.y());
    try std.testing.expectEqual(@as(f64, 1.0), k.z());
}

test "Point color conversion" {
    // Import color types for testing
    const Rgb = @import("../color.zig").Rgb;
    const Rgba = @import("../color.zig").Rgba;

    // Test RGB to Point conversion (float point)
    const rgb_color = Rgb{ .r = 255, .g = 128, .b = 0 };
    const point_from_rgb = Point(3, f64).fromColor(rgb_color);

    try std.testing.expectApproxEqAbs(@as(f64, 1.0), point_from_rgb.x(), 0.01); // R normalized
    try std.testing.expectApproxEqAbs(@as(f64, 128.0 / 255.0), point_from_rgb.y(), 0.01); // G normalized
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), point_from_rgb.z(), 0.01); // B normalized

    // Test Point to RGB conversion
    const recovered_rgb = point_from_rgb.toColor(Rgb);
    try std.testing.expectEqual(rgb_color.r, recovered_rgb.r);
    try std.testing.expectEqual(rgb_color.g, recovered_rgb.g);
    try std.testing.expectEqual(rgb_color.b, recovered_rgb.b);

    // Test RGBA to Point conversion (4D)
    const rgba_color = Rgba{ .r = 255, .g = 0, .b = 0, .a = 128 };
    const point_from_rgba = Point(4, f64).fromColor(rgba_color);

    try std.testing.expectApproxEqAbs(@as(f64, 1.0), point_from_rgba.x(), 0.01); // R
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), point_from_rgba.y(), 0.01); // G
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), point_from_rgba.z(), 0.01); // B
    try std.testing.expectApproxEqAbs(@as(f64, 128.0 / 255.0), point_from_rgba.w(), 0.01); // A

    const recovered_rgba = point_from_rgba.toColor(Rgba);
    try std.testing.expectEqual(rgba_color.r, recovered_rgba.r);
    try std.testing.expectEqual(rgba_color.g, recovered_rgba.g);
    try std.testing.expectEqual(rgba_color.b, recovered_rgba.b);
    try std.testing.expectEqual(rgba_color.a, recovered_rgba.a);
}
