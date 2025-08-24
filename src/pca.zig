//! Principal Component Analysis (PCA) for dimensionality reduction and feature extraction.
//!
//! - Works on arbitrary-dimensional vectors using Zig's SIMD vectors (`@Vector(dim, T)`).
//! - Supports both covariance (dim × dim) and Gram (n × n) paths automatically.
//! - Components are stored column-wise in a matrix of shape `dim × k` (orthonormal).
//! - Eigenvalues are singular values squared of centered data, scaled by `1/(n-1)` (variances).
//!
//! Shapes and conventions
//! - Input vectors: `Vec = @Vector(dim, T)`.
//! - `components`: `Matrix(T)` with shape `dim × k` where each column is a principal direction.
//! - `eigenvalues`: `[]T` length `k`, sorted descending.
//! - Projection of a vector `x`: `coeffs = components^T * (x - mean)` (length `k`).
//! - Reconstruction: `x_hat = mean + components * coeffs`.
//!
//! Example
//! ```zig
//! const points_2d = [_]@Vector(2, f64){ .{1.0, 2.0}, .{3.0, 4.0}, .{5.0, 6.0} };
//! var pca_2d = PrincipalComponentAnalysis(f64, 2).init(allocator);
//! defer pca_2d.deinit();
//! try pca_2d.fit(&points_2d, null); // keep all possible components
//!
//! // Project (allocates a slice owned by caller)
//! const coeffs = try pca_2d.project(.{2.0, 3.0});
//! defer allocator.free(coeffs);
//! const reconstructed = try pca_2d.reconstruct(coeffs);
//!
//! // No-alloc projection into a caller-provided buffer
//! var tmp = try allocator.alloc(f64, pca_2d.num_components);
//! defer allocator.free(tmp);
//! try pca_2d.projectInto(tmp, .{2.0, 3.0});
//!
//! // Batch transform (m × k matrix)
//! var coeffs_mat = try pca_2d.transform(&points_2d);
//! defer coeffs_mat.deinit();
//! ```

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Image = @import("image.zig").Image;
const Matrix = @import("matrix.zig").Matrix;
const OpsBuilder = @import("matrix/OpsBuilder.zig").OpsBuilder;
const Rgb = @import("color.zig").Rgb;
const SMatrix = @import("matrix.zig").SMatrix;

/// Principal Component Analysis for arbitrary-dimensional vectors.
/// Uses SIMD-accelerated vector operations for optimal performance.
pub fn PrincipalComponentAnalysis(comptime T: type, comptime dim: usize) type {
    assert(@typeInfo(T) == .float);
    assert(dim >= 1);

    return struct {
        const Self = @This();
        const Vec = @Vector(dim, T);

        /// Mean vector for centering data
        mean: Vec,
        /// Principal components matrix (dim × num_components)
        components: Matrix(T),
        /// Eigenvalues in descending order
        eigenvalues: []T,
        /// Number of components retained
        num_components: usize,
        /// Memory allocator
        allocator: Allocator,

        /// Initialize an empty PCA instance
        pub fn init(allocator: Allocator) Self {
            return Self{
                .mean = @splat(0),
                .components = undefined,
                .eigenvalues = &[_]T{},
                .num_components = 0,
                .allocator = allocator,
            };
        }

        /// Free allocated memory
        pub fn deinit(self: *Self) void {
            if (self.eigenvalues.len > 0) {
                self.allocator.free(self.eigenvalues);
                self.eigenvalues = &[_]T{};
            }
            if (self.num_components > 0) {
                self.components.deinit();
                self.num_components = 0;
            }
        }

        /// Fit the PCA model on centered data derived from `vectors`.
        /// - vectors: training samples (length n), each `@Vector(dim, T)`
        /// - num_components: number of components to retain; when null keeps `min(n-1, dim)`
        ///
        /// Notes:
        /// - Uses covariance path when `n > dim`, Gram path otherwise.
        /// - Replaces previous `components`/`eigenvalues` if already fitted.
        /// - Returns `error.InsufficientData` for `n < 2` and `error.InvalidComponents` for `0`.
        pub fn fit(self: *Self, vectors: []const Vec, num_components: ?usize) !void {
            if (vectors.len == 0) return error.NoVectors;
            if (vectors.len == 1) return error.InsufficientData;

            const n_samples = vectors.len;
            const max_components = @min(n_samples - 1, dim);
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

            // Compute mean vector using SIMD operations
            self.mean = @splat(0);
            for (vectors) |vec| {
                self.mean += vec;
            }
            self.mean = self.mean / @as(Vec, @splat(@floatFromInt(n_samples)));

            // Create centered data matrix
            var data_matrix: Matrix(T) = try .init(self.allocator, n_samples, dim);
            defer data_matrix.deinit();

            for (vectors, 0..) |vec, i| {
                const centered = vec - self.mean;
                for (0..dim) |j| {
                    data_matrix.at(i, j).* = centered[j];
                }
            }

            // Choose computation path based on data dimensions
            if (n_samples <= dim) {
                // Few samples: use Gram matrix approach (n_samples × n_samples)
                try self.computeComponentsFromGram(&data_matrix, actual_components);
            } else {
                // Many samples: use covariance matrix approach (dim × dim)
                try self.computeComponentsFromCovariance(&data_matrix, actual_components);
            }
        }

        /// Project a single vector onto PCA space, returning a freshly allocated coefficient slice.
        /// - Input: `vector` of length `dim`
        /// - Output: `[]T` of length `num_components` (caller frees)
        /// - For hot paths, prefer `projectInto` to reuse a buffer.
        pub fn project(self: Self, vector: Vec) ![]T {
            if (self.num_components == 0) return error.NotFitted;

            // Center the vector
            const centered = vector - self.mean;

            // Project onto components
            var coefficients = try self.allocator.alloc(T, self.num_components);
            for (0..self.num_components) |i| {
                var sum: T = 0;
                for (0..dim) |j| {
                    sum += centered[j] * self.components.at(j, i).*;
                }
                coefficients[i] = sum;
            }

            return coefficients;
        }

        /// Project a single vector into a caller-provided buffer (avoids allocation).
        /// - `dst.len` must equal `num_components`.
        /// - Writes `components^T * (vector - mean)` into `dst`.
        pub fn projectInto(self: Self, dst: []T, vector: Vec) !void {
            if (self.num_components == 0) return error.NotFitted;
            if (dst.len != self.num_components) return error.InvalidCoefficients;

            const centered = vector - self.mean;
            for (0..self.num_components) |i| {
                var sum: T = 0;
                for (0..dim) |j| {
                    sum += centered[j] * self.components.at(j, i).*;
                }
                dst[i] = sum;
            }
        }

        /// Reconstruct a vector from PCA coefficients: `mean + components * coefficients`.
        /// - `coefficients.len` must equal `num_components`.
        pub fn reconstruct(self: Self, coefficients: []const T) !Vec {
            if (self.num_components == 0) return error.NotFitted;
            if (coefficients.len != self.num_components) return error.InvalidCoefficients;

            // Start with mean
            var result = self.mean;

            // Add weighted components
            for (0..self.num_components) |i| {
                const weight = coefficients[i];
                for (0..dim) |j| {
                    result[j] += weight * self.components.at(j, i).*;
                }
            }

            return result;
        }

        /// Batch-transform: project multiple vectors using a single GEMM.
        /// - Builds a centered matrix `Xc` (m × dim) and returns `Xc * components` (m × k).
        /// - Returns a `Matrix(T)` owned by the caller; free with `deinit()`.
        pub fn transform(self: Self, vectors: []const Vec) !Matrix(T) {
            if (self.num_components == 0) return error.NotFitted;
            if (vectors.len == 0) return error.NoVectors;

            // Build centered data matrix (m × dim)
            const m = vectors.len;
            var data_matrix: Matrix(T) = try Matrix(T).init(self.allocator, m, dim);
            errdefer data_matrix.deinit();
            defer data_matrix.deinit();
            for (vectors, 0..) |vec, i| {
                const centered = vec - self.mean;
                for (0..dim) |j| {
                    data_matrix.at(i, j).* = centered[j];
                }
            }

            // Compute Xc * components -> (m × k)
            var ops = try OpsBuilder(T).init(self.allocator, data_matrix);
            defer ops.deinit();
            try ops.gemm(false, self.components, false, 1.0, 0.0, null);
            return ops.toOwned();
        }

        /// Get the mean vector
        pub fn getMean(self: Self) Vec {
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
            self.components = try Matrix(T).init(self.allocator, dim, num_components);

            if (n <= 64) {
                // Static SVD fast path
                var cov_static: SMatrix(T, 64, 64) = .initAll(0);
                for (0..n) |i| {
                    for (0..n) |j| {
                        cov_static.items[i][j] = cov_matrix.at(i, j).*;
                    }
                }
                const result = cov_static.svd(.{
                    .with_u = true,
                    .with_v = false,
                    .mode = .skinny_u,
                });
                if (result.converged != 0) return error.SvdFailed;

                for (0..num_components) |i| {
                    if (i < n) {
                        self.eigenvalues[i] = result.s.at(i, 0).*;
                        for (0..dim) |j| {
                            self.components.at(j, i).* = if (j < n) result.u.at(j, i).* else 0;
                        }
                    } else {
                        self.eigenvalues[i] = 0;
                        for (0..dim) |j| self.components.at(j, i).* = 0;
                    }
                }
            } else {
                // Dynamic SVD fallback for large dimensions
                var result = try cov_matrix.svd(self.allocator, .{
                    .with_u = true,
                    .with_v = false,
                    .mode = .skinny_u,
                });
                defer result.deinit();
                if (result.converged != 0) return error.SvdFailed;

                for (0..num_components) |i| {
                    if (i < n) {
                        self.eigenvalues[i] = result.s.at(i, 0).*;
                        for (0..dim) |j| {
                            self.components.at(j, i).* = result.u.at(j, i).*;
                        }
                    } else {
                        self.eigenvalues[i] = 0;
                        for (0..dim) |j| self.components.at(j, i).* = 0;
                    }
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
            self.components = try Matrix(T).init(self.allocator, dim, num_components);

            if (n <= 64) {
                var gram_static: SMatrix(T, 64, 64) = .initAll(0);
                for (0..n) |i| {
                    for (0..n) |j| {
                        gram_static.items[i][j] = gram_matrix.at(i, j).*;
                    }
                }

                const result = gram_static.svd(.{
                    .with_u = true,
                    .with_v = false,
                    .mode = .skinny_u,
                });
                if (result.converged != 0) return error.SvdFailed;

                const actual_components = @min(num_components, n);
                for (0..actual_components) |i| {
                    const eigenval = result.s.at(i, 0).*;
                    self.eigenvalues[i] = eigenval;

                    if (eigenval > 1e-10) {
                        // Principal component: X^T u_i / sqrt((n-1) * eigenval)
                        for (0..dim) |j| {
                            var sum: T = 0;
                            for (0..n) |k| {
                                sum += data_matrix.at(k, j).* * result.u.at(k, i).*;
                            }
                            self.components.at(j, i).* = sum / @sqrt(eigenval * @as(T, @floatFromInt(n_samples - 1)));
                        }
                    } else {
                        for (0..dim) |j| self.components.at(j, i).* = 0;
                    }
                }
                for (actual_components..num_components) |i| {
                    self.eigenvalues[i] = 0;
                    for (0..dim) |j| self.components.at(j, i).* = 0;
                }
            } else {
                var result = try gram_matrix.svd(self.allocator, .{
                    .with_u = true,
                    .with_v = false,
                    .mode = .skinny_u,
                });
                defer result.deinit();
                if (result.converged != 0) return error.SvdFailed;

                const actual_components = @min(num_components, n);
                for (0..actual_components) |i| {
                    const eigenval = result.s.at(i, 0).*;
                    self.eigenvalues[i] = eigenval;

                    if (eigenval > 1e-10) {
                        for (0..dim) |j| {
                            var sum: T = 0;
                            for (0..n) |k| {
                                sum += data_matrix.at(k, j).* * result.u.at(k, i).*;
                            }
                            self.components.at(j, i).* = sum / @sqrt(eigenval * @as(T, @floatFromInt(n_samples - 1)));
                        }
                    } else {
                        for (0..dim) |j| self.components.at(j, i).* = 0;
                    }
                }
                for (actual_components..num_components) |i| {
                    self.eigenvalues[i] = 0;
                    for (0..dim) |j| self.components.at(j, i).* = 0;
                }
            }
        }
    };
}

// Tests

test "PCA initialization and cleanup" {
    const allocator = std.testing.allocator;

    var pca = PrincipalComponentAnalysis(f64, 2).init(allocator);
    defer pca.deinit();

    try std.testing.expectEqual(@as(usize, 0), pca.num_components);
}

test "PCA on 2D vectors" {
    const allocator = std.testing.allocator;

    // Create simple test vectors
    const vectors = [_]@Vector(2, f64){
        .{ 1.0, 2.0 },
        .{ 3.0, 4.0 },
        .{ 5.0, 6.0 },
        .{ 7.0, 8.0 },
    };

    var pca = PrincipalComponentAnalysis(f64, 2).init(allocator);
    defer pca.deinit();

    try pca.fit(&vectors, null);

    // Should have fitted successfully
    try std.testing.expect(pca.num_components > 0);

    // Test projection and reconstruction
    const coeffs = try pca.project(.{ 4.0, 5.0 });
    defer allocator.free(coeffs);

    const reconstructed = try pca.reconstruct(coeffs);

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

    // Convert to color points using Point's fromColor method
    var color_points = try allocator.alloc(@Vector(3, f64), image.data.len);
    defer allocator.free(color_points);

    for (image.data, 0..) |pixel, i| {
        const point = Point3.fromColor(pixel);
        color_points[i] = point.asVector();
    }

    // Apply PCA to color data
    var pca = PrincipalComponentAnalysis(f64, 3).init(allocator);
    defer pca.deinit();

    try pca.fit(color_points, 1); // Keep only 1 component

    // Test basic functionality
    try std.testing.expect(pca.num_components == 1);

    // Project and reconstruct a point
    const coeffs = try pca.project(color_points[0]);
    defer allocator.free(coeffs);

    const reconstructed = try pca.reconstruct(coeffs);
    _ = reconstructed; // Just verify it works
}

test "PCA Gram path normalization and direction" {
    const allocator = std.testing.allocator;

    // Two 3D samples along x-axis -> triggers Gram path (n_samples <= dim)
    const vectors = [_]@Vector(3, f64){ .{ 1.0, 0.0, 0.0 }, .{ 3.0, 0.0, 0.0 } };

    var pca = PrincipalComponentAnalysis(f64, 3).init(allocator);
    defer pca.deinit();
    try pca.fit(&vectors, 1);

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
    var coeffs_matrix = try pca.transform(&vectors);
    defer coeffs_matrix.deinit();

    const coeffs0 = try allocator.alloc(f64, pca.num_components);
    defer allocator.free(coeffs0);
    try pca.projectInto(coeffs0, vectors[0]);

    try std.testing.expect(@abs(coeffs0[0] - coeffs_matrix.at(0, 0).*) < 1e-12);
}
