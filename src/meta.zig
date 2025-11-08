const std = @import("std");

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
        else => @compileError(@typeName(@TypeOf(from)) ++ " is not supported."),
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

/// Strips all type names to their unqualified base names.
/// e.g., "zignal.Rgb" -> "Rgb", "std.builtin.Type" -> "Type"
pub inline fn getSimpleTypeName(comptime T: type) []const u8 {
    const full_name = @typeName(T);
    if (std.mem.lastIndexOf(u8, full_name, ".")) |dot_index| {
        return full_name[dot_index + 1 ..];
    }
    return full_name;
}

/// Converts a comptime string to lowercase.
/// e.g., "RGB" -> "rgb", "OkLab" -> "oklab"
pub inline fn comptimeLowercase(comptime input: []const u8) []const u8 {
    comptime var result: [input.len]u8 = undefined;
    inline for (input, 0..) |char, i| {
        result[i] = std.ascii.toLower(char);
    }
    return &result;
}

/// Returns true if and only if all fields of T are of type u8
pub fn allFieldsAreU8(comptime T: type) bool {
    return for (std.meta.fields(T)) |field| {
        if (field.type != u8) break false;
    } else true;
}

/// Clamps a value to the valid range for type T and converts it.
/// For unsigned integers, clamps to [0, maxInt(T)].
/// For signed integers, clamps to [minInt(T), maxInt(T)].
/// For floats, performs a direct cast without clamping.
///
/// Example usage:
/// ```zig
/// const clamped_u8 = meta.clamp(u8, -5); // Returns 0
/// const clamped_i16 = meta.clamp(i16, 40000); // Returns 32767
/// ```
pub inline fn clamp(comptime T: type, value: anytype) T {
    switch (@typeInfo(T)) {
        .int => |int_info| {
            const ValueType = @TypeOf(value);
            switch (@typeInfo(ValueType)) {
                .int, .comptime_int => {
                    return std.math.cast(T, value) orelse if (value < 0)
                        if (int_info.signedness == .unsigned) @as(T, 0) else std.math.minInt(T)
                    else
                        std.math.maxInt(T);
                },
                .float, .comptime_float => {
                    const min = if (int_info.signedness == .unsigned)
                        0.0
                    else
                        @as(f64, @floatFromInt(std.math.minInt(T)));
                    const max = @as(f64, @floatFromInt(std.math.maxInt(T)));
                    return @intFromFloat(std.math.clamp(@round(as(f64, value)), min, max));
                },
                else => @compileError("clamp only supports numeric inputs, got: " ++ @typeName(ValueType)),
            }
        },
        .float => return as(T, value),
        else => @compileError("clamp only supports integer and float types, got: " ++ @typeName(T)),
    }
}

/// Check if a type is an RGB or RGBA type with u8 components.
/// Returns true for structs with 3 or 4 u8 fields named (r,g,b[,a]) or (red,green,blue[,alpha]).
///
/// Example usage:
/// ```zig
/// const is_rgb = meta.isRgb(Rgb);  // true
/// const is_rgba = meta.isRgb(Rgba); // true
/// const not_rgb = meta.isRgb(Hsv); // false
/// ```
pub fn isRgb(comptime T: type) bool {
    const type_info = @typeInfo(T);
    if (type_info != .@"struct") return false;

    const fields = std.meta.fields(T);
    if (fields.len < 3 or fields.len > 4) return false;

    // Check first three fields are u8 and named appropriately
    if (fields[0].type != u8) return false;
    if (fields[1].type != u8) return false;
    if (fields[2].type != u8) return false;

    // Check for RGB naming pattern
    const has_rgb_names = (std.mem.eql(u8, fields[0].name, "r") and
        std.mem.eql(u8, fields[1].name, "g") and
        std.mem.eql(u8, fields[2].name, "b"));

    if (!has_rgb_names) return false;

    // If 4 fields, check alpha is also u8
    if (fields.len == 4) {
        return fields[3].type == u8;
    }

    return true;
}

/// Check if a struct type has an alpha channel (4th field named 'a' or 'alpha').
///
/// Example usage:
/// ```zig
/// const has_alpha = meta.hasAlphaChannel(Rgba); // true
/// const no_alpha = meta.hasAlphaChannel(Rgb);   // false
/// ```
pub fn hasAlphaChannel(comptime T: type) bool {
    const fields = std.meta.fields(T);
    if (fields.len != 4) return false;
    const last_field = fields[3];
    return std.mem.eql(u8, last_field.name, "a") or std.mem.eql(u8, last_field.name, "alpha");
}

/// Check if a type is specifically an RGBA type (RGB + alpha channel).
///
/// Example usage:
/// ```zig
/// const is_rgba = meta.isRgba(Rgba); // true
/// const not_rgba = meta.isRgba(Rgb); // false
/// ```
pub inline fn isRgba(comptime T: type) bool {
    return isRgb(T) and hasAlphaChannel(T);
}
