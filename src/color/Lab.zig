//! A color in the [CIELAB color space](https://en.wikipedia.org/wiki/CIELAB_color_space) (also known as L*a*b*).
//! It expresses color as three values:
//! - l: Lightness (0 for black to 100 for white).
//! - a: Green-red axis (-128 for green to +127 for red).
//! - b: Blue-yellow axis (-128 for blue to +127 for yellow).

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

l: f64,
a: f64,
b: f64,

pub const black: @This() = .{ .l = 0, .a = 0, .b = 0 };
pub const white: @This() = .{ .l = 100, .a = 0, .b = 0 };

const Self = @This();

pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    return formatting.formatColor(Self, self, fmt, options, writer);
}

pub fn isGray(self: Self) bool {
    return self.a == 0 and self.b == 0;
}

pub fn toGray(self: Self) u8 {
    return @intFromFloat(@round(self.l / 100 * 255));
}

pub fn toRgb(self: Self) Rgb {
    return conversions.labToRgb(self);
}

pub fn toRgba(self: Self, alpha: u8) Rgba {
    return self.toRgb().toRgba(alpha);
}

pub fn toHsl(self: Self) Hsl {
    return conversions.labToHsl(self);
}

pub fn toHsv(self: Self) Hsv {
    return self.toRgb().toHsv();
}

pub fn toXyz(self: Self) Xyz {
    return conversions.labToRgb(self).toXyz();
}

pub fn toLms(self: Self) Lms {
    return self.toXyz().toLms();
}

pub fn toOklab(self: Self) Oklab {
    return self.toLms().toOklab();
}

pub fn toXyb(self: Self) Xyb {
    return self.toLms().toXyb();
}

pub fn blend(self: *Self, color: Rgba) void {
    var rgb = self.toRgb();
    rgb.blend(color);
    self.* = rgb.toLab();
}
