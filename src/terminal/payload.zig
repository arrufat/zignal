//! Shared image-payload preparation for the passthrough graphics protocols
//! (kitty, iTerm2): aspect-preserving scale, PNG-encode, then base64-encode.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Image = @import("../image.zig").Image;
const Interpolation = @import("../image/interpolation.zig").Interpolation;
const png = @import("../codecs.zig").png;
const detect = @import("detect.zig");

/// Result of `scaledPngBase64`. `base64` is caller-owned (free with `gpa.free`).
pub const PngBase64 = struct {
    /// Base64-encoded PNG bytes.
    base64: []u8,
    /// Decoded PNG byte count (what iTerm2's `size=` field needs).
    png_len: usize,
};

/// Scale `image` to fit the optional `width`/`height` (via `detect.aspectScale`),
/// PNG-encode it, and base64-encode the result.
pub fn scaledPngBase64(
    comptime T: type,
    image: Image(T),
    gpa: Allocator,
    width: ?u32,
    height: ?u32,
    interpolation: Interpolation,
) !PngBase64 {
    var image_to_encode = image;
    var scaled_image: ?Image(T) = null;
    defer if (scaled_image) |*img| img.deinit(gpa);

    const scale_factor = detect.aspectScale(width, height, image.rows, image.cols);
    if (@abs(scale_factor - 1.0) > 0.001) {
        scaled_image = try image.scale(gpa, scale_factor, interpolation);
        image_to_encode = scaled_image.?;
    }

    const png_data = try png.encode(T, gpa, image_to_encode, .default);
    defer gpa.free(png_data);

    const encoder = std.base64.standard.Encoder;
    const base64 = try gpa.alloc(u8, encoder.calcSize(png_data.len));
    errdefer gpa.free(base64);
    _ = encoder.encode(base64, png_data);

    return .{ .base64 = base64, .png_len = png_data.len };
}
