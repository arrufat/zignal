//! Edges subcommand: detects image edges using Sobel or Shen-Castan filters.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const args = @import("args.zig");
const common = @import("common.zig");
const display = @import("display.zig");

pub const Args = struct {
    filter: ?Algo = null,
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
    protocol: ?display.ProtocolTag = null,

    pub const meta = .{
        .filter = .{ .help = "Filter: " ++ common.joinFieldNames(Algo) ++ " (default: sobel)", .metavar = "name" },
        .output = .{ .help = "Output file path (default: display only)", .metavar = "path", .short = 'o' },
        .display = .{ .help = "Display the result in the terminal (default if no output)", .short = 'd' },
        .sigma = .{ .help = "Canny sigma (def: 1.0) or Shen-Castan smoothing (def: 0.9)", .metavar = "float" },
        .low = .{ .help = "Canny low thresh (def: 50) or Shen-Castan low_rel (def: 0.5)", .metavar = "float" },
        .high = .{ .help = "Canny high thresh (def: 100) or Shen-Castan high_ratio (def: 0.99)", .metavar = "float" },
        .window = .{ .help = "Shen-Castan window size (default: 7)", .metavar = "int" },
        .nms = .{ .help = "Shen-Castan: use Non-Maximum Suppression" },
        .width = .{ .help = "Display width", .metavar = "N" },
        .height = .{ .help = "Display height", .metavar = "N" },
        .protocol = .{ .help = display.protocol_help, .metavar = "p" },
    };
};

pub const description = "Perform edge detection on an image using Sobel, Canny, or Shen-Castan algorithms.";

pub const help = args.generateHelp(
    Args,
    "zignal edges <image> [options]",
    description,
);

const Algo = enum {
    sobel,
    canny,
    shen_castan,
};

pub fn run(io: Io, gpa: Allocator, writer: *Io.Writer, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help or parsed.positionals.len == 0) {
        try args.printHelp(writer, help);
        return;
    }

    const target = if (parsed.options.output) |out| try common.resolveOutputTarget(io, out, parsed.positionals.len > 1) else null;
    const display_format = display.displayFormatFor(parsed.options, target);
    try display.processInputs(u8, io, gpa, writer, parsed.positionals, target, display_format, parsed.options, applyGray);
}

/// Run the selected edge detector on a grayscale image, returning a freshly allocated
/// image the caller owns. The standalone command stays on this u8 fast path.
pub fn applyGray(io: Io, gpa: Allocator, img: zignal.Image(u8), options: Args) !zignal.Image(u8) {
    const algo = options.filter orelse .sobel;
    var out: zignal.Image(u8) = try .initLike(gpa, img);
    errdefer out.deinit(gpa);

    std.log.debug("applying {s} edge detection...", .{@tagName(algo)});
    const timer = common.Timer.begin(io);

    switch (algo) {
        .sobel => try img.sobel(io, gpa, out),
        .canny => {
            const sigma = options.sigma orelse 1.0;
            const low = options.low orelse 50.0;
            const high = options.high orelse 100.0;
            std.log.debug("canny params: sigma={d:.2}, low={d:.2}, high={d:.2}", .{ sigma, low, high });
            try img.canny(io, gpa, out, sigma, low, high);
        },
        .shen_castan => {
            const opts = zignal.image.ShenCastan{
                .smooth = options.sigma orelse 0.9,
                .window_size = options.window orelse 7,
                .high_ratio = options.high orelse 0.99,
                .low_rel = options.low orelse 0.5,
                .use_nms = options.nms,
            };
            std.log.debug("shen_castan params: smooth={d:.2}, window={d}, high_ratio={d:.2}, low_rel={d:.2}, nms={}", .{
                opts.smooth, opts.window_size, opts.high_ratio, opts.low_rel, opts.use_nms,
            });
            try img.shenCastan(io, gpa, out, opts);
        },
    }

    timer.logElapsed("edge detection");
    return out;
}

/// Pipeline-facing wrapper: detect edges on an RGBA image by bridging through
/// grayscale, returning a freshly allocated RGBA image the caller owns.
pub fn apply(io: Io, gpa: Allocator, img: zignal.Image(zignal.Rgba(u8)), options: Args) !zignal.Image(zignal.Rgba(u8)) {
    var gray = try img.convert(io, gpa, u8);
    defer gray.deinit(gpa);

    var edges_gray = try applyGray(io, gpa, gray, options);
    defer edges_gray.deinit(gpa);

    return edges_gray.convert(io, gpa, zignal.Rgba(u8));
}
