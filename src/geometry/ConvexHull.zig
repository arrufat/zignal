const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;

const Point2d = @import("points.zig").Point2d;

/// Struct that encapsulates all logic for a Convex Hull computation.
pub fn ConvexHull(comptime T: type) type {
    return struct {
        points: std.ArrayList(Point2d(T)),
        hull: std.ArrayList(Point2d(T)),

        const Self = @This();
        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .points = .init(allocator),
                .hull = .init(allocator),
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

            // Find the topmost-leftmost point (lowest y, then lowest x)
            var lowest_idx: usize = 0;
            for (self.points.items[1..], 1..) |p, i| {
                const current = self.points.items[lowest_idx];
                if (p.y < current.y or (p.y == current.y and p.x < current.x)) {
                    lowest_idx = i;
                }
            }

            // Swap the pivot point to the beginning
            if (lowest_idx != 0) {
                std.mem.swap(Point2d(T), &self.points.items[0], &self.points.items[lowest_idx]);
            }
            const lowest = self.points.items[0];

            // Sort remaining points by polar angle in clockwise order
            std.mem.sort(Point2d(T), self.points.items[1..], lowest, clockwiseOrder);

            self.hull.clearRetainingCapacity();
            try self.hull.append(lowest); // Add pivot first

            // Process remaining points
            for (self.points.items[1..]) |p| {
                // Remove points that do NOT create a clockwise turn
                while (self.hull.items.len > 1 and computeOrientation(
                    self.hull.items[self.hull.items.len - 2],
                    self.hull.items[self.hull.items.len - 1],
                    p,
                ) != .clockwise) {
                    _ = self.hull.pop();
                }
                try self.hull.append(p);
            }

            // Handle the case where all input points were collinear.
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
    var convex_hull: ConvexHull(f32) = .init(std.testing.allocator);
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
    var convex_hull: ConvexHull(f32) = .init(std.testing.allocator);
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
