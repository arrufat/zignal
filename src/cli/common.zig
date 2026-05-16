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

/// Resolves the user's `--filter` string (if any) into an interpolation method.
/// Defaults to bilinear.
pub fn resolveFilter(name: ?[]const u8) !zignal.Interpolation {
    const n = name orelse {
        std.log.debug("using default filter: bilinear", .{});
        return .bilinear;
    };
    std.log.debug("resolving filter: {s}", .{n});
    const filter_map = std.StaticStringMap(zignal.Interpolation).initComptime(.{
        .{ "nearest", .nearest_neighbor },
        .{ "bilinear", .bilinear },
        .{ "bicubic", .bicubic },
        .{ "lanczos", .lanczos },
        .{ "catmull-rom", .catmull_rom },
        .{ "mitchell", zignal.Interpolation{ .mitchell = .default } },
    });
    return filter_map.get(n) orelse {
        std.log.err("unknown filter type: {s}", .{n});
        return error.InvalidArguments;
    };
}

/// Returns a comma-separated string of `T`'s field names, evaluated at comptime.
/// Useful for help text and error messages derived from an enum or tagged union
/// so the rendered list cannot drift from the type definition.
pub fn joinFieldNames(comptime T: type) []const u8 {
    const fields = std.meta.fields(T);
    var names: []const u8 = "";
    for (fields, 0..) |field, i| {
        names = names ++ field.name;
        if (i < fields.len - 1) names = names ++ ", ";
    }
    return names;
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
