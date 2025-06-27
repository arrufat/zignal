//! Shared formatting utilities for color types.
//! 
//! Provides ANSI terminal color formatting for all color types, allowing colors to be
//! displayed with their actual color as background in terminal output.

const std = @import("std");

pub fn formatColor(
    comptime T: type,
    self: T,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;

    // Get the short type name
    const type_name = comptime blk: {
        const full_name = @typeName(T);
        if (std.mem.lastIndexOf(u8, full_name, ".")) |pos| {
            break :blk full_name[pos + 1 ..];
        }
        break :blk full_name;
    };

    // Check if we should use ANSI colors
    const use_ansi = comptime std.mem.eql(u8, fmt, "ansi") or std.mem.eql(u8, fmt, "color");

    if (use_ansi) {
        // Convert to RGB for terminal display - this assumes the type has a toRgb() method
        const rgb = if (@hasDecl(T, "toRgb")) self.toRgb() else self;

        // Determine text color based on background darkness
        const fg: u8 = if (shouldUseLightText(rgb)) 255 else 0;

        // Start with ANSI escape codes
        try writer.print(
            "\x1b[1m\x1b[38;2;{};{};{}m\x1b[48;2;{};{};{}m{s}{{ ",
            .{ fg, fg, fg, rgb.r, rgb.g, rgb.b, type_name },
        );
    } else {
        // Plain text format
        try writer.print("{s}{{ ", .{type_name});
    }

    // Print each field
    const fields = std.meta.fields(T);
    inline for (fields, 0..) |field, i| {
        try writer.print(".{s} = ", .{field.name});

        // Format the field value appropriately
        const value = @field(self, field.name);
        switch (field.type) {
            u8 => try writer.print("{}", .{value}),
            f64 => try writer.print("{d:.2}", .{value}), // 2 decimal places for floats
            else => try writer.print("{}", .{value}),
        }

        if (i < fields.len - 1) {
            try writer.print(", ", .{});
        }
    }

    // Close and reset
    if (use_ansi) {
        try writer.print(" }}\x1b[0m", .{});
    } else {
        try writer.print(" }}", .{});
    }
}

fn shouldUseLightText(rgb: anytype) bool {
    const luma = if (@hasDecl(@TypeOf(rgb), "luma")) 
        rgb.luma() 
    else 
        // Fallback calculation
        (@as(f64, @floatFromInt(rgb.r)) * 0.2126 + 
         @as(f64, @floatFromInt(rgb.g)) * 0.7152 + 
         @as(f64, @floatFromInt(rgb.b)) * 0.0722) / 255;
    
    return luma < 0.5;
}