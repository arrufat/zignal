const std = @import("std");

/// Converts between numeric types: .@"enum", .int and .float.
pub fn as(comptime T: type, from: anytype) T {
    return switch (@typeInfo(@TypeOf(from))) {
        .@"enum" => {
            return switch (@typeInfo(T)) {
                .int => @intFromEnum(from),
                else => @compileError(@typeName(@TypeOf(from)) ++ " can't be converted to " ++ @typeName(T)),
            };
        },
        .int, .comptime_int => {
            return switch (@typeInfo(T)) {
                .@"enum" => @enumFromInt(from),
                .int => @intCast(from),
                .float => @floatFromInt(from),
                else => @compileError(@typeName(@TypeOf(from)) ++ " can't be converted to " ++ @typeName(T)),
            };
        },
        .float, .comptime_float => {
            return switch (@typeInfo(T)) {
                .float => @floatCast(from),
                .int => @intFromFloat(@round(from)),
                else => @compileError(@typeName(@TypeOf(from)) ++ " can't be converted to " ++ @typeName(T)),
            };
        },
        else => @compileError(@typeName(@TypeOf(from)) ++ " is not supported."),
    };
}

/// Returns true if and only if T represents a scalar type.
pub fn isScalar(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .comptime_int, .int, .comptime_float, .float => true,
        else => false,
    };
}

/// Returns true if and only if T is a packed struct.
/// Useful for determining memory layout and conversion strategies.
pub fn isPacked(comptime T: type) bool {
    const type_info = @typeInfo(T);
    return type_info == .@"struct" and type_info.@"struct".layout == .@"packed";
}

/// Strips all type names to their unqualified base names.
/// e.g., "zignal.Rgb" -> "Rgb", "std.builtin.Type" -> "Type"
pub fn getSimpleTypeName(comptime T: type) []const u8 {
    const full_name = @typeName(T);
    if (std.mem.findLast(u8, full_name, ".")) |dot_index| {
        return full_name[dot_index + 1 ..];
    }
    return full_name;
}

/// Strips generic type parameters from a simple type name.
/// e.g., "Rgb(u8)" -> "Rgb"
pub fn getGenericBaseName(comptime T: type) []const u8 {
    const name = getSimpleTypeName(T);
    if (std.mem.findScalar(u8, name, '(')) |idx| {
        return name[0..idx];
    }
    return name;
}

/// Converts a comptime string to lowercase.
/// e.g., "RGB" -> "rgb", "OkLab" -> "oklab"
pub fn comptimeLowercase(comptime input: []const u8) []const u8 {
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
pub fn clamp(comptime T: type, value: anytype) T {
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
pub fn isRgba(comptime T: type) bool {
    return isRgb(T) and hasAlphaChannel(T);
}

/// Safely casts a value to type T, returning an error if the value is out of range.
/// Supports casting from float to int (with rounding and bounds check).
pub fn safeCast(comptime T: type, value: anytype) !T {
    const ValueType = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int => |int_info| {
            switch (@typeInfo(ValueType)) {
                .int, .comptime_int => return std.math.cast(T, value) orelse error.Overflow,
                .float, .comptime_float => {
                    if (!std.math.isFinite(value)) return error.Overflow;
                    const rounded = @round(value);
                    const min_limit = @as(f64, @floatFromInt(std.math.minInt(T)));
                    const max_limit = @as(f64, @floatFromInt(std.math.maxInt(T)));
                    if (rounded < min_limit or rounded > max_limit) return error.Overflow;
                    // Special check for negative zero or small negative floats casting to unsigned
                    if (int_info.signedness == .unsigned and rounded < 0) return error.Overflow;
                    return @intFromFloat(rounded);
                },
                else => @compileError("safeCast only supports numeric inputs"),
            }
        },
        .float => {
            switch (@typeInfo(ValueType)) {
                .int, .comptime_int, .float, .comptime_float => return @floatCast(value),
                else => @compileError("safeCast only supports numeric inputs"),
            }
        },
        else => @compileError("safeCast only supports numeric target types"),
    }
}

test "meta.clamp" {
    const expect = std.testing.expect;

    // Int to Int
    try expect(clamp(u8, 256) == 255);
    try expect(clamp(u8, -1) == 0);
    try expect(clamp(u8, 100) == 100);

    // Float to Int
    try expect(clamp(u8, 100.4) == 100);
    try expect(clamp(u8, 100.6) == 101); // Rounding
    try expect(clamp(u8, -10.0) == 0);
    try expect(clamp(u8, 300.0) == 255);

    // Signed Int
    try expect(clamp(i8, -130) == -128);
    try expect(clamp(i8, 130) == 127);

    // Float to Float
    try expect(clamp(f32, 1.5) == 1.5);
}

/// Normalizes a value from [min, max] to [0, 1] and clamps it.
/// Returns 0 if max <= min to avoid division by zero.
/// Only supports floating point types.
pub fn normalize(comptime T: type, value: T, min: T, max: T) T {
    if (@typeInfo(T) != .float) @compileError("normalize requires floating point type");
    if (max <= min) return 0;
    return std.math.clamp((value - min) / (max - min), 0, 1);
}
