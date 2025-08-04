/// Converts between numeric types: .@"enum", .int and .float.
pub inline fn as(comptime T: type, from: anytype) T {
    switch (@typeInfo(@TypeOf(from))) {
        .@"enum" => {
            switch (@typeInfo(T)) {
                .int => return @intFromEnum(from),
                else => @compileError(@typeName(@TypeOf(from)) ++ " can't be converted to " ++ @typeName(T)),
            }
        },
        .int => {
            switch (@typeInfo(T)) {
                .@"enum" => return @enumFromInt(from),
                .int => return @intCast(from),
                .float => return @floatFromInt(from),
                else => @compileError(@typeName(@TypeOf(from)) ++ " can't be converted to " ++ @typeName(T)),
            }
        },
        .float => {
            switch (@typeInfo(T)) {
                .float => return @floatCast(from),
                .int => return @intFromFloat(from),
                else => @compileError(@typeName(@TypeOf(from)) ++ " can't be converted to " ++ @typeName(T)),
            }
        },
        else => @compileError(@typeName(@TypeOf(from) ++ " is not supported.")),
    }
}

/// Returns true if and only if T represents a scalar type.
pub inline fn isScalar(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .comptime_int, .int, .comptime_float, .float => true,
        else => false,
    };
}

/// Returns true if and only if T represents a struct type.
pub inline fn isStruct(comptime T: type) bool {
    return @typeInfo(T) == .@"struct";
}

/// Returns true if and only if T is a packed struct.
/// Useful for determining memory layout and conversion strategies.
pub inline fn isPacked(comptime T: type) bool {
    const type_info = @typeInfo(T);
    return type_info == .@"struct" and type_info.@"struct".layout == .@"packed";
}

/// Returns true if and only if T is a struct with exactly 4 u8 fields.
/// This is used to identify pixel types suitable for SIMD optimization (e.g., RGBA, BGRA).
pub inline fn is4xu8Struct(comptime T: type) bool {
    return comptime blk: {
        if (@typeInfo(T) != .@"struct") break :blk false;
        const fields = @import("std").meta.fields(T);
        if (fields.len != 4) break :blk false;
        for (fields) |field| {
            if (field.type != u8) break :blk false;
        }
        break :blk true;
    };
}

/// Strips all type names to their unqualified base names.
/// e.g., "zignal.Rgb" -> "Rgb", "std.builtin.Type" -> "Type"
pub inline fn getSimpleTypeName(comptime T: type) []const u8 {
    const full_name = @typeName(T);
    const std = @import("std");
    if (std.mem.lastIndexOf(u8, full_name, ".")) |dot_index| {
        return full_name[dot_index + 1 ..];
    }
    return full_name;
}
