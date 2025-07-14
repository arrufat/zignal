//! Matrix formatting utilities for both static and dynamic matrices

const std = @import("std");

/// Helper function to format numbers with fallback to scientific notation
fn formatNumber(comptime T: type, buf: []u8, comptime format_str: []const u8, value: T) []const u8 {
    return std.fmt.bufPrint(buf, format_str, .{value}) catch {
        // If formatting fails (number too large), try scientific notation
        return std.fmt.bufPrint(buf, "{any}", .{value}) catch {
            // If even scientific notation fails, use a fallback
            return "ERR";
        };
    };
}

/// Generic matrix formatting function that works with both SMatrix and Matrix
pub fn formatMatrix(matrix: anytype, comptime number_fmt: []const u8, writer: anytype) !void {
    const MatrixType = @TypeOf(matrix);

    // Matrix has allocator field, SMatrix doesn't
    const is_smatrix = !@hasField(MatrixType, "allocator");
    const rows = matrix.rows;
    const cols = matrix.cols;

    // First pass: calculate the maximum width needed for each column
    var col_widths_buffer: [256]usize = undefined;
    const max_cols = @min(cols, 256);
    var col_widths = col_widths_buffer[0..max_cols];
    @memset(col_widths, 0);

    for (0..rows) |r| {
        for (0..max_cols) |c| {
            // Create a temporary buffer to measure the width of this element
            var temp_buf: [64]u8 = undefined;
            const value = if (is_smatrix) matrix.items[r][c] else matrix.at(r, c).*;
            const formatted = formatNumber(@TypeOf(value), temp_buf[0..], number_fmt, value);
            col_widths[c] = @max(col_widths[c], formatted.len);
        }
    }

    // Second pass: format and write the matrix with proper alignment
    for (0..rows) |r| {
        try writer.writeAll("[ ");
        for (0..@min(cols, max_cols)) |c| {
            // Format the number
            var temp_buf: [64]u8 = undefined;
            const value = if (is_smatrix) matrix.items[r][c] else matrix.at(r, c).*;
            const formatted = formatNumber(@TypeOf(value), temp_buf[0..], number_fmt, value);

            // Right-align the number within the column width
            const padding = col_widths[c] -| formatted.len;
            for (0..padding) |_| {
                try writer.writeAll(" ");
            }
            try writer.writeAll(formatted);

            if (c < @min(cols, max_cols) - 1) {
                try writer.writeAll("  "); // Two spaces between columns
            }
        }
        if (cols > max_cols) {
            try writer.writeAll(" ...");
        }
        try writer.writeAll(" ]");
        if (r < rows - 1) {
            try writer.writeAll("\n");
        }
    }
}

/// Decimal formatter with specified precision
pub fn DecimalFormatter(comptime MatrixType: type, comptime precision: u8) type {
    return struct {
        const Self = @This();
        matrix: MatrixType,

        pub fn format(self: Self, writer: anytype) !void {
            const number_fmt = std.fmt.comptimePrint("{{d:.{d}}}", .{precision});
            try formatMatrix(self.matrix, number_fmt, writer);
        }
    };
}

/// Scientific notation formatter
pub fn ScientificFormatter(comptime MatrixType: type) type {
    return struct {
        const Self = @This();
        matrix: MatrixType,

        pub fn format(self: Self, writer: anytype) !void {
            try formatMatrix(self.matrix, "{e}", writer);
        }
    };
}

// Tests for formatting functionality
const expectEqualStrings = std.testing.expectEqualStrings;
const SMatrix = @import("SMatrix.zig").SMatrix;

test "static matrix format" {
    // Test 2x3 matrix with known values
    var m: SMatrix(f32, 2, 3) = .{};
    m.at(0, 0).* = 1.23;
    m.at(0, 1).* = -4.5;
    m.at(0, 2).* = 7.0;
    m.at(1, 0).* = 10.1;
    m.at(1, 1).* = 0.0;
    m.at(1, 2).* = -5.67;

    var buffer: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);

    // Test default formatting (scientific notation)
    try std.fmt.format(stream.writer(), "{f}", .{m});
    const result_default = stream.getWritten();
    const expected_default =
        \\[ 1.23e0  -4.5e0      7e0 ]
        \\[ 1.01e1     0e0  -5.67e0 ]
    ;
    try expectEqualStrings(expected_default, result_default);

    // Test decimal(2) formatting
    stream.reset();
    try std.fmt.format(stream.writer(), "{f}", .{m.decimal(2)});
    const result_decimal2 = stream.getWritten();
    const expected_decimal2 =
        \\[  1.23  -4.50   7.00 ]
        \\[ 10.10   0.00  -5.67 ]
    ;
    try expectEqualStrings(expected_decimal2, result_decimal2);

    // Test decimal(0) formatting
    stream.reset();
    try std.fmt.format(stream.writer(), "{f}", .{m.decimal(0)});
    const result_decimal0 = stream.getWritten();
    const expected_decimal0 =
        \\[  1  -5   7 ]
        \\[ 10   0  -6 ]
    ;
    try expectEqualStrings(expected_decimal0, result_decimal0);

    // Test scientific formatting
    stream.reset();
    try std.fmt.format(stream.writer(), "{f}", .{m.scientific()});
    const result_scientific = stream.getWritten();
    const expected_scientific =
        \\[ 1.23e0  -4.5e0      7e0 ]
        \\[ 1.01e1     0e0  -5.67e0 ]
    ;
    try expectEqualStrings(expected_scientific, result_scientific);
}