//! Statistics module for computing various statistical measures
//!
//! This module provides RunningStats for streaming/online statistics computation
//! using Welford's algorithm for numerical stability.
//!
//! Inspired by dlib's running_stats implementation.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const Matrix = @import("matrix.zig").Matrix;

/// Selects which quantities `RunningStats` tracks. Opt out of moments/extrema you don't need to
/// skip the corresponding per-sample work; mean/variance/stdDev are always available.
pub const RunningStatsConfig = struct {
    /// Track 3rd/4th central moments (required for `skewness`, `exKurtosis`, `combine`).
    higher_moments: bool,
    /// Track running min/max (required for `min`, `max`, `combine`).
    extrema: bool,

    /// Track everything: mean, variance, skewness, kurtosis, and extrema.
    pub const all: RunningStatsConfig = .{ .higher_moments = true, .extrema = true };
    /// Track only what mean/variance/stdDev need — the cheapest per-sample update.
    /// Usage: `RunningStats(f64, .variance)`.
    pub const variance: RunningStatsConfig = .{ .higher_moments = false, .extrema = false };
    /// Track mean/variance/stdDev plus running min/max, but not the higher moments.
    pub const summary: RunningStatsConfig = .{ .higher_moments = false, .extrema = true };
};

/// Running statistics for streaming data using Welford's algorithm for numerical stability.
/// `config` selects which quantities are tracked — pass a preset such as `.all` or `.variance`
/// (see `RunningStatsConfig`). mean/variance/stdDev are always available. Inspired by dlib's
/// running_stats.
pub fn RunningStats(comptime T: type, comptime config: RunningStatsConfig) type {
    comptime assert(@typeInfo(T) == .float);

    return struct {
        const Self = @This();

        /// Number of samples
        n: usize,
        /// Sum of values
        sum: T,

        // Running mean for Welford's algorithm
        /// Mean
        m1: T,
        /// Second moment
        m2: T,
        /// Third moment (only updated when `config.higher_moments`)
        m3: T,
        /// Fourth moment (only updated when `config.higher_moments`)
        m4: T,

        // Extrema (only updated when `config.extrema`)
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
            self.* = .init();
        }

        /// Add a new value to the running statistics
        pub fn add(self: *Self, val: T) void {
            const n: T = @floatFromInt(self.n);
            const n1 = n + 1;
            const delta = val - self.m1;
            const delta_n = delta / n1;
            const term1 = delta * delta_n * n;

            // Higher moments use the pre-update m2/m3, so update them first when tracked.
            if (config.higher_moments) {
                const delta_n2 = delta_n * delta_n;
                self.m4 += term1 * delta_n2 * (n1 * n1 - 3 * n1 + 3) +
                    6 * delta_n2 * self.m2 - 4 * delta_n * self.m3;
                self.m3 += term1 * delta_n * (n1 - 2) - 3 * delta_n * self.m2;
            }
            self.m1 += delta_n;
            self.m2 += term1;

            // Update simple sums
            self.sum += val;
            self.n += 1;

            if (config.extrema) {
                self.min_val = @min(self.min_val, val);
                self.max_val = @max(self.max_val, val);
            }
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
            if (!config.higher_moments) @compileError("skewness requires RunningStatsConfig.higher_moments = true");
            if (self.n <= 2) return 0;

            const variance_val = self.variance();
            if (variance_val == 0) return 0;

            // G1 = n / ((n-1)(n-2)) · Σ(x-μ)³ / s³ with s² the sample variance.
            const n = @as(T, @floatFromInt(self.n));
            return (n / ((n - 1) * (n - 2))) * self.m3 / std.math.pow(T, variance_val, 1.5);
        }

        /// Compute the excess kurtosis (requires n > 3)
        pub fn exKurtosis(self: Self) T {
            if (!config.higher_moments) @compileError("exKurtosis requires RunningStatsConfig.higher_moments = true");
            if (self.n <= 3) return 0;

            const variance_val = self.variance();
            if (variance_val == 0) return 0;

            // G2 = n(n+1) / ((n-1)(n-2)(n-3)) · Σ(x-μ)⁴ / s⁴ − 3(n-1)² / ((n-2)(n-3)).
            const n: T = @floatFromInt(self.n);
            const n1 = n - 1;
            return ((n * (n + 1)) / (n1 * (n - 2) * (n - 3))) * (self.m4 / (variance_val * variance_val)) -
                (3 * n1 * n1) / ((n - 2) * (n - 3));
        }

        /// Get the minimum value seen so far
        pub fn min(self: Self) T {
            if (!config.extrema) @compileError("min requires RunningStatsConfig.extrema = true");
            if (self.n == 0) return 0;
            return self.min_val;
        }

        /// Get the maximum value seen so far
        pub fn max(self: Self) T {
            if (!config.extrema) @compileError("max requires RunningStatsConfig.extrema = true");
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
            if (!config.higher_moments or !config.extrema)
                @compileError("combine requires RunningStatsConfig.higher_moments and .extrema = true");
            if (self.n == 0) return other;
            if (other.n == 0) return self;

            var result = Self.init();
            result.n = self.n + other.n;
            result.sum = self.sum + other.sum;

            const n1: T = @floatFromInt(self.n);
            const n2: T = @floatFromInt(other.n);
            const n_total: T = @floatFromInt(result.n);

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
            const n: T = @floatFromInt(self.count);

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
            const n_1: T = @floatFromInt(self.count - 1);
            var res: [dim]T = undefined;

            inline for (0..dim) |i| {
                res[i] = self.m2[i][i] / n_1;
            }
            return res;
        }

        /// Returns full covariance matrix allocated with allocator
        pub fn covarianceMatrix(self: Self, allocator: std.mem.Allocator) !Matrix(T) {
            var mat: Matrix(T) = try .init(allocator, dim, dim);
            if (self.count <= 1) {
                @memset(mat.items, 0);
                return mat;
            }

            const n_1: T = @floatFromInt(self.count - 1);

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
    var stats: RunningStats(f64, .all) = .init();

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
    var stats: RunningStats(f64, .all) = .init();

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

test "RunningStats: skewness and kurtosis exact values, scale invariant" {
    // {0,0,0,1}: G1 = 2, G2 = 4 (scipy.stats.skew/kurtosis with bias=False).
    for ([_]f64{ 1, 10, 1e-3 }) |scale| {
        var stats: RunningStats(f64, .all) = .init();
        for ([_]f64{ 0, 0, 0, scale }) |v| stats.add(v);
        try testing.expectApproxEqAbs(2.0, stats.skewness(), 1e-12);
        try testing.expectApproxEqAbs(4.0, stats.exKurtosis(), 1e-12);
    }
}

test "RunningStats: combine" {
    var stats1: RunningStats(f64, .all) = .init();
    var stats2: RunningStats(f64, .all) = .init();
    var combined_direct: RunningStats(f64, .all) = .init();

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
    var stats: RunningStats(f64, .all) = .init();

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

/// Two-pass sample skewness and excess kurtosis (G1, G2) of `values`, as a reference.
fn referenceMoments(values: []const f64) struct { skew: f64, kurt: f64 } {
    const n: f64 = @floatFromInt(values.len);
    var mean_val: f64 = 0;
    for (values) |v| mean_val += v;
    mean_val /= n;
    var m2: f64 = 0;
    var m3: f64 = 0;
    var m4: f64 = 0;
    for (values) |v| {
        const d = v - mean_val;
        m2 += d * d;
        m3 += d * d * d;
        m4 += d * d * d * d;
    }
    const s2 = m2 / (n - 1);
    return .{
        .skew = n / ((n - 1) * (n - 2)) * m3 / std.math.pow(f64, s2, 1.5),
        .kurt = n * (n + 1) / ((n - 1) * (n - 2) * (n - 3)) * m4 / (s2 * s2) - 3 * (n - 1) * (n - 1) / ((n - 2) * (n - 3)),
    };
}

test "RunningStats: normal distribution approximation" {
    var stats: RunningStats(f64, .all) = .init();
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    var values: [100]f64 = undefined;
    for (&values) |*v| {
        v.* = rand.floatNorm(f64);
        stats.add(v.*);
    }

    try testing.expectEqual(100, stats.currentN());
    try testing.expectApproxEqAbs(0, @abs(stats.mean()), 0.1);
    try testing.expectApproxEqAbs(1.0, stats.variance(), 0.04);
    try testing.expectApproxEqAbs(1.0, stats.stdDev(), 0.04);
    // The running estimate must match the two-pass reference; the sample itself is only
    // loosely normal (standard errors at n=100: skew ≈ 0.24, kurtosis ≈ 0.49).
    const ref = referenceMoments(&values);
    try testing.expectApproxEqAbs(ref.skew, stats.skewness(), 1e-10);
    try testing.expectApproxEqAbs(ref.kurt, stats.exKurtosis(), 1e-10);
    try testing.expect(@abs(stats.skewness()) < 0.5);
    try testing.expect(@abs(stats.exKurtosis()) < 1.0);
}

test "RunningStats: skewed distribution" {
    var stats: RunningStats(f64, .all) = .init();
    var prng = std.Random.DefaultPrng.init(123);
    const rand = prng.random();
    var values: [100]f64 = undefined;
    for (&values) |*v| {
        v.* = rand.floatExp(f64); // mean 1, skew 2, excess kurtosis 6
        stats.add(v.*);
    }

    try testing.expectEqual(@as(usize, 100), stats.currentN());
    try testing.expectApproxEqAbs(@as(f64, 1.0), stats.mean(), 0.05);
    try testing.expectApproxEqAbs(@as(f64, 1.0), stats.variance(), 0.12);
    const ref = referenceMoments(&values);
    try testing.expectApproxEqAbs(ref.skew, stats.skewness(), 1e-10);
    try testing.expectApproxEqAbs(ref.kurt, stats.exKurtosis(), 1e-10);
    try testing.expect(stats.skewness() > 1.0);
    try testing.expect(stats.exKurtosis() > 1.5);
}

test "RunningStats: scaling/z-score" {
    var stats: RunningStats(f64, .all) = .init();

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
    var stats: RunningStats(f64, .all) = .init();

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
