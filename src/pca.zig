//! Principal Component Analysis (PCA) for dimensionality reduction and feature extraction.
//!
//! This implementation works with arbitrary-dimensional vectors and points,
//! providing a unified interface for PCA on geometric data, color spaces, and more.
//!
//! ## Example
//! ```zig
//! // 2D geometric points
//! const points_2d = [_]@Vector(2, f64){ .{1.0, 2.0}, .{3.0, 4.0}, .{5.0, 6.0} };
//! var pca_2d = PrincipalComponentAnalysis(f64, 2).init(allocator);
//! try pca_2d.fit(&points_2d, null);
//!
//! // Project and reconstruct
//! const coeffs = try pca_2d.project(.{2.0, 3.0});
//! const reconstructed = try pca_2d.reconstruct(coeffs);
//!
//! // Convert Points to vectors if needed
//! const point = Point2d(f64).init2d(1.0, 2.0);
//! const coeffs = try pca_2d.project(point.asVector());
//! ```

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Image = @import("image.zig").Image;
const Matrix = @import("matrix.zig").Matrix;
const Rgb = @import("color.zig").Rgb;
const Rgba = @import("color.zig").Rgba;
const SMatrix = @import("matrix.zig").SMatrix;
const svd = @import("svd.zig").svd;
const OpsBuilder = @import("matrix/OpsBuilder.zig").OpsBuilder;

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

        /// Fit PCA model to a set of vectors.
        /// - vectors: Training data as vectors
        /// - num_components: Number of components to retain (null = keep all possible)
        pub fn fit(self: *Self, vectors: []const Vec, num_components: ?usize) !void {
            if (vectors.len == 0) return error.NoVectors;
            if (vectors.len == 1) return error.InsufficientData;

            const n_samples = vectors.len;
            const max_components = @min(n_samples - 1, dim);
            const requested_components = num_components orelse max_components;
            const actual_components = @min(requested_components, max_components);

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

        /// Project a vector onto the principal components.
        /// Returns the coefficients in PCA space.
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

        /// Reconstruct a vector from PCA coefficients.
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
            // Compute covariance matrix (X^T * X) / (n-1)
            const n_samples = data_matrix.rows;
            const scale = 1.0 / @as(T, @floatFromInt(n_samples - 1));
            
            var ops = try OpsBuilder(T).init(self.allocator, data_matrix.*);
            defer ops.deinit();
            try ops.covariance();
            try ops.scale(scale);
            var cov_matrix = ops.toOwned();
            defer cov_matrix.deinit();

            const n = cov_matrix.rows;

            // Convert to static matrix for SVD - keep size reasonable
            if (n > 64) return error.DimensionTooLarge;

            var cov_static: SMatrix(T, 64, 64) = .initAll(0);
            for (0..n) |i| {
                for (0..n) |j| {
                    cov_static.items[i][j] = cov_matrix.at(i, j).*;
                }
            }

            // Perform SVD
            const result = svd(T, 64, 64, cov_static, .{
                .with_u = true,
                .with_v = false,
                .mode = .skinny_u,
            });

            if (result.converged != 0) return error.SvdFailed;

            // Extract components and eigenvalues
            self.num_components = num_components;
            self.eigenvalues = try self.allocator.alloc(T, num_components);
            self.components = try Matrix(T).init(self.allocator, dim, num_components);

            for (0..num_components) |i| {
                if (i < n) {
                    self.eigenvalues[i] = result.s.items[i][0];
                    for (0..dim) |j| {
                        if (j < n) {
                            self.components.at(j, i).* = result.u.items[j][i];
                        } else {
                            self.components.at(j, i).* = 0;
                        }
                    }
                } else {
                    self.eigenvalues[i] = 0;
                    for (0..dim) |j| {
                        self.components.at(j, i).* = 0;
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
            // Compute Gram matrix (X * X^T) / (n-1)
            const n_samples = data_matrix.rows;
            const scale = 1.0 / @as(T, @floatFromInt(n_samples - 1));
            
            var ops = try OpsBuilder(T).init(self.allocator, data_matrix.*);
            defer ops.deinit();
            try ops.gram();
            try ops.scale(scale);
            var gram_matrix = ops.toOwned();
            defer gram_matrix.deinit();

            const n = gram_matrix.rows;

            // Convert to static matrix for SVD - keep size reasonable
            if (n > 64) return error.DimensionTooLarge;

            var gram_static: SMatrix(T, 64, 64) = .{};
            for (0..n) |i| {
                for (0..n) |j| {
                    gram_static.items[i][j] = gram_matrix.at(i, j).*;
                }
            }

            // Perform SVD on Gram matrix
            const result = svd(T, 64, 64, gram_static, .{
                .with_u = true,
                .with_v = false,
                .mode = .skinny_u,
            });

            if (result.converged != 0) return error.SvdFailed;

            // Extract components by projecting data onto eigenvectors
            self.num_components = num_components;
            self.eigenvalues = try self.allocator.alloc(T, num_components);
            self.components = try Matrix(T).init(self.allocator, dim, num_components);

            // Ensure we don't exceed the actual number of eigenvalues/eigenvectors computed
            const actual_components = @min(num_components, n);
            for (0..actual_components) |i| {
                const eigenval = result.s.items[i][0];
                self.eigenvalues[i] = eigenval;

                if (eigenval > 1e-10) {
                    // Compute component as X^T * u_i / sqrt(eigenval)
                    for (0..dim) |j| {
                        var sum: T = 0;
                        for (0..n) |k| {
                            sum += data_matrix.at(k, j).* * result.u.items[k][i];
                        }
                        self.components.at(j, i).* = sum / @sqrt(eigenval * @as(T, @floatFromInt(n)));
                    }
                } else {
                    // Zero eigenvalue, set component to zero
                    for (0..dim) |j| {
                        self.components.at(j, i).* = 0;
                    }
                }
            }

            // Fill remaining components with zeros if num_components > actual_components
            for (actual_components..num_components) |i| {
                self.eigenvalues[i] = 0;
                for (0..dim) |j| {
                    self.components.at(j, i).* = 0;
                }
            }
        }
    };
}

// Image-to-Points Conversion Utilities

/// Generic function to convert any color type to a point using reflection.
/// Works with any struct with numeric fields (u8, f32, etc.).
pub fn colorToPoint(comptime ColorType: type, color: ColorType) @Vector(std.meta.fields(ColorType).len, f64) {
    const fields = std.meta.fields(ColorType);
    var point: @Vector(fields.len, f64) = undefined;

    inline for (fields, 0..) |field, i| {
        const value = @field(color, field.name);
        const field_type = @TypeOf(value);

        // Convert to normalized f64 based on field type
        point[i] = switch (@typeInfo(field_type)) {
            .int => @as(f64, @floatFromInt(value)) / 255.0, // Assume u8 values are 0-255
            .float => @as(f64, @floatCast(value)), // Assume float values are already normalized
            else => @compileError("Unsupported color field type: " ++ @typeName(field_type)),
        };
    }

    return point;
}

/// Generic function to convert a point back to any color type using reflection.
/// Works with any struct with numeric fields (u8, f32, etc.).
pub fn pointToColor(comptime ColorType: type, point: @Vector(std.meta.fields(ColorType).len, f64)) ColorType {
    const fields = std.meta.fields(ColorType);
    var color: ColorType = undefined;

    inline for (fields, 0..) |field, i| {
        const field_type = field.type;
        const value = point[i];

        // Convert from normalized f64 based on field type
        @field(color, field.name) = switch (@typeInfo(field_type)) {
            .int => @intFromFloat(@round(std.math.clamp(value * 255.0, 0, 255))),
            .float => @floatCast(value),
            else => @compileError("Unsupported color field type: " ++ @typeName(field_type)),
        };
    }

    return color;
}

/// Generic function to convert any image to color points using reflection.
/// Works with any color type - RGB, RGBA, HSL, Lab, etc.
pub fn imageToColorPoints(comptime ColorType: type, allocator: Allocator, image: Image(ColorType)) ![]@Vector(std.meta.fields(ColorType).len, f64) {
    const num_channels = std.meta.fields(ColorType).len;
    var points = try allocator.alloc(@Vector(num_channels, f64), image.data.len);

    for (image.data, 0..) |pixel, i| {
        points[i] = colorToPoint(ColorType, pixel);
    }

    return points;
}

/// Generic function to convert color points back to an image using reflection.
/// Works with any color type - RGB, RGBA, HSL, Lab, etc.
pub fn colorPointsToImage(comptime ColorType: type, allocator: Allocator, points: []const @Vector(std.meta.fields(ColorType).len, f64), rows: usize, cols: usize) !Image(ColorType) {
    assert(points.len == rows * cols);

    var image = try Image(ColorType).initAlloc(allocator, rows, cols);

    for (points, 0..) |point, i| {
        image.data[i] = pointToColor(ColorType, point);
    }

    return image;
}

/// Convert a grayscale image to 1D intensity points.
/// Special case for u8 images (single intensity value).
pub fn imageToIntensityPoints(allocator: Allocator, image: Image(u8)) ![]@Vector(1, f64) {
    var points = try allocator.alloc(@Vector(1, f64), image.data.len);

    for (image.data, 0..) |pixel, i| {
        points[i] = .{@as(f64, @floatFromInt(pixel)) / 255.0};
    }

    return points;
}

/// Convert intensity points back to a grayscale image.
/// Reconstructs an image from 1D intensity points.
pub fn intensityPointsToImage(allocator: Allocator, points: []const @Vector(1, f64), rows: usize, cols: usize) !Image(u8) {
    assert(points.len == rows * cols);

    var image = try Image(u8).initAlloc(allocator, rows, cols);

    for (points, 0..) |point, i| {
        const intensity = std.math.clamp(point[0] * 255.0, 0, 255);
        image.data[i] = @intFromFloat(@round(intensity));
    }

    return image;
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

test "Generic color to point conversion" {
    _ = std.testing.allocator;

    // Test with RGB color
    const rgb_color = Rgb{ .r = 255, .g = 128, .b = 0 };
    const rgb_point = colorToPoint(Rgb, rgb_color);

    try std.testing.expectEqual(@as(f64, 1.0), rgb_point[0]); // R
    try std.testing.expectEqual(@as(f64, 128.0 / 255.0), rgb_point[1]); // G
    try std.testing.expectEqual(@as(f64, 0.0), rgb_point[2]); // B

    // Convert back
    const recovered_rgb = pointToColor(Rgb, rgb_point);
    try std.testing.expectEqual(rgb_color.r, recovered_rgb.r);
    try std.testing.expectEqual(rgb_color.g, recovered_rgb.g);
    try std.testing.expectEqual(rgb_color.b, recovered_rgb.b);

    // Test with RGBA color
    const rgba_color = Rgba{ .r = 255, .g = 0, .b = 0, .a = 128 };
    const rgba_point = colorToPoint(Rgba, rgba_color);

    try std.testing.expectEqual(@as(f64, 1.0), rgba_point[0]); // R
    try std.testing.expectEqual(@as(f64, 0.0), rgba_point[1]); // G
    try std.testing.expectEqual(@as(f64, 0.0), rgba_point[2]); // B
    try std.testing.expectEqual(@as(f64, 128.0 / 255.0), rgba_point[3]); // A

    const recovered_rgba = pointToColor(Rgba, rgba_point);
    try std.testing.expectEqual(rgba_color.r, recovered_rgba.r);
    try std.testing.expectEqual(rgba_color.g, recovered_rgba.g);
    try std.testing.expectEqual(rgba_color.b, recovered_rgba.b);
    try std.testing.expectEqual(rgba_color.a, recovered_rgba.a);
}

test "Generic image to color points conversion" {
    const allocator = std.testing.allocator;

    // Create a simple 2x2 RGB image
    var image = try Image(Rgb).initAlloc(allocator, 2, 2);
    defer image.deinit(allocator);

    image.data[0] = Rgb{ .r = 255, .g = 0, .b = 0 }; // Red
    image.data[1] = Rgb{ .r = 0, .g = 255, .b = 0 }; // Green
    image.data[2] = Rgb{ .r = 0, .g = 0, .b = 255 }; // Blue
    image.data[3] = Rgb{ .r = 255, .g = 255, .b = 255 }; // White

    // Convert to color points using generic function
    const color_points = try imageToColorPoints(Rgb, allocator, image);
    defer allocator.free(color_points);

    // Check conversions
    try std.testing.expectEqual(@as(usize, 4), color_points.len);
    try std.testing.expectEqual(@as(f64, 1.0), color_points[0][0]); // Red pixel
    try std.testing.expectEqual(@as(f64, 0.0), color_points[0][1]);
    try std.testing.expectEqual(@as(f64, 0.0), color_points[0][2]);

    try std.testing.expectEqual(@as(f64, 0.0), color_points[1][0]); // Green pixel
    try std.testing.expectEqual(@as(f64, 1.0), color_points[1][1]);
    try std.testing.expectEqual(@as(f64, 0.0), color_points[1][2]);

    // Convert back to image using generic function
    var reconstructed = try colorPointsToImage(Rgb, allocator, color_points, 2, 2);
    defer reconstructed.deinit(allocator);

    // Check that reconstruction matches original
    try std.testing.expectEqual(image.data[0].r, reconstructed.data[0].r);
    try std.testing.expectEqual(image.data[0].g, reconstructed.data[0].g);
    try std.testing.expectEqual(image.data[0].b, reconstructed.data[0].b);
}

test "PCA on image color data" {
    const allocator = std.testing.allocator;

    // Create a simple gradient image
    var image = try Image(Rgb).initAlloc(allocator, 2, 2);
    defer image.deinit(allocator);

    image.data[0] = Rgb{ .r = 0, .g = 0, .b = 0 }; // Black
    image.data[1] = Rgb{ .r = 85, .g = 85, .b = 85 }; // Dark gray
    image.data[2] = Rgb{ .r = 170, .g = 170, .b = 170 }; // Light gray
    image.data[3] = Rgb{ .r = 255, .g = 255, .b = 255 }; // White

    // Convert to color points
    const color_points = try imageToColorPoints(Rgb, allocator, image);
    defer allocator.free(color_points);

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
