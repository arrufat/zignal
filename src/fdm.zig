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

/// Feature Distribution Matching (FDM) for image style transfer and domain adaptation.
///
/// Transfers the color distribution (mean and covariance) from a reference image to a source image,
/// effectively matching the "style" or "look" of the reference while preserving the structure of the source.
///
/// ## Algorithm
/// FDM works by matching the first and second-order statistics of pixel distributions:
/// 1. **Reshape** - Convert images to feature matrices (H×W, 3)
/// 2. **Center** - Subtract mean from both source and reference
/// 3. **Whiten** - Transform source to have identity covariance: Cov(X_src) = I
/// 4. **Color Transform** - Apply reference covariance: Cov(X_result) = Cov(X_ref)
/// 5. **Restore Mean** - Add reference mean to final result
/// 6. **Reshape** - Convert back to image format
///
/// ## Mathematical Foundation
/// Given source X_src and reference X_ref, FDM computes:
/// ```
/// X_result = (X_src - μ_src) * Σ_src^(-1/2) * U_src * Σ_ref^(1/2) * U_ref^T + μ_ref
/// ```
/// Where μ is mean, Σ is covariance eigenvalues, and U is covariance eigenvectors.
///
/// ## Paper Reference
/// "Keep it Simple: Image Statistics Matching for Domain Adaptation"
/// by A. Abramov, et al. (2020)
/// https://arxiv.org/abs/2005.12551
///
/// ## Supported Image Types
/// - `Rgb`: 24-bit color images
/// - `Rgba`: 32-bit color images with alpha (alpha channel preserved)
/// - `u8`: Grayscale images (uses simplified 1D algorithm)
///
/// ## Implementation Notes
/// - Automatically detects grayscale images and uses optimized 1D algorithm
/// - Handles edge cases like zero variance gracefully
/// - Uses SVD for robust covariance decomposition
/// - All operations performed in f64 precision, converted back to u8
///
/// ## Parameters
/// - `T`: Image pixel type (Rgb, Rgba, or u8)
/// - `gpa`: General purpose allocator for temporary matrices
/// - `src_img`: Source image to be modified (input/output)
/// - `ref_img`: Reference image providing target distribution (input only)
///
/// ## Example
/// ```zig
/// var src = try loadPng(Rgb, allocator, "source.png");
/// defer src.deinit(allocator);
/// var ref = try loadPng(Rgb, allocator, "reference.png");
/// defer ref.deinit(allocator);
///
/// try featureDistributionMatch(Rgb, allocator, src, ref);
/// try savePng(Rgb, allocator, src, "result.png");
/// ```
pub fn featureDistributionMatch(
    T: type,
    gpa: std.mem.Allocator,
    src_img: Image(T),
    ref_img: Image(T),
) !void {
    comptime assert(T == Rgb or T == Rgba or T == u8);

    if (T == u8) {
        return featureDistributionMatchGrayscale(gpa, src_img, ref_img);
    }

    // Use unified algorithm that handles both grayscale and color cases

    // 1.) reshape to feature matrix (H*W,C) and detect if grayscale
    const src_size = src_img.rows * src_img.cols;
    var feature_mat_src = try Matrix(f64).init(gpa, src_size, 3);
    defer feature_mat_src.deinit();
    const src_is_grayscale = getFeatureMatrix(T, src_img, &feature_mat_src);

    const ref_size = ref_img.rows * ref_img.cols;
    var feature_mat_ref = try Matrix(f64).init(gpa, ref_size, 3);
    defer feature_mat_ref.deinit();
    const ref_is_grayscale = getFeatureMatrix(T, ref_img, &feature_mat_ref);

    // Use the especialized grayscale algorithm if both images are grayscale
    if (src_is_grayscale and ref_is_grayscale) {
        // Use simplified 1D algorithm for grayscale images
        // 2.) center (subtract mean) - only first column
        _ = centerImage(&feature_mat_src, 1)[0];
        const ref_mean = centerImage(&feature_mat_ref, 1)[0];

        // 3-4.) Simple grayscale distribution matching
        grayscaleDistributionMatch(&feature_mat_src, feature_mat_ref);

        // 5-6.) Add reference mean and reshape
        const reference_mean = [_]f64{ ref_mean, 0, 0 };
        reshapeToImage(T, feature_mat_src, src_img, reference_mean, true);
    } else {
        // Use full 3D algorithm - handles mixed grayscale/color cases correctly
        // 2.) center (subtract mean)
        _ = centerImage(&feature_mat_src, 3);
        const reference_mean = centerImage(&feature_mat_ref, 3);

        // 3.) whitening: cov(feature_mat_src) = I
        var feature_mat_src_white = try whitening(gpa, feature_mat_src, src_size);
        defer feature_mat_src_white.deinit();

        // 4.) transform covariance: make cov(feature_mat_src_transformed) = cov(feature_mat_ref)
        var feature_mat_src_transformed = try covarianceTransformation(gpa, feature_mat_src_white, feature_mat_ref, ref_size);
        defer feature_mat_src_transformed.deinit();

        // 5.) Add reference mean + 6.) Reshape
        reshapeToImage(T, feature_mat_src_transformed, src_img, reference_mean, false);
    }
}

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

/// Step 3: Whitening - make cov(feature_mat_src) = I
fn whitening(
    gpa: std.mem.Allocator,
    feature_matrix: Matrix(f64),
    matrix_size: usize,
) !Matrix(f64) {
    // Compute covariance matrix and SVD decomposition
    var ops = try OpsBuilder(f64).init(gpa, feature_matrix);
    defer ops.deinit();
    try ops.transpose();
    try ops.dot(feature_matrix);
    try ops.scale(1.0 / @as(f64, @floatFromInt(matrix_size)));
    var cov_matrix = ops.toOwned();
    defer cov_matrix.deinit();

    var cov: SMatrix(f64, 3, 3) = .{};
    for (0..cov.cols) |c| {
        for (0..cov.rows) |r| {
            cov.items[r][c] = cov_matrix.at(r, c).*;
        }
    }

    const res = svd(f64, cov.rows, cov.cols, cov, .{
        .with_u = true,
        .with_v = false,
        .mode = .skinny_u,
    });

    var u_matrix = try Matrix(f64).init(gpa, res[0].rows, res[0].cols);
    defer u_matrix.deinit();
    for (0..u_matrix.rows) |r| {
        for (0..u_matrix.cols) |c| {
            u_matrix.at(r, c).* = res[0].items[r][c];
        }
    }

    // Create whitening matrix (Σ^(-1/2))
    var whitening_matrix = try Matrix(f64).init(gpa, 3, 3);
    defer whitening_matrix.deinit();
    for (0..whitening_matrix.rows) |r| {
        for (0..whitening_matrix.cols) |c| {
            if (r == c) {
                const eigenval = res[1].items[r][0];
                // Avoid division by zero or very small numbers
                if (eigenval > 1e-10) {
                    whitening_matrix.at(r, c).* = 1 / @sqrt(eigenval);
                } else {
                    whitening_matrix.at(r, c).* = 0;
                }
            } else {
                whitening_matrix.at(r, c).* = 0;
            }
        }
    }

    // Apply whitening: X_white = X * U * Σ^(-1/2)
    var whitening_ops = try OpsBuilder(f64).init(gpa, feature_matrix);
    defer whitening_ops.deinit();
    try whitening_ops.dot(u_matrix);
    try whitening_ops.dot(whitening_matrix);
    return whitening_ops.toOwned();
}

/// Step 4: Covariance transformation - transform to match reference covariance
fn covarianceTransformation(
    gpa: std.mem.Allocator,
    whitened_src: Matrix(f64),
    ref_feature_matrix: Matrix(f64),
    ref_size: usize,
) !Matrix(f64) {
    // Compute reference covariance and decomposition
    var ref_ops = try OpsBuilder(f64).init(gpa, ref_feature_matrix);
    defer ref_ops.deinit();
    try ref_ops.transpose();
    try ref_ops.dot(ref_feature_matrix);
    try ref_ops.scale(1.0 / @as(f64, @floatFromInt(ref_size)));
    var ref_cov_matrix = ref_ops.toOwned();
    defer ref_cov_matrix.deinit();

    var ref_cov: SMatrix(f64, 3, 3) = .{};
    for (0..ref_cov.cols) |c| {
        for (0..ref_cov.rows) |r| {
            ref_cov.items[r][c] = ref_cov_matrix.at(r, c).*;
        }
    }

    const ref_res = svd(f64, ref_cov.rows, ref_cov.cols, ref_cov, .{
        .with_u = true,
        .with_v = false,
        .mode = .skinny_u,
    });

    var ref_u = try Matrix(f64).init(gpa, ref_res[0].rows, ref_res[0].cols);
    defer ref_u.deinit();
    for (0..ref_u.rows) |r| {
        for (0..ref_u.cols) |c| {
            ref_u.at(r, c).* = ref_res[0].items[r][c];
        }
    }

    // Create reference transformation matrix (Σ_ref^(1/2))
    var ref_transform = try Matrix(f64).init(gpa, 3, 3);
    defer ref_transform.deinit();
    for (0..ref_transform.rows) |r| {
        for (0..ref_transform.cols) |c| {
            if (r == c) {
                const ref_eigenval = ref_res[1].items[r][0];
                // Protect against non-positive eigenvalues
                if (ref_eigenval > std.math.floatEps(f64)) {
                    ref_transform.at(r, c).* = @sqrt(ref_eigenval);
                } else {
                    ref_transform.at(r, c).* = 0;
                }
            } else {
                ref_transform.at(r, c).* = 0;
            }
        }
    }

    // Create U_ref^T
    var ref_u_ops = try OpsBuilder(f64).init(gpa, ref_u);
    defer ref_u_ops.deinit();
    try ref_u_ops.transpose();
    var ref_u_transposed = ref_u_ops.toOwned();
    defer ref_u_transposed.deinit();

    // Apply transformation: X_transformed = X_white * Σ_ref^(1/2) * U_ref^T
    var transform_ops = try OpsBuilder(f64).init(gpa, whitened_src);
    defer transform_ops.deinit();
    try transform_ops.dot(ref_transform);
    try transform_ops.dot(ref_u_transposed);
    return transform_ops.toOwned();
}

/// Step 6: Reshape back to original image shape
/// Note: Step 5 (add reference mean) is implicitly done here
fn reshapeToImage(comptime T: type, matrix: Matrix(f64), image: Image(T), reference_mean: [3]f64, is_grayscale: bool) void {
    var i: usize = 0;
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            if (is_grayscale) {
                // For grayscale, use the single channel for all RGB components
                const gray_val = matrix.at(i, 0).* + reference_mean[0];
                const final_gray = @as(u8, @intFromFloat(@round(255 * clamp(gray_val, 0, 1))));
                image.at(r, c).r = final_gray;
                image.at(r, c).g = final_gray;
                image.at(r, c).b = final_gray;
            } else {
                // Step 5 is implicitly done here: Add reference mean
                const final_r = matrix.at(i, 0).* + reference_mean[0];
                const final_g = matrix.at(i, 1).* + reference_mean[1];
                const final_b = matrix.at(i, 2).* + reference_mean[2];

                image.at(r, c).r = @intFromFloat(@round(255 * clamp(final_r, 0, 1)));
                image.at(r, c).g = @intFromFloat(@round(255 * clamp(final_g, 0, 1)));
                image.at(r, c).b = @intFromFloat(@round(255 * clamp(final_b, 0, 1)));
            }
            i += 1;
        }
    }
}

/// Simple 1D version for grayscale images
fn grayscaleDistributionMatch(src_matrix: *Matrix(f64), ref_matrix: Matrix(f64)) void {
    // Compute standard deviations
    var src_var: f64 = 0;
    for (0..src_matrix.rows) |r| {
        const val = src_matrix.at(r, 0).*;
        src_var += val * val;
    }
    src_var /= @floatFromInt(src_matrix.rows);
    const src_std = @sqrt(src_var);

    var ref_var: f64 = 0;
    for (0..ref_matrix.rows) |r| {
        const val = ref_matrix.at(r, 0).*;
        ref_var += val * val;
    }
    ref_var /= @floatFromInt(ref_matrix.rows);
    const ref_std = @sqrt(ref_var);

    // Apply transformation: scale by ratio of standard deviations
    const scale_factor = if (src_std > 1e-10) ref_std / src_std else 1.0;
    for (0..src_matrix.rows) |r| {
        src_matrix.at(r, 0).* *= scale_factor;
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

/// Helper: Convert matrix back to grayscale image with reference mean
fn grayscaleMatrixToImage(matrix: Matrix(f64), image: Image(u8), ref_mean: f64) void {
    var i: usize = 0;
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            const val = clamp(matrix.at(i, 0).* + ref_mean, 0, 1);
            image.at(r, c).* = @intFromFloat(@round(255.0 * val));
            i += 1;
        }
    }
}

/// Computes the feature distribution matching for grayscale images using unified helper functions
fn featureDistributionMatchGrayscale(
    gpa: std.mem.Allocator,
    src_img: Image(u8),
    ref_img: Image(u8),
) !void {
    const src_size = src_img.rows * src_img.cols;
    var src_matrix = try Matrix(f64).init(gpa, src_size, 1);
    defer src_matrix.deinit();
    const ref_size = ref_img.rows * ref_img.cols;
    var ref_matrix = try Matrix(f64).init(gpa, ref_size, 1);
    defer ref_matrix.deinit();

    // 1. Convert grayscale images to matrices
    grayscaleImageToMatrix(src_img, &src_matrix);
    grayscaleImageToMatrix(ref_img, &ref_matrix);

    // 2. Center using the shared helper function (only first column)
    _ = centerImage(&src_matrix, 1);
    const ref_mean = centerImage(&ref_matrix, 1)[0];

    // 3-4. Use the shared grayscale distribution matching function
    grayscaleDistributionMatch(&src_matrix, ref_matrix);

    // 5-6. Convert back to image using shared helper
    grayscaleMatrixToImage(src_matrix, src_img, ref_mean);
}

test "FDM mean and covariance matching" {
    const allocator = testing.allocator;

    // Create source image with known statistics
    var src_img = try Image(Rgb).initAlloc(allocator, 50, 50);
    defer src_img.deinit(allocator);
    for (src_img.data, 0..) |*pixel, i| {
        // Create specific pattern for known covariance structure
        const x = i % 50;
        const y = i / 50;
        pixel.* = Rgb{
            .r = @intCast(100 + (x % 20)), // Variance in R
            .g = @intCast(150 + (y % 15)), // Variance in G
            .b = @intCast(80 + ((x + y) % 25)), // Variance in B, correlated with R+G
        };
    }

    // Create reference image with different known statistics
    var ref_img = try Image(Rgb).initAlloc(allocator, 50, 50);
    defer ref_img.deinit(allocator);
    for (ref_img.data, 0..) |*pixel, i| {
        const x = i % 50;
        const y = i / 50;
        pixel.* = Rgb{
            .r = @intCast(50 + (x % 30)), // Different variance in R
            .g = @intCast(70 + (y % 20)), // Different variance in G
            .b = @intCast(90 + ((x + y) % 35)), // Different variance in B
        };
    }

    // Calculate reference statistics before FDM
    var ref_sum_r: u32 = 0;
    var ref_sum_g: u32 = 0;
    var ref_sum_b: u32 = 0;
    for (ref_img.data) |pixel| {
        ref_sum_r += pixel.r;
        ref_sum_g += pixel.g;
        ref_sum_b += pixel.b;
    }
    const ref_mean_r = @as(f64, @floatFromInt(ref_sum_r)) / @as(f64, @floatFromInt(ref_img.data.len));
    const ref_mean_g = @as(f64, @floatFromInt(ref_sum_g)) / @as(f64, @floatFromInt(ref_img.data.len));
    const ref_mean_b = @as(f64, @floatFromInt(ref_sum_b)) / @as(f64, @floatFromInt(ref_img.data.len));

    // Calculate reference variances
    var ref_var_r: f64 = 0;
    var ref_var_g: f64 = 0;
    var ref_var_b: f64 = 0;
    for (ref_img.data) |pixel| {
        const dr = @as(f64, @floatFromInt(pixel.r)) - ref_mean_r;
        const dg = @as(f64, @floatFromInt(pixel.g)) - ref_mean_g;
        const db = @as(f64, @floatFromInt(pixel.b)) - ref_mean_b;
        ref_var_r += dr * dr;
        ref_var_g += dg * dg;
        ref_var_b += db * db;
    }
    ref_var_r /= @as(f64, @floatFromInt(ref_img.data.len));
    ref_var_g /= @as(f64, @floatFromInt(ref_img.data.len));
    ref_var_b /= @as(f64, @floatFromInt(ref_img.data.len));

    // Apply FDM
    try featureDistributionMatch(Rgb, allocator, src_img, ref_img);

    // Calculate result statistics
    var result_sum_r: u32 = 0;
    var result_sum_g: u32 = 0;
    var result_sum_b: u32 = 0;
    for (src_img.data) |pixel| {
        result_sum_r += pixel.r;
        result_sum_g += pixel.g;
        result_sum_b += pixel.b;
    }
    const result_mean_r = @as(f64, @floatFromInt(result_sum_r)) / @as(f64, @floatFromInt(src_img.data.len));
    const result_mean_g = @as(f64, @floatFromInt(result_sum_g)) / @as(f64, @floatFromInt(src_img.data.len));
    const result_mean_b = @as(f64, @floatFromInt(result_sum_b)) / @as(f64, @floatFromInt(src_img.data.len));

    // Calculate result variances
    var result_var_r: f64 = 0;
    var result_var_g: f64 = 0;
    var result_var_b: f64 = 0;
    for (src_img.data) |pixel| {
        const dr = @as(f64, @floatFromInt(pixel.r)) - result_mean_r;
        const dg = @as(f64, @floatFromInt(pixel.g)) - result_mean_g;
        const db = @as(f64, @floatFromInt(pixel.b)) - result_mean_b;
        result_var_r += dr * dr;
        result_var_g += dg * dg;
        result_var_b += db * db;
    }
    result_var_r /= @as(f64, @floatFromInt(src_img.data.len));
    result_var_g /= @as(f64, @floatFromInt(src_img.data.len));
    result_var_b /= @as(f64, @floatFromInt(src_img.data.len));

    // Test 1: Mean should match reference (within tolerance for rounding)
    try expectApproxEqAbs(result_mean_r, ref_mean_r, 2.0);
    try expectApproxEqAbs(result_mean_g, ref_mean_g, 2.0);
    try expectApproxEqAbs(result_mean_b, ref_mean_b, 2.0);

    // Test 2: Variances should be close to reference (FDM matches covariance structure)
    try expectApproxEqAbs(result_var_r, ref_var_r, 1);
    try expectApproxEqAbs(result_var_g, ref_var_g, 1);
    try expectApproxEqAbs(result_var_b, ref_var_b, 1);
}

test "FDM grayscale mean and variance matching" {
    const allocator = testing.allocator;

    // Create source image with known statistics
    var src_img = try Image(u8).initAlloc(allocator, 100, 1);
    defer src_img.deinit(allocator);

    // Fill with values 0-99 for known mean=49.5, variance
    for (src_img.data, 0..) |*pixel, i| {
        pixel.* = @intCast(i);
    }

    // Create reference image with different known statistics
    var ref_img = try Image(u8).initAlloc(allocator, 100, 1);
    defer ref_img.deinit(allocator);

    // Fill with values 100-199 for known mean=149.5
    for (ref_img.data, 0..) |*pixel, i| {
        pixel.* = @intCast(100 + i);
    }

    // Apply FDM
    try featureDistributionMatch(u8, allocator, src_img, ref_img);

    // Calculate actual mean of result
    var sum: u32 = 0;
    for (src_img.data) |pixel| {
        sum += pixel;
    }
    const actual_mean = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(src_img.data.len));

    // Mean should be the reference mean (149.5)
    try expectEqual(actual_mean, 149.5);
}
