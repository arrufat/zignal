//! Optimal one-to-one feature matching using the Hungarian algorithm
//!
//! Unlike BruteForceMatcher which allows many-to-many matching,
//! OptimalMatcher guarantees each feature in the query set matches
//! to at most one feature in the train set, minimizing total cost.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Matrix = @import("../matrix.zig").Matrix;
const optimization = @import("../optimization.zig");
const BinaryDescriptor = @import("BinaryDescriptor.zig");

/// Maximum distance threshold for valid matches
max_distance: f32 = 100,

/// Whether to normalize distances to [0, 1] range
normalize_costs: bool = false,

/// Whether to use squared distances (emphasizes larger differences)
use_squared_distance: bool = false,

const OptimalMatcher = @This();

/// Match between two feature descriptors
pub const Match = struct {
    /// Index of the query descriptor
    query_idx: usize,

    /// Index of the train descriptor
    train_idx: usize,

    /// Distance between descriptors
    distance: f32,

    /// Compare matches by distance (for sorting)
    pub fn compareDistance(context: void, a: Match, b: Match) bool {
        _ = context;
        return a.distance < b.distance;
    }
};

/// Find optimal one-to-one matches using Hungarian algorithm
pub fn match(
    self: OptimalMatcher,
    query_descriptors: []const BinaryDescriptor,
    train_descriptors: []const BinaryDescriptor,
    allocator: Allocator,
) ![]Match {
    if (query_descriptors.len == 0 or train_descriptors.len == 0) {
        return try allocator.alloc(Match, 0);
    }

    // Build cost matrix
    var cost_matrix = try Matrix(f32).init(
        allocator,
        query_descriptors.len,
        train_descriptors.len,
    );
    defer cost_matrix.deinit();

    // Fill cost matrix with distances
    for (query_descriptors, 0..) |q_desc, i| {
        for (train_descriptors, 0..) |t_desc, j| {
            var dist = @as(f32, @floatFromInt(q_desc.hammingDistance(t_desc)));

            if (self.normalize_costs) {
                dist = dist / 256.0; // Max Hamming distance is 256
            }

            if (self.use_squared_distance) {
                dist = dist * dist;
            }

            cost_matrix.at(i, j).* = dist;
        }
    }

    // Solve assignment problem (minimize cost)
    var assignment = try optimization.solveAssignmentProblem(f32, allocator, cost_matrix, .min);
    defer assignment.deinit();

    // Convert assignments to Match structs, filtering by max_distance
    var matches: std.ArrayList(Match) = .{};
    defer matches.deinit(allocator);

    for (assignment.assignments, 0..) |maybe_train_idx, query_idx| {
        if (maybe_train_idx) |train_idx| {
            const dist = @as(f32, @floatFromInt(query_descriptors[query_idx].hammingDistance(train_descriptors[train_idx])));

            if (dist <= self.max_distance) {
                try matches.append(allocator, .{
                    .query_idx = query_idx,
                    .train_idx = train_idx,
                    .distance = dist,
                });
            }
        }
    }

    return try matches.toOwnedSlice(allocator);
}

/// Compute match statistics
pub fn computeStats(matches: []const Match) MatchStats {
    if (matches.len == 0) {
        return .{
            .total_matches = 0,
            .mean_distance = 0,
            .min_distance = 0,
            .max_distance = 0,
        };
    }

    var sum: f32 = 0;
    var min: f32 = std.math.floatMax(f32);
    var max: f32 = 0;

    for (matches) |m| {
        sum += m.distance;
        min = @min(min, m.distance);
        max = @max(max, m.distance);
    }

    return .{
        .total_matches = matches.len,
        .mean_distance = sum / @as(f32, @floatFromInt(matches.len)),
        .min_distance = min,
        .max_distance = max,
    };
}

pub const MatchStats = struct {
    total_matches: usize,
    mean_distance: f32,
    min_distance: f32,
    max_distance: f32,
};

// Tests
const expectEqual = std.testing.expectEqual;

test "OptimalMatcher basic matching" {
    const allocator = std.testing.allocator;

    // Create test descriptors
    var query = [_]BinaryDescriptor{
        BinaryDescriptor.init(),
        BinaryDescriptor.init(),
    };
    var train = [_]BinaryDescriptor{
        BinaryDescriptor.init(),
        BinaryDescriptor.init(),
        BinaryDescriptor.init(),
    };

    // Set up descriptors with known distances
    query[0].setBit(0);
    query[1].setBit(10);

    train[0].setBit(0); // Best match for query[0] (distance 0)
    train[1].setBit(10); // Best match for query[1] (distance 0)
    train[2].setBit(20); // Extra descriptor

    const matcher = OptimalMatcher{
        .max_distance = 100,
    };

    const matches = try matcher.match(&query, &train, allocator);
    defer allocator.free(matches);

    // Should find optimal one-to-one matches
    try expectEqual(@as(usize, 2), matches.len);

    // Each query should match its best train descriptor
    for (matches) |m| {
        if (m.query_idx == 0) {
            try expectEqual(@as(usize, 0), m.train_idx);
            try expectEqual(@as(f32, 0), m.distance);
        } else if (m.query_idx == 1) {
            try expectEqual(@as(usize, 1), m.train_idx);
            try expectEqual(@as(f32, 0), m.distance);
        }
    }
}

test "OptimalMatcher with conflicting best matches" {
    const allocator = std.testing.allocator;

    // Create scenario where both queries prefer the same train descriptor
    var query = [_]BinaryDescriptor{
        BinaryDescriptor.init(),
        BinaryDescriptor.init(),
    };
    var train = [_]BinaryDescriptor{
        BinaryDescriptor.init(),
        BinaryDescriptor.init(),
    };

    // Both queries are similar to train[0]
    query[0].setBit(0);
    query[1].setBit(0);
    query[1].setBit(1); // Slightly different

    train[0].setBit(0); // Best for both
    train[1].setBit(10); // Worse alternative

    const matcher = OptimalMatcher{
        .max_distance = 100,
    };

    const matches = try matcher.match(&query, &train, allocator);
    defer allocator.free(matches);

    // Should find optimal assignment (one-to-one)
    try expectEqual(@as(usize, 2), matches.len);

    // Check that each train descriptor is used at most once
    var train_used = [_]bool{false} ** 2;
    for (matches) |m| {
        try expectEqual(false, train_used[m.train_idx]);
        train_used[m.train_idx] = true;
    }
}

test "OptimalMatcher with distance threshold" {
    const allocator = std.testing.allocator;

    var query = [_]BinaryDescriptor{
        BinaryDescriptor.init(),
    };
    var train = [_]BinaryDescriptor{
        BinaryDescriptor.init(),
    };

    // Create large distance
    for (0..100) |i| {
        query[0].setBit(i);
    }
    // train[0] has no bits set, distance = 100

    const matcher = OptimalMatcher{
        .max_distance = 50, // Below actual distance
    };

    const matches = try matcher.match(&query, &train, allocator);
    defer allocator.free(matches);

    // Should filter out matches above threshold
    try expectEqual(@as(usize, 0), matches.len);
}
