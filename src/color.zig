//! Color module - All color types and utilities
//!
//! This module provides a unified interface to all color types in the system.
//! Each color type is implemented as a separate file using Zig's file-as-struct pattern.

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;

const blending = @import("color/blending.zig");
pub const Blending = blending.Blending;
pub const blendColors = blending.blendColors;
const conversions = @import("color/conversions.zig");
pub const convertColor = conversions.convertColor;
pub const isColor = conversions.isColor;
pub const Hsl = @import("color/Hsl.zig");
pub const Hsv = @import("color/Hsv.zig");
pub const Lab = @import("color/Lab.zig");
pub const Lch = @import("color/Lch.zig");
pub const Lms = @import("color/Lms.zig");
pub const Oklab = @import("color/Oklab.zig");
pub const Oklch = @import("color/Oklch.zig");
pub const Rgb = @import("color/Rgb.zig");
pub const Rgba = @import("color/Rgba.zig").Rgba;
pub const Xyb = @import("color/Xyb.zig");
pub const Xyz = @import("color/Xyz.zig");
pub const Ycbcr = @import("color/Ycbcr.zig");
const getSimpleTypeName = @import("meta.zig").getSimpleTypeName;

// ============================================================================
// TESTS
// ============================================================================

// Import tests from sub-modules
test {
    _ = @import("color/blending.zig");
}

// Helper function for testing round-trip conversions
fn testColorConversion(from: Rgb, to: anytype) !void {
    const converted = convertColor(@TypeOf(to), from);
    try expectEqualDeep(converted, to);
    const recovered = convertColor(Rgb, converted);
    try expectEqualDeep(recovered, from);
}

test "convert grayscale" {
    try expectEqual(convertColor(u8, Rgb{ .r = 128, .g = 128, .b = 128 }), 128);
    try expectEqual(convertColor(u8, Hsl{ .h = 0, .s = 100, .l = 50 }), 54);
    try expectEqual(convertColor(u8, Hsv{ .h = 0, .s = 100, .v = 50 }), 27);
    try expectEqual(convertColor(u8, Lab{ .l = 50, .a = 0, .b = 0 }), 119);
}

test "Rgb fromHex and toHex" {
    // Test fromHex with various colors
    try expectEqualDeep(Rgb.fromHex(0x4e008e), Rgb{ .r = 78, .g = 0, .b = 142 });
    try expectEqualDeep(Rgb.fromHex(0x000000), Rgb{ .r = 0, .g = 0, .b = 0 });
    try expectEqualDeep(Rgb.fromHex(0xffffff), Rgb{ .r = 255, .g = 255, .b = 255 });
    try expectEqualDeep(Rgb.fromHex(0xff0000), Rgb{ .r = 255, .g = 0, .b = 0 });
    try expectEqualDeep(Rgb.fromHex(0x00ff00), Rgb{ .r = 0, .g = 255, .b = 0 });
    try expectEqualDeep(Rgb.fromHex(0x0000ff), Rgb{ .r = 0, .g = 0, .b = 255 });
    try expectEqualDeep(Rgb.fromHex(0x808080), Rgb{ .r = 128, .g = 128, .b = 128 });

    // Test toHex converts back correctly
    const purple = Rgb{ .r = 78, .g = 0, .b = 142 };
    try expectEqual(purple.toHex(), 0x4e008e);

    const black = Rgb{ .r = 0, .g = 0, .b = 0 };
    try expectEqual(black.toHex(), 0x000000);

    const white = Rgb{ .r = 255, .g = 255, .b = 255 };
    try expectEqual(white.toHex(), 0xffffff);

    const red = Rgb{ .r = 255, .g = 0, .b = 0 };
    try expectEqual(red.toHex(), 0xff0000);

    // Test round-trip conversion
    const test_colors = [_]u24{ 0x123456, 0xabcdef, 0x987654, 0xfedcba, 0x111111, 0xeeeeee };
    for (test_colors) |hex_color| {
        const rgb = Rgb.fromHex(hex_color);
        const converted_back = rgb.toHex();
        try expectEqual(converted_back, hex_color);
    }
}

test "Rgba fromHex and toHex" {
    // Test fromHex with various colors (RGBA format)
    try expectEqualDeep(Rgba.fromHex(0x4e008eff), Rgba{ .r = 78, .g = 0, .b = 142, .a = 255 });
    try expectEqualDeep(Rgba.fromHex(0x000000ff), Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 });
    try expectEqualDeep(Rgba.fromHex(0xffffff00), Rgba{ .r = 255, .g = 255, .b = 255, .a = 0 });
    try expectEqualDeep(Rgba.fromHex(0xff000080), Rgba{ .r = 255, .g = 0, .b = 0, .a = 128 });
    try expectEqualDeep(Rgba.fromHex(0x00ff00c0), Rgba{ .r = 0, .g = 255, .b = 0, .a = 192 });
    try expectEqualDeep(Rgba.fromHex(0x0000ff40), Rgba{ .r = 0, .g = 0, .b = 255, .a = 64 });

    // Test toHex converts back correctly
    const purple_alpha = Rgba{ .r = 78, .g = 0, .b = 142, .a = 255 };
    try expectEqual(purple_alpha.toHex(), 0x4e008eff);

    const transparent_white = Rgba{ .r = 255, .g = 255, .b = 255, .a = 0 };
    try expectEqual(transparent_white.toHex(), 0xffffff00);

    const semi_red = Rgba{ .r = 255, .g = 0, .b = 0, .a = 128 };
    try expectEqual(semi_red.toHex(), 0xff000080);

    // Test round-trip conversion
    const test_colors = [_]u32{ 0x12345678, 0xabcdef90, 0x98765432, 0xfedcba01, 0x11111111, 0xeeeeeeee };
    for (test_colors) |hex_color| {
        const rgba = Rgba.fromHex(hex_color);
        const converted_back = rgba.toHex();
        try expectEqual(converted_back, hex_color);
    }

    // Test edge cases
    try expectEqualDeep(Rgba.fromHex(0x00000000), Rgba.transparent);
    try expectEqualDeep(Rgba.fromHex(0x000000ff), Rgba.black);
    try expectEqualDeep(Rgba.fromHex(0xffffffff), Rgba.white);
}

test "primary colors" {
    // red: 0xff0000
    try testColorConversion(.{ .r = 255, .g = 0, .b = 0 }, Hsl{ .h = 0, .s = 100, .l = 50 });
    try testColorConversion(.{ .r = 255, .g = 0, .b = 0 }, Hsv{ .h = 0, .s = 100, .v = 100 });
    try testColorConversion(.{ .r = 255, .g = 0, .b = 0 }, Lab{ .l = 53.23288178584245, .a = 80.10930952982204, .b = 67.22006831026425 });
    // green: 0x00ff00
    try testColorConversion(.{ .r = 0, .g = 255, .b = 0 }, Hsl{ .h = 120, .s = 100, .l = 50 });
    try testColorConversion(.{ .r = 0, .g = 255, .b = 0 }, Hsv{ .h = 120, .s = 100, .v = 100 });
    try testColorConversion(.{ .r = 0, .g = 255, .b = 0 }, Lab{ .l = 87.73703347354422, .a = -86.1846364976253, .b = 83.18116474777855 });
    // blue: 0x0000ff
    try testColorConversion(.{ .r = 0, .g = 0, .b = 255 }, Hsl{ .h = 240, .s = 100, .l = 50 });
    try testColorConversion(.{ .r = 0, .g = 0, .b = 255 }, Hsv{ .h = 240, .s = 100, .v = 100 });
    try testColorConversion(.{ .r = 0, .g = 0, .b = 255 }, Lab{ .l = 32.302586667249486, .a = 79.19666178930935, .b = -107.86368104495168 });
}

test "secondary colors" {
    // cyan: 0x00ffff
    try testColorConversion(.{ .r = 0, .g = 255, .b = 255 }, Hsl{ .h = 180, .s = 100, .l = 50 });
    try testColorConversion(.{ .r = 0, .g = 255, .b = 255 }, Hsv{ .h = 180, .s = 100, .v = 100 });
    try testColorConversion(.{ .r = 0, .g = 255, .b = 255 }, Lab{ .l = 91.11652110946342, .a = -48.079618466228716, .b = -14.138127754846131 });
    // magenta: 0xff00ff
    try testColorConversion(.{ .r = 255, .g = 0, .b = 255 }, Hsl{ .h = 300, .s = 100, .l = 50 });
    try testColorConversion(.{ .r = 255, .g = 0, .b = 255 }, Hsv{ .h = 300, .s = 100, .v = 100 });
    try testColorConversion(.{ .r = 255, .g = 0, .b = 255 }, Lab{ .l = 60.319933664076004, .a = 98.25421868616108, .b = -60.84298422386232 });
    // yellow: 0xffff00
    try testColorConversion(.{ .r = 255, .g = 255, .b = 0 }, Hsl{ .h = 60, .s = 100, .l = 50 });
    try testColorConversion(.{ .r = 255, .g = 255, .b = 0 }, Hsv{ .h = 60, .s = 100, .v = 100 });
    try testColorConversion(.{ .r = 255, .g = 255, .b = 0 }, Lab{ .l = 97.13824698129729, .a = -21.555908334832285, .b = 94.48248544644461 });
}

test "complementary colors" {
    // orange: 0xff8800
    try testColorConversion(.{ .r = 255, .g = 136, .b = 0 }, Hsl{ .h = 32, .s = 100, .l = 50 });
    try testColorConversion(.{ .r = 255, .g = 136, .b = 0 }, Hsv{ .h = 32, .s = 100, .v = 100 });
    try testColorConversion(.{ .r = 255, .g = 136, .b = 0 }, Lab{ .l = 68.65577208167872, .a = 38.85052375564019, .b = 74.99022544139406 });
    // purple: 0x800080
    try testColorConversion(.{ .r = 128, .g = 0, .b = 128 }, Hsl{ .h = 300, .s = 100, .l = 25.098039215686274 });
    try testColorConversion(.{ .r = 128, .g = 0, .b = 128 }, Hsv{ .h = 300, .s = 100, .v = 50.19607843137255 });
    try testColorConversion(.{ .r = 128, .g = 0, .b = 128 }, Lab{ .l = 29.782100092098077, .a = 58.93983731904206, .b = -36.49792996282386 });
}

test "neutral colors" {
    // white: 0xffffff
    try testColorConversion(.{ .r = 255, .g = 255, .b = 255 }, Hsl{ .h = 0, .s = 0, .l = 100 });
    try testColorConversion(.{ .r = 255, .g = 255, .b = 255 }, Hsv{ .h = 0, .s = 0, .v = 100 });
    try testColorConversion(.{ .r = 255, .g = 255, .b = 255 }, Lab{ .l = 100, .a = 0.00526049995830391, .b = -0.010408184525267927 });
    // gray: 0x808080
    try testColorConversion(.{ .r = 128, .g = 128, .b = 128 }, Hsl{ .h = 0, .s = 0, .l = 50.19607843137255 });
    try testColorConversion(.{ .r = 128, .g = 128, .b = 128 }, Hsv{ .h = 0, .s = 0, .v = 50.19607843137255 });
    try testColorConversion(.{ .r = 128, .g = 128, .b = 128 }, Lab{ .l = 53.58501345216902, .a = 0.003155620347972121, .b = -0.006243566036268078 });
    // black: 0x000000
    try testColorConversion(.{ .r = 0, .g = 0, .b = 0 }, Hsl{ .h = 0, .s = 0, .l = 0 });
    try testColorConversion(.{ .r = 0, .g = 0, .b = 0 }, Hsv{ .h = 0, .s = 0, .v = 0 });
    try testColorConversion(.{ .r = 0, .g = 0, .b = 0 }, Lab{ .l = 0, .a = 0, .b = 0 });
}

test "pastel colors" {
    // pale_pink: 0xffd3ba
    try testColorConversion(.{ .r = 255, .g = 211, .b = 186 }, Hsl{ .h = 21.739130434782602, .s = 100, .l = 86.47058823529412 });
    try testColorConversion(.{ .r = 255, .g = 211, .b = 186 }, Hsv{ .h = 21.739130434782602, .s = 27.058823529411768, .v = 100 });
    try testColorConversion(.{ .r = 255, .g = 211, .b = 186 }, Lab{ .l = 87.67593388241974, .a = 11.843797404960165, .b = 18.16236917854479 });
    // mint_green: 0x96fa96
    try testColorConversion(.{ .r = 150, .g = 250, .b = 150 }, Hsl{ .h = 120, .s = 90.90909090909089, .l = 78.43137254901961 });
    try testColorConversion(.{ .r = 150, .g = 250, .b = 150 }, Hsv{ .h = 120, .s = 40, .v = 98.0392156862745 });
    try testColorConversion(.{ .r = 150, .g = 250, .b = 150 }, Lab{ .l = 90.34795996024553, .a = -48.75545372512652, .b = 38.96689290268498 });
    // sky_blue: #8ad1ed
    try testColorConversion(.{ .r = 138, .g = 209, .b = 237 }, Hsl{ .h = 196.96969696969697, .s = 73.33333333333336, .l = 73.52941176470588 });
    try testColorConversion(.{ .r = 138, .g = 209, .b = 237 }, Hsv{ .h = 196.96969696969697, .s = 41.77215189873419, .v = 92.94117647058823 });
    try testColorConversion(.{ .r = 138, .g = 209, .b = 237 }, Lab{ .l = 80.24627015828005, .a = -15.11865203941365, .b = -20.767024460106565 });
}

test "vivid colors" {
    // hot_pink: #ff66b3
    try testColorConversion(.{ .r = 255, .g = 102, .b = 179 }, Hsl{ .h = 329.80392156862746, .s = 99.99999999999997, .l = 70 });
    try testColorConversion(.{ .r = 255, .g = 102, .b = 179 }, Hsv{ .h = 329.80392156862746, .s = 60, .v = 100 });
    try testColorConversion(.{ .r = 255, .g = 102, .b = 179 }, Lab{ .l = 64.9763931162809, .a = 65.40669278373645, .b = -10.847761988977656 });
    // lime_green:#31cc31
    try testColorConversion(.{ .r = 49, .g = 204, .b = 49 }, Hsl{ .h = 120, .s = 61.26482213438735, .l = 49.6078431372549 });
    try testColorConversion(.{ .r = 49, .g = 204, .b = 49 }, Hsv{ .h = 120, .s = 75.98039215686275, .v = 80 });
    try testColorConversion(.{ .r = 49, .g = 204, .b = 49 }, Lab{ .l = 72.26888334336961, .a = -67.03378336285304, .b = 61.425460443480894 });
    // electric_blue: #80dfff
    try testColorConversion(.{ .r = 128, .g = 223, .b = 255 }, Hsl{ .h = 195.11811023622047, .s = 100, .l = 75.09803921568627 });
    try testColorConversion(.{ .r = 128, .g = 223, .b = 255 }, Hsv{ .h = 195.11811023622047, .s = 49.80392156862745, .v = 100 });
    try testColorConversion(.{ .r = 128, .g = 223, .b = 255 }, Lab{ .l = 84.26919487615707, .a = -19.773688316136685, .b = -24.252061008370738 });
}

test "color formatting" {
    const red = Rgb{ .r = 255, .g = 0, .b = 0 };

    // Test plain format with {any}
    var plain_buffer: [100]u8 = undefined;
    const plain_result = try std.fmt.bufPrint(&plain_buffer, "{any}", .{red});
    try std.testing.expect(std.mem.indexOf(u8, plain_result, ".r = 255, .g = 0, .b = 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain_result, "\x1b[") == null); // No SGR codes

    // Test colored format with {f}
    var color_buffer: [200]u8 = undefined;
    const color_result = try std.fmt.bufPrint(&color_buffer, "{f}", .{red});
    try std.testing.expect(std.mem.indexOf(u8, color_result, "Rgb{ .r = 255, .g = 0, .b = 0 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, color_result, "\x1b[") != null); // Has SGR codes
}

test "100 random colors" {
    const seed: u64 = std.crypto.random.int(u64);
    var prng: std.Random.DefaultPrng = .init(seed);
    var random = prng.random();
    for (0..100) |_| {
        const rgb: Rgb = .{ .r = random.int(u8), .g = random.int(u8), .b = random.int(u8) };
        const rgb_from_hsl = rgb.toHsl().toRgb();
        try expectEqualDeep(rgb, rgb_from_hsl);
        const rgb_from_hsv = rgb.toHsv().toRgb();
        try expectEqualDeep(rgb, rgb_from_hsv);
        const rgb_from_xyz = rgb.toXyz().toRgb();
        try expectEqualDeep(rgb, rgb_from_xyz);
        const rgb_from_lab = rgb.toLab().toRgb();
        try expectEqualDeep(rgb, rgb_from_lab);
    }
}

test "color type validation" {
    try expectEqual(isColor(u8), true);
    try expectEqual(isColor(Rgb), true);
    try expectEqual(isColor(Rgba), true);
    try expectEqual(isColor(Hsl), true);
    try expectEqual(isColor(Hsv), true);
    try expectEqual(isColor(Lab), true);
    try expectEqual(isColor(Xyz), true);
    try expectEqual(isColor(Lms), true);
    try expectEqual(isColor(Oklab), true);
    try expectEqual(isColor(Oklch), true);
    try expectEqual(isColor(Xyb), true);
    try expectEqual(isColor(Ycbcr), true);
    try expectEqual(isColor(f32), false);
    try expectEqual(isColor(i32), false);
}

test "generic convert function" {
    const red = Rgb{ .r = 255, .g = 0, .b = 0 };

    // Test conversion to all color types
    const red_rgba = convertColor(Rgba, red);
    try expectEqualDeep(red_rgba, Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 });

    const red_hsl = convertColor(Hsl, red);
    try expectEqualDeep(red_hsl, Hsl{ .h = 0, .s = 100, .l = 50 });

    const red_hsv = convertColor(Hsv, red);
    try expectEqualDeep(red_hsv, Hsv{ .h = 0, .s = 100, .v = 100 });

    const gray = convertColor(u8, red);
    try expectEqual(gray, 54); // Luma-based grayscale of red
}

test "extended color space round trips" {
    const colors = [_]Rgb{
        .{ .r = 255, .g = 0, .b = 0 }, // Red
        .{ .r = 0, .g = 255, .b = 0 }, // Green
        .{ .r = 0, .g = 0, .b = 255 }, // Blue
        .{ .r = 255, .g = 255, .b = 255 }, // White
        .{ .r = 128, .g = 128, .b = 128 }, // Gray
    };

    for (colors) |original| {
        // Test all round-trip conversions
        try expectEqualDeep(original, original.toXyz().toRgb());
        try expectEqualDeep(original, original.toLms().toRgb());
        try expectEqualDeep(original, original.toOklab().toRgb());
        try expectEqualDeep(original, original.toOklch().toRgb());
        try expectEqualDeep(original, original.toXyb().toRgb());
    }
}

test "color invert matches RGB inversion" {
    const samples = [_]Rgb{
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 255, .g = 255, .b = 255 },
        .{ .r = 12, .g = 34, .b = 56 },
        .{ .r = 128, .g = 64, .b = 32 },
        .{ .r = 5, .g = 200, .b = 150 },
    };

    inline for (color_types) |ColorType| {
        for (samples) |rgb| {
            const typed: ColorType = if (comptime ColorType == Rgb) rgb else convertColor(ColorType, rgb);
            const inverted = typed.invert();
            const recovered_rgb: Rgb = if (comptime ColorType == Rgb) inverted else inverted.toRgb();
            const expected = rgb.invert();

            if (comptime ColorType == Ycbcr) {
                try expect(@abs(@as(i16, expected.r) - @as(i16, recovered_rgb.r)) <= 1);
                try expect(@abs(@as(i16, expected.g) - @as(i16, recovered_rgb.g)) <= 1);
                try expect(@abs(@as(i16, expected.b) - @as(i16, recovered_rgb.b)) <= 1);
            } else {
                try expectEqualDeep(expected, recovered_rgb);
            }

            if (comptime ColorType == Rgba) {
                const original_rgba = convertColor(Rgba, rgb);
                try expectEqual(original_rgba.a, inverted.a);
            }
        }
    }
}

test "Xyz blend matches RGB blend" {
    const base_rgb = Rgb{ .r = 120, .g = 100, .b = 80 };
    const overlay = Rgba{ .r = 200, .g = 50, .b = 150, .a = 128 };

    const blended_xyz = base_rgb.toXyz().blend(overlay, Blending.normal);
    const blended_rgb = base_rgb.blend(overlay, Blending.normal);

    try expectEqualDeep(blended_rgb, blended_xyz.toRgb());
}

/// List of color types to test. This is the only thing to update when adding a new color space.
const color_types = .{ Rgb, Rgba, Hsl, Hsv, Lab, Lch, Xyz, Lms, Oklab, Oklch, Xyb, Ycbcr };

/// Generates the list of conversion methods based on the color type names.
fn generateConversionMethods() [color_types.len][]const u8 {
    var methods: [color_types.len][]const u8 = undefined;
    inline for (color_types, 0..) |ColorType, i| {
        const simple_name = getSimpleTypeName(ColorType);
        methods[i] = "to" ++ simple_name;
    }
    return methods;
}

/// Skip self-conversion methods (e.g., Rgb.toRgb doesn't exist)
fn shouldSkipMethod(comptime ColorType: type, comptime method_name: []const u8) bool {
    if (method_name.len < 3 or !std.mem.startsWith(u8, method_name, "to")) return false;

    const target_type_name = method_name[2..]; // Remove "to" prefix
    const current_type_name = getSimpleTypeName(ColorType);

    return std.mem.eql(u8, current_type_name, target_type_name);
}

test "comprehensive color conversion method validation and round-trip testing" {
    @setEvalBranchQuota(10000);
    // Test colors for round-trip validation
    const test_colors = [_]Rgb{
        .{ .r = 255, .g = 0, .b = 0 }, // Pure red
        .{ .r = 0, .g = 255, .b = 0 }, // Pure green
        .{ .r = 0, .g = 0, .b = 255 }, // Pure blue
        .{ .r = 255, .g = 255, .b = 255 }, // White
        .{ .r = 128, .g = 128, .b = 128 }, // Gray
        .{ .r = 255, .g = 64, .b = 32 }, // Orange-red
        .{ .r = 64, .g = 192, .b = 128 }, // Teal-green
    };

    // Use metaprogramming to verify all color types have expected conversion methods
    // and test round-trip accuracy for each conversion
    inline for (color_types) |ColorType| {
        inline for (comptime generateConversionMethods()) |method_name| {
            // Skip self-conversion and special cases
            if (comptime shouldSkipMethod(ColorType, method_name)) continue;

            // Verify method exists using @hasDecl
            try expect(@hasDecl(ColorType, method_name));

            // Test round-trip conversion accuracy for this specific method
            if (comptime std.mem.eql(u8, method_name, "toRgb")) {
                // For toRgb methods, test conversion from each test color
                for (test_colors) |test_rgb| {
                    const intermediate_color = convertColor(ColorType, test_rgb);
                    const recovered_rgb = intermediate_color.toRgb();
                    // Allow small differences for integer-based color spaces like YCbCr
                    if (ColorType == Ycbcr) {
                        // Integer YCbCr conversion can have rounding errors
                        try expect(@abs(@as(i16, test_rgb.r) - @as(i16, recovered_rgb.r)) <= 1);
                        try expect(@abs(@as(i16, test_rgb.g) - @as(i16, recovered_rgb.g)) <= 1);
                        try expect(@abs(@as(i16, test_rgb.b) - @as(i16, recovered_rgb.b)) <= 1);
                    } else {
                        try expectEqualDeep(test_rgb, recovered_rgb);
                    }
                }
            }

            // Special case: test RGBA round-trip
            if (comptime ColorType == Rgba and std.mem.eql(u8, method_name, "toRgb")) {
                for (test_colors) |test_rgb| {
                    const rgba = test_rgb.toRgba(255);
                    try expectEqualDeep(test_rgb, rgba.toRgb());
                }
            }
        }
    }
}

test "color conversion accuracy with reference values" {
    // Test with well-known reference values to verify conversion accuracy

    // Pure red: RGB(255,0,0) should convert to specific known values
    try expectEqualDeep(Hsl{ .h = 0, .s = 100, .l = 50 }, (Rgb{ .r = 255, .g = 0, .b = 0 }).toHsl());
    try expectEqualDeep(Hsv{ .h = 0, .s = 100, .v = 100 }, (Rgb{ .r = 255, .g = 0, .b = 0 }).toHsv());

    // Pure green: RGB(0,255,0) should have hue=120
    try expectEqualDeep(Hsl{ .h = 120, .s = 100, .l = 50 }, (Rgb{ .r = 0, .g = 255, .b = 0 }).toHsl());
    try expectEqualDeep(Hsv{ .h = 120, .s = 100, .v = 100 }, (Rgb{ .r = 0, .g = 255, .b = 0 }).toHsv());

    // Pure blue: RGB(0,0,255) should have hue=240
    try expectEqualDeep(Hsl{ .h = 240, .s = 100, .l = 50 }, (Rgb{ .r = 0, .g = 0, .b = 255 }).toHsl());
    try expectEqualDeep(Hsv{ .h = 240, .s = 100, .v = 100 }, (Rgb{ .r = 0, .g = 0, .b = 255 }).toHsv());

    // White should have L=100 in Lab space (with small tolerance for floating point)
    const white_lab = (Rgb{ .r = 255, .g = 255, .b = 255 }).toLab();
    try expectEqualDeep(Lab{ .l = 100, .a = 0.00526049995830391, .b = -0.010408184525267927 }, white_lab);

    // Black should have L=0 in Lab space
    try expectEqualDeep(Lab{ .l = 0, .a = 0, .b = 0 }, (Rgb{ .r = 0, .g = 0, .b = 0 }).toLab());

    // Gray should have saturation=0 in HSL
    try expectEqualDeep(Hsl{ .h = 0, .s = 0, .l = 50.19607843137255 }, (Rgb{ .r = 128, .g = 128, .b = 128 }).toHsl());

    // Cyan: RGB(0,255,255) should have hue=180
    try expectEqualDeep(Hsl{ .h = 180, .s = 100, .l = 50 }, (Rgb{ .r = 0, .g = 255, .b = 255 }).toHsl());

    // Magenta: RGB(255,0,255) should have hue=300
    try expectEqualDeep(Hsl{ .h = 300, .s = 100, .l = 50 }, (Rgb{ .r = 255, .g = 0, .b = 255 }).toHsl());

    // Yellow: RGB(255,255,0) should have hue=60
    try expectEqualDeep(Hsl{ .h = 60, .s = 100, .l = 50 }, (Rgb{ .r = 255, .g = 255, .b = 0 }).toHsl());
}
