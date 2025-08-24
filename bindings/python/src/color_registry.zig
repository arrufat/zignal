// Centralized registry for all color type bindings
// This file defines which color types to expose to Python and their configurations

const std = @import("std");

const zignal = @import("zignal");

/// Complete list of all color types available in the system
/// This serves as the single source of truth for auto-generation
pub const color_types = .{
    zignal.Rgb,
    zignal.Rgba,
    zignal.Hsl,
    zignal.Hsv,
    zignal.Lab,
    zignal.Lch,
    zignal.Lms,
    zignal.Oklab,
    zignal.Oklch,
    zignal.Xyb,
    zignal.Xyz,
    zignal.Ycbcr,
};

/// Generic color component validation using type introspection
/// This function determines validation rules based on the actual field types and semantics
pub fn validateColorComponent(comptime ColorType: type, field_name: []const u8, value: anytype) bool {
    // Apply validation rules grouped by color type families
    return switch (ColorType) {
        // RGB family: integer components 0-255
        zignal.Rgb, zignal.Rgba => {
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
        zignal.Hsv, zignal.Hsl => {
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
        zignal.Lab => {
            if (std.mem.eql(u8, field_name, "l")) {
                return value >= 0.0 and value <= 100.0;
            } else if (std.mem.eql(u8, field_name, "a") or std.mem.eql(u8, field_name, "b")) {
                return value >= -128.0 and value <= 127.0;
            }
            return false;
        },

        // Oklab: L: 0-1, a/b: -0.5 to 0.5
        zignal.Oklab => {
            if (std.mem.eql(u8, field_name, "l")) {
                return value >= 0.0 and value <= 1.0;
            } else if (std.mem.eql(u8, field_name, "a") or std.mem.eql(u8, field_name, "b")) {
                return value >= -0.5 and value <= 0.5;
            }
            return false;
        },

        // Oklch: L: 0-1, c: 0-0.5, h: 0-360
        zignal.Oklch => {
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
        zignal.Lch => {
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
        zignal.Xyz => {
            if (std.mem.eql(u8, field_name, "x") or
                std.mem.eql(u8, field_name, "y") or
                std.mem.eql(u8, field_name, "z"))
            {
                return value >= 0.0 and value <= 150.0;
            }
            return false;
        },

        // YCbCr: 0-255
        zignal.Ycbcr => {
            if (std.mem.eql(u8, field_name, "y") or
                std.mem.eql(u8, field_name, "cb") or
                std.mem.eql(u8, field_name, "cr"))
            {
                return value >= 0.0 and value <= 255.0;
            }
            return false;
        },

        // LMS: L/M/S cone responses
        zignal.Lms => {
            if (std.mem.eql(u8, field_name, "l") or
                std.mem.eql(u8, field_name, "m") or
                std.mem.eql(u8, field_name, "s"))
            {
                return value >= 0.0 and value <= 1000.0; // Non-negative cone responses
            }
            return false;
        },

        // XYB: JPEG XL color space
        zignal.Xyb => {
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
        zignal.Rgb, zignal.Rgba => "RGB values must be in range 0-255",
        zignal.Hsv => "HSV values must be in valid ranges (h: 0-360, s: 0-100, v: 0-100)",
        zignal.Hsl => "HSL values must be in valid ranges (h: 0-360, s: 0-100, l: 0-100)",
        zignal.Lab => "Lab values must be in valid ranges (L: 0-100, a/b: -128 to 127)",
        zignal.Xyz => "XYZ values must be in range 0-150",
        zignal.Oklab => "Oklab values must be in valid ranges (l: 0-1, a/b: -0.5 to 0.5)",
        zignal.Oklch => "Oklch values must be in valid ranges (l: 0-1, c: 0-0.5, h: 0-360)",
        zignal.Lch => "Lch values must be in valid ranges (l: 0-100, c: >=0, h: 0-360)",
        zignal.Lms => "LMS values must be in range 0-1000",
        zignal.Xyb => "XYB values must be in range -1000 to 1000",
        zignal.Ycbcr => "YCbCr values must be in range 0-255",
        else => @compileError("Missing validation error message for color type '" ++ @typeName(ColorType) ++ "'. "),
    };
}

/// Get the documentation string for a specific color type
pub fn getDocumentationString(comptime ColorType: type) []const u8 {
    // Return appropriate documentation based on color type
    return switch (ColorType) {
        zignal.Rgb => "RGB color in sRGB colorspace with components in range 0-255",
        zignal.Rgba => "RGBA color with alpha channel, components in range 0-255",
        zignal.Hsv => "HSV (Hue-Saturation-Value) color representation",
        zignal.Hsl => "HSL (Hue-Saturation-Lightness) color representation",
        zignal.Lab => "CIELAB color space representation",
        zignal.Xyz => "CIE 1931 XYZ color space representation",
        zignal.Oklab => "Oklab perceptual color space representation",
        zignal.Oklch => "Oklch perceptual color space in cylindrical coordinates",
        zignal.Lch => "CIE LCH color space representation (cylindrical Lab)",
        zignal.Lms => "LMS color space representing Long, Medium, Short wavelength cone responses",
        zignal.Xyb => "XYB color space used in JPEG XL image compression",
        zignal.Ycbcr => "YCbCr color space used in JPEG and video encoding",
        else => @compileError("Missing documentation for color type '" ++ @typeName(ColorType) ++ "'. "),
    };
}
