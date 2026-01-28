const std = @import("std");
const zignal = @import("zignal");
const Io = std.Io;

pub const OutputTarget = struct {
    path: []const u8,
    is_directory: bool,
};

pub fn resolveOutputTarget(
    io: Io,
    output_arg: []const u8,
    is_batch: bool,
) !OutputTarget {
    var is_directory = false;

    // Try to open it as a directory first. This is the most robust check.
    if (std.Io.Dir.cwd().openDir(io, output_arg, .{})) |dir| {
        dir.close(io);
        is_directory = true;
    } else |err| switch (err) {
        error.NotDir => {
            // It exists but it's not a directory, so it's a file.
            if (is_batch) {
                std.log.err("Output path '{s}' is a file, but multiple input files were provided. Batch output requires a directory.", .{output_arg});
                return error.InvalidArguments;
            }
            is_directory = false;
        },
        error.FileNotFound => {
            // It doesn't exist. Infer intent from trailing separator.
            const ends_with_sep = std.mem.endsWith(u8, output_arg, "/") or std.mem.endsWith(u8, output_arg, "\\");
            if (ends_with_sep) {
                is_directory = true;
                std.log.debug("Creating output directory '{s}'...", .{output_arg});
                try std.Io.Dir.cwd().createDirPath(io, output_arg);
            } else {
                if (is_batch) {
                    std.log.err("Output path '{s}' does not exist and does not end with a separator. Batch output requires a directory.", .{output_arg});
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

pub fn parseFilter(name: []const u8) !zignal.Interpolation {
    const filter_map = std.StaticStringMap(zignal.Interpolation).initComptime(.{
        .{ "nearest", .nearest_neighbor },
        .{ "bilinear", .bilinear },
        .{ "bicubic", .bicubic },
        .{ "lanczos", .lanczos },
        .{ "catmull-rom", .catmull_rom },
        .{ "mitchell", zignal.Interpolation{ .mitchell = .default } },
    });
    if (filter_map.get(name)) |f_enum| {
        return f_enum;
    } else {
        return error.InvalidArguments;
    }
}

pub fn resolveFilter(name: ?[]const u8) !zignal.Interpolation {
    if (name) |n| {
        std.log.debug("Resolving filter: {s}", .{n});
        return parseFilter(n) catch |err| {
            std.log.err("Unknown filter type: {s}", .{n});
            return err;
        };
    }
    std.log.debug("Using default filter: bilinear", .{});
    return .bilinear;
}
