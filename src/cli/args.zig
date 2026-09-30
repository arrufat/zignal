//! Command-line argument parsing and help text generation.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const meta = @import("zignal").meta;
const common = @import("common.zig");

pub var runtime_log_level: std.log.Level = if (builtin.mode == .debug) .debug else .err;

/// Comma-separated list of valid `std.log.Level` names — shared by error messages
/// and help text so they cannot drift.
pub const log_level_names: []const u8 = common.joinFieldNames(std.log.Level);

/// Configuration for a specific command-line option.
pub const OptionConfig = struct {
    /// The descriptive help text for this option.
    help: []const u8,
    /// The name used for the value placeholder in the help message (e.g., "N" in "--width <N>").
    metavar: ?[]const u8 = null,
    /// Optional single-character alias, e.g. `.short = 'o'` for `--output`.
    /// `'h'` is reserved for `--help` and is ignored here.
    short: ?u8 = null,
};

/// How many positional arguments a command takes; a null `max` is unbounded.
pub const Positionals = struct {
    min: usize = 1,
    max: ?usize = null,

    pub const default: Positionals = .{};

    pub fn contains(self: Positionals, n: usize) bool {
        return n >= self.min and n <= self.max orelse n;
    }
};

/// The result of parsing command-line arguments.
pub fn ParseResult(comptime T: type) type {
    return struct {
        /// Populated struct containing the parsed options.
        options: T,
        /// Slice of positional arguments (non-flag/option arguments).
        positionals: [][]const u8,
        /// True if the user requested help (via --help or -h).
        help: bool,

        /// Frees the memory allocated for the positionals slice.
        pub fn deinit(self: *const @This(), allocator: Allocator) void {
            allocator.free(self.positionals);
        }
    };
}

/// Returns the underlying payload type if `T` is an optional, otherwise returns `T`.
fn PayloadType(comptime T: type) type {
    const info = @typeInfo(T);
    return if (info == .optional) info.optional.child else T;
}

/// Returns the single-character alias declared for `field_name` in `T.meta`,
/// or null if the field has no `meta` entry or no `.short`.
fn fieldShort(comptime T: type, comptime field_name: []const u8) ?u8 {
    if (!@hasDecl(T, "meta")) return null;
    if (!@hasField(@TypeOf(T.meta), field_name)) return null;
    const info = @field(T.meta, field_name);
    if (!@hasField(@TypeOf(info), "short")) return null;
    return info.short;
}

/// The 4-character help column prefix for a flag: `"-o, "` when a short alias
/// exists, or four spaces so long-only flags stay aligned under it.
fn shortPrefix(comptime T: type, comptime field_name: []const u8) [4]u8 {
    return if (fieldShort(T, field_name)) |s|
        [4]u8{ '-', s, ',', ' ' }
    else
        [4]u8{ ' ', ' ', ' ', ' ' };
}

/// Assigns the value for a matched option field, consuming a value from `args`
/// for non-boolean fields. Shared by the long (`--flag`) and short (`-f`) paths.
fn setOption(comptime T: type, comptime field: anytype, options: *T, args: *std.process.Args.Iterator) !void {
    const ChildType = PayloadType(field.type);

    if (ChildType == bool) {
        @field(options.*, field.name) = true;
        std.log.debug("option --{s} set to true", .{field.name});
        return;
    }

    const val_str = args.next() orelse {
        std.log.err("missing value for --{s}", .{field.name});
        return error.InvalidArguments;
    };

    if (ChildType == []const u8) {
        @field(options.*, field.name) = val_str;
        std.log.debug("option --{s} set to '{s}'", .{ field.name, val_str });
    } else if (@typeInfo(ChildType) == .int) {
        @field(options.*, field.name) = std.fmt.parseInt(ChildType, val_str, 10) catch {
            std.log.err("invalid value for --{s}: {s}", .{ field.name, val_str });
            return error.InvalidArguments;
        };
        std.log.debug("option --{s} set to {s}", .{ field.name, val_str });
    } else if (@typeInfo(ChildType) == .float) {
        @field(options.*, field.name) = std.fmt.parseFloat(ChildType, val_str) catch {
            std.log.err("invalid value for --{s}: {s}", .{ field.name, val_str });
            return error.InvalidArguments;
        };
        std.log.debug("option --{s} set to {s}", .{ field.name, val_str });
    } else if (@typeInfo(ChildType) == .@"enum") {
        // Accept either kebab- or snake-case, matching the ZON enum-literal names.
        @field(options.*, field.name) = common.parseEnum(ChildType, val_str) orelse {
            std.log.err("invalid value for --{s}: {s}", .{ field.name, val_str });
            return error.InvalidArguments;
        };
        std.log.debug("option --{s} set to {s}", .{ field.name, val_str });
    } else {
        @compileError("Unsupported type for arg parsing: " ++ @typeName(ChildType));
    }
}

/// Checks if the argument is a log level flag and parses it.
/// Returns true if consumed, false otherwise.
pub fn parseLogLevel(arg: []const u8, args: *std.process.Args.Iterator) !bool {
    if (!std.mem.eql(u8, arg, "--log-level")) return false;

    const level_str = args.next() orelse {
        std.log.err("missing value for --log-level", .{});
        return error.InvalidArguments;
    };
    runtime_log_level = std.meta.stringToEnum(std.log.Level, level_str) orelse {
        std.log.err("invalid log level: {s}. supported levels: {s}", .{ level_str, log_level_names });
        return error.InvalidArguments;
    };
    return true;
}

/// Parses command-line arguments into a struct of type `T`.
/// `T` is a struct whose fields represent options (e.g., `width: ?u32`).
/// Boolean fields are treated as flags (no value required).
/// Supported types: `bool`, integers, floats, enums, and `[]const u8`.
pub fn parse(comptime T: type, allocator: Allocator, args: *std.process.Args.Iterator) !ParseResult(T) {
    std.log.debug("parsing arguments for type {s}...", .{@typeName(T)});
    var options: T = .{};
    var positionals: std.ArrayList([]const u8) = .empty;
    errdefer positionals.deinit(allocator);
    var help_requested = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            help_requested = true;
            continue;
        }
        if (try parseLogLevel(arg, args)) continue;

        if (std.mem.eql(u8, arg, "--")) {
            while (args.next()) |pos| {
                try positionals.append(allocator, pos);
            }
            break;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            const flag_name = arg[2..];
            var found = false;

            inline for (comptime meta.structFields(T)) |field| {
                const matches = blk: {
                    if (flag_name.len != field.name.len) break :blk false;
                    for (flag_name, field.name) |c_flag, c_field| {
                        if (c_flag == c_field) continue;
                        if (c_flag == '-' and c_field == '_') continue;
                        break :blk false;
                    }
                    break :blk true;
                };

                if (matches) {
                    found = true;
                    try setOption(T, field, &options, args);
                }
            }
            if (!found) {
                std.log.err("unknown option: {s}", .{arg});
                return error.InvalidArguments;
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            // Short alias, e.g. `-o`. Only single-character shorts are supported.
            if (arg.len != 2) {
                std.log.err("unknown option: {s}", .{arg});
                return error.InvalidArguments;
            }
            const short = arg[1];
            var found = false;

            inline for (comptime meta.structFields(T)) |field| {
                if (comptime fieldShort(T, field.name)) |s| {
                    if (s == short) {
                        found = true;
                        try setOption(T, field, &options, args);
                    }
                }
            }
            if (!found) {
                std.log.err("unknown option: {s}", .{arg});
                return error.InvalidArguments;
            }
        } else {
            try positionals.append(allocator, arg);
        }
    }
    return .{
        .options = options,
        .positionals = try positionals.toOwnedSlice(allocator),
        .help = help_requested,
    };
}

fn kebabName(comptime name: []const u8) [name.len]u8 {
    var res: [name.len]u8 = undefined;
    for (name, 0..) |c, i| {
        res[i] = if (c == '_') '-' else c;
    }
    return res;
}

/// The `meta` entry for `field_name`, or a placeholder when it has none.
fn fieldConfig(comptime T: type, comptime field_name: []const u8) OptionConfig {
    if (!@hasDecl(T, "meta") or !@hasField(@TypeOf(T.meta), field_name)) return .{ .help = "No description" };
    const info = @field(T.meta, field_name);
    return .{
        .help = info.help,
        .metavar = if (@hasField(@TypeOf(info), "metavar")) info.metavar else null,
    };
}

/// The help column for `field`: `"  -o, --output <path>"`, without the value for flags.
fn flagString(comptime T: type, comptime field: anytype) []const u8 {
    const flag = "  " ++ shortPrefix(T, field.name) ++ "--" ++ kebabName(field.name);
    if (PayloadType(field.type) == bool) return flag;
    return flag ++ " <" ++ (fieldConfig(T, field.name).metavar orelse "value") ++ ">";
}

/// Generates a formatted help message at compile-time based on the struct T.
/// T can optionally contain a `meta` declaration of type `struct { [field_name]: OptionConfig }`.
pub fn generateHelp(comptime T: type, comptime usage_line: []const u8, comptime description: []const u8) []const u8 {
    @setEvalBranchQuota(10_000);
    var text: []const u8 = "Usage: " ++ usage_line ++ "\n\n" ++ description ++ "\n\n";

    const fields = comptime meta.structFields(T);
    if (fields.len > 0) {
        text = text ++ "Options:\n";
    }

    comptime var max_len = 0;
    inline for (fields) |field| max_len = @max(max_len, flagString(T, field).len);

    inline for (fields) |field| {
        const flag_str = flagString(T, field);
        const padding: [max_len + 2 - flag_str.len]u8 = @splat(' ');
        text = text ++ flag_str ++ padding ++ fieldConfig(T, field.name).help ++ "\n";
    }
    return text;
}

/// Prints the help message to stdout using the provided writer.
pub fn printHelp(writer: *Io.Writer, help: []const u8) !void {
    try writer.print("{s}", .{help});
    try writer.flush();
}
