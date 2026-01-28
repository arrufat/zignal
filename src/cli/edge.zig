const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const args = @import("args.zig");
const common = @import("common.zig");
const display = @import("display.zig");

const Args = struct {
    algo: ?[]const u8 = null,
    output: ?[]const u8 = null,
    display: bool = false,

    // Parameters
    sigma: ?f32 = null,
    low: ?f32 = null,
    high: ?f32 = null,
    window: ?usize = null,
    nms: bool = false,

    // Display options
    width: ?u32 = null,
    height: ?u32 = null,
    protocol: ?[]const u8 = null,
    filter: ?[]const u8 = null,

    pub const meta = .{
        .algo = .{ .help = "Algorithm: sobel, canny, shen-castan (default: sobel)", .metavar = "name" },
        .output = .{ .help = "Output file path (default: display only)", .metavar = "path" },
        .display = .{ .help = "Display the result in the terminal (default if no output)" },
        .sigma = .{ .help = "Canny sigma (def: 1.0) or Shen-Castan smoothing (def: 0.9)", .metavar = "float" },
        .low = .{ .help = "Canny low thresh (def: 50) or Shen-Castan low_rel (def: 0.5)", .metavar = "float" },
        .high = .{ .help = "Canny high thresh (def: 100) or Shen-Castan high_ratio (def: 0.99)", .metavar = "float" },
        .window = .{ .help = "Shen-Castan window size (default: 7)", .metavar = "int" },
        .nms = .{ .help = "Shen-Castan: use Non-Maximum Suppression" },
        .width = .{ .help = "Display width", .metavar = "N" },
        .height = .{ .help = "Display height", .metavar = "N" },
        .protocol = .{ .help = "Display protocol: kitty, sixel, sgr, braille, auto", .metavar = "p" },
        .filter = .{ .help = "Display resize filter", .metavar = "name" },
    };
};

pub const description = "Perform edge detection on an image using Sobel, Canny, or Shen-Castan algorithms.";

pub const help = args.generateHelp(
    Args,
    "zignal edge <image> [options]",
    description,
);

const Algo = enum {
    sobel,
    canny,
    shen_castan,
};

pub fn run(io: Io, writer: *std.Io.Writer, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help or parsed.positionals.len == 0) {
        try args.printHelp(writer, help);
        return;
    }

    const input_path = parsed.positionals[0];
    const output_path = parsed.options.output;
    const should_display = parsed.options.display or output_path == null;

    var algo: Algo = .sobel;
    if (parsed.options.algo) |a| {
        if (std.mem.eql(u8, a, "sobel")) {
            algo = .sobel;
        } else if (std.mem.eql(u8, a, "canny")) {
            algo = .canny;
        } else if (std.mem.eql(u8, a, "shen-castan")) {
            algo = .shen_castan;
        } else {
            std.log.err("Unknown algorithm: {s}. Supported: sobel, canny, shen-castan", .{a});
            return error.InvalidArguments;
        }
    }

    std.log.debug("Loading image: {s}", .{input_path});
    var img = try zignal.Image(u8).load(io, gpa, input_path);
    defer img.deinit(gpa);

    var out_img = try zignal.Image(u8).init(gpa, img.rows, img.cols);
    defer out_img.deinit(gpa);

    std.log.debug("Applying {s} edge detection...", .{@tagName(algo)});
    var timer = try std.time.Timer.start();

    switch (algo) {
        .sobel => {
            try img.sobel(gpa, out_img);
        },
        .canny => {
            const sigma = parsed.options.sigma orelse 1.0;
            const low = parsed.options.low orelse 50.0;
            const high = parsed.options.high orelse 100.0;
            std.log.debug("Canny params: sigma={d:.2}, low={d:.2}, high={d:.2}", .{ sigma, low, high });
            try img.canny(gpa, sigma, low, high, out_img);
        },
        .shen_castan => {
            const opts = zignal.ShenCastan{
                .smooth = parsed.options.sigma orelse 0.9,
                .window_size = parsed.options.window orelse 7,
                .high_ratio = parsed.options.high orelse 0.99,
                .low_rel = parsed.options.low orelse 0.5,
                .use_nms = parsed.options.nms,
            };
            std.log.debug("Shen-Castan params: smooth={d:.2}, window={d}, high_ratio={d:.2}, low_rel={d:.2}, nms={}", .{
                opts.smooth, opts.window_size, opts.high_ratio, opts.low_rel, opts.use_nms,
            });
            try img.shenCastan(gpa, opts, out_img);
        },
    }

    const duration_ns = timer.read();
    std.log.debug("Edge detection took {d:.3} ms", .{@as(f64, @floatFromInt(duration_ns)) / std.time.ns_per_ms});

    if (output_path) |path| {
        std.log.info("Saving result to {s}...", .{path});
        try out_img.save(io, gpa, path);
    }

    if (should_display) {
        const filter = try common.resolveFilter(parsed.options.filter);
        const format = try display.resolveDisplayFormat(parsed.options.protocol, parsed.options.width, parsed.options.height, filter);
        try display.displayCanvas(io, writer, out_img, format);
    }
}
