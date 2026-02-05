//! Vectorization module for converting raster edge maps into geometric paths.
//!
//! This module provides functionality to trace connected pixels in a binary image
//! and convert them into ordered lists of points (polylines). It includes:
//! - **Tracing**: Converting raster edges to vector paths using neighbor chaining.
//! - **Simplification**: Reducing point count using the Ramer-Douglas-Peucker algorithm.
//! - **Noise Filtering**: Removing paths that are too short to be significant.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Image = @import("../image.zig").Image;
const Point = @import("../geometry/Point.zig").Point;

pub const Tracer = struct {
    allocator: Allocator,

    /// Minimum length (in pixels) for a path to be kept.
    min_path_length: usize = 5,

    /// Epsilon for Ramer-Douglas-Peucker simplification.
    /// Higher values = fewer points/straighter lines. 0 = no simplification.
    simplification_epsilon: f32 = 1.0,

    pub const Path = ArrayList(Point(2, f32));
    pub const PathList = ArrayList(Path);

    /// Initializes a new Tracer instance.
    pub fn init(allocator: Allocator, options: struct {
        min_path_length: usize = 5,
        simplification_epsilon: f32 = 1.0,
    }) Tracer {
        return .{
            .allocator = allocator,
            .min_path_length = options.min_path_length,
            .simplification_epsilon = options.simplification_epsilon,
        };
    }

    /// Traces connected components in a binary edge image.
    /// Input `edges` should be a u8 image where > 0 indicates an edge.
    /// Returns a list of paths, where each path is a list of Points.
    /// Caller owns the returned memory (must deinit the list and each path).
    pub fn trace(self: Tracer, edges: Image(u8)) !PathList {
        var paths: PathList = .empty;
        errdefer {
            for (paths.items) |*p| p.deinit(self.allocator);
            paths.deinit(self.allocator);
        }

        // Keep track of visited pixels to avoid infinite loops and duplicate paths
        var visited = try Image(u8).init(self.allocator, edges.rows, edges.cols);
        defer visited.deinit(self.allocator);
        @memset(visited.data, 0);

        for (0..edges.rows) |r| {
            for (0..edges.cols) |c| {
                // Find a starting point: an unvisited edge pixel
                if (edges.at(r, c).* > 0 and visited.at(r, c).* == 0) {
                    var raw_path = try self.followPath(edges, &visited, r, c);

                    if (raw_path.items.len >= self.min_path_length) {
                        if (self.simplification_epsilon > 0) {
                            const simplified = try self.simplifyPath(raw_path.items);
                            raw_path.deinit(self.allocator);
                            try paths.append(self.allocator, simplified);
                        } else {
                            try paths.append(self.allocator, raw_path);
                        }
                    } else {
                        raw_path.deinit(self.allocator);
                    }
                }
            }
        }

        return paths;
    }

    /// Greedily follows connected neighbors.
    /// Note: This is a simple chain tracer. Complex junctions might split paths arbitrarily.
    fn followPath(self: Tracer, edges: Image(u8), visited: *Image(u8), start_r: usize, start_c: usize) !Path {
        var path: Path = .empty;
        var curr_r = start_r;
        var curr_c = start_c;

        // Add start point
        try path.append(self.allocator, Point(2, f32).init(.{ @as(f32, @floatFromInt(curr_c)), @as(f32, @floatFromInt(curr_r)) }));
        visited.at(curr_r, curr_c).* = 1;

        // Neighbor offsets (8-connectivity)
        const offsets = [_][2]isize{
            .{ -1, -1 }, .{ -1, 0 }, .{ -1, 1 },
            .{ 0, -1 },  .{ 0, 1 },  .{ 1, -1 },
            .{ 1, 0 },   .{ 1, 1 },
        };

        while (true) {
            var found_next = false;

            for (offsets) |offset| {
                const next_r_i = @as(isize, @intCast(curr_r)) + offset[0];
                const next_c_i = @as(isize, @intCast(curr_c)) + offset[1];

                if (next_r_i >= 0 and next_r_i < edges.rows and
                    next_c_i >= 0 and next_c_i < edges.cols)
                {
                    const next_r: usize = @intCast(next_r_i);
                    const next_c: usize = @intCast(next_c_i);

                    // Check if it's an edge and not visited
                    if (edges.at(next_r, next_c).* > 0 and visited.at(next_r, next_c).* == 0) {
                        curr_r = next_r;
                        curr_c = next_c;
                        try path.append(self.allocator, Point(2, f32).init(.{ @as(f32, @floatFromInt(curr_c)), @as(f32, @floatFromInt(curr_r)) }));
                        visited.at(curr_r, curr_c).* = 1;
                        found_next = true;
                        break; // Greedy: take the first valid neighbor found
                    }
                }
            }

            if (!found_next) break;
        }

        return path;
    }

    /// Simplifies a path using the Ramer-Douglas-Peucker algorithm.
    fn simplifyPath(self: Tracer, points: []const Point(2, f32)) !Path {
        if (points.len < 3) {
            var new_path = try Path.initCapacity(self.allocator, points.len);
            try new_path.appendSlice(self.allocator, points);
            return new_path;
        }

        // Track which points to keep
        var keep = try self.allocator.alloc(bool, points.len);
        defer self.allocator.free(keep);
        @memset(keep, false);

        keep[0] = true;
        keep[points.len - 1] = true;

        self.douglasPeucker(points, keep, 0, points.len - 1);

        // Build the final path
        var simplified: Path = .empty;
        for (points, 0..) |p, i| {
            if (keep[i]) {
                try simplified.append(self.allocator, p);
            }
        }
        return simplified;
    }

    /// Recursive step of RDP.
    /// Finds the point furthest from the line segment (start, end).
    /// If distance > epsilon, split and recurse.
    fn douglasPeucker(self: Tracer, points: []const Point(2, f32), keep: []bool, start_idx: usize, end_idx: usize) void {
        if (end_idx <= start_idx + 1) return;

        const first = points[start_idx];
        const last = points[end_idx];

        var max_dist: f32 = 0;
        var index: usize = 0;

        // Find point with maximum perpendicular distance
        var i: usize = start_idx + 1;
        while (i < end_idx) : (i += 1) {
            const d = perpendicularDistance(points[i], first, last);
            if (d > max_dist) {
                max_dist = d;
                index = i;
            }
        }

        if (max_dist > self.simplification_epsilon) {
            keep[index] = true;
            self.douglasPeucker(points, keep, start_idx, index);
            self.douglasPeucker(points, keep, index, end_idx);
        }
    }
};

/// Computes the perpendicular distance from point P to the line segment AB.
fn perpendicularDistance(p: Point(2, f32), a: Point(2, f32), b: Point(2, f32)) f32 {
    const ab = b.sub(a);
    const ap = p.sub(a);

    const ab_len_sq = ab.normSquared();

    if (ab_len_sq == 0) {
        return ap.norm();
    }

    // Project AP onto AB to find the parameter t
    // t = (AP . AB) / |AB|^2
    const t = ap.dot(ab) / ab_len_sq;

    if (t < 0.0) {
        return ap.norm(); // Closest point is A
    } else if (t > 1.0) {
        return p.sub(b).norm(); // Closest point is B
    }

    // Closest point is on the segment
    const projection = a.add(ab.scale(t));
    return p.sub(projection).norm();
}
