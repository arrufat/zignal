//! Tile subcommand: arranges multiple input images into a grid layout.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const args = @import("args.zig");
const common = @import("common.zig");
const display = @import("display.zig");

const LayoutMode = enum {
    square,
    horizontal,
    vertical,
    grid,
    factors,
};

pub const Args = struct {
    mode: ?LayoutMode = null,
    rows: ?u32 = null,
    cols: ?u32 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    output: ?[]const u8 = null,
    display: bool = false,
    protocol: ?display.ProtocolTag = null,

    pub const meta = .{
        .mode = .{ .help = "Layout mode: " ++ common.joinFieldNames(LayoutMode), .metavar = "mode" },
        .rows = .{ .help = "Number of rows (for grid mode)", .metavar = "N" },
        .cols = .{ .help = "Number of columns (for grid mode)", .metavar = "N" },
        .width = .{ .help = "Force cell width (default: first image width)", .metavar = "N" },
        .height = .{ .help = "Force cell height (default: first image height)", .metavar = "N" },
        .output = .{ .help = "Output file path", .metavar = "file", .short = 'o' },
        .display = .{ .help = "Display the result in the terminal", .short = 'd' },
        .protocol = .{ .help = display.protocol_help, .metavar = "p" },
    };
};

pub const description = "Combine multiple images into a single tiled image.\nIf --output is omitted, the result is displayed in the terminal.";

pub const usage = "zignal tile <images...> [options]";

pub fn run(io: Io, gpa: Allocator, writer: *Io.Writer, options: Args, inputs: []const []const u8) !void {
    const input_paths = inputs;
    const img_count = input_paths.len;
    const output_path = options.output;

    const should_display = options.display or output_path == null;

    const mode = options.mode orelse .square;

    const rows: u32, const cols: u32 = switch (mode) {
        .horizontal => .{ 1, @intCast(img_count) },
        .vertical => .{ @intCast(img_count), 1 },
        .square => blk: {
            const cols: u32 = @ceil(std.math.sqrt(@as(f32, @floatFromInt(img_count))));
            break :blk .{ @intCast((img_count + cols - 1) / cols), cols };
        },
        .grid => blk: {
            const missing_msg = "mode 'grid' requires --rows and --cols";
            const rows = options.rows orelse {
                std.log.err(missing_msg, .{});
                return error.InvalidArguments;
            };
            const cols = options.cols orelse {
                std.log.err(missing_msg, .{});
                return error.InvalidArguments;
            };
            if (rows * cols < img_count) {
                std.log.warn("grid size ({d}x{d}={d}) is smaller than image count ({d}). some images will be ignored.", .{ rows, cols, rows * cols, img_count });
            } else if (rows * cols > img_count) {
                std.log.debug("grid size ({d}x{d}={d}) is larger than image count ({d}). empty cells will be black.", .{ rows, cols, rows * cols, img_count });
            }
            break :blk .{ rows, cols };
        },
        .factors => blk: {
            // Largest factor at most sqrt(n), so rows <= cols (landscape).
            const n: u32 = @intCast(img_count);
            var best_r: u32 = 1;
            var i: u32 = 1;
            while (i * i <= n) : (i += 1) {
                if (n % i == 0) best_r = i;
            }
            std.log.debug("factors mode: calculated {d}x{d} grid for {d} images", .{ best_r, n / best_r, n });
            break :blk .{ best_r, n / best_r };
        },
    };

    std.log.info("tiling {d} images into a {d}x{d} grid ({s})...", .{ img_count, cols, rows, @tagName(mode) });

    var cell_w: u32 = options.width orelse 0;
    var cell_h: u32 = options.height orelse 0;
    // Caches the first image so we don't load it twice when it doubles as the
    // reference for cell sizing.
    var reference_img: ?zignal.Image(zignal.Rgba(u8)) = null;
    defer if (reference_img) |*img| img.deinit(gpa);

    if (cell_w == 0 or cell_h == 0) {
        std.log.debug("analyzing reference image: {s}...", .{input_paths[0]});
        reference_img = try zignal.Image(zignal.Rgba(u8)).load(io, gpa, input_paths[0]);
        const ref = reference_img.?;

        const ref_w_f: f32 = @floatFromInt(ref.cols);
        const ref_h_f: f32 = @floatFromInt(ref.rows);

        if (cell_w == 0 and cell_h == 0) {
            cell_w = ref.cols;
            cell_h = ref.rows;
        } else if (cell_h == 0) {
            cell_h = @round((@as(f32, @floatFromInt(cell_w)) / ref_w_f) * ref_h_f);
        } else {
            cell_w = @round((@as(f32, @floatFromInt(cell_h)) / ref_h_f) * ref_w_f);
        }
    }

    const canvas_w = cols * cell_w;
    const canvas_h = rows * cell_h;

    std.log.debug("cell size: {d}x{d}", .{ cell_w, cell_h });
    std.log.debug("canvas size: {d}x{d}", .{ canvas_w, canvas_h });

    var canvas = try zignal.Image(zignal.Rgba(u8)).init(gpa, canvas_h, canvas_w);
    defer canvas.deinit(gpa);
    canvas.fill(.black);

    var failed = false;
    const timer = common.Timer.begin(io);
    for (input_paths, 0..) |path, idx| {
        if (idx >= rows * cols) break;

        const r = idx / cols;
        const c = idx % cols;

        std.log.debug("[{d}/{d}] processing {s}...", .{ idx + 1, img_count, path });

        const cached = if (idx == 0) reference_img else null;
        var img = cached orelse zignal.Image(zignal.Rgba(u8)).load(io, gpa, path) catch |err| {
            std.log.warn("failed to load {s}: {t}. skipping slot.", .{ path, err });
            failed = true;
            continue;
        };
        defer if (cached == null) img.deinit(gpa);

        const scale_x = @as(f32, @floatFromInt(cell_w)) / @as(f32, @floatFromInt(img.cols));
        const scale_y = @as(f32, @floatFromInt(cell_h)) / @as(f32, @floatFromInt(img.rows));
        const scale = @min(scale_x, scale_y);

        const target_w = @as(f32, @floatFromInt(img.cols)) * scale;
        const target_h = @as(f32, @floatFromInt(img.rows)) * scale;

        const x_offset = (@as(f32, @floatFromInt(cell_w)) - target_w) / 2.0;
        const y_offset = (@as(f32, @floatFromInt(cell_h)) - target_h) / 2.0;

        const cell_l: f32 = @floatFromInt(c * cell_w);
        const cell_t: f32 = @floatFromInt(r * cell_h);

        const dest_rect = zignal.Rectangle(f32){
            .l = cell_l + x_offset,
            .t = cell_t + y_offset,
            .r = cell_l + x_offset + target_w,
            .b = cell_t + y_offset + target_h,
        };

        canvas.insert(io, img, dest_rect, 0, .bilinear, .none);
    }
    timer.logElapsed("tiling");

    if (output_path) |out_path| {
        std.log.info("saving to {s}...", .{out_path});
        try canvas.save(io, gpa, out_path);
    }

    if (should_display) {
        const format = display.resolveDisplayFormat(options.protocol, null, null);
        try display.displayCanvas(io, writer, &canvas, format);
    }

    if (failed) return error.BatchIncomplete;
}
