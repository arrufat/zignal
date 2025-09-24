const std = @import("std");
const assert = std.debug.assert;

const Image = @import("../image.zig").Image;
const meta = @import("../meta.zig");
const as = meta.as;

/// Integral image (summed-area table) operations for fast box filtering.
/// Provides O(1) computation of rectangular region sums after O(n) preprocessing.
/// Computes the integral image (summed-area table) from a source image.
/// The integral image allows O(1) computation of rectangular region sums.
///
/// After building the integral image:
/// - sat[r,c] = sum of all pixels in rectangle from (0,0) to (r,c) inclusive
/// - Rectangle sum from (r1,c1) to (r2,c2) = sat[r2,c2] - sat[r1-1,c2] - sat[r2,c1-1] + sat[r1-1,c1-1]
///
/// Uses SIMD optimization for the column-wise accumulation pass.
pub fn integralPlane(comptime SrcT: type, src_img: Image(SrcT), dst_img: Image(f32)) void {
    assert(src_img.rows == dst_img.rows and src_img.cols == dst_img.cols);

    const rows = src_img.rows;
    const cols = src_img.cols;
    const simd_len = std.simd.suggestVectorLength(f32) orelse 1;

    // First pass: compute row-wise cumulative sums
    for (0..rows) |r| {
        var tmp: f32 = 0;
        const src_row_offset = r * src_img.stride;
        const dst_row_offset = r * dst_img.stride; // equals cols
        for (0..cols) |c| {
            tmp += as(f32, src_img.data[src_row_offset + c]);
            dst_img.data[dst_row_offset + c] = tmp;
        }
    }

    // Second pass: add column-wise cumulative sums using SIMD over packed dst
    for (1..rows) |r| {
        const prev_row_offset = (r - 1) * dst_img.stride;
        const curr_row_offset = r * dst_img.stride;
        var c: usize = 0;

        // Process SIMD-width chunks
        while (c + simd_len <= cols) : (c += simd_len) {
            const prev_vec: @Vector(simd_len, f32) = dst_img.data[prev_row_offset + c ..][0..simd_len].*;
            const curr_vec: @Vector(simd_len, f32) = dst_img.data[curr_row_offset + c ..][0..simd_len].*;
            const sum_vec = prev_vec + curr_vec;
            dst_img.data[curr_row_offset + c ..][0..simd_len].* = sum_vec;
        }

        // Process remaining elements
        while (c < cols) : (c += 1) {
            dst_img.data[curr_row_offset + c] += dst_img.data[prev_row_offset + c];
        }
    }
}

/// Computes the sum of pixels in a rectangular region using the integral image.
/// The rectangle is defined by (r1, c1) as top-left and (r2, c2) as bottom-right, inclusive.
///
/// Formula: sum = sat[r2,c2] - sat[r1-1,c2] - sat[r2,c1-1] + sat[r1-1,c1-1]
/// Handles boundary conditions when r1=0 or c1=0.
pub fn computeIntegralSum(sat: Image(f32), r1: usize, c1: usize, r2: usize, c2: usize) f32 {
    return sat.data[r2 * sat.stride + c2] -
        (if (c1 > 0) sat.data[r2 * sat.stride + (c1 - 1)] else 0) -
        (if (r1 > 0) sat.data[(r1 - 1) * sat.stride + c2] else 0) +
        (if (r1 > 0 and c1 > 0) sat.data[(r1 - 1) * sat.stride + (c1 - 1)] else 0);
}

/// Computes the sum of pixels in a rectangular region for multi-channel images.
/// Similar to computeIntegralSum but operates on a specific channel of a multi-channel integral image.
pub fn computeIntegralSumMultiChannel(sat: anytype, r1: usize, c1: usize, r2: usize, c2: usize, channel: usize) f32 {
    return (if (r2 < sat.rows and c2 < sat.cols) sat.at(r2, c2)[channel] else 0) -
        (if (r2 < sat.rows and c1 > 0) sat.at(r2, c1 - 1)[channel] else 0) -
        (if (r1 > 0 and c2 < sat.cols) sat.at(r1 - 1, c2)[channel] else 0) +
        (if (r1 > 0 and c1 > 0) sat.at(r1 - 1, c1 - 1)[channel] else 0);
}
