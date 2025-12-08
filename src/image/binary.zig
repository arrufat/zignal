const std = @import("std");
const Gray = @import("../color.zig").Gray;
const Image = @import("../image.zig").Image;

/// Structuring element used by binary morphology operations.
///
/// The kernel data should contain 0 for "off" and non-zero for "on" pixels.
/// Any non-zero value is treated as 1 (on) in the morphological operations.
pub const Kernel = struct {
    rows: usize,
    cols: usize,
    data: []const u8,

    /// Initialize a kernel with the given dimensions and data.
    /// Requirements:
    /// - rows and cols must be positive and odd (for symmetric anchor point)
    /// - data.len must equal rows * cols
    /// - data values: 0 = off, any non-zero = on
    pub fn init(rows: usize, cols: usize, data: []const u8) Kernel {
        std.debug.assert(rows > 0 and cols > 0);
        std.debug.assert(rows % 2 == 1 and cols % 2 == 1);
        std.debug.assert(data.len == rows * cols);
        return .{ .rows = rows, .cols = cols, .data = data };
    }

    /// Check if a kernel element is "on" (non-zero).
    pub inline fn element(self: Kernel, row: usize, col: usize) bool {
        return self.data[row * self.cols + col] != 0;
    }
};

const Operation = enum { dilate, erode };

pub const Binary = struct {
    pub fn thresholdOtsu(image: Image(u8), _: std.mem.Allocator, out: Image(u8)) !u8 {
        if (image.rows == 0 or image.cols == 0) {
            return 0;
        }

        const hist = image.histogram();
        const total_pixels: f64 = @as(f64, @floatFromInt(image.rows * image.cols));

        var sum_total: f64 = 0;
        for (hist.values, 0..) |count, intensity| {
            sum_total += @as(f64, @floatFromInt(count)) * @as(f64, @floatFromInt(intensity));
        }

        var sum_background: f64 = 0;
        var weight_background: f64 = 0;
        var max_variance: f64 = -1;
        var threshold: u8 = 0;

        for (hist.values, 0..) |count, intensity| {
            weight_background += @as(f64, @floatFromInt(count));
            if (weight_background == 0) continue;

            const weight_foreground = total_pixels - weight_background;
            if (weight_foreground == 0) break;

            sum_background += @as(f64, @floatFromInt(count)) * @as(f64, @floatFromInt(intensity));
            const mean_background = sum_background / weight_background;
            const mean_foreground = (sum_total - sum_background) / weight_foreground;
            const diff = mean_background - mean_foreground;
            const variance = weight_background * weight_foreground * diff * diff;

            if (variance > max_variance) {
                max_variance = variance;
                threshold = @intCast(intensity);
            }
        }

        for (0..image.rows) |r| {
            for (0..image.cols) |c| {
                const src_val = image.at(r, c).*;
                out.at(r, c).* = if (src_val > threshold) 255 else 0;
            }
        }

        return threshold;
    }

    pub fn thresholdAdaptiveMean(
        image: Image(u8),
        allocator: std.mem.Allocator,
        radius: usize,
        c: f32,
        out: Image(u8),
    ) !void {
        if (radius == 0) return error.InvalidRadius;
        if (image.rows == 0 or image.cols == 0) {
            return;
        }

        var planes = Image(u8).Integral.Planes.init();
        defer planes.deinit(allocator);
        try Image(u8).Integral.compute(image, allocator, &planes);
        const sat = planes.planes[0];

        const rows = image.rows;
        const cols = image.cols;

        for (0..rows) |row| {
            const r1 = row -| radius;
            const r2 = @min(row + radius, rows - 1);
            for (0..cols) |col| {
                const c1 = col -| radius;
                const c2 = @min(col + radius, cols - 1);
                const area = @as(f32, @floatFromInt((r2 - r1 + 1) * (c2 - c1 + 1)));
                const sum = Image(u8).Integral.sum(sat, r1, c1, r2, c2);
                const mean = sum / area;
                const src_val = @as(f32, @floatFromInt(image.at(row, col).*));
                out.at(row, col).* = if (src_val > mean - c) 255 else 0;
            }
        }
    }

    pub fn dilate(
        image: Image(u8),
        allocator: std.mem.Allocator,
        kernel: Kernel,
        iterations: usize,
        out: Image(u8),
    ) !void {
        try morph(image, allocator, kernel, iterations, out, .dilate);
    }

    pub fn erode(
        image: Image(u8),
        allocator: std.mem.Allocator,
        kernel: Kernel,
        iterations: usize,
        out: Image(u8),
    ) !void {
        try morph(image, allocator, kernel, iterations, out, .erode);
    }

    pub fn open(
        image: Image(u8),
        allocator: std.mem.Allocator,
        kernel: Kernel,
        iterations: usize,
        out: Image(u8),
    ) !void {
        try morphComposite(image, allocator, kernel, iterations, out, .erode, .dilate);
    }

    pub fn close(
        image: Image(u8),
        allocator: std.mem.Allocator,
        kernel: Kernel,
        iterations: usize,
        out: Image(u8),
    ) !void {
        try morphComposite(image, allocator, kernel, iterations, out, .dilate, .erode);
    }

    fn morphComposite(
        image: Image(u8),
        allocator: std.mem.Allocator,
        kernel: Kernel,
        iterations: usize,
        out: Image(u8),
        first_op: Operation,
        second_op: Operation,
    ) !void {
        if (iterations == 0) {
            image.copy(out);
            return;
        }

        var temp = try Image(u8).initLike(allocator, image);
        defer temp.deinit(allocator);

        try morph(image, allocator, kernel, iterations, temp, first_op);
        try morph(temp, allocator, kernel, iterations, out, second_op);
    }

    fn morph(
        image: Image(u8),
        allocator: std.mem.Allocator,
        kernel: Kernel,
        iterations: usize,
        out: Image(u8),
        op: Operation,
    ) !void {
        if (image.rows == 0 or image.cols == 0) {
            return;
        }

        if (iterations == 0) {
            image.copy(out);
            return;
        }

        const alias = out.isAliased(image);

        var source = image;
        var owned_source: ?Image(u8) = null;
        defer if (owned_source) |*s| s.deinit(allocator);

        // If input aliases output, we need a copy
        if (alias) {
            owned_source = try image.dupe(allocator);
            source = owned_source.?;
        }

        if (iterations == 1) {
            // Single iteration: source -> out
            applyMorph(source, out, kernel, op);
        } else {
            // Multiple iterations: ping-pong between temp and out
            var temp = try Image(u8).initLike(allocator, image);
            defer temp.deinit(allocator);

            // Perform iterations, alternating buffers
            for (0..iterations) |i| {
                const src = if (i == 0) source else if (i % 2 == 1) temp else out;
                const dst = if (i % 2 == 0) temp else out;
                applyMorph(src, dst, kernel, op);
            }

            // If final result is in temp, copy to out
            if (iterations % 2 == 1) {
                temp.copy(out);
            }
        }
    }

    fn applyMorph(src: Image(u8), dst: Image(u8), kernel: Kernel, op: Operation) void {
        const rows = src.rows;
        const cols = src.cols;
        const anchor_r: isize = @intCast(kernel.rows / 2);
        const anchor_c: isize = @intCast(kernel.cols / 2);

        for (0..rows) |r_usize| {
            const r: isize = @intCast(r_usize);
            for (0..cols) |c_usize| {
                const c: isize = @intCast(c_usize);
                var value: u8 = switch (op) {
                    .dilate => 0,
                    .erode => 255,
                };

                outer: for (0..kernel.rows) |kr| {
                    const kr_isize: isize = @intCast(kr);
                    const sample_r = r + kr_isize - anchor_r;

                    for (0..kernel.cols) |kc| {
                        if (!kernel.element(kr, kc)) continue;

                        const kc_isize: isize = @intCast(kc);
                        const sample_c = c + kc_isize - anchor_c;

                        const sample = src.atOrNull(sample_r, sample_c);

                        switch (op) {
                            .dilate => {
                                if (sample) |ptr| {
                                    if (ptr.* != 0) {
                                        value = 255;
                                        break :outer;
                                    }
                                }
                            },
                            .erode => {
                                // Treat out-of-bounds or background pixels as erosion
                                if (sample == null or sample.?.* == 0) {
                                    value = 0;
                                    break :outer;
                                }
                            },
                        }
                    }
                }

                dst.at(r_usize, c_usize).* = value;
            }
        }
    }
};
