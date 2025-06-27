//! A color in the [LMS color space](https://en.wikipedia.org/wiki/LMS_color_space).
//! Represents the response of the three types of cones (Long, Medium, Short wavelength) in the human eye.
//! Values are typically positive and represent the stimulus for each cone type.

const std = @import("std");

const conversions = @import("conversions.zig");
const formatting = @import("formatting.zig");

l: f64,
m: f64,
s: f64,

pub const black: @This() = .{ .l = 0, .m = 0, .s = 0 };

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

pub fn toRgb(self: Self) @import("Rgb.zig") {
    return conversions.lmsToRgb(self);
}

pub fn toRgba(self: Self, alpha: u8) @import("Rgba.zig") {
    return self.toRgb().toRgba(alpha);
}

pub fn toHsl(self: Self) @import("Hsl.zig") {
    return conversions.lmsToHsl(self);
}

pub fn toHsv(self: Self) @import("Hsv.zig") {
    return conversions.lmsToHsv(self);
}

pub fn toXyz(self: Self) @import("Xyz.zig") {
    return conversions.lmsToXyz(self);
}

pub fn toLab(self: Self) @import("Lab.zig") {
    return conversions.lmsToLab(self);
}

pub fn toOklab(self: Self) @import("Oklab.zig") {
    return conversions.lmsToOklab(self);
}

pub fn toXyb(self: Self) @import("Xyb.zig") {
    return conversions.lmsToXyb(self);
}

pub fn blend(self: *Self, color: @import("Rgba.zig")) void {
    var rgb = self.toRgb();
    rgb.blend(color);
    self.* = rgb.toLms();
}
