const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const args = @import("args.zig");

const Args = struct {};

pub const description = "Compute quality metrics (PSNR, SSIM, Mean Error) between a reference and target images.";

pub const help = args.generateHelp(
    Args,
    "zignal metrics <reference_image> <target_images...>",
    description ++ "\n\nThe first image provided is used as the reference, and all subsequent images are compared against it.",
);

pub fn run(io: Io, writer: *std.Io.Writer, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help) {
        try args.printHelp(writer, help);
        return;
    }

    if (parsed.positionals.len < 2) {
        std.log.err("Not enough arguments. Need at least two images (reference and target).", .{});
        try args.printHelp(writer, help);
        return;
    }

    const ref_path = parsed.positionals[0];
    const targets = parsed.positionals[1..];

    std.log.info("Reference image: {s}", .{ref_path});
    var ref_img = try zignal.Image(zignal.Rgba(u8)).load(io, gpa, ref_path);
    defer ref_img.deinit(gpa);

    for (targets) |path| {
        try writer.print("\nComparing: {s}\n", .{path});

        // Load target image
        var img = try zignal.Image(zignal.Rgba(u8)).load(io, gpa, path);
        defer img.deinit(gpa);

        if (img.rows != ref_img.rows or img.cols != ref_img.cols) {
            std.log.err("Dimension mismatch for {s}: Reference {d}x{d} vs Target {d}x{d}", .{
                path, ref_img.cols, ref_img.rows, img.cols, img.rows,
            });
            continue;
        }

        const psnr_val = try ref_img.psnr(img);
        const mean_err = try ref_img.meanPixelError(img);

        // SSIM calculation
        var ssim_val: f64 = 0;
        // SSIM requires minimum 11x11
        if (img.rows >= 11 and img.cols >= 11) {
            ssim_val = try ref_img.ssim(img);
        } else {
            std.log.warn("Image {s} is too small for SSIM (min 11x11)", .{path});
        }

        try writer.print("  PSNR: {d:.4} dB\n", .{psnr_val});
        try writer.print("  SSIM: {d:.4}\n", .{ssim_val});
        try writer.print("  Mean Error: {d:.4} (normalized 0-1)\n", .{mean_err});

        try writer.flush();
    }
}
