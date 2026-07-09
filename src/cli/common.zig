const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zignal = @import("zignal");

pub const OutputTarget = struct {
    path: []const u8,
    is_directory: bool,

    /// Resolve the destination path for a given input file. When the target is a
    /// directory, the result is owned by the caller (free via `ResolvedPath.deinit`).
    pub fn resolveOutputPath(self: OutputTarget, allocator: Allocator, input_path: []const u8) !ResolvedPath {
        if (self.is_directory) {
            const basename = Io.Dir.path.basename(input_path);
            const joined = try Io.Dir.path.join(allocator, &.{ self.path, basename });
            return .{ .path = joined, .owned = true };
        }
        return .{ .path = self.path, .owned = false };
    }
};

pub const ResolvedPath = struct {
    path: []const u8,
    owned: bool,

    pub fn deinit(self: ResolvedPath, allocator: Allocator) void {
        if (self.owned) allocator.free(self.path);
    }
};

pub fn resolveOutputTarget(
    io: Io,
    output_arg: []const u8,
    is_batch: bool,
) !OutputTarget {
    var is_directory = false;

    if (Io.Dir.cwd().openDir(io, output_arg, .{})) |dir| {
        dir.close(io);
        is_directory = true;
    } else |err| switch (err) {
        error.NotDir => {
            if (is_batch) {
                std.log.err("output path '{s}' is a file, but multiple input files were provided. batch output requires a directory.", .{output_arg});
                return error.InvalidArguments;
            }
            is_directory = false;
        },
        error.FileNotFound => {
            const ends_with_sep = std.mem.endsWith(u8, output_arg, "/") or std.mem.endsWith(u8, output_arg, "\\");
            if (ends_with_sep) {
                is_directory = true;
                std.log.debug("creating output directory '{s}'...", .{output_arg});
                try Io.Dir.cwd().createDirPath(io, output_arg);
            } else {
                if (is_batch) {
                    std.log.err("output path '{s}' does not exist and does not end with a separator. batch output requires a directory.", .{output_arg});
                    return error.InvalidArguments;
                }
                is_directory = false;
            }
        },
        else => return err,
    }

    return OutputTarget{
        .path = output_arg,
        .is_directory = is_directory,
    };
}

/// The tag enum of `zignal.Interpolation` — usable directly as a CLI/ZON option
/// field, since the tag names double as the accepted filter names.
pub const InterpolationTag = @typeInfo(zignal.Interpolation).@"union".tag_type.?;

/// Expands a selected interpolation tag into a full `Interpolation` value,
/// defaulting to bilinear when unset. The `mitchell` payload uses `.default`.
pub fn resolveFilter(tag: ?InterpolationTag) zignal.Interpolation {
    const t = tag orelse {
        std.log.debug("using default filter: bilinear", .{});
        return .bilinear;
    };
    return switch (t) {
        // The only variant with a payload — every other variant is bare.
        .mitchell => .{ .mitchell = .default },
        inline else => |x| @unionInit(zignal.Interpolation, @tagName(x), {}),
    };
}

/// Replace `-` with `_`. Used at parse time to normalize kebab-case CLI flag
/// values into the snake-case form expected by `std.meta.stringToEnum`. The
/// transform is idempotent on inputs without hyphens.
pub fn toSnake(name: []const u8, buf: []u8) []const u8 {
    std.debug.assert(buf.len >= name.len);
    for (name, 0..) |c, i| buf[i] = if (c == '-') '_' else c;
    return buf[0..name.len];
}

/// Looks up `T` from a CLI flag value, accepting either kebab- or snake-case.
/// Returns null for unknown values, including inputs longer than the longest
/// possible variant name (which cannot match anything).
pub fn parseEnum(comptime T: type, name: []const u8) ?T {
    const max_len = comptime blk: {
        var m: usize = 0;
        for (std.meta.fieldNames(T)) |field_name| {
            if (field_name.len > m) m = field_name.len;
        }
        break :blk m;
    };
    if (name.len > max_len) return null;
    var buf: [max_len]u8 = undefined;
    return std.meta.stringToEnum(T, toSnake(name, &buf));
}

/// Returns a comma-separated, kebab-cased string of `T`'s field names,
/// evaluated at comptime. Use to derive CLI help lists from an enum or
/// tagged union so help text cannot drift from the type. Tags without
/// underscores pass through unchanged.
pub fn joinFieldNames(comptime T: type) []const u8 {
    const names = std.meta.fieldNames(T);
    var result: []const u8 = "";
    inline for (names, 0..) |name, i| {
        inline for (name) |c| {
            result = result ++ &[_]u8{if (c == '_') '-' else c};
        }
        if (i < names.len - 1) result = result ++ ", ";
    }
    return result;
}

/// Measures wall-clock elapsed time and logs it at debug level.
pub const Timer = struct {
    io: Io,
    start: Io.Timestamp,

    pub fn begin(io: Io) Timer {
        return .{ .io = io, .start = Io.Clock.awake.now(io) };
    }

    pub fn logElapsed(self: Timer, comptime label: []const u8) void {
        const end = Io.Clock.awake.now(self.io);
        const ns = self.start.durationTo(end).toNanoseconds();
        std.log.debug(label ++ " took {d:.3} ms", .{@as(f64, @floatFromInt(ns)) / std.time.ns_per_ms});
    }
};
