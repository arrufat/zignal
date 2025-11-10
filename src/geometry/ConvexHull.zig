const std = @import("std");
const Allocator = std.mem.Allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;

const Point = @import("Point.zig").Point;
const Rectangle = @import("Rectangle.zig").Rectangle;
const computeOrientation = @import("utils.zig").computeOrientation;

/// Struct that encapsulates all logic for a Convex Hull computation.
pub fn ConvexHull(comptime T: type) type {
    return struct {
        gpa: Allocator,
        points: std.ArrayList(Point(2, T)),
        hull: std.ArrayList(Point(2, T)),

        const Self = @This();
        pub fn init(gpa: Allocator) Self {
            return Self{
                .gpa = gpa,
                .points = .empty,
                .hull = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.points.deinit(self.gpa);
            self.hull.deinit(self.gpa);
        }

        /// Compares the points by polar angle in clockwise order.
        fn clockwiseOrder(p: Point(2, T), a: Point(2, T), b: Point(2, T)) bool {
            return switch (computeOrientation(T, p, a, b)) {
                .clockwise => true,
                .counter_clockwise => false,
                .collinear => p.distanceSquared(a) < p.distanceSquared(b),
            };
        }

        /// Returns the convex hull of a set of points using the Graham's scan algorithm.
        pub fn find(self: *Self, points: []const Point(2, T)) !?[]Point(2, T) {
            self.hull.clearRetainingCapacity();
            // We need at least 3 points to compute a hull.
            if (points.len < 3) {
                return null;
            }
            self.points.clearRetainingCapacity();
            try self.points.resize(self.gpa, points.len);
            @memcpy(self.points.items, points);

            // Find the topmost-leftmost point (lowest y, then lowest x)
            var lowest_idx: usize = 0;
            for (self.points.items[1..], 1..) |p, i| {
                const current = self.points.items[lowest_idx];
                if (p.y() < current.y() or (p.y() == current.y() and p.x() < current.x())) {
                    lowest_idx = i;
                }
            }

            // Swap the pivot point to the beginning
            if (lowest_idx != 0) {
                std.mem.swap(Point(2, T), &self.points.items[0], &self.points.items[lowest_idx]);
            }
            const lowest = self.points.items[0];

            // Sort remaining points by polar angle in clockwise order
            std.mem.sort(Point(2, T), self.points.items[1..], lowest, clockwiseOrder);

            try self.hull.append(self.gpa, lowest); // Add pivot first

            // Process remaining points
            for (self.points.items[1..]) |p| {
                // Remove points that do NOT create a clockwise turn
                while (self.hull.items.len > 1 and computeOrientation(
                    T,
                    self.hull.items[self.hull.items.len - 2],
                    self.hull.items[self.hull.items.len - 1],
                    p,
                ) != .clockwise) {
                    _ = self.hull.pop();
                }
                try self.hull.append(self.gpa, p);
            }

            // Handle the case where all input points were collinear.
            if (!self.isValid()) {
                self.hull.clearRetainingCapacity();
                return null;
            }

            return self.hull.items;
        }

        /// Returns true when the current hull contains at least three vertices.
        pub fn isValid(self: *const Self) bool {
            return self.hull.items.len >= 3;
        }

        /// Returns the tightest axis-aligned rectangle containing the current hull.
        pub fn getRectangle(self: *const Self) ?Rectangle(T) {
            if (!self.isValid()) {
                return null;
            }
            var min = self.hull.items[0].items;
            var max = self.hull.items[0].items;
            for (self.hull.items[1..]) |point| {
                min = @min(point.items, min);
                max = @max(point.items, max);
            }
            return .init(min[0], min[1], max[0], max[1]);
        }
    };
}

test "convex hull" {
    const points: []const Point(2, f32) = &.{
        .init(.{ 0.0, 0.0 }),
        .init(.{ 1.0, 1.0 }),
        .init(.{ 2.0, 2.0 }),
        .init(.{ 3.0, 1.0 }),
        .init(.{ 4.0, 0.0 }),
        .init(.{ 2.0, 4.0 }),
        .init(.{ 1.0, 3.0 }),
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
    // These three points can have different orientations due to floating point precision.
    const a: Point(2, f32) = .init(.{ 4.9171928e-1, 6.473901e-1 });
    const b: Point(2, f32) = .init(.{ 3.6271343e-1, 9.712454e-1 });
    const c: Point(2, f32) = .init(.{ 3.9276862e-1, 8.9579517e-1 });
    const orientation_abc = computeOrientation(f32, a, b, c);
    const orientation_acb = computeOrientation(f32, a, c, b);
    try std.testing.expectEqual(orientation_abc, orientation_acb);
}

test "convex hull square" {
    const points: []const Point(2, f32) = &.{
        .init(.{ 0.0, 0.0 }),
        .init(.{ 1.0, 0.0 }),
        .init(.{ 1.0, 1.0 }),
        .init(.{ 0.0, 1.0 }),
    };
    var convex_hull: ConvexHull(f32) = .init(std.testing.allocator);
    defer convex_hull.deinit();
    const result = (try convex_hull.find(points)).?;
    try expectEqual(result.len, 4);
    const expected = [_]Point(2, f32){ points[0], points[3], points[2], points[1] };
    try expectEqualDeep(result, &expected);
    try expectEqual(convex_hull.isValid(), true);
    const rect = convex_hull.getRectangle().?;
    try expectEqualDeep(rect, Rectangle(f32).init(0.0, 0.0, 1.0, 1.0));
}

test "convex hull triangle" {
    const points: []const Point(2, f32) = &.{
        .init(.{ 0.0, 0.0 }),
        .init(.{ 1.0, 0.0 }),
        .init(.{ 0.5, 1.0 }),
    };
    var convex_hull: ConvexHull(f32) = .init(std.testing.allocator);
    defer convex_hull.deinit();
    const result = (try convex_hull.find(points)).?;
    try expectEqual(result.len, 3);
    const expected = [_]Point(2, f32){ points[0], points[2], points[1] };
    try expectEqualDeep(result, &expected);
}

test "convex hull with interior points" {
    const points: []const Point(2, f32) = &.{
        .init(.{ 0.0, 0.0 }),
        .init(.{ 2.0, 0.0 }),
        .init(.{ 1.0, 2.0 }),
        .init(.{ 1.0, 1.0 }), // Interior point
        .init(.{ 0.5, 0.5 }), // Interior point
    };
    var convex_hull: ConvexHull(f32) = .init(std.testing.allocator);
    defer convex_hull.deinit();
    const hull = (try convex_hull.find(points)).?;
    try expectEqual(hull.len, 3);
    const expected = [_]Point(2, f32){ points[0], points[2], points[1] };
    try expectEqualDeep(hull, &expected);
}

test "convex hull duplicate points" {
    const points: []const Point(2, f32) = &.{
        .init(.{ 0.0, 0.0 }),
        .init(.{ 1.0, 0.0 }),
        .init(.{ 1.0, 1.0 }),
        .init(.{ 0.0, 1.0 }),
        .init(.{ 0.0, 0.0 }), // Duplicate
        .init(.{ 1.0, 0.0 }), // Duplicate
    };
    var convex_hull: ConvexHull(f32) = .init(std.testing.allocator);
    defer convex_hull.deinit();
    const result = (try convex_hull.find(points)).?;
    try expectEqual(result.len, 4);
    const expected = [_]Point(2, f32){ points[0], points[3], points[2], points[1] };
    try expectEqualDeep(result, &expected);
}

test "convex hull bounding rectangle requires valid hull" {
    const collinear: []const Point(2, f32) = &.{
        .init(.{ 0.0, 0.0 }),
        .init(.{ 1.0, 1.0 }),
        .init(.{ 2.0, 2.0 }),
        .init(.{ 3.0, 3.0 }),
    };
    var convex_hull: ConvexHull(f32) = .init(std.testing.allocator);
    defer convex_hull.deinit();

    try expectEqual(convex_hull.isValid(), false);
    try expectEqual(convex_hull.getRectangle(), null);
    const degenerate = try convex_hull.find(collinear);
    try expectEqual(degenerate, null);
    try expectEqual(convex_hull.isValid(), false);
    try expectEqual(convex_hull.getRectangle(), null);

    const points: []const Point(2, f32) = &.{
        .init(.{ -1.0, -2.0 }),
        .init(.{ 3.0, 0.0 }),
        .init(.{ 1.0, 4.0 }),
        .init(.{ -2.0, 1.5 }),
    };

    _ = (try convex_hull.find(points)).?;
    try expectEqual(convex_hull.isValid(), true);
    const rect = convex_hull.getRectangle().?;
    try expectEqualDeep(rect, Rectangle(f32).init(-2.0, -2.0, 3.0, 4.0));
}
