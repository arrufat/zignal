const std = @import("std");
const assert = std.debug.assert;
const clamp = std.math.clamp;
const testing = std.testing;
const expectEqual = testing.expectEqual;
const expectApproxEqRel = testing.expectApproxEqRel;
const expectApproxEqAbs = testing.expectApproxEqAbs;
const builtin = @import("builtin");

const Image = @import("image.zig").Image;
const Matrix = @import("matrix.zig").Matrix;
const OpsBuilder = @import("matrix.zig").OpsBuilder;
const Rgb = @import("color.zig").Rgb;
const Rgba = @import("color.zig").Rgba;
const SMatrix = @import("matrix.zig").SMatrix;
const svd = @import("svd.zig").svd;

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
        target_cov_u: Matrix(f64),
        target_cov_s: [3]f64,
        target_is_grayscale: bool,
        target_size: usize,

        // Source image reference (not statistics, as source is modified in-place)
        source_image: ?Image(T),

        // State flags
        has_target: bool,
        has_source: bool,

        /// Initialize an empty FDM instance
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .target_mean = [_]f64{0} ** 3,
                .target_cov_u = Matrix(f64){
                    .rows = 0,
                    .cols = 0,
                    .items = &[_]f64{},
                    .allocator = allocator,
                },
                .target_cov_s = [_]f64{0} ** 3,
                .target_is_grayscale = false,
                .target_size = 0,
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

            if (T == u8) {
                // Grayscale image
                self.target_size = target_image.rows * target_image.cols;
                self.target_is_grayscale = true;

                // Compute grayscale statistics
                var sum: f64 = 0;
                for (target_image.data) |pixel| {
                    sum += @as(f64, @floatFromInt(pixel)) / 255.0;
                }
                self.target_mean[0] = sum / @as(f64, @floatFromInt(self.target_size));

                // Compute variance
                var variance: f64 = 0;
                for (target_image.data) |pixel| {
                    const val = @as(f64, @floatFromInt(pixel)) / 255.0 - self.target_mean[0];
                    variance += val * val;
                }
                variance /= @as(f64, @floatFromInt(self.target_size));
                self.target_cov_s[0] = variance;

                // No eigenvectors needed for grayscale
                self.target_cov_u = Matrix(f64){
                    .rows = 0,
                    .cols = 0,
                    .items = &[_]f64{},
                    .allocator = self.allocator,
                };
            } else {
                // Color image - extract features and compute covariance
                self.target_size = target_image.rows * target_image.cols;
                var feature_mat = try Matrix(f64).init(self.allocator, self.target_size, 3);
                defer feature_mat.deinit();

                self.target_is_grayscale = getFeatureMatrix(T, target_image, &feature_mat);
                if (self.target_is_grayscale) {
                    self.target_mean = centerImage(&feature_mat, 1);
                } else {
                    self.target_mean = centerImage(&feature_mat, 3);
                }

                if (self.target_is_grayscale) {
                    // Grayscale disguised as color
                    var variance: f64 = 0;
                    for (0..feature_mat.rows) |r| {
                        const val = feature_mat.at(r, 0).*;
                        variance += val * val;
                    }
                    variance /= @as(f64, @floatFromInt(feature_mat.rows));
                    self.target_cov_s[0] = variance;
                    self.target_cov_u = Matrix(f64){
                        .rows = 0,
                        .cols = 0,
                        .items = &[_]f64{},
                        .allocator = self.allocator,
                    };
                } else {
                    // Full color - compute and store SVD
                    var cov_ops = try OpsBuilder(f64).init(self.allocator, feature_mat);
                    defer cov_ops.deinit();
                    try cov_ops.gemm(
                        true,
                        feature_mat,
                        false,
                        1.0 / @as(f64, @floatFromInt(self.target_size)),
                        0.0,
                        null,
                    );
                    var cov_matrix = cov_ops.toOwned();
                    defer cov_matrix.deinit();

                    const cov_static = cov_matrix.toSMatrix(3, 3);
                    const target_svd = svd(f64, 3, 3, cov_static, .{
                        .with_u = true,
                        .with_v = false,
                        .mode = .skinny_u,
                    });

                    // Store eigenvectors and eigenvalues
                    self.target_cov_u = try Matrix(f64).fromSMatrix(self.allocator, target_svd.u);
                    for (0..3) |i| {
                        self.target_cov_s[i] = target_svd.s.items[i][0];
                    }
                }
            }

            self.has_target = true;
        }

        /// Set the source image to be transformed.
        /// The source will be modified in-place when update() is called.
        pub fn setSource(self: *Self, source_image: Image(T)) !void {
            self.source_image = source_image;
            self.has_source = true;
        }

        /// Set both source and target images at once and apply the transformation.
        /// This is a convenience method that calls setTarget, setSource, and update.
        pub fn match(self: *Self, source_image: Image(T), target_image: Image(T)) !void {
            try self.setTarget(target_image);
            try self.setSource(source_image);
            try self.update();
        }

        /// Apply the feature distribution matching transformation.
        /// Modifies the source image in-place to match the target distribution.
        pub fn update(self: *Self) !void {
            if (!self.has_target) return error.NoTargetSet;
            if (!self.has_source or self.source_image == null) return error.NoSourceSet;

            const source_img = self.source_image.?;

            if (T == u8) {
                // Grayscale processing
                const source_size = source_img.rows * source_img.cols;
                var source_matrix = try Matrix(f64).init(self.allocator, source_size, 1);
                defer source_matrix.deinit();

                grayscaleImageToMatrix(source_img, &source_matrix);
                _ = centerImage(&source_matrix, 1);

                // Apply variance matching
                const source_var = blk: {
                    var var_sum: f64 = 0;
                    for (0..source_matrix.rows) |r| {
                        const val = source_matrix.at(r, 0).*;
                        var_sum += val * val;
                    }
                    break :blk var_sum / @as(f64, @floatFromInt(source_matrix.rows));
                };

                const scale_factor = if (source_var > 1e-10) @sqrt(self.target_cov_s[0] / source_var) else 1.0;
                for (0..source_matrix.rows) |r| {
                    source_matrix.at(r, 0).* *= scale_factor;
                }

                grayscaleMatrixToImage(source_matrix, source_img, self.target_mean[0]);
            } else {
                // Color processing
                const source_size = source_img.rows * source_img.cols;
                var feature_mat_source = try Matrix(f64).init(self.allocator, source_size, 3);
                defer feature_mat_source.deinit();

                const source_is_grayscale = getFeatureMatrix(T, source_img, &feature_mat_source);

                if (source_is_grayscale and self.target_is_grayscale) {
                    // Both grayscale - use simple algorithm
                    _ = centerImage(&feature_mat_source, 1);

                    const source_var = blk: {
                        var var_sum: f64 = 0;
                        for (0..feature_mat_source.rows) |r| {
                            const val = feature_mat_source.at(r, 0).*;
                            var_sum += val * val;
                        }
                        break :blk var_sum / @as(f64, @floatFromInt(feature_mat_source.rows));
                    };

                    const scale_factor = if (source_var > 1e-10) @sqrt(self.target_cov_s[0] / source_var) else 1.0;
                    for (0..feature_mat_source.rows) |r| {
                        feature_mat_source.at(r, 0).* *= scale_factor;
                    }

                    reshapeToImage(T, feature_mat_source, source_img, self.target_mean, true);
                } else {
                    // Full color transformation
                    _ = centerImage(&feature_mat_source, 3);

                    // Compute source covariance
                    var source_cov_ops = try OpsBuilder(f64).init(self.allocator, feature_mat_source);
                    defer source_cov_ops.deinit();
                    try source_cov_ops.gemm(
                        true,
                        feature_mat_source,
                        false,
                        1.0 / @as(f64, @floatFromInt(source_size)),
                        0.0,
                        null,
                    );
                    var source_cov_matrix = source_cov_ops.toOwned();
                    defer source_cov_matrix.deinit();

                    const source_cov = source_cov_matrix.toSMatrix(3, 3);
                    const source_svd = svd(f64, 3, 3, source_cov, .{
                        .with_u = true,
                        .with_v = false,
                        .mode = .skinny_u,
                    });

                    // Compute transformation matrix W = U_src * Σ_src^(-1/2) * Σ_target^(1/2) * U_target^T
                    var transform_matrix = try Matrix(f64).init(self.allocator, 3, 3);
                    defer transform_matrix.deinit();

                    // Create Σ_src^(-1/2) * Σ_target^(1/2) diagonal
                    var sigma_combined = try Matrix(f64).init(self.allocator, 3, 3);
                    defer sigma_combined.deinit();
                    @memset(sigma_combined.items, 0);

                    for (0..3) |i| {
                        const source_eigenval = source_svd.s.items[i][0];
                        const target_eigenval = self.target_cov_s[i];

                        if (source_eigenval > 1e-10 and target_eigenval > std.math.floatEps(f64)) {
                            sigma_combined.at(i, i).* = @sqrt(target_eigenval / source_eigenval);
                        } else {
                            sigma_combined.at(i, i).* = 0;
                        }
                    }

                    // Compute W = U_src * Σ_combined * U_target^T
                    var u_source = try Matrix(f64).fromSMatrix(self.allocator, source_svd.u);
                    defer u_source.deinit();

                    var u_target_t = try Matrix(f64).init(self.allocator, 3, 3);
                    defer u_target_t.deinit();
                    for (0..3) |i| {
                        for (0..3) |j| {
                            u_target_t.at(i, j).* = self.target_cov_u.at(j, i).*;
                        }
                    }

                    var w_ops = try OpsBuilder(f64).init(self.allocator, u_source);
                    defer w_ops.deinit();

                    // Apply diagonal matrix
                    for (0..3) |r| {
                        for (0..3) |c| {
                            w_ops.result.at(r, c).* *= sigma_combined.at(c, c).*;
                        }
                    }

                    try w_ops.dot(u_target_t);
                    var w_matrix = w_ops.toOwned();
                    defer w_matrix.deinit();

                    // Apply transformation
                    var result_ops = try OpsBuilder(f64).init(self.allocator, feature_mat_source);
                    defer result_ops.deinit();
                    try result_ops.dot(w_matrix);
                    var result_matrix = result_ops.toOwned();
                    defer result_matrix.deinit();

                    reshapeToImage(T, result_matrix, source_img, self.target_mean, false);
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
/// 1. **Reshape** - Convert images to feature matrices (H×W, 3)
/// 2. **Center** - Subtract mean from both source and target
/// 3. **Whiten** - Transform source to have identity covariance: Cov(X_src) = I
/// 4. **Color Transform** - Apply target covariance: Cov(X_result) = Cov(X_target)
/// 5. **Restore Mean** - Add target mean to final result
/// 6. **Reshape** - Convert back to image format
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
/// var fdm = FeatureDistributionMatching(Rgb).init(allocator);
/// defer fdm.deinit();
/// try fdm.match(source_img, target_img); // Modifies source_img in-place
///
/// // Batch processing with same target style
/// var fdm = FeatureDistributionMatching(Rgb).init(allocator);
/// defer fdm.deinit();
/// try fdm.setTarget(style_image);
/// for (images_to_transform) |img| {
///     try fdm.setSource(img);
///     try fdm.update(); // Modifies img in-place
/// }
/// ```

// ============================================================================
// FDM Helper Functions - Corresponding to the listed steps in the paper
// ============================================================================

/// Step 1: Get feature matrix - reshape to feature matrix (H*W,C)
/// Returns true if the image is grayscale (R=G=B for all pixels)
fn getFeatureMatrix(comptime T: type, image: Image(T), matrix: *Matrix(f64)) bool {
    var is_grayscale = true;
    var i: usize = 0;
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            const p = image.at(r, c);
            matrix.at(i, 0).* = @as(f64, @floatFromInt(p.r)) / 255;
            matrix.at(i, 1).* = @as(f64, @floatFromInt(p.g)) / 255;
            matrix.at(i, 2).* = @as(f64, @floatFromInt(p.b)) / 255;

            if (is_grayscale and (p.r != p.g or p.g != p.b)) {
                is_grayscale = false;
            }
            i += 1;
        }
    }
    return is_grayscale;
}

/// Step 2: Center image - subtract mean
fn centerImage(matrix: *Matrix(f64), comptime channels: usize) [3]f64 {
    var means = [_]f64{0} ** 3;
    for (0..channels) |c| {
        for (0..matrix.rows) |r| {
            means[c] += matrix.at(r, c).*;
        }
        means[c] /= @floatFromInt(matrix.rows);
        for (0..matrix.rows) |r| {
            matrix.at(r, c).* -= means[c];
        }
    }
    return means;
}

/// Steps 5-6: Reshape back to original image shape and add target mean
fn reshapeToImage(comptime T: type, matrix: Matrix(f64), image: Image(T), target_mean: [3]f64, is_grayscale: bool) void {
    var i: usize = 0;
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            if (is_grayscale) {
                // For grayscale, use the single channel for all RGB components
                const gray_val = matrix.at(i, 0).* + target_mean[0];
                const final_gray = @as(u8, @intFromFloat(@round(255 * clamp(gray_val, 0, 1))));
                image.at(r, c).r = final_gray;
                image.at(r, c).g = final_gray;
                image.at(r, c).b = final_gray;
            } else {
                // Step 5 is implicitly done here: Add target mean
                const final_r = matrix.at(i, 0).* + target_mean[0];
                const final_g = matrix.at(i, 1).* + target_mean[1];
                const final_b = matrix.at(i, 2).* + target_mean[2];

                image.at(r, c).r = @intFromFloat(@round(255 * clamp(final_r, 0, 1)));
                image.at(r, c).g = @intFromFloat(@round(255 * clamp(final_g, 0, 1)));
                image.at(r, c).b = @intFromFloat(@round(255 * clamp(final_b, 0, 1)));
            }
            i += 1;
        }
    }
}

/// Helper: Convert grayscale image to matrix
fn grayscaleImageToMatrix(image: Image(u8), matrix: *Matrix(f64)) void {
    var i: usize = 0;
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            const p = image.at(r, c);
            matrix.at(i, 0).* = @as(f64, @floatFromInt(p.*)) / 255.0;
            i += 1;
        }
    }
}

/// Helper: Convert matrix back to grayscale image with target mean
fn grayscaleMatrixToImage(matrix: Matrix(f64), image: Image(u8), target_mean: f64) void {
    var i: usize = 0;
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            const val = clamp(matrix.at(i, 0).* + target_mean, 0, 1);
            image.at(r, c).* = @intFromFloat(@round(255.0 * val));
            i += 1;
        }
    }
}

test "FDM mean and covariance matching" {
    const allocator = testing.allocator;

    // Create source image with known statistics
    var source_img = try Image(Rgb).initAlloc(allocator, 50, 50);
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
    var target_img = try Image(Rgb).initAlloc(allocator, 50, 50);
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
    var fdm = FeatureDistributionMatching(Rgb).init(allocator);
    defer fdm.deinit();
    try fdm.match(source_img, target_img);
    try fdm.update();

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
    var source_img = try Image(u8).initAlloc(allocator, 100, 1);
    defer source_img.deinit(allocator);

    // Fill with values 0-99 for known mean=49.5, variance
    for (source_img.data, 0..) |*pixel, i| {
        pixel.* = @intCast(i);
    }

    // Create target image with different known statistics
    var target_img = try Image(u8).initAlloc(allocator, 100, 1);
    defer target_img.deinit(allocator);

    // Fill with values 100-199 for known mean=149.5
    for (target_img.data, 0..) |*pixel, i| {
        pixel.* = @intCast(100 + i);
    }

    // Apply FDM using new API
    var fdm = FeatureDistributionMatching(u8).init(allocator);
    defer fdm.deinit();
    try fdm.match(source_img, target_img);
    try fdm.update();

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
    var target_img = try Image(Rgb).initAlloc(allocator, 20, 20);
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
        img.* = try Image(Rgb).initAlloc(allocator, 20, 20);
        for (img.data, 0..) |*pixel, i| {
            // Different cool color patterns
            pixel.* = Rgb{
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
    var fdm = FeatureDistributionMatching(Rgb).init(allocator);
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

test "FDM error handling" {
    const allocator = testing.allocator;

    var fdm = FeatureDistributionMatching(Rgb).init(allocator);
    defer fdm.deinit();

    // Test update without setting images
    try testing.expectError(error.NoTargetSet, fdm.update());

    // Set target but not source
    var target_img = try Image(Rgb).initAlloc(allocator, 10, 10);
    defer target_img.deinit(allocator);
    try fdm.setTarget(target_img);

    try testing.expectError(error.NoSourceSet, fdm.update());

    // Now it should work
    var source_img = try Image(Rgb).initAlloc(allocator, 10, 10);
    defer source_img.deinit(allocator);
    try fdm.setSource(source_img);
    try fdm.update(); // Should succeed
}
