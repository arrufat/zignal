const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

const display = @import("cli/display.zig");
const fdm = @import("cli/fdm.zig");
const info = @import("cli/info.zig");
const tile = @import("cli/tile.zig");
const version = @import("cli/version.zig");
const resize = @import("cli/resize.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
};

const command_names = .{ "display", "resize", "fdm", "tile", "info", "version" };

const Command = struct {
    run: *const fn (Io, *std.Io.Writer, Allocator, *std.process.Args.Iterator) anyerror!void,
    description: []const u8,
    help: []const u8,
};

const commands = blk: {
    const KV = struct { []const u8, Command };
    var items: [command_names.len]KV = undefined;
    for (command_names, 0..) |name, i| {
        const module = @field(@This(), name);
        items[i] = .{ name, Command{
            .run = module.run,
            .description = module.description,
            .help = module.help_text,
        } };
    }
    break :blk std.StaticStringMap(Command).initComptime(items);
};

fn generateGeneralHelp() []const u8 {
    var text: []const u8 =
        \\Usage: zignal <command> [options]
        \\
        \\Commands:
        \\
    ;

    // First pass: find max length
    comptime var max_len = 0;
    inline for (command_names) |name| {
        if (name.len > max_len) max_len = name.len;
    }
    const help_cmd_len = "help".len;
    if (help_cmd_len > max_len) max_len = help_cmd_len;

    const padding_target = max_len + 2;

    inline for (command_names) |name| {
        const module = @field(@This(), name);
        // Take the first line of the description
        const desc = blk: {
            var iter = std.mem.splitSequence(u8, module.description, "\n");
            break :blk iter.first();
        };

        const padding_len = padding_target - name.len;
        const padding = " " ** padding_len;
        text = text ++ "  " ++ name ++ padding ++ desc ++ "\n";
    }

    // Add help command manually
    const padding_len = padding_target - "help".len;
    const padding = " " ** padding_len;
    text = text ++ "  help" ++ padding ++ "Display this help message\n";

    text = text ++
        \\
        \\Run 'zignal help <command>' for more information on a specific command.
        \\
    ;
    return text;
}

const general_help = generateGeneralHelp();

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);

    while (args.next()) |arg| {
        if (commands.get(arg)) |cmd| {
            cmd.run(init.io, &stdout.interface, init.gpa, &args) catch |err| {
                std.log.err("{s} command failed: {t}", .{ arg, err });
                std.process.exit(1);
            };
            return;
        }

        if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try help(&stdout.interface, &args);
            return;
        }

        std.log.err("Unknown command: '{s}'", .{arg});
        try help(&stdout.interface, null);
        std.process.exit(1);
    }
    try help(&stdout.interface, null);
}

fn help(stdout: *std.Io.Writer, args: ?*std.process.Args.Iterator) !void {
    if (args) |iterator| {
        if (iterator.next()) |subcmd| {
            if (commands.get(subcmd)) |cmd| {
                try stdout.print("{s}", .{cmd.help});
            } else if (std.mem.eql(u8, subcmd, "help")) {
                try stdout.print("{s}", .{general_help});
            } else {
                try stdout.print("Unknown command: \"{s}\"\n\n{s}", .{ subcmd, general_help });
                try stdout.flush();
                std.process.exit(1);
            }
            try stdout.flush();
            return;
        }
    }
    try stdout.print("{s}", .{general_help});
    try stdout.flush();
}
