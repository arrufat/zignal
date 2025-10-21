const std = @import("std");
const builtin = @import("builtin");
const Image = @import("zignal").Image;
const Rgba = @import("zignal").Rgba;

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

pub const MetricsResultCount = 2;

pub export fn compute_metrics(
    reference_ptr: [*]Rgba,
    reference_rows: usize,
    reference_cols: usize,
    distorted_ptr: [*]Rgba,
    distorted_rows: usize,
    distorted_cols: usize,
    result_ptr: [*]f64,
) void {
    if (reference_rows != distorted_rows or reference_cols != distorted_cols) {
        @panic("Image dimensions must match");
    }

    const pixel_count = reference_rows * reference_cols;
    const reference_slice = reference_ptr[0..pixel_count];
    const distorted_slice = distorted_ptr[0..pixel_count];

    const reference_img: Image(Rgba) = .initFromSlice(reference_rows, reference_cols, reference_slice);
    const distorted_img: Image(Rgba) = .initFromSlice(distorted_rows, distorted_cols, distorted_slice);

    result_ptr[0] = Image(Rgba).psnr(reference_img, distorted_img) catch @panic("PSNR computation failed");
    result_ptr[1] = Image(Rgba).ssim(reference_img, distorted_img) catch @panic("SSIM computation failed");
}
