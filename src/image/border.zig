//! Unified border handling utilities for image operations
//!
//! This module provides consistent border mode handling used by various
//! image processing operations like convolution and order statistic filters.

const std = @import("std");

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
    switch (border) {
        .zero => {
            if (row < 0 or col < 0 or row >= rows or col >= cols) {
                return null;
            }
            return .{ .row = @intCast(row), .col = @intCast(col) };
        },
        .replicate => {
            const r = @max(0, @min(row, rows - 1));
            const c = @max(0, @min(col, cols - 1));
            return .{ .row = @intCast(r), .col = @intCast(c) };
        },
        .mirror => {
            if (rows == 0 or cols == 0) return null;
            var r = row;
            var c = col;
            // Handle negative row indices
            while (r < 0) {
                r = -r - 1;
                if (r >= rows) r = 2 * rows - r - 1;
            }
            // Handle row indices >= rows
            while (r >= rows) {
                r = 2 * rows - r - 1;
                if (r < 0) r = -r - 1;
            }
            // Handle negative column indices
            while (c < 0) {
                c = -c - 1;
                if (c >= cols) c = 2 * cols - c - 1;
            }
            // Handle column indices >= cols
            while (c >= cols) {
                c = 2 * cols - c - 1;
                if (c < 0) c = -c - 1;
            }
            return .{ .row = @intCast(r), .col = @intCast(c) };
        },
        .wrap => {
            const r = @mod(row, rows);
            const c = @mod(col, cols);
            return .{ .row = @intCast(r), .col = @intCast(c) };
        },
    }
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
    switch (border) {
        .zero => {
            if (idx < 0 or idx >= length) return null;
            return @intCast(idx);
        },
        .replicate => {
            if (length == 0) return null;
            const clamped = std.math.clamp(idx, 0, length - 1);
            return @intCast(clamped);
        },
        .mirror => {
            if (length == 0) return null;
            if (length == 1) return 0;
            var i = idx;
            const max = length - 1;
            while (i < 0 or i > max) {
                if (i < 0) {
                    i = -i - 1;
                } else {
                    i = 2 * length - i - 2;
                }
            }
            return @intCast(i);
        },
        .wrap => {
            if (length == 0) return null;
            const wrapped = @mod(idx, length);
            return @intCast(wrapped);
        },
    }
}
