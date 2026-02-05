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

const geometry = @import("../geometry.zig");
const Point = geometry.Point;
const Image = @import("../image.zig").Image;

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
        var visited: Image(u8) = try .init(self.allocator, edges.rows, edges.cols);
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

    /// Pre-calculated neighbor offsets and normalized direction vectors.
    const Neighbor = struct {
        offset: [2]isize,
        dir: Point(2, f32),
    };

    const neighbors: [8]Neighbor = blk: {
        var n: [8]Neighbor = undefined;
        const offsets = [_][2]isize{
            .{ -1, -1 }, .{ -1, 0 }, .{ -1, 1 },
            .{ 0, -1 },  .{ 0, 1 },  .{ 1, -1 },
            .{ 1, 0 },   .{ 1, 1 },
        };
        for (offsets, 0..) |off, i| {
            const dx = @as(f32, @floatFromInt(off[1]));
            const dy = @as(f32, @floatFromInt(off[0]));
            const len = @sqrt(dx * dx + dy * dy);
            n[i] = .{
                .offset = off,
                .dir = Point(2, f32).init(.{ dx / len, dy / len }),
            };
        }
        break :blk n;
    };

    /// Follows connected neighbors, preferring those that maintain the current direction (inertia).
    /// This prevents sharp 90-degree turns at junctions when a straight path is available.
    fn followPath(self: Tracer, edges: Image(u8), visited: *Image(u8), start_r: usize, start_c: usize) !Path {
        var path: Path = .empty;
        var curr_r = start_r;
        var curr_c = start_c;

        // Add start point
        try path.append(self.allocator, .init(.{ @as(f32, @floatFromInt(curr_c)), @as(f32, @floatFromInt(curr_r)) }));
        visited.at(curr_r, curr_c).* = 1;

        while (true) {
            var best_r: ?usize = null;
            var best_c: ?usize = null;
            var best_score: f32 = -2.0;

            // Determine current direction if we have history
            var prev_dir: Point(2, f32) = Point(2, f32).origin;
            const has_history = path.items.len >= 2;

            if (has_history) {
                const p_curr = path.items[path.items.len - 1];
                const p_prev = path.items[path.items.len - 2];
                prev_dir = p_curr.sub(p_prev).normalize();
            }

            // Check all neighbors
            for (neighbors) |n| {
                const next_r_i = @as(isize, @intCast(curr_r)) + n.offset[0];
                const next_c_i = @as(isize, @intCast(curr_c)) + n.offset[1];

                if (next_r_i >= 0 and next_r_i < edges.rows and
                    next_c_i >= 0 and next_c_i < edges.cols)
                {
                    const next_r: usize = @intCast(next_r_i);
                    const next_c: usize = @intCast(next_c_i);

                    if (edges.at(next_r, next_c).* > 0 and visited.at(next_r, next_c).* == 0) {
                        if (!has_history) {
                            best_r = next_r;
                            best_c = next_c;
                            break;
                        }

                        // Calculate direction score: dot product of (prev_dir) . (candidate_dir)
                        const score = prev_dir.dot(n.dir);

                        if (score > best_score) {
                            best_score = score;
                            best_r = next_r;
                            best_c = next_c;
                        }
                    }
                }
            }

            if (best_r) |r| {
                const c = best_c.?;
                curr_r = r;
                curr_c = c;
                try path.append(self.allocator, .init(.{ @as(f32, @floatFromInt(curr_c)), @as(f32, @floatFromInt(curr_r)) }));
                visited.at(curr_r, curr_c).* = 1;
            } else break;
        }

        return path;
    }

    /// Simplifies a path using the Ramer-Douglas-Peucker algorithm.
    fn simplifyPath(self: Tracer, points: []const Point(2, f32)) !Path {
        if (points.len < 3) {
            var new_path: Path = try .initCapacity(self.allocator, points.len);
            try new_path.appendSlice(self.allocator, points);
            return new_path;
        }

        // Track which points to keep
        var keep = try self.allocator.alloc(bool, points.len);
        defer self.allocator.free(keep);
        @memset(keep, false);

        keep[0] = true;
        keep[points.len - 1] = true;

        try self.douglasPeucker(points, keep, 0, points.len - 1);

        // Build the final path
        var simplified: Path = .empty;
        for (points, 0..) |p, i| {
            if (keep[i]) {
                try simplified.append(self.allocator, p);
            }
        }
        return simplified;
    }

    /// Iterative RDP implementation using an explicit stack to avoid recursion depth limits.
    fn douglasPeucker(self: Tracer, points: []const Point(2, f32), keep: []bool, start_idx: usize, end_idx: usize) !void {
        const Range = struct { start: usize, end: usize };
        var stack: ArrayList(Range) = .empty;
        defer stack.deinit(self.allocator);

        try stack.append(self.allocator, .{ .start = start_idx, .end = end_idx });

        while (stack.pop()) |range| {
            if (range.end <= range.start + 1) continue;

            const first = points[range.start];
            const last = points[range.end];

            var max_dist: f32 = 0;
            var index: usize = 0;

            // Find point with maximum perpendicular distance
            var i: usize = range.start + 1;
            while (i < range.end) : (i += 1) {
                const d = points[i].distanceToSegment(first, last);
                if (d > max_dist) {
                    max_dist = d;
                    index = i;
                }
            }

            if (max_dist > self.simplification_epsilon) {
                keep[index] = true;
                try stack.append(self.allocator, .{ .start = range.start, .end = index });
                try stack.append(self.allocator, .{ .start = index, .end = range.end });
            }
        }
    }
};
