const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;

const meta = @import("../meta.zig");
const Point = @import("Point.zig").Point;

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
            assert(r >= l and b >= t);
            return .{ .l = l, .t = t, .r = r, .b = b };
        }

        /// Initialize a rectangle at center x, y with the specified width and height.
        pub fn initCenter(x: T, y: T, w: T, h: T) Self {
            assert(w > 0 and h > 0);
            switch (@typeInfo(T)) {
                .int => {
                    const l = x - @divFloor(w, 2);
                    const t = y - @divFloor(h, 2);
                    const r = l + w;
                    const b = t + h;
                    return .init(l, t, r, b);
                },
                .float => {
                    const l = x - w / 2;
                    const t = y - h / 2;
                    const r = l + w;
                    const b = t + h;
                    return .init(l, t, r, b);
                },
                else => @compileError("Unsupported type " ++ @typeName(T) ++ " for Rectangle"),
            }
        }

        /// Casts self's underlying type to U.
        pub fn as(self: Self, comptime U: type) Rectangle(U) {
            return .{
                .l = meta.as(U, self.l),
                .t = meta.as(U, self.t),
                .r = meta.as(U, self.r),
                .b = meta.as(U, self.b),
            };
        }

        /// Checks if a rectangle is ill-formed.
        pub fn isEmpty(self: Self) bool {
            return self.t >= self.b or self.l >= self.r;
        }

        /// Returns a new rectangle with coordinates re-ordered such that l <= r and t <= b.
        pub fn reorder(self: Self) Self {
            return .{
                .l = @min(self.l, self.r),
                .t = @min(self.t, self.b),
                .r = @max(self.l, self.r),
                .b = @max(self.t, self.b),
            };
        }

        /// Returns the width of the rectangle.
        pub fn width(self: Self) if (@typeInfo(T) == .int) usize else T {
            if (self.l >= self.r) return 0;
            return switch (@typeInfo(T)) {
                .int => @intCast(self.r - self.l),
                .float => self.r - self.l,
                else => unreachable,
            };
        }

        /// Returns the height of the rectangle.
        pub fn height(self: Self) if (@typeInfo(T) == .int) usize else T {
            if (self.t >= self.b) return 0;
            return switch (@typeInfo(T)) {
                .int => @intCast(self.b - self.t),
                .float => self.b - self.t,
                else => unreachable,
            };
        }

        /// Returns the area of the rectangle
        pub fn area(self: Self) if (@typeInfo(T) == .int) usize else T {
            if (self.isEmpty()) return 0;
            return self.height() * self.width();
        }

        /// Returns true if the point is inside the rectangle.
        /// Can be called with a Point(2, T) or with x and y coordinates.
        pub fn contains(self: Self, args: anytype) bool {
            const ArgsType = @TypeOf(args);
            const coords = switch (@typeInfo(ArgsType)) {
                .@"struct" => |s| if (s.is_tuple) .{ args[0], args[1] } else .{ args.x(), args.y() },
                else => @compileError("contains expects a Point(2, T) or a tuple .{x, y}"),
            };
            const x = meta.as(T, coords[0]);
            const y = meta.as(T, coords[1]);

            switch (@typeInfo(T)) {
                .float => {
                    if (std.math.isNan(x) or std.math.isNan(y)) return false;
                },
                else => {},
            }
            if (x < self.l or x >= self.r or y < self.t or y >= self.b) {
                return false;
            }
            return true;
        }

        /// Returns the center of the rectangle as an (x, y) tuple.
        pub fn center(self: Self) std.meta.Tuple(&.{ T, T }) {
            switch (@typeInfo(T)) {
                .int => {
                    const half_width = @divTrunc(self.r - self.l, 2);
                    const half_height = @divTrunc(self.b - self.t, 2);
                    return .{ self.l + half_width, self.t + half_height };
                },
                .float => {
                    const half_width = (self.r - self.l) / 2;
                    const half_height = (self.b - self.t) / 2;
                    return .{ self.l + half_width, self.t + half_height };
                },
                else => @compileError("Unsupported type " ++ @typeName(T) ++ " for Rectangle"),
            }
        }

        /// Returns the top-left corner as an (x, y) tuple.
        pub fn topLeft(self: Self) std.meta.Tuple(&.{ T, T }) {
            return .{ self.l, self.t };
        }

        /// Returns the top-right corner as an (x, y) tuple.
        pub fn topRight(self: Self) std.meta.Tuple(&.{ T, T }) {
            return .{ self.r, self.t };
        }

        /// Returns the bottom-left corner as an (x, y) tuple.
        pub fn bottomLeft(self: Self) std.meta.Tuple(&.{ T, T }) {
            return .{ self.l, self.b };
        }

        /// Returns the bottom-right corner as an (x, y) tuple.
        pub fn bottomRight(self: Self) std.meta.Tuple(&.{ T, T }) {
            return .{ self.r, self.b };
        }

        /// Grows the given rectangle by expanding its borders by `amount`.
        pub fn grow(self: Self, amount: T) Self {
            return switch (@typeInfo(T)) {
                .int => .{
                    .l = self.l -| amount,
                    .t = self.t -| amount,
                    .r = self.r +| amount,
                    .b = self.b +| amount,
                },
                .float => .{
                    .l = self.l - amount,
                    .t = self.t - amount,
                    .r = self.r + amount,
                    .b = self.b + amount,
                },
                else => @compileError("Unsupported type " ++ @typeName(T) ++ " for Rectangle"),
            };
        }

        /// Shrinks the given rectangle by shrinking its borders by `amount`.
        pub fn shrink(self: Self, amount: T) Self {
            return switch (@typeInfo(T)) {
                .int => .{
                    .l = self.l +| amount,
                    .t = self.t +| amount,
                    .r = self.r -| amount,
                    .b = self.b -| amount,
                },
                .float => .{
                    .l = self.l + amount,
                    .t = self.t + amount,
                    .r = self.r - amount,
                    .b = self.b - amount,
                },
                else => @compileError("Unsupported type " ++ @typeName(T) ++ " for Rectangle"),
            };
        }

        /// Returns a new rectangle translated by (dx, dy).
        pub fn translate(self: Self, dx: T, dy: T) Self {
            return switch (@typeInfo(T)) {
                .int => .{
                    .l = self.l +| dx,
                    .t = self.t +| dy,
                    .r = self.r +| dx,
                    .b = self.b +| dy,
                },
                .float => .{
                    .l = self.l + dx,
                    .t = self.t + dy,
                    .r = self.r + dx,
                    .b = self.b + dy,
                },
                else => @compileError("Unsupported type " ++ @typeName(T) ++ " for Rectangle"),
            };
        }

        /// Returns the rectangle clipped to `bounds`.
        pub fn clip(self: Self, bounds: Self) Self {
            return .{
                .l = @max(self.l, bounds.l),
                .t = @max(self.t, bounds.t),
                .r = @min(self.r, bounds.r),
                .b = @min(self.b, bounds.b),
            };
        }

        /// Returns the intersection of two rectangles, or null if they don't overlap.
        pub fn intersect(self: Self, other: Self) ?Self {
            const l = @max(self.l, other.l);
            const t = @max(self.t, other.t);
            const r = @min(self.r, other.r);
            const b = @min(self.b, other.b);

            // Check if the intersection is empty
            return switch (@typeInfo(T)) {
                .int => if (l >= r or t >= b) null else Self.init(l, t, r, b),
                .float => if (l >= r or t >= b) null else Self.init(l, t, r, b),
                else => @compileError("Unsupported type " ++ @typeName(T) ++ " for Rectangle"),
            };
        }

        /// Returns the diagonal length of the rectangle as an f64.
        pub fn diagonal(self: Self) f64 {
            const width_val = switch (@typeInfo(T)) {
                .int => @as(f64, @floatFromInt(self.width())),
                .float => @as(f64, self.width()),
                else => @compileError("Unsupported type " ++ @typeName(T) ++ " for Rectangle"),
            };
            const height_val = switch (@typeInfo(T)) {
                .int => @as(f64, @floatFromInt(self.height())),
                .float => @as(f64, self.height()),
                else => @compileError("Unsupported type " ++ @typeName(T) ++ " for Rectangle"),
            };
            return std.math.hypot(width_val, height_val);
        }

        /// Returns true if `other` is fully contained within `self`.
        pub fn covers(self: Self, other: Self) bool {
            if (self.isEmpty()) return false;
            if (other.isEmpty()) return true;
            return other.l >= self.l and other.t >= self.t and other.r <= self.r and other.b <= self.b;
        }

        /// Calculates the Intersection over Union (IoU) of two rectangles.
        /// Returns a value between 0 (no overlap) and 1 (identical rectangles).
        pub fn iou(self: Self, other: Self) f64 {
            const intersection = self.intersect(other) orelse return 0.0;
            const intersection_area = intersection.area();

            // Calculate union area = area1 + area2 - intersection_area
            const self_area = self.area();
            const other_area = other.area();
            const union_area = self_area + other_area - intersection_area;

            // Handle edge case where both rectangles have zero area
            if (union_area == 0) return 0.0;

            // Convert to f64 for accurate division
            return switch (@typeInfo(T)) {
                .int => @as(f64, @floatFromInt(intersection_area)) / @as(f64, @floatFromInt(union_area)),
                .float => @as(f64, intersection_area) / @as(f64, union_area),
                else => @compileError("Unsupported type " ++ @typeName(T) ++ " for Rectangle"),
            };
        }

        /// Determines whether two rectangles overlap enough using intersection-over-union (IoU)
        /// and coverage thresholds. A rectangle is considered overlapping if:
        /// - IoU > iou_thresh
        /// - intersection.area / self.area ≥ coverage_thresh
        /// - intersection.area / other.area ≥ coverage_thresh
        /// Set `iou_thresh = 0` and `coverage_thresh = 0` to test simple intersection.
        /// Use `contains` for directional containment checks.
        pub fn overlaps(self: Self, other: Self, iou_thresh: f64, coverage_thresh: f64) bool {
            assert(iou_thresh >= 0 and iou_thresh <= 1);
            assert(coverage_thresh >= 0 and coverage_thresh <= 1);

            const intersection = self.intersect(other) orelse return false;
            const intersection_area = intersection.area();

            const self_area = self.area();
            const other_area = other.area();

            // Check IoU threshold
            const union_area = self_area + other_area - intersection_area;
            if (union_area > 0) {
                const iou_value = switch (@typeInfo(T)) {
                    .int => @as(f64, @floatFromInt(intersection_area)) / @as(f64, @floatFromInt(union_area)),
                    .float => @as(f64, intersection_area) / @as(f64, union_area),
                    else => @compileError("Unsupported type " ++ @typeName(T) ++ " for Rectangle"),
                };
                if (iou_value > iou_thresh) return true;
            }

            // Check coverage thresholds
            if (self_area > 0) {
                const self_coverage = switch (@typeInfo(T)) {
                    .int => @as(f64, @floatFromInt(intersection_area)) / @as(f64, @floatFromInt(self_area)),
                    .float => @as(f64, intersection_area) / @as(f64, self_area),
                    else => @compileError("Unsupported type " ++ @typeName(T) ++ " for Rectangle"),
                };
                // Inclusive comparison lets coverage_thresh = 1 represent full containment.
                if (self_coverage >= coverage_thresh) return true;
            }

            if (other_area > 0) {
                const other_coverage = switch (@typeInfo(T)) {
                    .int => @as(f64, @floatFromInt(intersection_area)) / @as(f64, @floatFromInt(other_area)),
                    .float => @as(f64, intersection_area) / @as(f64, other_area),
                    else => @compileError("Unsupported type " ++ @typeName(T) ++ " for Rectangle"),
                };
                // Same rationale as above—coverage_thresh = 1 means the other rect is fully covered.
                if (other_coverage >= coverage_thresh) return true;
            }

            return false;
        }

        /// Returns the bounding box containing both rectangles.
        /// Note: "union" is a reserved keyword in Zig, so we use "merge".
        pub fn merge(self: Self, other: Self) Self {
            if (self.isEmpty()) return other;
            if (other.isEmpty()) return self;
            return .{
                .l = @min(self.l, other.l),
                .t = @min(self.t, other.t),
                .r = @max(self.r, other.r),
                .b = @max(self.b, other.b),
            };
        }

        /// Returns the aspect ratio (width / height).
        /// Returns `inf` if height is 0 and width is non-zero.
        /// Returns `NaN` if both width and height are 0.
        pub fn aspectRatio(self: Self) f64 {
            const w = self.width();
            const h = self.height();
            if (h == 0) {
                if (w == 0) return std.math.nan(f64);
                return std.math.inf(f64);
            }

            return switch (@typeInfo(T)) {
                .int => @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(h)),
                .float => @as(f64, w) / @as(f64, h),
                else => unreachable,
            };
        }

        /// Returns the perimeter of the rectangle.
        pub fn perimeter(self: Self) if (@typeInfo(T) == .int) usize else T {
            return (self.width() + self.height()) * 2;
        }
    };
}

test "Rectangle" {
    const irect = Rectangle(isize){ .l = 0, .t = 0, .r = 640, .b = 480 };
    try expectEqual(irect.width(), 640);
    try expectEqual(irect.height(), 480);
    const frect = Rectangle(f64){ .l = 0, .t = 0, .r = 640, .b = 480 };
    try expectEqual(frect.width(), 640);
    try expectEqual(frect.height(), 480);
    try expectEqual(frect.contains(.{ 320, 240 }), true);
    try expectEqual(irect.contains(.{ 640, 480 }), false);
    try expectEqualDeep(frect.as(isize), irect);
}

test "Rectangle grow and shrink" {
    const rect = Rectangle(i32){ .l = 50, .t = 25, .r = 100, .b = 100 };
    const amount: i32 = 10;
    var rect2 = rect.grow(amount);
    try expectEqual(rect.width() + 2 * amount, rect2.width());
    try expectEqual(rect.height() + 2 * amount, rect2.height());
    try expectEqualDeep(rect2, Rectangle(i32){ .l = 40, .t = 15, .r = 110, .b = 110 });
    rect2 = rect2.shrink(10);
    try expectEqualDeep(rect, rect2);
}

test "Rectangle intersect" {
    // Test integer rectangles
    const rect1 = Rectangle(i32){ .l = 0, .t = 0, .r = 100, .b = 100 };
    const rect2 = Rectangle(i32){ .l = 50, .t = 50, .r = 150, .b = 150 };
    const rect3 = Rectangle(i32){ .l = 200, .t = 200, .r = 250, .b = 250 };

    // Overlapping rectangles
    const intersection1 = rect1.intersect(rect2);
    try expectEqualDeep(intersection1, Rectangle(i32){ .l = 50, .t = 50, .r = 100, .b = 100 });

    // Non-overlapping rectangles
    const intersection2 = rect1.intersect(rect3);
    try expectEqual(intersection2, null);

    // Test float rectangles
    const frect1 = Rectangle(f32){ .l = 0.0, .t = 0.0, .r = 100.0, .b = 100.0 };
    const frect2 = Rectangle(f32){ .l = 50.0, .t = 50.0, .r = 150.0, .b = 150.0 };
    const frect3 = Rectangle(f32){ .l = 100.0, .t = 100.0, .r = 200.0, .b = 200.0 };

    // Overlapping float rectangles
    const fintersection1 = frect1.intersect(frect2);
    try expectEqualDeep(fintersection1, Rectangle(f32){ .l = 50.0, .t = 50.0, .r = 100.0, .b = 100.0 });

    // Touching edges (no overlap for floats)
    const fintersection2 = frect1.intersect(frect3);
    try expectEqual(fintersection2, null);
}

test "Rectangle iou and overlaps" {
    const expectApproxEqAbs = std.testing.expectApproxEqAbs;

    // Test with integer rectangles
    const rect1 = Rectangle(i32){ .l = 0, .t = 0, .r = 100, .b = 100 };
    const rect2 = Rectangle(i32){ .l = 50, .t = 50, .r = 150, .b = 150 };
    const rect3 = Rectangle(i32){ .l = 0, .t = 0, .r = 100, .b = 100 }; // Identical to rect1
    const rect4 = Rectangle(i32){ .l = 200, .t = 200, .r = 250, .b = 250 }; // No overlap
    const rect5 = Rectangle(i32){ .l = 25, .t = 25, .r = 75, .b = 75 }; // Completely inside rect1

    // Test IoU calculations
    // rect1 and rect2: intersection = 50x50 = 2500, union = 10000 + 10000 - 2500 = 17500
    try expectApproxEqAbs(rect1.iou(rect2), 2500.0 / 17500.0, 0.0001);

    // Identical rectangles should have IoU = 1
    try expectApproxEqAbs(rect1.iou(rect3), 1.0, 0.0001);

    // Non-overlapping rectangles should have IoU = 0
    try expectApproxEqAbs(rect1.iou(rect4), 0.0, 0.0001);

    // rect5 completely inside rect1: intersection = 2500, union = 10000
    try expectApproxEqAbs(rect1.iou(rect5), 2500.0 / 10000.0, 0.0001);

    // Test overlaps with different thresholds
    // Low IoU threshold
    try expectEqual(rect1.overlaps(rect2, 0.1, 1.0), true); // IoU ≈ 0.143 > 0.1
    try expectEqual(rect1.overlaps(rect2, 0.2, 1.0), false); // IoU ≈ 0.143 < 0.2

    // Coverage threshold tests
    // rect5 is completely inside rect1, so coverage = 1.0 for rect5
    try expectEqual(rect1.overlaps(rect5, 0.0, 0.9), true); // rect5 is 100% covered
    try expectEqual(rect5.overlaps(rect1, 0.0, 0.9), true); // Same check from other direction

    // rect1 and rect2: intersection/rect1.area = 2500/10000 = 0.25. IoU is ~0.143.
    // Test when only coverage passes
    try expectEqual(rect1.overlaps(rect2, 0.2, 0.24), true); // IoU fails (0.143 < 0.2), but coverage passes (0.25 > 0.24)
    // Test when only IoU passes
    try expectEqual(rect1.overlaps(rect2, 0.1, 0.26), true); // IoU passes (0.143 > 0.1), coverage fails (0.25 < 0.26)
    // Test when both fail
    try expectEqual(rect1.overlaps(rect2, 0.2, 0.26), false); // Both fail
    // Test when both pass
    try expectEqual(rect1.overlaps(rect2, 0.1, 0.24), true); // Both pass

    // Test with float rectangles
    const frect1 = Rectangle(f32){ .l = 0.0, .t = 0.0, .r = 100.0, .b = 100.0 };
    const frect2 = Rectangle(f32){ .l = 50.0, .t = 50.0, .r = 150.0, .b = 150.0 };

    try expectApproxEqAbs(frect1.iou(frect2), 2500.0 / 17500.0, 0.0001);
    try expectEqual(frect1.overlaps(frect2, 0.1, 1.0), true);

    // Self intersection
    const self_intersection = rect1.intersect(rect1);
    try expectEqualDeep(self_intersection, rect1);
}

test "Rectangle contains rejects NaN" {
    const rect = Rectangle(f32){ .l = -10.0, .t = -10.0, .r = 10.0, .b = 10.0 };
    const nan = std.math.nan(f32);
    try expectEqual(false, rect.contains(.{ nan, 0.0 }));
    try expectEqual(false, rect.contains(.{ 0.0, nan }));
}

test "Rectangle helpers" {
    const expectApproxEqAbs = std.testing.expectApproxEqAbs;

    const rect = Rectangle(i32){ .l = 10, .t = 20, .r = 30, .b = 50 };
    try expectEqual(rect.center(), .{ 20, 35 });
    try expectEqual(rect.topLeft(), .{ 10, 20 });
    try expectEqual(rect.topRight(), .{ 30, 20 });
    try expectEqual(rect.bottomLeft(), .{ 10, 50 });
    try expectEqual(rect.bottomRight(), .{ 30, 50 });

    const moved = rect.translate(5, -5);
    try expectEqualDeep(moved, Rectangle(i32){ .l = 15, .t = 15, .r = 35, .b = 45 });

    const moved_again = rect.translate(-5, 5);
    try expectEqualDeep(moved_again, Rectangle(i32){ .l = 5, .t = 25, .r = 25, .b = 55 });

    const bounds = Rectangle(i32){ .l = 0, .t = 0, .r = 25, .b = 40 };
    const clipped = rect.clip(bounds);
    try expectEqualDeep(clipped, Rectangle(i32){ .l = 10, .t = 20, .r = 25, .b = 40 });

    const outside = Rectangle(i32){ .l = 100, .t = 100, .r = 120, .b = 120 };
    const clipped_empty = outside.clip(bounds);
    try expectEqual(true, clipped_empty.isEmpty());

    const inner = Rectangle(i32){ .l = 12, .t = 22, .r = 18, .b = 30 };
    try expectEqual(rect.covers(inner), true);
    try expectEqual(inner.covers(rect), false);

    const overlapping = Rectangle(i32){ .l = 25, .t = 45, .r = 40, .b = 60 };
    try expectEqual(rect.overlaps(overlapping, 0.0, 0.0), true);
    try expectEqual(rect.overlaps(outside, 0.0, 0.0), false);

    try expectApproxEqAbs(rect.diagonal(), std.math.hypot(20.0, 30.0), 1e-9);

    const frect = Rectangle(f32){ .l = 0.0, .t = 0.0, .r = 2.0, .b = 2.0 };
    try expectEqual(frect.center(), .{ 1.0, 1.0 });
    const float_bounds = Rectangle(f32){ .l = -1.0, .t = -1.0, .r = 4.0, .b = 4.0 };
    try expectEqual(false, frect.clip(float_bounds).isEmpty());
    try expectEqual(frect.covers(Rectangle(f32){ .l = 0.5, .t = 0.5, .r = 1.5, .b = 1.5 }), true);
}

test "Rectangle merge" {
    const rect1 = Rectangle(i32){ .l = 0, .t = 0, .r = 10, .b = 10 };
    const rect2 = Rectangle(i32){ .l = 20, .t = 20, .r = 30, .b = 30 };
    const merged = rect1.merge(rect2);
    try expectEqualDeep(merged, Rectangle(i32){ .l = 0, .t = 0, .r = 30, .b = 30 });

    const empty = Rectangle(i32){ .l = 0, .t = 0, .r = 0, .b = 0 };
    try expectEqualDeep(rect1.merge(empty), rect1);
    try expectEqualDeep(empty.merge(rect1), rect1);
}

test "Rectangle perimeter and aspect ratio" {
    const rect = Rectangle(i32){ .l = 0, .t = 0, .r = 100, .b = 50 };
    try expectEqual(rect.perimeter(), 300);
    try std.testing.expectApproxEqAbs(rect.aspectRatio(), 2.0, 1e-9);

    const square = Rectangle(f32){ .l = 0, .t = 0, .r = 10.0, .b = 10.0 };
    try expectEqual(square.perimeter(), 40.0);
    try std.testing.expectApproxEqAbs(square.aspectRatio(), 1.0, 1e-9);

    const line = Rectangle(i32){ .l = 0, .t = 0, .r = 100, .b = 0 };
    try std.testing.expect(line.aspectRatio() == std.math.inf(f64));

    const point = Rectangle(i32){ .l = 0, .t = 0, .r = 0, .b = 0 };
    try std.testing.expect(std.math.isNan(point.aspectRatio()));
}

test "Rectangle reorder" {
    const flipped = Rectangle(i32){ .l = 100, .t = 100, .r = 0, .b = 0 };
    try expectEqual(flipped.isEmpty(), true);
    try expectEqual(flipped.width(), 0);

    const fixed = flipped.reorder();
    try expectEqual(fixed.isEmpty(), false);
    try expectEqualDeep(fixed, Rectangle(i32){ .l = 0, .t = 0, .r = 100, .b = 100 });
    try expectEqual(fixed.width(), 100);
}

test "Rectangle contains with Point" {
    const rect = Rectangle(f32){ .l = 0, .t = 0, .r = 10, .b = 10 };
    const p_in = Point(2, f32).init(.{ 5.0, 5.0 });
    const p_out = Point(2, f32).init(.{ 15.0, 5.0 });

    try expectEqual(rect.contains(p_in), true);
    try expectEqual(rect.contains(p_out), false);
}
