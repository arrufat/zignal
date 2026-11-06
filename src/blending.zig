//! Color blending modes and compositing operations.

const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const Rgba = @import("color.zig").Rgba;

/// Color blending modes following standard compositing equations.
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

/// The float type colors with backing type `T` are computed in: f32 for u8, `T` itself for floats.
fn Float(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .float => T,
        .int => if (T == u8) f32 else @compileError("Unsupported backing type " ++ @typeName(T) ++ " for color space"),
        else => @compileError("Unsupported backing type " ++ @typeName(T) ++ " for color space"),
    };
}

/// Blends two RGBA colors using the specified blend mode.
/// Accepts any Rgba(T) types (e.g., Rgba(u8), Rgba(f32)).
/// Returns Rgba(T) matching the base color's type.
pub fn blendColors(comptime T: type, base: Rgba(T), overlay: Rgba(T), mode: Blending) Rgba(T) {
    if (mode == .none) return overlay;

    // Early return for fully transparent overlay
    if (if (T == u8) overlay.a == 0 else overlay.a <= 0) return base;

    // Hidden base color should not influence blending
    if (if (T == u8) base.a == 0 else base.a <= 0) return overlay;

    // For normal blend mode with a fully opaque overlay, result is just overlay
    if (mode == .normal and (if (T == u8) overlay.a == 255 else overlay.a >= 1.0)) return overlay;

    const F = Float(T);
    const base_f = if (T == u8) base.as(F) else base;
    const overlay_f = if (T == u8) overlay.as(F) else overlay;

    const base_v = @Vector(3, F){ base_f.r, base_f.g, base_f.b };
    const overlay_v = @Vector(3, F){ overlay_f.r, overlay_f.g, overlay_f.b };
    var blended_v: @Vector(3, F) = undefined;

    switch (mode) {
        .none => unreachable,
        .normal => {
            blended_v = overlay_v;
        },
        .multiply => {
            blended_v = base_v * overlay_v;
        },
        .screen => {
            const ones: @Vector(3, F) = @splat(1.0);
            blended_v = ones - (ones - base_v) * (ones - overlay_v);
        },
        .overlay => {
            const halfs: @Vector(3, F) = @splat(0.5);
            const cond = base_v < halfs;
            const ones: @Vector(3, F) = @splat(1.0);
            const twos: @Vector(3, F) = @splat(2.0);
            const expr1 = twos * base_v * overlay_v;
            const expr2 = ones - twos * (ones - base_v) * (ones - overlay_v);
            blended_v = @select(F, cond, expr1, expr2);
        },
        .soft_light => {
            const halfs: @Vector(3, F) = @splat(0.5);
            const cond = overlay_v <= halfs;
            const ones: @Vector(3, F) = @splat(1.0);
            const twos: @Vector(3, F) = @splat(2.0);
            const sqrt_base = @sqrt(base_v);
            const expr1 = base_v - (ones - twos * overlay_v) * base_v * (ones - base_v);
            const expr2 = base_v + (twos * overlay_v - ones) * (sqrt_base - base_v);
            blended_v = @select(F, cond, expr1, expr2);
        },
        .hard_light => {
            const halfs: @Vector(3, F) = @splat(0.5);
            const cond = overlay_v < halfs;
            const ones: @Vector(3, F) = @splat(1.0);
            const twos: @Vector(3, F) = @splat(2.0);
            const expr1 = twos * overlay_v * base_v;
            const expr2 = ones - twos * (ones - overlay_v) * (ones - base_v);
            blended_v = @select(F, cond, expr1, expr2);
        },
        .color_dodge => {
            const ones: @Vector(3, F) = @splat(1.0);
            const zeros: @Vector(3, F) = @splat(0.0);
            const result = base_v / (ones - overlay_v);
            const is_base_zero = base_v == zeros;
            const is_blend_one = overlay_v >= ones;
            const val_else = @min(ones, result);
            const val_blend = @select(F, is_blend_one, ones, val_else);
            blended_v = @select(F, is_base_zero, zeros, val_blend);
        },
        .color_burn => {
            const ones: @Vector(3, F) = @splat(1.0);
            const zeros: @Vector(3, F) = @splat(0.0);
            const result = ones - (ones - base_v) / overlay_v;
            const is_base_one = base_v >= ones;
            const is_blend_zero = overlay_v <= zeros;
            const val_else = @max(zeros, result);
            const val_blend = @select(F, is_blend_zero, zeros, val_else);
            blended_v = @select(F, is_base_one, ones, val_blend);
        },
        .darken => {
            blended_v = @min(base_v, overlay_v);
        },
        .lighten => {
            blended_v = @max(base_v, overlay_v);
        },
        .difference => {
            blended_v = @abs(base_v - overlay_v);
        },
        .exclusion => {
            const twos: @Vector(3, F) = @splat(2.0);
            blended_v = base_v + overlay_v - twos * base_v * overlay_v;
        },
    }

    const is_opaque = if (T == u8) overlay.a == 255 else overlay.a >= 1.0;
    var out: Rgba(F) = undefined;

    if (is_opaque) {
        out = .{
            .r = blended_v[0],
            .g = blended_v[1],
            .b = blended_v[2],
            .a = 1.0,
        };
    } else {
        const result_a = overlay_f.a + base_f.a * (1.0 - overlay_f.a);
        if (result_a <= 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        const base_weight = base_f.a * (1.0 - overlay_f.a);
        const inv_result_a = 1.0 / result_a;

        const base_weight_v: @Vector(3, F) = @splat(base_weight);
        const overlay_a_v: @Vector(3, F) = @splat(overlay_f.a);
        const inv_result_a_v: @Vector(3, F) = @splat(inv_result_a);

        const out_v = (blended_v * overlay_a_v + base_v * base_weight_v) * inv_result_a_v;
        out = .{
            .r = out_v[0],
            .g = out_v[1],
            .b = out_v[2],
            .a = result_a,
        };
    }

    return if (T == u8) out.as(T) else out;
}

/// Porter-Duff compositing operators, where `src` is the overlay and `dst` the base.
/// Each operator weights the premultiplied colors as `out = Fa * src + Fb * dst`.
pub const Compositing = enum {
    /// Fully transparent result.
    clear,
    /// Overlay only.
    src,
    /// Base only.
    dst,
    /// Overlay over base (normal alpha compositing).
    src_over,
    /// Base over overlay.
    dst_over,
    /// Overlay where the base is opaque.
    src_in,
    /// Base where the overlay is opaque.
    dst_in,
    /// Overlay where the base is transparent.
    src_out,
    /// Base where the overlay is transparent.
    dst_out,
    /// Overlay over base, clipped to the base.
    src_atop,
    /// Base over overlay, clipped to the overlay.
    dst_atop,
    /// Overlay and base where they do not overlap.
    xor,
    /// Additive sum, saturated.
    plus,

    /// Returns the overlay and base weights `.{ Fa, Fb }`.
    fn factors(self: Compositing, comptime F: type, src_a: F, dst_a: F) [2]F {
        return switch (self) {
            .clear => .{ 0, 0 },
            .src => .{ 1, 0 },
            .dst => .{ 0, 1 },
            .src_over => .{ 1, 1 - src_a },
            .dst_over => .{ 1 - dst_a, 1 },
            .src_in => .{ dst_a, 0 },
            .dst_in => .{ 0, src_a },
            .src_out => .{ 1 - dst_a, 0 },
            .dst_out => .{ 0, 1 - src_a },
            .src_atop => .{ dst_a, 1 - src_a },
            .dst_atop => .{ 1 - dst_a, src_a },
            .xor => .{ 1 - dst_a, 1 - src_a },
            .plus => .{ 1, 1 },
        };
    }
};

/// Composites `overlay` (source) onto `base` (destination) with a Porter-Duff operator.
/// Accepts Rgba(u8) or any float Rgba(T); the result is straight (non-premultiplied) alpha.
pub fn compositeColors(comptime T: type, base: Rgba(T), overlay: Rgba(T), op: Compositing) Rgba(T) {
    if (op == .src_over) {
        if (if (T == u8) overlay.a == 255 else overlay.a >= 1) return overlay;
        if (if (T == u8) overlay.a == 0 else overlay.a <= 0) return base;
    }
    const F = Float(T);
    const V = @Vector(4, F);
    const s = if (T == u8) overlay.as(F) else overlay;
    const d = if (T == u8) base.as(F) else base;

    const fa, const fb = op.factors(F, s.a, d.a);
    const src_v: V = .{ s.r * s.a, s.g * s.a, s.b * s.a, s.a };
    const dst_v: V = .{ d.r * d.a, d.g * d.a, d.b * d.a, d.a };
    var out_v = src_v * @as(V, @splat(fa)) + dst_v * @as(V, @splat(fb));
    if (op == .plus) out_v = @min(out_v, @as(V, @splat(1)));

    const a = out_v[3];
    if (a <= 0) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const rgb = out_v * @as(V, @splat(1 / a));
    const out: Rgba(F) = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = a };
    return if (T == u8) out.as(T) else out;
}

// Channel implementations

fn colorDodgeChannel(comptime F: type, base: F, blend: F) F {
    comptime assert(@typeInfo(F) == .float);
    if (base == 0) return 0;
    if (blend >= 1.0) return 1.0;
    return @min(1.0, base / (1.0 - blend));
}

fn colorBurnChannel(comptime F: type, base: F, blend: F) F {
    comptime assert(@typeInfo(F) == .float);
    if (base >= 1.0) return 1.0;
    if (blend <= 0.0) return 0.0;
    return @max(0.0, 1.0 - (1.0 - base) / blend);
}

// Tests

test "blendColors: normal mode" {
    const base: Rgba(u8) = .{ .r = 100, .g = 100, .b = 100, .a = 255 };
    const blend: Rgba(u8) = .{ .r = 200, .g = 200, .b = 200, .a = 128 };

    const result = blendColors(u8, base, blend, .normal);

    // Should be approximately halfway between base and blend
    try expect(result.r > 140 and result.r < 160);
    try expect(result.g > 140 and result.g < 160);
    try expect(result.b > 140 and result.b < 160);
}

test "blendColors: multiply mode" {
    const white = Rgba(u8){ .r = 255, .g = 255, .b = 255, .a = 255 };
    const gray = Rgba(u8){ .r = 128, .g = 128, .b = 128, .a = 255 };

    const result = blendColors(u8, white, gray, .multiply);

    try expectEqual(result.r, 128);
    try expectEqual(result.g, 128);
    try expectEqual(result.b, 128);
}

test "blendColors: screen mode" {
    const black = Rgba(u8){ .r = 0, .g = 0, .b = 0, .a = 255 };
    const gray = Rgba(u8){ .r = 128, .g = 128, .b = 128, .a = 255 };

    const result = blendColors(u8, black, gray, .screen);

    try expectEqual(result.r, 128);
    try expectEqual(result.g, 128);
    try expectEqual(result.b, 128);
}

test "blendColors: transparent overlay" {
    const base: Rgba(u8) = .{ .r = 100, .g = 100, .b = 100, .a = 255 };
    const transparent: Rgba(u8) = .{ .r = 200, .g = 200, .b = 200, .a = 0 };

    const result = blendColors(u8, base, transparent, .normal);

    // Should remain unchanged
    try expectEqual(result.r, base.r);
    try expectEqual(result.g, base.g);
    try expectEqual(result.b, base.b);
    try expectEqual(result.a, base.a);
}

test "blendColors: semi-transparent colors" {
    // Test Porter-Duff compositing with two semi-transparent colors
    const base: Rgba(u8) = .{ .r = 100, .g = 100, .b = 100, .a = 128 }; // ~50% opacity
    const overlay: Rgba(u8) = .{ .r = 200, .g = 200, .b = 200, .a = 128 }; // ~50% opacity

    const result = blendColors(u8, base, overlay, .normal);

    // Alpha should be: 0.5 + 0.5 * (1 - 0.5) = 0.75 = ~191
    try expect(result.a >= 190 and result.a <= 192);

    // RGB should be properly composited
    try expect(result.r > 130 and result.r < 170); // Should be between base and overlay
}

test "blendColors: transparent base" {
    // Test blending onto a fully transparent base
    const base: Rgba(u8) = .{ .r = 0, .g = 0, .b = 0, .a = 0 }; // Fully transparent
    const overlay: Rgba(u8) = .{ .r = 200, .g = 150, .b = 100, .a = 180 }; // ~70% opacity

    const result = blendColors(u8, base, overlay, .normal);

    // Result alpha should be same as overlay since base is transparent
    try expectEqual(result.a, 180);

    // RGB should be overlay's colors (with slight rounding possible)
    try expect(@abs(@as(i16, result.r) - 200) <= 1);
    try expect(@abs(@as(i16, result.g) - 150) <= 1);
    try expect(@abs(@as(i16, result.b) - 100) <= 1);
}

test "blendColors: modes with alpha" {
    // Test that blend modes work correctly with semi-transparent colors
    const base: Rgba(u8) = .{ .r = 100, .g = 100, .b = 100, .a = 200 }; // ~78% opacity
    const overlay: Rgba(u8) = .{ .r = 50, .g = 50, .b = 50, .a = 100 }; // ~39% opacity

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

test "blendColors: ignores hidden base color when fully transparent" {
    const base: Rgba(u8) = .{ .r = 25, .g = 75, .b = 125, .a = 0 };
    const overlay: Rgba(u8) = .{ .r = 200, .g = 150, .b = 100, .a = 180 };

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

test "blendColors: f64 support" {
    const base: Rgba(f64) = .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 };
    const overlay: Rgba(f64) = .{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 0.5 };

    const result = blendColors(f64, base, overlay, .normal);

    try expectEqual(result.r, 0.75);
    try expectEqual(result.a, 1.0);
}

test "colorDodgeChannel: edge cases" {
    const F = f32;
    // B=0, S=1 -> result=0 (W3C standard)
    try expectEqual(colorDodgeChannel(F, 0.0, 1.0), 0.0);
    // B=0.5, S=1 -> result=1
    try expectEqual(colorDodgeChannel(F, 0.5, 1.0), 1.0);
}

test "colorBurnChannel: edge cases" {
    const F = f32;
    // B=1, S=0 -> result=1 (W3C standard)
    try expectEqual(colorBurnChannel(F, 1.0, 0.0), 1.0);
    // B=0.5, S=0 -> result=0
    try expectEqual(colorBurnChannel(F, 0.5, 0.0), 0.0);
}

test "blendColors: none mode" {
    // Should just return the overlay (replace)
    const base: Rgba(u8) = .{ .r = 100, .g = 100, .b = 100, .a = 255 };
    const overlay: Rgba(u8) = .{ .r = 200, .g = 200, .b = 200, .a = 255 };
    const result = blendColors(u8, base, overlay, .none);
    try expectEqual(result.r, overlay.r);
    try expectEqual(result.g, overlay.g);
    try expectEqual(result.b, overlay.b);
}

test "blendColors: overlay mode" {
    // If base < 0.5: 2 * base * blend
    const base_dark: Rgba(f32) = .{ .r = 0.25, .g = 0.25, .b = 0.25, .a = 1.0 };
    const overlay: Rgba(f32) = .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 };
    const result_dark = blendColors(f32, base_dark, overlay, .overlay);
    // 2 * 0.25 * 0.5 = 0.25
    try expectEqual(result_dark.r, 0.25);

    // If base >= 0.5: 1 - 2 * (1 - base) * (1 - blend)
    const base_light: Rgba(f32) = .{ .r = 0.75, .g = 0.75, .b = 0.75, .a = 1.0 };
    const result_light = blendColors(f32, base_light, overlay, .overlay);
    // 1 - 2 * (0.25) * (0.5) = 1 - 0.25 = 0.75
    try expectEqual(result_light.r, 0.75);
}

test "blendColors: hard_light mode" {
    // Hard light is overlay with base and overlay swapped
    // If overlay < 0.5: 2 * overlay * base
    const base: Rgba(f32) = .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 };
    const overlay_dark: Rgba(f32) = .{ .r = 0.25, .g = 0.25, .b = 0.25, .a = 1.0 };
    const result_dark = blendColors(f32, base, overlay_dark, .hard_light);
    // 2 * 0.25 * 0.5 = 0.25
    try expectEqual(result_dark.r, 0.25);
}

test "blendColors: soft_light mode" {
    // If blend <= 0.5: base - (1 - 2*blend) * base * (1 - base)
    const base: Rgba(f32) = .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 };
    const overlay_dark: Rgba(f32) = .{ .r = 0.25, .g = 0.25, .b = 0.25, .a = 1.0 };
    const result = blendColors(f32, base, overlay_dark, .soft_light);
    // 0.5 - (1 - 0.5) * 0.5 * 0.5 = 0.5 - 0.5 * 0.25 = 0.5 - 0.125 = 0.375
    try expectEqual(result.r, 0.375);
}

test "blendColors: darken mode" {
    const base: Rgba(u8) = .{ .r = 100, .g = 200, .b = 100, .a = 255 };
    const overlay: Rgba(u8) = .{ .r = 200, .g = 100, .b = 100, .a = 255 };
    const result = blendColors(u8, base, overlay, .darken);
    try expectEqual(result.r, 100);
    try expectEqual(result.g, 100);
    try expectEqual(result.b, 100);
}

test "blendColors: lighten mode" {
    const base: Rgba(u8) = .{ .r = 100, .g = 200, .b = 100, .a = 255 };
    const overlay: Rgba(u8) = .{ .r = 200, .g = 100, .b = 100, .a = 255 };
    const result = blendColors(u8, base, overlay, .lighten);
    try expectEqual(result.r, 200);
    try expectEqual(result.g, 200);
    try expectEqual(result.b, 100);
}

test "blendColors: difference mode" {
    const base: Rgba(u8) = .{ .r = 200, .g = 100, .b = 50, .a = 255 };
    const overlay: Rgba(u8) = .{ .r = 50, .g = 200, .b = 200, .a = 255 };
    const result = blendColors(u8, base, overlay, .difference);
    try expectEqual(result.r, 150);
    try expectEqual(result.g, 100);
    try expectEqual(result.b, 150);
}

test "blendColors: exclusion mode" {
    // base + blend - 2 * base * blend
    const base: Rgba(f32) = .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 };
    const overlay: Rgba(f32) = .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 1.0 };
    const result = blendColors(f32, base, overlay, .exclusion);
    // 0.5 + 0.5 - 2 * 0.25 = 1.0 - 0.5 = 0.5
    try expectEqual(result.r, 0.5);
}

test "Rgba.composite: alpha follows the Porter-Duff factors" {
    const base: Rgba(f32) = .{ .r = 1, .g = 0, .b = 0, .a = 0.5 };
    const overlay: Rgba(f32) = .{ .r = 0, .g = 0, .b = 1, .a = 0.5 };
    const cases = [_]struct { op: Compositing, a: f32 }{
        .{ .op = .clear, .a = 0 },
        .{ .op = .src, .a = 0.5 },
        .{ .op = .dst, .a = 0.5 },
        .{ .op = .src_over, .a = 0.75 },
        .{ .op = .dst_over, .a = 0.75 },
        .{ .op = .src_in, .a = 0.25 },
        .{ .op = .dst_in, .a = 0.25 },
        .{ .op = .src_out, .a = 0.25 },
        .{ .op = .dst_out, .a = 0.25 },
        .{ .op = .src_atop, .a = 0.5 },
        .{ .op = .dst_atop, .a = 0.5 },
        .{ .op = .xor, .a = 0.5 },
        .{ .op = .plus, .a = 1 },
    };
    for (cases) |case| {
        try expectEqual(case.a, base.composite(overlay, case.op).a);
    }
}

test "Rgba.composite: in, out and atop pick the expected color" {
    const base: Rgba(u8) = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    const overlay: Rgba(u8) = .{ .r = 0, .g = 0, .b = 255, .a = 128 };

    // Opaque base: src_in keeps the overlay as is, src_out removes it.
    try expectEqual(overlay, base.composite(overlay, .src_in));
    try expectEqual(Rgba(u8){ .r = 0, .g = 0, .b = 0, .a = 0 }, base.composite(overlay, .src_out));

    // src_atop keeps the base alpha and mixes the colors like src_over.
    const atop = base.composite(overlay, .src_atop);
    try expectEqual(255, atop.a);
    try expectEqual(base.composite(overlay, .src_over), atop);

    // dst_in keeps the base color with the overlay alpha.
    try expectEqual(Rgba(u8){ .r = 255, .g = 0, .b = 0, .a = 128 }, base.composite(overlay, .dst_in));
}

test "Rgba.composite: src_over matches normal blending" {
    const base: Rgba(u8) = .{ .r = 100, .g = 150, .b = 200, .a = 200 };
    const overlay: Rgba(u8) = .{ .r = 200, .g = 50, .b = 25, .a = 100 };
    const composited = base.composite(overlay, .src_over);
    const blended = blendColors(u8, base, overlay, .normal);
    inline for (.{ "r", "g", "b", "a" }) |field| {
        try expect(@abs(@as(i16, @field(composited, field)) - @field(blended, field)) <= 1);
    }
}

test "Rgba.composite: plus saturates" {
    const base: Rgba(u8) = .{ .r = 200, .g = 100, .b = 0, .a = 255 };
    const overlay: Rgba(u8) = .{ .r = 100, .g = 100, .b = 50, .a = 255 };
    try expectEqual(Rgba(u8){ .r = 255, .g = 200, .b = 50, .a = 255 }, base.composite(overlay, .plus));
}
