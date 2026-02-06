const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const math = std.math;

const Image = @import("../image.zig").Image;
const Point = @import("../geometry.zig").Point;
const Rectangle = @import("../geometry.zig").Rectangle;

/// Hough Transform implementation for line detection.
pub const HoughTransform = struct {
    /// Represents a detected line in Hough space.
    pub const Line = struct {
        /// Angle of the line in degrees.
        /// 0 means horizontal, 90/-90 means vertical.
        angle: f32,
        /// Distance from the center of the image.
        radius: f32,
        /// Strength of the line (vote count).
        score: u32,
        /// Computed start point of the line segment (clipped to image bounds).
        p1: Point(2, f32),
        /// Computed end point of the line segment (clipped to image bounds).
        p2: Point(2, f32),
    };

    size: u32,
    even_size: u32,
    cos_table: []i32,
    sin_table: []i32,
    y_cache: []i32,
    allocator: Allocator,

    const Self = @This();

    /// Initializes the Hough Transform with 1D lookup tables.
    /// `size` defines the resolution of the Hough space (size x size).
    pub fn init(allocator: Allocator, size: u32) !Self {
        assert(size > 0);
        const even_size = if (size % 2 == 0) size else size - 1;

        const cos_table = try allocator.alloc(i32, size);
        errdefer allocator.free(cos_table);
        const sin_table = try allocator.alloc(i32, size);
        errdefer allocator.free(sin_table);
        const y_cache = try allocator.alloc(i32, size);
        errdefer allocator.free(y_cache);

        const scale: f64 = 1 << 16;
        const sqrt_2 = math.sqrt(2.0);

        for (0..size) |t| {
            const theta = @as(f64, @floatFromInt(t)) * math.pi / @as(f64, @floatFromInt(even_size));
            cos_table[t] = @intFromFloat(scale * @cos(theta) / sqrt_2);
            sin_table[t] = @intFromFloat(scale * @sin(theta) / sqrt_2);
        }

        return .{
            .size = size,
            .even_size = even_size,
            .cos_table = cos_table,
            .sin_table = sin_table,
            .y_cache = y_cache,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.cos_table);
        self.allocator.free(self.sin_table);
        self.allocator.free(self.y_cache);
    }

    /// Performs the Hough Transform on a binary edge image.
    /// Optimized with integer arithmetic, precomputed Y-terms, and loop unrolling.
    pub fn compute(self: Self, edges: Image(u8), box: Rectangle(u32), accumulator: Image(u32)) void {
        assert(box.width() == self.size and box.height() == self.size);
        assert(accumulator.rows == self.size and accumulator.cols == self.size);

        const area = box.intersect(edges.getRectangle()) orelse return;

        const size_minus_one: i32 = @intCast(self.size - 1);
        const box_t: i32 = @intCast(box.t);
        const box_l: i32 = @intCast(box.l);
        const offset = @as(i32, @intFromFloat(((1 << 16) * @as(f64, @floatFromInt(self.even_size)) / 4.0) + 0.5));

        // Use a local slice for faster access and to avoid bounds checks in the hot loop
        const cos_table = self.cos_table;
        const y_cache = self.y_cache;
        const max_n4 = (self.size / 4) * 4;

        var r = area.t;
        while (r < area.b) : (r += 1) {
            const y_val = 2 * (@as(i32, @intCast(r)) - box_t) - size_minus_one;

            // Precompute Y terms for this row
            // This lifts one multiplication out of the inner loop (size * size reduction)
            for (0..self.size) |t| {
                y_cache[t] = y_val * self.sin_table[t];
            }

            var c = area.l;
            while (c < area.r) : (c += 1) {
                if (edges.at(r, c).* == 0) continue;

                const x_val = 2 * (@as(i32, @intCast(c)) - box_l) - size_minus_one;

                var t: usize = 0;
                while (t < max_n4) {
                    // Unrolled 4x for better pipelining and reduced loop overhead
                    const rho0 = x_val * cos_table[t] + y_cache[t];
                    const rr0 = ((rho0 >> 1) + (offset << 1)) >> 16;
                    if (rr0 >= 0 and rr0 < self.size) accumulator.at(@intCast(rr0), t).* += 1;

                    const rho1 = x_val * cos_table[t + 1] + y_cache[t + 1];
                    const rr1 = ((rho1 >> 1) + (offset << 1)) >> 16;
                    if (rr1 >= 0 and rr1 < self.size) accumulator.at(@intCast(rr1), t + 1).* += 1;

                    const rho2 = x_val * cos_table[t + 2] + y_cache[t + 2];
                    const rr2 = ((rho2 >> 1) + (offset << 1)) >> 16;
                    if (rr2 >= 0 and rr2 < self.size) accumulator.at(@intCast(rr2), t + 2).* += 1;

                    const rho3 = x_val * cos_table[t + 3] + y_cache[t + 3];
                    const rr3 = ((rho3 >> 1) + (offset << 1)) >> 16;
                    if (rr3 >= 0 and rr3 < self.size) accumulator.at(@intCast(rr3), t + 3).* += 1;

                    t += 4;
                }

                // Handle remaining items
                while (t < self.size) : (t += 1) {
                    const rho = x_val * cos_table[t] + y_cache[t];
                    const rr = ((rho >> 1) + (offset << 1)) >> 16;
                    if (rr >= 0 and rr < self.size) {
                        accumulator.at(@intCast(rr), t).* += 1;
                    }
                }
            }
        }
    }

    /// Finds strong lines in the accumulator using NMS.
    pub fn findLines(
        self: Self,
        allocator: Allocator,
        accumulator: Image(u32),
        threshold: u32,
        angle_nms_thresh: f32,
        radius_nms_thresh: f32,
    ) ![]Line {
        var lines = try std.ArrayList(Line).initCapacity(allocator, 128);
        defer lines.deinit(allocator);

        if (accumulator.rows < 3 or accumulator.cols < 3) return try allocator.alloc(Line, 0);

        for (1..accumulator.rows - 1) |r| {
            for (1..accumulator.cols - 1) |c| {
                const votes = accumulator.at(r, c).*;
                if (votes < threshold) continue;

                var is_local_max = true;
                check_neighbors: for (r - 1..r + 2) |nr| {
                    for (c - 1..c + 2) |nc| {
                        if (nr == r and nc == c) continue;
                        if (accumulator.at(nr, nc).* > votes) {
                            is_local_max = false;
                            break :check_neighbors;
                        }
                    }
                }

                if (is_local_max) {
                    const angle, const radius = self.getLineProperties(@floatFromInt(c), @floatFromInt(r));
                    try lines.append(allocator, self.createLine(angle, radius, votes));
                }
            }
        }

        std.mem.sort(Line, lines.items, {}, struct {
            fn lessThan(_: void, a: Line, b: Line) bool {
                return a.score > b.score;
            }
        }.lessThan);

        var final_lines = try std.ArrayList(Line).initCapacity(allocator, lines.items.len);
        errdefer final_lines.deinit(allocator);

        for (lines.items) |candidate| {
            var too_close = false;
            for (final_lines.items) |existing| {
                const da = @abs(existing.angle - candidate.angle);
                const dr = @abs(existing.radius - candidate.radius);
                if ((da < angle_nms_thresh and dr < radius_nms_thresh) or
                    ((180.0 - da) < angle_nms_thresh and @abs(existing.radius + candidate.radius) < radius_nms_thresh))
                {
                    too_close = true;
                    break;
                }
            }
            if (!too_close) try final_lines.append(allocator, candidate);
        }

        return final_lines.toOwnedSlice(allocator);
    }

    /// Returns angle and radius
    fn getLineProperties(self: Self, theta_idx: f32, rho_idx: f32) struct { f32, f32 } {
        const center_val = @as(f32, @floatFromInt(self.size - 1)) / 2.0;
        const angle = 180.0 * (theta_idx - center_val) / @as(f32, @floatFromInt(self.even_size));
        const radius = (rho_idx - center_val) * math.sqrt(@as(f32, 2.0));
        return .{ angle, radius };
    }

    fn createLine(self: Self, angle: f32, radius: f32, score: u32) Line {
        const center = @as(f32, @floatFromInt(self.size - 1)) / 2.0;
        const theta_rad = (angle + 90.0) * math.pi / 180.0;
        const cos_t = @cos(theta_rad);
        const sin_t = @sin(theta_rad);

        const p_center: Point(2, f32) = .init(.{ radius * cos_t, radius * sin_t });
        const dir: Point(2, f32) = .init(.{ -sin_t, cos_t });
        const huge = @as(f32, @floatFromInt(self.size)) * 2.0;

        var p1: Point(2, f32) = .init(.{ center + p_center.x() + dir.x() * huge, center + p_center.y() + dir.y() * huge });
        var p2: Point(2, f32) = .init(.{ center + p_center.x() - dir.x() * huge, center + p_center.y() - dir.y() * huge });
        clipLine(.{ .l = 0, .t = 0, .r = @floatFromInt(self.size), .b = @floatFromInt(self.size) }, &p1, &p2);

        return .{ .angle = angle, .radius = radius, .score = score, .p1 = p1, .p2 = p2 };
    }
};

fn clipLine(rect: Rectangle(f32), p1: *Point(2, f32), p2: *Point(2, f32)) void {
    var t0: f32 = 0.0;
    var t1: f32 = 1.0;
    const dx = p2.x() - p1.x();
    const dy = p2.y() - p1.y();
    const p = [4]f32{ -dx, dx, -dy, dy };
    const q = [4]f32{ p1.x() - rect.l, rect.r - p1.x(), p1.y() - rect.t, rect.b - p1.y() };
    for (0..4) |i| {
        if (p[i] == 0) {
            if (q[i] < 0) return;
        } else {
            const r = q[i] / p[i];
            if (p[i] < 0) {
                if (r > t1) return;
                if (r > t0) t0 = r;
            } else {
                if (r < t0) return;
                if (r < t1) t1 = r;
            }
        }
    }
    if (t0 > t1) return;
    const old_p1 = p1.*;
    p1.* = .init(.{ old_p1.x() + t0 * dx, old_p1.y() + t0 * dy });
    p2.* = .init(.{ old_p1.x() + t1 * dx, old_p1.y() + t1 * dy });
}

test "HoughTransform: detect horizontal line" {
    const allocator = std.testing.allocator;
    const size = 64;
    var edges: Image(u8) = try .init(allocator, size, size);
    defer edges.deinit(allocator);
    edges.fill(0);
    for (0..size) |c| edges.at(32, c).* = 255;

    var hough: HoughTransform = try .init(allocator, size);
    defer hough.deinit();
    var accumulator: Image(u32) = try .init(allocator, size, size);
    defer accumulator.deinit(allocator);
    accumulator.fill(0);

    hough.compute(edges, .{ .l = 0, .t = 0, .r = size, .b = size }, accumulator);
    const lines = try hough.findLines(allocator, accumulator, 30, 10.0, 5.0);
    defer allocator.free(lines);

    try std.testing.expect(lines.len >= 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lines[0].angle, 2.0);
}
