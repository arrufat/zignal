const std = @import("std");
const zignal = @import("zignal");
const Image = zignal.Image;
const Rgb = zignal.Rgb(u8);
const Canvas = zignal.Canvas;
const Point = zignal.Point(2, f32);
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();

    const input_path = if (args.next()) |arg| arg else "../assets/liza.jpg";

    std.debug.print("Loading image from {s}...\n", .{input_path});
    var image = try Image(Rgb).load(init.io, init.gpa, input_path);
    defer image.deinit(init.gpa);

    std.debug.print("Detecting edges...\n", .{});
    var gray = try image.convert(u8, init.gpa);
    defer gray.deinit(init.gpa);
    var edges = try Image(u8).init(init.gpa, image.rows, image.cols);
    defer edges.deinit(init.gpa);

    try gray.canny(init.gpa, 2.0, 25, 75, edges);
    // Custom "Human-Like" Shen-Castan parameters
    // try gray.shenCastan(init.gpa, .{
    //     .smooth = 0.5, // Moderate smoothing (balance detail/structure)
    //     .window_size = 13, // Medium window
    //     .high_ratio = 0.92, // More sensitive start threshold
    //     .low_rel = 0.4, // Continue lines even if faint
    //     .use_nms = true, // Clean single-pixel lines
    // }, edges);

    // Save edges for reference
    try edges.save(init.io, init.gpa, "trace_edges_input.png");

    // Trace
    std.debug.print("Tracing edges...\n", .{});

    // Initialize tracer with noise reduction and simplification
    const tracer = zignal.Tracer.init(init.gpa, .{
        .min_path_length = 10,
        .simplification_epsilon = 1.5,
    });

    var paths = try tracer.trace(edges);
    defer {
        for (paths.items) |*path| path.deinit(init.gpa);
        paths.deinit(init.gpa);
    }

    // Visualize result (SVG)
    const svg_out = "trace_edges_output.svg";
    try saveSvg(init.io, paths, image.cols, image.rows, svg_out);

    // Visualize result (Raster)
    const png_out = "trace_edges_preview.png";
    try savePreview(init.io, init.gpa, paths, image.cols, image.rows, png_out);

    std.debug.print("Found {d} paths.\n", .{paths.items.len});
    std.debug.print("Saved outputs:\n  - Edges: trace_edges_input.png\n  - Vector: {s}\n  - Preview: {s}\n", .{ svg_out, png_out });
}

fn saveSvg(io: Io, paths: std.ArrayList(std.ArrayList(Point)), width: usize, height: usize, filename: []const u8) !void {
    const file = try Io.Dir.cwd().createFile(io, filename, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const w = &writer.interface;

    try w.print("<svg width=\"{d}\" height=\"{d}\" xmlns=\"http://www.w3.org/2000/svg\">\n", .{ width, height });
    try w.print("<rect width=\"100%\" height=\"100%\" fill=\"white\"/>\n", .{});

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    for (paths.items) |path| {
        const r = random.intRangeAtMost(u8, 0, 200);
        const g = random.intRangeAtMost(u8, 0, 200);
        const b = random.intRangeAtMost(u8, 0, 200);

        try w.print("<path d=\"M {d:.1} {d:.1}", .{ path.items[0].x(), path.items[0].y() });
        for (path.items[1..]) |pt| {
            try w.print(" L {d:.1} {d:.1}", .{ pt.x(), pt.y() });
        }
        try w.print("\" stroke=\"rgb({d},{d},{d})\" stroke-width=\"1\" fill=\"none\"/>\n", .{ r, g, b });
    }

    try w.writeAll("</svg>");
    try writer.flush();
}

fn savePreview(io: Io, allocator: std.mem.Allocator, paths: std.ArrayList(std.ArrayList(Point)), width: usize, height: usize, filename: []const u8) !void {
    var image = try Image(Rgb).init(allocator, @intCast(height), @intCast(width));
    defer image.deinit(allocator);

    for (image.data) |*p| p.* = .{ .r = 255, .g = 255, .b = 255 };

    var canvas = Canvas(Rgb).init(allocator, image);
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    for (paths.items) |path| {
        const color = Rgb{
            .r = random.intRangeAtMost(u8, 0, 200),
            .g = random.intRangeAtMost(u8, 0, 200),
            .b = random.intRangeAtMost(u8, 0, 200),
        };

        if (path.items.len < 2) continue;

        for (0..path.items.len - 1) |i| {
            canvas.drawLine(path.items[i], path.items[i + 1], color, 1, .fast);
        }
    }

    try image.save(io, allocator, filename);
}
