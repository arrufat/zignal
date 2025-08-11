//! Color blending modes and utilities
//!
//! This module provides various blending modes for compositing colors,
//! similar to those found in image editing software.

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Rgb = @import("Rgb.zig");
const Rgba = @import("Rgba.zig").Rgba;

/// Available blending modes for color composition
pub const BlendMode = enum {
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

/// Blends two RGBA colors using the specified blend mode with proper alpha compositing.
/// Both colors' alpha channels are taken into account for mathematically correct blending.
/// Returns a new RGBA color with the blended result.
pub fn blendColors(base: Rgba, overlay: Rgba, mode: BlendMode) Rgba {
    // Early return for fully transparent overlay
    if (overlay.a == 0) return base;

    // Early return for fully opaque overlay with normal mode over transparent base
    if (overlay.a == 255 and base.a == 0 and mode == .normal) return overlay;

    // Calculate alpha values
    const base_alpha = @as(f32, @floatFromInt(base.a)) / 255.0;
    const overlay_alpha = @as(f32, @floatFromInt(overlay.a)) / 255.0;
    const result_alpha = base_alpha + overlay_alpha * (1.0 - base_alpha);

    // Handle case where both colors are fully transparent
    if (result_alpha == 0) {
        return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    }

    // Blend RGB components based on mode
    const blended_rgb = switch (mode) {
        .normal => blendNormal(base, overlay, base_alpha, overlay_alpha, result_alpha),
        .multiply => blendMultiply(base, overlay, base_alpha, overlay_alpha, result_alpha),
        .screen => blendScreen(base, overlay, base_alpha, overlay_alpha, result_alpha),
        .overlay => blendOverlay(base, overlay, base_alpha, overlay_alpha, result_alpha),
        .soft_light => blendSoftLight(base, overlay, base_alpha, overlay_alpha, result_alpha),
        .hard_light => blendHardLight(base, overlay, base_alpha, overlay_alpha, result_alpha),
        .color_dodge => blendColorDodge(base, overlay, base_alpha, overlay_alpha, result_alpha),
        .color_burn => blendColorBurn(base, overlay, base_alpha, overlay_alpha, result_alpha),
        .darken => blendDarken(base, overlay, base_alpha, overlay_alpha, result_alpha),
        .lighten => blendLighten(base, overlay, base_alpha, overlay_alpha, result_alpha),
        .difference => blendDifference(base, overlay, base_alpha, overlay_alpha, result_alpha),
        .exclusion => blendExclusion(base, overlay, base_alpha, overlay_alpha, result_alpha),
    };

    return .{
        .r = blended_rgb.r,
        .g = blended_rgb.g,
        .b = blended_rgb.b,
        .a = @intFromFloat(result_alpha * 255.0),
    };
}

// Helper function for proper alpha compositing of a single channel
// This composites the already-blended overlay value with the base value
fn compositeChannel(base_value: f32, blended_value: f32, base_alpha: f32, overlay_alpha: f32, result_alpha: f32) f32 {
    // When both are fully opaque, just return the blended value
    if (base_alpha == 1.0 and overlay_alpha == 1.0) {
        return blended_value;
    }
    // Simplified case when base is opaque - common for RGB blending onto opaque surface
    if (base_alpha == 1.0) {
        return std.math.lerp(base_value, blended_value, overlay_alpha);
    }
    // General alpha compositing using lerp
    // (base_value * base_alpha + blended_value * overlay_alpha * (1.0 - base_alpha)) / result_alpha;
    // The interpolation weight is the portion of the final alpha that comes from the overlay
    const lerp_weight = overlay_alpha * (1.0 - base_alpha) / result_alpha;
    return std.math.lerp(base_value, blended_value, lerp_weight);
}

fn blendNormal(base: Rgba, overlay: Rgba, base_alpha: f32, overlay_alpha: f32, result_alpha: f32) Rgb {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));

    return .{
        .r = @intFromFloat(compositeChannel(base_r, overlay_r, base_alpha, overlay_alpha, result_alpha)),
        .g = @intFromFloat(compositeChannel(base_g, overlay_g, base_alpha, overlay_alpha, result_alpha)),
        .b = @intFromFloat(compositeChannel(base_b, overlay_b, base_alpha, overlay_alpha, result_alpha)),
    };
}

fn blendMultiply(base: Rgba, overlay: Rgba, base_alpha: f32, overlay_alpha: f32, result_alpha: f32) Rgb {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));

    const blended_r = (base_r * overlay_r) / 255.0;
    const blended_g = (base_g * overlay_g) / 255.0;
    const blended_b = (base_b * overlay_b) / 255.0;

    return .{
        .r = @intFromFloat(compositeChannel(base_r, blended_r, base_alpha, overlay_alpha, result_alpha)),
        .g = @intFromFloat(compositeChannel(base_g, blended_g, base_alpha, overlay_alpha, result_alpha)),
        .b = @intFromFloat(compositeChannel(base_b, blended_b, base_alpha, overlay_alpha, result_alpha)),
    };
}

fn blendScreen(base: Rgba, overlay: Rgba, base_alpha: f32, overlay_alpha: f32, result_alpha: f32) Rgb {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));

    const blended_r = 255.0 - ((255.0 - base_r) * (255.0 - overlay_r) / 255.0);
    const blended_g = 255.0 - ((255.0 - base_g) * (255.0 - overlay_g) / 255.0);
    const blended_b = 255.0 - ((255.0 - base_b) * (255.0 - overlay_b) / 255.0);

    return .{
        .r = @intFromFloat(compositeChannel(base_r, blended_r, base_alpha, overlay_alpha, result_alpha)),
        .g = @intFromFloat(compositeChannel(base_g, blended_g, base_alpha, overlay_alpha, result_alpha)),
        .b = @intFromFloat(compositeChannel(base_b, blended_b, base_alpha, overlay_alpha, result_alpha)),
    };
}

fn overlayChannel(base: f32, blend: f32) f32 {
    if (base < 128.0) {
        return (2.0 * base * blend) / 255.0;
    } else {
        return 255.0 - (2.0 * (255.0 - base) * (255.0 - blend) / 255.0);
    }
}

fn blendOverlay(base: Rgba, overlay: Rgba, base_alpha: f32, overlay_alpha: f32, result_alpha: f32) Rgb {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));

    const blended_r = overlayChannel(base_r, overlay_r);
    const blended_g = overlayChannel(base_g, overlay_g);
    const blended_b = overlayChannel(base_b, overlay_b);

    return .{
        .r = @intFromFloat(compositeChannel(base_r, blended_r, base_alpha, overlay_alpha, result_alpha)),
        .g = @intFromFloat(compositeChannel(base_g, blended_g, base_alpha, overlay_alpha, result_alpha)),
        .b = @intFromFloat(compositeChannel(base_b, blended_b, base_alpha, overlay_alpha, result_alpha)),
    };
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

fn blendSoftLight(base: Rgba, overlay: Rgba, base_alpha: f32, overlay_alpha: f32, result_alpha: f32) Rgb {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));

    const blended_r = softLightChannel(base_r, overlay_r);
    const blended_g = softLightChannel(base_g, overlay_g);
    const blended_b = softLightChannel(base_b, overlay_b);

    return .{
        .r = @intFromFloat(compositeChannel(base_r, blended_r, base_alpha, overlay_alpha, result_alpha)),
        .g = @intFromFloat(compositeChannel(base_g, blended_g, base_alpha, overlay_alpha, result_alpha)),
        .b = @intFromFloat(compositeChannel(base_b, blended_b, base_alpha, overlay_alpha, result_alpha)),
    };
}

fn blendHardLight(base: Rgba, overlay: Rgba, base_alpha: f32, overlay_alpha: f32, result_alpha: f32) Rgb {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));

    // Hard light is overlay with base and overlay swapped
    const blended_r = overlayChannel(overlay_r, base_r);
    const blended_g = overlayChannel(overlay_g, base_g);
    const blended_b = overlayChannel(overlay_b, base_b);

    return .{
        .r = @intFromFloat(compositeChannel(base_r, blended_r, base_alpha, overlay_alpha, result_alpha)),
        .g = @intFromFloat(compositeChannel(base_g, blended_g, base_alpha, overlay_alpha, result_alpha)),
        .b = @intFromFloat(compositeChannel(base_b, blended_b, base_alpha, overlay_alpha, result_alpha)),
    };
}

fn colorDodgeChannel(base: f32, blend: f32) f32 {
    if (blend >= 255.0) return 255.0;
    const result = (base * 255.0) / (255.0 - blend);
    return @min(255.0, result);
}

fn blendColorDodge(base: Rgba, overlay: Rgba, base_alpha: f32, overlay_alpha: f32, result_alpha: f32) Rgb {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));

    const blended_r = colorDodgeChannel(base_r, overlay_r);
    const blended_g = colorDodgeChannel(base_g, overlay_g);
    const blended_b = colorDodgeChannel(base_b, overlay_b);

    return .{
        .r = @intFromFloat(compositeChannel(base_r, blended_r, base_alpha, overlay_alpha, result_alpha)),
        .g = @intFromFloat(compositeChannel(base_g, blended_g, base_alpha, overlay_alpha, result_alpha)),
        .b = @intFromFloat(compositeChannel(base_b, blended_b, base_alpha, overlay_alpha, result_alpha)),
    };
}

fn colorBurnChannel(base: f32, blend: f32) f32 {
    if (blend <= 0.0) return 0.0;
    const result = 255.0 - ((255.0 - base) * 255.0) / blend;
    return @max(0.0, result);
}

fn blendColorBurn(base: Rgba, overlay: Rgba, base_alpha: f32, overlay_alpha: f32, result_alpha: f32) Rgb {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));

    const blended_r = colorBurnChannel(base_r, overlay_r);
    const blended_g = colorBurnChannel(base_g, overlay_g);
    const blended_b = colorBurnChannel(base_b, overlay_b);

    return .{
        .r = @intFromFloat(compositeChannel(base_r, blended_r, base_alpha, overlay_alpha, result_alpha)),
        .g = @intFromFloat(compositeChannel(base_g, blended_g, base_alpha, overlay_alpha, result_alpha)),
        .b = @intFromFloat(compositeChannel(base_b, blended_b, base_alpha, overlay_alpha, result_alpha)),
    };
}

fn blendDarken(base: Rgba, overlay: Rgba, base_alpha: f32, overlay_alpha: f32, result_alpha: f32) Rgb {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));

    const blended_r = @min(base_r, overlay_r);
    const blended_g = @min(base_g, overlay_g);
    const blended_b = @min(base_b, overlay_b);

    return .{
        .r = @intFromFloat(compositeChannel(base_r, blended_r, base_alpha, overlay_alpha, result_alpha)),
        .g = @intFromFloat(compositeChannel(base_g, blended_g, base_alpha, overlay_alpha, result_alpha)),
        .b = @intFromFloat(compositeChannel(base_b, blended_b, base_alpha, overlay_alpha, result_alpha)),
    };
}

fn blendLighten(base: Rgba, overlay: Rgba, base_alpha: f32, overlay_alpha: f32, result_alpha: f32) Rgb {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));

    const blended_r = @max(base_r, overlay_r);
    const blended_g = @max(base_g, overlay_g);
    const blended_b = @max(base_b, overlay_b);

    return .{
        .r = @intFromFloat(compositeChannel(base_r, blended_r, base_alpha, overlay_alpha, result_alpha)),
        .g = @intFromFloat(compositeChannel(base_g, blended_g, base_alpha, overlay_alpha, result_alpha)),
        .b = @intFromFloat(compositeChannel(base_b, blended_b, base_alpha, overlay_alpha, result_alpha)),
    };
}

fn blendDifference(base: Rgba, overlay: Rgba, base_alpha: f32, overlay_alpha: f32, result_alpha: f32) Rgb {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));

    const blended_r = @abs(base_r - overlay_r);
    const blended_g = @abs(base_g - overlay_g);
    const blended_b = @abs(base_b - overlay_b);

    return .{
        .r = @intFromFloat(compositeChannel(base_r, blended_r, base_alpha, overlay_alpha, result_alpha)),
        .g = @intFromFloat(compositeChannel(base_g, blended_g, base_alpha, overlay_alpha, result_alpha)),
        .b = @intFromFloat(compositeChannel(base_b, blended_b, base_alpha, overlay_alpha, result_alpha)),
    };
}

fn exclusionChannel(base: f32, blend: f32) f32 {
    return base + blend - 2.0 * base * blend / 255.0;
}

fn blendExclusion(base: Rgba, overlay: Rgba, base_alpha: f32, overlay_alpha: f32, result_alpha: f32) Rgb {
    const base_r = @as(f32, @floatFromInt(base.r));
    const base_g = @as(f32, @floatFromInt(base.g));
    const base_b = @as(f32, @floatFromInt(base.b));
    const overlay_r = @as(f32, @floatFromInt(overlay.r));
    const overlay_g = @as(f32, @floatFromInt(overlay.g));
    const overlay_b = @as(f32, @floatFromInt(overlay.b));

    const blended_r = exclusionChannel(base_r, overlay_r);
    const blended_g = exclusionChannel(base_g, overlay_g);
    const blended_b = exclusionChannel(base_b, overlay_b);

    return .{
        .r = @intFromFloat(compositeChannel(base_r, blended_r, base_alpha, overlay_alpha, result_alpha)),
        .g = @intFromFloat(compositeChannel(base_g, blended_g, base_alpha, overlay_alpha, result_alpha)),
        .b = @intFromFloat(compositeChannel(base_b, blended_b, base_alpha, overlay_alpha, result_alpha)),
    };
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
