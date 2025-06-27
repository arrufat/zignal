//! A color in the [LMS color space](https://en.wikipedia.org/wiki/LMS_color_space).
//! Represents the response of the three types of cones (Long, Medium, Short wavelength) in the human eye.
//! Values are typically positive and represent the stimulus for each cone type.

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

pub fn toRgb(self: Self) Rgb {
    return conversions.lmsToRgb(self);
}

pub fn toRgba(self: Self, alpha: u8) Rgba {
    return self.toRgb().toRgba(alpha);
}

pub fn toHsl(self: Self) Hsl {
    return conversions.lmsToHsl(self);
}

pub fn toHsv(self: Self) Hsv {
    return conversions.lmsToHsv(self);
}

pub fn toXyz(self: Self) Xyz {
    return conversions.lmsToXyz(self);
}

pub fn toLab(self: Self) Lab {
    return conversions.lmsToLab(self);
}

pub fn toOklab(self: Self) Oklab {
    return conversions.lmsToOklab(self);
}

pub fn toXyb(self: Self) Xyb {
    return conversions.lmsToXyb(self);
}

pub fn blend(self: *Self, color: Rgba) void {
    var rgb = self.toRgb();
    rgb.blend(color);
    self.* = rgb.toLms();
}
