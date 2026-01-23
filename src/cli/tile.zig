const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const args = @import("args.zig");
const display = @import("display.zig");
const common = @import("common.zig");

// reusing parseFilter

const LayoutMode = enum {
    square,
    horizontal,
    vertical,
    grid,
    factors,
};

const Args = struct {
    mode: ?[]const u8 = null,
    rows: ?u32 = null,
    cols: ?u32 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    filter: ?[]const u8 = null,
    output: ?[]const u8 = null,
    display: bool = false,
    protocol: ?[]const u8 = null,

    pub const meta = .{
        .mode = .{ .help = "Layout mode: square, horizontal, vertical, grid, factors", .metavar = "mode" },
        .rows = .{ .help = "Number of rows (for grid mode)", .metavar = "N" },
        .cols = .{ .help = "Number of columns (for grid mode)", .metavar = "N" },
        .width = .{ .help = "Force cell width (default: first image width)", .metavar = "N" },
        .height = .{ .help = "Force cell height (default: first image height)", .metavar = "N" },
        .filter = .{ .help = "Interpolation filter (nearest, bilinear, bicubic, catmull-rom, mitchell, lanczos)", .metavar = "name" },
        .output = .{ .help = "Output file path", .metavar = "file" },
        .display = .{ .help = "Display the result in the terminal" },
        .protocol = .{ .help = "Force protocol: kitty, sixel, sgr, braille, auto", .metavar = "p" },
    };
};

pub const help_text = args.generateHelp(
    Args,
    "zignal tile <images...> [options]",
    "Combine multiple images into a single tiled image.\nIf --output is omitted, the result is displayed in the terminal.",
);

pub fn run(io: Io, writer: *std.Io.Writer, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help or parsed.positionals.len < 1) {
        try args.printHelp(writer, help_text);
        return;
    }

    const input_paths = parsed.positionals;
    const img_count = input_paths.len;
    const output_path = parsed.options.output;

    // Display if requested OR if no output file is specified
    const should_display = parsed.options.display or output_path == null;

    var mode: LayoutMode = .square;
    if (parsed.options.mode) |m| {
        const mode_map: std.StaticStringMap(LayoutMode) = .initComptime(.{
            .{ "square", .square },
            .{ "horizontal", .horizontal },
            .{ "vertical", .vertical },
            .{ "grid", .grid },
            .{ "factors", .factors },
        });
        if (mode_map.get(m)) |val| {
            mode = val;
        } else {
            std.log.err("Unknown layout mode: {s}", .{m});
            return error.InvalidArguments;
        }
    }

    // Determine Grid Dimensions
    var rows: u32 = 0;
    var cols: u32 = 0;

    switch (mode) {
        .horizontal => {
            rows = 1;
            cols = @intCast(img_count);
        },
        .vertical => {
            rows = @intCast(img_count);
            cols = 1;
        },
        .square => {
            const sqrt = std.math.sqrt(@as(f32, @floatFromInt(img_count)));
            cols = @intFromFloat(@ceil(sqrt));
            rows = @intFromFloat(@ceil(@as(f32, @floatFromInt(img_count)) / @as(f32, @floatFromInt(cols))));
        },
        .grid => {
            if (parsed.options.rows == null or parsed.options.cols == null) {
                std.log.err("Mode 'grid' requires --rows and --cols", .{});
                return error.InvalidArguments;
            }
            rows = parsed.options.rows.?;
            cols = parsed.options.cols.?;
            if (rows * cols < img_count) {
                std.log.warn("Grid size ({d}x{d}={d}) is smaller than image count ({d}). Some images will be ignored.", .{ rows, cols, rows * cols, img_count });
            }
        },
        .factors => {
            // Find factors closest to square
            const n = @as(u32, @intCast(img_count));
            var best_r: u32 = 1;
            var i: u32 = 1;
            while (i * i <= n) : (i += 1) {
                if (n % i == 0) {
                    best_r = i;
                }
            }
            rows = best_r;
            cols = n / best_r;
            // Prefer landscape orientation (more cols than rows)
            if (rows > cols) {
                const tmp = rows;
                rows = cols;
                cols = tmp;
            }
        },
    }

    std.log.info("Tiling {d} images into a {d}x{d} grid ({s})...", .{ img_count, cols, rows, @tagName(mode) });

    // Determine Cell Size
    var cell_w: u32 = 0;
    var cell_h: u32 = 0;
    var reference_img: ?zignal.Image(zignal.Rgba(u8)) = null;
    defer if (reference_img) |*img| img.deinit(gpa);

    if (parsed.options.width) |w| cell_w = w;
    if (parsed.options.height) |h| cell_h = h;

    if (cell_w == 0 or cell_h == 0) {
        // Load first image to establish dimensions
        std.log.info("Analyzing reference image: {s}...", .{input_paths[0]});

        // Use RGBA for safety to handle transparency
        reference_img = try zignal.Image(zignal.Rgba(u8)).load(io, gpa, input_paths[0]);

        const ref_w_f = @as(f32, @floatFromInt(reference_img.?.cols));
        const ref_h_f = @as(f32, @floatFromInt(reference_img.?.rows));

        if (cell_w == 0 and cell_h == 0) {
            cell_w = @intCast(reference_img.?.cols);
            cell_h = @intCast(reference_img.?.rows);
        } else if (cell_w != 0 and cell_h == 0) {
            // Scale height proportionally
            cell_h = @intFromFloat(@round((@as(f32, @floatFromInt(cell_w)) / ref_w_f) * ref_h_f));
        } else if (cell_w == 0 and cell_h != 0) {
            // Scale width proportionally
            cell_w = @intFromFloat(@round((@as(f32, @floatFromInt(cell_h)) / ref_h_f) * ref_w_f));
        }
    }

    const canvas_w = cols * cell_w;
    const canvas_h = rows * cell_h;

    std.log.info("Cell Size: {d}x{d}", .{ cell_w, cell_h });
    std.log.info("Canvas Size: {d}x{d}", .{ canvas_w, canvas_h });

    // Create Canvas
    var canvas = try zignal.Image(zignal.Rgba(u8)).init(gpa, canvas_h, canvas_w);
    defer canvas.deinit(gpa);
    canvas.fill(.{ .r = 0, .g = 0, .b = 0, .a = 255 }); // Fill black (opaque)

    var filter: zignal.Interpolation = .bilinear;
    if (parsed.options.filter) |f| {
        filter = common.parseFilter(f) catch |err| {
            std.log.err("Unknown filter type: {s}", .{f});
            return err;
        };
    }

    // Process Images
    for (input_paths, 0..) |path, idx| {
        if (idx >= rows * cols) break;

        const r = idx / cols;
        const c = idx % cols;

        std.log.info("[{d}/{d}] Processing {s}...", .{ idx + 1, img_count, path });

        var img: zignal.Image(zignal.Rgba(u8)) = undefined;
        var loaded_new = false;

        // Optimization: Use the already loaded reference if it's the first one
        if (idx == 0 and reference_img != null) {
            img = reference_img.?;
        } else {
            // Load
            img = zignal.Image(zignal.Rgba(u8)).load(io, gpa, path) catch |err| {
                std.log.warn("Failed to load {s}: {s}. Skipping slot.", .{ path, @errorName(err) });
                continue;
            };
            loaded_new = true;
        }
        defer if (loaded_new) img.deinit(gpa);

        // Check if resize is needed
        if (img.cols != cell_w or img.rows != cell_h) {
            // We need to resize.
            // Create a temp buffer for the resized image
            // Note: We can resize directly into the canvas using insert?
            // Image.insert supports scaling?
            // Checking src/image.zig: insert(self, source, rect, angle, method, blend_mode)
            // It scales source to fit rect! Perfect.
        }

        // Calculate aspect-preserving destination rectangle
        const scale_x = @as(f32, @floatFromInt(cell_w)) / @as(f32, @floatFromInt(img.cols));
        const scale_y = @as(f32, @floatFromInt(cell_h)) / @as(f32, @floatFromInt(img.rows));
        const scale = @min(scale_x, scale_y);

        const target_w = @as(f32, @floatFromInt(img.cols)) * scale;
        const target_h = @as(f32, @floatFromInt(img.rows)) * scale;

        const x_offset = (@as(f32, @floatFromInt(cell_w)) - target_w) / 2.0;
        const y_offset = (@as(f32, @floatFromInt(cell_h)) - target_h) / 2.0;

        const cell_l = @as(f32, @floatFromInt(c * cell_w));
        const cell_t = @as(f32, @floatFromInt(r * cell_h));

        const dest_rect = zignal.Rectangle(f32){
            .l = cell_l + x_offset,
            .t = cell_t + y_offset,
            .r = cell_l + x_offset + target_w,
            .b = cell_t + y_offset + target_h,
        };

        canvas.insert(img, dest_rect, 0, filter, .none);
    }

    if (output_path) |out_path| {
        std.log.info("Saving to {s}...", .{out_path});
        try canvas.save(io, gpa, out_path);
    }

    if (should_display) {
        try display.displayCanvas(io, writer, &canvas, parsed.options.protocol, filter);
    }

    std.log.info("Done.", .{});
}
