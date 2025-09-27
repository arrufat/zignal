//! Color blending modes and utilities
//!
//! This module provides various blending modes for compositing colors,
//! similar to those found in image editing software.

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Rgba = @import("Rgba.zig").Rgba;

/// Available blending modes for color composition
pub const Blending = enum {
    /// Performs no blending. The overlay fully replaces the base color.
    none,
    /// Standard alpha blending. The overlay color is painted on top of the base with transparency.
    normal,

    /// Darkens the base color by multiplying it with the overlay. White has no effect, black results in black.
    /// Useful for creating shadows and darkening effects.
    multiply,

    /// Lightens the base color by inverting, multiplying, then inverting again. Black has no effect, white results in white.
    /// Opposite of multiply, useful for creating highlights.
    screen,

    /// Combines multiply and screen. Dark colors multiply, light colors screen.
    /// Increases contrast by making darks darker and lights lighter.
    overlay,

    /// Similar to overlay but gentler. Produces a subtle contrast adjustment.
    /// Uses a smooth algorithm that avoids harsh transitions.
    soft_light,

    /// Like overlay but uses the overlay color to determine the blend mode.
    /// More dramatic contrast adjustment than soft light.
    hard_light,

    /// Brightens the base color based on the overlay. The darker the overlay, the more intense the effect.
    /// Can produce very bright results, useful for glowing effects.
    color_dodge,

    /// Darkens the base color based on the overlay. The lighter the overlay, the more intense the effect.
    /// Opposite of color dodge, useful for creating deep shadows.
    color_burn,

    /// Selects the darker of the two colors for each channel.
    /// Useful for removing white or creating silhouettes.
    darken,

    /// Selects the lighter of the two colors for each channel.
    /// Useful for removing black or creating overlays.
    lighten,

    /// Subtracts the darker color from the lighter color.
    /// Creates an inverted effect, useful for comparing images.
    difference,

    /// Similar to difference but with lower contrast.
    /// Produces a softer inversion effect.
    exclusion,
};

/// Computes the resulting alpha using Porter-Duff "over" operator
/// result_alpha = src_alpha + dst_alpha * (1 - src_alpha)
fn compositeAlpha(base_a: u8, overlay_a: u8) f32 {
    const overlay_alpha = @as(f32, @floatFromInt(overlay_a)) / 255.0;
    const base_alpha = @as(f32, @floatFromInt(base_a)) / 255.0;
    return overlay_alpha + base_alpha * (1.0 - overlay_alpha);
}

/// Composites blended RGB values with proper alpha handling
/// Takes pre-blended RGB values and composites them using Porter-Duff over operator
fn compositeBlendedColors(
    base_r: f32,
    base_g: f32,
    base_b: f32,
    base_a: f32,
    blended_r: f32,
    blended_g: f32,
    blended_b: f32,
    overlay_a: f32,
    base: Rgba,
    overlay: Rgba,
) Rgba {
    // Calculate result alpha
    const result_a = compositeAlpha(base.a, overlay.a);
    if (result_a == 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    // Composite RGB values using Porter-Duff formula
    const r = (blended_r * overlay_a + base_r * base_a * (1.0 - overlay_a)) / result_a;
    const g = (blended_g * overlay_a + base_g * base_a * (1.0 - overlay_a)) / result_a;
    const b = (blended_b * overlay_a + base_b * base_a * (1.0 - overlay_a)) / result_a;

    return .{
        .r = @intFromFloat(r),
        .g = @intFromFloat(g),
        .b = @intFromFloat(b),
        .a = @intFromFloat(result_a * 255.0),
    };
}

/// Blends two RGBA colors using the specified blend mode with proper alpha compositing.
/// Both colors' alpha channels are taken into account for mathematically correct blending.
/// Returns a new RGBA color with the blended result.
pub fn blendColors(base: Rgba, overlay: Rgba, mode: Blending) Rgba {
    // Early return for fully transparent overlay
    if (overlay.a == 0) return base;

    // Hidden base color should not influence blending
    if (base.a == 0) return overlay;

    // Blend based on mode - each function handles alpha compositing internally
    return switch (mode) {
        .none => overlay,
        .normal => blendNormal(base, overlay),
        .multiply => blendMultiply(base, overlay),
        .screen => blendScreen(base, overlay),
        .overlay => blendOverlay(base, overlay),
        .soft_light => blendSoftLight(base, overlay),
        .hard_light => blendHardLight(base, overlay),
        .color_dodge => blendColorDodge(base, overlay),
        .color_burn => blendColorBurn(base, overlay),
        .darken => blendDarken(base, overlay),
        .lighten => blendLighten(base, overlay),
        .difference => blendDifference(base, overlay),
        .exclusion => blendExclusion(base, overlay),
    };
}

fn blendNormal(base: Rgba, overlay: Rgba) Rgba {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const base_a = @as(f32, @floatFromInt(base.a)) / 255.0;
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));
    const overlay_a = @as(f32, @floatFromInt(overlay.a)) / 255.0;

    // For normal blend mode, the blended color is just the overlay color
    return compositeBlendedColors(
        base_r,
        base_g,
        base_b,
        base_a,
        overlay_r,
        overlay_g,
        overlay_b,
        overlay_a,
        base,
        overlay,
    );
}

fn blendMultiply(base: Rgba, overlay: Rgba) Rgba {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const base_a = @as(f32, @floatFromInt(base.a)) / 255.0;
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));
    const overlay_a = @as(f32, @floatFromInt(overlay.a)) / 255.0;

    // Apply multiply blend mode
    const blended_r = (base_r * overlay_r) / 255.0;
    const blended_g = (base_g * overlay_g) / 255.0;
    const blended_b = (base_b * overlay_b) / 255.0;

    return compositeBlendedColors(
        base_r,
        base_g,
        base_b,
        base_a,
        blended_r,
        blended_g,
        blended_b,
        overlay_a,
        base,
        overlay,
    );
}

fn blendScreen(base: Rgba, overlay: Rgba) Rgba {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const base_a = @as(f32, @floatFromInt(base.a)) / 255.0;
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));
    const overlay_a = @as(f32, @floatFromInt(overlay.a)) / 255.0;

    // Apply screen blend mode
    const blended_r = 255.0 - ((255.0 - base_r) * (255.0 - overlay_r) / 255.0);
    const blended_g = 255.0 - ((255.0 - base_g) * (255.0 - overlay_g) / 255.0);
    const blended_b = 255.0 - ((255.0 - base_b) * (255.0 - overlay_b) / 255.0);

    return compositeBlendedColors(
        base_r,
        base_g,
        base_b,
        base_a,
        blended_r,
        blended_g,
        blended_b,
        overlay_a,
        base,
        overlay,
    );
}

fn overlayChannel(base: f32, blend: f32) f32 {
    if (base < 128.0) {
        return (2.0 * base * blend) / 255.0;
    } else {
        return 255.0 - (2.0 * (255.0 - base) * (255.0 - blend) / 255.0);
    }
}

fn blendOverlay(base: Rgba, overlay: Rgba) Rgba {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const base_a = @as(f32, @floatFromInt(base.a)) / 255.0;
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));
    const overlay_a = @as(f32, @floatFromInt(overlay.a)) / 255.0;

    // Apply overlay blend mode
    const blended_r = overlayChannel(base_r, overlay_r);
    const blended_g = overlayChannel(base_g, overlay_g);
    const blended_b = overlayChannel(base_b, overlay_b);

    return compositeBlendedColors(
        base_r,
        base_g,
        base_b,
        base_a,
        blended_r,
        blended_g,
        blended_b,
        overlay_a,
        base,
        overlay,
    );
}

fn softLightChannel(base: f32, blend: f32) f32 {
    const b = blend / 255.0;
    const a = base / 255.0;

    if (b <= 0.5) {
        return 255.0 * (a - (1.0 - 2.0 * b) * a * (1.0 - a));
    } else {
        const sqrt_a = @sqrt(a);
        return 255.0 * (a + (2.0 * b - 1.0) * (sqrt_a - a));
    }
}

fn blendSoftLight(base: Rgba, overlay: Rgba) Rgba {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const base_a = @as(f32, @floatFromInt(base.a)) / 255.0;
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));
    const overlay_a = @as(f32, @floatFromInt(overlay.a)) / 255.0;

    // Apply soft light blend mode
    const blended_r = softLightChannel(base_r, overlay_r);
    const blended_g = softLightChannel(base_g, overlay_g);
    const blended_b = softLightChannel(base_b, overlay_b);

    return compositeBlendedColors(
        base_r,
        base_g,
        base_b,
        base_a,
        blended_r,
        blended_g,
        blended_b,
        overlay_a,
        base,
        overlay,
    );
}

fn blendHardLight(base: Rgba, overlay: Rgba) Rgba {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const base_a = @as(f32, @floatFromInt(base.a)) / 255.0;
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));
    const overlay_a = @as(f32, @floatFromInt(overlay.a)) / 255.0;

    // Hard light is overlay with base and overlay swapped
    const blended_r = overlayChannel(overlay_r, base_r);
    const blended_g = overlayChannel(overlay_g, base_g);
    const blended_b = overlayChannel(overlay_b, base_b);

    return compositeBlendedColors(
        base_r,
        base_g,
        base_b,
        base_a,
        blended_r,
        blended_g,
        blended_b,
        overlay_a,
        base,
        overlay,
    );
}

fn colorDodgeChannel(base: f32, blend: f32) f32 {
    if (blend >= 255.0) return 255.0;
    const result = (base * 255.0) / (255.0 - blend);
    return @min(255.0, result);
}

fn blendColorDodge(base: Rgba, overlay: Rgba) Rgba {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const base_a = @as(f32, @floatFromInt(base.a)) / 255.0;
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));
    const overlay_a = @as(f32, @floatFromInt(overlay.a)) / 255.0;

    // Apply color dodge blend mode
    const blended_r = colorDodgeChannel(base_r, overlay_r);
    const blended_g = colorDodgeChannel(base_g, overlay_g);
    const blended_b = colorDodgeChannel(base_b, overlay_b);

    return compositeBlendedColors(
        base_r,
        base_g,
        base_b,
        base_a,
        blended_r,
        blended_g,
        blended_b,
        overlay_a,
        base,
        overlay,
    );
}

fn colorBurnChannel(base: f32, blend: f32) f32 {
    if (blend <= 0.0) return 0.0;
    const result = 255.0 - ((255.0 - base) * 255.0) / blend;
    return @max(0.0, result);
}

fn blendColorBurn(base: Rgba, overlay: Rgba) Rgba {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const base_a = @as(f32, @floatFromInt(base.a)) / 255.0;
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));
    const overlay_a = @as(f32, @floatFromInt(overlay.a)) / 255.0;

    // Apply color burn blend mode
    const blended_r = colorBurnChannel(base_r, overlay_r);
    const blended_g = colorBurnChannel(base_g, overlay_g);
    const blended_b = colorBurnChannel(base_b, overlay_b);

    return compositeBlendedColors(
        base_r,
        base_g,
        base_b,
        base_a,
        blended_r,
        blended_g,
        blended_b,
        overlay_a,
        base,
        overlay,
    );
}

fn blendDarken(base: Rgba, overlay: Rgba) Rgba {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const base_a = @as(f32, @floatFromInt(base.a)) / 255.0;
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));
    const overlay_a = @as(f32, @floatFromInt(overlay.a)) / 255.0;

    // Apply darken blend mode
    const blended_r = @min(base_r, overlay_r);
    const blended_g = @min(base_g, overlay_g);
    const blended_b = @min(base_b, overlay_b);

    return compositeBlendedColors(
        base_r,
        base_g,
        base_b,
        base_a,
        blended_r,
        blended_g,
        blended_b,
        overlay_a,
        base,
        overlay,
    );
}

fn blendLighten(base: Rgba, overlay: Rgba) Rgba {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const base_a = @as(f32, @floatFromInt(base.a)) / 255.0;
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));
    const overlay_a = @as(f32, @floatFromInt(overlay.a)) / 255.0;

    // Apply lighten blend mode
    const blended_r = @max(base_r, overlay_r);
    const blended_g = @max(base_g, overlay_g);
    const blended_b = @max(base_b, overlay_b);

    return compositeBlendedColors(
        base_r,
        base_g,
        base_b,
        base_a,
        blended_r,
        blended_g,
        blended_b,
        overlay_a,
        base,
        overlay,
    );
}

fn blendDifference(base: Rgba, overlay: Rgba) Rgba {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const base_a = @as(f32, @floatFromInt(base.a)) / 255.0;
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));
    const overlay_a = @as(f32, @floatFromInt(overlay.a)) / 255.0;

    // Apply difference blend mode
    const blended_r = @abs(base_r - overlay_r);
    const blended_g = @abs(base_g - overlay_g);
    const blended_b = @abs(base_b - overlay_b);

    return compositeBlendedColors(
        base_r,
        base_g,
        base_b,
        base_a,
        blended_r,
        blended_g,
        blended_b,
        overlay_a,
        base,
        overlay,
    );
}

fn exclusionChannel(base: f32, blend: f32) f32 {
    return base + blend - 2.0 * base * blend / 255.0;
}

fn blendExclusion(base: Rgba, overlay: Rgba) Rgba {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const base_a = @as(f32, @floatFromInt(base.a)) / 255.0;
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));
    const overlay_a = @as(f32, @floatFromInt(overlay.a)) / 255.0;

    // Apply exclusion blend mode
    const blended_r = exclusionChannel(base_r, overlay_r);
    const blended_g = exclusionChannel(base_g, overlay_g);
    const blended_b = exclusionChannel(base_b, overlay_b);

    return compositeBlendedColors(
        base_r,
        base_g,
        base_b,
        base_a,
        blended_r,
        blended_g,
        blended_b,
        overlay_a,
        base,
        overlay,
    );
}

// Tests
test "blend normal mode" {
    const base = Rgba{ .r = 100, .g = 100, .b = 100, .a = 255 };
    const blend = Rgba{ .r = 200, .g = 200, .b = 200, .a = 128 };

    const result = blendColors(base, blend, .normal);

    // Should be approximately halfway between base and blend
    try expect(result.r > 140 and result.r < 160);
    try expect(result.g > 140 and result.g < 160);
    try expect(result.b > 140 and result.b < 160);
}

test "blend multiply mode" {
    const white = Rgba{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const gray = Rgba{ .r = 128, .g = 128, .b = 128, .a = 255 };

    const result = blendColors(white, gray, .multiply);

    // With both colors opaque, multiply should darken white to gray
    // But with alpha compositing, since both are opaque, only the overlay color matters
    // Actually the blend formula gives us the multiply result
    try expectEqual(result.r, 128);
    try expectEqual(result.g, 128);
    try expectEqual(result.b, 128);
}

test "blend screen mode" {
    const black = Rgba{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const gray = Rgba{ .r = 128, .g = 128, .b = 128, .a = 255 };

    const result = blendColors(black, gray, .screen);

    // Screen with gray should lighten to gray
    try expectEqual(result.r, 128);
    try expectEqual(result.g, 128);
    try expectEqual(result.b, 128);
}

test "blend with transparent" {
    const base = Rgba{ .r = 100, .g = 100, .b = 100, .a = 255 };
    const transparent = Rgba{ .r = 200, .g = 200, .b = 200, .a = 0 };

    const result = blendColors(base, transparent, .normal);

    // Should remain unchanged
    try expectEqual(result, base);
}

test "blend semi-transparent colors" {
    // Test Porter-Duff compositing with two semi-transparent colors
    const base = Rgba{ .r = 100, .g = 100, .b = 100, .a = 128 }; // 50% opacity
    const overlay = Rgba{ .r = 200, .g = 200, .b = 200, .a = 128 }; // 50% opacity

    const result = blendColors(base, overlay, .normal);

    // Alpha should be: 0.5 + 0.5 * (1 - 0.5) = 0.75 = ~191
    try expect(result.a >= 190 and result.a <= 192);

    // RGB should be properly composited
    try expect(result.r > 130 and result.r < 170); // Should be between base and overlay
}

test "blend with transparent base" {
    // Test blending onto a fully transparent base
    const base = Rgba{ .r = 0, .g = 0, .b = 0, .a = 0 }; // Fully transparent
    const overlay = Rgba{ .r = 200, .g = 150, .b = 100, .a = 180 }; // ~70% opacity

    const result = blendColors(base, overlay, .normal);

    // Result alpha should be same as overlay since base is transparent
    try expectEqual(result.a, 180);

    // RGB should be overlay's colors (with slight rounding possible)
    try expect(@abs(@as(i16, result.r) - 200) <= 1);
    try expect(@abs(@as(i16, result.g) - 150) <= 1);
    try expect(@abs(@as(i16, result.b) - 100) <= 1);
}

test "blend modes with alpha" {
    // Test that blend modes work correctly with semi-transparent colors
    const base = Rgba{ .r = 100, .g = 100, .b = 100, .a = 200 }; // ~78% opacity
    const overlay = Rgba{ .r = 50, .g = 50, .b = 50, .a = 100 }; // ~39% opacity

    // Test multiply with alpha
    const multiply_result = blendColors(base, overlay, .multiply);
    // Alpha should composite correctly using Porter-Duff formula:
    // result_a = overlay_a + base_a * (1 - overlay_a)
    // = 100/255 + 200/255 * (1 - 100/255)
    // = 100/255 + 200/255 * 155/255
    // = 0.392 + 0.784 * 0.608 = 0.392 + 0.477 = 0.869 = ~221
    const expected_alpha: u8 = 221;
    try expect(@abs(@as(i16, multiply_result.a) - @as(i16, expected_alpha)) <= 2);

    // Test screen with alpha - should have same alpha as multiply
    const screen_result = blendColors(base, overlay, .screen);
    try expect(@abs(@as(i16, screen_result.a) - @as(i16, expected_alpha)) <= 2);

    // RGB values should differ between multiply and screen
    try expect(multiply_result.r < screen_result.r); // Multiply darkens, screen lightens
}

test "blend ignores hidden base color when fully transparent" {
    const base = Rgba{ .r = 25, .g = 75, .b = 125, .a = 0 };
    const overlay = Rgba{ .r = 200, .g = 150, .b = 100, .a = 180 };

    const multiply_result = blendColors(base, overlay, .multiply);
    try expectEqual(multiply_result, overlay);

    const screen_result = blendColors(base, overlay, .screen);
    try expectEqual(screen_result, overlay);

    const exclusion_result = blendColors(base, overlay, .exclusion);
    try expectEqual(exclusion_result, overlay);
}
