const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const math = std.math;

const Image = @import("../image.zig").Image;
const Point = @import("../geometry.zig").Point;
const Rectangle = @import("../geometry.zig").Rectangle;

/// Represents a detected line in Hough space.
pub const HoughLine = struct {
    /// Angle of the line in degrees (-90 to 90).
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

/// Hough Transform implementation for line detection.
/// Inspired by dlib's implementation.
pub const HoughTransform = struct {
    size: u32,
    even_size: u32,
    x_cos_theta: []i32, // Flattened 2D array: size * size
    y_sin_theta: []i32, // Flattened 2D array: size * size
    allocator: Allocator,

    const Self = @This();

    /// Initializes the Hough Transform with a specific accumulator size.
    /// This precomputes lookup tables for fast voting.
    /// `size` defines the resolution of the Hough space (size x size).
    pub fn init(allocator: Allocator, size: u32) !Self {
        assert(size > 0);
        const even_size = if (size % 2 == 0) size else size - 1;

        const total_size = try math.mul(usize, size, size);
        const x_cos = try allocator.alloc(i32, total_size);
        errdefer allocator.free(x_cos);
        const y_sin = try allocator.alloc(i32, total_size);
        errdefer allocator.free(y_sin);

        // Precompute trigonometric tables
        // We use fixed-point arithmetic with 16-bit shift
        const scale: f64 = 1 << 16;
        const sqrt_2 = math.sqrt(2.0);

        // Center of the square box (0,0, size-1, size-1)
        const center_x = @as(f64, @floatFromInt(size - 1)) / 2.0;
        const center_y = @as(f64, @floatFromInt(size - 1)) / 2.0;
        const offset = (scale * @as(f64, @floatFromInt(even_size)) / 4.0) + 0.5;

        // Temporary buffers for cos/sin values
        const cos_theta = try allocator.alloc(f64, size);
        defer allocator.free(cos_theta);
        const sin_theta = try allocator.alloc(f64, size);
        defer allocator.free(sin_theta);

        for (0..size) |t| {
            const theta = @as(f64, @floatFromInt(t)) * math.pi / @as(f64, @floatFromInt(even_size));
            cos_theta[t] = scale * @cos(theta) / sqrt_2;
            sin_theta[t] = scale * @sin(theta) / sqrt_2;
        }

        // Fill x_cos_theta table
        for (0..size) |c| {
            const x = @as(f64, @floatFromInt(c)) - center_x;
            const row_offset = c * size;
            for (0..size) |t| {
                x_cos[row_offset + t] = @intFromFloat(x * cos_theta[t] + offset);
            }
        }

        // Fill y_sin_theta table
        for (0..size) |r| {
            const y = @as(f64, @floatFromInt(r)) - center_y;
            const row_offset = r * size;
            for (0..size) |t| {
                y_sin[row_offset + t] = @intFromFloat(y * sin_theta[t] + offset);
            }
        }

        return .{
            .size = size,
            .even_size = even_size,
            .x_cos_theta = x_cos,
            .y_sin_theta = y_sin,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.x_cos_theta);
        self.allocator.free(self.y_sin_theta);
    }

    /// Performs the Hough Transform on a binary edge image.
    /// `edges`: Input binary image (non-zero pixels are treated as edges).
    /// `box`: The rectangle in the input image to consider (must match `size` x `size`).
    /// `accumulator`: Output image (size x size) storing the votes. Must be initialized to 0.
    pub fn compute(self: Self, edges: Image(u8), box: Rectangle(u32), accumulator: Image(u32)) void {
        assert(box.width() == self.size and box.height() == self.size);
        assert(accumulator.rows == self.size and accumulator.cols == self.size);

        // Intersect box with image bounds
        const img_rect = edges.getRectangle();
        const area = box.intersect(img_rect) orelse return;

        const max_n8 = (self.size / 8) * 8;

        // Iterate over the valid area
        var r = area.t;
        while (r < area.b) : (r += 1) {
            // y_sin row pointer
            const y_idx = (r - box.t) * self.size;

            var c = area.l;
            while (c < area.r) : (c += 1) {
                if (edges.at(r, c).* == 0) continue;

                // x_cos row pointer
                const x_idx = (c - box.l) * self.size;

                var t: usize = 0;
                // Unrolled loop for performance
                while (t < max_n8) {
                    const rr0 = (self.x_cos_theta[x_idx + t] + self.y_sin_theta[y_idx + t]) >> 16;
                    accumulator.at(@intCast(rr0), t).* += 1;
                    t += 1;

                    const rr1 = (self.x_cos_theta[x_idx + t] + self.y_sin_theta[y_idx + t]) >> 16;
                    accumulator.at(@intCast(rr1), t).* += 1;
                    t += 1;

                    const rr2 = (self.x_cos_theta[x_idx + t] + self.y_sin_theta[y_idx + t]) >> 16;
                    accumulator.at(@intCast(rr2), t).* += 1;
                    t += 1;

                    const rr3 = (self.x_cos_theta[x_idx + t] + self.y_sin_theta[y_idx + t]) >> 16;
                    accumulator.at(@intCast(rr3), t).* += 1;
                    t += 1;

                    const rr4 = (self.x_cos_theta[x_idx + t] + self.y_sin_theta[y_idx + t]) >> 16;
                    accumulator.at(@intCast(rr4), t).* += 1;
                    t += 1;

                    const rr5 = (self.x_cos_theta[x_idx + t] + self.y_sin_theta[y_idx + t]) >> 16;
                    accumulator.at(@intCast(rr5), t).* += 1;
                    t += 1;

                    const rr6 = (self.x_cos_theta[x_idx + t] + self.y_sin_theta[y_idx + t]) >> 16;
                    accumulator.at(@intCast(rr6), t).* += 1;
                    t += 1;

                    const rr7 = (self.x_cos_theta[x_idx + t] + self.y_sin_theta[y_idx + t]) >> 16;
                    accumulator.at(@intCast(rr7), t).* += 1;
                    t += 1;
                }

                // Handle remaining items
                while (t < self.size) : (t += 1) {
                    const rr = (self.x_cos_theta[x_idx + t] + self.y_sin_theta[y_idx + t]) >> 16;
                    accumulator.at(@intCast(rr), t).* += 1;
                }
            }
        }
    }

    /// Finds strong lines in the accumulator image using Non-Maximum Suppression.
    /// Returns a slice of lines that must be freed by the caller using `allocator`.
    /// Note: The returned lines (p1, p2) are in the local coordinate system of the `box`
    /// passed to `compute` (i.e., [0, size] x [0, size]).
    pub fn findLines(
        self: Self,
        accumulator: Image(u32),
        threshold: u32,
        angle_nms_thresh: f32, // in degrees
        radius_nms_thresh: f32, // in pixels
        allocator: Allocator,
    ) ![]HoughLine {
        var lines = try std.ArrayList(HoughLine).initCapacity(allocator, 128);
        defer lines.deinit(allocator);

        // 1. Collect all candidates above threshold with 3x3 Non-Maximum Suppression (NMS)
        // We skip the 1-pixel border to simplify neighbor checks.
        if (accumulator.rows < 3 or accumulator.cols < 3) return &[_]HoughLine{};

        for (1..accumulator.rows - 1) |r| {
            for (1..accumulator.cols - 1) |c| {
                const votes = accumulator.at(r, c).*;
                if (votes < threshold) continue;

                // 3x3 local maximum check
                var is_local_max = true;
                check_neighbors: for (r - 1..r + 2) |nr| {
                    for (c - 1..c + 2) |nc| {
                        // Skip self
                        if (nr == r and nc == c) continue;
                        if (accumulator.at(nr, nc).* > votes) {
                            is_local_max = false;
                            break :check_neighbors;
                        }
                    }
                }

                if (is_local_max) {
                    const props = self.getLineProperties(Point(2, f32).init(.{ @as(f32, @floatFromInt(c)), @as(f32, @floatFromInt(r)) }));

                    // Calculate endpoints for the line segment
                    // We define the segment by clipping the line to the box
                    const center_pt = Point(2, f32).init(.{ @as(f32, @floatFromInt(self.size - 1)) / 2.0, @as(f32, @floatFromInt(self.size - 1)) / 2.0 });

                    const theta_rad = props.angle * math.pi / 180.0;
                    const cos_t = @cos(theta_rad);
                    const sin_t = @sin(theta_rad);

                    // Vector along the line direction (-sin, cos)
                    const dir_x = -sin_t;
                    const dir_y = cos_t;

                    // Point on the line closest to center
                    const p_center_x = props.radius * cos_t;
                    const p_center_y = props.radius * sin_t;

                    // Extend far in both directions
                    const huge_dist = @as(f32, @floatFromInt(self.size)) * 2.0;

                    var p1 = Point(2, f32).init(.{
                        center_pt.items[0] + p_center_x + dir_x * huge_dist,
                        center_pt.items[1] + p_center_y + dir_y * huge_dist,
                    });
                    var p2 = Point(2, f32).init(.{
                        center_pt.items[0] + p_center_x - dir_x * huge_dist,
                        center_pt.items[1] + p_center_y - dir_y * huge_dist,
                    });

                    const box_rect = Rectangle(f32){ .l = 0, .t = 0, .r = @floatFromInt(self.size), .b = @floatFromInt(self.size) };
                    clipLine(box_rect, &p1, &p2);

                    try lines.append(allocator, .{
                        .angle = props.angle,
                        .radius = props.radius,
                        .score = votes,
                        .p1 = p1,
                        .p2 = p2,
                    });
                }
            }
        }

        // 2. Sort by score (descending)
        std.mem.sort(HoughLine, lines.items, {}, struct {
            fn lessThan(_: void, a: HoughLine, b: HoughLine) bool {
                return a.score > b.score;
            }
        }.lessThan);

        // 3. Apply NMS
        var final_lines = try std.ArrayList(HoughLine).initCapacity(allocator, lines.items.len);
        // We will return this as a slice, so we don't defer deinit here unless we error.
        errdefer final_lines.deinit(allocator);

        for (lines.items) |candidate| {
            var too_close = false;
            for (final_lines.items) |existing| {
                const da = @abs(existing.angle - candidate.angle);
                const dr = @abs(existing.radius - candidate.radius);

                // Check normal proximity
                if (da < angle_nms_thresh and dr < radius_nms_thresh) {
                    too_close = true;
                    break;
                }

                // Check wrap-around proximity (e.g. 179 deg vs 1 deg)
                if ((180.0 - da) < angle_nms_thresh and @abs(existing.radius + candidate.radius) < radius_nms_thresh) {
                    too_close = true;
                    break;
                }
            }

            if (!too_close) {
                try final_lines.append(allocator, candidate);
            }
        }

        return final_lines.toOwnedSlice(allocator);
    }

    /// Converts a point in Hough space (theta_idx, rho_idx) to physical properties (angle, radius).
    fn getLineProperties(self: Self, p: Point(2, f32)) struct { angle: f32, radius: f32 } {
        const center_val = @as(f32, @floatFromInt(self.size - 1)) / 2.0;
        const sqrt_2 = math.sqrt(2.0);

        const theta_idx = p.items[0];
        const rho_idx = p.items[1];

        // theta_idx corresponds to x in the accumulator
        const theta_offset = theta_idx - center_val;
        // rho_idx corresponds to y in the accumulator
        var radius_offset = rho_idx - center_val;

        const angle = 180.0 * theta_offset / @as(f32, @floatFromInt(self.even_size));
        // Inverse of: radius = radius_real * sqrt_2 + 0.5 + even_size/4 * scale?
        // Wait, looking at dlib:
        // double theta = p.x() - cent.x();
        // radius = p.y() - cent.y();
        // angle = 180 * theta / even_size;
        // radius = radius * sqrt_2 + 0.5; <-- This seems to be converting FROM centered hough coords TO something else?

        // Let's re-read dlib's get_line_properties carefully.
        // It returns radius and angle.
        // It says: radius = (p.y() - cent.y()) * sqrt_2 + 0.5
        // This 'radius' is the distance from the center of the image.

        radius_offset = radius_offset * sqrt_2 + 0.5;

        return .{ .angle = angle, .radius = radius_offset };
    }
};

// Helper function to clip a line segment to a rectangle
fn clipLine(rect: Rectangle(f32), p1: *Point(2, f32), p2: *Point(2, f32)) void {
    // Cohen-Sutherland algorithm or similar could be used.
    // For brevity, using a simplified approach since we know the box is axis aligned.
    // We'll use a standard Liang-Barsky implementation for efficiency.

    var t0: f32 = 0.0;
    var t1: f32 = 1.0;
    const dx = p2.items[0] - p1.items[0];
    const dy = p2.items[1] - p1.items[1];

    const p = [4]f32{ -dx, dx, -dy, dy };
    const q = [4]f32{ p1.items[0] - rect.l, rect.r - p1.items[0], p1.items[1] - rect.t, rect.b - p1.items[1] };

    for (0..4) |i| {
        if (p[i] == 0) {
            if (q[i] < 0) return; // Parallel and outside
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

    if (t0 > t1) return; // Outside

    const new_p1_x = p1.items[0] + t0 * dx;
    const new_p1_y = p1.items[1] + t0 * dy;
    const new_p2_x = p1.items[0] + t1 * dx;
    const new_p2_y = p1.items[1] + t1 * dy;

    p1.items[0] = new_p1_x;
    p1.items[1] = new_p1_y;
    p2.items[0] = new_p2_x;
    p2.items[1] = new_p2_y;
}

test "HoughTransform: detect horizontal line" {
    const allocator = std.testing.allocator;
    const size = 64;

    // 1. Create a black image with a horizontal line
    var edges = try Image(u8).init(allocator, size, size);
    defer edges.deinit(allocator);
    edges.fill(0);

    // Draw horizontal line at row 32
    for (0..size) |c| {
        edges.at(32, c).* = 255;
    }

    // 2. Initialize Hough Transform
    var hough = try HoughTransform.init(allocator, size);
    defer hough.deinit();

    var accumulator = try Image(u32).init(allocator, size, size);
    defer accumulator.deinit(allocator);
    accumulator.fill(0);

    // 3. Compute
    const box = Rectangle(u32){ .l = 0, .t = 0, .r = size, .b = size };
    hough.compute(edges, box, accumulator);

    // 4. Find Lines
    const lines = try hough.findLines(accumulator, 30, 10.0, 5.0, allocator);
    defer allocator.free(lines);

    // 5. Verify
    try std.testing.expect(lines.len >= 1);
    const best_line = lines[0];

    // Horizontal line should have angle near 90 degrees (if theta 0 is vertical) or 0/180
    // dlib logic:
    // theta is angle of normal vector.
    // Horizontal line: normal is vertical (90 deg or 270 deg).
    // Let's check what angle we get.

    // In our coordinate system:
    // theta = 0 -> normal is (1, 0) -> vertical line
    // theta = 90 -> normal is (0, 1) -> horizontal line

    // So we expect angle around 0 (dlib convention shifts theta by 90 degrees).
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), best_line.angle, 2.0);
}
