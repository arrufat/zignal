const std = @import("std");

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
    pub fn init(rows: usize, cols: usize, data: []const u8) !Kernel {
        if (rows == 0 or cols == 0) return error.InvalidKernelSize;
        if (rows % 2 == 0 or cols % 2 == 0) return error.InvalidKernelSize;
        if (data.len != rows * cols) return error.InvalidKernelSize;
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
            const count_f: f64 = @floatFromInt(count);
            weight_background += count_f;
            if (weight_background == 0) continue;

            const weight_foreground = total_pixels - weight_background;
            if (weight_foreground == 0) break;

            sum_background += count_f * @as(f64, @floatFromInt(intensity));
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

        var mean = try Image(u8).initLike(allocator, image);
        defer mean.deinit(allocator);
        try image.boxBlur(allocator, @intCast(radius), mean);

        for (0..image.rows) |row| {
            for (0..image.cols) |col| {
                const src_val: f32 = @floatFromInt(image.at(row, col).*);
                const mean_val: f32 = @floatFromInt(mean.at(row, col).*);
                out.at(row, col).* = if (src_val > mean_val - c) 255 else 0;
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
        comptime first_op: Operation,
        comptime second_op: Operation,
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
        comptime op: Operation,
    ) !void {
        if (image.rows == 0 or image.cols == 0) {
            return;
        }

        if (iterations == 0) {
            image.copy(out);
            return;
        }

        var source = image;
        var owned_source: ?Image(u8) = null;
        defer if (owned_source) |*s| s.deinit(allocator);

        if (out.isAliased(image)) {
            owned_source = try image.dupe(allocator);
            source = owned_source.?;
        }

        if (iterations == 1) {
            applyMorph(source, out, kernel, op);
            return;
        }

        var temp = try Image(u8).initLike(allocator, image);
        defer temp.deinit(allocator);

        // Pick parity so the final iteration writes directly into `out`,
        // avoiding a trailing temp->out copy.
        var current_src = source;
        for (0..iterations) |i| {
            const remaining = iterations - 1 - i;
            const dst = if (remaining % 2 == 0) out else temp;
            applyMorph(current_src, dst, kernel, op);
            current_src = dst;
        }
    }

    fn applyMorph(src: Image(u8), dst: Image(u8), kernel: Kernel, comptime op: Operation) void {
        const rows = src.rows;
        const cols = src.cols;
        const anchor_r: i32 = @intCast(kernel.rows / 2);
        const anchor_c: i32 = @intCast(kernel.cols / 2);

        for (0..rows) |r_usize| {
            const r: i32 = @intCast(r_usize);
            for (0..cols) |c_usize| {
                const c: i32 = @intCast(c_usize);
                var value: u8 = switch (op) {
                    .dilate => 0,
                    .erode => 255,
                };

                outer: for (0..kernel.rows) |kr| {
                    const ikr: i32 = @intCast(kr);
                    const sample_r = r + ikr - anchor_r;

                    for (0..kernel.cols) |kc| {
                        if (!kernel.element(kr, kc)) continue;

                        const ikc: i32 = @intCast(kc);
                        const sample_c = c + ikc - anchor_c;

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
                                // OOB samples are treated as background, so any miss erodes the pixel.
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
