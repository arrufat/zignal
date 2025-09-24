//! Motion blur effects for images

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Image = @import("../image.zig").Image;
const meta = @import("../meta.zig");
const as = meta.as;
const isScalar = meta.isScalar;

/// Motion blur type for unified API.
/// Provides different types of motion blur effects to simulate camera or object movement.
pub const MotionBlur = union(enum) {
    /// Linear motion blur simulates straight-line camera or object movement.
    /// Creates a directional blur effect along the specified angle.
    linear: struct {
        /// Direction of motion in radians.
        /// - 0 = horizontal (left-right)
        /// - π/2 = vertical (up-down)
        /// - π/4 = diagonal (45 degrees)
        angle: f32,
        /// Length of the blur effect in pixels.
        /// Larger values create more pronounced motion trails.
        distance: usize,
    },
    /// Radial zoom blur simulates camera zoom or dolly movement.
    /// Creates a blur effect that radiates outward from or inward to a center point.
    radial_zoom: struct {
        /// X coordinate of the zoom center (0.0 to 1.0, normalized).
        /// 0.5 = center of image horizontally.
        center_x: f32,
        /// Y coordinate of the zoom center (0.0 to 1.0, normalized).
        /// 0.5 = center of image vertically.
        center_y: f32,
        /// Intensity of the zoom blur (0.0 to 1.0).
        /// - 0.0 = no blur
        /// - 1.0 = maximum blur
        /// Typically use 0.3-0.7 for realistic effects.
        strength: f32,
    },
    /// Radial spin blur simulates rotational camera or object movement.
    /// Creates a circular blur effect around a center point, like a spinning wheel.
    radial_spin: struct {
        /// X coordinate of the rotation center (0.0 to 1.0, normalized).
        /// 0.5 = center of image horizontally.
        center_x: f32,
        /// Y coordinate of the rotation center (0.0 to 1.0, normalized).
        /// 0.5 = center of image vertically.
        center_y: f32,
        /// Intensity of the spin blur (0.0 to 1.0).
        /// - 0.0 = no blur
        /// - 1.0 = maximum blur
        /// Controls the arc length of the circular blur.
        strength: f32,
    },
};

/// Motion blur operations for Image(T)
pub fn MotionBlurOps(comptime T: type) type {
    return struct {
        /// Radial blur types
        pub const RadialType = enum { zoom, spin };

        /// Applies linear motion blur to simulate camera or object movement in a straight line.
        /// The blur is created by averaging pixels along a line at the specified angle and distance.
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for temporary buffers.
        /// - `angle`: Direction of motion in radians (0 = horizontal, π/2 = vertical).
        /// - `distance`: Length of the blur effect in pixels.
        /// - `out`: Output image containing the motion blurred result.
        pub fn linear(image: Image(T), allocator: Allocator, angle: f32, distance: usize, out: *Image(T)) !void {
            if (!image.hasSameShape(out.*)) {
                out.deinit(allocator);
                out.* = try .init(allocator, image.rows, image.cols);
            }

            if (distance == 0) {
                image.copy(out.*);
                return;
            }

            // Calculate motion vector components
            const cos_angle = @cos(angle);
            const sin_angle = @sin(angle);
            const half_dist = @as(f32, @floatFromInt(distance)) / 2.0;

            // For purely horizontal or vertical motion, use optimized separable approach
            const epsilon = 0.001;
            const is_horizontal = @abs(sin_angle) < epsilon;
            const is_vertical = @abs(cos_angle) < epsilon;

            if (is_horizontal) {
                // Use separable convolution for horizontal motion blur
                const kernel_size = distance;
                const kernel = try allocator.alloc(f32, kernel_size);
                defer allocator.free(kernel);

                // Create uniform kernel
                const weight = 1.0 / @as(f32, @floatFromInt(kernel_size));
                for (kernel) |*k| {
                    k.* = weight;
                }

                // Identity kernel for vertical (no blur)
                const identity = [_]f32{1.0};

                // Apply separable convolution (horizontal blur only)
                try image.convolveSeparable(allocator, kernel, &identity, out, .replicate);
            } else if (is_vertical) {
                // Use separable convolution for vertical motion blur
                const kernel_size = distance;
                const kernel = try allocator.alloc(f32, kernel_size);
                defer allocator.free(kernel);

                // Create uniform kernel
                const weight = 1.0 / @as(f32, @floatFromInt(kernel_size));
                for (kernel) |*k| {
                    k.* = weight;
                }

                // Identity kernel for horizontal (no blur)
                const identity = [_]f32{1.0};

                // Apply separable convolution (vertical blur only)
                try image.convolveSeparable(allocator, &identity, kernel, out, .replicate);
            } else {
                // General diagonal motion blur
                switch (@typeInfo(T)) {
                    .int, .float => {
                        // Process scalar types directly
                        for (0..image.rows) |r| {
                            for (0..image.cols) |c| {
                                var sum: f32 = 0;
                                var count: f32 = 0;

                                // Sample along the motion line
                                var t: f32 = -half_dist;
                                while (t <= half_dist) : (t += 1.0) {
                                    const sample_x = @as(f32, @floatFromInt(c)) + t * cos_angle;
                                    const sample_y = @as(f32, @floatFromInt(r)) + t * sin_angle;

                                    // Check bounds
                                    if (sample_x >= 0 and sample_x < @as(f32, @floatFromInt(image.cols)) and
                                        sample_y >= 0 and sample_y < @as(f32, @floatFromInt(image.rows)))
                                    {
                                        // Bilinear interpolation
                                        const x0 = @as(usize, @intFromFloat(@floor(sample_x)));
                                        const x1 = @min(x0 + 1, image.cols - 1);
                                        const y0 = @as(usize, @intFromFloat(@floor(sample_y)));
                                        const y1 = @min(y0 + 1, image.rows - 1);

                                        const fx = sample_x - @as(f32, @floatFromInt(x0));
                                        const fy = sample_y - @as(f32, @floatFromInt(y0));

                                        const v00 = as(f32, image.at(y0, x0).*);
                                        const v10 = as(f32, image.at(y0, x1).*);
                                        const v01 = as(f32, image.at(y1, x0).*);
                                        const v11 = as(f32, image.at(y1, x1).*);

                                        const v0 = v00 * (1 - fx) + v10 * fx;
                                        const v1 = v01 * (1 - fx) + v11 * fx;
                                        const value = v0 * (1 - fy) + v1 * fy;

                                        sum += value;
                                        count += 1;
                                    }
                                }

                                const result = if (count > 0) sum / count else as(f32, image.at(r, c).*);
                                out.at(r, c).* = switch (@typeInfo(T)) {
                                    .int => @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(result)))),
                                    .float => as(T, result),
                                    else => unreachable,
                                };
                            }
                        }
                    },
                    .@"struct" => {
                        // Process struct types (RGB, RGBA, etc.)
                        const fields = std.meta.fields(T);
                        for (0..image.rows) |r| {
                            for (0..image.cols) |c| {
                                var result_pixel: T = undefined;

                                inline for (fields) |field| {
                                    var sum: f32 = 0;
                                    var count: f32 = 0;

                                    // Sample along the motion line
                                    var t: f32 = -half_dist;
                                    while (t <= half_dist) : (t += 1.0) {
                                        const sample_x = @as(f32, @floatFromInt(c)) + t * cos_angle;
                                        const sample_y = @as(f32, @floatFromInt(r)) + t * sin_angle;

                                        // Check bounds
                                        if (sample_x >= 0 and sample_x < @as(f32, @floatFromInt(image.cols)) and
                                            sample_y >= 0 and sample_y < @as(f32, @floatFromInt(image.rows)))
                                        {
                                            // Bilinear interpolation
                                            const x0 = @as(usize, @intFromFloat(@floor(sample_x)));
                                            const x1 = @min(x0 + 1, image.cols - 1);
                                            const y0 = @as(usize, @intFromFloat(@floor(sample_y)));
                                            const y1 = @min(y0 + 1, image.rows - 1);

                                            const fx = sample_x - @as(f32, @floatFromInt(x0));
                                            const fy = sample_y - @as(f32, @floatFromInt(y0));

                                            const v00 = as(f32, @field(image.at(y0, x0).*, field.name));
                                            const v10 = as(f32, @field(image.at(y0, x1).*, field.name));
                                            const v01 = as(f32, @field(image.at(y1, x0).*, field.name));
                                            const v11 = as(f32, @field(image.at(y1, x1).*, field.name));

                                            const v0 = v00 * (1 - fx) + v10 * fx;
                                            const v1 = v01 * (1 - fx) + v11 * fx;
                                            const value = v0 * (1 - fy) + v1 * fy;

                                            sum += value;
                                            count += 1;
                                        }
                                    }

                                    const channel_result = if (count > 0) sum / count else as(f32, @field(image.at(r, c).*, field.name));
                                    @field(result_pixel, field.name) = switch (@typeInfo(field.type)) {
                                        .int => @intFromFloat(@max(std.math.minInt(field.type), @min(std.math.maxInt(field.type), @round(channel_result)))),
                                        .float => as(field.type, channel_result),
                                        else => @compileError("Unsupported field type"),
                                    };
                                }

                                out.at(r, c).* = result_pixel;
                            }
                        }
                    },
                    else => @compileError("Linear motion blur not supported for type " ++ @typeName(T)),
                }
            }
        }

        /// Applies radial motion blur to simulate zoom or rotational movement.
        /// Creates either a zoom effect (radiating from center) or spin effect (rotating around center).
        ///
        /// Parameters:
        /// - `allocator`: The allocator to use for temporary buffers.
        /// - `center_x`: X coordinate of the blur center (0.0 to 1.0, normalized).
        /// - `center_y`: Y coordinate of the blur center (0.0 to 1.0, normalized).
        /// - `strength`: Intensity of the blur effect (0.0 to 1.0).
        /// - `blur_type`: Type of radial blur - .zoom for zoom blur, .spin for rotational blur.
        /// - `out`: Output image containing the radial motion blurred result.
        pub fn radial(
            image: Image(T),
            allocator: Allocator,
            center_x: f32,
            center_y: f32,
            strength: f32,
            blur_type: RadialType,
            out: *Image(T),
        ) !void {
            if (!image.hasSameShape(out.*)) {
                out.deinit(allocator);
                out.* = try .init(allocator, image.rows, image.cols);
            }

            if (strength == 0) {
                image.copy(out.*);
                return;
            }

            // Convert normalized center to pixel coordinates
            const cx = center_x * @as(f32, @floatFromInt(image.cols - 1));
            const cy = center_y * @as(f32, @floatFromInt(image.rows - 1));

            // Clamp strength to [0, 1]
            const clamped_strength = @max(0, @min(1, strength));

            // Calculate number of samples based on strength
            const base_samples = 8;
            const max_additional_samples = 24;
            const num_samples = base_samples + @as(usize, @intFromFloat(clamped_strength * @as(f32, @floatFromInt(max_additional_samples))));

            switch (@typeInfo(T)) {
                .int, .float => {
                    // Process scalar types
                    for (0..image.rows) |r| {
                        for (0..image.cols) |c| {
                            const fx = @as(f32, @floatFromInt(c));
                            const fy = @as(f32, @floatFromInt(r));

                            // Calculate distance and angle from center
                            const dx = fx - cx;
                            const dy = fy - cy;
                            const distance = @sqrt(dx * dx + dy * dy);
                            const angle = std.math.atan2(dy, dx);

                            // Calculate blur amount based on distance from center
                            const max_distance = @sqrt(cx * cx + cy * cy);
                            const blur_amount = if (blur_type == .zoom)
                                (distance / max_distance) * clamped_strength * 20
                            else
                                clamped_strength * 0.5;

                            var sum: f32 = 0;
                            var count: usize = 0;

                            // Sample along blur path
                            for (0..num_samples) |s| {
                                const t = (@as(f32, @floatFromInt(s)) - @as(f32, @floatFromInt(num_samples - 1)) / 2.0) / @as(f32, @floatFromInt(num_samples - 1));

                                var sample_x: f32 = undefined;
                                var sample_y: f32 = undefined;

                                if (blur_type == .zoom) {
                                    // Zoom blur: sample along radial line
                                    const scale = 1.0 + t * blur_amount * 0.1;
                                    sample_x = cx + dx * scale;
                                    sample_y = cy + dy * scale;
                                } else {
                                    // Spin blur: sample along circular arc
                                    const angle_offset = t * blur_amount;
                                    const new_angle = angle + angle_offset;
                                    sample_x = cx + distance * @cos(new_angle);
                                    sample_y = cy + distance * @sin(new_angle);
                                }

                                // Check bounds
                                if (sample_x >= 0 and sample_x < @as(f32, @floatFromInt(image.cols)) and
                                    sample_y >= 0 and sample_y < @as(f32, @floatFromInt(image.rows)))
                                {
                                    // Bilinear interpolation
                                    const x0 = @as(usize, @intFromFloat(@floor(sample_x)));
                                    const x1 = @min(x0 + 1, image.cols - 1);
                                    const y0 = @as(usize, @intFromFloat(@floor(sample_y)));
                                    const y1 = @min(y0 + 1, image.rows - 1);

                                    const fx_interp = sample_x - @as(f32, @floatFromInt(x0));
                                    const fy_interp = sample_y - @as(f32, @floatFromInt(y0));

                                    const v00 = as(f32, image.at(y0, x0).*);
                                    const v10 = as(f32, image.at(y0, x1).*);
                                    const v01 = as(f32, image.at(y1, x0).*);
                                    const v11 = as(f32, image.at(y1, x1).*);

                                    const v0 = v00 * (1 - fx_interp) + v10 * fx_interp;
                                    const v1 = v01 * (1 - fx_interp) + v11 * fx_interp;
                                    const value = v0 * (1 - fy_interp) + v1 * fy_interp;

                                    sum += value;
                                    count += 1;
                                }
                            }

                            const result = if (count > 0) sum / @as(f32, @floatFromInt(count)) else as(f32, image.at(r, c).*);
                            out.at(r, c).* = switch (@typeInfo(T)) {
                                .int => @intFromFloat(@max(std.math.minInt(T), @min(std.math.maxInt(T), @round(result)))),
                                .float => as(T, result),
                                else => unreachable,
                            };
                        }
                    }
                },
                .@"struct" => {
                    // Process struct types (RGB, RGBA, etc.)
                    const fields = std.meta.fields(T);
                    for (0..image.rows) |r| {
                        for (0..image.cols) |c| {
                            const fx = @as(f32, @floatFromInt(c));
                            const fy = @as(f32, @floatFromInt(r));

                            // Calculate distance and angle from center
                            const dx = fx - cx;
                            const dy = fy - cy;
                            const distance = @sqrt(dx * dx + dy * dy);
                            const angle = std.math.atan2(dy, dx);

                            // Calculate blur amount based on distance from center
                            const max_distance = @sqrt(cx * cx + cy * cy);
                            const blur_amount = if (blur_type == .zoom)
                                (distance / max_distance) * clamped_strength * 20
                            else
                                clamped_strength * 0.5;

                            var result_pixel: T = undefined;

                            inline for (fields) |field| {
                                var sum: f32 = 0;
                                var count: usize = 0;

                                // Sample along blur path
                                for (0..num_samples) |s| {
                                    const t = (@as(f32, @floatFromInt(s)) - @as(f32, @floatFromInt(num_samples - 1)) / 2.0) / @as(f32, @floatFromInt(num_samples - 1));

                                    var sample_x: f32 = undefined;
                                    var sample_y: f32 = undefined;

                                    if (blur_type == .zoom) {
                                        // Zoom blur: sample along radial line
                                        const scale = 1.0 + t * blur_amount * 0.1;
                                        sample_x = cx + dx * scale;
                                        sample_y = cy + dy * scale;
                                    } else {
                                        // Spin blur: sample along circular arc
                                        const angle_offset = t * blur_amount;
                                        const new_angle = angle + angle_offset;
                                        sample_x = cx + distance * @cos(new_angle);
                                        sample_y = cy + distance * @sin(new_angle);
                                    }

                                    // Check bounds
                                    if (sample_x >= 0 and sample_x < @as(f32, @floatFromInt(image.cols)) and
                                        sample_y >= 0 and sample_y < @as(f32, @floatFromInt(image.rows)))
                                    {
                                        // Bilinear interpolation
                                        const x0 = @as(usize, @intFromFloat(@floor(sample_x)));
                                        const x1 = @min(x0 + 1, image.cols - 1);
                                        const y0 = @as(usize, @intFromFloat(@floor(sample_y)));
                                        const y1 = @min(y0 + 1, image.rows - 1);

                                        const fx_interp = sample_x - @as(f32, @floatFromInt(x0));
                                        const fy_interp = sample_y - @as(f32, @floatFromInt(y0));

                                        const v00 = as(f32, @field(image.at(y0, x0).*, field.name));
                                        const v10 = as(f32, @field(image.at(y0, x1).*, field.name));
                                        const v01 = as(f32, @field(image.at(y1, x0).*, field.name));
                                        const v11 = as(f32, @field(image.at(y1, x1).*, field.name));

                                        const v0 = v00 * (1 - fx_interp) + v10 * fx_interp;
                                        const v1 = v01 * (1 - fx_interp) + v11 * fx_interp;
                                        const value = v0 * (1 - fy_interp) + v1 * fy_interp;

                                        sum += value;
                                        count += 1;
                                    }
                                }

                                const channel_result = if (count > 0) sum / @as(f32, @floatFromInt(count)) else as(f32, @field(image.at(r, c).*, field.name));
                                @field(result_pixel, field.name) = switch (@typeInfo(field.type)) {
                                    .int => @intFromFloat(@max(std.math.minInt(field.type), @min(std.math.maxInt(field.type), @round(channel_result)))),
                                    .float => as(field.type, channel_result),
                                    else => @compileError("Unsupported field type"),
                                };
                            }

                            out.at(r, c).* = result_pixel;
                        }
                    }
                },
                else => @compileError("Radial motion blur not supported for type " ++ @typeName(T)),
            }
        }
    };
}
