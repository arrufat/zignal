const std = @import("std");
const builtin = @import("builtin");
const Image = @import("zignal").Image;
const Rgba = @import("zignal").Rgba(u8);

pub const std_options: std.Options = .{
    .logFn = if (builtin.cpu.arch.isWasm()) @import("js.zig").logFn else std.log.defaultLog,
    .log_level = std.log.default_level,
};

pub fn panic(msg: []const u8, st: ?*std.builtin.StackTrace, addr: ?usize) noreturn {
    _ = st;
    _ = addr;
    std.log.err("panic: {s}", .{msg});
    @trap();
}

pub const MetricsResultCount = 3;

pub export fn compute_metrics(
    reference_ptr: [*]Rgba,
    reference_rows: u32,
    reference_cols: u32,
    distorted_ptr: [*]Rgba,
    distorted_rows: u32,
    distorted_cols: u32,
    result_ptr: [*]f64,
) void {
    if (reference_rows != distorted_rows or reference_cols != distorted_cols) {
        @panic("Image dimensions must match");
    }

    const size = @as(usize, reference_rows) * @as(usize, reference_cols);

    const reference_img: Image(Rgba) = .initFromSlice(reference_rows, reference_cols, reference_ptr[0..size]);
    const distorted_img: Image(Rgba) = .initFromSlice(distorted_rows, distorted_cols, distorted_ptr[0..size]);

    result_ptr[0] = reference_img.psnr(distorted_img) catch @panic("PSNR computation failed");
    result_ptr[1] = reference_img.ssim(distorted_img) catch @panic("SSIM computation failed");
    result_ptr[2] = reference_img.meanPixelError(distorted_img) catch @panic("Mean pixel error computation failed");
}
