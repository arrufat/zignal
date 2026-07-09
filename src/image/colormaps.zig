//! Colormap implementations for visualization.
//!
//! This module provides various colormaps to map scalar values to RGB colors.
//! Supported maps include:
//! - Jet: The classic blue-cyan-yellow-red map (ported from dlib).
//! - Heat: A black-red-yellow-white heatmap (ported from dlib).
//! - Turbo: An improved rainbow colormap by Google (LUT based).
//! - Viridis: A perceptually uniform colormap (matplotlib default, LUT based).
//! - Inferno: A perceptually uniform black-purple-orange-yellow colormap (LUT based).

const std = @import("std");
const math = std.math;
const testing = std.testing;
const meta = @import("../meta.zig");

const Image = @import("../image.zig").Image;

const Rgb = @import("../color.zig").Rgb(u8);

/// Defines the available colormaps and their optional range parameters.
pub const Colormap = union(enum) {
    /// The classic "jet" colormap (blue-cyan-yellow-red).
    jet: Range,
    /// A "heat" colormap (black-red-yellow-white).
    heat: Range,
    /// The "turbo" colormap (an improved, perceptually smoother rainbow).
    turbo: Range,
    /// The "viridis" colormap (perceptually uniform, colorblind-friendly).
    viridis: Range,
    /// The "inferno" colormap (perceptually uniform, black-purple-orange-yellow).
    inferno: Range,

    pub const Range = struct {
        /// Minimum value of the range (mapped to the start of the colormap).
        /// If null, the image's minimum value will be used.
        min: ?f64 = null,
        /// Maximum value of the range (mapped to the end of the colormap).
        /// If null, the image's maximum value will be used.
        max: ?f64 = null,
    };
};

/// Maps a scalar value to a color using the "jet" colormap.
/// Logic ported from dlib.
pub fn jet(value: f64, min_val: f64, max_val: f64) Rgb {
    const t = meta.normalize(f64, value, min_val, max_val);
    const index: usize = @round(t * 255.0);
    const color = jet_lut[index];
    return .{ .r = color[0], .g = color[1], .b = color[2] };
}

/// Maps a scalar value to a color using the "heat" colormap.
/// Logic ported from dlib.
pub fn heat(value: f64, min_val: f64, max_val: f64) Rgb {
    const t = meta.normalize(f64, value, min_val, max_val);
    const index: usize = @round(t * 255.0);
    const color = heat_lut[index];
    return .{ .r = color[0], .g = color[1], .b = color[2] };
}

/// Maps a scalar value to a color using the "turbo" colormap.
/// Uses a 256-entry lookup table generated at comptime.
pub fn turbo(value: f64, min_val: f64, max_val: f64) Rgb {
    const t = meta.normalize(f64, value, min_val, max_val);
    const index: usize = @round(t * 255.0);
    const color = turbo_lut[index];
    return .{ .r = color[0], .g = color[1], .b = color[2] };
}

/// Maps a scalar value to a color using the "viridis" colormap.
/// Uses a 256-entry lookup table.
pub fn viridis(value: f64, min_val: f64, max_val: f64) Rgb {
    const t = meta.normalize(f64, value, min_val, max_val);
    const index: usize = @round(t * 255.0);
    const color = viridis_lut[index];
    return .{ .r = color[0], .g = color[1], .b = color[2] };
}

/// Maps a scalar value to a color using the "inferno" colormap.
/// Uses a 256-entry lookup table.
pub fn inferno(value: f64, min_val: f64, max_val: f64) Rgb {
    const t = meta.normalize(f64, value, min_val, max_val);
    const index: usize = @round(t * 255.0);
    const color = inferno_lut[index];
    return .{ .r = color[0], .g = color[1], .b = color[2] };
}

// ============================================================================
// LUT Generation
// ============================================================================

fn jetEval(t: f64) [3]u8 {
    const gray = 8.0 * t;
    const s = 1.0 / 2.0;

    var r: u8 = 0;
    var g: u8 = 0;
    var b: u8 = 0;

    if (gray <= 1) {
        r = 0;
        g = 0;
        b = @round((gray + 1) * s * 255.0);
    } else if (gray <= 3) {
        r = 0;
        g = @round((gray - 1) * s * 255.0);
        b = 255;
    } else if (gray <= 5) {
        r = @round((gray - 3) * s * 255.0);
        g = 255;
        b = @round((5 - gray) * s * 255.0);
    } else if (gray <= 7) {
        r = 255;
        g = @round((7 - gray) * s * 255.0);
        b = 0;
    } else {
        r = @round((9 - gray) * s * 255.0);
        g = 0;
        b = 0;
    }
    return .{ r, g, b };
}

const jet_lut = blk: {
    @setEvalBranchQuota(5000);
    var lut: [256][3]u8 = undefined;
    for (0..256) |i| {
        lut[i] = jetEval(@as(f64, @floatFromInt(i)) / 255.0);
    }
    break :blk lut;
};

fn heatEval(t: f64) [3]u8 {
    const r: u8 = @round(@min(t / 0.4, 1.0) * 255.0);
    var g: u8 = 0;
    var b: u8 = 0;

    if (t > 0.4) {
        g = @round(@min((t - 0.4) / 0.4, 1.0) * 255.0);
    }
    if (t > 0.8) {
        b = @round(@min((t - 0.8) / 0.2, 1.0) * 255.0);
    }
    return .{ r, g, b };
}

const heat_lut = blk: {
    @setEvalBranchQuota(5000);
    var lut: [256][3]u8 = undefined;
    for (0..256) |i| {
        lut[i] = heatEval(@as(f64, @floatFromInt(i)) / 255.0);
    }
    break :blk lut;
};

fn turboEval(t: f64) [3]u8 {
    // Polynomial approximation coefficients from Google
    // https://gist.github.com/mikhailov-work/0d177465a8151be6ede748bc5b38297f
    const r_coeffs = @Vector(6, f64){ 0.13572138, 4.61539260, -42.66032258, 132.13108234, -152.94239396, 59.28637943 };
    const g_coeffs = @Vector(6, f64){ 0.09140261, 2.19418839, 4.84296658, -14.18503333, 4.27729857, 2.82956604 };
    const b_coeffs = @Vector(6, f64){ 0.10667330, 12.64194608, -60.58204836, 110.36276771, -89.90310912, 27.34824973 };

    const t2 = t * t;
    const t3 = t2 * t;
    const t4 = t3 * t;
    const t5 = t4 * t;
    const v = @Vector(6, f64){ 1.0, t, t2, t3, t4, t5 };

    // dot product equivalent
    const r_val = @reduce(.Add, v * r_coeffs);
    const g_val = @reduce(.Add, v * g_coeffs);
    const b_val = @reduce(.Add, v * b_coeffs);

    return .{
        @round(math.clamp(r_val, 0.0, 1.0) * 255.0),
        @round(math.clamp(g_val, 0.0, 1.0) * 255.0),
        @round(math.clamp(b_val, 0.0, 1.0) * 255.0),
    };
}

// Generated using matplotlib.colormaps['turbo']
const turbo_lut = blk: {
    @setEvalBranchQuota(5000);
    var lut: [256][3]u8 = undefined;
    for (0..256) |i| {
        lut[i] = turboEval(@as(f64, @floatFromInt(i)) / 255.0);
    }
    break :blk lut;
};

// Generated using matplotlib.colormaps['viridis']
const viridis_lut = [_][3]u8{
    .{ 68, 1, 84 },
    .{ 68, 2, 86 },
    .{ 69, 4, 87 },
    .{ 69, 5, 89 },
    .{ 70, 7, 90 },
    .{ 70, 8, 92 },
    .{ 70, 10, 93 },
    .{ 70, 11, 94 },
    .{ 71, 13, 96 },
    .{ 71, 14, 97 },
    .{ 71, 16, 99 },
    .{ 71, 17, 100 },
    .{ 71, 19, 101 },
    .{ 72, 20, 103 },
    .{ 72, 22, 104 },
    .{ 72, 23, 105 },
    .{ 72, 24, 106 },
    .{ 72, 26, 108 },
    .{ 72, 27, 109 },
    .{ 72, 28, 110 },
    .{ 72, 29, 111 },
    .{ 72, 31, 112 },
    .{ 72, 32, 113 },
    .{ 72, 33, 115 },
    .{ 72, 35, 116 },
    .{ 72, 36, 117 },
    .{ 72, 37, 118 },
    .{ 72, 38, 119 },
    .{ 72, 40, 120 },
    .{ 72, 41, 121 },
    .{ 71, 42, 122 },
    .{ 71, 44, 122 },
    .{ 71, 45, 123 },
    .{ 71, 46, 124 },
    .{ 71, 47, 125 },
    .{ 70, 48, 126 },
    .{ 70, 50, 126 },
    .{ 70, 51, 127 },
    .{ 70, 52, 128 },
    .{ 69, 53, 129 },
    .{ 69, 55, 129 },
    .{ 69, 56, 130 },
    .{ 68, 57, 131 },
    .{ 68, 58, 131 },
    .{ 68, 59, 132 },
    .{ 67, 61, 132 },
    .{ 67, 62, 133 },
    .{ 66, 63, 133 },
    .{ 66, 64, 134 },
    .{ 66, 65, 134 },
    .{ 65, 66, 135 },
    .{ 65, 68, 135 },
    .{ 64, 69, 136 },
    .{ 64, 70, 136 },
    .{ 63, 71, 136 },
    .{ 63, 72, 137 },
    .{ 62, 73, 137 },
    .{ 62, 74, 137 },
    .{ 62, 76, 138 },
    .{ 61, 77, 138 },
    .{ 61, 78, 138 },
    .{ 60, 79, 138 },
    .{ 60, 80, 139 },
    .{ 59, 81, 139 },
    .{ 59, 82, 139 },
    .{ 58, 83, 139 },
    .{ 58, 84, 140 },
    .{ 57, 85, 140 },
    .{ 57, 86, 140 },
    .{ 56, 88, 140 },
    .{ 56, 89, 140 },
    .{ 55, 90, 140 },
    .{ 55, 91, 141 },
    .{ 54, 92, 141 },
    .{ 54, 93, 141 },
    .{ 53, 94, 141 },
    .{ 53, 95, 141 },
    .{ 52, 96, 141 },
    .{ 52, 97, 141 },
    .{ 51, 98, 141 },
    .{ 51, 99, 141 },
    .{ 50, 100, 142 },
    .{ 50, 101, 142 },
    .{ 49, 102, 142 },
    .{ 49, 103, 142 },
    .{ 49, 104, 142 },
    .{ 48, 105, 142 },
    .{ 48, 106, 142 },
    .{ 47, 107, 142 },
    .{ 47, 108, 142 },
    .{ 46, 109, 142 },
    .{ 46, 110, 142 },
    .{ 46, 111, 142 },
    .{ 45, 112, 142 },
    .{ 45, 113, 142 },
    .{ 44, 113, 142 },
    .{ 44, 114, 142 },
    .{ 44, 115, 142 },
    .{ 43, 116, 142 },
    .{ 43, 117, 142 },
    .{ 42, 118, 142 },
    .{ 42, 119, 142 },
    .{ 42, 120, 142 },
    .{ 41, 121, 142 },
    .{ 41, 122, 142 },
    .{ 41, 123, 142 },
    .{ 40, 124, 142 },
    .{ 40, 125, 142 },
    .{ 39, 126, 142 },
    .{ 39, 127, 142 },
    .{ 39, 128, 142 },
    .{ 38, 129, 142 },
    .{ 38, 130, 142 },
    .{ 38, 130, 142 },
    .{ 37, 131, 142 },
    .{ 37, 132, 142 },
    .{ 37, 133, 142 },
    .{ 36, 134, 142 },
    .{ 36, 135, 142 },
    .{ 35, 136, 142 },
    .{ 35, 137, 142 },
    .{ 35, 138, 141 },
    .{ 34, 139, 141 },
    .{ 34, 140, 141 },
    .{ 34, 141, 141 },
    .{ 33, 142, 141 },
    .{ 33, 143, 141 },
    .{ 33, 144, 141 },
    .{ 33, 145, 140 },
    .{ 32, 146, 140 },
    .{ 32, 146, 140 },
    .{ 32, 147, 140 },
    .{ 31, 148, 140 },
    .{ 31, 149, 139 },
    .{ 31, 150, 139 },
    .{ 31, 151, 139 },
    .{ 31, 152, 139 },
    .{ 31, 153, 138 },
    .{ 31, 154, 138 },
    .{ 30, 155, 138 },
    .{ 30, 156, 137 },
    .{ 30, 157, 137 },
    .{ 31, 158, 137 },
    .{ 31, 159, 136 },
    .{ 31, 160, 136 },
    .{ 31, 161, 136 },
    .{ 31, 161, 135 },
    .{ 31, 162, 135 },
    .{ 32, 163, 134 },
    .{ 32, 164, 134 },
    .{ 33, 165, 133 },
    .{ 33, 166, 133 },
    .{ 34, 167, 133 },
    .{ 34, 168, 132 },
    .{ 35, 169, 131 },
    .{ 36, 170, 131 },
    .{ 37, 171, 130 },
    .{ 37, 172, 130 },
    .{ 38, 173, 129 },
    .{ 39, 173, 129 },
    .{ 40, 174, 128 },
    .{ 41, 175, 127 },
    .{ 42, 176, 127 },
    .{ 44, 177, 126 },
    .{ 45, 178, 125 },
    .{ 46, 179, 124 },
    .{ 47, 180, 124 },
    .{ 49, 181, 123 },
    .{ 50, 182, 122 },
    .{ 52, 182, 121 },
    .{ 53, 183, 121 },
    .{ 55, 184, 120 },
    .{ 56, 185, 119 },
    .{ 58, 186, 118 },
    .{ 59, 187, 117 },
    .{ 61, 188, 116 },
    .{ 63, 188, 115 },
    .{ 64, 189, 114 },
    .{ 66, 190, 113 },
    .{ 68, 191, 112 },
    .{ 70, 192, 111 },
    .{ 72, 193, 110 },
    .{ 74, 193, 109 },
    .{ 76, 194, 108 },
    .{ 78, 195, 107 },
    .{ 80, 196, 106 },
    .{ 82, 197, 105 },
    .{ 84, 197, 104 },
    .{ 86, 198, 103 },
    .{ 88, 199, 101 },
    .{ 90, 200, 100 },
    .{ 92, 200, 99 },
    .{ 94, 201, 98 },
    .{ 96, 202, 96 },
    .{ 99, 203, 95 },
    .{ 101, 203, 94 },
    .{ 103, 204, 92 },
    .{ 105, 205, 91 },
    .{ 108, 205, 90 },
    .{ 110, 206, 88 },
    .{ 112, 207, 87 },
    .{ 115, 208, 86 },
    .{ 117, 208, 84 },
    .{ 119, 209, 83 },
    .{ 122, 209, 81 },
    .{ 124, 210, 80 },
    .{ 127, 211, 78 },
    .{ 129, 211, 77 },
    .{ 132, 212, 75 },
    .{ 134, 213, 73 },
    .{ 137, 213, 72 },
    .{ 139, 214, 70 },
    .{ 142, 214, 69 },
    .{ 144, 215, 67 },
    .{ 147, 215, 65 },
    .{ 149, 216, 64 },
    .{ 152, 216, 62 },
    .{ 155, 217, 60 },
    .{ 157, 217, 59 },
    .{ 160, 218, 57 },
    .{ 162, 218, 55 },
    .{ 165, 219, 54 },
    .{ 168, 219, 52 },
    .{ 170, 220, 50 },
    .{ 173, 220, 48 },
    .{ 176, 221, 47 },
    .{ 178, 221, 45 },
    .{ 181, 222, 43 },
    .{ 184, 222, 41 },
    .{ 186, 222, 40 },
    .{ 189, 223, 38 },
    .{ 192, 223, 37 },
    .{ 194, 223, 35 },
    .{ 197, 224, 33 },
    .{ 200, 224, 32 },
    .{ 202, 225, 31 },
    .{ 205, 225, 29 },
    .{ 208, 225, 28 },
    .{ 210, 226, 27 },
    .{ 213, 226, 26 },
    .{ 216, 226, 25 },
    .{ 218, 227, 25 },
    .{ 221, 227, 24 },
    .{ 223, 227, 24 },
    .{ 226, 228, 24 },
    .{ 229, 228, 25 },
    .{ 231, 228, 25 },
    .{ 234, 229, 26 },
    .{ 236, 229, 27 },
    .{ 239, 229, 28 },
    .{ 241, 229, 29 },
    .{ 244, 230, 30 },
    .{ 246, 230, 32 },
    .{ 248, 230, 33 },
    .{ 251, 231, 35 },
    .{ 253, 231, 37 },
};

// Generated using matplotlib.colormaps['inferno']
const inferno_lut = [_][3]u8{
    .{ 0, 0, 4 },
    .{ 1, 0, 5 },
    .{ 1, 1, 6 },
    .{ 1, 1, 8 },
    .{ 2, 1, 10 },
    .{ 2, 2, 12 },
    .{ 2, 2, 14 },
    .{ 3, 2, 16 },
    .{ 4, 3, 18 },
    .{ 4, 3, 20 },
    .{ 5, 4, 23 },
    .{ 6, 4, 25 },
    .{ 7, 5, 27 },
    .{ 8, 5, 29 },
    .{ 9, 6, 31 },
    .{ 10, 7, 34 },
    .{ 11, 7, 36 },
    .{ 12, 8, 38 },
    .{ 13, 8, 41 },
    .{ 14, 9, 43 },
    .{ 16, 9, 45 },
    .{ 17, 10, 48 },
    .{ 18, 10, 50 },
    .{ 20, 11, 52 },
    .{ 21, 11, 55 },
    .{ 22, 11, 57 },
    .{ 24, 12, 60 },
    .{ 25, 12, 62 },
    .{ 27, 12, 65 },
    .{ 28, 12, 67 },
    .{ 30, 12, 69 },
    .{ 31, 12, 72 },
    .{ 33, 12, 74 },
    .{ 35, 12, 76 },
    .{ 36, 12, 79 },
    .{ 38, 12, 81 },
    .{ 40, 11, 83 },
    .{ 41, 11, 85 },
    .{ 43, 11, 87 },
    .{ 45, 11, 89 },
    .{ 47, 10, 91 },
    .{ 49, 10, 92 },
    .{ 50, 10, 94 },
    .{ 52, 10, 95 },
    .{ 54, 9, 97 },
    .{ 56, 9, 98 },
    .{ 57, 9, 99 },
    .{ 59, 9, 100 },
    .{ 61, 9, 101 },
    .{ 62, 9, 102 },
    .{ 64, 10, 103 },
    .{ 66, 10, 104 },
    .{ 68, 10, 104 },
    .{ 69, 10, 105 },
    .{ 71, 11, 106 },
    .{ 73, 11, 106 },
    .{ 74, 12, 107 },
    .{ 76, 12, 107 },
    .{ 77, 13, 108 },
    .{ 79, 13, 108 },
    .{ 81, 14, 108 },
    .{ 82, 14, 109 },
    .{ 84, 15, 109 },
    .{ 85, 15, 109 },
    .{ 87, 16, 110 },
    .{ 89, 16, 110 },
    .{ 90, 17, 110 },
    .{ 92, 18, 110 },
    .{ 93, 18, 110 },
    .{ 95, 19, 110 },
    .{ 97, 19, 110 },
    .{ 98, 20, 110 },
    .{ 100, 21, 110 },
    .{ 101, 21, 110 },
    .{ 103, 22, 110 },
    .{ 105, 22, 110 },
    .{ 106, 23, 110 },
    .{ 108, 24, 110 },
    .{ 109, 24, 110 },
    .{ 111, 25, 110 },
    .{ 113, 25, 110 },
    .{ 114, 26, 110 },
    .{ 116, 26, 110 },
    .{ 117, 27, 110 },
    .{ 119, 28, 109 },
    .{ 120, 28, 109 },
    .{ 122, 29, 109 },
    .{ 124, 29, 109 },
    .{ 125, 30, 109 },
    .{ 127, 30, 108 },
    .{ 128, 31, 108 },
    .{ 130, 32, 108 },
    .{ 132, 32, 107 },
    .{ 133, 33, 107 },
    .{ 135, 33, 107 },
    .{ 136, 34, 106 },
    .{ 138, 34, 106 },
    .{ 140, 35, 105 },
    .{ 141, 35, 105 },
    .{ 143, 36, 105 },
    .{ 144, 37, 104 },
    .{ 146, 37, 104 },
    .{ 147, 38, 103 },
    .{ 149, 38, 103 },
    .{ 151, 39, 102 },
    .{ 152, 39, 102 },
    .{ 154, 40, 101 },
    .{ 155, 41, 100 },
    .{ 157, 41, 100 },
    .{ 159, 42, 99 },
    .{ 160, 42, 99 },
    .{ 162, 43, 98 },
    .{ 163, 44, 97 },
    .{ 165, 44, 96 },
    .{ 166, 45, 96 },
    .{ 168, 46, 95 },
    .{ 169, 46, 94 },
    .{ 171, 47, 94 },
    .{ 173, 48, 93 },
    .{ 174, 48, 92 },
    .{ 176, 49, 91 },
    .{ 177, 50, 90 },
    .{ 179, 50, 90 },
    .{ 180, 51, 89 },
    .{ 182, 52, 88 },
    .{ 183, 53, 87 },
    .{ 185, 53, 86 },
    .{ 186, 54, 85 },
    .{ 188, 55, 84 },
    .{ 189, 56, 83 },
    .{ 191, 57, 82 },
    .{ 192, 58, 81 },
    .{ 193, 58, 80 },
    .{ 195, 59, 79 },
    .{ 196, 60, 78 },
    .{ 198, 61, 77 },
    .{ 199, 62, 76 },
    .{ 200, 63, 75 },
    .{ 202, 64, 74 },
    .{ 203, 65, 73 },
    .{ 204, 66, 72 },
    .{ 206, 67, 71 },
    .{ 207, 68, 70 },
    .{ 208, 69, 69 },
    .{ 210, 70, 68 },
    .{ 211, 71, 67 },
    .{ 212, 72, 66 },
    .{ 213, 74, 65 },
    .{ 215, 75, 63 },
    .{ 216, 76, 62 },
    .{ 217, 77, 61 },
    .{ 218, 78, 60 },
    .{ 219, 80, 59 },
    .{ 221, 81, 58 },
    .{ 222, 82, 56 },
    .{ 223, 83, 55 },
    .{ 224, 85, 54 },
    .{ 225, 86, 53 },
    .{ 226, 87, 52 },
    .{ 227, 89, 51 },
    .{ 228, 90, 49 },
    .{ 229, 92, 48 },
    .{ 230, 93, 47 },
    .{ 231, 94, 46 },
    .{ 232, 96, 45 },
    .{ 233, 97, 43 },
    .{ 234, 99, 42 },
    .{ 235, 100, 41 },
    .{ 235, 102, 40 },
    .{ 236, 103, 38 },
    .{ 237, 105, 37 },
    .{ 238, 106, 36 },
    .{ 239, 108, 35 },
    .{ 239, 110, 33 },
    .{ 240, 111, 32 },
    .{ 241, 113, 31 },
    .{ 241, 115, 29 },
    .{ 242, 116, 28 },
    .{ 243, 118, 27 },
    .{ 243, 120, 25 },
    .{ 244, 121, 24 },
    .{ 245, 123, 23 },
    .{ 245, 125, 21 },
    .{ 246, 126, 20 },
    .{ 246, 128, 19 },
    .{ 247, 130, 18 },
    .{ 247, 132, 16 },
    .{ 248, 133, 15 },
    .{ 248, 135, 14 },
    .{ 248, 137, 12 },
    .{ 249, 139, 11 },
    .{ 249, 140, 10 },
    .{ 249, 142, 9 },
    .{ 250, 144, 8 },
    .{ 250, 146, 7 },
    .{ 250, 148, 7 },
    .{ 251, 150, 6 },
    .{ 251, 151, 6 },
    .{ 251, 153, 6 },
    .{ 251, 155, 6 },
    .{ 251, 157, 7 },
    .{ 252, 159, 7 },
    .{ 252, 161, 8 },
    .{ 252, 163, 9 },
    .{ 252, 165, 10 },
    .{ 252, 166, 12 },
    .{ 252, 168, 13 },
    .{ 252, 170, 15 },
    .{ 252, 172, 17 },
    .{ 252, 174, 18 },
    .{ 252, 176, 20 },
    .{ 252, 178, 22 },
    .{ 252, 180, 24 },
    .{ 251, 182, 26 },
    .{ 251, 184, 29 },
    .{ 251, 186, 31 },
    .{ 251, 188, 33 },
    .{ 251, 190, 35 },
    .{ 250, 192, 38 },
    .{ 250, 194, 40 },
    .{ 250, 196, 42 },
    .{ 250, 198, 45 },
    .{ 249, 199, 47 },
    .{ 249, 201, 50 },
    .{ 249, 203, 53 },
    .{ 248, 205, 55 },
    .{ 248, 207, 58 },
    .{ 247, 209, 61 },
    .{ 247, 211, 64 },
    .{ 246, 213, 67 },
    .{ 246, 215, 70 },
    .{ 245, 217, 73 },
    .{ 245, 219, 76 },
    .{ 244, 221, 79 },
    .{ 244, 223, 83 },
    .{ 244, 225, 86 },
    .{ 243, 227, 90 },
    .{ 243, 229, 93 },
    .{ 242, 230, 97 },
    .{ 242, 232, 101 },
    .{ 242, 234, 105 },
    .{ 241, 236, 109 },
    .{ 241, 237, 113 },
    .{ 241, 239, 117 },
    .{ 241, 241, 121 },
    .{ 242, 242, 125 },
    .{ 242, 244, 130 },
    .{ 243, 245, 134 },
    .{ 243, 246, 138 },
    .{ 244, 248, 142 },
    .{ 245, 249, 146 },
    .{ 246, 250, 150 },
    .{ 248, 251, 154 },
    .{ 249, 252, 157 },
    .{ 250, 253, 161 },
    .{ 252, 255, 164 },
};

test "colormaps" {
    const allocator = testing.allocator;
    // Create a horizontal gradient 0..255
    var gradient: Image(u8) = try .init(allocator, 1, 256);
    defer gradient.deinit(allocator);

    for (0..256) |i| {
        gradient.at(0, i).* = @intCast(i);
    }

    // Jet
    {
        var jet_img = try gradient.applyColormap(allocator, .{ .jet = .{} });
        defer jet_img.deinit(allocator);

        // Min (0) -> Dark Blue (0, 0, 128)
        // dlib logic: 0 -> gray=0. gray<=1 -> b = round((0+1)*0.5*255) = 128.
        try testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 128 }, jet_img.at(0, 0).*);

        // Mid (128) -> ~0.5 -> Green/Yellow
        // 128/255 * 8 = ~4.
        // gray=4 -> (4-3)*0.5*255 = 127.5 -> 128 (red). G=255. B=(5-4)*0.5*255 = 128.
        // So R=128, G=255, B=128. Light green?
        const mid = jet_img.at(0, 128).*;
        try testing.expect(mid.g == 255);

        // Max (255) -> Dark Red (128, 0, 0)
        try testing.expectEqual(Rgb{ .r = 128, .g = 0, .b = 0 }, jet_img.at(0, 255).*);
    }

    // Heat
    {
        var heat_img = try gradient.applyColormap(allocator, .{ .heat = .{} });
        defer heat_img.deinit(allocator);

        // 0 -> Black
        try testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, heat_img.at(0, 0).*);

        // 255 -> White
        try testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, heat_img.at(0, 255).*);
    }

    // Turbo
    {
        var turbo_img = try gradient.applyColormap(allocator, .{ .turbo = .{} });
        defer turbo_img.deinit(allocator);

        // 0 -> Roughly R=35, G=23, B=27 (from Polynomial)
        // coefficients[0] * 255
        const p0 = turbo_img.at(0, 0).*;
        try testing.expectApproxEqAbs(@as(f32, 35.0), @as(f32, p0.r), 1.0);
        try testing.expectApproxEqAbs(@as(f32, 23.0), @as(f32, p0.g), 1.0);
        try testing.expectApproxEqAbs(@as(f32, 27.0), @as(f32, p0.b), 1.0);

        // 255 -> Roughly R=144, G=13, B=0 (from Polynomial)
        const p255 = turbo_img.at(0, 255).*;
        // We use a larger tolerance for the end because summing coefficients might have error accumulation
        try testing.expectApproxEqAbs(@as(f32, 144.0), @as(f32, p255.r), 2.0);
        try testing.expectApproxEqAbs(@as(f32, 13.0), @as(f32, p255.g), 2.0);
        try testing.expectApproxEqAbs(@as(f32, 0.0), @as(f32, p255.b), 2.0);
    }

    // Viridis
    {
        var viridis_img = try gradient.applyColormap(allocator, .{ .viridis = .{} });
        defer viridis_img.deinit(allocator);

        // 0 -> 68, 1, 84
        try testing.expectEqual(Rgb{ .r = 68, .g = 1, .b = 84 }, viridis_img.at(0, 0).*);

        // 255 -> 253, 231, 37
        try testing.expectEqual(Rgb{ .r = 253, .g = 231, .b = 37 }, viridis_img.at(0, 255).*);
    }

    // Inferno
    {
        var inferno_img = try gradient.applyColormap(allocator, .{ .inferno = .{} });
        defer inferno_img.deinit(allocator);

        // 0 -> 0, 0, 4
        try testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 4 }, inferno_img.at(0, 0).*);

        // 255 -> 252, 255, 164
        try testing.expectEqual(Rgb{ .r = 252, .g = 255, .b = 164 }, inferno_img.at(0, 255).*);
    }

    // Explicit Range
    {
        // Gradient 0..255.
        // Map 0..128 (normalized 0..0.5) to colormap.
        // So 128 (0.5) maps to max (Dark Red in Jet).
        const max_val = 128.0 / 255.0;
        var jet_clamped = try gradient.applyColormap(allocator, .{ .jet = .{ .min = 0, .max = max_val } });
        defer jet_clamped.deinit(allocator);

        // 128 should be dark red
        try testing.expectEqual(Rgb{ .r = 128, .g = 0, .b = 0 }, jet_clamped.at(0, 128).*);

        // 255 should also be dark red (clamped)
        try testing.expectEqual(Rgb{ .r = 128, .g = 0, .b = 0 }, jet_clamped.at(0, 255).*);
    }
}

test "nan safety" {
    const nan = std.math.nan(f64);

    // These calls should not panic
    _ = jet(nan, 0, 1);
    _ = heat(nan, 0, 1);
    _ = turbo(nan, 0, 1);
    _ = viridis(nan, 0, 1);
    _ = inferno(nan, 0, 1);
}

test "colormap on view" {
    const allocator = testing.allocator;

    // Underlying image: 10x10, mostly 0, one 255
    var img = try Image(u8).init(allocator, 10, 10);
    defer img.deinit(allocator);
    img.fill(0);
    img.at(0, 0).* = 255;

    // View: 2x2 region where all pixels are 128
    var v = img.view(.{ .l = 4, .t = 4, .r = 6, .b = 6 });
    v.fill(128);

    // Applying colormap to the view should auto-detect min=128, max=128
    // If it was bugged and used [0, 255] from the underlying buffer,
    // 128 would map to 0.5 (Greenish).
    // If fixed, it auto-ranges to [128, 129], mapping 128 to 0.0 (Dark Blue).
    var vis = try v.applyColormap(allocator, .{ .jet = .{} });
    defer vis.deinit(allocator);

    // Jet at 0.0 -> (0, 0, 128)
    try testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 128 }, vis.at(0, 0).*);
}
