const std = @import("std");
const zignal = @import("zignal");

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
