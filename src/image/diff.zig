const std = @import("std");
const meta = @import("../meta.zig");
const Image = @import("../image.zig").Image;
const RunningStats = @import("../stats.zig").RunningStats;

/// Options for computing image differences.
pub const DiffOptions = struct {
    /// Ignore differences smaller than this value.
    threshold: f32 = 0,
    /// Scale factor applied to the difference magnitude (for visualization).
    scale: f32 = 1.0,
    /// If true, output pixels are either 0 or MaxVal (white) based on threshold.
    binary: bool = false,
    /// If true and the image has an alpha channel, set it to MaxVal (opaque).
    force_opaque: bool = false,
};

/// Result of a difference operation.
pub const DiffResult = struct {
    stats: RunningStats(f64),
    diff_count: usize,
};

/// Computes the difference between two images per pixel/channel.
/// The result is stored in `out`, which must have the same dimensions.
/// Applies scaling, thresholding, and visualization options in a single pass.
pub fn compute(
    comptime T: type,
    img1: Image(T),
    img2: Image(T),
    out: Image(T),
    opts: DiffOptions,
) !DiffResult {
    if (!img1.hasSameShape(img2) or !img1.hasSameShape(out)) {
        return error.DimensionMismatch;
    }

    var stats: RunningStats(f64) = .init();
    var diff_count: usize = 0;

    for (0..img1.rows) |r| {
        for (0..img1.cols) |c| {
            const p1 = img1.at(r, c).*;
            const p2 = img2.at(r, c).*;
            const dest = out.at(r, c);

            switch (@typeInfo(T)) {
                .int => {
                    const d_raw = if (p1 > p2) p1 - p2 else p2 - p1;
                    const d_float = @as(f32, @floatFromInt(d_raw));

                    if (d_float > opts.threshold) diff_count += 1;

                    var val_out: T = 0;
                    if (opts.binary) {
                        val_out = if (d_float > opts.threshold) std.math.maxInt(T) else 0;
                    } else {
                        const scaled = d_float * opts.scale;
                        val_out = meta.clamp(T, scaled);
                    }

                    dest.* = val_out;
                    stats.add(@floatFromInt(val_out));
                },
                .float => {
                    const d_raw = @abs(p1 - p2);

                    if (d_raw > opts.threshold) diff_count += 1;

                    var val_out: T = 0;
                    if (opts.binary) {
                        val_out = if (d_raw > opts.threshold) 1.0 else 0.0;
                    } else {
                        val_out = d_raw * opts.scale;
                    }

                    dest.* = val_out;
                    stats.add(val_out);
                },
                .@"struct" => {
                    var is_pixel_diff = false;
                    var pixel_max_val: f64 = 0;
                    const fields = std.meta.fields(T);
                    var diffs: [fields.len]f32 = undefined;

                    // 1. Calculate raw differences and check threshold
                    inline for (fields, 0..) |field, i| {
                        const v1 = @field(p1, field.name);
                        const v2 = @field(p2, field.name);
                        const F = field.type;
                        diffs[i] = switch (@typeInfo(F)) {
                            .int => @as(f32, @floatFromInt(if (v1 > v2) v1 - v2 else v2 - v1)),
                            .float => @abs(v1 - v2),
                            else => 0,
                        };
                        if (diffs[i] > opts.threshold) is_pixel_diff = true;
                    }

                    if (is_pixel_diff) diff_count += 1;

                    // 2. Write output with scaling/binary/alpha logic
                    inline for (fields, 0..) |field, i| {
                        const F = field.type;
                        const max_v: F = switch (@typeInfo(F)) {
                            .int => std.math.maxInt(F),
                            .float => 1.0,
                            else => unreachable,
                        };

                        // Handle Alpha forcing
                        const is_alpha = std.mem.eql(u8, field.name, "a");
                        if (opts.force_opaque and is_alpha) {
                            @field(dest.*, field.name) = max_v;
                        } else if (opts.binary) {
                            // Binary mode: all channels set to max if pixel differs
                            const val = if (is_pixel_diff) max_v else 0;
                            @field(dest.*, field.name) = val;
                            const val_f = switch (@typeInfo(F)) {
                                .int => @as(f64, @floatFromInt(val)),
                                .float => @as(f64, val),
                                else => 0,
                            };
                            if (val_f > pixel_max_val) pixel_max_val = val_f;
                        } else {
                            const scaled = diffs[i] * opts.scale;
                            // Convert back to F
                            const val_out = switch (@typeInfo(F)) {
                                .int => meta.clamp(F, scaled),
                                .float => scaled,
                                else => 0,
                            };

                            @field(dest.*, field.name) = val_out;
                            const val_f = switch (@typeInfo(F)) {
                                .int => @as(f64, @floatFromInt(val_out)),
                                .float => @as(f64, val_out),
                                else => 0,
                            };
                            if (val_f > pixel_max_val) pixel_max_val = val_f;
                        }
                    }
                    stats.add(pixel_max_val);
                },
                .array => |info| {
                    var is_pixel_diff = false;
                    var pixel_max_val: f64 = 0;
                    var diffs: [info.len]f32 = undefined;

                    // 1. Calculate raw differences and check threshold
                    for (0..info.len) |i| {
                        const v1 = p1[i];
                        const v2 = p2[i];
                        diffs[i] = switch (@typeInfo(info.child)) {
                            .int => @as(f32, @floatFromInt(if (v1 > v2) v1 - v2 else v2 - v1)),
                            .float => @abs(v1 - v2),
                            else => 0,
                        };
                        if (diffs[i] > opts.threshold) is_pixel_diff = true;
                    }

                    if (is_pixel_diff) diff_count += 1;

                    // 2. Output
                    const max_v: info.child = switch (@typeInfo(info.child)) {
                        .int => std.math.maxInt(info.child),
                        .float => 1.0,
                        else => unreachable,
                    };

                    for (0..info.len) |i| {
                        if (opts.binary) {
                            const val = if (is_pixel_diff) max_v else 0;
                            dest.*[i] = val;
                            const val_f = switch (@typeInfo(info.child)) {
                                .int => @as(f64, @floatFromInt(val)),
                                .float => @as(f64, val),
                                else => 0,
                            };
                            if (val_f > pixel_max_val) pixel_max_val = val_f;
                        } else {
                            const scaled = diffs[i] * opts.scale;
                            const val_out = switch (@typeInfo(info.child)) {
                                .int => meta.clamp(info.child, scaled),
                                .float => scaled,
                                else => 0,
                            };
                            dest.*[i] = val_out;
                            const val_f = switch (@typeInfo(info.child)) {
                                .int => @as(f64, @floatFromInt(val_out)),
                                .float => @as(f64, val_out),
                                else => 0,
                            };
                            if (val_f > pixel_max_val) pixel_max_val = val_f;
                        }
                    }
                    stats.add(pixel_max_val);
                },
                else => @compileError("Unsupported pixel type for diff"),
            }
        }
    }
    return DiffResult{ .stats = stats, .diff_count = diff_count };
}
