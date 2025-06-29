const std = @import("std");

const conversions = @import("conversions.zig");
const formatting = @import("formatting.zig");
const Hsl = @import("Hsl.zig");
const Hsv = @import("Hsv.zig");
const Lab = @import("Lab.zig");
const Lms = @import("Lms.zig");
const Oklab = @import("Oklab.zig");
const Rgb = @import("Rgb.zig");
const Xyb = @import("Xyb.zig");
const Xyz = @import("Xyz.zig");

/// A color in the [sRGB](https://en.wikipedia.org/wiki/SRGB) colorspace with an alpha channel.
/// Each component (r, g, b, a) is an unsigned 8-bit integer (0-255).
pub const Rgba = packed struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub const black: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const white: Rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const transparent: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    /// Formats the RGBA color for display. Use "color" format for ANSI color output.
    pub fn format(self: Rgba, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        return formatting.formatColor(Rgba, self, fmt, options, writer);
    }

    /// Creates an RGBA color from a grayscale value with specified alpha.
    pub fn fromGray(gray: u8, alpha: u8) Rgba {
        return .{ .r = gray, .g = gray, .b = gray, .a = alpha };
    }

    /// Creates RGBA from 32-bit hexadecimal value (0xRRGGBBAA format).
    pub fn fromHex(hex_code: u32) Rgba {
        return @bitCast(std.mem.nativeToBig(u32, hex_code));
    }

    /// Calculates the perceptual luminance using ITU-R BT.709 coefficients (ignores alpha).
    pub fn luma(self: Rgba) f64 {
        return conversions.rgbLuma(self.r, self.g, self.b);
    }

    /// Returns true if all RGB components are equal (grayscale, ignores alpha).
    pub fn isGray(self: Rgba) bool {
        return self.r == self.g and self.g == self.b;
    }

    /// Converts to grayscale using perceptual luminance calculation (ignores alpha).
    pub fn toGray(self: Rgba) u8 {
        return @intFromFloat(self.luma() * 255);
    }

    /// Converts RGBA to 32-bit hexadecimal representation (0xRRGGBBAA format).
    pub fn toHex(self: Rgba) u32 {
        return std.mem.bigToNative(u32, @bitCast(self));
    }

    /// Converts RGBA to RGB by discarding the alpha channel.
    pub fn toRgb(self: Rgba) Rgb {
        return .{ .r = self.r, .g = self.g, .b = self.b };
    }

    /// Converts RGBA to HSL by first converting to RGB.
    pub fn toHsl(self: Rgba) Hsl {
        return self.toRgb().toHsl();
    }

    /// Converts RGBA to HSV by first converting to RGB.
    pub fn toHsv(self: Rgba) Hsv {
        return self.toRgb().toHsv();
    }

    /// Converts RGBA to CIELAB by first converting to RGB.
    pub fn toLab(self: Rgba) Lab {
        return self.toRgb().toLab();
    }

    /// Converts RGBA to CIE XYZ by first converting to RGB.
    pub fn toXyz(self: Rgba) Xyz {
        return self.toRgb().toXyz();
    }

    /// Converts RGBA to LMS cone response by first converting to RGB.
    pub fn toLms(self: Rgba) Lms {
        return self.toRgb().toLms();
    }

    /// Converts RGBA to Oklab by first converting to RGB.
    pub fn toOklab(self: Rgba) Oklab {
        return self.toRgb().toOklab();
    }

    /// Converts RGBA to XYB by first converting to RGB.
    pub fn toXyb(self: Rgba) Xyb {
        return self.toRgb().toXyb();
    }

    /// Returns a new RGBA color with the alpha channel multiplied by the given factor.
    /// Useful for modulating transparency in drawing operations.
    pub fn fade(self: Rgba, alpha: f32) Rgba {
        const new_alpha = @as(f32, @floatFromInt(self.a)) * std.math.clamp(alpha, 0.0, 1.0);
        return .{
            .r = self.r,
            .g = self.g,
            .b = self.b,
            .a = @intFromFloat(new_alpha),
        };
    }

    /// Alpha blends the given RGBA color onto this RGBA color in-place.
    pub fn blend(self: *Rgba, color: Rgba) void {
        if (color.a == 0) return;

        const a = @as(f32, @floatFromInt(color.a)) / 255;
        self.r = @intFromFloat(std.math.lerp(@as(f32, @floatFromInt(self.r)), @as(f32, @floatFromInt(color.r)), a));
        self.g = @intFromFloat(std.math.lerp(@as(f32, @floatFromInt(self.g)), @as(f32, @floatFromInt(color.g)), a));
        self.b = @intFromFloat(std.math.lerp(@as(f32, @floatFromInt(self.b)), @as(f32, @floatFromInt(color.b)), a));
    }
};
