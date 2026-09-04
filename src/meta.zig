const std = @import("std");

/// Converts between numeric types: .@"enum", .int and .float.
pub fn as(comptime T: type, from: anytype) T {
    return switch (@typeInfo(@TypeOf(from))) {
        .@"enum" => {
            return switch (@typeInfo(T)) {
                .int => @backingInt(from),
                else => @compileError(@typeName(@TypeOf(from)) ++ " can't be converted to " ++ @typeName(T)),
            };
        },
        .int, .comptime_int => {
            return switch (@typeInfo(T)) {
                .@"enum" => @fromBackingInt(from),
                .int => @intCast(from),
                .float => @floatFromInt(from),
                else => @compileError(@typeName(@TypeOf(from)) ++ " can't be converted to " ++ @typeName(T)),
            };
        },
        .float, .comptime_float => {
            return switch (@typeInfo(T)) {
                .float => @floatCast(from),
                .int => @round(from),
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

/// A struct field's name, type and default value, mirroring the old `std.builtin.Type.StructField`.
pub const FieldDesc = struct { name: [:0]const u8, type: type, default_value_ptr: ?*const anyopaque };

/// Replacement for the removed `std.meta.fields` (struct kind). Comptime-only;
/// call in a comptime context, e.g. `inline for (comptime meta.structFields(T))`.
pub fn structFields(comptime T: type) []const FieldDesc {
    return comptime blk: {
        const info = @typeInfo(T).@"struct";
        var result: [info.field_names.len]FieldDesc = undefined;
        for (info.field_names, info.field_types, info.field_attrs, 0..) |field_name, field_type, attrs, i| {
            result[i] = .{ .name = field_name, .type = field_type, .default_value_ptr = attrs.default_value_ptr };
        }
        const final = result;
        break :blk &final;
    };
}

/// Returns true if and only if all fields of T are of type u8
pub fn allFieldsAreU8(comptime T: type) bool {
    return for (comptime structFields(T)) |field| {
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
                        @as(f64, std.math.minInt(T));
                    const max = @as(f64, std.math.maxInt(T));
                    return @trunc(std.math.clamp(@round(as(f64, value)), min, max));
                },
                else => @compileError("clamp only supports numeric inputs, got: " ++ @typeName(ValueType)),
            }
        },
        .float => return as(T, value),
        else => @compileError("clamp only supports integer and float types, got: " ++ @typeName(T)),
    }
}

/// Narrows integer vector lanes already in 0..255 to bytes. `@intCast` to `u8` lanes is lowered
/// as a signed saturating pack in release builds (zig 0.17.0-dev.1970), which turns 128..255
/// into 127; truncating the unsigned view of the lanes sidesteps it.
pub fn narrowToBytes(v: anytype) @Vector(@typeInfo(@TypeOf(v)).vector.len, u8) {
    const info = @typeInfo(@TypeOf(v)).vector;
    const V = @TypeOf(v);
    if (std.debug.runtime_safety) {
        std.debug.assert(@reduce(.And, v >= @as(V, @splat(0))) and @reduce(.And, v <= @as(V, @splat(255))));
    }
    const Unsigned = @Vector(info.len, @Int(.unsigned, @typeInfo(info.child).int.bits));
    return @truncate(@as(Unsigned, @bitCast(v)));
}

/// Rounds f32 lanes to bytes, clamping to 0..255 first.
pub fn roundToBytes(v: anytype) @Vector(@typeInfo(@TypeOf(v)).vector.len, u8) {
    const V = @TypeOf(v);
    return @round(std.math.clamp(v, @as(V, @splat(0)), @as(V, @splat(255))));
}

/// Shuffle masks for a stride-`n` running window over `B` lanes: `repeat` broadcasts the
/// `n` window sums across the block and `tail` picks the block's last `n` lanes.
pub fn StrideMasks(comptime B: usize, comptime n: usize) type {
    return struct {
        pub const repeat: [B]i32 = blk: {
            var m: [B]i32 = undefined;
            for (&m, 0..) |*e, j| e.* = @intCast(j % n);
            break :blk m;
        };
        pub const tail: [n]i32 = blk: {
            var m: [n]i32 = undefined;
            for (&m, 0..) |*e, t| e.* = @intCast(B - n + t);
            break :blk m;
        };
    };
}

/// Check if a type is an RGB or RGBA type with u8 components.
/// Returns true for structs with 3 or 4 u8 fields named r, g, b[, a].
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

    const fields = comptime structFields(T);
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
                    const min_limit: f64 = @floatFromInt(std.math.minInt(T));
                    const max_limit: f64 = @floatFromInt(std.math.maxInt(T));
                    if (rounded < min_limit or rounded > max_limit) return error.Overflow;
                    // Special check for negative zero or small negative floats casting to unsigned
                    if (int_info.signedness == .unsigned and rounded < 0) return error.Overflow;
                    return @trunc(rounded);
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

test "meta.narrowToBytes keeps lanes above 127" {
    var lanes: [16]i32 = undefined;
    for (&lanes, 0..) |*lane, i| lane.* = @intCast(120 + 9 * i);
    std.mem.doNotOptimizeAway(&lanes);
    const bytes: [16]u8 = narrowToBytes(@as(@Vector(16, i32), lanes));
    for (bytes, lanes) |byte, lane| try std.testing.expectEqual(lane, byte);
    const wide: [8]u8 = narrowToBytes(@as(@Vector(8, i16), .{ 0, 1, 127, 128, 129, 200, 254, 255 }));
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 127, 128, 129, 200, 254, 255 }, &wide);
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
/// Returns 0 if value, min, or max are NaN to avoid undefined behavior/panics.
/// Only supports floating point types.
pub fn normalize(comptime T: type, value: T, min: T, max: T) T {
    if (@typeInfo(T) != .float) @compileError("normalize requires floating point type");
    if (std.math.isNan(value) or std.math.isNan(min) or std.math.isNan(max)) return 0;
    if (max <= min) return 0;
    return std.math.clamp((value - min) / (max - min), 0, 1);
}
