// Centralized registry for all color type bindings
// This file defines which color types to expose to Python and their configurations

const std = @import("std");

const zignal = @import("zignal");

const Gray = zignal.Gray(u8);
const Rgb = zignal.Rgb(u8);
const Rgba = zignal.Rgba(u8);
const Hsl = zignal.Hsl(f64);
const Hsv = zignal.Hsv(f64);
const Lab = zignal.Lab(f64);
const Lch = zignal.Lch(f64);
const Lms = zignal.Lms(f64);
const Oklab = zignal.Oklab(f64);
const Oklch = zignal.Oklch(f64);
const Xyb = zignal.Xyb(f64);
const Xyz = zignal.Xyz(f64);
const Ycbcr = zignal.Ycbcr(u8);

/// Complete list of all color types available in the system
/// This serves as the single source of truth for auto-generation
pub const color_types = .{
    Gray,
    Rgb,
    Rgba,
    Hsl,
    Hsv,
    Lab,
    Lch,
    Lms,
    Oklab,
    Oklch,
    Xyb,
    Xyz,
    Ycbcr,
};

/// Generic color component validation using type introspection
/// This function determines validation rules based on the actual field types and semantics
pub fn validateColorComponent(comptime ColorType: type, field_name: []const u8, value: anytype) bool {
    // Apply validation rules grouped by color type families
    return switch (ColorType) {
        // RGB family: integer components 0-255
        Gray => std.mem.eql(u8, field_name, "y") and value >= 0 and value <= 255,
        Rgb, Rgba => {
            if (std.mem.eql(u8, field_name, "r") or
                std.mem.eql(u8, field_name, "g") or
                std.mem.eql(u8, field_name, "b") or
                std.mem.eql(u8, field_name, "a"))
            {
                return value >= 0 and value <= 255;
            }
            return false;
        },

        // HSV/HSL family: same validation rules (h: 0-360, s/v/l: 0-100)
        Hsv, Hsl => {
            if (std.mem.eql(u8, field_name, "h")) {
                return value >= 0.0 and value <= 360.0;
            } else if (std.mem.eql(u8, field_name, "s") or
                std.mem.eql(u8, field_name, "v") or
                std.mem.eql(u8, field_name, "l"))
            {
                return value >= 0.0 and value <= 100.0;
            }
            return false;
        },

        // Lab: L: 0-100, a/b: -128 to 127
        Lab => {
            if (std.mem.eql(u8, field_name, "l")) {
                return value >= 0.0 and value <= 100.0;
            } else if (std.mem.eql(u8, field_name, "a") or std.mem.eql(u8, field_name, "b")) {
                return value >= -128.0 and value <= 127.0;
            }
            return false;
        },

        // Oklab: L: 0-1, a/b: -0.5 to 0.5
        Oklab => {
            if (std.mem.eql(u8, field_name, "l")) {
                return value >= 0.0 and value <= 1.0;
            } else if (std.mem.eql(u8, field_name, "a") or std.mem.eql(u8, field_name, "b")) {
                return value >= -0.5 and value <= 0.5;
            }
            return false;
        },

        // Oklch: L: 0-1, c: 0-0.5, h: 0-360
        Oklch => {
            if (std.mem.eql(u8, field_name, "l")) {
                return value >= 0.0 and value <= 1.0;
            } else if (std.mem.eql(u8, field_name, "c")) {
                return value >= 0.0 and value <= 0.5;
            } else if (std.mem.eql(u8, field_name, "h")) {
                return value >= 0.0 and value <= 360.0;
            }
            return false;
        },

        // Lch: L: 0-100, c: >=0, h: 0-360
        Lch => {
            if (std.mem.eql(u8, field_name, "l")) {
                return value >= 0.0 and value <= 100.0;
            } else if (std.mem.eql(u8, field_name, "c")) {
                return value >= 0.0;
            } else if (std.mem.eql(u8, field_name, "h")) {
                return value >= 0.0 and value <= 360.0;
            }
            return false;
        },

        // XYZ: 0-150 (can exceed 100)
        Xyz => {
            if (std.mem.eql(u8, field_name, "x") or
                std.mem.eql(u8, field_name, "y") or
                std.mem.eql(u8, field_name, "z"))
            {
                return value >= 0.0 and value <= 150.0;
            }
            return false;
        },

        // YCbCr: 0-255
        Ycbcr => {
            if (std.mem.eql(u8, field_name, "y") or
                std.mem.eql(u8, field_name, "cb") or
                std.mem.eql(u8, field_name, "cr"))
            {
                return value >= 0.0 and value <= 255.0;
            }
            return false;
        },

        // LMS: L/M/S cone responses
        Lms => {
            if (std.mem.eql(u8, field_name, "l") or
                std.mem.eql(u8, field_name, "m") or
                std.mem.eql(u8, field_name, "s"))
            {
                return value >= 0.0 and value <= 1000.0; // Non-negative cone responses
            }
            return false;
        },

        // XYB: JPEG XL color space
        Xyb => {
            if (std.mem.eql(u8, field_name, "x") or
                std.mem.eql(u8, field_name, "y") or
                std.mem.eql(u8, field_name, "b"))
            {
                return value >= -1000.0 and value <= 1000.0;
            }
            return false;
        },

        else => @compileError("Missing validation for color type '" ++ @typeName(ColorType) ++ "'. "),
    };
}

/// Get the validation error message for a specific color type
pub fn getValidationErrorMessage(comptime ColorType: type) []const u8 {
    // Return appropriate error message based on color type
    return switch (ColorType) {
        Gray => "Gray values must be in range 0-255",
        Rgb, Rgba => "RGB values must be in range 0-255",
        Hsv => "HSV values must be in valid ranges (h: 0-360, s: 0-100, v: 0-100)",
        Hsl => "HSL values must be in valid ranges (h: 0-360, s: 0-100, l: 0-100)",
        Lab => "Lab values must be in valid ranges (L: 0-100, a/b: -128 to 127)",
        Xyz => "XYZ values must be in range 0-150",
        Oklab => "Oklab values must be in valid ranges (l: 0-1, a/b: -0.5 to 0.5)",
        Oklch => "Oklch values must be in valid ranges (l: 0-1, c: 0-0.5, h: 0-360)",
        Lch => "Lch values must be in valid ranges (l: 0-100, c: >=0, h: 0-360)",
        Lms => "LMS values must be in range 0-1000",
        Xyb => "XYB values must be in range -1000 to 1000",
        Ycbcr => "YCbCr values must be in range 0-255",
        else => @compileError("Missing validation error message for color type '" ++ @typeName(ColorType) ++ "'. "),
    };
}

/// Get the documentation string for a specific color type
pub fn getDocumentationString(comptime ColorType: type) []const u8 {
    // Return appropriate documentation based on color type
    return switch (ColorType) {
        Gray => "Gray color with intensity in range 0-255",
        Rgb => "RGB color in sRGB colorspace with components in range 0-255",
        Rgba => "RGBA color with alpha channel, components in range 0-255",
        Hsv => "HSV (Hue-Saturation-Value) color representation",
        Hsl => "HSL (Hue-Saturation-Lightness) color representation",
        Lab => "CIELAB color space representation",
        Xyz => "CIE 1931 XYZ color space representation",
        Oklab => "Oklab perceptual color space representation",
        Oklch => "Oklch perceptual color space in cylindrical coordinates",
        Lch => "CIE LCH color space representation (cylindrical Lab)",
        Lms => "LMS color space representing Long, Medium, Short wavelength cone responses",
        Xyb => "XYB color space used in JPEG XL image compression",
        Ycbcr => "YCbCr color space used in JPEG and video encoding",
        else => @compileError("Missing documentation for color type '" ++ @typeName(ColorType) ++ "'. "),
    };
}
