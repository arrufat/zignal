//! A color in the [sRGB](https://en.wikipedia.org/wiki/SRGB) colorspace, with all components
//! within the range 0-255.

const std = @import("std");

const blendColors = @import("blending.zig").blendColors;
const Blending = @import("blending.zig").Blending;
const conversions = @import("conversions.zig");
const formatting = @import("formatting.zig");
const Hsl = @import("Hsl.zig");
const Hsv = @import("Hsv.zig");
const Lab = @import("Lab.zig");
const Lch = @import("Lch.zig");
const Lms = @import("Lms.zig");
const Oklab = @import("Oklab.zig");
const Oklch = @import("Oklch.zig");
const Rgba = @import("Rgba.zig").Rgba;
const Xyb = @import("Xyb.zig");
const Xyz = @import("Xyz.zig");
const Ycbcr = @import("Ycbcr.zig");

r: u8,
g: u8,
b: u8,

const Rgb = @This();

pub const black: Rgb = .{ .r = 0, .g = 0, .b = 0 };
pub const white: Rgb = .{ .r = 255, .g = 255, .b = 255 };
pub const red: Rgb = .{ .r = 255, .g = 0, .b = 0 };
pub const green: Rgb = .{ .r = 0, .g = 255, .b = 0 };
pub const blue: Rgb = .{ .r = 0, .g = 0, .b = 255 };

/// Default formatting with ANSI color output
pub fn format(self: Rgb, writer: *std.Io.Writer) !void {
    return formatting.formatColor(Rgb, self, writer);
}

/// Creates an RGB color from a grayscale value (gray applied to all channels).
pub fn fromGray(gray: u8) Rgb {
    return .{ .r = gray, .g = gray, .b = gray };
}

/// Creates RGB from 24-bit hexadecimal value (0xRRGGBB format).
pub fn fromHex(hex_code: u24) Rgb {
    return .{
        .r = @intCast((hex_code >> (8 * 2)) & 0x0000ff),
        .g = @intCast((hex_code >> (8 * 1)) & 0x0000ff),
        .b = @intCast((hex_code >> (8 * 0)) & 0x0000ff),
    };
}

/// Calculates the perceptual luminance using ITU-R BT.709 coefficients.
pub fn luma(self: Rgb) f64 {
    return conversions.rgbLuma(self.r, self.g, self.b);
}

/// Returns true if all RGB components are equal (grayscale).
pub fn isGray(self: Rgb) bool {
    return self.r == self.g and self.g == self.b;
}

/// Converts to grayscale using perceptual luminance calculation.
pub fn toGray(self: Rgb) u8 {
    return @intFromFloat(self.luma() * 255);
}

/// Converts RGB to 24-bit hexadecimal representation (0xRRGGBB format).
pub fn toHex(self: Rgb) u24 {
    return (@as(u24, self.r) << 16) | (@as(u24, self.g) << 8) | @as(u24, self.b);
}

/// Converts RGB to RGBA by adding the specified alpha channel value.
pub fn toRgba(self: Rgb, alpha: u8) Rgba {
    return .{ .r = self.r, .g = self.g, .b = self.b, .a = alpha };
}

/// Converts RGB to HSL (Hue, Saturation, Lightness) color space.
pub fn toHsl(self: Rgb) Hsl {
    return conversions.rgbToHsl(self);
}

/// Converts RGB to HSV (Hue, Saturation, Value) color space.
pub fn toHsv(self: Rgb) Hsv {
    return conversions.rgbToHsv(self);
}

/// Converts RGB to CIE 1931 XYZ color space using D65 illuminant.
pub fn toXyz(self: Rgb) Xyz {
    return conversions.rgbToXyz(self);
}

/// Converts RGB to CIELAB color space via XYZ intermediate conversion.
pub fn toLab(self: Rgb) Lab {
    return conversions.rgbToLab(self);
}

/// Converts RGB to LCh color space via Lab intermediate conversion.
pub fn toLch(self: Rgb) Lch {
    return self.toLab().toLch();
}

/// Converts RGB to LMS (Long, Medium, Short) cone response space.
pub fn toLms(self: Rgb) Lms {
    return conversions.xyzToLms(self.toXyz());
}

/// Converts RGB to Oklab color space for improved perceptual uniformity.
pub fn toOklab(self: Rgb) Oklab {
    return conversions.lmsToOklab(self.toLms());
}

/// Converts RGB to Oklch color space via Oklab intermediate conversion.
pub fn toOklch(self: Rgb) Oklch {
    return conversions.oklabToOklch(self.toOklab());
}

/// Converts RGB to XYB color space via LMS intermediate conversion.
pub fn toXyb(self: Rgb) Xyb {
    return conversions.lmsToXyb(self.toLms());
}

/// Converts RGB to YCbCr color space using ITU-R BT.601 coefficients.
pub fn toYcbcr(self: Rgb) Ycbcr {
    return conversions.rgbToYcbcr(self);
}

/// Alpha blends the given RGBA color onto this RGB color using the specified blend mode.
/// Returns a new blended color.
pub fn blend(self: Rgb, overlay: Rgba, mode: Blending) Rgb {
    const blended = blendColors(self.toRgba(255), overlay, mode);
    return .{ .r = blended.r, .g = blended.g, .b = blended.b };
}
