//! Kitty graphics protocol support for image rendering
//!
//! This module provides functionality to convert images to Kitty graphics protocol format,
//! which is supported by Kitty terminal and other compatible terminal emulators.
//!
//! The Kitty graphics protocol allows displaying raster images directly in the terminal
//! with features like alpha blending, positioning, and scaling.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Image = @import("image.zig").Image;
const Interpolation = @import("image/interpolation.zig").Interpolation;
const png = @import("png.zig");
const Rgb = @import("color.zig").Rgb;
const terminal = @import("terminal.zig");

// Kitty protocol constants
const max_chunk_size: usize = 4096; // Maximum payload size per escape sequence

/// Options for Kitty graphics protocol encoding
pub const Options = struct {
    /// Suppress terminal responses (0=normal, 1=suppress OK, 2=suppress all)
    quiet: u2 = 1,
    /// Image placement ID (optional, for referencing the image later)
    image_id: ?u32 = null,
    /// Placement ID (optional, for multiple placements of same image)
    placement_id: ?u32 = null,
    /// Delete image after display
    delete_after: bool = false,
    /// Enable chunking for increased reliability (Ghostty doesn't support it)
    enable_chunking: bool = false,
    /// Display width in pixels
    /// If null, uses image's natural width
    width: ?u32 = null,
    /// Display height in pixels
    /// If null, uses image's natural height or calculates from width to preserve aspect ratio
    height: ?u32 = null,
    /// Interpolation method to use when scaling the image
    interpolation: Interpolation = .bilinear,

    /// Default options for automatic formatting
    pub const default: Options = .{
        .quiet = 1,
        .image_id = null,
        .placement_id = null,
        .delete_after = false,
        .enable_chunking = false,
        .width = null,
        .height = null,
        .interpolation = .bilinear,
    };
};

/// Converts an image to Kitty graphics protocol format
pub fn fromImage(
    comptime T: type,
    image: Image(T),
    gpa: Allocator,
    options: Options,
) ![]u8 {
    var image_to_encode = image;
    var scaled_image: ?Image(T) = null;
    defer if (scaled_image) |*img| img.deinit(gpa);

    // Handle scaling with shared policy (preserve aspect ratio)
    const scale_factor = terminal.aspectScale(options.width, options.height, image.rows, image.cols);
    if (@abs(scale_factor - 1.0) > 0.001) {
        scaled_image = try image.scale(gpa, scale_factor, options.interpolation);
        image_to_encode = scaled_image.?;
    }

    // Encode the (possibly scaled) image as PNG
    const png_data = try png.encodeImage(T, gpa, image_to_encode, .default);
    defer gpa.free(png_data);

    // Calculate base64 encoded size
    const encoder = std.base64.standard.Encoder;
    const encoded_size = encoder.calcSize(png_data.len);

    // Allocate buffer for base64 data
    const base64_data = try gpa.alloc(u8, encoded_size);
    defer gpa.free(base64_data);

    // Encode to base64
    _ = encoder.encode(base64_data, png_data);

    // Build the output with proper escape sequences
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(gpa);

    // If chunking is disabled, send everything in one go
    if (!options.enable_chunking) {
        // Write escape sequence start
        try output.appendSlice(gpa, "\x1b_G");

        // Write control data
        try output.appendSlice(gpa, "a=T");
        try output.appendSlice(gpa, ",f=100");
        const q_fmt = try std.fmt.allocPrint(gpa, ",q={d}", .{options.quiet});
        defer gpa.free(q_fmt);
        try output.appendSlice(gpa, q_fmt);

        // Optional parameters
        if (options.image_id) |id| {
            const i_fmt = try std.fmt.allocPrint(gpa, ",i={d}", .{id});
            defer gpa.free(i_fmt);
            try output.appendSlice(gpa, i_fmt);
        }
        if (options.placement_id) |id| {
            const p_fmt = try std.fmt.allocPrint(gpa, ",p={d}", .{id});
            defer gpa.free(p_fmt);
            try output.appendSlice(gpa, p_fmt);
        }
        if (options.delete_after) {
            try output.appendSlice(gpa, ",d=1");
        }

        // Separator and payload
        try output.appendSlice(gpa, ";");
        try output.appendSlice(gpa, base64_data);
        try output.appendSlice(gpa, "\x1b\\");

        return output.toOwnedSlice(gpa);
    }

    // Process each chunk (original chunking logic)
    var offset: usize = 0;
    var chunk_index: usize = 0;
    while (offset < base64_data.len) : (chunk_index += 1) {
        const is_last = offset + max_chunk_size >= base64_data.len;
        const chunk_end = if (is_last)
            base64_data.len
        else
            // Non-final chunks must be multiples of 4
            offset + (max_chunk_size & ~@as(usize, 3));
        const chunk = base64_data[offset..chunk_end];

        // Write escape sequence start
        try output.appendSlice(gpa, "\x1b_G");

        // Write control data for first chunk
        if (chunk_index == 0) {
            // Action: transmit and display
            try output.appendSlice(gpa, "a=T");

            // Format: PNG
            try output.appendSlice(gpa, ",f=100");

            // Quiet mode
            const q_fmt = try std.fmt.allocPrint(gpa, ",q={d}", .{options.quiet});
            defer gpa.free(q_fmt);
            try output.appendSlice(gpa, q_fmt);

            // Optional image ID
            if (options.image_id) |id| {
                const i_fmt = try std.fmt.allocPrint(gpa, ",i={d}", .{id});
                defer gpa.free(i_fmt);
                try output.appendSlice(gpa, i_fmt);
            }

            // Optional placement ID
            if (options.placement_id) |id| {
                const p_fmt = try std.fmt.allocPrint(gpa, ",p={d}", .{id});
                defer gpa.free(p_fmt);
                try output.appendSlice(gpa, p_fmt);
            }

            // Delete after display
            if (options.delete_after) {
                try output.appendSlice(gpa, ",d=1");
            }
        }

        // More data indicator (m=1 for continuation, m=0 or omitted for final)
        if (!is_last) {
            if (chunk_index == 0) {
                try output.appendSlice(gpa, ",m=1");
            } else {
                try output.appendSlice(gpa, "m=1");
            }
        }

        // Separator between control and payload
        try output.appendSlice(gpa, ";");

        // Write chunk data
        try output.appendSlice(gpa, chunk);

        // Write escape sequence end
        try output.appendSlice(gpa, "\x1b\\");

        offset = chunk_end;
    }

    return output.toOwnedSlice(gpa);
}

/// Detects if the terminal supports Kitty graphics protocol
pub fn isSupported() bool {
    // Check if we're connected to a terminal
    if (!terminal.isStdoutTty()) {
        // Not a TTY, don't support Kitty for file output
        return false;
    }

    // Try terminal detection first
    return terminal.isKittySupported() catch false;
}

// Tests
test "imageToKitty basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a small test image
    var img = try Image(Rgb).init(allocator, 2, 2);
    defer img.deinit(allocator);

    // Fill with test colors
    img.at(0, 0).* = Rgb{ .r = 255, .g = 0, .b = 0 };
    img.at(0, 1).* = Rgb{ .r = 0, .g = 255, .b = 0 };
    img.at(1, 0).* = Rgb{ .r = 0, .g = 0, .b = 255 };
    img.at(1, 1).* = Rgb{ .r = 255, .g = 255, .b = 255 };

    // Convert to Kitty format
    const kitty_data = try fromImage(Rgb, img, allocator, .default);
    defer allocator.free(kitty_data);

    // Basic validation - should start with Kitty escape sequence
    try testing.expect(std.mem.startsWith(u8, kitty_data, "\x1b_G"));

    // Should end with escape sequence terminator
    try testing.expect(std.mem.endsWith(u8, kitty_data, "\x1b\\"));

    // Should contain PNG format specifier
    try testing.expect(std.mem.indexOf(u8, kitty_data, "f=100") != null);

    // Should contain action=transmit
    try testing.expect(std.mem.indexOf(u8, kitty_data, "a=T") != null);
}

test "imageToKitty with options" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a small test image
    var img = try Image(u8).init(allocator, 1, 1);
    defer img.deinit(allocator);
    img.at(0, 0).* = 128;

    // Test with custom options
    const options = Options{
        .quiet = 2,
        .image_id = 42,
        .placement_id = 7,
        .delete_after = true,
    };

    const kitty_data = try fromImage(u8, img, allocator, options);
    defer allocator.free(kitty_data);

    // Check that options are included
    try testing.expect(std.mem.indexOf(u8, kitty_data, "q=2") != null);
    try testing.expect(std.mem.indexOf(u8, kitty_data, "i=42") != null);
    try testing.expect(std.mem.indexOf(u8, kitty_data, "p=7") != null);
    try testing.expect(std.mem.indexOf(u8, kitty_data, "d=1") != null);
}
