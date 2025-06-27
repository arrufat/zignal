//! A color in the [sRGB](https://en.wikipedia.org/wiki/SRGB) colorspace, with all components
//! within the range 0-255.

const std = @import("std");

const conversions = @import("conversions.zig");
const formatting = @import("formatting.zig");

// Import color types
const Rgba = @import("Rgba.zig").Rgba;
const Hsl = @import("Hsl.zig");
const Hsv = @import("Hsv.zig");
const Lab = @import("Lab.zig");
const Xyz = @import("Xyz.zig");
const Lms = @import("Lms.zig");
const Oklab = @import("Oklab.zig");
const Xyb = @import("Xyb.zig");

r: u8,
g: u8,
b: u8,

pub const black: @This() = .{ .r = 0, .g = 0, .b = 0 };
pub const white: @This() = .{ .r = 255, .g = 255, .b = 255 };
pub const red: @This() = .{ .r = 255, .g = 0, .b = 0 };
pub const green: @This() = .{ .r = 0, .g = 255, .b = 0 };
pub const blue: @This() = .{ .r = 0, .g = 0, .b = 255 };

const Self = @This();

pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    return formatting.formatColor(Self, self, fmt, options, writer);
}

pub fn fromGray(gray: u8) Self {
    return .{ .r = gray, .g = gray, .b = gray };
}

pub fn fromHex(hex_code: u24) Self {
    return .{
        .r = @intCast((hex_code >> (8 * 2)) & 0x0000ff),
        .g = @intCast((hex_code >> (8 * 1)) & 0x0000ff),
        .b = @intCast((hex_code >> (8 * 0)) & 0x0000ff),
    };
}

pub fn luma(self: Self) f64 {
    const r = @as(f64, @floatFromInt(self.r)) / 255;
    const g = @as(f64, @floatFromInt(self.g)) / 255;
    const b = @as(f64, @floatFromInt(self.b)) / 255;
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

pub fn isGray(self: Self) bool {
    return self.r == self.g and self.g == self.b;
}

pub fn toGray(self: Self) u8 {
    return @intFromFloat(self.luma() * 255);
}

pub fn toHex(self: Self) u24 {
    return (@as(u24, self.r) << 16) | (@as(u24, self.g) << 8) | @as(u24, self.b);
}

pub fn toRgba(self: Self, alpha: u8) Rgba {
    return .{ .r = self.r, .g = self.g, .b = self.b, .a = alpha };
}

pub fn toHsl(self: Self) Hsl {
    return conversions.rgbToHsl(self);
}

pub fn toHsv(self: Self) Hsv {
    return conversions.rgbToHsv(self);
}

pub fn toXyz(self: Self) Xyz {
    return conversions.rgbToXyz(self);
}

pub fn toLab(self: Self) Lab {
    return conversions.rgbToLab(self);
}

pub fn toLms(self: Self) Lms {
    return conversions.xyzToLms(self.toXyz());
}

pub fn toOklab(self: Self) Oklab {
    return conversions.lmsToOklab(self.toLms());
}

pub fn toXyb(self: Self) Xyb {
    return conversions.lmsToXyb(self.toLms());
}

pub fn blend(self: *Self, color: Rgba) void {
    if (color.a == 0) return;

    const a = @as(f32, @floatFromInt(color.a)) / 255;
    self.r = @intFromFloat(std.math.lerp(@as(f32, @floatFromInt(self.r)), @as(f32, @floatFromInt(color.r)), a));
    self.g = @intFromFloat(std.math.lerp(@as(f32, @floatFromInt(self.g)), @as(f32, @floatFromInt(color.g)), a));
    self.b = @intFromFloat(std.math.lerp(@as(f32, @floatFromInt(self.b)), @as(f32, @floatFromInt(color.b)), a));
}
