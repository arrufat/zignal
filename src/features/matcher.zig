const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

const BinaryDescriptor = @import("BinaryDescriptor.zig");

/// A match between two feature descriptors
pub const Match = struct {
    /// Index of the query descriptor
    query_idx: usize,

    /// Index of the train descriptor
    train_idx: usize,

    /// Distance between descriptors (Hamming distance for binary)
    distance: f32,

    /// Compare matches by distance (for sorting)
    pub fn compareDistance(context: void, a: Match, b: Match) bool {
        _ = context;
        return a.distance < b.distance;
    }

    /// Check if this is a good match based on distance threshold
    pub fn isGood(self: Match, threshold: f32) bool {
        return self.distance < threshold;
    }
};

/// Brute-force matcher for binary descriptors using Hamming distance
pub const BruteForceMatcher = struct {
    /// Whether to cross-check matches (match must be mutual best match)
    cross_check: bool = false,

    /// Maximum allowed Hamming distance for a match
    max_distance: u32 = 64,

    /// Lowe's ratio test threshold (0.7-0.8 typical)
    ratio_threshold: f32 = 0.8,

    /// Match descriptors from query set to train set
    pub fn match(
        self: BruteForceMatcher,
        query_descriptors: []const BinaryDescriptor,
        train_descriptors: []const BinaryDescriptor,
        allocator: Allocator,
    ) ![]Match {
        if (query_descriptors.len == 0 or train_descriptors.len == 0) {
            return try allocator.alloc(Match, 0);
        }

        var matches: ArrayList(Match) = .{};
        defer matches.deinit(allocator);

        // For each query descriptor, find best matches in train set
        for (query_descriptors, 0..) |q_desc, q_idx| {
            var best_dist: u32 = std.math.maxInt(u32);
            var second_best_dist: u32 = std.math.maxInt(u32);
            var best_idx: usize = 0;

            // Find best and second-best matches
            for (train_descriptors, 0..) |t_desc, t_idx| {
                const dist = q_desc.hammingDistance(t_desc);

                if (dist < best_dist) {
                    second_best_dist = best_dist;
                    best_dist = dist;
                    best_idx = t_idx;
                } else if (dist < second_best_dist) {
                    second_best_dist = dist;
                }
            }

            // Apply ratio test and distance threshold
            const best_dist_f = @as(f32, @floatFromInt(best_dist));
            const second_best_dist_f = @as(f32, @floatFromInt(second_best_dist));

            if (best_dist <= self.max_distance and
                (second_best_dist == std.math.maxInt(u32) or
                    best_dist_f < self.ratio_threshold * second_best_dist_f))
            {

                // If cross-check is enabled, verify reverse match
                if (self.cross_check) {
                    const reverse_best = self.findBestMatch(train_descriptors[best_idx], query_descriptors);
                    if (reverse_best.index == q_idx) {
                        try matches.append(allocator, .{
                            .query_idx = q_idx,
                            .train_idx = best_idx,
                            .distance = best_dist_f,
                        });
                    }
                } else {
                    try matches.append(allocator, .{
                        .query_idx = q_idx,
                        .train_idx = best_idx,
                        .distance = best_dist_f,
                    });
                }
            }
        }

        return try matches.toOwnedSlice(allocator);
    }

    /// Find k nearest neighbors for each query descriptor
    pub fn knnMatch(
        self: BruteForceMatcher,
        query_descriptors: []const BinaryDescriptor,
        train_descriptors: []const BinaryDescriptor,
        k: usize,
        allocator: Allocator,
    ) ![][]Match {
        if (query_descriptors.len == 0 or train_descriptors.len == 0 or k == 0) {
            return try allocator.alloc([]Match, 0);
        }

        var all_matches = try allocator.alloc([]Match, query_descriptors.len);
        var filled: usize = 0;
        errdefer {
            for (all_matches[0..filled]) |matches| {
                allocator.free(matches);
            }
            allocator.free(all_matches);
        }

        // Allocate distances buffer once
        var distances = try allocator.alloc(Match, train_descriptors.len);
        defer allocator.free(distances);

        // For each query descriptor
        for (query_descriptors, 0..) |q_desc, q_idx| {
            // Calculate distances to all train descriptors
            for (train_descriptors, 0..) |t_desc, t_idx| {
                distances[t_idx] = .{
                    .query_idx = q_idx,
                    .train_idx = t_idx,
                    .distance = @floatFromInt(q_desc.hammingDistance(t_desc)),
                };
            }

            // Sort by distance
            std.mem.sort(Match, distances, {}, Match.compareDistance);

            // Keep top k matches that pass distance threshold
            var k_matches: ArrayList(Match) = .{};
            errdefer k_matches.deinit(allocator);
            for (distances[0..@min(k, distances.len)]) |m| {
                if (m.distance <= @as(f32, @floatFromInt(self.max_distance))) {
                    try k_matches.append(allocator, m);
                }
            }

            const owned = try k_matches.toOwnedSlice(allocator);
            all_matches[q_idx] = owned;
            filled = q_idx + 1;
        }

        return all_matches;
    }

    /// Find radius neighbors - all matches within a distance threshold
    pub fn radiusMatch(
        self: BruteForceMatcher,
        query_descriptors: []const BinaryDescriptor,
        train_descriptors: []const BinaryDescriptor,
        max_dist: f32,
        allocator: Allocator,
    ) ![][]Match {
        _ = self; // Currently unused, but kept for API consistency
        if (query_descriptors.len == 0 or train_descriptors.len == 0) {
            return try allocator.alloc([]Match, 0);
        }

        var all_matches = try allocator.alloc([]Match, query_descriptors.len);
        var filled: usize = 0;
        errdefer {
            for (all_matches[0..filled]) |matches| {
                allocator.free(matches);
            }
            allocator.free(all_matches);
        }

        // For each query descriptor
        for (query_descriptors, 0..) |q_desc, q_idx| {
            var radius_matches: ArrayList(Match) = .{};
            errdefer radius_matches.deinit(allocator);

            // Find all matches within radius
            for (train_descriptors, 0..) |t_desc, t_idx| {
                const dist = @as(f32, @floatFromInt(q_desc.hammingDistance(t_desc)));

                if (dist <= max_dist) {
                    try radius_matches.append(allocator, .{
                        .query_idx = q_idx,
                        .train_idx = t_idx,
                        .distance = dist,
                    });
                }
            }

            // Sort by distance
            const matches_slice = try radius_matches.toOwnedSlice(allocator);
            std.mem.sort(Match, matches_slice, {}, Match.compareDistance);
            all_matches[q_idx] = matches_slice;
            filled = q_idx + 1;
        }

        return all_matches;
    }

    /// Helper: Find best match for a single descriptor
    fn findBestMatch(
        self: BruteForceMatcher,
        query: BinaryDescriptor,
        train_descriptors: []const BinaryDescriptor,
    ) struct { index: usize, distance: u32 } {
        _ = self;
        var best_dist: u32 = std.math.maxInt(u32);
        var best_idx: usize = 0;

        for (train_descriptors, 0..) |t_desc, t_idx| {
            const dist = query.hammingDistance(t_desc);
            if (dist < best_dist) {
                best_dist = dist;
                best_idx = t_idx;
            }
        }

        return .{ .index = best_idx, .distance = best_dist };
    }
};

/// Compute match statistics
pub const MatchStats = struct {
    total_matches: usize,
    mean_distance: f32,
    min_distance: f32,
    max_distance: f32,

    pub fn compute(matches: []const Match) MatchStats {
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

        for (matches) |match| {
            sum += match.distance;
            min = @min(min, match.distance);
            max = @max(max, match.distance);
        }

        return .{
            .total_matches = matches.len,
            .mean_distance = sum / @as(f32, @floatFromInt(matches.len)),
            .min_distance = min,
            .max_distance = max,
        };
    }
};

// Tests
test "BruteForceMatcher basic matching" {
    const allocator = std.testing.allocator;

    // Create some test descriptors
    var desc1 = [_]BinaryDescriptor{
        BinaryDescriptor.init(),
        BinaryDescriptor.init(),
    };
    var desc2 = [_]BinaryDescriptor{
        BinaryDescriptor.init(),
        BinaryDescriptor.init(),
    };

    // Make descriptors slightly different
    desc1[0].setBit(0);
    desc1[0].setBit(10);
    desc1[1].setBit(5);
    desc1[1].setBit(15);

    desc2[0].setBit(0); // Similar to desc1[0]
    desc2[0].setBit(11); // Slightly different
    desc2[1].setBit(100); // Very different
    desc2[1].setBit(200);

    const matcher = BruteForceMatcher{
        .max_distance = 100,
        .cross_check = false,
    };

    const matches = try matcher.match(&desc1, &desc2, allocator);
    defer allocator.free(matches);

    // Should find matches
    try expectEqual(true, matches.len > 0);

    // First descriptor should match better with first in desc2
    if (matches.len > 0) {
        try expectEqual(@as(usize, 0), matches[0].query_idx);
        try expectEqual(@as(usize, 0), matches[0].train_idx);
    }
}

test "BruteForceMatcher cross-check" {
    const allocator = std.testing.allocator;

    // Create descriptors where only some have mutual best matches
    var desc1 = [_]BinaryDescriptor{
        BinaryDescriptor.init(),
        BinaryDescriptor.init(),
    };
    var desc2 = [_]BinaryDescriptor{
        BinaryDescriptor.init(),
        BinaryDescriptor.init(),
    };

    // Set up mutual best match between desc1[0] and desc2[0]
    desc1[0].setBit(0);
    desc2[0].setBit(0);

    // desc1[1] and desc2[1] are very different
    for (0..100) |i| {
        desc1[1].setBit(i);
    }
    for (100..200) |i| {
        desc2[1].setBit(i);
    }

    const matcher_no_cross = BruteForceMatcher{
        .max_distance = 256,
        .cross_check = false,
    };

    const matcher_cross = BruteForceMatcher{
        .max_distance = 256,
        .cross_check = true,
    };

    const matches_no_cross = try matcher_no_cross.match(&desc1, &desc2, allocator);
    defer allocator.free(matches_no_cross);

    const matches_cross = try matcher_cross.match(&desc1, &desc2, allocator);
    defer allocator.free(matches_cross);

    // Cross-check should produce fewer matches
    try expectEqual(true, matches_cross.len <= matches_no_cross.len);
}

test "BruteForceMatcher kNN matching" {
    const allocator = std.testing.allocator;

    // Create query descriptor
    var query = [_]BinaryDescriptor{BinaryDescriptor.init()};
    query[0].setBit(0);

    // Create train descriptors with varying distances
    var train = [_]BinaryDescriptor{
        BinaryDescriptor.init(), // Distance 1
        BinaryDescriptor.init(), // Distance 2
        BinaryDescriptor.init(), // Distance 3
    };
    train[0].setBit(1);
    train[1].setBit(1);
    train[1].setBit(2);
    train[2].setBit(1);
    train[2].setBit(2);
    train[2].setBit(3);

    const matcher = BruteForceMatcher{};

    const knn_matches = try matcher.knnMatch(&query, &train, 2, allocator);
    defer {
        for (knn_matches) |matches| {
            allocator.free(matches);
        }
        allocator.free(knn_matches);
    }

    // Should return k=2 best matches for the query
    try expectEqual(@as(usize, 1), knn_matches.len);
    try expectEqual(true, knn_matches[0].len <= 2);

    // Matches should be sorted by distance
    if (knn_matches[0].len >= 2) {
        try expectEqual(true, knn_matches[0][0].distance <= knn_matches[0][1].distance);
    }
}

test "MatchStats computation" {
    const matches = [_]Match{
        .{ .query_idx = 0, .train_idx = 0, .distance = 10 },
        .{ .query_idx = 1, .train_idx = 1, .distance = 20 },
        .{ .query_idx = 2, .train_idx = 2, .distance = 30 },
    };

    const stats = MatchStats.compute(&matches);

    try expectEqual(@as(usize, 3), stats.total_matches);
    try expectApproxEqAbs(@as(f32, 20), stats.mean_distance, 0.01);
    try expectEqual(@as(f32, 10), stats.min_distance);
    try expectEqual(@as(f32, 30), stats.max_distance);
}
