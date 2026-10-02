//! Pipeline subcommand: executes chained image processing operations from ZON recipes.

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
pub const Args = struct {
    output: ?[]const u8 = null,
    display: bool = false,
    width: ?u32 = null,
    height: ?u32 = null,
    protocol: ?display.ProtocolTag = null,

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
    \\command's options (enum-valued options are enum literals, e.g. .gaussian).
    \\The recipe may set .input/.output, which a CLI positional/--output override.
    \\
    \\Example recipe (recipe.zon):
    \\  .{
    \\      .input = "assets/liza.jpg",
    \\      .output = "out.png",
    \\      .steps = .{
    \\          .{ .resize = .{ .width = 800, .filter = .lanczos } },
    \\          .{ .blur = .{ .type = .gaussian, .sigma = 2.0 } },
    \\          .{ .edges = .{ .filter = .sobel } },
    \\      },
    \\  }
;

pub const usage = "zignal pipeline <recipe.zon> [images...] [options]";

pub fn run(io: Io, gpa: Allocator, writer: *Io.Writer, options: Args, positionals: []const []const u8) !void {
    const recipe_path = positionals[0];
    const input_overrides = positionals[1..];

    // The recipe and every string it references live in this arena for the
    // duration of processing.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = Io.Dir.cwd().readFileAllocOptions(io, recipe_path, arena, .limited(max_recipe_bytes), .of(u8), 0) catch |err| {
        std.log.err("failed to read recipe '{s}': {t}", .{ recipe_path, err });
        return error.InvalidArguments;
    };

    var diag: std.zon.parse.Diagnostics = undefined;
    const recipe = std.zon.parse.fromSlice(Recipe, .{
        .gpa = gpa,
        .arena = arena,
        .source = source,
        .diagnostics = &diag,
    }) catch |err| switch (err) {
        error.ParseZon => {
            std.log.err("invalid recipe '{s}':\n{f}", .{ recipe_path, diag.fmt(recipe_path) });
            return error.InvalidArguments;
        },
        else => |e| return e,
    };

    // Validate recipe steps before loading any images
    for (recipe.steps) |step| {
        if (step == .resize) try step.resize.validate();
    }

    if (recipe.steps.len == 0) {
        std.log.warn("recipe '{s}' has no steps; output will equal input", .{recipe_path});
    }

    // Inputs: CLI positionals win, otherwise the recipe's `.input`.
    const inputs: []const []const u8 = if (input_overrides.len > 0)
        input_overrides
    else if (recipe.input) |*in|
        in[0..1]
    else {
        std.log.err("no input image: recipe has no .input and none given on the command line", .{});
        return error.InvalidArguments;
    };

    // Output: CLI --output wins, otherwise the recipe's `.output`.
    const output_arg = options.output orelse recipe.output;
    const target = if (output_arg) |out| try common.resolveOutputTarget(io, out, inputs.len > 1) else null;
    const display_format = display.displayFormatFor(options, target);
    try display.processInputs(zignal.Rgba(u8), io, gpa, writer, inputs, target, display_format, recipe.steps, applySteps);
}

/// Runs `steps` in order on `img`, returning a freshly allocated image the caller owns.
fn applySteps(io: Io, gpa: Allocator, img: zignal.Image(zignal.Rgba(u8)), steps: []const Step) !zignal.Image(zignal.Rgba(u8)) {
    var current: ?zignal.Image(zignal.Rgba(u8)) = null;
    errdefer if (current) |*c| c.deinit(gpa);

    for (steps, 1..) |step, step_no| {
        std.log.info("step {d}: {s}", .{ step_no, @tagName(step) });
        const src = current orelse img;
        const next = switch (step) {
            .resize => |o| try resize.apply(io, gpa, src, o),
            .blur => |o| try blur.apply(io, gpa, src, o),
            .edges => |o| try edges.apply(io, gpa, src, o),
        };
        if (current) |*c| c.deinit(gpa);
        current = next;
    }
    return current orelse img.dupe(gpa);
}
