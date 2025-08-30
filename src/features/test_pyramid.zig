const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

// Simplified Image type for testing
pub fn Image(comptime T: type) type {
    return struct {
        const Self = @This();
        rows: usize,
        cols: usize,
        data: []T,
        stride: usize,

        pub const empty: Self = .{ .rows = 0, .cols = 0, .data = undefined, .stride = 0 };

        pub fn initAlloc(allocator: Allocator, rows: usize, cols: usize) !Self {
            return .{
                .rows = rows,
                .cols = cols,
                .data = try allocator.alloc(T, rows * cols),
                .stride = cols,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.data);
            self.rows = 0;
            self.cols = 0;
        }

        pub fn at(self: Self, row: usize, col: usize) *T {
            return &self.data[row * self.stride + col];
        }

        pub fn isView(self: Self) bool {
            return self.stride != self.cols;
        }

        // Simple resize using nearest neighbor for testing
        pub fn resize(self: Self, allocator: Allocator, out: Self, method: Interpolation) !void {
            _ = allocator;
            _ = method;

            const x_scale = @as(f32, @floatFromInt(self.cols)) / @as(f32, @floatFromInt(out.cols));
            const y_scale = @as(f32, @floatFromInt(self.rows)) / @as(f32, @floatFromInt(out.rows));

            for (0..out.rows) |r| {
                for (0..out.cols) |c| {
                    const src_r = @min(self.rows - 1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(r)) * y_scale)));
                    const src_c = @min(self.cols - 1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(c)) * x_scale)));
                    out.at(r, c).* = self.at(src_r, src_c).*;
                }
            }
        }
    };
}

// Minimal interpolation support
pub const Interpolation = enum {
    nearest_neighbor,
    bilinear,
};

// Simplified Filter for testing
pub fn Filter(comptime T: type) type {
    return struct {
        pub fn boxBlur(self: Image(T), allocator: Allocator, blurred: *Image(T), radius: usize) !void {
            _ = radius;
            if (blurred.rows == 0) {
                blurred.* = try Image(T).init(allocator, self.rows, self.cols);
            }

            // Simple box blur (just copy for testing)
            for (0..self.rows) |r| {
                for (0..self.cols) |c| {
                    blurred.at(r, c).* = self.at(r, c).*;
                }
            }
        }
    };
}

// Image Pyramid implementation
pub fn ImagePyramid(comptime T: type) type {
    return struct {
        const Self = @This();

        levels: []Image(T),
        scale_factor: f32,
        n_levels: u8,
        blur_sigma: f32,
        allocator: Allocator,

        pub fn build(
            allocator: Allocator,
            source: Image(T),
            n_levels: u8,
            scale_factor: f32,
            blur_sigma: f32,
        ) !Self {
            assert(n_levels > 0);
            assert(scale_factor > 1.0);
            assert(blur_sigma > 0);

            var levels = try allocator.alloc(Image(T), n_levels);
            errdefer {
                for (levels[0..], 0..) |*level, i| {
                    if (i > 0 and level.rows > 0) {
                        level.deinit(allocator);
                    }
                }
                allocator.free(levels);
            }

            levels[0] = source;

            for (1..n_levels) |i| {
                const prev_level = levels[i - 1];
                const scale = std.math.pow(f32, scale_factor, @as(f32, @floatFromInt(i)));
                const new_rows = @max(1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(source.rows)) / scale)));
                const new_cols = @max(1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(source.cols)) / scale)));

                if (new_rows < 8 or new_cols < 8) {
                    const actual_levels = try allocator.realloc(levels, i);
                    return .{
                        .levels = actual_levels,
                        .scale_factor = scale_factor,
                        .n_levels = @intCast(i),
                        .blur_sigma = blur_sigma,
                        .allocator = allocator,
                    };
                }

                // Simple blur for testing
                var blurred: Image(T) = .empty;
                defer if (blurred.rows > 0) blurred.deinit(allocator);

                const radius = @as(usize, @intFromFloat(blur_sigma * 2));
                try Filter(T).boxBlur(prev_level, allocator, &blurred, radius);

                levels[i] = try Image(T).init(allocator, new_rows, new_cols);

                const blur_to_use = if (blurred.rows > 0) blurred else prev_level;
                try blur_to_use.resize(allocator, levels[i], .bilinear);
            }

            return .{
                .levels = levels,
                .scale_factor = scale_factor,
                .n_levels = n_levels,
                .blur_sigma = blur_sigma,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.levels[1..]) |*level| {
                level.deinit(self.allocator);
            }
            self.allocator.free(self.levels);
        }

        pub fn getScale(self: Self, level: u8) f32 {
            assert(level < self.n_levels);
            return std.math.pow(f32, self.scale_factor, @as(f32, @floatFromInt(level)));
        }
    };
}

// Tests
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

test "ImagePyramid construction and scaling" {
    const allocator = std.testing.allocator;

    var image = try Image(u8).init(allocator, 640, 480);
    defer image.deinit(allocator);

    // Fill with test pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = @intCast((r + c) % 256);
        }
    }

    var pyramid = try ImagePyramid(u8).build(allocator, image, 5, 1.5, 1.0);
    defer pyramid.deinit();

    try expectEqual(@as(u8, 5), pyramid.n_levels);
    try expectEqual(@as(f32, 1.5), pyramid.scale_factor);

    // Check dimensions decrease
    for (1..pyramid.n_levels) |i| {
        const level = pyramid.levels[i];
        const prev_level = pyramid.levels[i - 1];

        try expectEqual(true, level.rows < prev_level.rows);
        try expectEqual(true, level.cols < prev_level.cols);

        // Check approximate scaling
        const expected_scale = pyramid.getScale(@intCast(i));
        const actual_row_scale = @as(f32, @floatFromInt(image.rows)) / @as(f32, @floatFromInt(level.rows));
        const actual_col_scale = @as(f32, @floatFromInt(image.cols)) / @as(f32, @floatFromInt(level.cols));

        // Should be approximately correct (within rounding)
        try expectApproxEqAbs(expected_scale, actual_row_scale, 1.0);
        try expectApproxEqAbs(expected_scale, actual_col_scale, 1.0);
    }
}
