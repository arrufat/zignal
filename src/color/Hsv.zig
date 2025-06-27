//! A color in the [HSV](https://en.wikipedia.org/wiki/HSL_and_HSV) colorspace.
//! - h: Hue, in degrees (0-360, though often normalized to 0-359).
//! - s: Saturation, as a percentage (0-100).
//! - v: Value, as a percentage (0-100).

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

h: f64,
s: f64,
v: f64,

pub const black: @This() = .{ .h = 0, .s = 0, .v = 0 };
pub const white: @This() = .{ .h = 0, .s = 0, .v = 100 };

const Self = @This();

pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    return formatting.formatColor(Self, self, fmt, options, writer);
}

pub fn isGray(self: Self) bool {
    return self.s == 0;
}

pub fn toGray(self: Self) u8 {
    return @intFromFloat(@round(self.v / 100 * 255));
}

pub fn toRgb(self: Self) Rgb {
    return conversions.hsvToRgb(self);
}

pub fn toRgba(self: Self, alpha: u8) Rgba {
    return self.toRgb().toRgba(alpha);
}

pub fn toHsl(self: Self) Hsl {
    return conversions.hsvToHsl(self);
}

pub fn toXyz(self: Self) Xyz {
    return self.toRgb().toXyz();
}

pub fn toLab(self: Self) Lab {
    return conversions.hsvToLab(self);
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
    self.* = rgb.toHsv();
}
