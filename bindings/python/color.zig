// This file now uses the color factory for clean, automated binding generation
// The old manual implementation has been replaced with the factory approach

const std = @import("std");
const zignal = @import("zignal");
const color_factory = @import("color_factory.zig");
const py_utils = @import("py_utils.zig");

pub const registerType = py_utils.registerType;

const c = @cImport({
    @cDefine("PY_SSIZE_T_CLEAN", {});
    @cInclude("Python.h");
});

// ============================================================================
// RGB TYPE USING COLOR FACTORY
// ============================================================================

// RGB validation function
fn validateRgbComponent(field_name: []const u8, value: anytype) bool {
    _ = field_name;
    const T = @TypeOf(value);

    return switch (@typeInfo(T)) {
        .int => |info| if (info.signedness == .unsigned)
            value <= 255
        else
            value >= 0 and value <= 255,
        else => false,
    };
}

// Create RGB binding using the factory - this replaces ~200 lines of manual code!
pub const RgbBinding = color_factory.createColorBinding("Rgb", zignal.Rgb, .{
    .validation_fn = validateRgbComponent,
    .validation_error = "RGB values must be in range 0-255",
    .doc = "RGB color in sRGB colorspace with components in range 0-255",
});

// Generate the static arrays
var rgb_getset = RgbBinding.generateGetters();
var rgb_methods = RgbBinding.generateMethods();

// Export the type object with factory-generated components
pub var RgbType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.Rgb",
    .tp_basicsize = @sizeOf(RgbBinding.PyObjectType),
    .tp_dealloc = @ptrCast(&RgbBinding.dealloc),
    .tp_repr = @ptrCast(&RgbBinding.repr),
    .tp_str = @ptrCast(&RgbBinding.repr),
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = "RGB color in sRGB colorspace with components in range 0-255",
    .tp_methods = @ptrCast(&rgb_methods),
    .tp_getset = @ptrCast(&rgb_getset),
    .tp_init = @ptrCast(&RgbBinding.init),
    .tp_new = @ptrCast(&RgbBinding.new),
};

// ============================================================================
// HSV TYPE USING COLOR FACTORY - DEBUGGING
// ============================================================================

// HSV validation function
fn validateHsvComponent(field_name: []const u8, value: anytype) bool {
    const T = @TypeOf(value);

    return switch (@typeInfo(T)) {
        .float => {
            if (std.mem.eql(u8, field_name, "h")) {
                return value >= 0.0 and value <= 360.0;
            } else if (std.mem.eql(u8, field_name, "s") or std.mem.eql(u8, field_name, "v")) {
                return value >= 0.0 and value <= 100.0;
            } else {
                return false;
            }
        },
        else => false,
    };
}

// Try to create HSV binding like RGB but use simpler approach
pub const HsvBinding = color_factory.createColorBinding("Hsv", zignal.Hsv, .{
    .validation_fn = validateHsvComponent,
    .validation_error = "HSV values must be in valid ranges (h: 0-360, s: 0-100, v: 0-100)",
    .doc = "HSV color",
});

// Generate the static arrays for HSV
var hsv_getset = HsvBinding.generateGetters();
var hsv_methods = HsvBinding.generateMethods();

// Export the HSV type object with factory-generated components
pub var HsvType = c.PyTypeObject{
    .ob_base = .{ .ob_base = .{}, .ob_size = 0 },
    .tp_name = "zignal.Hsv",
    .tp_basicsize = @sizeOf(HsvBinding.PyObjectType),
    .tp_dealloc = @ptrCast(&HsvBinding.dealloc),
    .tp_repr = @ptrCast(&HsvBinding.repr),
    .tp_str = @ptrCast(&HsvBinding.repr),
    .tp_flags = c.Py_TPFLAGS_DEFAULT,
    .tp_doc = "HSV color",
    .tp_methods = @ptrCast(&hsv_methods),
    .tp_getset = @ptrCast(&hsv_getset),
    .tp_init = @ptrCast(&HsvBinding.init),
    .tp_new = @ptrCast(&HsvBinding.new),
};

// ============================================================================
// FUTURE COLOR TYPES CAN BE ADDED HERE WITH SIMILAR SIMPLICITY
// ============================================================================

// Example of how easy it would be to add HSL:
// const HslBinding = color_factory.createColorBinding("Hsl", zignal.Hsl, .{
//     .validation_fn = validateHslComponent,
//     .validation_error = "HSL values must be in valid ranges",
//     .doc = "HSL color in Hue-Saturation-Lightness color space",
// });

// Example of how easy it would be to add Lab:
// const LabBinding = color_factory.createColorBinding("Lab", zignal.Lab, .{
//     .validation_fn = validateLabComponent,
//     .validation_error = "Lab values must be in valid ranges",
//     .doc = "Lab color in CIELAB color space",
// });
