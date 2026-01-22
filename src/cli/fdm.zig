const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");
const args = @import("args.zig");

const Args = struct {
    pub const meta = .{};
};

pub const help_text = args.generateHelp(
    Args,
    "zignal fdm <source> <target> <output>",
    "Apply Feature Distribution Matching (style transfer) from target to source image.",
);

pub fn run(io: Io, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help or parsed.positionals.len != 3) {
        var buffer: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &buffer);
        try stdout.interface.print("{s}", .{help_text});
        try stdout.interface.flush();
        return;
    }

    const source_path = parsed.positionals[0];
    const target_path = parsed.positionals[1];
    const output_path = parsed.positionals[2];

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);

    try stdout.interface.print("Source: {s}\n", .{source_path});
    try stdout.interface.print("Target: {s}\n", .{target_path});
    try stdout.interface.flush();

    // Use Rgb(u8) for style transfer
    const Pixel = zignal.Rgb(u8);

    // Load source image
    var source_img = try zignal.Image(Pixel).load(io, gpa, source_path);
    defer source_img.deinit(gpa);

    // Load target image
    var target_img = try zignal.Image(Pixel).load(io, gpa, target_path);
    defer target_img.deinit(gpa);

    // Initialize FDM
    var fdm = zignal.FeatureDistributionMatching(Pixel).init(gpa);
    defer fdm.deinit();

    try stdout.interface.print("Applying FDM style transfer...\n", .{});
    try stdout.interface.flush();

    // Apply match
    try fdm.match(source_img, target_img);

    try stdout.interface.print("Saving result to {s}...\n", .{output_path});
    try stdout.interface.flush();

    // Save result
    try source_img.save(io, gpa, output_path);

    try stdout.interface.print("Done.\n", .{});
    try stdout.interface.flush();
}
