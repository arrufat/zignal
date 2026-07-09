const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const args = @import("args.zig");
const common = @import("common.zig");

const Args = struct {};

pub const description = "Compute quality metrics (PSNR, SSIM, Mean Error) between a reference and target images.";

pub const help = args.generateHelp(
    Args,
    "zignal metrics <reference_image> <target_images...>",
    description ++ "\n\nThe first image provided is used as the reference, and all subsequent images are compared against it.",
);

pub fn run(io: Io, writer: *Io.Writer, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help) {
        try args.printHelp(writer, help);
        return;
    }

    if (parsed.positionals.len < 2) {
        std.log.err("not enough arguments, need at least two images (reference and target).", .{});
        try args.printHelp(writer, help);
        return;
    }

    const ref_path = parsed.positionals[0];
    const targets = parsed.positionals[1..];

    std.log.debug("loading reference image: {s}", .{ref_path});
    var ref_img = try zignal.Image(zignal.Rgba(u8)).load(io, gpa, ref_path);
    defer ref_img.deinit(gpa);

    var failed = false;
    for (targets) |path| {
        try writer.print("\nComparing: {s}\n", .{path});

        std.log.debug("loading target image: {s}", .{path});
        var img = zignal.Image(zignal.Rgba(u8)).load(io, gpa, path) catch |err| {
            std.log.err("failed to load image '{s}': {t}", .{ path, err });
            failed = true;
            continue;
        };
        defer img.deinit(gpa);

        if (img.rows != ref_img.rows or img.cols != ref_img.cols) {
            std.log.err("dimension mismatch for {s}: reference {d}x{d} vs target {d}x{d}", .{
                path, ref_img.cols, ref_img.rows, img.cols, img.rows,
            });
            failed = true;
            continue;
        }

        const timer = common.Timer.begin(io);

        const psnr_val = ref_img.psnr(img) catch unreachable;
        const mean_err = ref_img.meanPixelError(img) catch unreachable;

        // SSIM requires the window to fit, so 11x11 is the minimum.
        var ssim_val: f64 = 0;
        if (img.rows >= 11 and img.cols >= 11) {
            ssim_val = try ref_img.ssim(img);
        } else {
            std.log.warn("image {s} is too small for ssim (min 11x11)", .{path});
        }

        timer.logElapsed("metrics");

        try writer.print("  PSNR: {d:.4} dB\n", .{psnr_val});
        try writer.print("  SSIM: {d:.4}\n", .{ssim_val});
        try writer.print("  Mean Error: {d:.4} (normalized 0-1)\n", .{mean_err});

        try writer.flush();
    }
    if (failed) return error.BatchIncomplete;
}
