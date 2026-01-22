const std = @import("std");
const Allocator = std.mem.Allocator;

/// Configuration for a specific command-line option.
pub const OptionConfig = struct {
    /// The descriptive help text for this option.
    help: []const u8,
    /// The name used for the value placeholder in the help message (e.g., "N" in "--width <N>").
    metavar: ?[]const u8 = null,
};

/// The result of parsing command-line arguments.
pub fn ParseResult(comptime T: type) type {
    return struct {
        /// Populated struct containing the parsed options.
        options: T,
        /// Slice of positional arguments (non-flag/option arguments).
        positionals: [][]const u8,

        /// Frees the memory allocated for the positionals slice.
        pub fn deinit(self: *const @This(), allocator: Allocator) void {
            allocator.free(self.positionals);
        }
    };
}

/// Helper to get the underlying type of an optional or return the type itself.
fn PayloadType(comptime T: type) type {
    const info = @typeInfo(T);
    return if (info == .optional) info.optional.child else T;
}

/// Parses command-line arguments into a struct of type T.
/// T should be a struct where fields represent options (e.g., `width: ?u32`).
/// Boolean fields are treated as flags (no value required).
/// Supported types: bool, integer types, and []const u8.
pub fn parse(comptime T: type, allocator: Allocator, args: *std.process.Args.Iterator) !ParseResult(T) {
    var options: T = .{};
    var positionals: std.ArrayList([]const u8) = .empty;
    errdefer positionals.deinit(allocator);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--")) {
            while (args.next()) |pos| {
                try positionals.append(allocator, pos);
            }
            break;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            const flag_name = arg[2..];
            var found = false;

            inline for (std.meta.fields(T)) |field| {
                if (std.mem.eql(u8, flag_name, field.name)) {
                    found = true;
                    const ChildType = PayloadType(field.type);

                    if (ChildType == bool) {
                        @field(options, field.name) = true;
                    } else {
                        const val_str = args.next() orelse {
                            std.log.err("Missing value for --{s}", .{field.name});
                            return error.InvalidArguments;
                        };

                        if (ChildType == []const u8) {
                            @field(options, field.name) = val_str;
                        } else if (@typeInfo(ChildType) == .int) {
                            @field(options, field.name) = std.fmt.parseInt(ChildType, val_str, 10) catch {
                                std.log.err("Invalid value for --{s}: {s}", .{ field.name, val_str });
                                return error.InvalidArguments;
                            };
                        } else {
                            @compileError("Unsupported type for arg parsing: " ++ @typeName(ChildType));
                        }
                    }
                }
            }
            if (!found) {
                std.log.err("Unknown option: {s}", .{arg});
                return error.InvalidArguments;
            }
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.log.err("Unknown option: {s}", .{arg});
            return error.InvalidArguments;
        } else {
            try positionals.append(allocator, arg);
        }
    }
    return .{ .options = options, .positionals = try positionals.toOwnedSlice(allocator) };
}

/// Generates a formatted help message at compile-time based on the struct T.
/// T can optionally contain a `meta` declaration of type `struct { [field_name]: OptionConfig }`.
pub fn generateHelp(comptime T: type, comptime usage_line: []const u8, comptime description: []const u8) []const u8 {
    var text: []const u8 = "Usage: " ++ usage_line ++ "\n\n" ++ description ++ "\n\n";

    const fields = std.meta.fields(T);
    if (fields.len > 0) {
        text = text ++ "Options:\n";
    }

    comptime var max_len = 0;
    inline for (fields) |field| {
        const is_bool = PayloadType(field.type) == bool;
        const info = if (@hasDecl(T, "meta") and @hasField(@TypeOf(T.meta), field.name))
            @field(T.meta, field.name)
        else
            OptionConfig{ .help = "No description" };

        const metavar = if (@hasField(@TypeOf(info), "metavar"))
            switch (@typeInfo(@TypeOf(info.metavar))) {
                .optional => info.metavar orelse "value",
                else => info.metavar,
            }
        else
            "value";

        const flag_len = if (is_bool)
            ("  --" ++ field.name).len
        else
            ("  --" ++ field.name ++ " <" ++ metavar ++ ">").len;

        if (flag_len > max_len) max_len = flag_len;
    }

    const padding_target = max_len + 2;

    inline for (fields) |field| {
        const meta_info = if (@hasDecl(T, "meta") and @hasField(@TypeOf(T.meta), field.name))
            @field(T.meta, field.name)
        else
            OptionConfig{ .help = "No description" };

        const metavar = if (@hasField(@TypeOf(meta_info), "metavar")) blk: {
            const m = meta_info.metavar;
            break :blk if (@typeInfo(@TypeOf(m)) == .optional) m orelse "value" else m;
        } else "value";

        const is_bool = PayloadType(field.type) == bool;

        const flag_str = if (is_bool)
            "  --" ++ field.name
        else
            "  --" ++ field.name ++ " <" ++ metavar ++ ">";

        const padding_len = padding_target - flag_str.len;
        const padding = " " ** padding_len;

        text = text ++ flag_str ++ padding ++ meta_info.help ++ "\n";
    }
    return text;
}
