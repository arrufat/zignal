//! Color module - All color types and utilities
//!
//! This module provides a unified interface to all color types in the system.
//! Each color type is implemented as a separate file using Zig's file-as-struct pattern.

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;

const conversions = @import("color/conversions.zig");
pub const convert = conversions.convert;
pub const isColor = conversions.isColor;
pub const Hsl = @import("color/Hsl.zig");
pub const Hsv = @import("color/Hsv.zig");
pub const Lab = @import("color/Lab.zig");
pub const Lms = @import("color/Lms.zig");
pub const Oklab = @import("color/Oklab.zig");
pub const Rgb = @import("color/Rgb.zig");
pub const Rgba = @import("color/Rgba.zig");
pub const Xyb = @import("color/Xyb.zig");
pub const Xyz = @import("color/Xyz.zig");

// ============================================================================
// TESTS
// ============================================================================

// Helper function for testing round-trip conversions
fn testColorConversion(from: Rgb, to: anytype) !void {
    const converted = convert(@TypeOf(to), from);
    try expectEqualDeep(converted, to);
    const recovered = convert(Rgb, converted);
    try expectEqualDeep(recovered, from);
}

test "convert grayscale" {
    try expectEqual(convert(u8, Rgb{ .r = 128, .g = 128, .b = 128 }), 128);
    try expectEqual(convert(u8, Hsl{ .h = 0, .s = 100, .l = 50 }), 128);
    try expectEqual(convert(u8, Hsv{ .h = 0, .s = 100, .v = 50 }), 128);
    try expectEqual(convert(u8, Lab{ .l = 50, .a = 0, .b = 0 }), 128);
}

test "alphaBlend" {
    const white = Rgb{ .r = 255, .g = 255, .b = 255 };
    var output = Rgb{ .r = 0, .g = 0, .b = 0 };
    output.blend(white.toRgba(128));
    try expectEqualDeep(output, Rgb{ .r = 128, .g = 128, .b = 128 });
}

test "blend methods for all color types" {
    // Test data: blend red (255,0,0) with 50% alpha onto black background
    const red_rgba = Rgba{ .r = 255, .g = 0, .b = 0, .a = 128 };
    const expected_rgb = Rgb{ .r = 128, .g = 0, .b = 0 }; // 50% blend of red on black

    // Test Rgba.blend
    {
        var rgba_color = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };
        rgba_color.blend(red_rgba);
        try expectEqualDeep(rgba_color.toRgb(), expected_rgb);
    }

    // Test Hsl.blend
    {
        var hsl_color = Hsl{ .h = 0, .s = 0, .l = 0 }; // black
        hsl_color.blend(red_rgba);
        const result_rgb = hsl_color.toRgb();
        try expectEqualDeep(result_rgb, expected_rgb);
    }

    // Test Hsv.blend
    {
        var hsv_color = Hsv{ .h = 0, .s = 0, .v = 0 }; // black
        hsv_color.blend(red_rgba);
        const result_rgb = hsv_color.toRgb();
        try expectEqualDeep(result_rgb, expected_rgb);
    }

    // Test Lab.blend
    {
        var lab_color = Lab{ .l = 0, .a = 0, .b = 0 }; // black
        lab_color.blend(red_rgba);
        const result_rgb = lab_color.toRgb();
        try expectEqualDeep(result_rgb, expected_rgb);
    }

    // Test Oklab.blend
    {
        var oklab_color = Oklab{ .l = 0, .a = 0, .b = 0 }; // black
        oklab_color.blend(red_rgba);
        const result_rgb = oklab_color.toRgb();
        try expectEqualDeep(result_rgb, expected_rgb);
    }

    // Test Lms.blend
    {
        var lms_color = Lms{ .l = 0, .m = 0, .s = 0 }; // black
        lms_color.blend(red_rgba);
        const result_rgb = lms_color.toRgb();
        try expectEqualDeep(result_rgb, expected_rgb);
    }

    // Test Xyb.blend
    {
        var xyb_color = Xyb{ .x = 0, .y = 0, .b = 0 }; // black
        xyb_color.blend(red_rgba);
        const result_rgb = xyb_color.toRgb();
        try expectEqualDeep(result_rgb, expected_rgb);
    }
}

test "blend with zero alpha should not change color" {
    const transparent_red = Rgba{ .r = 255, .g = 0, .b = 0, .a = 0 };
    const original_blue = Rgb{ .r = 0, .g = 0, .b = 255 };

    // Test that blending with zero alpha doesn't change the original color
    var test_rgb = original_blue;
    test_rgb.blend(transparent_red);
    try expectEqualDeep(test_rgb, original_blue);

    var test_hsl = original_blue.toHsl();
    const original_hsl = test_hsl;
    test_hsl.blend(transparent_red);
    try expectEqualDeep(test_hsl, original_hsl);
}

test "hex to RGB/A" {
    try expectEqualDeep(Rgb.fromHex(0x4e008e), Rgb{ .r = 78, .g = 0, .b = 142 });
    try expectEqualDeep(Rgb.fromHex(0x000000), Rgb{ .r = 0, .g = 0, .b = 0 });
    try expectEqualDeep(Rgb.fromHex(0xffffff), Rgb{ .r = 255, .g = 255, .b = 255 });
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

    // Test plain format
    var plain_buffer: [100]u8 = undefined;
    var plain_stream = std.io.fixedBufferStream(&plain_buffer);
    try red.format("", .{}, plain_stream.writer());
    const plain_result = plain_stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, plain_result, "Rgb{ .r = 255, .g = 0, .b = 0 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain_result, "\x1b[") == null); // No ANSI codes

    // Test colored format
    var color_buffer: [200]u8 = undefined;
    var color_stream = std.io.fixedBufferStream(&color_buffer);
    try red.format("color", .{}, color_stream.writer());
    const color_result = color_stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, color_result, "Rgb{ .r = 255, .g = 0, .b = 0 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, color_result, "\x1b[") != null); // Has ANSI codes
}

test "100 random colors" {
    const seed: u64 = @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
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
    try expectEqual(isColor(Xyb), true);
    try expectEqual(isColor(f32), false);
    try expectEqual(isColor(i32), false);
}

test "generic convert function" {
    const red = Rgb{ .r = 255, .g = 0, .b = 0 };

    // Test conversion to all color types
    const red_rgba = convert(Rgba, red);
    try expectEqualDeep(red_rgba, Rgba{ .r = 255, .g = 0, .b = 0, .a = 255 });

    const red_hsl = convert(Hsl, red);
    try expectEqualDeep(red_hsl, Hsl{ .h = 0, .s = 100, .l = 50 });

    const red_hsv = convert(Hsv, red);
    try expectEqualDeep(red_hsv, Hsv{ .h = 0, .s = 100, .v = 100 });

    const gray = convert(u8, red);
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
        try expectEqualDeep(original, original.toXyb().toRgb());
    }
}

test "comprehensive color conversion paths" {
    // Test color: bright red-orange to ensure all conversion methods compile and work
    const test_rgb = Rgb{ .r = 255, .g = 64, .b = 32 };

    // Convert to all color types to ensure all conversion methods work
    const rgba = test_rgb.toRgba(200);
    const hsl = test_rgb.toHsl();
    const hsv = test_rgb.toHsv();
    const lab = test_rgb.toLab();
    const xyz = test_rgb.toXyz();
    const lms = test_rgb.toLms();
    const oklab = test_rgb.toOklab();
    const xyb = test_rgb.toXyb();

    // Test all conversions FROM each color type to ensure no compilation errors
    // and that all conversion methods exist and work correctly

    // From Rgba - only has toRgb() method, other conversions go through RGB
    _ = rgba.toRgb();
    _ = rgba.toHsl();
    _ = rgba.toHsv();
    _ = rgba.toLab();
    _ = rgba.toXyz();
    _ = rgba.toLms();
    _ = rgba.toOklab();
    _ = rgba.toXyb();

    // From Hsl - test all 8 conversion methods
    _ = hsl.toRgb();
    _ = hsl.toRgba(255);
    _ = hsl.toHsv(); // This was the buggy method we fixed
    _ = hsl.toLab();
    _ = hsl.toXyz();
    _ = hsl.toLms();
    _ = hsl.toOklab();
    _ = hsl.toXyb();

    // From Hsv - test all 8 conversion methods
    _ = hsv.toRgb();
    _ = hsv.toRgba(255);
    _ = hsv.toHsl();
    _ = hsv.toLab();
    _ = hsv.toXyz();
    _ = hsv.toLms();
    _ = hsv.toOklab();
    _ = hsv.toXyb();

    // From Lab - test all 8 conversion methods
    _ = lab.toRgb();
    _ = lab.toRgba(255);
    _ = lab.toHsl();
    _ = lab.toHsv();
    _ = lab.toXyz();
    _ = lab.toLms();
    _ = lab.toOklab();
    _ = lab.toXyb();

    // From Xyz - test all 8 conversion methods
    _ = xyz.toRgb();
    _ = xyz.toRgba(255);
    _ = xyz.toHsl();
    _ = xyz.toHsv();
    _ = xyz.toLab();
    _ = xyz.toLms();
    _ = xyz.toOklab();
    _ = xyz.toXyb();

    // From Lms - test all 8 conversion methods
    _ = lms.toRgb();
    _ = lms.toRgba(255);
    _ = lms.toHsl();
    _ = lms.toHsv();
    _ = lms.toLab();
    _ = lms.toXyz();
    _ = lms.toOklab();
    _ = lms.toXyb();

    // From Oklab - test all 8 conversion methods
    _ = oklab.toRgb();
    _ = oklab.toRgba(255);
    _ = oklab.toHsl();
    _ = oklab.toHsv();
    _ = oklab.toLab();
    _ = oklab.toXyz();
    _ = oklab.toLms();
    _ = oklab.toXyb();

    // From Xyb - test all 8 conversion methods
    _ = xyb.toRgb();
    _ = xyb.toRgba(255);
    _ = xyb.toHsl();
    _ = xyb.toHsv();
    _ = xyb.toLab();
    _ = xyb.toXyz();
    _ = xyb.toLms();
    _ = xyb.toOklab();
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
