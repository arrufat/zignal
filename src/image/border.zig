//! Unified border handling utilities for image operations
//!
//! This module provides consistent border mode handling used by various
//! image processing operations like convolution and order statistic filters.

const std = @import("std");
const clamp = std.math.clamp;

/// Border handling modes for operations that access pixels outside image bounds
pub const BorderMode = enum {
    /// Pad with zeros
    zero,
    /// Replicate edge pixels
    replicate,
    /// Mirror at edges
    mirror,
    /// Wrap around (circular)
    wrap,
};

/// Computes border-adjusted coordinates for a given position and border mode.
/// Returns null when the result should be zero (out of bounds with .zero mode, or empty image).
///
/// Parameters:
/// - `row`: Row index (can be negative or >= rows)
/// - `col`: Column index (can be negative or >= cols)
/// - `rows`: Total number of rows in the image
/// - `cols`: Total number of columns in the image
/// - `border`: The border handling mode to apply
///
/// Returns:
/// - Adjusted coordinates within bounds, or null if pixel should be zero
pub fn computeCoords(
    row: isize,
    col: isize,
    rows: isize,
    cols: isize,
    border: BorderMode,
) ?struct { row: usize, col: usize } {
    const r = resolveIndex(row, rows, border) orelse return null;
    const c = resolveIndex(col, cols, border) orelse return null;
    return .{ .row = r, .col = c };
}

/// Convenience function to resolve a single dimension index with border handling.
/// Useful for 1D operations or when rows and columns are handled separately.
///
/// Parameters:
/// - `idx`: Index to resolve (can be negative or >= length)
/// - `length`: Total length of the dimension
/// - `border`: The border handling mode to apply
///
/// Returns:
/// - Adjusted index within bounds, or null if should be treated as zero
pub fn resolveIndex(idx: isize, length: isize, border: BorderMode) ?usize {
    return if (idx >= 0 and idx < length)
        @intCast(idx)
    else switch (border) {
        // For zero padding, out of bounds means 0 value (represented by null index)
        .zero => null,
        .replicate => if (length == 0) null else @intCast(clamp(idx, 0, length - 1)),
        .mirror => blk: {
            if (length <= 0) break :blk null;
            if (length == 1) break :blk 0;
            const period = 2 * (length - 1);
            const m = @mod(idx, period);
            const i = if (m < 0) m + period else m;
            break :blk @intCast(if (i >= length) period - i else i);
        },
        .wrap => if (length == 0) null else @intCast(@mod(idx, length)),
    };
}

test "resolveIndex basic" {
    const testing = std.testing;

    // Test in-bounds (fast path)
    try testing.expectEqual(@as(?usize, 5), resolveIndex(5, 10, .zero));
    try testing.expectEqual(@as(?usize, 5), resolveIndex(5, 10, .replicate));
    try testing.expectEqual(@as(?usize, 5), resolveIndex(5, 10, .mirror));
    try testing.expectEqual(@as(?usize, 5), resolveIndex(5, 10, .wrap));

    // Test zero length
    try testing.expectEqual(@as(?usize, null), resolveIndex(0, 0, .zero));
    try testing.expectEqual(@as(?usize, null), resolveIndex(0, 0, .replicate));
    try testing.expectEqual(@as(?usize, null), resolveIndex(0, 0, .mirror));
    try testing.expectEqual(@as(?usize, null), resolveIndex(0, 0, .wrap));
}

test "resolveIndex zero mode" {
    const testing = std.testing;
    const len: isize = 10;

    // Out of bounds negative
    try testing.expectEqual(@as(?usize, null), resolveIndex(-1, len, .zero));
    try testing.expectEqual(@as(?usize, null), resolveIndex(-5, len, .zero));

    // Out of bounds positive
    try testing.expectEqual(@as(?usize, null), resolveIndex(10, len, .zero));
    try testing.expectEqual(@as(?usize, null), resolveIndex(15, len, .zero));
}

test "resolveIndex replicate mode" {
    const testing = std.testing;
    const len: isize = 10;

    // Out of bounds negative -> 0
    try testing.expectEqual(@as(?usize, 0), resolveIndex(-1, len, .replicate));
    try testing.expectEqual(@as(?usize, 0), resolveIndex(-5, len, .replicate));

    // Out of bounds positive -> len-1 (9)
    try testing.expectEqual(@as(?usize, 9), resolveIndex(10, len, .replicate));
    try testing.expectEqual(@as(?usize, 9), resolveIndex(15, len, .replicate));
}

test "resolveIndex mirror mode" {
    const testing = std.testing;
    const len: isize = 5; // Indices: 0, 1, 2, 3, 4
    // Mirror pattern: 0 1 2 3 4 3 2 1 0 1 ...
    // Period = 2*(5-1) = 8

    // -1 -> 1
    try testing.expectEqual(@as(?usize, 1), resolveIndex(-1, len, .mirror));
    // -2 -> 2
    try testing.expectEqual(@as(?usize, 2), resolveIndex(-2, len, .mirror));
    // 5 -> 3
    try testing.expectEqual(@as(?usize, 3), resolveIndex(5, len, .mirror));
    // 6 -> 2
    try testing.expectEqual(@as(?usize, 2), resolveIndex(6, len, .mirror));

    // Test length 1
    try testing.expectEqual(@as(?usize, 0), resolveIndex(-1, 1, .mirror));
    try testing.expectEqual(@as(?usize, 0), resolveIndex(5, 1, .mirror));
}

test "resolveIndex wrap mode" {
    const testing = std.testing;
    const len: isize = 5;

    // -1 -> 4
    try testing.expectEqual(@as(?usize, 4), resolveIndex(-1, len, .wrap));
    // -6 -> 4
    try testing.expectEqual(@as(?usize, 4), resolveIndex(-6, len, .wrap));
    // 5 -> 0
    try testing.expectEqual(@as(?usize, 0), resolveIndex(5, len, .wrap));
    // 6 -> 1
    try testing.expectEqual(@as(?usize, 1), resolveIndex(6, len, .wrap));
}
