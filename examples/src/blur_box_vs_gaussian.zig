//! Compare Gaussian blur with repeated box blurs and report PSNR and runtime metrics.

const std = @import("std");
const zignal = @import("zignal");

const Gray = zignal.Gray(u8);
const Image = zignal.Image(Gray);

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

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();

    var original: Image = try .load(init.io, init.gpa, if (args.next()) |arg| arg else "../assets/liza.jpg");
    defer original.deinit(init.gpa);
    const sigma: f32 = if (args.next()) |arg| std.fmt.parseFloat(f32, arg) catch 1.0 else 1.0;

    try original.save(init.io, init.gpa, "blur_original.png");

    var gaussian: Image = try .initLike(init.gpa, original);
    defer gaussian.deinit(init.gpa);

    var timer = try std.time.Timer.start();
    try original.gaussianBlur(init.gpa, sigma, gaussian);
    const gaussian_ns = timer.read();
    try gaussian.save(init.io, init.gpa, "blur_gaussian.png");

    std.debug.print("Gaussian blur sigma={d:.1} took {d:.3} ms\n\n", .{ sigma, @as(f64, @floatFromInt(gaussian_ns)) / std.time.ns_per_ms });
    std.debug.print("Box blur approximations using formula: w_ideal = sqrt((12*σ²/n) + 1)\n", .{});
    std.debug.print("{s:^6} | {s:^20} | {s:^13} | {s:^9} | {s:^9} | {s:^7} | {s:^10}\n", .{
        "passes",
        "widths",
        "box time (ms)",
        "speedup",
        "PSNR (dB)",
        "SSIM",
        "Avg Error",
    });
    std.debug.print("{s:-<6}-+-{s:-<20}-+-{s:-<13}-+-{s:-<9}-+-{s:-<9}-+-{s:-<7}-+-{s:-<10}\n", .{ "", "", "", "", "", "", "" });

    var temp_a: Image = try .initLike(init.gpa, original);
    defer temp_a.deinit(init.gpa);
    var temp_b: Image = try .initLike(init.gpa, original);
    defer temp_b.deinit(init.gpa);

    const pass_counts = [_]usize{ 1, 2, 3, 4, 5 };

    for (pass_counts) |passes| {
        var widths_storage: [pass_counts.len]usize = undefined;
        const widths = try boxesForGaussian(sigma, passes, widths_storage[0..passes]);

        // Apply box blur passes
        var box_timer = try std.time.Timer.start();
        var source: *const Image = &original;
        var scratch = [_]*Image{ &temp_a, &temp_b };
        var scratch_index: usize = 0;
        var last_result: *Image = &temp_a;

        for (widths) |width| {
            std.debug.assert(width >= 1 and (width % 2 == 1));
            const radius: u32 = @intCast((width - 1) / 2);
            const dst = scratch[scratch_index];
            scratch_index = (scratch_index + 1) % scratch.len;
            try source.boxBlur(init.gpa, radius, dst.*);
            source = dst;
            last_result = dst;
        }

        const box_ns = box_timer.read();
        const speedup = @as(f64, @floatFromInt(gaussian_ns)) / @as(f64, @floatFromInt(box_ns));
        const psnr = try gaussian.psnr(last_result.*);
        const ssim_value = try gaussian.ssim(last_result.*);

        const avg_error = (try gaussian.meanPixelError(last_result.*)) * 100.0;

        var widths_buf: [64]u8 = undefined;
        const widths_text = try formatWidths(widths, &widths_buf);

        var name_buf: [48]u8 = undefined;
        const output_name = try std.fmt.bufPrint(&name_buf, "blur_box_pass_{d}.png", .{passes});
        try last_result.save(init.io, init.gpa, output_name);

        std.debug.print(
            "{d:>6} | {s:>20} | {d:>13.3} | {d:>8.2}x | {d:>9.2} | {d:>7.4} | {d:>8.2}%\n",
            .{ passes, widths_text, @as(f64, @floatFromInt(box_ns)) / std.time.ns_per_ms, speedup, psnr, ssim_value, avg_error },
        );
    }

    std.debug.print("\nNote: The formula optimizes box widths for each pass count independently.\n", .{});
    std.debug.print("SSIM ranges from 0-1 (higher is better). Avg Error % (lower is better).\n", .{});
    std.debug.print("For best Gaussian approximation, use 3 passes (recommended by literature).\n", .{});
}
