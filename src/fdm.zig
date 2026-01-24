const std = @import("std");
const assert = std.debug.assert;
const clamp = std.math.clamp;
const testing = std.testing;
const expectEqual = testing.expectEqual;
const expectApproxEqAbs = testing.expectApproxEqAbs;

const Image = @import("image.zig").Image;
const Matrix = @import("matrix.zig").Matrix;
const Rgb = @import("color.zig").Rgb(u8);
const Rgba = @import("color.zig").Rgba(u8);
const Gray = @import("color.zig").Gray;
const convertColor = @import("color.zig").convertColor;
const RunningStats = @import("stats.zig").RunningStats;
const CovarianceStats = @import("stats.zig").CovarianceStats;

/// Feature Distribution Matching struct for stateful image style transfer.
/// Allows efficient batch processing by reusing target distribution statistics.
pub fn FeatureDistributionMatching(comptime T: type) type {
    comptime assert(T == Rgb or T == Rgba or T == u8);

    return struct {
        const Self = @This();

        // Core state
        allocator: std.mem.Allocator,

        // Target distribution statistics (computed once, reused)
        target_mean: [3]f64,
        target_cov_u: Matrix(f64), // Eigenvectors of covariance
        target_cov_s: [3]f64, // Eigenvalues of covariance
        target_is_grayscale: bool,

        // Source image reference
        source_image: ?Image(T),

        // State flags
        has_target: bool,
        has_source: bool,

        /// Initialize an empty FDM instance
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .target_mean = @splat(0),
                .target_cov_u = Matrix(f64){
                    .rows = 0,
                    .cols = 0,
                    .items = &[_]f64{}, // Safe because rows=0 guards against deinit
                    .allocator = allocator,
                },
                .target_cov_s = @splat(0),
                .target_is_grayscale = false,
                .source_image = null,
                .has_target = false,
                .has_source = false,
            };
        }

        /// Free allocated memory
        pub fn deinit(self: *Self) void {
            if (self.target_cov_u.rows > 0) {
                self.target_cov_u.deinit();
            }
            self.* = Self.init(self.allocator);
        }

        /// Set the target image whose distribution will be matched.
        /// This computes and stores the target statistics for reuse.
        pub fn setTarget(self: *Self, target_image: Image(T)) !void {
            // Clean up previous target data if any
            if (self.has_target and self.target_cov_u.rows > 0) {
                self.target_cov_u.deinit();
            }

            var stats = CovarianceStats(3, f64).init();

            // Pass 1: Accumulate statistics
            if (T == u8) {
                for (target_image.data) |pixel| {
                    const v = @as(f64, @floatFromInt(pixel)) / 255.0;
                    stats.add(.{ v, v, v });
                }
                self.target_is_grayscale = true;
            } else {
                var is_gray = true;
                for (target_image.data) |pixel| {
                    const r = @as(f64, @floatFromInt(pixel.r)) / 255.0;
                    const g = @as(f64, @floatFromInt(pixel.g)) / 255.0;
                    const b = @as(f64, @floatFromInt(pixel.b)) / 255.0;
                    stats.add(.{ r, g, b });
                    if (pixel.r != pixel.g or pixel.g != pixel.b) is_gray = false;
                }
                self.target_is_grayscale = is_gray;
            }

            self.target_mean = stats.mean();

            if (self.target_is_grayscale) {
                // Grayscale logic: only variance matters
                const cov = stats.varianceVector();
                // Use the variance of the first channel (all are same) as the eigenvalue
                self.target_cov_s = .{ cov[0], 0, 0 };

                // Initialize empty matrix for U since we won't use it
                self.target_cov_u = Matrix(f64){ .rows = 0, .cols = 0, .items = &[_]f64{}, .allocator = self.allocator };
            } else {
                // Color logic: Full SVD of covariance
                var cov_matrix = try stats.covarianceMatrix(self.allocator);
                defer cov_matrix.deinit();

                const cov_static = cov_matrix.toSMatrix(3, 3);
                const target_svd = cov_static.svd(.{
                    .with_u = true,
                    .with_v = false,
                    .mode = .skinny_u,
                });

                if (target_svd.converged != 0) {
                    return error.NotConverged;
                }

                self.target_cov_u = try Matrix(f64).fromSMatrix(self.allocator, target_svd.u);
                for (0..3) |i| {
                    self.target_cov_s[i] = target_svd.s.at(i, 0).*;
                }
            }

            self.has_target = true;
        }

        /// Set the source image to be transformed.
        pub fn setSource(self: *Self, source_image: Image(T)) !void {
            self.source_image = source_image;
            self.has_source = true;
        }

        /// Convenience method to match source to target immediately.
        pub fn match(self: *Self, source_image: Image(T), target_image: Image(T)) !void {
            try self.setTarget(target_image);
            try self.setSource(source_image);
            try self.update();
        }

        /// Apply the feature distribution matching transformation.
        /// Modifies the source image in-place.
        pub fn update(self: *Self) !void {
            if (!self.has_target) return error.NoTargetSet;
            if (!self.has_source or self.source_image == null) return error.NoSourceSet;

            const source_img = self.source_image.?;
            var stats = CovarianceStats(3, f64).init();

            // Pass 1: Compute source statistics
            if (T == u8) {
                for (source_img.data) |pixel| {
                    const v = @as(f64, @floatFromInt(pixel)) / 255.0;
                    stats.add(.{ v, v, v });
                }
            } else {
                if (self.target_is_grayscale) {
                    // If target is grayscale, treat source as luminance for stats
                    for (source_img.data) |pixel| {
                        // Using convertColor logic to get grayscale value.
                        const gray = convertColor(u8, pixel);
                        const v = @as(f64, @floatFromInt(gray)) / 255.0;
                        stats.add(.{ v, v, v });
                    }
                } else {
                    for (source_img.data) |pixel| {
                        stats.add(.{
                            @as(f64, @floatFromInt(pixel.r)) / 255.0,
                            @as(f64, @floatFromInt(pixel.g)) / 255.0,
                            @as(f64, @floatFromInt(pixel.b)) / 255.0,
                        });
                    }
                }
            }

            const source_mean = stats.mean();

            // Pass 2: Apply transformation
            if (T == u8 or self.target_is_grayscale) {
                // Scalar matching logic
                const source_cov = stats.varianceVector();
                const source_var = source_cov[0];
                const scale = if (source_var > 1e-10) @sqrt(self.target_cov_s[0] / source_var) else 1.0;
                const offset = self.target_mean[0] - source_mean[0] * scale;

                if (T == u8) {
                    for (source_img.data) |*pixel| {
                        const val = @as(f64, @floatFromInt(pixel.*)) / 255.0;
                        const result = clamp(val * scale + offset, 0, 1);
                        pixel.* = @as(u8, @intFromFloat(@round(255.0 * result)));
                    }
                } else {
                    for (source_img.data) |*pixel| {
                        // Color image, target is grayscale: convert to gray then match
                        const val = @as(f64, @floatFromInt(convertColor(u8, pixel.*))) / 255.0;
                        const result = clamp(val * scale + offset, 0, 1);
                        const res_u8 = @as(u8, @intFromFloat(@round(255.0 * result)));
                        pixel.* = .{ .r = res_u8, .g = res_u8, .b = res_u8 };
                    }
                }
            } else {
                // Color matching logic
                var source_cov_mat = try stats.covarianceMatrix(self.allocator);
                defer source_cov_mat.deinit();

                // Compute W transform matrix
                // W = U_s * diag(sqrt(lambda_t / lambda_s)) * U_t^T

                const source_cov_static = source_cov_mat.toSMatrix(3, 3);
                const source_svd = source_cov_static.svd(.{ .with_u = true, .with_v = false, .mode = .skinny_u });

                if (source_svd.converged != 0) {
                    return error.NotConverged;
                }

                // Construct combined scaling matrix
                var sigma_combined = try Matrix(f64).init(self.allocator, 3, 3);
                defer sigma_combined.deinit();
                @memset(sigma_combined.items, 0);

                for (0..3) |i| {
                    const s_val = source_svd.s.at(i, 0).*;
                    const t_val = self.target_cov_s[i];
                    if (s_val > 1e-10) {
                        sigma_combined.at(i, i).* = @sqrt(t_val / s_val);
                    }
                }

                var u_source = try Matrix(f64).fromSMatrix(self.allocator, source_svd.u);
                defer u_source.deinit();

                var u_target_t = self.target_cov_u.transpose();
                defer u_target_t.deinit();

                // w_temp = u_source * sigma_combined
                var w_temp = try u_source.dot(sigma_combined).eval();
                defer w_temp.deinit();

                // w = w_temp * u_target_t
                var w = try w_temp.dot(u_target_t).eval();
                defer w.deinit();

                // Apply W to every pixel
                // X_new = (X - mu_s) * W + mu_t
                // Optimization: Precompute 'bias' = mu_t - mu_s * W
                // Then X_new = X * W + bias

                // Compute mu_s * W (row vector multiply)
                var bias: [3]f64 = undefined;
                for (0..3) |j| {
                    var sum: f64 = 0;
                    for (0..3) |k| {
                        sum += source_mean[k] * w.at(k, j).*;
                    }
                    bias[j] = self.target_mean[j] - sum;
                }

                // In-place update
                for (source_img.data) |*pixel| {
                    const r = @as(f64, @floatFromInt(pixel.r)) / 255.0;
                    const g = @as(f64, @floatFromInt(pixel.g)) / 255.0;
                    const b = @as(f64, @floatFromInt(pixel.b)) / 255.0;

                    // Apply linear transform: pixel * W + bias
                    var res = [3]f64{ 0, 0, 0 };
                    res[0] = r * w.at(0, 0).* + g * w.at(1, 0).* + b * w.at(2, 0).* + bias[0];
                    res[1] = r * w.at(0, 1).* + g * w.at(1, 1).* + b * w.at(2, 1).* + bias[1];
                    res[2] = r * w.at(0, 2).* + g * w.at(1, 2).* + b * w.at(2, 2).* + bias[2];

                    pixel.r = @intFromFloat(@round(255.0 * clamp(res[0], 0, 1)));
                    pixel.g = @intFromFloat(@round(255.0 * clamp(res[1], 0, 1)));
                    pixel.b = @intFromFloat(@round(255.0 * clamp(res[2], 0, 1)));
                }
            }
        }
    };
}

/// Feature Distribution Matching (FDM) for image style transfer and domain adaptation.
///
/// Transfers the color distribution (mean and covariance) from a target image to a source image,
/// effectively matching the "style" or "look" of the target while preserving the structure of the source.
///
/// ## Algorithm
/// FDM works by matching the first and second-order statistics of pixel distributions:
/// 1. **Accumulate** - Stream pixels to compute mean and covariance statistics (O(1) memory)
/// 2. **Whiten** - Transform source to have identity covariance: Cov(X_src) = I
/// 3. **Color Transform** - Apply target covariance: Cov(X_result) = Cov(X_target)
/// 4. **Restore Mean** - Add target mean to final result
///
/// ## Mathematical Foundation
/// Given source X_src and target X_target, FDM computes:
/// ```
/// X_result = (X_src - μ_src) * Σ_src^(-1/2) * U_src * Σ_target^(1/2) * U_target^T + μ_target
/// ```
/// Where μ is mean, Σ is covariance eigenvalues, and U is covariance eigenvectors.
///
/// ## Paper Reference
/// "Keep it Simple: Image Statistics Matching for Domain Adaptation"
/// by A. Abramov, et al. (2020)
/// https://arxiv.org/abs/2005.12551
///
/// ## Example Usage
/// ```zig
/// // Single image transformation
/// var fdm: FeatureDistributionMatching(Rgb(u8)) = .init(allocator);
/// defer fdm.deinit();
/// try fdm.match(source_img, target_img); // Modifies source_img in-place
///
/// // Batch processing with same target style
/// var fdm: FeatureDistributionMatching(Rgb(u8)) = .init(allocator);
/// defer fdm.deinit();
/// try fdm.setTarget(style_image);
/// for (images_to_transform) |img| {
///     try fdm.setSource(img);
///     try fdm.update(); // Modifies img in-place
/// }
/// ```
fn populationVariance(stats: RunningStats(f64)) f64 {
    const n_samples = stats.currentN();
    if (n_samples <= 1) return 0;
    const n_f = @as(f64, @floatFromInt(n_samples));
    const correction = @as(f64, @floatFromInt(n_samples - 1)) / n_f;
    return stats.variance() * correction;
}

test "FDM mean and covariance matching" {
    const allocator = testing.allocator;

    // Create source image with known statistics
    var source_img: Image(Rgb) = try .init(allocator, 50, 50);
    defer source_img.deinit(allocator);
    for (source_img.data, 0..) |*pixel, i| {
        // Create specific pattern for known covariance structure
        const x = i % 50;
        const y = i / 50;
        pixel.* = Rgb{
            .r = @intCast(100 + (x % 20)), // Variance in R
            .g = @intCast(150 + (y % 15)), // Variance in G
            .b = @intCast(80 + ((x + y) % 25)), // Variance in B, correlated with R+G
        };
    }

    // Create target image with different known statistics
    var target_img: Image(Rgb) = try .init(allocator, 50, 50);
    defer target_img.deinit(allocator);
    for (target_img.data, 0..) |*pixel, i| {
        const x = i % 50;
        const y = i / 50;
        pixel.* = Rgb{
            .r = @intCast(50 + (x % 30)), // Different variance in R
            .g = @intCast(70 + (y % 20)), // Different variance in G
            .b = @intCast(90 + ((x + y) % 35)), // Different variance in B
        };
    }

    // Calculate target statistics before FDM
    var target_sum_r: u32 = 0;
    var target_sum_g: u32 = 0;
    var target_sum_b: u32 = 0;
    for (target_img.data) |pixel| {
        target_sum_r += pixel.r;
        target_sum_g += pixel.g;
        target_sum_b += pixel.b;
    }
    const target_mean_r = @as(f64, @floatFromInt(target_sum_r)) / @as(f64, @floatFromInt(target_img.data.len));
    const target_mean_g = @as(f64, @floatFromInt(target_sum_g)) / @as(f64, @floatFromInt(target_img.data.len));
    const target_mean_b = @as(f64, @floatFromInt(target_sum_b)) / @as(f64, @floatFromInt(target_img.data.len));

    // Calculate target variances
    var target_var_r: f64 = 0;
    var target_var_g: f64 = 0;
    var target_var_b: f64 = 0;
    for (target_img.data) |pixel| {
        const dr = @as(f64, @floatFromInt(pixel.r)) - target_mean_r;
        const dg = @as(f64, @floatFromInt(pixel.g)) - target_mean_g;
        const db = @as(f64, @floatFromInt(pixel.b)) - target_mean_b;
        target_var_r += dr * dr;
        target_var_g += dg * dg;
        target_var_b += db * db;
    }
    target_var_r /= @as(f64, @floatFromInt(target_img.data.len));
    target_var_g /= @as(f64, @floatFromInt(target_img.data.len));
    target_var_b /= @as(f64, @floatFromInt(target_img.data.len));

    // Apply FDM using new API
    var fdm: FeatureDistributionMatching(Rgb) = .init(allocator);
    defer fdm.deinit();
    try fdm.match(source_img, target_img);

    // Calculate result statistics
    var result_sum_r: u32 = 0;
    var result_sum_g: u32 = 0;
    var result_sum_b: u32 = 0;
    for (source_img.data) |pixel| {
        result_sum_r += pixel.r;
        result_sum_g += pixel.g;
        result_sum_b += pixel.b;
    }
    const result_mean_r = @as(f64, @floatFromInt(result_sum_r)) / @as(f64, @floatFromInt(source_img.data.len));
    const result_mean_g = @as(f64, @floatFromInt(result_sum_g)) / @as(f64, @floatFromInt(source_img.data.len));
    const result_mean_b = @as(f64, @floatFromInt(result_sum_b)) / @as(f64, @floatFromInt(source_img.data.len));

    // Calculate result variances
    var result_var_r: f64 = 0;
    var result_var_g: f64 = 0;
    var result_var_b: f64 = 0;
    for (source_img.data) |pixel| {
        const dr = @as(f64, @floatFromInt(pixel.r)) - result_mean_r;
        const dg = @as(f64, @floatFromInt(pixel.g)) - result_mean_g;
        const db = @as(f64, @floatFromInt(pixel.b)) - result_mean_b;
        result_var_r += dr * dr;
        result_var_g += dg * dg;
        result_var_b += db * db;
    }
    result_var_r /= @as(f64, @floatFromInt(source_img.data.len));
    result_var_g /= @as(f64, @floatFromInt(source_img.data.len));
    result_var_b /= @as(f64, @floatFromInt(source_img.data.len));

    // Test 1: Mean should match target (within tolerance for rounding)
    try expectApproxEqAbs(result_mean_r, target_mean_r, 2.0);
    try expectApproxEqAbs(result_mean_g, target_mean_g, 2.0);
    try expectApproxEqAbs(result_mean_b, target_mean_b, 2.0);

    // Test 2: Variances should be close to target (FDM matches covariance structure)
    try expectApproxEqAbs(result_var_r, target_var_r, 1);
    try expectApproxEqAbs(result_var_g, target_var_g, 1);
    try expectApproxEqAbs(result_var_b, target_var_b, 1);
}

test "FDM grayscale mean and variance matching" {
    const allocator = testing.allocator;

    // Create source image with known statistics
    var source_img: Image(u8) = try .init(allocator, 100, 1);
    defer source_img.deinit(allocator);

    // Fill with values 0-99 for known mean=49.5, variance
    for (source_img.data, 0..) |*pixel, i| {
        pixel.* = @intCast(i);
    }

    // Create target image with different known statistics
    var target_img: Image(u8) = try .init(allocator, 100, 1);
    defer target_img.deinit(allocator);

    // Fill with values 100-199 for known mean=149.5
    for (target_img.data, 0..) |*pixel, i| {
        pixel.* = @intCast(100 + i);
    }

    // Apply FDM using new API
    var fdm: FeatureDistributionMatching(u8) = .init(allocator);
    defer fdm.deinit();
    try fdm.match(source_img, target_img);

    // Calculate actual mean of result
    var sum: u32 = 0;
    for (source_img.data) |pixel| {
        sum += pixel;
    }
    const actual_mean = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(source_img.data.len));

    // Mean should be the target mean (149.5)
    try expectEqual(actual_mean, 149.5);
}

test "FDM batch processing with reused target" {
    const allocator = testing.allocator;

    // Create a target style image
    var target_img: Image(Rgb) = try .init(allocator, 20, 20);
    defer target_img.deinit(allocator);
    for (target_img.data, 0..) |*pixel, i| {
        // Warm color palette
        pixel.* = Rgb{
            .r = @intCast(200 + (i % 55)),
            .g = @intCast(100 + (i % 50)),
            .b = @intCast(50 + (i % 30)),
        };
    }

    // Create multiple source images to transform
    var source_images: [3]Image(Rgb) = undefined;
    for (&source_images, 0..) |*img, idx| {
        img.* = try .init(allocator, 20, 20);
        for (img.data, 0..) |*pixel, i| {
            // Different cool color patterns
            pixel.* = .{
                .r = @intCast((idx * 20 + i) % 100),
                .g = @intCast((idx * 30 + i) % 150),
                .b = @intCast((idx * 40 + i) % 200),
            };
        }
    }
    defer for (&source_images) |*img| {
        img.deinit(allocator);
    };

    // Create FDM instance and set target once
    var fdm: FeatureDistributionMatching(Rgb) = .init(allocator);
    defer fdm.deinit();
    try fdm.setTarget(target_img);

    // Apply the same target distribution to all source images
    for (&source_images) |source_img| {
        try fdm.setSource(source_img);
        try fdm.update();
    }

    // Verify all transformed images have similar statistics
    var means: [3][3]f64 = undefined;
    for (source_images, 0..) |img, idx| {
        var sums = [_]u32{ 0, 0, 0 };
        for (img.data) |pixel| {
            sums[0] += pixel.r;
            sums[1] += pixel.g;
            sums[2] += pixel.b;
        }
        means[idx][0] = @as(f64, @floatFromInt(sums[0])) / @as(f64, @floatFromInt(img.data.len));
        means[idx][1] = @as(f64, @floatFromInt(sums[1])) / @as(f64, @floatFromInt(img.data.len));
        means[idx][2] = @as(f64, @floatFromInt(sums[2])) / @as(f64, @floatFromInt(img.data.len));
    }

    // All transformed images should have similar means (close to target)
    for (1..means.len) |i| {
        try expectApproxEqAbs(means[0][0], means[i][0], 5.0); // R channel
        try expectApproxEqAbs(means[0][1], means[i][1], 5.0); // G channel
        try expectApproxEqAbs(means[0][2], means[i][2], 5.0); // B channel
    }
}

test "FDM grayscale target applied to color source" {
    const allocator = testing.allocator;

    // Build a color source image with distinct RGB patterns.
    var source_img: Image(Rgb) = try .init(allocator, 12, 12);
    defer source_img.deinit(allocator);
    for (source_img.data, 0..) |*pixel, idx| {
        const x = idx % 12;
        const y = idx / 12;
        pixel.* = Rgb{
            .r = @intCast((x * 30 + y * 5) % 255),
            .g = @intCast((x * 15 + y * 40) % 255),
            .b = @intCast((x * 50 + y * 25) % 255),
        };
    }

    // Target image is RGB but grayscale-valued.
    var target_img: Image(Rgb) = try .init(allocator, 12, 12);
    defer target_img.deinit(allocator);
    for (target_img.data, 0..) |*pixel, idx| {
        const val: u8 = @intCast(40 + (idx % 160));
        pixel.* = .{ .r = val, .g = val, .b = val };
    }

    // Pre-compute target statistics (on 0-255 scale).
    var target_stats: RunningStats(f64) = .init();
    for (target_img.data) |pixel| {
        target_stats.add(@as(f64, @floatFromInt(pixel.r)));
    }
    const target_mean = target_stats.mean();
    const target_var = populationVariance(target_stats);

    var fdm: FeatureDistributionMatching(Rgb) = .init(allocator);
    defer fdm.deinit();

    try fdm.match(source_img, target_img);

    // Result image should be grayscale and match target statistics within tolerance.
    var result_stats: RunningStats(f64) = .init();
    for (source_img.data) |pixel| {
        try expectEqual(pixel.r, pixel.g);
        try expectEqual(pixel.g, pixel.b);
        result_stats.add(@floatFromInt(pixel.r));
    }

    const result_mean = result_stats.mean();
    try expectApproxEqAbs(result_mean, target_mean, 2.0);

    const result_var = populationVariance(result_stats);
    try expectApproxEqAbs(result_var, target_var, 2.0);
}

test "FDM error handling" {
    const allocator = testing.allocator;

    var fdm: FeatureDistributionMatching(Rgb) = .init(allocator);
    defer fdm.deinit();

    // Test update without setting images
    try testing.expectError(error.NoTargetSet, fdm.update());

    // Set target but not source
    var target_img: Image(Rgb) = try .init(allocator, 10, 10);
    defer target_img.deinit(allocator);
    try fdm.setTarget(target_img);

    try testing.expectError(error.NoSourceSet, fdm.update());

    // Now it should work
    var source_img: Image(Rgb) = try .init(allocator, 10, 10);
    defer source_img.deinit(allocator);
    try fdm.setSource(source_img);
    try fdm.update(); // Should succeed
}
