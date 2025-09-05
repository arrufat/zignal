//! Image filtering and effects

const std = @import("std");
const zignal = @import("zignal");
const Image = zignal.Image;
const Rgba = zignal.Rgba;
const Rgb = zignal.Rgb;
const MotionBlur = zignal.MotionBlur;

const py_utils = @import("../py_utils.zig");
const allocator = py_utils.allocator;
const c = py_utils.c;

const blending = @import("../blending.zig");
const PyImageMod = @import("../PyImage.zig");
const PyImage = PyImageMod.PyImage;

// Import the ImageObject type from parent
const ImageObject = @import("../image.zig").ImageObject;
const getImageType = @import("../image.zig").getImageType;

// Filtering functions
pub const image_box_blur_doc =
    \\Apply a box blur to the image.
    \\
    \\## Parameters
    \\- `radius` (int): Non-negative blur radius in pixels. `0` returns an unmodified copy.
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\soft = img.box_blur(2)
    \\identity = img.box_blur(0)  # no-op copy
    \\```
;

pub fn image_box_blur(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse arguments
    var radius_long: c_long = 0;
    var kwlist = [_:null]?[*:0]u8{ @constCast("radius"), null };
    const format = std.fmt.comptimePrint("l", .{});
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(&kwlist), &radius_long) == 0) {
        return null;
    }

    if (radius_long < 0) {
        c.PyErr_SetString(c.PyExc_ValueError, "radius must be >= 0");
        return null;
    }

    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(getImageType()), 0) orelse return null;
        const result = @as(*ImageObject, @ptrCast(py_obj));
        switch (pimg.data) {
            inline else => |img| {
                var out = @TypeOf(img).empty;
                img.boxBlur(allocator, &out, @intCast(radius_long)) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    return null;
                };
                const pnew = PyImage.createFrom(allocator, out, .owned) orelse {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                result.py_image = pnew;
            },
        }
        result.numpy_ref = null;
        result.parent_ref = null;
        return py_obj;
    }
    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

pub const image_gaussian_blur_doc =
    \\Apply Gaussian blur to the image.
    \\
    \\## Parameters
    \\- `sigma` (float): Standard deviation of the Gaussian kernel. Must be > 0.
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\blurred = img.gaussian_blur(2.0)
    \\blurred_soft = img.gaussian_blur(5.0)  # More blur
    \\```
;

pub fn image_gaussian_blur(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse arguments
    var sigma: f64 = 0;
    var kwlist = [_:null]?[*:0]u8{ @constCast("sigma"), null };
    const format = std.fmt.comptimePrint("d", .{});
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(&kwlist), &sigma) == 0) {
        return null;
    }

    // Validate sigma: must be finite and > 0
    if (!std.math.isFinite(sigma) or sigma <= 0) {
        c.PyErr_SetString(c.PyExc_ValueError, "sigma must be > 0");
        return null;
    }

    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(getImageType()), 0) orelse return null;
        const result = @as(*ImageObject, @ptrCast(py_obj));
        switch (pimg.data) {
            inline else => |img| {
                var out = @TypeOf(img).empty;
                img.gaussianBlur(allocator, @floatCast(sigma), &out) catch |err| {
                    c.Py_DECREF(py_obj);
                    if (err == error.InvalidSigma) {
                        c.PyErr_SetString(c.PyExc_ValueError, "Invalid sigma value");
                    } else {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    }
                    return null;
                };
                const pnew = PyImage.createFrom(allocator, out, .owned) orelse {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                result.py_image = pnew;
            },
        }
        result.numpy_ref = null;
        result.parent_ref = null;
        return py_obj;
    }
    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

pub const image_sharpen_doc =
    \\Sharpen the image using unsharp masking (2 * self - blur_box).
    \\
    \\## Parameters
    \\- `radius` (int): Non-negative blur radius used to compute the unsharp mask. `0` returns an unmodified copy.
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\crisp = img.sharpen(2)
    \\identity = img.sharpen(0)  # no-op copy
    \\```
;

pub fn image_sharpen(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse arguments
    var radius_long: c_long = 0;
    var kwlist = [_:null]?[*:0]u8{ @constCast("radius"), null };
    const format = std.fmt.comptimePrint("l", .{});
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(&kwlist), &radius_long) == 0) {
        return null;
    }

    if (radius_long < 0) {
        c.PyErr_SetString(c.PyExc_ValueError, "radius must be >= 0");
        return null;
    }

    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(getImageType()), 0) orelse return null;
        const result = @as(*ImageObject, @ptrCast(py_obj));
        switch (pimg.data) {
            inline else => |img| {
                var out = @TypeOf(img).empty;
                img.sharpen(allocator, &out, @intCast(radius_long)) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    return null;
                };
                const pnew = PyImage.createFrom(allocator, out, .owned) orelse {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                result.py_image = pnew;
            },
        }
        result.numpy_ref = null;
        result.parent_ref = null;
        return py_obj;
    }
    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

pub const image_motion_blur_doc =
    \\Apply motion blur effect to the image.
    \\
    \\Motion blur simulates camera or object movement during exposure.
    \\Three types of motion blur are supported:
    \\- `MotionBlur.linear()` - Linear motion blur
    \\- `MotionBlur.radial_zoom()` - Radial zoom blur
    \\- `MotionBlur.radial_spin()` - Radial spin blur
    \\
    \\## Examples
    \\```python
    \\from zignal import Image, MotionBlur
    \\import math
    \\
    \\img = Image.load("photo.png")
    \\
    \\# Linear motion blur examples
    \\horizontal_blur = img.motion_blur(MotionBlur.linear(angle=0, distance=30))  # Camera panning
    \\vertical_blur = img.motion_blur(MotionBlur.linear(angle=math.pi/2, distance=20))  # Camera shake
    \\diagonal_blur = img.motion_blur(MotionBlur.linear(angle=math.pi/4, distance=25))  # Diagonal motion
    \\
    \\# Radial zoom blur examples
    \\center_zoom = img.motion_blur(MotionBlur.radial_zoom(center=(0.5, 0.5), strength=0.7))  # Center zoom burst
    \\off_center_zoom = img.motion_blur(MotionBlur.radial_zoom(center=(0.33, 0.67), strength=0.5))  # Rule of thirds
    \\subtle_zoom = img.motion_blur(MotionBlur.radial_zoom(strength=0.3))  # Subtle effect with defaults
    \\
    \\# Radial spin blur examples
    \\center_spin = img.motion_blur(MotionBlur.radial_spin(center=(0.5, 0.5), strength=0.5))  # Center rotation
    \\swirl_effect = img.motion_blur(MotionBlur.radial_spin(center=(0.3, 0.3), strength=0.6))  # Off-center swirl
    \\strong_spin = img.motion_blur(MotionBlur.radial_spin(strength=0.8))  # Strong spin with defaults
    \\```
    \\
    \\## Notes
    \\- Linear blur preserves image dimensions
    \\- Radial effects use bilinear interpolation for smooth results
    \\- Strength values closer to 1.0 produce stronger blur effects
;

pub fn image_motion_blur(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));
    const motion_blur = @import("../motion_blur.zig");

    // Parse the single argument (config object)
    var config_obj: ?*c.PyObject = undefined;
    if (c.PyArg_ParseTuple(args, "O", &config_obj) == 0) {
        return null;
    }

    // Check that it's a MotionBlur object
    const type_obj = c.Py_TYPE(config_obj);
    const type_name = type_obj.*.tp_name;

    if (!std.mem.eql(u8, std.mem.span(type_name), "zignal.MotionBlur")) {
        c.PyErr_SetString(c.PyExc_TypeError, "config must be a MotionBlur object created with MotionBlur.linear(), MotionBlur.radial_zoom(), or MotionBlur.radial_spin()");
        return null;
    }

    // Cast to MotionBlurObject to access the blur_type discriminator
    const blur_obj = @as(*motion_blur.MotionBlurObject, @ptrCast(config_obj));

    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(getImageType()), 0) orelse return null;
        const result = @as(*ImageObject, @ptrCast(py_obj));

        switch (pimg.data) {
            inline else => |img| {
                var out = @TypeOf(img).empty;

                // Create the appropriate MotionBlur config based on the type
                const blur_config: MotionBlur = switch (blur_obj.blur_type) {
                    .linear => .{
                        .linear = .{
                            .angle = @floatCast(blur_obj.angle),
                            .distance = @intCast(blur_obj.distance),
                        },
                    },
                    .radial_zoom => .{
                        .radial_zoom = .{
                            .center_x = @floatCast(blur_obj.center_x),
                            .center_y = @floatCast(blur_obj.center_y),
                            .strength = @floatCast(blur_obj.strength),
                        },
                    },
                    .radial_spin => .{
                        .radial_spin = .{
                            .center_x = @floatCast(blur_obj.center_x),
                            .center_y = @floatCast(blur_obj.center_y),
                            .strength = @floatCast(blur_obj.strength),
                        },
                    },
                };

                img.motionBlur(allocator, blur_config, &out) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    return null;
                };

                const pnew = PyImage.createFrom(allocator, out, .owned) orelse {
                    out.deinit(allocator);
                    c.Py_DECREF(py_obj);
                    return null;
                };
                result.py_image = pnew;
            },
        }
        result.numpy_ref = null;
        result.parent_ref = null;
        return py_obj;
    }

    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

pub const image_sobel_doc =
    \\Apply Sobel edge detection and return the gradient magnitude.
    \\
    \\The result is a new grayscale image (`dtype=zignal.Grayscale`) where
    \\each pixel encodes the edge strength at that location.
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\edges = img.sobel()
    \\```
;

pub fn image_sobel(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(getImageType()), 0) orelse return null;
        const result = @as(*ImageObject, @ptrCast(py_obj));

        var out = Image(u8).empty;
        switch (pimg.data) {
            inline else => |img| {
                img.sobel(allocator, &out) catch {
                    c.Py_DECREF(py_obj);
                    c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    return null;
                };
            },
        }

        const pnew = PyImage.createFrom(allocator, out, .owned) orelse {
            out.deinit(allocator);
            c.Py_DECREF(py_obj);
            return null;
        };
        result.py_image = pnew;
        result.numpy_ref = null;
        result.parent_ref = null;
        return py_obj;
    }

    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

pub const image_shen_castan_doc =
    \\Apply Shen-Castan edge detection to the image.
    \\
    \\The Shen-Castan algorithm uses ISEF (Infinite Symmetric Exponential Filter)
    \\for edge detection with adaptive gradient computation and hysteresis thresholding.
    \\Returns a grayscale image where pixel values indicate edge strength.
    \\
    \\## Parameters
    \\- `smooth` (float, optional): ISEF smoothing factor (0 < smooth < 1). Higher values preserve more detail. Default: 0.9
    \\- `window_size` (int, optional): Odd window size for local gradient statistics (>= 3). Default: 7
    \\- `high_ratio` (float, optional): Percentile for high threshold selection (0 < high_ratio < 1). Default: 0.99
    \\- `low_rel` (float, optional): Low threshold as fraction of high threshold (0 < low_rel < 1). Default: 0.5
    \\- `hysteresis` (bool, optional): Enable hysteresis edge linking. Default: True
    \\- `use_nms` (bool, optional): Use non-maximum suppression for single-pixel edges. Default: False
    \\
    \\## Returns
    \\- `Image`: Grayscale edge map
    \\
    \\## Examples
    \\```python
    \\from zignal import Image
    \\
    \\img = Image.load("photo.jpg")
    \\
    \\# Use default settings
    \\edges = img.shen_castan()
    \\
    \\# Low-noise settings for clean images
    \\clean_edges = img.shen_castan(smooth=0.95, high_ratio=0.98)
    \\
    \\# High-noise settings for noisy images
    \\denoised_edges = img.shen_castan(smooth=0.7, window_size=11)
    \\
    \\# Single-pixel edges with NMS
    \\thin_edges = img.shen_castan(use_nms=True)
    \\```
;

pub fn image_shen_castan(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse arguments with defaults matching ShenCastan.zig
    var smooth: f64 = 0.9;
    var window_size: c_long = 7;
    var high_ratio: f64 = 0.99;
    var low_rel: f64 = 0.5;
    var hysteresis: c_int = 1; // True by default
    var use_nms: c_int = 0; // False by default

    var kwlist = [_:null]?[*:0]u8{
        @constCast("smooth"),
        @constCast("window_size"),
        @constCast("high_ratio"),
        @constCast("low_rel"),
        @constCast("hysteresis"),
        @constCast("use_nms"),
        null,
    };
    const format = std.fmt.comptimePrint("|dlddpp", .{});
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, format.ptr, @ptrCast(&kwlist), &smooth, &window_size, &high_ratio, &low_rel, &hysteresis, &use_nms) == 0) {
        return null;
    }

    // Validate parameters
    if (smooth <= 0 or smooth >= 1) {
        c.PyErr_SetString(c.PyExc_ValueError, "smooth must be between 0 and 1");
        return null;
    }
    if (window_size < 3) {
        c.PyErr_SetString(c.PyExc_ValueError, "window_size must be >= 3");
        return null;
    }
    if (@mod(window_size, 2) == 0) {
        c.PyErr_SetString(c.PyExc_ValueError, "window_size must be odd");
        return null;
    }
    if (high_ratio <= 0 or high_ratio >= 1) {
        c.PyErr_SetString(c.PyExc_ValueError, "high_ratio must be between 0 and 1");
        return null;
    }
    if (low_rel <= 0 or low_rel >= 1) {
        c.PyErr_SetString(c.PyExc_ValueError, "low_rel must be between 0 and 1");
        return null;
    }

    if (self.py_image) |pimg| {
        const py_obj = c.PyType_GenericAlloc(@ptrCast(getImageType()), 0) orelse return null;
        const result = @as(*ImageObject, @ptrCast(py_obj));

        var out = Image(u8).empty;

        // Create the simplified ShenCastan configuration
        const opts = zignal.ShenCastan{
            .smooth = @floatCast(smooth),
            .window_size = @intCast(window_size),
            .high_ratio = @floatCast(high_ratio),
            .low_rel = @floatCast(low_rel),
            .hysteresis = hysteresis != 0,
            .use_nms = use_nms != 0,
        };

        // Apply Shen-Castan edge detection
        switch (pimg.data) {
            inline else => |img| {
                img.shenCastan(allocator, opts, &out) catch |err| {
                    c.Py_DECREF(py_obj);
                    if (err == error.InvalidBParameter) {
                        c.PyErr_SetString(c.PyExc_ValueError, "Invalid smoothing parameter (must be between 0 and 1)");
                    } else if (err == error.WindowSizeMustBeOdd) {
                        c.PyErr_SetString(c.PyExc_ValueError, "Window size must be odd");
                    } else if (err == error.WindowSizeTooSmall) {
                        c.PyErr_SetString(c.PyExc_ValueError, "Window size must be >= 3");
                    } else if (err == error.InvalidThreshold) {
                        c.PyErr_SetString(c.PyExc_ValueError, "Invalid threshold values");
                    } else {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory");
                    }
                    return null;
                };
            },
        }

        const pnew = PyImage.createFrom(allocator, out, .owned) orelse {
            out.deinit(allocator);
            c.Py_DECREF(py_obj);
            return null;
        };
        result.py_image = pnew;
        result.numpy_ref = null;
        result.parent_ref = null;
        return py_obj;
    }

    c.PyErr_SetString(c.PyExc_ValueError, "Image not initialized");
    return null;
}

pub const image_blend_doc =
    \\Blend an overlay image onto this image using the specified blend mode.
    \\
    \\Modifies this image in-place. Both images must have the same dimensions.
    \\The overlay image must have an alpha channel for proper blending.
    \\
    \\## Parameters
    \\- `overlay` (Image): Image to blend onto this image
    \\- `mode` (Blending, optional): Blending mode (default: NORMAL)
    \\
    \\## Raises
    \\- `ValueError`: If images have different dimensions
    \\- `TypeError`: If overlay is not an Image object
    \\
    \\## Examples
    \\```python
    \\# Basic alpha blending
    \\base = Image(100, 100, (255, 0, 0))
    \\overlay = Image(100, 100, (0, 0, 255, 128))  # Semi-transparent blue
    \\base.blend(overlay)  # Default NORMAL mode
    \\
    \\# Using different blend modes
    \\base.blend(overlay, zignal.Blending.MULTIPLY)
    \\base.blend(overlay, zignal.Blending.SCREEN)
    \\base.blend(overlay, zignal.Blending.OVERLAY)
    \\```
;

pub fn image_blend(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = @as(*ImageObject, @ptrCast(self_obj.?));

    // Parse arguments: overlay image and optional blend mode
    var overlay_obj: ?*c.PyObject = null;
    var mode_obj: ?*c.PyObject = null;

    var kwlist = [_:null]?[*:0]u8{ @constCast("overlay"), @constCast("mode"), null };
    const fmt = std.fmt.comptimePrint("O|O", .{});
    if (c.PyArg_ParseTupleAndKeywords(args, kwds, fmt.ptr, @ptrCast(&kwlist), &overlay_obj, &mode_obj) == 0) {
        return null;
    }

    // Check if overlay is an Image instance
    if (c.PyObject_IsInstance(overlay_obj, @ptrCast(getImageType())) <= 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "overlay must be an Image object");
        return null;
    }

    const overlay = @as(*ImageObject, @ptrCast(overlay_obj.?));

    // Get blend mode (default to normal if not specified)
    var blend_mode = zignal.Blending.normal;
    if (mode_obj != null and mode_obj != c.Py_None()) {
        blend_mode = blending.convertToZigBlending(mode_obj.?) catch {
            return null; // Error already set by convertToZigBlending
        };
    }

    // Both images must be initialized
    if (self.py_image == null or overlay.py_image == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Both images must be initialized");
        return null;
    }

    const self_pimg = self.py_image.?;
    const overlay_pimg = overlay.py_image.?;

    // Check dimensions match
    const self_rows = self_pimg.rows();
    const self_cols = self_pimg.cols();
    const overlay_rows = overlay_pimg.rows();
    const overlay_cols = overlay_pimg.cols();

    if (self_rows != overlay_rows or self_cols != overlay_cols) {
        c.PyErr_SetString(c.PyExc_ValueError, "Images must have the same dimensions");
        return null;
    }

    // Overlay must be RGBA
    const overlay_img = switch (overlay_pimg.data) {
        .rgba => |img| img,
        else => {
            c.PyErr_SetString(c.PyExc_TypeError, "Overlay image must be RGBA type");
            return null;
        },
    };

    // Perform the blend operation based on base image type
    switch (self_pimg.data) {
        .grayscale => |base_img| {
            for (0..self_rows) |row| {
                for (0..self_cols) |col| {
                    const base_pixel = base_img.at(row, col).*;
                    const base_rgb: Rgb = .{ .r = base_pixel, .g = base_pixel, .b = base_pixel };
                    base_img.at(row, col).* = base_rgb.blend(overlay_img.at(row, col).*, blend_mode).toGray();
                }
            }
        },
        inline .rgb, .rgba => |*base_img| {
            for (0..self_rows) |row| {
                for (0..self_cols) |col| {
                    base_img.at(row, col).* = base_img.at(row, col).blend(overlay_img.at(row, col).*, blend_mode);
                }
            }
        },
    }

    // Return None (Python convention for in-place operations)
    c.Py_INCREF(c.Py_None());
    return c.Py_None();
}
