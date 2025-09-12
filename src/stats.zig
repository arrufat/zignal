//! Statistics module for computing various statistical measures
//!
//! This module provides RunningStats for streaming/online statistics computation
//! using Welford's algorithm for numerical stability.
//!
//! Inspired by dlib's running_stats implementation.

const std = @import("std");
const testing = std.testing;

/// Running statistics for streaming data.
/// Computes mean, variance, skewness, and kurtosis in a single pass.
/// Uses Welford's algorithm for numerical stability.
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
        n: usize = 0, // Number of samples
        sum: T = 0, // Sum of values
        sum_sqr: T = 0, // Sum of squared deviations
        sum_cub: T = 0, // Sum of cubed deviations
        sum_four: T = 0, // Sum of fourth power deviations

        // Running mean for Welford's algorithm
        m1: T = 0, // Mean
        m2: T = 0, // Second moment
        m3: T = 0, // Third moment
        m4: T = 0, // Fourth moment

        // Extrema
        min_val: T = std.math.inf(T),
        max_val: T = -std.math.inf(T),

        /// Clear all statistics and reset to initial state
        pub fn clear(self: *Self) void {
            self.* = .{};
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

            var result = Self{};
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

// ============================================================================
// TESTS
// ============================================================================

test "RunningStats: basic operations" {
    var stats = RunningStats(f64){};

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
    var stats = RunningStats(f64){};

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
    var stats1 = RunningStats(f64){};
    var stats2 = RunningStats(f64){};
    var combined_direct = RunningStats(f64){};

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
