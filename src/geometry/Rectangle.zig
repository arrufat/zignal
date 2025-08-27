const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;

const as = @import("../meta.zig").as;

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
        pub fn cast(self: Self, comptime U: type) Rectangle(U) {
            return .{
                .l = as(U, self.l),
                .t = as(U, self.t),
                .r = as(U, self.r),
                .b = as(U, self.b),
            };
        }

        /// Checks if a rectangle is ill-formed.
        pub fn isEmpty(self: Self) bool {
            return switch (@typeInfo(T)) {
                .int => self.t >= self.b or self.l >= self.r,
                .float => self.t >= self.b or self.l >= self.r,
                else => @compileError("Unsupported type " ++ @typeName(T) ++ " for Rectangle"),
            };
        }

        /// Returns the width of the rectangle.
        pub fn width(self: Self) if (@typeInfo(T) == .int) usize else T {
            return if (self.isEmpty()) 0 else switch (@typeInfo(T)) {
                .int => @intCast(self.r - self.l),
                .float => self.r - self.l,
                else => @compileError("Unsupported type " ++ @typeName(T) ++ " for Rectangle"),
            };
        }

        /// Returns the height of the rectangle.
        pub fn height(self: Self) if (@typeInfo(T) == .int) usize else T {
            return if (self.isEmpty()) 0 else switch (@typeInfo(T)) {
                .int => @intCast(self.b - self.t),
                .float => self.b - self.t,
                else => @compileError("Unsupported type " ++ @typeName(T) ++ " for Rectangle"),
            };
        }

        /// Returns the area of the rectangle
        pub fn area(self: Self) if (@typeInfo(T) == .int) usize else T {
            return self.height() * self.width();
        }

        /// Returns true if the point at x, y is inside the rectangle.
        pub fn contains(self: Self, x: T, y: T) bool {
            if (x < self.l or x >= self.r or y < self.t or y >= self.b) {
                return false;
            }
            return true;
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
    };
}

test "Rectangle" {
    const irect = Rectangle(isize){ .l = 0, .t = 0, .r = 640, .b = 480 };
    try expectEqual(irect.width(), 640);
    try expectEqual(irect.height(), 480);
    const frect = Rectangle(f64){ .l = 0, .t = 0, .r = 640, .b = 480 };
    try expectEqual(frect.width(), 640);
    try expectEqual(frect.height(), 480);
    try expectEqual(frect.contains(320, 240), true);
    try expectEqual(irect.contains(640, 480), false);
    try expectEqualDeep(frect.cast(isize), irect);
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

    // Self intersection
    const self_intersection = rect1.intersect(rect1);
    try expectEqualDeep(self_intersection, rect1);
}
