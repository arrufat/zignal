//! Ycbcr (Y'CbCr) colorspace used in JPEG and video encoding.
//! Y is luma (brightness), Cb is blue-difference chroma, Cr is red-difference chroma.
//! Uses ITU-R BT.601 coefficients for conversion to/from RGB.

const std = @import("std");

const BlendMode = @import("blending.zig").BlendMode;
const conversions = @import("conversions.zig");
const formatting = @import("formatting.zig");
const Hsl = @import("Hsl.zig");
const Hsv = @import("Hsv.zig");
const Lab = @import("Lab.zig");
const Lch = @import("Lch.zig");
const Lms = @import("Lms.zig");
const Oklab = @import("Oklab.zig");
const Oklch = @import("Oklch.zig");
const Rgb = @import("Rgb.zig");
const Rgba = @import("Rgba.zig").Rgba;
const Xyb = @import("Xyb.zig");
const Xyz = @import("Xyz.zig");

/// Y component (luma/brightness) in range [0, 255]
y: f32,
/// Cb component (blue-difference chroma) in range [0, 255] (128 = neutral)
cb: f32,
/// Cr component (red-difference chroma) in range [0, 255] (128 = neutral)
cr: f32,

const Ycbcr = @This();

/// Common Ycbcr values
pub const black: Ycbcr = .{ .y = 0, .cb = 128, .cr = 128 };
pub const white: Ycbcr = .{ .y = 255, .cb = 128, .cr = 128 };

/// Formats the Ycbcr color for display. Use "color" format for ANSI color output.
/// Default formatting with ANSI color output
pub fn format(self: Ycbcr, writer: *std.Io.Writer) !void {
    return formatting.formatColor(Ycbcr, self, writer);
}

/// Converts Ycbcr to RGB using ITU-R BT.601 coefficients.
pub fn toRgb(self: Ycbcr) Rgb {
    return conversions.ycbcrToRgb(self);
}

/// Converts to RGBA with full opacity.
pub fn toRgba(self: Ycbcr, alpha: u8) Rgba {
    return self.toRgb().toRgba(alpha);
}

/// Converts to HSL via RGB.
pub fn toHsl(self: Ycbcr) Hsl {
    return self.toRgb().toHsl();
}

/// Converts to HSV via RGB.
pub fn toHsv(self: Ycbcr) Hsv {
    return self.toRgb().toHsv();
}

/// Converts to Lab via RGB.
pub fn toLab(self: Ycbcr) Lab {
    return self.toRgb().toLab();
}

/// Converts to LCh via RGB.
pub fn toLch(self: Ycbcr) Lch {
    return self.toRgb().toLch();
}

/// Converts to XYZ via RGB.
pub fn toXyz(self: Ycbcr) Xyz {
    return self.toRgb().toXyz();
}

/// Converts to LMS via RGB.
pub fn toLms(self: Ycbcr) Lms {
    return self.toRgb().toLms();
}

/// Converts to Oklab via RGB.
pub fn toOklab(self: Ycbcr) Oklab {
    return self.toRgb().toOklab();
}

/// Converts to Oklch via RGB.
pub fn toOklch(self: Ycbcr) Oklch {
    return self.toRgb().toOklch();
}

/// Converts to XYB via RGB.
pub fn toXyb(self: Ycbcr) Xyb {
    return self.toRgb().toXyb();
}

/// Converts to grayscale using the Y (luma) component.
pub fn toGray(self: Ycbcr) u8 {
    return @intFromFloat(@max(0, @min(255, @round(self.y))));
}

/// Alpha blends this color with another RGBA color using the specified blend mode and returns the result.
pub fn blend(self: Ycbcr, overlay: Rgba, mode: BlendMode) Ycbcr {
    return self.toRgb().blend(overlay, mode).toYcbcr();
}
