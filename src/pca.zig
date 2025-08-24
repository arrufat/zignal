//! Principal Component Analysis (PCA) for dimensionality reduction and feature extraction.
//!
//! - Works on arbitrary-dimensional vectors
//! - Supports both covariance (dim × dim) and Gram (n × n) paths automatically.
//! - Components are stored column-wise in a matrix of shape `dim × k` (orthonormal).
//! - Eigenvalues are singular values squared of centered data, scaled by `1/(n-1)` (variances).
//!
//! Shapes and conventions
//! - Input vectors: `[]const T, of length dim`.
//! - `components`: `Matrix(T)` with shape `dim × k` where each column is a principal direction.
//! - `eigenvalues`: `[]T` length `k`, sorted descending.
//! - Projection of a vector `x`: `coeffs = components^T * (x - mean)` (length `k`).
//! - Reconstruction: `x_hat = mean + components * coeffs`.
//!
//! Example
//! ```zig
//! // Create data matrix with 3 samples of 2D points
//! var data: Matrix(f64) = try .init(allocator, 3, 2);
//! defer data.deinit();
//! data.at(0, 0).* = 1.0; data.at(0, 1).* = 2.0;
//! data.at(1, 0).* = 3.0; data.at(1, 1).* = 4.0;
//! data.at(2, 0).* = 5.0; data.at(2, 1).* = 6.0;
//!
//! var pca: Pca(f64) = try .init(allocator, 2);
//! defer pca.deinit();
//! try pca.fit(data, null); // keep all possible components
//!
//! // Project a single point (allocates a slice owned by caller)
//! const test_point = [_]f64{2.0, 3.0};
//! const coeffs = try pca.project(&test_point);
//! defer allocator.free(coeffs);
//! const reconstructed = try pca.reconstruct(coeffs);
//! defer allocator.free(reconstructed);
//!
//! // Batch transform (m × k matrix)
//! var coeffs_mat = try pca.transform(data);
//! defer coeffs_mat.deinit();
//! ```

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Image = @import("image.zig").Image;
const Matrix = @import("matrix.zig").Matrix;
const OpsBuilder = @import("matrix/OpsBuilder.zig").OpsBuilder;
const Rgb = @import("color.zig").Rgb;

/// Principal Component Analysis
///
/// Type parameters
/// - `T`: floating-point scalar type used for all computations and storage.
///   Typically `f32` (faster, less memory) or `f64` (higher precision).
///   Constraints: `T` must be a floating-point type.
///
/// Notes
/// - The components matrix has shape `dim × k` (columns are principal axes).
/// - Eigenvalues (length `k`) are variances along each component (descending).
/// - Choose `T = f32` for speed and `T = f64` for numerical robustness.
pub fn Pca(comptime T: type) type {
    assert(@typeInfo(T) == .float);

    return struct {
        const Self = @This();

        /// Mean vector for centering data
        mean: []T,
        /// Principal components matrix (dim × num_components)
        components: Matrix(T),
        /// Eigenvalues in descending order
        eigenvalues: []T,
        /// Number of components retained
        num_components: usize,
        /// Dimension of input vectors
        dim: usize,
        /// Memory allocator
        allocator: Allocator,

        /// Initialize an empty PCA instance with runtime dimension
        pub fn init(allocator: Allocator, dim: usize) !Self {
            assert(dim >= 1);
            const mean_slice = try allocator.alloc(T, dim);
            @memset(mean_slice, 0);
            return Self{
                .mean = mean_slice,
                .components = undefined,
                .eigenvalues = &[_]T{},
                .num_components = 0,
                .dim = dim,
                .allocator = allocator,
            };
        }

        /// Free allocated memory
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.mean);
            self.allocator.free(self.eigenvalues);
            if (self.num_components > 0) {
                self.components.deinit();
            }
        }

        /// Fit the PCA model on centered data derived from data matrix.
        /// - data_matrix: training samples matrix (n_samples × dim)
        /// - num_components: number of components to retain; when null keeps `min(n-1, dim)`
        ///
        /// Notes:
        /// - Uses covariance path when `n > dim`, Gram path otherwise.
        /// - Replaces previous `components`/`eigenvalues` if already fitted.
        /// - Returns `error.InsufficientData` for `n < 2` and `error.InvalidComponents` for `0`.
        pub fn fit(self: *Self, data_matrix: Matrix(T), num_components: ?usize) !void {
            const n_samples = data_matrix.rows;
            const data_dim = data_matrix.cols;

            if (data_dim != self.dim) return error.DimensionMismatch;
            if (n_samples == 0) return error.NoVectors;
            if (n_samples == 1) return error.InsufficientData;

            const max_components = @min(n_samples - 1, self.dim);
            if (num_components) |k| {
                if (k == 0) return error.InvalidComponents;
            }
            const requested_components = num_components orelse max_components;
            const actual_components = @min(requested_components, max_components);

            // If this instance was previously fitted, free old allocations
            if (self.eigenvalues.len > 0) {
                self.allocator.free(self.eigenvalues);
                self.eigenvalues = &[_]T{};
            }
            if (self.num_components > 0) {
                self.components.deinit();
                self.num_components = 0;
            }

            // Compute mean vector using scalar operations
            @memset(self.mean, 0);
            for (0..n_samples) |i| {
                for (0..self.dim) |j| {
                    self.mean[j] += data_matrix.at(i, j).*;
                }
            }
            const n_samples_f = @as(T, @floatFromInt(n_samples));
            for (0..self.dim) |j| {
                self.mean[j] /= n_samples_f;
            }

            // Create centered data matrix
            var centered_matrix: Matrix(T) = try .init(self.allocator, n_samples, self.dim);
            defer centered_matrix.deinit();

            for (0..n_samples) |i| {
                for (0..self.dim) |j| {
                    centered_matrix.at(i, j).* = data_matrix.at(i, j).* - self.mean[j];
                }
            }

            // Choose computation path based on data dimensions
            if (n_samples <= self.dim) {
                // Few samples: use Gram matrix approach (n_samples × n_samples)
                try self.computeComponentsFromGram(&centered_matrix, actual_components);
            } else {
                // Many samples: use covariance matrix approach (dim × dim)
                try self.computeComponentsFromCovariance(&centered_matrix, actual_components);
            }
        }

        /// Project a single vector onto PCA space, returning a freshly allocated coefficient slice.
        /// - Input: `vector` slice of length `dim`
        /// - Output: `[]T` of length `num_components` (caller frees)
        /// - For hot paths, prefer `projectInto` to reuse a buffer.
        pub fn project(self: Self, vector: []const T) ![]T {
            if (self.num_components == 0) return error.NotFitted;
            if (vector.len != self.dim) return error.DimensionMismatch;

            // Allocate coefficients
            const coefficients = try self.allocator.alloc(T, self.num_components);
            errdefer self.allocator.free(coefficients);

            try self.projectInto(coefficients, vector);
            return coefficients;
        }

        /// Project a single vector into a caller-provided buffer (avoids allocation).
        /// - `dst.len` must equal `num_components`.
        /// - Writes `components^T * (vector - mean)` into `dst`.
        pub fn projectInto(self: Self, dst: []T, vector: []const T) !void {
            if (self.num_components == 0) return error.NotFitted;
            if (dst.len != self.num_components) return error.InvalidCoefficients;
            if (vector.len != self.dim) return error.DimensionMismatch;

            for (0..self.num_components) |i| {
                var sum: T = 0;
                for (0..self.dim) |j| {
                    const centered = vector[j] - self.mean[j];
                    sum += centered * self.components.at(j, i).*;
                }
                dst[i] = sum;
            }
        }

        /// Reconstruct a vector from PCA coefficients: `mean + components * coefficients`.
        /// - `coefficients.len` must equal `num_components`.
        /// - Returns allocated slice of length `dim` (caller must free)
        pub fn reconstruct(self: Self, coefficients: []const T) ![]T {
            if (self.num_components == 0) return error.NotFitted;
            if (coefficients.len != self.num_components) return error.InvalidCoefficients;

            // Allocate result
            var result = try self.allocator.alloc(T, self.dim);
            errdefer self.allocator.free(result);

            // Start with mean
            @memcpy(result, self.mean);

            // Add weighted components
            for (0..self.num_components) |i| {
                const weight = coefficients[i];
                for (0..self.dim) |j| {
                    result[j] += weight * self.components.at(j, i).*;
                }
            }

            return result;
        }

        /// Batch-transform: project a data matrix onto PCA space.
        /// - data_matrix: samples matrix (n_samples × dim)
        /// - Returns: transformed matrix (n_samples × num_components)
        pub fn transform(self: Self, data_matrix: Matrix(T)) !Matrix(T) {
            if (self.num_components == 0) return error.NotFitted;
            if (data_matrix.cols != self.dim) return error.DimensionMismatch;
            if (data_matrix.rows == 0) return error.NoVectors;

            // Build centered data matrix
            var centered_matrix: Matrix(T) = try Matrix(T).init(self.allocator, data_matrix.rows, self.dim);
            defer centered_matrix.deinit();

            for (0..data_matrix.rows) |i| {
                for (0..self.dim) |j| {
                    centered_matrix.at(i, j).* = data_matrix.at(i, j).* - self.mean[j];
                }
            }

            // Compute centered * components
            var ops = try OpsBuilder(T).init(self.allocator, centered_matrix);
            defer ops.deinit();
            try ops.gemm(false, self.components, false, 1.0, 0.0, null);
            return ops.toOwned();
        }

        /// Get the mean vector
        pub fn getMean(self: Self) []const T {
            return self.mean;
        }

        /// Compute principal components using the covariance matrix approach.
        ///
        /// This method is efficient when n_samples > dimensions because it computes
        /// the covariance matrix C = X^T * X / (n-1), which is only dim × dim.
        ///
        /// Mathematical basis:
        /// - The eigenvectors of the covariance matrix are the principal components
        /// - The eigenvalues represent the variance along each component
        /// - We directly get the components without additional projection
        ///
        /// Example: For 1000 RGB images (1000×3 matrix), we compute a 3×3 covariance
        /// matrix instead of a 1000×1000 Gram matrix, making it much more efficient.
        fn computeComponentsFromCovariance(self: *Self, data_matrix: *Matrix(T), num_components: usize) !void {
            // Compute scaled covariance matrix (X^T * X) / (n-1) in single GEMM operation
            const n_samples = data_matrix.rows;
            const scale = 1.0 / @as(T, @floatFromInt(n_samples - 1));

            var ops = try OpsBuilder(T).init(self.allocator, data_matrix.*);
            defer ops.deinit();
            // Use GEMM directly: scale * (X^T * X) + 0 * C
            // This combines matrix multiplication and scaling in one optimized operation
            try ops.gemm(true, data_matrix.*, false, scale, 0.0, null);
            var cov_matrix = ops.toOwned();
            defer cov_matrix.deinit();

            const n = cov_matrix.rows;

            // Prepare outputs
            self.num_components = num_components;
            self.eigenvalues = try self.allocator.alloc(T, num_components);
            self.components = try Matrix(T).init(self.allocator, self.dim, num_components);

            // Compute SVD of covariance matrix
            var result = try cov_matrix.svd(self.allocator, .{
                .with_u = true,
                .with_v = false,
                .mode = .skinny_u,
            });
            defer result.deinit();
            if (result.converged != 0) return error.SvdFailed;

            // Extract eigenvalues and components
            for (0..num_components) |i| {
                if (i < n) {
                    self.eigenvalues[i] = result.s.at(i, 0).*;
                    for (0..self.dim) |j| {
                        self.components.at(j, i).* = if (j < n) result.u.at(j, i).* else 0;
                    }
                } else {
                    self.eigenvalues[i] = 0;
                    for (0..self.dim) |j| self.components.at(j, i).* = 0;
                }
            }
        }

        /// Compute principal components using the Gram matrix approach.
        ///
        /// This method is efficient when n_samples ≤ dimensions because it computes
        /// the Gram matrix G = X * X^T / (n-1), which is only n_samples × n_samples.
        ///
        /// Mathematical basis:
        /// - The Gram matrix and covariance matrix share the same non-zero eigenvalues
        /// - The eigenvectors of G are related to the principal components through X
        /// - We must project the eigenvectors back: PC_i = X^T * u_i / sqrt(λ_i * n)
        ///
        /// Why the projection step?
        /// - Eigenvectors of G live in sample space, not feature space
        /// - We need to transform them back to get the actual principal components
        ///
        /// Example: For 10 high-dimensional vectors (10×1000 matrix), we compute a
        /// 10×10 Gram matrix instead of a 1000×1000 covariance matrix.
        fn computeComponentsFromGram(self: *Self, data_matrix: *Matrix(T), num_components: usize) !void {
            // Compute scaled Gram matrix (X * X^T) / (n-1) in single GEMM operation
            const n_samples = data_matrix.rows;
            const scale = 1.0 / @as(T, @floatFromInt(n_samples - 1));

            var ops = try OpsBuilder(T).init(self.allocator, data_matrix.*);
            defer ops.deinit();
            // Use GEMM directly: scale * (X * X^T) + 0 * C
            // This combines matrix multiplication and scaling in one optimized operation
            try ops.gemm(false, data_matrix.*, true, scale, 0.0, null);
            var gram_matrix = ops.toOwned();
            defer gram_matrix.deinit();

            const n = gram_matrix.rows;

            // Extract components by projecting data onto eigenvectors
            self.num_components = num_components;
            self.eigenvalues = try self.allocator.alloc(T, num_components);
            self.components = try Matrix(T).init(self.allocator, self.dim, num_components);

            // Compute SVD of Gram matrix
            var result = try gram_matrix.svd(self.allocator, .{
                .with_u = true,
                .with_v = false,
                .mode = .skinny_u,
            });
            defer result.deinit();
            if (result.converged != 0) return error.SvdFailed;

            // Project eigenvectors back to feature space
            const actual_components = @min(num_components, n);
            for (0..actual_components) |i| {
                const eigenval = result.s.at(i, 0).*;
                self.eigenvalues[i] = eigenval;

                if (eigenval > 1e-10) {
                    // Principal component: X^T u_i / sqrt((n-1) * eigenval)
                    for (0..self.dim) |j| {
                        var sum: T = 0;
                        for (0..n) |k| {
                            sum += data_matrix.at(k, j).* * result.u.at(k, i).*;
                        }
                        self.components.at(j, i).* = sum / @sqrt(eigenval * @as(T, @floatFromInt(n_samples - 1)));
                    }
                } else {
                    for (0..self.dim) |j| self.components.at(j, i).* = 0;
                }
            }
            for (actual_components..num_components) |i| {
                self.eigenvalues[i] = 0;
                for (0..self.dim) |j| self.components.at(j, i).* = 0;
            }
        }
    };
}

// Tests

test "PCA initialization and cleanup" {
    const allocator = std.testing.allocator;

    var pca = try Pca(f64).init(allocator, 2);
    defer pca.deinit();

    try std.testing.expectEqual(@as(usize, 0), pca.num_components);
    try std.testing.expectEqual(@as(usize, 2), pca.dim);
}

test "PCA on 2D vectors" {
    const allocator = std.testing.allocator;

    // Create data matrix with 4 samples of 2D points
    var data = try Matrix(f64).init(allocator, 4, 2);
    defer data.deinit();
    data.at(0, 0).* = 1.0;
    data.at(0, 1).* = 2.0;
    data.at(1, 0).* = 3.0;
    data.at(1, 1).* = 4.0;
    data.at(2, 0).* = 5.0;
    data.at(2, 1).* = 6.0;
    data.at(3, 0).* = 7.0;
    data.at(3, 1).* = 8.0;

    var pca = try Pca(f64).init(allocator, 2);
    defer pca.deinit();

    try pca.fit(data, null);

    // Should have fitted successfully
    try std.testing.expect(pca.num_components > 0);

    // Test projection and reconstruction
    const test_vec = [_]f64{ 4.0, 5.0 };
    const coeffs = try pca.project(&test_vec);
    defer allocator.free(coeffs);

    const reconstructed = try pca.reconstruct(coeffs);
    defer allocator.free(reconstructed);

    // Reconstruction should be close to original (within numerical precision)
    try std.testing.expect(@abs(reconstructed[0] - 4.0) < 1e-10);
    try std.testing.expect(@abs(reconstructed[1] - 5.0) < 1e-10);
}

test "PCA on image color data using Point conversion" {
    const allocator = std.testing.allocator;
    const Point3 = @import("geometry/Point.zig").Point(3, f64);

    // Create a simple gradient image
    var image = try Image(Rgb).init(allocator, 2, 2);
    defer image.deinit(allocator);

    image.data[0] = Rgb{ .r = 0, .g = 0, .b = 0 }; // Black
    image.data[1] = Rgb{ .r = 85, .g = 85, .b = 85 }; // Dark gray
    image.data[2] = Rgb{ .r = 170, .g = 170, .b = 170 }; // Light gray
    image.data[3] = Rgb{ .r = 255, .g = 255, .b = 255 }; // White

    // Convert to color matrix (4 samples × 3 dimensions)
    var color_matrix = try Matrix(f64).init(allocator, 4, 3);
    defer color_matrix.deinit();

    for (image.data, 0..) |pixel, i| {
        const point = Point3.fromColor(pixel);
        const vec = point.asVector();
        color_matrix.at(i, 0).* = vec[0];
        color_matrix.at(i, 1).* = vec[1];
        color_matrix.at(i, 2).* = vec[2];
    }

    // Apply PCA to color data
    var pca = try Pca(f64).init(allocator, 3);
    defer pca.deinit();

    try pca.fit(color_matrix, 1); // Keep only 1 component

    // Test basic functionality
    try std.testing.expect(pca.num_components == 1);

    // Project and reconstruct a point
    const test_color = [_]f64{ 0, 0, 0 }; // Black
    const coeffs = try pca.project(&test_color);
    defer allocator.free(coeffs);

    const reconstructed = try pca.reconstruct(coeffs);
    defer allocator.free(reconstructed);
    // Just verify it works - reconstruction is used in defer above
}

test "PCA Gram path normalization and direction" {
    const allocator = std.testing.allocator;

    // Two 3D samples along x-axis -> triggers Gram path (n_samples <= dim)
    var data = try Matrix(f64).init(allocator, 2, 3);
    defer data.deinit();
    data.at(0, 0).* = 1.0;
    data.at(0, 1).* = 0.0;
    data.at(0, 2).* = 0.0;
    data.at(1, 0).* = 3.0;
    data.at(1, 1).* = 0.0;
    data.at(1, 2).* = 0.0;

    var pca = try Pca(f64).init(allocator, 3);
    defer pca.deinit();
    try pca.fit(data, 1);

    // First eigenvalue should be 2 (since covariance on centered data has [[2,0,0],...])
    try std.testing.expect(@abs(pca.eigenvalues[0] - 2.0) < 1e-9);

    // First component direction should align with x-axis (sign-insensitive)
    const c0x = pca.components.at(0, 0).*;
    const c0y = pca.components.at(1, 0).*;
    const c0z = pca.components.at(2, 0).*;
    try std.testing.expect(@abs(@abs(c0x) - 1.0) < 1e-9);
    try std.testing.expect(@abs(c0y) < 1e-12);
    try std.testing.expect(@abs(c0z) < 1e-12);

    // Batch transform should match per-vector projection
    var coeffs_matrix = try pca.transform(data);
    defer coeffs_matrix.deinit();

    const test_vec = [_]f64{ 1.0, 0.0, 0.0 };
    const coeffs0 = try allocator.alloc(f64, pca.num_components);
    defer allocator.free(coeffs0);
    try pca.projectInto(coeffs0, &test_vec);

    try std.testing.expect(@abs(coeffs0[0] - coeffs_matrix.at(0, 0).*) < 1e-12);
}
