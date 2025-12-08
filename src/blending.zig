const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const Rgba = @import("color.zig").Rgba;

pub const Blending = enum {
    none,
    normal,
    multiply,
    screen,
    overlay,
    soft_light,
    hard_light,
    color_dodge,
    color_burn,
    darken,
    lighten,
    difference,
    exclusion,
};

/// Helper to calculate the alpha of the resulting color.
/// Inputs are normalized alpha values (0.0 - 1.0).
fn compositeAlpha(base_a: f32, overlay_a: f32) f32 {
    return overlay_a + base_a * (1.0 - overlay_a);
}

/// Helper to composite a blended color channel (result of blend mode) with the base color
/// using standard alpha compositing (Source Over).
/// All inputs are normalized f32 (0.0 - 1.0).
/// Formula: C_out = (B(Cb, Cs) * as + Cb * ab * (1 - as)) / ar
fn compositePixel(
    base_val: f32,
    base_a: f32,
    blend_val: f32,
    overlay_a: f32,
    result_a: f32,
) f32 {
    if (result_a == 0) return 0;
    return (blend_val * overlay_a + base_val * base_a * (1.0 - overlay_a)) / result_a;
}

/// Blends two RGBA colors using the specified blend mode.
/// Accepts any Rgba(T) types (e.g., Rgba(u8), Rgba(f32)).
/// Returns Rgba(T) matching the base color's type.
pub fn blendColors(comptime T: type, base: Rgba(T), overlay: Rgba(T), mode: Blending) Rgba(T) {
    switch (@typeInfo(T)) {
        .float => {},
        .int => if (T != u8) @compileError("Unsupported backing type " ++ @typeName(T) ++ " for color space"),
        else => @compileError("Unsupported backing type " ++ @typeName(T) ++ " for color space"),
    }
    const base_f = if (T == u8) base.as(f32) else base;
    const overlay_f = if (T == u8) overlay.as(f32) else overlay;
    // Early return for fully transparent overlay
    if (overlay_f.a <= 0) return base;

    // Hidden base color should not influence blending
    if (base_f.a <= 0) return overlay;

    const result_a = compositeAlpha(base_f.a, overlay_f.a);
    if (result_a <= 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    var blended: Rgba(f32) = undefined;

    switch (mode) {
        .none => return overlay,
        .normal => {
            blended.r = overlay_f.r;
            blended.g = overlay_f.g;
            blended.b = overlay_f.b;
        },
        .multiply => {
            blended.r = base_f.r * overlay_f.r;
            blended.g = base_f.g * overlay_f.g;
            blended.b = base_f.b * overlay_f.b;
        },
        .screen => {
            blended.r = 1.0 - (1.0 - base_f.r) * (1.0 - overlay_f.r);
            blended.g = 1.0 - (1.0 - base_f.g) * (1.0 - overlay_f.g);
            blended.b = 1.0 - (1.0 - base_f.b) * (1.0 - overlay_f.b);
        },
        .overlay => {
            blended.r = overlayChannel(base_f.r, overlay_f.r);
            blended.g = overlayChannel(base_f.g, overlay_f.g);
            blended.b = overlayChannel(base_f.b, overlay_f.b);
        },
        .soft_light => {
            blended.r = softLightChannel(base_f.r, overlay_f.r);
            blended.g = softLightChannel(base_f.g, overlay_f.g);
            blended.b = softLightChannel(base_f.b, overlay_f.b);
        },
        .hard_light => {
            // Hard light is overlay with base and overlay swapped
            blended.r = overlayChannel(overlay_f.r, base_f.r);
            blended.g = overlayChannel(overlay_f.g, base_f.g);
            blended.b = overlayChannel(overlay_f.b, base_f.b);
        },
        .color_dodge => {
            blended.r = colorDodgeChannel(base_f.r, overlay_f.r);
            blended.g = colorDodgeChannel(base_f.g, overlay_f.g);
            blended.b = colorDodgeChannel(base_f.b, overlay_f.b);
        },
        .color_burn => {
            blended.r = colorBurnChannel(base_f.r, overlay_f.r);
            blended.g = colorBurnChannel(base_f.g, overlay_f.g);
            blended.b = colorBurnChannel(base_f.b, overlay_f.b);
        },
        .darken => {
            blended.r = @min(base_f.r, overlay_f.r);
            blended.g = @min(base_f.g, overlay_f.g);
            blended.b = @min(base_f.b, overlay_f.b);
        },
        .lighten => {
            blended.r = @max(base_f.r, overlay_f.r);
            blended.g = @max(base_f.g, overlay_f.g);
            blended.b = @max(base_f.b, overlay_f.b);
        },
        .difference => {
            blended.r = @abs(base_f.r - overlay_f.r);
            blended.g = @abs(base_f.g - overlay_f.g);
            blended.b = @abs(base_f.b - overlay_f.b);
        },
        .exclusion => {
            blended.r = exclusionChannel(base_f.r, overlay_f.r);
            blended.g = exclusionChannel(base_f.g, overlay_f.g);
            blended.b = exclusionChannel(base_f.b, overlay_f.b);
        },
    }

    const out = Rgba(if (T == u8) f32 else T){
        .r = compositePixel(base_f.r, base_f.a, blended.r, overlay_f.a, result_a),
        .g = compositePixel(base_f.g, base_f.a, blended.g, overlay_f.a, result_a),
        .b = compositePixel(base_f.b, base_f.a, blended.b, overlay_f.a, result_a),
        .a = result_a,
    };

    return if (T == u8) out.as(T) else out;
}

// Channel implementations (f32)

fn overlayChannel(base: f32, blend: f32) f32 {
    if (base < 0.5) {
        return 2.0 * base * blend;
    } else {
        return 1.0 - 2.0 * (1.0 - base) * (1.0 - blend);
    }
}

fn softLightChannel(base: f32, blend: f32) f32 {
    if (blend <= 0.5) {
        return base - (1.0 - 2.0 * blend) * base * (1.0 - base);
    } else {
        const sqrt_base = @sqrt(base);
        return base + (2.0 * blend - 1.0) * (sqrt_base - base);
    }
}

fn colorDodgeChannel(base: f32, blend: f32) f32 {
    if (blend >= 1.0) return 1.0;
    const result = base / (1.0 - blend);
    return @min(1.0, result);
}

fn colorBurnChannel(base: f32, blend: f32) f32 {
    if (blend <= 0.0) return 0.0;
    const result = 1.0 - (1.0 - base) / blend;
    return @max(0.0, result);
}

fn exclusionChannel(base: f32, blend: f32) f32 {
    return base + blend - 2.0 * base * blend;
}

// Tests

test "blend normal mode" {
    const base = Rgba(u8){ .r = 100, .g = 100, .b = 100, .a = 255 };
    const blend = Rgba(u8){ .r = 200, .g = 200, .b = 200, .a = 128 };

    const result = blendColors(u8, base, blend, .normal);

    // Should be approximately halfway between base and blend
    try expect(result.r > 140 and result.r < 160);
    try expect(result.g > 140 and result.g < 160);
    try expect(result.b > 140 and result.b < 160);
}

test "blend multiply mode" {
    const white = Rgba(u8){ .r = 255, .g = 255, .b = 255, .a = 255 };
    const gray = Rgba(u8){ .r = 128, .g = 128, .b = 128, .a = 255 };

    const result = blendColors(u8, white, gray, .multiply);

    try expectEqual(result.r, 128);
    try expectEqual(result.g, 128);
    try expectEqual(result.b, 128);
}

test "blend screen mode" {
    const black = Rgba(u8){ .r = 0, .g = 0, .b = 0, .a = 255 };
    const gray = Rgba(u8){ .r = 128, .g = 128, .b = 128, .a = 255 };

    const result = blendColors(u8, black, gray, .screen);

    try expectEqual(result.r, 128);
    try expectEqual(result.g, 128);
    try expectEqual(result.b, 128);
}

test "blend with transparent" {
    const base = Rgba(u8){ .r = 100, .g = 100, .b = 100, .a = 255 };
    const transparent = Rgba(u8){ .r = 200, .g = 200, .b = 200, .a = 0 };

    const result = blendColors(u8, base, transparent, .normal);

    // Should remain unchanged
    try expectEqual(result.r, base.r);
    try expectEqual(result.g, base.g);
    try expectEqual(result.b, base.b);
    try expectEqual(result.a, base.a);
}

test "blend semi-transparent colors" {
    // Test Porter-Duff compositing with two semi-transparent colors
    const base = Rgba(u8){ .r = 100, .g = 100, .b = 100, .a = 128 }; // ~50% opacity
    const overlay = Rgba(u8){ .r = 200, .g = 200, .b = 200, .a = 128 }; // ~50% opacity

    const result = blendColors(u8, base, overlay, .normal);

    // Alpha should be: 0.5 + 0.5 * (1 - 0.5) = 0.75 = ~191
    try expect(result.a >= 190 and result.a <= 192);

    // RGB should be properly composited
    try expect(result.r > 130 and result.r < 170); // Should be between base and overlay
}

test "blend with transparent base" {
    // Test blending onto a fully transparent base
    const base = Rgba(u8){ .r = 0, .g = 0, .b = 0, .a = 0 }; // Fully transparent
    const overlay = Rgba(u8){ .r = 200, .g = 150, .b = 100, .a = 180 }; // ~70% opacity

    const result = blendColors(u8, base, overlay, .normal);

    // Result alpha should be same as overlay since base is transparent
    try expectEqual(result.a, 180);

    // RGB should be overlay's colors (with slight rounding possible)
    try expect(@abs(@as(i16, result.r) - 200) <= 1);
    try expect(@abs(@as(i16, result.g) - 150) <= 1);
    try expect(@abs(@as(i16, result.b) - 100) <= 1);
}

test "blend modes with alpha" {
    // Test that blend modes work correctly with semi-transparent colors
    const base = Rgba(u8){ .r = 100, .g = 100, .b = 100, .a = 200 }; // ~78% opacity
    const overlay = Rgba(u8){ .r = 50, .g = 50, .b = 50, .a = 100 }; // ~39% opacity

    // Test multiply with alpha
    const multiply_result = blendColors(u8, base, overlay, .multiply);
    // Alpha should composite correctly using Porter-Duff formula:
    // result_a = overlay_a + base_a * (1 - overlay_a)
    // = 100/255 + 200/255 * (1 - 100/255)
    // = 100/255 + 200/255 * 155/255
    // = 0.392 + 0.784 * 0.608 = 0.392 + 0.477 = 0.869 = ~221
    const expected_alpha: u8 = 221;
    try expect(@abs(@as(i16, multiply_result.a) - @as(i16, expected_alpha)) <= 2);

    // Test screen with alpha - should have same alpha as multiply
    const screen_result = blendColors(u8, base, overlay, .screen);
    try expect(@abs(@as(i16, screen_result.a) - @as(i16, expected_alpha)) <= 2);

    // RGB values should differ between multiply and screen
    try expect(multiply_result.r < screen_result.r); // Multiply darkens, screen lightens
}

test "blend ignores hidden base color when fully transparent" {
    const base = Rgba(u8){ .r = 25, .g = 75, .b = 125, .a = 0 };
    const overlay = Rgba(u8){ .r = 200, .g = 150, .b = 100, .a = 180 };

    const multiply_result = blendColors(u8, base, overlay, .multiply);
    try expectEqual(multiply_result.r, overlay.r);
    try expectEqual(multiply_result.g, overlay.g);
    try expectEqual(multiply_result.b, overlay.b);
    try expectEqual(multiply_result.a, overlay.a);

    const screen_result = blendColors(u8, base, overlay, .screen);
    try expectEqual(screen_result.r, overlay.r);
    try expectEqual(screen_result.g, overlay.g);
    try expectEqual(screen_result.b, overlay.b);
    try expectEqual(screen_result.a, overlay.a);

    const exclusion_result = blendColors(u8, base, overlay, .exclusion);
    try expectEqual(exclusion_result.r, overlay.r);
    try expectEqual(exclusion_result.g, overlay.g);
    try expectEqual(exclusion_result.b, overlay.b);
    try expectEqual(exclusion_result.a, overlay.a);
}
