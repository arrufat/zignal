//! A color in the [HSL](https://en.wikipedia.org/wiki/HSL_and_HSV) colorspace.
//! - h: Hue, in degrees (0-360, though often normalized to 0-359).
//! - s: Saturation, as a percentage (0-100).
//! - l: Lightness, as a percentage (0-100).

const std = @import("std");

const conversions = @import("conversions.zig");
const formatting = @import("formatting.zig");
const Hsl = @import("Hsl.zig");
const Hsv = @import("Hsv.zig");
const Lab = @import("Lab.zig");
const Lms = @import("Lms.zig");
const Oklab = @import("Oklab.zig");
const Rgb = @import("Rgb.zig");
const Rgba = @import("Rgba.zig").Rgba;
const Xyb = @import("Xyb.zig");
const Xyz = @import("Xyz.zig");

h: f64,
s: f64,
l: f64,

pub const black: @This() = .{ .h = 0, .s = 0, .l = 0 };
pub const white: @This() = .{ .h = 0, .s = 0, .l = 100 };

const Self = @This();

pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    return formatting.formatColor(Self, self, fmt, options, writer);
}

pub fn isGray(self: Self) bool {
    return self.s == 0;
}

pub fn toGray(self: Self) u8 {
    return @intFromFloat(@round(self.l / 100 * 255));
}

pub fn toRgb(self: Self) Rgb {
    return conversions.hslToRgb(self);
}

pub fn toRgba(self: Self, alpha: u8) Rgba {
    return self.toRgb().toRgba(alpha);
}

pub fn toHsv(self: Self) Hsv {
    return self.toRgb().toHsv();
}

pub fn toXyz(self: Self) Xyz {
    return self.toRgb().toXyz();
}

pub fn toLab(self: Self) Lab {
    return conversions.hslToLab(self);
}

pub fn toLms(self: Self) Lms {
    return self.toRgb().toLms();
}

pub fn toOklab(self: Self) Oklab {
    return self.toRgb().toOklab();
}

pub fn toXyb(self: Self) Xyb {
    return self.toRgb().toXyb();
}

pub fn blend(self: *Self, color: Rgba) void {
    var rgb = self.toRgb();
    rgb.blend(color);
    self.* = rgb.toHsl();
}
