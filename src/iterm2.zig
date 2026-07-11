//! iTerm2 inline image protocol support for image rendering
//!
//! This module converts images to the iTerm2 inline image protocol (`OSC 1337`),
//! supported by iTerm2, WezTerm, and other compatible terminal emulators.
//!
//! The image is PNG-encoded and base64-wrapped in a single control sequence:
//! `ESC ] 1337 ; File = inline=1 ; size=<bytes> : <base64> BEL`.
//! Unlike Kitty, there is no cache/placement lifecycle — each call emits one
//! self-contained image at the cursor.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Image = @import("image.zig").Image;
const Interpolation = @import("image/interpolation.zig").Interpolation;
const png = @import("codecs.zig").png;
const Rgb = @import("color.zig").Rgb(u8);
const terminal = @import("terminal.zig");

/// Options for iTerm2 inline image encoding
pub const Options = struct {
    /// Display width in pixels (null = image's natural width)
    width: ?u32 = null,
    /// Display height in pixels (null = aspect-preserved from width, or natural height)
    height: ?u32 = null,
    /// Interpolation method to use when scaling the image
    interpolation: Interpolation = .bilinear,

    /// Default options for automatic formatting
    pub const default: Options = .{
        .width = null,
        .height = null,
        .interpolation = .bilinear,
    };
};

/// Converts an image to iTerm2 inline image protocol format
pub fn fromImage(
    comptime T: type,
    image: Image(T),
    gpa: Allocator,
    options: Options,
) ![]u8 {
    var image_to_encode = image;
    var scaled_image: ?Image(T) = null;
    defer if (scaled_image) |*img| img.deinit(gpa);

    const scale_factor = terminal.aspectScale(options.width, options.height, image.rows, image.cols);
    if (@abs(scale_factor - 1.0) > 0.001) {
        scaled_image = try image.scale(gpa, scale_factor, options.interpolation);
        image_to_encode = scaled_image.?;
    }

    const png_data = try png.encode(T, gpa, image_to_encode, .default);
    defer gpa.free(png_data);

    const encoder = std.base64.standard.Encoder;
    const base64_data = try gpa.alloc(u8, encoder.calcSize(png_data.len));
    defer gpa.free(base64_data);
    _ = encoder.encode(base64_data, png_data);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);
    try output.ensureTotalCapacity(gpa, base64_data.len + 64);

    // OSC 1337 ; File=inline=1 ; size=<png bytes> : <base64> BEL.
    // `size` is the decoded (PNG) byte count, not the base64 length.
    try output.print(gpa, "\x1b]1337;File=inline=1;size={d}:", .{png_data.len});
    try output.appendSlice(gpa, base64_data);
    try output.append(gpa, 0x07);
    return output.toOwnedSlice(gpa);
}

/// Detects if the terminal supports the iTerm2 inline image protocol.
/// Identified via the terminal's XTVERSION name (iTerm2, WezTerm).
pub fn isSupported(io: std.Io) bool {
    if (!terminal.isStdoutTty(io)) return false;
    return terminal.isIterm2Supported(io) catch false;
}

// Tests
test "imageToIterm2 basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var img = try Image(Rgb).init(allocator, 2, 2);
    defer img.deinit(allocator);

    img.at(0, 0).* = Rgb{ .r = 255, .g = 0, .b = 0 };
    img.at(0, 1).* = Rgb{ .r = 0, .g = 255, .b = 0 };
    img.at(1, 0).* = Rgb{ .r = 0, .g = 0, .b = 255 };
    img.at(1, 1).* = Rgb{ .r = 255, .g = 255, .b = 255 };

    const data = try fromImage(Rgb, img, allocator, .default);
    defer allocator.free(data);

    // Starts with the OSC 1337 File preamble
    try testing.expect(std.mem.startsWith(u8, data, "\x1b]1337;File="));
    // Marks the payload as an inline image with a declared size
    try testing.expect(std.mem.find(u8, data, "inline=1") != null);
    try testing.expect(std.mem.find(u8, data, "size=") != null);
    // Terminated by BEL
    try testing.expect(std.mem.endsWith(u8, data, "\x07"));
}

test "imageToIterm2 with scaling" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var img = try Image(Rgb).init(allocator, 4, 4);
    defer img.deinit(allocator);

    for (0..4) |y| {
        for (0..4) |x| {
            const val: u8 = @intCast((x + y) * 32);
            img.at(y, x).* = Rgb{ .r = val, .g = val, .b = val };
        }
    }

    const options: Options = .{ .width = 16, .height = 16 };
    const data = try fromImage(Rgb, img, allocator, options);
    defer allocator.free(data);

    try testing.expect(std.mem.startsWith(u8, data, "\x1b]1337;File="));
    try testing.expect(std.mem.endsWith(u8, data, "\x07"));
    try testing.expect(data.len > 100);
}

test "imageToIterm2 declared size matches decoded payload" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var img = try Image(Rgb).init(allocator, 3, 3);
    defer img.deinit(allocator);
    for (0..3) |y| for (0..3) |x| {
        img.at(y, x).* = Rgb{ .r = @intCast(x * 80), .g = @intCast(y * 80), .b = 40 };
    };

    const data = try fromImage(Rgb, img, allocator, .default);
    defer allocator.free(data);

    // Parse the declared size and the base64 payload, then verify size ==
    // decoded length so the `size=` field can't silently drift to base64 length.
    const size_start = (std.mem.find(u8, data, "size=") orelse unreachable) + "size=".len;
    const colon = std.mem.indexOfScalarPos(u8, data, size_start, ':') orelse unreachable;
    const declared_size = try std.fmt.parseInt(usize, data[size_start..colon], 10);

    const payload = data[colon + 1 .. data.len - 1]; // strip trailing BEL
    const decoder = std.base64.standard.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(payload);
    try testing.expectEqual(declared_size, decoded_len);
}
