//! A color in the [XYB color space](https://jpeg.org/jpegxl/documentation/xl-color-management.html#xyb)
//! used in JPEG XL. It's derived from LMS and designed for efficient image compression.
//! - x: X component (L-M, red-green opponent channel).
//! - y: Y component (L+M, luminance-like channel).
//! - b: B component (S, blue-yellow like channel, but often scaled S cone response).
//! Ranges can vary based on transformations, but often centered around 0 for x and b, and positive for y.

const std = @import("std");

const conversions = @import("conversions.zig");
const formatting = @import("formatting.zig");

// Import color types
const Rgb = @import("Rgb.zig");
const Rgba = @import("Rgba.zig").Rgba;
const Hsl = @import("Hsl.zig");
const Hsv = @import("Hsv.zig");
const Lab = @import("Lab.zig");
const Xyz = @import("Xyz.zig");
const Lms = @import("Lms.zig");
const Oklab = @import("Oklab.zig");
const Xyb = @import("Xyb.zig");

x: f64,
y: f64,
b: f64,

pub const black: @This() = .{ .x = 0, .y = 0, .b = 0 };

const Self = @This();

pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    return formatting.formatColor(Self, self, fmt, options, writer);
}

pub fn isGray(self: Self) bool {
    const oklab = self.toOklab();
    return oklab.a == 0 and oklab.b == 0;
}

pub fn toGray(self: Self) u8 {
    return @intFromFloat(@round(@max(0, @min(1, self.toOklab().l)) * 255));
}

pub fn toRgb(self: Self) Rgb {
    return conversions.xybToRgb(self);
}

pub fn toRgba(self: Self, alpha: u8) Rgba {
    return self.toRgb().toRgba(alpha);
}

pub fn toHsl(self: Self) Hsl {
    return conversions.xybToHsl(self);
}

pub fn toHsv(self: Self) Hsv {
    return conversions.xybToHsv(self);
}

pub fn toXyz(self: Self) Xyz {
    return conversions.xybToXyz(self);
}

pub fn toLab(self: Self) Lab {
    return conversions.xybToLab(self);
}

pub fn toLms(self: Self) Lms {
    return conversions.xybToLms(self);
}

pub fn toOklab(self: Self) Oklab {
    return conversions.xybToOklab(self);
}

pub fn blend(self: *Self, color: Rgba) void {
    var rgb = self.toRgb();
    rgb.blend(color);
    self.* = rgb.toXyb();
}
