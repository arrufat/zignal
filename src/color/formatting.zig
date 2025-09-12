//! Shared formatting utilities for color types.
//!
//! Provides SGR terminal color formatting for all color types, allowing colors to be
//! displayed with their actual color as background in terminal output.

const std = @import("std");
const expectEqualStrings = std.testing.expectEqualStrings;

const convertColor = @import("conversions.zig").convertColor;
const Hsl = @import("Hsl.zig");
const Rgb = @import("Rgb.zig");

pub fn formatColor(
    comptime T: type,
    self: T,
    writer: *std.Io.Writer,
) !void {

    // Get the short type name
    const type_name = comptime blk: {
        const full_name = @typeName(T);
        if (std.mem.lastIndexOf(u8, full_name, ".")) |pos| {
            break :blk full_name[pos + 1 ..];
        }
        break :blk full_name;
    };

    // Convert to RGB for terminal display using the generic conversion function
    const rgb = convertColor(Rgb, self);

    // Determine text color based on background darkness
    const fg: u8 = if (rgb.toOklab().l < 0.5) 255 else 0;

    // Start with the SGR sequence
    try writer.print(
        "\x1b[1m\x1b[38;2;{d};{d};{d}m\x1b[48;2;{d};{d};{d}m{s}{{ ",
        .{ fg, fg, fg, rgb.r, rgb.g, rgb.b, type_name },
    );

    // Print each field
    const fields = std.meta.fields(T);
    inline for (fields, 0..) |field, i| {
        try writer.print(".{s} = ", .{field.name});

        // Format the field value appropriately
        const value = @field(self, field.name);
        switch (field.type) {
            u8 => try writer.print("{d}", .{value}),
            f64 => try writer.print("{d:.2}", .{value}), // 2 decimal places for floats
            else => try writer.print("{any}", .{value}),
        }

        if (i < fields.len - 1) {
            try writer.print(", ", .{});
        }
    }

    // Close and reset
    try writer.print(" }}\x1b[0m", .{});
}

// Tests for color formatting functionality
test "RGB color formatting - plain text with {any}" {
    const red = Rgb{ .r = 255, .g = 0, .b = 0 };
    const green = Rgb{ .r = 0, .g = 255, .b = 0 };
    const blue = Rgb{ .r = 0, .g = 0, .b = 255 };

    var buffer: [256]u8 = undefined;

    // Test red color plain formatting with {any}
    const result_red = try std.fmt.bufPrint(&buffer, "{any}", .{red});
    const expected_red = ".{ .r = 255, .g = 0, .b = 0 }";
    try expectEqualStrings(expected_red, result_red);

    // Test green color
    const result_green = try std.fmt.bufPrint(&buffer, "{any}", .{green});
    const expected_green = ".{ .r = 0, .g = 255, .b = 0 }";
    try expectEqualStrings(expected_green, result_green);

    // Test blue color
    const result_blue = try std.fmt.bufPrint(&buffer, "{any}", .{blue});
    const expected_blue = ".{ .r = 0, .g = 0, .b = 255 }";
    try expectEqualStrings(expected_blue, result_blue);
}

test "RGB color formatting - SGR color output" {
    const red = Rgb{ .r = 255, .g = 0, .b = 0 };
    const dark_color = Rgb{ .r = 50, .g = 50, .b = 50 };
    const light_color = Rgb{ .r = 200, .g = 200, .b = 200 };

    var buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);

    // Test SGR color formatting with {f}
    try stream.print("{f}", .{red});
    const result_red = buffer[0..stream.end];

    // Should contain specific SGR  sequences and content
    const expected_red = "\x1b[1m\x1b[38;2;255;255;255m\x1b[48;2;255;0;0mRgb{ .r = 255, .g = 0, .b = 0 }\x1b[0m";
    try expectEqualStrings(expected_red, result_red);

    // Test dark color (should use light text)
    stream.end = 0;
    try stream.print("{f}", .{dark_color});
    const result_dark = buffer[0..stream.end];
    const expected_dark = "\x1b[1m\x1b[38;2;255;255;255m\x1b[48;2;50;50;50mRgb{ .r = 50, .g = 50, .b = 50 }\x1b[0m";
    try expectEqualStrings(expected_dark, result_dark);

    // Test light color (should use dark text)
    stream.end = 0;
    try stream.print("{f}", .{light_color});
    const result_light = buffer[0..stream.end];
    const expected_light = "\x1b[1m\x1b[38;2;0;0;0m\x1b[48;2;200;200;200mRgb{ .r = 200, .g = 200, .b = 200 }\x1b[0m";
    try expectEqualStrings(expected_light, result_light);
}

test "HSL color formatting - plain text with {any}" {
    const red_hsl = Hsl{ .h = 0, .s = 100, .l = 50 };
    const green_hsl = Hsl{ .h = 120, .s = 100, .l = 50 };
    const blue_hsl = Hsl{ .h = 240, .s = 100, .l = 50 };

    var buffer: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);

    // Test red HSL color plain formatting with {any}
    try stream.print("{any}", .{red_hsl});
    const result_red = buffer[0..stream.end];
    const expected_red = ".{ .h = 0, .s = 100, .l = 50 }";
    try expectEqualStrings(expected_red, result_red);

    // Test green HSL color
    stream.end = 0;
    try stream.print("{any}", .{green_hsl});
    const result_green = buffer[0..stream.end];
    const expected_green = ".{ .h = 120, .s = 100, .l = 50 }";
    try expectEqualStrings(expected_green, result_green);

    // Test blue HSL color
    stream.end = 0;
    try stream.print("{any}", .{blue_hsl});
    const result_blue = buffer[0..stream.end];
    const expected_blue = ".{ .h = 240, .s = 100, .l = 50 }";
    try expectEqualStrings(expected_blue, result_blue);
}

test "HSL color formatting - SGR  color output" {
    const red_hsl = Hsl{ .h = 0, .s = 100, .l = 50 };
    const dark_hsl = Hsl{ .h = 0, .s = 0, .l = 20 }; // Dark gray
    const light_hsl = Hsl{ .h = 0, .s = 0, .l = 80 }; // Light gray

    var buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);

    // Test SGR  color formatting with HSL color using {f}
    try stream.print("{f}", .{red_hsl});
    const result_red = buffer[0..stream.end];

    // Should contain specific SGR  sequences and HSL content
    const expected_red = "\x1b[1m\x1b[38;2;255;255;255m\x1b[48;2;255;0;0mHsl{ .h = 0.00, .s = 100.00, .l = 50.00 }\x1b[0m";
    try expectEqualStrings(expected_red, result_red);

    // Test dark HSL color (should use light text)
    stream.end = 0;
    try stream.print("{f}", .{dark_hsl});
    const result_dark = buffer[0..stream.end];
    const expected_dark = "\x1b[1m\x1b[38;2;255;255;255m\x1b[48;2;51;51;51mHsl{ .h = 0.00, .s = 0.00, .l = 20.00 }\x1b[0m";
    try expectEqualStrings(expected_dark, result_dark);

    // Test light HSL color (should use dark text)
    stream.end = 0;
    try stream.print("{f}", .{light_hsl});
    const result_light = buffer[0..stream.end];
    const expected_light = "\x1b[1m\x1b[38;2;0;0;0m\x1b[48;2;204;204;204mHsl{ .h = 0.00, .s = 0.00, .l = 80.00 }\x1b[0m";
    try expectEqualStrings(expected_light, result_light);
}

test "formatColor function edge cases" {
    var buffer: [512]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);

    // Test color with zero values
    const zero_color = Rgb{ .r = 0, .g = 0, .b = 0 };
    try stream.print("{f}", .{zero_color});
    const result_zero = buffer[0..stream.end];
    const expected_zero = "\x1b[1m\x1b[38;2;255;255;255m\x1b[48;2;0;0;0mRgb{ .r = 0, .g = 0, .b = 0 }\x1b[0m";
    try expectEqualStrings(expected_zero, result_zero);

    // Test color with max values
    stream.end = 0;
    const max_color = Rgb{ .r = 255, .g = 255, .b = 255 };
    try stream.print("{f}", .{max_color});
    const result_max = buffer[0..stream.end];
    const expected_max = "\x1b[1m\x1b[38;2;0;0;0m\x1b[48;2;255;255;255mRgb{ .r = 255, .g = 255, .b = 255 }\x1b[0m";
    try expectEqualStrings(expected_max, result_max);

    // Test with {any} format (should be plain text)
    stream.end = 0;
    try stream.print("{any}", .{max_color});
    const result_plain = buffer[0..stream.end];
    const expected_plain = ".{ .r = 255, .g = 255, .b = 255 }";
    try expectEqualStrings(expected_plain, result_plain);
}
