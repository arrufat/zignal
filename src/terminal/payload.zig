//! Shared image-payload preparation for the passthrough graphics protocols
//! (kitty, iTerm2): aspect-preserving scale, then PNG-encode.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Image = @import("../image.zig").Image;
const Interpolation = @import("../image/interpolation.zig").Interpolation;
const png = @import("../codecs.zig").png;
const detect = @import("detect.zig");

/// Scale `image` to fit the optional `width`/`height` (via `detect.aspectScale`)
/// and PNG-encode it. Caller owns the returned bytes (free with `gpa.free`).
pub fn scaledPng(
    comptime T: type,
    io: Io,
    image: Image(T),
    gpa: Allocator,
    width: ?u32,
    height: ?u32,
    interpolation: Interpolation,
) ![]u8 {
    var image_to_encode = image;
    var scaled_image: ?Image(T) = null;
    defer if (scaled_image) |*img| img.deinit(gpa);

    const scale_factor = detect.aspectScale(width, height, image.rows, image.cols);
    if (!detect.isIdentityScale(scale_factor)) {
        scaled_image = try image.scale(io, gpa, scale_factor, interpolation);
        image_to_encode = scaled_image.?;
    }

    return png.encode(T, io, gpa, image_to_encode, .default);
}
