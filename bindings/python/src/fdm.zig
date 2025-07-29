const std = @import("std");

const zignal = @import("zignal");

const image = @import("image.zig");
const py_utils = @import("py_utils.zig");
const c = py_utils.c;
const stub_metadata = @import("stub_metadata.zig");

// Documentation for feature_distribution_match function
const feature_distribution_match_doc =
    \\feature_distribution_match(source, reference, /)
    \\--
    \\
    \\Apply Feature Distribution Matching (FDM) to transfer color/style from reference to source image.
    \\
    \\This function modifies the source image in-place to match the color distribution
    \\(mean and covariance) of the reference image while preserving the structure of the source.
    \\The algorithm works by transforming the color distribution of the source image to match
    \\that of the reference image using statistical moments.
    \\
    \\Parameters
    \\----------
    \\source : Image
    \\    Source image to be modified (modified in-place). The structure and content
    \\    of this image will be preserved, but its colors will be adjusted.
    \\reference : Image
    \\    Reference image providing the target color distribution. This image's color
    \\    statistics (mean and covariance) will be matched by the source image.
    \\
    \\Returns
    \\-------
    \\None
    \\    This function modifies the source image in-place
    \\
    \\Raises
    \\------
    \\TypeError
    \\    If either source or reference is not an Image object
    \\ValueError
    \\    If either image is not initialized
    \\MemoryError
    \\    If the algorithm runs out of memory during processing
    \\
    \\Notes
    \\-----
    \\FDM is particularly useful for:
    \\- Color transfer between images
    \\- Style matching for consistent look across image sets
    \\- Histogram matching with preservation of image structure
    \\- Color grading and correction
    \\
    \\The algorithm preserves the structure of the source image while only
    \\modifying its color distribution, making it ideal for artistic style
    \\transfer applications.
    \\
    \\Examples
    \\--------
    \\>>> # Basic color transfer
    \\>>> src_img = Image.load("portrait.png")
    \\>>> ref_img = Image.load("sunset.png")
    \\>>> zignal.feature_distribution_match(src_img, ref_img)
    \\>>> src_img.save("portrait_sunset_colors.png")
    \\
    \\>>> # Batch processing with consistent color grading
    \\>>> reference = Image.load("color_reference.png")
    \\>>> for filename in image_files:
    \\...     img = Image.load(filename)
    \\...     zignal.feature_distribution_match(img, reference)
    \\...     img.save(f"graded_{filename}")
;

pub fn feature_distribution_match(self: ?*c.PyObject, args: ?*c.PyObject) callconv(.c) ?*c.PyObject {
    _ = self;

    var src_obj: ?*c.PyObject = undefined;
    var ref_obj: ?*c.PyObject = undefined;

    const format = std.fmt.comptimePrint("OO", .{});
    if (c.PyArg_ParseTuple(args, format.ptr, &src_obj, &ref_obj) == 0) {
        return null;
    }

    // Check if both arguments are Image objects
    if (c.PyObject_IsInstance(src_obj, @ptrCast(&image.ImageType)) != 1) {
        c.PyErr_SetString(c.PyExc_TypeError, "First argument must be an Image object");
        return null;
    }

    if (c.PyObject_IsInstance(ref_obj, @ptrCast(&image.ImageType)) != 1) {
        c.PyErr_SetString(c.PyExc_TypeError, "Second argument must be an Image object");
        return null;
    }

    // Cast to ImageObject
    const src_img_obj = @as(*image.ImageObject, @ptrCast(src_obj.?));
    const ref_img_obj = @as(*image.ImageObject, @ptrCast(ref_obj.?));

    // Check if images are initialized
    if (src_img_obj.image_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Source image is not initialized");
        return null;
    }

    if (ref_img_obj.image_ptr == null) {
        c.PyErr_SetString(c.PyExc_ValueError, "Reference image is not initialized");
        return null;
    }

    var arena = py_utils.createArenaAllocator();
    defer arena.deinit();
    const allocator = arena.allocator();

    // Call the FDM function
    zignal.featureDistributionMatch(zignal.Rgba, allocator, src_img_obj.image_ptr.?.*, ref_img_obj.image_ptr.?.*) catch |err| {
        switch (err) {
            error.OutOfMemory => c.PyErr_SetString(c.PyExc_MemoryError, "Out of memory during feature distribution matching"),
        }
        return null;
    };

    // Return None
    const none = c.Py_None();
    c.Py_INCREF(none);
    return none;
}

// FDM function metadata
pub const fdm_metadata = stub_metadata.FunctionWithMetadata{
    .name = "feature_distribution_match",
    .meth = @ptrCast(&feature_distribution_match),
    .flags = c.METH_VARARGS,
    .doc = feature_distribution_match_doc,
    .params = "source: Image, reference: Image",
    .returns = "None",
};
