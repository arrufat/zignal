//! A color in the [CIELCh color space](https://en.wikipedia.org/wiki/CIELAB_color_space#Cylindrical_model).
//! LCh is the cylindrical representation of the CIELAB color space.
//! - l: Lightness (0 for black to 100 for white).
//! - c: Chroma (chromatic intensity) (0 for achromatic, no upper bound).
//! - h: Hue angle in degrees (0-360).

const std = @import("std");

const BlendMode = @import("blending.zig").BlendMode;
const conversions = @import("conversions.zig");
const formatting = @import("formatting.zig");
const Hsl = @import("Hsl.zig");
const Hsv = @import("Hsv.zig");
const Lab = @import("Lab.zig");
const Lms = @import("Lms.zig");
const Oklab = @import("Oklab.zig");
const Oklch = @import("Oklch.zig");
const Rgb = @import("Rgb.zig");
const Rgba = @import("Rgba.zig").Rgba;
const Xyb = @import("Xyb.zig");
const Xyz = @import("Xyz.zig");
const Ycbcr = @import("Ycbcr.zig");

l: f64,
c: f64,
h: f64,

const Lch = @This();

pub const black: Lch = .{ .l = 0, .c = 0, .h = 0 };
pub const white: Lch = .{ .l = 100, .c = 0, .h = 0 };

/// Default formatting with ANSI color output
pub fn format(self: Lch, writer: *std.Io.Writer) !void {
    return formatting.formatColor(Lch, self, writer);
}

/// Returns true if chroma is 0 (neutral gray).
pub fn isGray(self: Lch) bool {
    return self.c == 0;
}

/// Converts to grayscale using the L* (lightness) component.
pub fn toGray(self: Lch) u8 {
    return @intFromFloat(@round(@max(0, @min(100, self.l)) / 100 * 255));
}

/// Converts LCh to Lab color space.
pub fn toLab(self: Lch) Lab {
    return conversions.lchToLab(self);
}

/// Converts LCh to RGB color space.
pub fn toRgb(self: Lch) Rgb {
    return conversions.lchToRgb(self);
}

/// Converts LCh to RGBA by first converting to RGB and adding alpha.
pub fn toRgba(self: Lch, alpha: u8) Rgba {
    return self.toRgb().toRgba(alpha);
}

/// Converts LCh to HSL color space via Lab intermediate conversion.
pub fn toHsl(self: Lch) Hsl {
    return conversions.lchToHsl(self);
}

/// Converts LCh to HSV color space via RGB intermediate conversion.
pub fn toHsv(self: Lch) Hsv {
    return conversions.lchToHsv(self);
}

/// Converts LCh to CIE XYZ color space via Lab intermediate conversion.
pub fn toXyz(self: Lch) Xyz {
    return self.toLab().toXyz();
}

/// Converts LCh to LMS cone response via XYZ intermediate conversion.
pub fn toLms(self: Lch) Lms {
    return self.toXyz().toLms();
}

/// Converts LCh to Oklab via LMS intermediate conversion.
pub fn toOklab(self: Lch) Oklab {
    return self.toLms().toOklab();
}

/// Converts LCh to Oklch via Oklab intermediate conversion.
pub fn toOklch(self: Lch) Oklch {
    return self.toOklab().toOklch();
}

/// Converts LCh to XYB via LMS intermediate conversion.
pub fn toXyb(self: Lch) Xyb {
    return self.toLms().toXyb();
}

/// Converts LCh to YCbCr via RGB intermediate conversion.
pub fn toYcbcr(self: Lch) Ycbcr {
    return self.toRgb().toYcbcr();
}

/// Alpha blending: blends the given RGBA color onto this LCh color and returns the result.
pub fn blend(self: Lch, overlay: Rgba, mode: BlendMode) Lch {
    return self.toRgb().blend(overlay, mode).toLch();
}
