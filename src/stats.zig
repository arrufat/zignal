//! Statistics module for computing various statistical measures
//!
//! This module provides RunningStats for streaming/online statistics computation
//! using Welford's algorithm for numerical stability.
//!
//! Inspired by dlib's running_stats implementation.

const std = @import("std");
const testing = std.testing;
const Matrix = @import("matrix.zig").Matrix;

/// Running statistics for streaming data.
/// Computes mean, variance, skewness, and kurtosis in a single pass.
/// Uses Welford's algorithm for numerical stability.
/// Inspired by dlib's running_stats implementation.
pub fn RunningStats(comptime T: type) type {
    comptime {
        const info = @typeInfo(T);
        if (info != .float) {
            @compileError("RunningStats only supports floating-point types (f32, f64, f128)");
        }
    }

    return struct {
        const Self = @This();

        // Core statistics
        n: usize, // Number of samples
        sum: T, // Sum of values

        // Running mean for Welford's algorithm
        m1: T, // Mean
        m2: T, // Second moment
        m3: T, // Third moment
        m4: T, // Fourth moment

        // Extrema
        min_val: T,
        max_val: T,

        /// Initialize a new RunningStats instance with zero values
        pub fn init() Self {
            return .{
                .n = 0,
                .sum = 0,
                .m1 = 0,
                .m2 = 0,
                .m3 = 0,
                .m4 = 0,
                .min_val = std.math.inf(T),
                .max_val = -std.math.inf(T),
            };
        }

        /// Clear all statistics and reset to initial state
        pub fn clear(self: *Self) void {
            self.* = Self.init();
        }

        /// Add a new value to the running statistics
        pub fn add(self: *Self, val: T) void {
            const n1 = @as(T, @floatFromInt(self.n + 1));
            const delta = val - self.m1;
            const delta_n = delta / n1;
            const delta_n2 = delta_n * delta_n;
            const term1 = delta * delta_n * @as(T, @floatFromInt(self.n));

            // Update moments using Welford's algorithm
            self.m1 += delta_n;
            self.m4 += term1 * delta_n2 * (n1 * n1 - 3 * n1 + 3) +
                6 * delta_n2 * self.m2 - 4 * delta_n * self.m3;
            self.m3 += term1 * delta_n * (n1 - 2) - 3 * delta_n * self.m2;
            self.m2 += term1;

            // Update simple sums
            self.sum += val;
            self.n += 1;

            // Update extrema
            self.min_val = @min(self.min_val, val);
            self.max_val = @max(self.max_val, val);
        }

        /// Get the current number of samples
        pub fn currentN(self: Self) usize {
            return self.n;
        }

        /// Get the sum of all values
        pub fn getSum(self: Self) T {
            return self.sum;
        }

        /// Compute the mean
        pub fn mean(self: Self) T {
            if (self.n == 0) return 0;
            return self.m1;
        }

        /// Compute the unbiased sample variance (requires n > 1)
        pub fn variance(self: Self) T {
            if (self.n <= 1) return 0;
            return self.m2 / @as(T, @floatFromInt(self.n - 1));
        }

        /// Compute the standard deviation
        pub fn stdDev(self: Self) T {
            return @sqrt(self.variance());
        }

        /// Compute the unbiased sample skewness (requires n > 2)
        pub fn skewness(self: Self) T {
            if (self.n <= 2) return 0;

            const variance_val = self.variance();
            if (variance_val == 0) return 0;

            const n = @as(T, @floatFromInt(self.n));
            const skew = (n / ((n - 1) * (n - 2))) *
                (self.m3 / (self.m2 / n));
            return skew / std.math.pow(T, variance_val, 1.5);
        }

        /// Compute the excess kurtosis (requires n > 3)
        pub fn exKurtosis(self: Self) T {
            if (self.n <= 3) return 0;

            const variance_val = self.variance();
            if (variance_val == 0) return 0;

            const n = @as(T, @floatFromInt(self.n));
            const n1 = n - 1;

            const kurt = ((n * (n + 1)) / (n1 * (n - 2) * (n - 3))) *
                (self.m4 / (self.m2 * self.m2 / (n * n))) -
                (3 * n1 * n1) / ((n - 2) * (n - 3));

            return kurt;
        }

        /// Get the minimum value seen so far
        pub fn min(self: Self) T {
            if (self.n == 0) return 0;
            return self.min_val;
        }

        /// Get the maximum value seen so far
        pub fn max(self: Self) T {
            if (self.n == 0) return 0;
            return self.max_val;
        }

        /// Scale a value: (val - mean) / stdDev
        pub fn scale(self: Self, val: T) T {
            const std_dev = self.stdDev();
            if (std_dev == 0) return 0;
            return (val - self.mean()) / std_dev;
        }

        /// Combine two RunningStats objects
        pub fn combine(self: Self, other: Self) Self {
            if (self.n == 0) return other;
            if (other.n == 0) return self;

            var result = Self.init();
            result.n = self.n + other.n;
            result.sum = self.sum + other.sum;

            const n1 = @as(T, @floatFromInt(self.n));
            const n2 = @as(T, @floatFromInt(other.n));
            const n_total = @as(T, @floatFromInt(result.n));

            const delta = other.m1 - self.m1;
            const delta2 = delta * delta;
            const delta3 = delta2 * delta;
            const delta4 = delta2 * delta2;

            result.m1 = (n1 * self.m1 + n2 * other.m1) / n_total;

            result.m2 = self.m2 + other.m2 +
                delta2 * n1 * n2 / n_total;

            result.m3 = self.m3 + other.m3 +
                delta3 * n1 * n2 * (n1 - n2) / (n_total * n_total) +
                3 * delta * (n1 * other.m2 - n2 * self.m2) / n_total;

            result.m4 = self.m4 + other.m4 +
                delta4 * n1 * n2 * (n1 * n1 - n1 * n2 + n2 * n2) /
                    (n_total * n_total * n_total) +
                6 * delta2 * (n1 * n1 * other.m2 + n2 * n2 * self.m2) /
                    (n_total * n_total) +
                4 * delta * (n1 * other.m3 - n2 * self.m3) / n_total;

            result.min_val = @min(self.min_val, other.min_val);
            result.max_val = @max(self.max_val, other.max_val);

            return result;
        }
    };
}

/// Multivariate running statistics for streaming data.
/// Computes mean vector and full covariance matrix in a single pass.
/// Supports generic dimensionality `dim`.
pub fn CovarianceStats(comptime dim: usize, comptime T: type) type {
    comptime {
        const info = @typeInfo(T);
        if (info != .float) {
            @compileError("CovarianceStats only supports floating-point types (f32, f64, f128)");
        }
    }

    return struct {
        const Self = @This();

        count: usize,
        mean_vec: [dim]T,
        // Upper triangular covariance sums are sufficient, but storing full matrix
        // simplifies indexing and is clearer. Stores sum(x_i * x_j).
        m2: [dim][dim]T,

        /// Initialize empty statistics
        pub fn init() Self {
            return .{
                .count = 0,
                .mean_vec = @splat(0),
                .m2 = @splat(@splat(0)),
            };
        }

        /// Add a sample vector
        pub fn add(self: *Self, sample: [dim]T) void {
            self.count += 1;
            const n = @as(T, @floatFromInt(self.count));

            var delta: [dim]T = undefined;
            inline for (0..dim) |i| {
                delta[i] = sample[i] - self.mean_vec[i];
                self.mean_vec[i] += delta[i] / n;
            }

            inline for (0..dim) |i| {
                inline for (i..dim) |j| {
                    const term = delta[i] * (sample[j] - self.mean_vec[j]);
                    self.m2[i][j] += term;
                    if (i != j) {
                        self.m2[j][i] += term;
                    }
                }
            }
        }

        /// Compute the mean vector
        pub fn mean(self: Self) [dim]T {
            if (self.count == 0) return @splat(0);
            return self.mean_vec;
        }

        /// Returns simple variance vector (diagonal of covariance matrix)
        pub fn varianceVector(self: Self) [dim]T {
            if (self.count <= 1) return @splat(0);
            const n_1 = @as(T, @floatFromInt(self.count - 1));
            var res: [dim]T = undefined;

            inline for (0..dim) |i| {
                res[i] = self.m2[i][i] / n_1;
            }
            return res;
        }

        /// Returns full covariance matrix allocated with allocator
        pub fn covarianceMatrix(self: Self, allocator: std.mem.Allocator) !Matrix(T) {
            var mat = try Matrix(T).init(allocator, dim, dim);
            if (self.count <= 1) {
                @memset(mat.items, 0);
                return mat;
            }

            const n_1 = @as(T, @floatFromInt(self.count - 1));

            inline for (0..dim) |i| {
                inline for (i..dim) |j| {
                    const cov_val = self.m2[i][j] / n_1;
                    mat.at(i, j).* = cov_val;
                    if (i != j) {
                        mat.at(j, i).* = cov_val;
                    }
                }
            }
            return mat;
        }
    };
}

// ============================================================================
// TESTS
// ============================================================================

test "RunningStats: basic operations" {
    var stats: RunningStats(f64) = .init();

    // Test with known values
    stats.add(2.0);
    stats.add(4.0);
    stats.add(4.0);
    stats.add(4.0);
    stats.add(5.0);
    stats.add(5.0);
    stats.add(7.0);
    stats.add(9.0);

    try testing.expectEqual(@as(usize, 8), stats.currentN());
    try testing.expectApproxEqAbs(@as(f64, 40.0), stats.getSum(), 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 5.0), stats.mean(), 1e-10);
    // Variance: sum((x - mean)^2) / (n-1) = 32/7 ≈ 4.571
    try testing.expectApproxEqAbs(@as(f64, 4.571428571428571), stats.variance(), 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 2.13808993), stats.stdDev(), 1e-6);
    try testing.expectEqual(@as(f64, 2.0), stats.min());
    try testing.expectEqual(@as(f64, 9.0), stats.max());
}

test "RunningStats: skewness and kurtosis" {
    var stats: RunningStats(f64) = .init();

    // Normal-like distribution
    const values = [_]f64{ 1, 2, 2, 3, 3, 3, 4, 4, 5 };
    for (values) |v| {
        stats.add(v);
    }

    // For a symmetric distribution, skewness should be close to 0
    try testing.expect(@abs(stats.skewness()) < 0.5);

    // For a normal-like distribution, excess kurtosis should be close to 0
    try testing.expect(@abs(stats.exKurtosis()) < 1.0);
}

test "RunningStats: combine" {
    var stats1: RunningStats(f64) = .init();
    var stats2: RunningStats(f64) = .init();
    var combined_direct: RunningStats(f64) = .init();

    // Add to first stats
    stats1.add(1.0);
    stats1.add(2.0);
    stats1.add(3.0);

    // Add to second stats
    stats2.add(4.0);
    stats2.add(5.0);
    stats2.add(6.0);

    // Add all to combined_direct
    combined_direct.add(1.0);
    combined_direct.add(2.0);
    combined_direct.add(3.0);
    combined_direct.add(4.0);
    combined_direct.add(5.0);
    combined_direct.add(6.0);

    // Combine stats1 and stats2
    const combined = stats1.combine(stats2);

    // They should be equivalent
    try testing.expectEqual(combined_direct.currentN(), combined.currentN());
    try testing.expectApproxEqAbs(combined_direct.mean(), combined.mean(), 1e-10);
    try testing.expectApproxEqAbs(combined_direct.variance(), combined.variance(), 1e-10);
}

test "RunningStats: edge cases" {
    var stats: RunningStats(f64) = .init();

    // Empty stats
    try testing.expectEqual(@as(usize, 0), stats.currentN());
    try testing.expectEqual(@as(f64, 0), stats.mean());
    try testing.expectEqual(@as(f64, 0), stats.variance());
    try testing.expectEqual(@as(f64, 0), stats.stdDev());
    try testing.expectEqual(@as(f64, 0), stats.skewness());
    try testing.expectEqual(@as(f64, 0), stats.exKurtosis());
    try testing.expectEqual(@as(f64, 0), stats.min());
    try testing.expectEqual(@as(f64, 0), stats.max());
    try testing.expectEqual(@as(f64, 0), stats.scale(1.0));

    // Single value
    stats.add(5.0);
    try testing.expectEqual(@as(usize, 1), stats.currentN());
    try testing.expectApproxEqAbs(@as(f64, 5.0), stats.mean(), 1e-10);
    try testing.expectEqual(@as(f64, 0), stats.variance());
    try testing.expectEqual(@as(f64, 0), stats.stdDev());
    try testing.expectEqual(@as(f64, 0), stats.skewness());
    try testing.expectEqual(@as(f64, 0), stats.exKurtosis());
    try testing.expectApproxEqAbs(@as(f64, 5.0), stats.min(), 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 5.0), stats.max(), 1e-10);
    try testing.expectEqual(@as(f64, 0), stats.scale(5.0));

    // Constant values (zero variance)
    stats.clear();
    stats.add(2.0);
    stats.add(2.0);
    stats.add(2.0);
    try testing.expectEqual(@as(f64, 0), stats.variance());
    try testing.expectEqual(@as(f64, 0), stats.skewness());
    try testing.expectEqual(@as(f64, 0), stats.exKurtosis());
}

test "RunningStats: normal distribution approximation" {
    var stats: RunningStats(f64) = .init();

    // Generate standard normal data using Zig's built-in normal random generator
    var prng = std.Random.DefaultPrng.init(42); // Fixed seed for deterministic test
    const rand = prng.random();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const value = rand.floatNorm(f64);
        stats.add(value);
    }

    try testing.expectEqual(100, stats.currentN());
    try testing.expectApproxEqAbs(0, @abs(stats.mean()), 0.1); // Should be near 0
    try testing.expectApproxEqAbs(1.0, stats.variance(), 0.04); // Should be near 1
    try testing.expectApproxEqAbs(1.0, stats.stdDev(), 0.04); // Should be near 1
    try testing.expectApproxEqAbs(0, @abs(stats.skewness()), 0.25); // Should be near 0 for symmetric
    try testing.expectApproxEqAbs(0, @abs(stats.exKurtosis()), 0.15); // Should be near 0 for normal-like
}

test "RunningStats: skewed distribution" {
    var stats: RunningStats(f64) = .init();

    // Generate right-skewed data using Zig's exponential random generator
    var prng = std.Random.DefaultPrng.init(123); // Fixed seed for deterministic test
    const rand = prng.random();

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const value = rand.floatExp(f64); // Exponential distribution: mean 1, skewed right
        stats.add(value);
    }

    try testing.expectEqual(@as(usize, 100), stats.currentN());
    try testing.expectApproxEqAbs(@as(f64, 1.0), stats.mean(), 0.05); // Should be near 1
    try testing.expectApproxEqAbs(@as(f64, 1.0), stats.variance(), 0.12); // Should be near 1
    try testing.expect(stats.skewness() > 1.9); // Positive skewness expected for exponential
    try testing.expect(stats.exKurtosis() > 3.1); // High excess kurtosis for exponential
}

test "RunningStats: scaling/z-score" {
    var stats: RunningStats(f64) = .init();

    // Add values with known mean and std
    stats.add(10.0);
    stats.add(12.0);
    stats.add(14.0);
    stats.add(16.0);
    stats.add(18.0);

    try testing.expectApproxEqAbs(@as(f64, 14.0), stats.mean(), 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 10.0), stats.variance(), 1e-10); // Variance: sum of squared diffs / (n-1)
    try testing.expectApproxEqAbs(@as(f64, 3.162), stats.stdDev(), 0.001);

    // Test scaling
    try testing.expectApproxEqAbs(@as(f64, -1.265), stats.scale(10.0), 0.001); // (10-14)/3.162
    try testing.expectApproxEqAbs(@as(f64, 0.0), stats.scale(14.0), 0.001); // Mean
    try testing.expectApproxEqAbs(@as(f64, 1.265), stats.scale(18.0), 0.001); // (18-14)/3.162
}

test "RunningStats: large values for numerical stability" {
    var stats: RunningStats(f64) = .init();

    // Add large values to test numerical stability
    stats.add(1e10);
    stats.add(1e10 + 1.0);
    stats.add(1e10 + 2.0);

    try testing.expectApproxEqAbs(@as(f64, 1e10 + 1.0), stats.mean(), 1e-5);
    try testing.expectApproxEqAbs(@as(f64, 1.0), stats.variance(), 1e-4);
    try testing.expectApproxEqAbs(@as(f64, 1.0), stats.stdDev(), 1e-4);
}

test "CovarianceStats: basic" {
    var stats = CovarianceStats(2, f64).init();

    stats.add(.{ 1.0, 2.0 });
    stats.add(.{ 2.0, 4.0 });
    stats.add(.{ 3.0, 6.0 });

    const mean = stats.mean();
    try testing.expectApproxEqAbs(@as(f64, 2.0), mean[0], 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 4.0), mean[1], 1e-10);

    var cov = try stats.covarianceMatrix(testing.allocator);
    defer cov.deinit();

    // Cov(X,Y) using unbiased Welford: m2 / (n-1)
    // Variance is m2[i][i] / (n-1)
    // Covariance is m2[i][j] / (n-1)
    // Here n=3, n-1=2
    // m2 is sum of squared differences from mean.
    // X values: 1, 2, 3. Mean 2. Diffs: -1, 0, 1. SqDiffs: 1, 0, 1. SumSqDiffs: 2. Var = 2/2 = 1.
    // Y values: 2, 4, 6. Mean 4. Diffs: -2, 0, 2. SqDiffs: 4, 0, 4. SumSqDiffs: 8. Var = 8/2 = 4.
    // XY products of diffs: (-1)*(-2)=2, 0*0=0, 1*2=2. SumProdDiffs = 4. Cov = 4/2 = 2.

    try testing.expectApproxEqAbs(@as(f64, 1.0), cov.at(0, 0).*, 1e-5); // Var(X)
    try testing.expectApproxEqAbs(@as(f64, 2.0), cov.at(0, 1).*, 1e-5); // Cov(X,Y)
}
