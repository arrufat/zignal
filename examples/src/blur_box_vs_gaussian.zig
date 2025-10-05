//! Compare Gaussian blur with repeated box blurs and report PSNR and runtime metrics.

const std = @import("std");
const zignal = @import("zignal");

const Image = zignal.Image;
const Canvas = zignal.Canvas;
const RunningStats = zignal.RunningStats;

fn buildBenchmarkScene(image: Image(u8), allocator: std.mem.Allocator) void {
    const rows = image.rows;
    const cols = image.cols;

    // Create a smooth gradient background (easier for blur comparison)
    const rows_f = if (rows > 1) @as(f64, @floatFromInt(rows - 1)) else 1.0;
    const cols_f = if (cols > 1) @as(f64, @floatFromInt(cols - 1)) else 1.0;

    for (0..rows) |r| {
        const row_norm = @as(f64, @floatFromInt(r)) / rows_f;
        for (0..cols) |c| {
            const col_norm = @as(f64, @floatFromInt(c)) / cols_f;
            // Simple radial gradient from center
            const dx = col_norm - 0.5;
            const dy = row_norm - 0.5;
            const dist = @sqrt(dx * dx + dy * dy);
            const value = 0.3 + 0.4 * (1.0 - @min(dist * 2.0, 1.0));
            const clamped = std.math.clamp(value, 0.0, 1.0);
            image.data[r * image.stride + c] = @as(u8, @intFromFloat(clamped * 255.0));
        }
    }

    // Draw simple shapes to test blur quality
    var canvas = Canvas(u8).init(allocator, image);
    const point = zignal.Point(2, f32).init;
    const cols_f32 = @as(f32, @floatFromInt(cols));
    const rows_f32 = @as(f32, @floatFromInt(rows));
    const center = point(.{
        cols_f32 / 2.0,
        rows_f32 / 2.0,
    });

    const min_dim = @as(f32, @floatFromInt(@min(rows, cols)));

    // Central filled circle with soft edge
    canvas.fillCircle(center, min_dim * 0.25, @as(u8, 220), .soft);

    // A few smaller circles at corners for edge testing
    canvas.fillCircle(point(.{ min_dim * 0.2, min_dim * 0.2 }), min_dim * 0.08, @as(u8, 200), .soft);
    canvas.fillCircle(point(.{ cols_f32 - min_dim * 0.2, min_dim * 0.2 }), min_dim * 0.08, @as(u8, 180), .soft);
    canvas.fillCircle(point(.{ min_dim * 0.2, rows_f32 - min_dim * 0.2 }), min_dim * 0.08, @as(u8, 160), .soft);
    canvas.fillCircle(point(.{ cols_f32 - min_dim * 0.2, rows_f32 - min_dim * 0.2 }), min_dim * 0.08, @as(u8, 140), .soft);

    // Single rectangle for edge testing
    const rect = zignal.Rectangle(f32).init(
        cols_f32 * 0.3,
        rows_f32 * 0.6,
        cols_f32 * 0.7,
        rows_f32 * 0.8,
    );
    canvas.fillRectangle(rect, @as(u8, 80), .soft);
}

fn formatWidths(widths: []const usize, buffer: []u8) ![]const u8 {
    if (buffer.len == 0) return error.BufferTooSmall;
    var index: usize = 0;
    buffer[index] = '[';
    index += 1;

    for (widths, 0..) |width, idx| {
        if (idx != 0) {
            if (index + 2 > buffer.len) return error.BufferTooSmall;
            buffer[index] = ',';
            buffer[index + 1] = ' ';
            index += 2;
        }

        const written = try std.fmt.bufPrint(buffer[index..], "{d}", .{width});
        index += written.len;
    }

    if (index >= buffer.len) return error.BufferTooSmall;
    buffer[index] = ']';
    index += 1;
    return buffer[0..index];
}

/// Calculate box widths for n passes to approximate Gaussian blur with given sigma.
/// Based on: https://peterkovesi.com/papers/FastGaussianSmoothing.pdf
/// Formula: w_ideal = sqrt((12*σ²/n) + 1)
fn boxesForGaussian(sigma: f32, passes: usize, buffer: []usize) ![]usize {
    if (passes == 0 or buffer.len < passes) return error.InvalidPassCount;

    const sigma64: f64 = @floatCast(sigma);
    const n: f64 = @floatFromInt(passes);
    const sigma_sq = sigma64 * sigma64;

    // Calculate ideal box width
    const w_ideal = @sqrt((12.0 * sigma_sq / n) + 1.0);
    var wl = @floor(w_ideal);

    // Make wl odd
    const wl_int_even_check: i64 = @intFromFloat(wl);
    if (@mod(wl_int_even_check, @as(i64, 2)) == 0) {
        wl -= 1.0;
    }
    if (wl < 1.0) wl = 1.0;

    const wu = wl + 2.0;

    // Calculate how many passes should use wl vs wu
    const numerator = 12.0 * sigma_sq - n * wl * wl - 4.0 * n * wl - 3.0 * n;
    const denominator = -4.0 * wl - 4.0;
    var m = std.math.round(numerator / denominator);

    if (!std.math.isFinite(m)) {
        m = 0;
    }

    var m_int: isize = @intFromFloat(m);
    if (m_int < 0) m_int = 0;
    if (m_int > passes) m_int = @intCast(passes);

    const wl_int = @max(@as(isize, 1), @as(isize, @intFromFloat(wl)));
    const wu_int = @max(@as(isize, 1), @as(isize, @intFromFloat(wu)));

    // First m passes use wl, remaining passes use wu
    for (0..passes) |i| {
        buffer[i] = @intCast(if (@as(isize, @intCast(i)) < m_int) wl_int else wu_int);
    }

    return buffer[0..passes];
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const size: usize = 512;
    var original = try Image(u8).init(allocator, size, size);
    defer original.deinit(allocator);
    original.fill(0);
    buildBenchmarkScene(original, allocator);

    try original.save(allocator, "blur_original.png");

    const sigma: f32 = 5.0;
    var gaussian = try Image(u8).initLike(allocator, original);
    defer gaussian.deinit(allocator);

    var timer = try std.time.Timer.start();
    try original.gaussianBlur(allocator, sigma, gaussian);
    const gaussian_ns = timer.read();
    try gaussian.save(allocator, "blur_gaussian.png");

    std.debug.print("Gaussian blur sigma={d:.1} took {d:.3} ms\n\n", .{ sigma, @as(f64, @floatFromInt(gaussian_ns)) / std.time.ns_per_ms });
    std.debug.print("Box blur approximations using formula: w_ideal = sqrt((12*σ²/n) + 1)\n", .{});
    std.debug.print("{s:^6} | {s:^15} | {s:^13} | {s:^9} | {s:^9} | {s:^7} | {s:^10}\n", .{
        "passes",
        "widths",
        "box time (ms)",
        "speedup",
        "PSNR (dB)",
        "SSIM",
        "Avg Error",
    });
    std.debug.print("{s:-<6}-+-{s:-<15}-+-{s:-<13}-+-{s:-<9}-+-{s:-<9}-+-{s:-<7}-+-{s:-<10}\n", .{ "", "", "", "", "", "", "" });

    var temp_a = try Image(u8).initLike(allocator, original);
    defer temp_a.deinit(allocator);
    var temp_b = try Image(u8).initLike(allocator, original);
    defer temp_b.deinit(allocator);

    const pass_counts = [_]usize{ 1, 2, 3, 4, 5 };

    for (pass_counts) |passes| {
        var widths_storage: [pass_counts.len]usize = undefined;
        const widths = try boxesForGaussian(sigma, passes, widths_storage[0..passes]);

        // Apply box blur passes
        var box_timer = try std.time.Timer.start();
        var source: *const Image(u8) = &original;
        var scratch = [_]*Image(u8){ &temp_a, &temp_b };
        var scratch_index: usize = 0;
        var last_result: *Image(u8) = &temp_a;

        for (widths) |width| {
            std.debug.assert(width >= 1 and (width % 2 == 1));
            const radius = (width - 1) / 2;
            const dst = scratch[scratch_index];
            scratch_index = (scratch_index + 1) % scratch.len;
            try source.boxBlur(allocator, radius, dst.*);
            source = dst;
            last_result = dst;
        }

        const box_ns = box_timer.read();
        const speedup = @as(f64, @floatFromInt(gaussian_ns)) / @as(f64, @floatFromInt(box_ns));
        const psnr = try gaussian.psnr(last_result.*);
        const ssim_value = try gaussian.ssim(last_result.*);

        // Calculate average error per pixel as percentage (like the blog post)
        var error_stats: RunningStats(f64) = .init();
        for (0..gaussian.rows) |r| {
            for (0..gaussian.cols) |c| {
                const g_val: f64 = @floatFromInt(gaussian.at(r, c).*);
                const b_val: f64 = @floatFromInt(last_result.at(r, c).*);
                error_stats.add(@abs(g_val - b_val));
            }
        }
        const avg_error = error_stats.mean() / 255.0 * 100.0;

        var widths_buf: [64]u8 = undefined;
        const widths_text = try formatWidths(widths, &widths_buf);

        var name_buf: [48]u8 = undefined;
        const output_name = try std.fmt.bufPrint(&name_buf, "blur_box_pass_{d}.png", .{passes});
        try last_result.save(allocator, output_name);

        std.debug.print(
            "{d:>6} | {s:>15} | {d:>13.3} | {d:>8.2}x | {d:>9.2} | {d:>7.4} | {d:>8.2}%\n",
            .{ passes, widths_text, @as(f64, @floatFromInt(box_ns)) / std.time.ns_per_ms, speedup, psnr, ssim_value, avg_error },
        );
    }

    std.debug.print("\nNote: The formula optimizes box widths for each pass count independently.\n", .{});
    std.debug.print("SSIM ranges from 0-1 (higher is better). Avg Error % (lower is better).\n", .{});
    std.debug.print("For best Gaussian approximation, use 3 passes (recommended by literature).\n", .{});
}
