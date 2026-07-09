const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const args = @import("args.zig");
const common = @import("common.zig");
const display = @import("display.zig");

const resize = @import("resize.zig");
const blur = @import("blur.zig");
const edges = @import("edges.zig");

/// Recipes are tiny; cap the read to guard against accidentally huge files.
const max_recipe_bytes = 1 << 20; // 1 MiB

/// One pipeline step. Each variant's payload is the exact `Args` struct of the
/// matching CLI command, so recipe fields mirror the CLI options one-to-one.
const Step = union(enum) {
    resize: resize.Args,
    blur: blur.Args,
    edges: edges.Args,
};

/// A full pipeline as described by a `.zon` recipe file.
const Recipe = struct {
    input: ?[]const u8 = null,
    output: ?[]const u8 = null,
    steps: []const Step = &.{},
};

/// CLI-level flags for the `pipeline` command itself. `--output` overrides the
/// recipe's `.output`; the display flags mirror the other commands.
const Args = struct {
    output: ?[]const u8 = null,
    display: bool = false,
    width: ?u32 = null,
    height: ?u32 = null,
    protocol: ?[]const u8 = null,

    pub const meta = .{
        .output = .{ .help = "Output file or directory (overrides recipe .output)", .metavar = "path", .short = 'o' },
        .display = .{ .help = "Display the result in the terminal (default if no output)", .short = 'd' },
        .width = .{ .help = "Display width", .metavar = "N" },
        .height = .{ .help = "Display height", .metavar = "N" },
        .protocol = .{ .help = display.protocol_help, .metavar = "p" },
    };
};

pub const description =
    \\Apply a sequence of operations described by a .zon recipe file.
    \\
    \\A recipe lists ordered steps; each step's fields mirror the matching CLI
    \\command's options (enum values are plain strings, e.g. "gaussian"). The
    \\recipe may set .input/.output, which a CLI positional/--output override.
    \\
    \\Example recipe (recipe.zon):
    \\  .{
    \\      .input = "assets/liza.jpg",
    \\      .output = "out.png",
    \\      .steps = .{
    \\          .{ .resize = .{ .width = 800, .filter = "lanczos" } },
    \\          .{ .blur = .{ .type = "gaussian", .sigma = 2.0 } },
    \\          .{ .edges = .{ .filter = "sobel" } },
    \\      },
    \\  }
;

pub const help = args.generateHelp(
    Args,
    "zignal pipeline <recipe.zon> [images...] [options]",
    description,
);

pub fn run(io: Io, writer: *Io.Writer, gpa: Allocator, iterator: *std.process.Args.Iterator) !void {
    const parsed = try args.parse(Args, gpa, iterator);
    defer parsed.deinit(gpa);

    if (parsed.help or parsed.positionals.len == 0) {
        try args.printHelp(writer, help);
        return;
    }

    const recipe_path = parsed.positionals[0];
    const input_overrides = parsed.positionals[1..];

    // The recipe and every string it references live in this arena for the
    // duration of processing.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bytes = Io.Dir.cwd().readFileAlloc(io, recipe_path, arena, .limited(max_recipe_bytes)) catch |err| {
        std.log.err("failed to read recipe '{s}': {t}", .{ recipe_path, err });
        return error.InvalidArguments;
    };
    const source = try arena.dupeSentinel(u8, bytes, 0);

    var diag: std.zon.parse.Diagnostics = .{};
    const recipe = std.zon.parse.fromSliceAlloc(Recipe, arena, source, &diag, .{ .free_on_error = false }) catch |err| switch (err) {
        error.ParseZon => {
            std.log.err("invalid recipe '{s}':\n{f}", .{ recipe_path, diag });
            return error.InvalidArguments;
        },
        else => |e| return e,
    };

    if (recipe.steps.len == 0) {
        std.log.warn("recipe '{s}' has no steps; output will equal input", .{recipe_path});
    }

    // Inputs: CLI positionals win, otherwise the recipe's `.input`.
    var single_input: [1][]const u8 = undefined;
    const inputs: []const []const u8 = if (input_overrides.len > 0)
        input_overrides
    else if (recipe.input) |in| blk: {
        single_input[0] = in;
        break :blk &single_input;
    } else {
        std.log.err("no input image: recipe has no .input and none given on the command line", .{});
        return error.InvalidArguments;
    };

    // Output: CLI --output wins, otherwise the recipe's `.output`.
    const output_arg = parsed.options.output orelse recipe.output;
    const is_batch = inputs.len > 1;
    var target: ?common.OutputTarget = null;
    if (output_arg) |out| {
        target = try common.resolveOutputTarget(io, out, is_batch);
    }

    const should_display = parsed.options.display or target == null;

    for (inputs) |input_path| {
        processImage(io, writer, gpa, input_path, recipe.steps, target, should_display, parsed.options) catch |err| {
            std.log.err("failed to process '{s}': {t}", .{ input_path, err });
            if (!is_batch) return err;
        };
    }
}

fn processImage(
    io: Io,
    writer: *Io.Writer,
    gpa: Allocator,
    input_path: []const u8,
    steps: []const Step,
    target: ?common.OutputTarget,
    should_display: bool,
    options: Args,
) !void {
    std.log.debug("loading {s}...", .{input_path});

    var current: zignal.Image(zignal.Rgba(u8)) = try .load(io, gpa, input_path);
    defer current.deinit(gpa);

    for (steps, 1..) |step, step_no| {
        std.log.info("step {d}: {s}", .{ step_no, @tagName(step) });
        const next = switch (step) {
            .resize => |o| try resize.apply(io, gpa, current, o),
            .blur => |o| try blur.apply(io, gpa, current, o),
            .edges => |o| try edges.apply(io, gpa, current, o),
        };
        current.deinit(gpa);
        current = next;
    }

    if (target) |tgt| {
        const resolved = try tgt.resolveOutputPath(gpa, input_path);
        defer resolved.deinit(gpa);
        std.log.info("saving to {s}...", .{resolved.path});
        try current.save(io, gpa, resolved.path);
    }

    if (should_display) {
        const format = try display.resolveDisplayFormat(options.protocol, options.width, options.height);
        try display.displayCanvas(io, writer, current, format);
    }
}
