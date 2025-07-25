//! Display format tests

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectEqualStrings = std.testing.expectEqualStrings;
const Image = @import("../image.zig").Image;
const color = @import("../../color.zig");
const DisplayFormat = @import("../display.zig").DisplayFormat;

test "image format function" {
    const Rgb = color.Rgb;

    // Create a small 2x2 RGB image
    var image = try Image(Rgb).initAlloc(std.testing.allocator, 2, 2);
    defer image.deinit(std.testing.allocator);

    // Set up a pattern: red, green, blue, white
    image.at(0, 0).* = Rgb.red;
    image.at(0, 1).* = Rgb.green;
    image.at(1, 0).* = Rgb.blue;
    image.at(1, 1).* = Rgb.white;

    // Test that format function works without error
    var buffer: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    // Force ANSI format for testing
    try std.fmt.format(stream.writer(), "{f}", .{image.display(.ansi_basic)});
    const result = stream.getWritten();

    // The expected output should be:
    // Row 0: red_bg + green_bg + newline
    // Row 1: blue_bg + white_bg
    const expected = "\x1b[48;2;255;0;0m \x1b[0m\x1b[48;2;0;255;0m \x1b[0m\n\x1b[48;2;0;0;255m \x1b[0m\x1b[48;2;255;255;255m \x1b[0m";

    try expectEqualStrings(expected, result);
}

test "image format ansi_blocks" {
    const Rgb = color.Rgb;

    // Create a small 2x2 RGB image
    var image = try Image(Rgb).initAlloc(std.testing.allocator, 2, 2);
    defer image.deinit(std.testing.allocator);

    // Set up a pattern: red, green, blue, white
    image.at(0, 0).* = Rgb.red;
    image.at(0, 1).* = Rgb.green;
    image.at(1, 0).* = Rgb.blue;
    image.at(1, 1).* = Rgb.white;

    // Test ansi_blocks format
    var buffer: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try std.fmt.format(stream.writer(), "{f}", .{image.display(.ansi_blocks)});
    const result = stream.getWritten();

    // The expected output should combine two rows into one using half-block character
    // First char: upper=red (fg), lower=blue (bg) with ▀
    // Second char: upper=green (fg), lower=white (bg) with ▀
    const expected = "\x1b[38;2;255;0;0;48;2;0;0;255m▀\x1b[0m\x1b[38;2;0;255;0;48;2;255;255;255m▀\x1b[0m";

    try expectEqualStrings(expected, result);
}

test "image format ansi_blocks odd rows" {
    const Rgb = color.Rgb;

    // Create a 3x2 RGB image (odd number of rows)
    var image = try Image(Rgb).initAlloc(std.testing.allocator, 3, 2);
    defer image.deinit(std.testing.allocator);

    // Set up colors
    image.at(0, 0).* = Rgb.red;
    image.at(0, 1).* = Rgb.green;
    image.at(1, 0).* = Rgb.blue;
    image.at(1, 1).* = Rgb.white;
    image.at(2, 0).* = Rgb.black;
    image.at(2, 1).* = Rgb{ .r = 128, .g = 128, .b = 128 }; // gray

    // Test ansi_blocks format with odd rows
    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try std.fmt.format(stream.writer(), "{f}", .{image.display(.ansi_blocks)});
    const result = stream.getWritten();

    // Expected: 2 lines (3 rows compressed to 2 using half-blocks)
    // Line 1: red/blue, green/white
    // Line 2: black/black, gray/gray (last row repeated for odd case)
    const expected = "\x1b[38;2;255;0;0;48;2;0;0;255m▀\x1b[0m\x1b[38;2;0;255;0;48;2;255;255;255m▀\x1b[0m\n" ++
        "\x1b[38;2;0;0;0;48;2;0;0;0m▀\x1b[0m\x1b[38;2;128;128;128;48;2;128;128;128m▀\x1b[0m";

    try expectEqualStrings(expected, result);
}

test "image format braille" {
    const Rgb = color.Rgb;

    // Create a 4x4 RGB image (perfect for one Braille character)
    var image = try Image(Rgb).initAlloc(std.testing.allocator, 4, 2);
    defer image.deinit(std.testing.allocator);

    // Create a diagonal pattern
    // ■ □
    // □ ■
    // ■ □
    // □ ■
    image.at(0, 0).* = Rgb.black;
    image.at(0, 1).* = Rgb.white;
    image.at(1, 0).* = Rgb.white;
    image.at(1, 1).* = Rgb.black;
    image.at(2, 0).* = Rgb.black;
    image.at(2, 1).* = Rgb.white;
    image.at(3, 0).* = Rgb.white;
    image.at(3, 1).* = Rgb.black;

    // Test braille format with default threshold
    var buffer: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try std.fmt.format(stream.writer(), "{f}", .{image.display(.{ .braille = .default })});
    const result = stream.getWritten();

    // Expected pattern: dots 2, 4, 6, 8 are on (white pixels)
    // Bit positions: 1, 3, 5, 7
    // Bit pattern: 10101010 = 0xAA
    // Unicode: 0x2800 + 0xAA = 0x28AA = ⡪
    const expected = "⡪";

    try expectEqualStrings(expected, result);
}

test "image format braille custom threshold" {
    const Rgb = color.Rgb;

    // Create a 4x2 grayscale gradient image
    var image = try Image(Rgb).initAlloc(std.testing.allocator, 4, 2);
    defer image.deinit(std.testing.allocator);

    // Create a gradient from black to white
    image.at(0, 0).* = Rgb{ .r = 0, .g = 0, .b = 0 }; // 0%
    image.at(0, 1).* = Rgb{ .r = 64, .g = 64, .b = 64 }; // 25%
    image.at(1, 0).* = Rgb{ .r = 96, .g = 96, .b = 96 }; // 38%
    image.at(1, 1).* = Rgb{ .r = 128, .g = 128, .b = 128 }; // 50%
    image.at(2, 0).* = Rgb{ .r = 160, .g = 160, .b = 160 }; // 63%
    image.at(2, 1).* = Rgb{ .r = 192, .g = 192, .b = 192 }; // 75%
    image.at(3, 0).* = Rgb{ .r = 224, .g = 224, .b = 224 }; // 88%
    image.at(3, 1).* = Rgb{ .r = 255, .g = 255, .b = 255 }; // 100%

    // Test with threshold 0.3 (should turn on pixels > 30% brightness)
    var buffer: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try std.fmt.format(stream.writer(), "{f}", .{image.display(.{ .braille = .{ .threshold = 0.3 } })});
    const result = stream.getWritten();

    // Expected: pixels with >30% brightness are on
    // That's positions: (1,0)=38%, (1,1)=50%, (2,0)=63%, (2,1)=75%, (3,0)=88%, (3,1)=100%
    // Dots on: 2, 5, 3, 6, 7, 8 (bits 1, 4, 2, 5, 6, 7)
    // Bit pattern: 11110110 = 0xF6
    // Unicode: 0x2800 + 0xF6 = 0x28F6 = ⣶
    const expected = "⣶";

    try expectEqualStrings(expected, result);
}

test "image format braille large image" {
    const Rgb = color.Rgb;

    // Create an 8x4 image (2x2 Braille characters)
    var image = try Image(Rgb).initAlloc(std.testing.allocator, 8, 4);
    defer image.deinit(std.testing.allocator);

    // Fill with checkerboard pattern
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            if ((r + c) % 2 == 0) {
                image.at(r, c).* = Rgb.white;
            } else {
                image.at(r, c).* = Rgb.black;
            }
        }
    }

    // Test braille format
    var buffer: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    try std.fmt.format(stream.writer(), "{f}", .{image.display(.{ .braille = .default })});
    const result = stream.getWritten();

    // Expected: checkerboard pattern creates same pattern in all blocks
    // Each 4x2 block has pattern:
    // W B -> dots 1,3,5,7 on (bits 0,2,4,6) = 01010101 = 0x55 = ⢕
    // B W
    // W B
    // B W
    // All blocks have the same pattern because checkerboard is regular
    const expected = "⢕⢕\n⢕⢕";

    try expectEqualStrings(expected, result);
}
