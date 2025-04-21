const std = @import("std");
const assert = std.debug.assert;

/// A simple 2D point with floating point coordinates.
pub fn Point2d(comptime T: type) type {
    assert(@typeInfo(T) == .float);
    return packed struct {
        x: T,
        y: T,

        /// Scales self x and y coordinates with x_scale and y_scale, respectively.
        pub fn scale(self: Point2d(T), x_scale: T, y_scale: T) Point2d(T) {
            return .{ .x = self.x * x_scale, .y = self.y * y_scale };
        }

        /// Adds self and other.
        pub fn add(self: Point2d(T), other: Point2d(T)) Point2d(T) {
            return .{ .x = self.x + other.x, .y = self.y + other.y };
        }

        /// Subtracts other from self.
        pub fn sub(self: Point2d(T), other: Point2d(T)) Point2d(T) {
            return .{ .x = self.x - other.x, .y = self.y - other.y };
        }

        /// Computes the norm of self.
        pub fn norm(self: Point2d(T)) T {
            return @sqrt(self.x * self.x + self.y * self.y);
        }

        /// Computes the squared distance between self and other, useful to avoid the call to sqrt.
        pub fn distanceSquared(self: Point2d(T), other: Point2d(T)) T {
            return
            // zig fmt: off
                (self.x - other.x) * (self.x - other.x) +
                (self.y - other.y) * (self.y - other.y);
            // zig fmt: on
        }

        /// Computes the distance between self and other.
        pub fn distance(self: Point2d(T), other: Point2d(T)) T {
            return @sqrt(self.distanceSquared(other));
        }

        /// Rotates the point by angle with regards to center.
        pub fn rotate(self: Point2d(T), angle: T, center: Point2d(T)) Point2d(T) {
            const cos = @cos(angle);
            const sin = @sin(angle);
            return .{
                .x = cos * (self.x - center.x) - sin * (self.y - center.y) + center.x,
                .y = sin * (self.x - center.x) + cos * (self.y - center.y) + center.y,
            };
        }

        /// Casts the underlying 2d point type T to U.
        pub fn as(self: Point2d(T), comptime U: type) Point2d(U) {
            return .{ .x = @floatCast(self.x), .y = @floatCast(self.y) };
        }

        /// Converts the 2d point to a 3d point with the given z coordinate.
        pub fn to3d(self: Point2d(T), z: T) Point3d(T) {
            return .{ .x = self.x, .y = self.y, .z = z };
        }
    };
}

/// A simple 3D point with floating point coordinates.
pub fn Point3d(comptime T: type) type {
    assert(@typeInfo(T) == .float);
    return struct {
        x: T,
        y: T,
        z: T,

        /// Scales self x, y and z coordinates with x_scale, y_scale and z_scale, respectively.
        pub fn scale(self: Point2d(T), x_scale: T, y_scale: T, z_scale: T) Point2d(T) {
            return .{ .x = self.x * x_scale, .y = self.y * y_scale, .z = self.z * z_scale };
        }

        /// Adds self and other.
        pub fn add(self: Point3d(T), other: Point3d(T)) Point3d(T) {
            return .{ .x = self.x + other.x, .y = self.y + other.y, .z = self.z + other.z };
        }

        /// Subtracts other from self.
        pub fn sub(self: Point3d(T), other: Point3d(T)) Point3d(T) {
            return .{ .x = self.x - other.x, .y = self.y - other.y, .z = self.z - other.z };
        }

        /// Computes the norm of self.
        pub fn norm(self: Point3d(T)) T {
            return @sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
        }

        /// Computes the squared distance between self and other, useful to avoid the call to sqrt.
        pub fn distanceSquared(self: Point3d(T), other: Point3d(T)) T {
            return
            // zig fmt: off
                (self.x - other.x) * (self.x - other.x) +
                (self.y - other.y) * (self.y - other.y) +
                (self.z - other.z) * (self.z - other.z);
            // zig fmt: on
        }

        /// Computes the distance between self and other.
        pub fn distance(self: Point3d(T), other: Point3d(T)) T {
            return @sqrt(self.distanceSquared(other));
        }

        /// Casts the underlying 3d point type T to U.
        pub fn as(self: Point3d(T), comptime U: type) Point3d(U) {
            return .{ .x = @floatCast(self.x), .y = @floatCast(self.y), .z = @floatCast(self.z) };
        }

        /// Converts the 3d point to a 2d point by removing the z coordinate.
        pub fn to2d(self: Point3d(T)) Point2d(T) {
            return .{ .x = self.x, .y = self.y };
        }

        /// Converts the 3d point to a 2d point in homogeneous coordinates, that is, by dividing
        /// x and y by z.
        pub fn to2dHomogeneous(self: Point3d(T)) Point2d(T) {
            if (self.z == 0) {
                return self.to2d();
            } else {
                return .{ .x = self.x / self.z, .y = self.y / self.z };
            }
        }
    };
}
