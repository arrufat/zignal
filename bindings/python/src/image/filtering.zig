//! Image filtering and effects

const std = @import("std");

const zignal = @import("zignal");
const Image = zignal.Image;
const Rgb = zignal.Rgb(u8);
const Gray = zignal.Gray(u8);
const MotionBlur = zignal.MotionBlur;

const moveImageToPython = @import("../image.zig").moveImageToPython;
const ImageObject = @import("../image.zig").ImageObject;
const getImageType = @import("../image.zig").getImageType;
const enum_utils = @import("../enum_utils.zig");
const py_utils = @import("../py_utils.zig");
const allocator = py_utils.allocator;
const c = py_utils.c;

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
    const self = py_utils.safeCast(ImageObject, self_obj);

    const Params = struct { radius: c_long };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const radius = py_utils.validateNonNegative(u32, params.radius, "radius") catch return null;

    if (self.py_image) |pimg| {
        switch (pimg.data) {
            inline else => |img| {
                const out = @TypeOf(img).initLike(allocator, img) catch {
                    py_utils.setMemoryError("image operation");
                    return null;
                };
                img.boxBlur(allocator, @intCast(radius), out) catch {
                    py_utils.setMemoryError("image operation");
                    return null;
                };
                return @ptrCast(moveImageToPython(out) orelse return null);
            },
        }
        return null;
    }
    py_utils.setValueError("Image not initialized", .{});
    return null;
}

pub const image_median_blur_doc =
    \\Apply a median blur (order-statistic filter) to the image.
    \\
    \\## Parameters
    \\- `radius` (int): Non-negative blur radius in pixels. `0` returns an unmodified copy.
    \\
    \\## Notes
    \\- Uses `BorderMode.MIRROR` at the image edges to avoid introducing artificial borders.
    \\
    \\## Examples
    \\```python
    \\img = Image.load("noisy.png")
    \\denoised = img.median_blur(2)
    \\```
;

pub fn image_median_blur(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(ImageObject, self_obj);

    const Params = struct { radius: c_long };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const radius = py_utils.validateNonNegative(u32, params.radius, "radius") catch return null;

    if (self.py_image) |pimg| {
        switch (pimg.data) {
            inline else => |img| {
                const out = @TypeOf(img).initLike(allocator, img) catch {
                    py_utils.setMemoryError("image operation");
                    return null;
                };
                img.medianBlur(allocator, @intCast(radius), out) catch |err| {
                    switch (err) {
                        error.InvalidRadius => py_utils.setValueError("radius must be > 0", .{}),
                        error.UnsupportedPixelType => py_utils.setValueError("median blur requires u8, RGB, or RGBA images", .{}),
                        else => py_utils.setMemoryError("image operation"),
                    }
                    return null;
                };
                return @ptrCast(moveImageToPython(out) orelse return null);
            },
        }
        return null;
    }
    py_utils.setValueError("Image not initialized", .{});
    return null;
}

pub const image_min_blur_doc =
    \\Apply a minimum filter (rank 0 percentile) to the image.
    \\
    \\## Parameters
    \\- `radius` (int): Non-negative blur radius in pixels. `0` returns an unmodified copy.
    \\- `border` (BorderMode, optional): Border handling strategy. Defaults to `BorderMode.MIRROR`.
    \\
    \\## Use case
    \\- Morphological erosion to remove "salt" noise or shrink bright speckles.
;

pub fn image_min_blur(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(ImageObject, self_obj);

    const Params = struct {
        radius: c_long,
        border: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const radius = py_utils.validateNonNegative(u32, params.radius, "radius") catch return null;
    var border = zignal.BorderMode.mirror;
    if (params.border) |obj| {
        if (obj == c.Py_None()) {
            py_utils.setValueError("border must be a BorderMode enum", .{});
            return null;
        }
        border = enum_utils.pyToEnum(zignal.BorderMode, obj) catch return null;
    }

    if (self.py_image) |pimg| {
        switch (pimg.data) {
            inline else => |img| {
                const out = @TypeOf(img).initLike(allocator, img) catch {
                    py_utils.setMemoryError("image operation");
                    return null;
                };
                img.minBlur(allocator, @intCast(radius), border, out) catch |err| {
                    switch (err) {
                        error.InvalidRadius => {
                            py_utils.setValueError("radius must be > 0", .{});
                        },
                        error.UnsupportedPixelType => {
                            py_utils.setValueError("min blur requires u8, RGB, or RGBA images", .{});
                        },
                        else => {
                            py_utils.setMemoryError("image operation");
                        },
                    }
                    return null;
                };
                return @ptrCast(moveImageToPython(out) orelse return null);
            },
        }
        return null;
    }
    py_utils.setValueError("Image not initialized", .{});
    return null;
}

pub const image_max_blur_doc =
    \\Apply a maximum filter (rank 1 percentile) to the image.
    \\
    \\## Parameters
    \\- `radius` (int): Non-negative blur radius in pixels.
    \\- `border` (BorderMode, optional): Border handling strategy. Defaults to `BorderMode.MIRROR`.
    \\
    \\## Use case
    \\- Morphological dilation to expand highlights or fill gaps in masks.
;

pub fn image_max_blur(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(ImageObject, self_obj);

    const Params = struct {
        radius: c_long,
        border: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const radius = py_utils.validateNonNegative(u32, params.radius, "radius") catch return null;
    var border = zignal.BorderMode.mirror;
    if (params.border) |obj| {
        if (obj == c.Py_None()) {
            py_utils.setValueError("border must be a BorderMode enum", .{});
            return null;
        }
        border = enum_utils.pyToEnum(zignal.BorderMode, obj) catch return null;
    }

    if (self.py_image) |pimg| {
        switch (pimg.data) {
            inline else => |img| {
                const out = @TypeOf(img).initLike(allocator, img) catch {
                    py_utils.setMemoryError("image operation");
                    return null;
                };
                img.maxBlur(allocator, @intCast(radius), border, out) catch |err| {
                    switch (err) {
                        error.InvalidRadius => {
                            py_utils.setValueError("radius must be > 0", .{});
                        },
                        error.UnsupportedPixelType => {
                            py_utils.setValueError("max blur requires u8, RGB, or RGBA images", .{});
                        },
                        else => {
                            py_utils.setMemoryError("image operation");
                        },
                    }
                    return null;
                };
                return @ptrCast(moveImageToPython(out) orelse return null);
            },
        }
        return null;
    }
    py_utils.setValueError("Image not initialized", .{});
    return null;
}

pub const image_midpoint_blur_doc =
    \\Apply a midpoint filter (average of min and max) to the image.
    \\
    \\## Parameters
    \\- `radius` (int): Non-negative blur radius.
    \\- `border` (BorderMode, optional): Border handling strategy. Defaults to `BorderMode.MIRROR`.
    \\
    \\## Use case
    \\- Softens impulse noise while preserving thin edges (midpoint between min/max).
;

pub fn image_midpoint_blur(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(ImageObject, self_obj);

    const Params = struct {
        radius: c_long,
        border: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const radius = py_utils.validateNonNegative(u32, params.radius, "radius") catch return null;
    var border = zignal.BorderMode.mirror;
    if (params.border) |obj| {
        if (obj == c.Py_None()) {
            py_utils.setValueError("border must be a BorderMode enum", .{});
            return null;
        }
        border = enum_utils.pyToEnum(zignal.BorderMode, obj) catch return null;
    }

    if (self.py_image) |pimg| {
        switch (pimg.data) {
            inline else => |img| {
                const out = @TypeOf(img).initLike(allocator, img) catch {
                    py_utils.setMemoryError("image operation");
                    return null;
                };
                img.midpointBlur(allocator, @intCast(radius), border, out) catch |err| {
                    switch (err) {
                        error.InvalidRadius => {
                            py_utils.setValueError("radius must be > 0", .{});
                        },
                        error.UnsupportedPixelType => {
                            py_utils.setValueError("midpoint blur requires u8, RGB, or RGBA images", .{});
                        },
                        else => {
                            py_utils.setMemoryError("image operation");
                        },
                    }
                    return null;
                };
                return @ptrCast(moveImageToPython(out) orelse return null);
            },
        }
        return null;
    }
    py_utils.setValueError("Image not initialized", .{});
    return null;
}

pub const image_percentile_blur_doc =
    \\Apply a percentile blur (order-statistic filter) to the image.
    \\
    \\## Parameters
    \\- `radius` (int): Non-negative blur radius defining the neighborhood window.
    \\- `percentile` (float): Value in the range [0.0, 1.0] selecting which ordered pixel to keep.
    \\- `border` (BorderMode, optional): Border handling strategy. Defaults to `BorderMode.MIRROR`.
    \\
    \\## Use case
    \\- Fine control over ordered statistics (e.g., `percentile=0.1` suppresses bright outliers).
    \\
    \\## Examples
    \\```python
    \\img = Image.load("noisy.png")
    \\median = img.percentile_blur(2, 0.5)
    \\max_filter = img.percentile_blur(1, 1.0, border=zignal.BorderMode.ZERO)
    \\```
;

pub fn image_percentile_blur(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(ImageObject, self_obj);

    const Params = struct {
        radius: c_long,
        percentile: f64,
        border: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const radius = py_utils.validateNonNegative(u32, params.radius, "radius") catch return null;
    const percentile_value = py_utils.validateRange(f64, params.percentile, 0.0, 1.0, "percentile") catch return null;
    var border_mode = zignal.BorderMode.mirror;
    if (params.border) |obj| {
        if (obj == c.Py_None()) {
            py_utils.setValueError("border must be a BorderMode enum", .{});
            return null;
        }
        border_mode = enum_utils.pyToEnum(zignal.BorderMode, obj) catch return null;
    }

    if (self.py_image) |pimg| {
        switch (pimg.data) {
            inline else => |img| {
                const out = @TypeOf(img).initLike(allocator, img) catch {
                    py_utils.setMemoryError("image operation");
                    return null;
                };
                img.percentileBlur(allocator, @intCast(radius), percentile_value, border_mode, out) catch |err| {
                    switch (err) {
                        error.InvalidRadius => py_utils.setValueError("radius must be > 0", .{}),
                        error.InvalidPercentile => py_utils.setValueError("percentile must be between 0 and 1", .{}),
                        error.UnsupportedPixelType => py_utils.setValueError("percentile blur requires u8, RGB, or RGBA images", .{}),
                        else => py_utils.setMemoryError("image operation"),
                    }
                    return null;
                };
                return @ptrCast(moveImageToPython(out) orelse return null);
            },
        }
        return null;
    }
    py_utils.setValueError("Image not initialized", .{});
    return null;
}

pub const image_alpha_trimmed_mean_blur_doc =
    \\Apply an alpha-trimmed mean blur, discarding a fraction of low/high pixels.
    \\
    \\## Parameters
    \\- `radius` (int): Non-negative blur radius.
    \\- `trim_fraction` (float): Fraction in [0, 0.5) removed from both tails.
    \\- `border` (BorderMode, optional): Border handling strategy. Defaults to `BorderMode.MIRROR`.
    \\
    \\## Use case
    \\- Robust alternative to averaging that discards extremes (hot pixels, specular highlights).
;

pub fn image_alpha_trimmed_mean_blur(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(ImageObject, self_obj);

    const Params = struct {
        radius: c_long,
        trim_fraction: f64,
        border: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    if (!std.math.isFinite(params.trim_fraction)) {
        py_utils.setValueError("trim_fraction must be finite", .{});
        return null;
    }

    const radius = py_utils.validateNonNegative(u32, params.radius, "radius") catch return null;
    var border = zignal.BorderMode.mirror;
    if (params.border) |obj| {
        if (obj == c.Py_None()) {
            py_utils.setValueError("border must be a BorderMode enum", .{});
            return null;
        }
        border = enum_utils.pyToEnum(zignal.BorderMode, obj) catch return null;
    }

    const trim_fraction = params.trim_fraction;

    if (self.py_image) |pimg| {
        switch (pimg.data) {
            inline else => |img| {
                const out = @TypeOf(img).initLike(allocator, img) catch {
                    py_utils.setMemoryError("image operation");
                    return null;
                };
                img.alphaTrimmedMeanBlur(allocator, @intCast(radius), trim_fraction, border, out) catch |err| {
                    switch (err) {
                        error.InvalidRadius => {
                            py_utils.setValueError("radius must be > 0", .{});
                        },
                        error.InvalidTrim => {
                            py_utils.setValueError("trim_fraction must be in [0, 0.5)", .{});
                        },
                        error.UnsupportedPixelType => {
                            py_utils.setValueError("alpha trimmed mean requires u8, RGB, or RGBA images", .{});
                        },
                        else => {
                            py_utils.setMemoryError("image operation");
                        },
                    }
                    return null;
                };
                return @ptrCast(moveImageToPython(out) orelse return null);
            },
        }
        return null;
    }
    py_utils.setValueError("Image not initialized", .{});
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
    const self = py_utils.safeCast(ImageObject, self_obj);

    const Params = struct { sigma: f64 };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    // Validate sigma: must be finite and > 0
    if (!std.math.isFinite(params.sigma)) {
        py_utils.setValueError("sigma must be finite", .{});
        return null;
    }
    const sigma_pos = py_utils.validatePositive(f64, params.sigma, "sigma") catch return null;

    if (self.py_image) |pimg| {
        switch (pimg.data) {
            inline else => |img| {
                const out = @TypeOf(img).initLike(allocator, img) catch {
                    py_utils.setMemoryError("image operation");
                    return null;
                };
                img.gaussianBlur(allocator, @floatCast(sigma_pos), out) catch |err| {
                    if (err == error.InvalidSigma) {
                        py_utils.setValueError("Invalid sigma value", .{});
                    } else {
                        py_utils.setMemoryError("image operation");
                    }
                    return null;
                };
                return @ptrCast(moveImageToPython(out) orelse return null);
            },
        }
        return null;
    }
    py_utils.setValueError("Image not initialized", .{});
    return null;
}

pub const image_invert_doc =
    \\Invert the colors of the image.
    \\
    \\Creates a negative/inverted version of the image where:
    \\- Gray pixels: 255 - value
    \\- RGB pixels: inverts each channel (255 - r, 255 - g, 255 - b)
    \\- RGBA pixels: inverts RGB channels while preserving alpha
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\inverted = img.invert()
    \\
    \\# Works with all image types
    \\gray = Image(100, 100, 128, dtype=zignal.Gray)
    \\gray_inv = gray.invert()  # pixels become 127
    \\```
;

pub fn image_invert(self_obj: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = args;
    const self = py_utils.safeCast(ImageObject, self_obj);

    if (self.py_image) |pimg| {
        switch (pimg.data) {
            inline else => |img| {
                var out = img.dupe(allocator) catch {
                    py_utils.setMemoryError("image data");
                    return null;
                };
                out.invert();
                return @ptrCast(moveImageToPython(out) orelse return null);
            },
        }
        return null;
    }

    py_utils.setValueError("Image not initialized", .{});
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
    const self = py_utils.safeCast(ImageObject, self_obj);

    const Params = struct { radius: c_long };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const radius = py_utils.validateNonNegative(u32, params.radius, "radius") catch return null;

    if (self.py_image) |pimg| {
        switch (pimg.data) {
            inline else => |img| {
                const out = @TypeOf(img).initLike(allocator, img) catch {
                    py_utils.setMemoryError("image operation");
                    return null;
                };
                img.sharpen(allocator, @intCast(radius), out) catch {
                    py_utils.setMemoryError("image operation");
                    return null;
                };
                return @ptrCast(moveImageToPython(out) orelse return null);
            },
        }
        return null;
    }
    py_utils.setValueError("Image not initialized", .{});
    return null;
}

pub const image_autocontrast_doc =
    \\Automatically adjust image contrast by stretching the intensity range.
    \\
    \\Analyzes the histogram and remaps pixel values so the darkest pixels
    \\become black (0) and brightest become white (255).
    \\
    \\## Parameters
    \\- `cutoff` (float, optional): Rate of pixels to ignore at extremes (0-0.5).
    \\  Default: 0. For example, 0.02 ignores the darkest and brightest 2% of pixels,
    \\  helping to remove outliers.
    \\
    \\## Returns
    \\A new image with adjusted contrast.
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\
    \\# Basic auto-contrast
    \\enhanced = img.autocontrast()
    \\
    \\# Ignore 2% outliers on each end
    \\enhanced = img.autocontrast(cutoff=0.02)
    \\```
;

pub fn image_autocontrast(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(ImageObject, self_obj);

    const Params = struct { cutoff: f64 = 0.0 };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    // Validate cutoff range (0.0 to 0.5 fraction)
    if (params.cutoff < 0 or params.cutoff >= 0.5) {
        py_utils.setValueError("cutoff must be between 0 and 0.5", .{});
        return null;
    }

    const cutoff: f32 = @floatCast(params.cutoff);

    if (self.py_image) |pimg| {
        switch (pimg.data) {
            inline else => |img| {
                // Make a copy since autocontrast now works in-place
                var out = img.dupe(allocator) catch {
                    py_utils.setMemoryError("image operation");
                    return null;
                };
                // we already checked for the cutoff value
                out.autocontrast(cutoff) catch unreachable;
                return @ptrCast(moveImageToPython(out) orelse return null);
            },
        }
    }
    py_utils.setValueError("Image not initialized", .{});
    return null;
}

pub const image_equalize_doc =
    \\Equalize the histogram of the image to improve contrast.
    \\
    \\Redistributes pixel intensities to achieve a more uniform histogram,
    \\which typically enhances contrast in images with poor contrast or
    \\uneven lighting conditions. The technique maps the cumulative
    \\distribution function (CDF) of pixel values to create a more even
    \\spread of intensities across the full range.
    \\
    \\For color images (RGB/RGBA), each channel is equalized independently.
    \\
    \\## Returns
    \\Image: New image with equalized histogram
    \\
    \\## Example
    \\```python
    \\import zignal
    \\
    \\# Load an image with poor contrast
    \\img = zignal.Image.load("low_contrast.jpg")
    \\
    \\# Apply histogram equalization
    \\equalized = img.equalize()
    \\
    \\# Save the result
    \\equalized.save("equalized.jpg")
    \\
    \\# Compare with autocontrast
    \\auto = img.autocontrast(cutoff=0.02)
    \\```
;

pub fn image_equalize(self_obj: ?*c.PyObject, _: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(ImageObject, self_obj);

    // Apply equalization
    if (self.py_image) |pimg| {
        switch (pimg.data) {
            inline else => |img| {
                // Make a copy since equalize now works in-place
                var out = img.dupe(allocator) catch {
                    py_utils.setMemoryError("image operation");
                    return null;
                };
                out.equalize();
                return @ptrCast(moveImageToPython(out) orelse return null);
            },
        }
    }
    py_utils.setValueError("Image not initialized", .{});
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

pub fn image_motion_blur(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(ImageObject, self_obj);
    const motion_blur = @import("../motion_blur.zig");

    const Params = struct { config: ?*c.PyObject };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const config_obj = params.config;

    // Check that it's a MotionBlur object
    const type_obj = c.Py_TYPE(config_obj);
    const type_name = type_obj.*.tp_name;

    if (!std.mem.eql(u8, std.mem.span(type_name), "zignal.MotionBlur")) {
        py_utils.setTypeError("MotionBlur object", config_obj);
        return null;
    }

    // Cast to MotionBlurObject to access the blur_type discriminator
    const blur_obj = @as(*motion_blur.MotionBlurObject, @ptrCast(config_obj));

    if (self.py_image) |pimg| {
        switch (pimg.data) {
            inline else => |img| {
                const out = @TypeOf(img).initLike(allocator, img) catch {
                    py_utils.setMemoryError("image operation");
                    return null;
                };

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

                img.motionBlur(allocator, blur_config, out) catch {
                    py_utils.setMemoryError("image operation");
                    return null;
                };

                return @ptrCast(moveImageToPython(out) orelse return null);
            },
        }
    }

    py_utils.setValueError("Image not initialized", .{});
    return null;
}

pub const image_sobel_doc =
    \\Apply Sobel edge detection and return the gradient magnitude.
    \\
    \\The result is a new grayscale image (`dtype=zignal.Gray`) where
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
    const self = py_utils.safeCast(ImageObject, self_obj);

    if (self.py_image) |pimg| {
        switch (pimg.data) {
            inline else => |img| {
                const out = Image(u8).initLike(allocator, img) catch {
                    py_utils.setMemoryError("image operation");
                    return null;
                };
                img.sobel(allocator, out) catch {
                    py_utils.setMemoryError("image operation");
                    return null;
                };
                return @ptrCast(moveImageToPython(out) orelse return null);
            },
        }
        return null;
    }

    py_utils.setValueError("Image not initialized", .{});
    return null;
}

pub const image_shen_castan_doc =
    \\Apply Shen-Castan edge detection to the image.
    \\
    \\The Shen-Castan algorithm uses ISEF (Infinite Symmetric Exponential Filter)
    \\for edge detection with adaptive gradient computation and hysteresis thresholding.
    \\Returns a binary edge map where edges are 255 (white) and non-edges are 0 (black).
    \\
    \\## Parameters
    \\- `smooth` (float, optional): ISEF smoothing factor (0 < smooth < 1). Higher values preserve more detail. Default: 0.9
    \\- `window_size` (int, optional): Odd window size for local gradient statistics (>= 3). Default: 7
    \\- `high_ratio` (float, optional): Percentile for high threshold selection (0 < high_ratio < 1). Default: 0.99
    \\- `low_rel` (float, optional): Low threshold as fraction of high threshold (0 < low_rel < 1). Default: 0.5
    \\- `hysteresis` (bool, optional): Enable hysteresis edge linking. When True, weak edges connected to strong edges are preserved. Default: True
    \\- `use_nms` (bool, optional): Use non-maximum suppression for single-pixel edges. When True, produces thinner edges. Default: False
    \\
    \\## Returns
    \\- `Image`: Binary edge map (Gray image with values 0 or 255)
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
    const self = py_utils.safeCast(ImageObject, self_obj);

    const Params = struct {
        smooth: f64 = 0.9,
        window_size: c_long = 7,
        high_ratio: f64 = 0.99,
        low_rel: f64 = 0.5,
        hysteresis: c_int = 1, // True by default
        use_nms: c_int = 0, // False by default
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    // Validate parameters
    if (params.smooth <= 0 or params.smooth >= 1) {
        py_utils.setValueError("smooth must be between 0 and 1", .{});
        return null;
    }
    if (params.window_size < 3) {
        py_utils.setValueError("window_size must be >= 3", .{});
        return null;
    }
    if (@mod(params.window_size, 2) == 0) {
        py_utils.setValueError("window_size must be odd", .{});
        return null;
    }
    if (params.high_ratio <= 0 or params.high_ratio >= 1) {
        c.PyErr_SetString(c.PyExc_ValueError, "high_ratio must be between 0 and 1");
        return null;
    }
    if (params.low_rel <= 0 or params.low_rel >= 1) {
        c.PyErr_SetString(c.PyExc_ValueError, "low_rel must be between 0 and 1");
        return null;
    }

    const smooth = params.smooth;
    const window_size = params.window_size;
    const high_ratio = params.high_ratio;
    const low_rel = params.low_rel;
    const hysteresis = params.hysteresis;
    const use_nms = params.use_nms;

    if (self.py_image) |pimg| {
        // Additional validation: window_size should not exceed image dimensions
        const rows = pimg.rows();
        const cols = pimg.cols();
        const max_window = @min(rows, cols);
        if (window_size > max_window) {
            const msg = std.fmt.allocPrint(allocator, "window_size ({d}) cannot exceed minimum image dimension ({d})\x00", .{ window_size, max_window }) catch {
                c.PyErr_SetString(c.PyExc_ValueError, "window_size too large for image dimensions");
                return null;
            };
            defer allocator.free(msg);
            c.PyErr_SetString(c.PyExc_ValueError, msg.ptr);
            return null;
        }

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
                const out = Image(u8).initLike(allocator, img) catch {
                    py_utils.setMemoryError("image operation");
                    return null;
                };
                img.shenCastan(allocator, opts, out) catch |err| {
                    if (err == error.InvalidBParameter) {
                        c.PyErr_SetString(c.PyExc_ValueError, "smooth parameter must be between 0 and 1");
                    } else if (err == error.WindowSizeMustBeOdd) {
                        py_utils.setValueError("window_size must be odd", .{});
                    } else if (err == error.WindowSizeTooSmall) {
                        py_utils.setValueError("window_size must be >= 3", .{});
                    } else if (err == error.InvalidThreshold) {
                        c.PyErr_SetString(c.PyExc_ValueError, "Invalid threshold parameters (high_ratio or low_rel out of range)");
                    } else {
                        c.PyErr_SetString(c.PyExc_MemoryError, "Failed to allocate memory for edge detection");
                    }
                    return null;
                };
                return @ptrCast(moveImageToPython(out) orelse return null);
            },
        }
    }

    py_utils.setValueError("Image not initialized", .{});
    return null;
}

pub const image_canny_doc =
    \\Apply Canny edge detection to the image.
    \\
    \\The Canny algorithm is a classic multi-stage edge detector that produces thin,
    \\well-localized edges with good noise suppression. It consists of five main steps:
    \\1. Gaussian smoothing to reduce noise
    \\2. Gradient computation using Sobel operators
    \\3. Non-maximum suppression to thin edges
    \\4. Double thresholding to classify strong and weak edges
    \\5. Edge tracking by hysteresis to link edges
    \\
    \\Returns a binary edge map where edges are 255 (white) and non-edges are 0 (black).
    \\
    \\## Parameters
    \\- `sigma` (float, optional): Standard deviation for Gaussian blur. Default: 1.4.
    \\                             Typical values: 1.0-2.0. Higher values = more smoothing, fewer edges.
    \\- `low` (float, optional): Lower threshold for hysteresis. Default: 50.
    \\- `high` (float, optional): Upper threshold for hysteresis. Default: 150.
    \\                            Should be 2-3x larger than `low`.
    \\
    \\## Returns
    \\A new grayscale image (`dtype=zignal.Gray`) with binary edge map.
    \\
    \\## Raises
    \\- `ValueError`: If sigma < 0, thresholds are negative, or low >= high
    \\
    \\## Examples
    \\```python
    \\img = Image.load("photo.png")
    \\
    \\# Use defaults (sigma=1.4, low=50, high=150)
    \\edges = img.canny()
    \\
    \\# Custom parameters - more aggressive edge detection (lower thresholds)
    \\edges_sensitive = img.canny(sigma=1.0, low=30, high=90)
    \\
    \\# Conservative edge detection (higher thresholds)
    \\edges_conservative = img.canny(sigma=2.0, low=100, high=200)
    \\```
;

pub fn image_canny(self_obj: ?*c.PyObject, args: ?*c.PyObject, kwds: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    const self = py_utils.safeCast(ImageObject, self_obj);

    const Params = struct {
        sigma: f64 = 1.4,
        low: f64 = 50,
        high: f64 = 150,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    // Validate parameters are finite first
    if (!std.math.isFinite(params.sigma)) {
        py_utils.setValueError("sigma must be finite", .{});
        return null;
    }
    if (!std.math.isFinite(params.low) or !std.math.isFinite(params.high)) {
        py_utils.setValueError("thresholds must be finite", .{});
        return null;
    }

    const sigma = py_utils.validateNonNegative(f32, params.sigma, "sigma") catch return null;
    const low = py_utils.validateNonNegative(f32, params.low, "low") catch return null;
    const high = py_utils.validateNonNegative(f32, params.high, "high") catch return null;

    if (low >= high) {
        py_utils.setValueError("low must be less than high", .{});
        return null;
    }

    if (self.py_image) |pimg| {
        // Apply Canny edge detection
        switch (pimg.data) {
            inline else => |img| {
                const out = Image(u8).initLike(allocator, img) catch {
                    py_utils.setMemoryError("image operation");
                    return null;
                };
                img.canny(allocator, sigma, low, high, out) catch |err| {
                    if (err == error.InvalidParameter) {
                        py_utils.setValueError("parameters must be finite numbers", .{});
                    } else if (err == error.InvalidSigma) {
                        py_utils.setValueError("sigma must be non-negative", .{});
                    } else if (err == error.InvalidThreshold) {
                        py_utils.setValueError("thresholds are invalid", .{});
                    } else {
                        py_utils.setMemoryError("image operation");
                    }
                    return null;
                };
                return @ptrCast(moveImageToPython(out) orelse return null);
            },
        }
    }

    py_utils.setValueError("Image not initialized", .{});
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
    const self = py_utils.safeCast(ImageObject, self_obj);

    const Params = struct {
        overlay: ?*c.PyObject,
        mode: ?*c.PyObject = null,
    };
    var params: Params = undefined;
    py_utils.parseArgs(Params, args, kwds, &params) catch return null;

    const overlay_obj = params.overlay;
    const mode_obj = params.mode;

    // Check if overlay is an Image instance
    if (c.PyObject_IsInstance(overlay_obj, @ptrCast(getImageType())) <= 0) {
        c.PyErr_SetString(c.PyExc_TypeError, "overlay must be an Image object");
        return null;
    }

    const overlay = @as(*ImageObject, @ptrCast(overlay_obj.?));

    // Get blend mode (default to normal if not specified)
    var blend_mode = zignal.Blending.normal;
    if (mode_obj != null and mode_obj != c.Py_None()) {
        blend_mode = enum_utils.pyToEnum(zignal.Blending, mode_obj.?) catch {
            return null; // Error already set
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
        .gray => |base_img| {
            for (0..self_rows) |row| {
                for (0..self_cols) |col| {
                    const base_pixel = base_img.at(row, col).*;
                    const base_rgb: Rgb = .{ .r = base_pixel, .g = base_pixel, .b = base_pixel };
                    base_img.at(row, col).* = base_rgb.blend(overlay_img.at(row, col).*, blend_mode).to(.gray).y;
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
