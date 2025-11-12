//! ORB (Oriented FAST and Rotated BRIEF) feature detector and descriptor

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const expectEqual = std.testing.expectEqual;

const Image = @import("../image.zig").Image;
const ImagePyramid = @import("../image/pyramid.zig").ImagePyramid;
const BinaryDescriptor = @import("BinaryDescriptor.zig");
const Fast = @import("Fast.zig");
const KeyPoint = @import("KeyPoint.zig");

/// Default patch size for BRIEF descriptor (industry standard)
pub const DEFAULT_PATCH_SIZE: u8 = 31;

/// ORB pattern for BRIEF descriptor - learned pattern from ORB paper
/// Each entry is [x1, y1, x2, y2] for the two points to compare
/// These are pre-computed optimal sampling locations within a 31x31 patch
const orb_pattern = [256][4]i8{
    .{ 8, -3, 9, 5 },       .{ 4, 2, 7, -12 },      .{ -11, 9, -8, 2 },     .{ 7, -12, 12, -13 },
    .{ 2, -13, 2, 12 },     .{ 1, -7, 1, 6 },       .{ -2, -10, -2, -4 },   .{ -13, -13, -11, -8 },
    .{ -13, -3, -12, -9 },  .{ 10, 4, 11, 9 },      .{ -13, -8, -8, -9 },   .{ -11, 7, -9, 12 },
    .{ 7, 7, 12, 6 },       .{ -4, -5, -3, 0 },     .{ -13, 2, -12, -3 },   .{ -9, 0, -7, 5 },
    .{ 12, -6, 12, -1 },    .{ -3, 6, -2, 12 },     .{ -6, -13, -4, -8 },   .{ 11, -13, 12, -8 },
    .{ 4, 7, 5, 1 },        .{ 5, -3, 10, -3 },     .{ 3, -7, 6, 12 },      .{ -8, -7, -6, -2 },
    .{ -2, 11, -1, -10 },   .{ -13, 12, -8, 10 },   .{ -7, 3, -5, -3 },     .{ -4, 2, -3, 7 },
    .{ -10, -12, -6, 11 },  .{ 5, -12, 6, -7 },     .{ 5, -6, 7, -1 },      .{ 1, 0, 4, -5 },
    .{ 9, 11, 11, -13 },    .{ 4, 7, 4, 12 },       .{ 2, -1, 4, 4 },       .{ -4, -12, -2, 7 },
    .{ -8, -5, -7, -10 },   .{ 4, 11, 9, 12 },      .{ 0, -8, 1, -13 },     .{ -13, -2, -8, 2 },
    .{ -3, -2, -2, 3 },     .{ -6, 9, -4, -9 },     .{ 8, 12, 10, 7 },      .{ 0, 9, 1, 3 },
    .{ 7, -5, 11, -10 },    .{ -13, -6, -11, 0 },   .{ 10, 7, 12, 1 },      .{ -6, -3, -6, 12 },
    .{ 10, -9, 12, -4 },    .{ -13, 8, -8, -12 },   .{ -13, 0, -8, -4 },    .{ 3, 3, 7, 8 },
    .{ 5, 7, 10, -7 },      .{ -1, 7, 1, -12 },     .{ 3, -10, 5, 6 },      .{ 2, -4, 3, -10 },
    .{ -13, 0, -13, 5 },    .{ -13, -7, -12, 12 },  .{ -13, 3, -11, 8 },    .{ -7, 12, -4, 7 },
    .{ 6, -10, 12, 8 },     .{ -9, -1, -7, -6 },    .{ -2, -5, 0, 12 },     .{ -12, 5, -7, 5 },
    .{ 3, -10, 8, -13 },    .{ -7, -7, -4, 5 },     .{ -3, -2, -1, -7 },    .{ 2, 9, 5, -11 },
    .{ -11, -13, -5, -13 }, .{ -1, 6, 0, -1 },      .{ 5, -3, 5, 2 },       .{ -4, -13, -4, 12 },
    .{ -9, -6, -9, 6 },     .{ -12, -10, -8, -4 },  .{ 10, 2, 12, -3 },     .{ 7, 12, 12, 12 },
    .{ -7, -13, -6, 5 },    .{ -4, 9, -3, 4 },      .{ 7, -1, 12, 2 },      .{ -7, 6, -5, 1 },
    .{ -13, 11, -12, 5 },   .{ -3, 7, -2, -6 },     .{ 7, -8, 12, -7 },     .{ -13, -7, -11, -12 },
    .{ 1, -3, 12, 12 },     .{ 2, -6, 3, 0 },       .{ -4, 3, -2, -13 },    .{ -1, -13, 1, 9 },
    .{ 7, 1, 8, -6 },       .{ 1, -1, 3, 12 },      .{ 9, 1, 12, 6 },       .{ -1, -9, -1, 3 },
    .{ -13, -13, -10, 5 },  .{ 7, 7, 10, 12 },      .{ 12, -5, 12, 9 },     .{ 6, 3, 7, 11 },
    .{ 5, -13, 6, 10 },     .{ 2, -12, 2, 3 },      .{ 3, 8, 4, -6 },       .{ 2, 6, 12, -13 },
    .{ 9, -12, 10, 3 },     .{ -8, 4, -7, 9 },      .{ -11, 12, -4, -6 },   .{ 1, 12, 2, -8 },
    .{ 6, -9, 7, -4 },      .{ 2, 3, 3, -2 },       .{ 6, 3, 11, 0 },       .{ 3, -3, 8, -8 },
    .{ 7, 8, 9, 3 },        .{ -11, -5, -6, -4 },   .{ -10, 11, -5, 10 },   .{ -5, -8, -3, 12 },
    .{ -10, 5, -9, 0 },     .{ 8, -1, 12, -6 },     .{ 4, -6, 6, -11 },     .{ -10, 12, -8, 7 },
    .{ 4, -2, 6, 7 },       .{ -2, 0, -2, 12 },     .{ -5, -8, -5, 2 },     .{ 7, -6, 10, 12 },
    .{ -9, -13, -8, -8 },   .{ -5, -13, -5, -2 },   .{ 8, -8, 9, -13 },     .{ -9, -11, -9, 0 },
    .{ 1, -8, 1, -2 },      .{ 7, -4, 9, 1 },       .{ -2, 1, -1, -4 },     .{ 11, -6, 12, -11 },
    .{ -12, -9, -6, 4 },    .{ 3, 7, 7, 12 },       .{ 5, 5, 10, 8 },       .{ 0, -4, 2, 8 },
    .{ -9, 12, -5, -13 },   .{ 0, 7, 2, 12 },       .{ -1, 2, 1, 7 },       .{ 5, 11, 7, -9 },
    .{ 3, 5, 6, -8 },       .{ -13, -4, -8, 9 },    .{ -5, 9, -3, -3 },     .{ -4, -7, -3, -12 },
    .{ 6, 5, 8, 0 },        .{ -7, 6, -6, 12 },     .{ -13, 6, -5, -2 },    .{ 1, -10, 3, 10 },
    .{ 4, 1, 8, -4 },       .{ -2, -2, 2, -13 },    .{ 2, -12, 12, 12 },    .{ -2, -13, 0, -6 },
    .{ 4, 1, 9, 3 },        .{ -6, -10, -3, -5 },   .{ -3, -13, -1, 1 },    .{ 7, 5, 12, -11 },
    .{ 4, -2, 5, -7 },      .{ -13, 9, -9, -5 },    .{ 7, 1, 8, 6 },        .{ 7, -8, 7, 6 },
    .{ -7, -4, -7, 1 },     .{ -8, 11, -7, -8 },    .{ -13, 6, -12, -8 },   .{ 2, 4, 3, 9 },
    .{ 10, -5, 12, 3 },     .{ -6, -5, -6, 7 },     .{ 8, -3, 9, -8 },      .{ 2, -12, 2, 8 },
    .{ -11, -2, -10, 3 },   .{ -12, -13, -7, -9 },  .{ -11, 0, -10, -5 },   .{ 5, -3, 11, 8 },
    .{ -2, -13, -1, 12 },   .{ -1, -8, 0, 9 },      .{ -13, -11, -12, -5 }, .{ -10, -2, -10, 11 },
    .{ -3, 9, -2, -13 },    .{ 2, -3, 3, 2 },       .{ -9, -13, -4, 0 },    .{ -4, 6, -3, -10 },
    .{ -4, 12, -2, -7 },    .{ -6, -11, -4, 9 },    .{ 6, -3, 6, 11 },      .{ -13, 11, -5, 5 },
    .{ 11, 11, 12, 6 },     .{ 7, -5, 12, -2 },     .{ -1, 12, 0, 7 },      .{ -4, -8, -3, -2 },
    .{ -7, 1, -6, 7 },      .{ -13, -12, -8, -13 }, .{ -7, -2, -6, -8 },    .{ -8, 5, -6, -9 },
    .{ -5, -1, -4, 5 },     .{ -13, 7, -8, 10 },    .{ 1, 5, 5, -13 },      .{ 1, 0, 10, -13 },
    .{ 9, 12, 10, -1 },     .{ 5, -8, 10, -9 },     .{ -1, 11, 1, -13 },    .{ -9, -3, -6, 2 },
    .{ -1, -10, 1, 12 },    .{ -13, 1, -8, -10 },   .{ 8, -11, 10, -6 },    .{ 2, -13, 3, -6 },
    .{ 7, -13, 12, -9 },    .{ -10, -10, -5, -7 },  .{ -10, -8, -8, -13 },  .{ 4, -6, 8, 5 },
    .{ 3, 12, 8, -13 },     .{ -4, 2, -3, -3 },     .{ 5, -13, 10, -12 },   .{ 4, -13, 5, -1 },
    .{ -9, 9, -4, 3 },      .{ 0, 3, 3, -9 },       .{ -12, 1, -6, 1 },     .{ 3, 2, 4, -8 },
    .{ -10, -10, -10, 9 },  .{ 8, -13, 12, 12 },    .{ -8, -12, -6, -5 },   .{ 2, 2, 3, 7 },
    .{ 10, 6, 11, -8 },     .{ 6, 8, 8, -12 },      .{ -7, 10, -6, 5 },     .{ -3, -9, -3, 9 },
    .{ -1, -13, -1, 5 },    .{ -3, -7, -3, 4 },     .{ -8, -2, -8, 3 },     .{ 4, 2, 12, 12 },
    .{ 2, -5, 3, 11 },      .{ 6, -9, 11, -13 },    .{ 3, -1, 7, 12 },      .{ 11, -1, 12, 4 },
    .{ -3, 0, -3, 6 },      .{ 4, -11, 4, 12 },     .{ 2, -4, 2, 1 },       .{ -10, -6, -8, 1 },
    .{ -13, 7, -11, 1 },    .{ -13, 12, -11, -13 }, .{ 6, 0, 11, -13 },     .{ 0, -1, 1, 4 },
    .{ -13, 3, -9, -2 },    .{ -9, 8, -6, -3 },     .{ -13, -6, -8, -2 },   .{ 5, -9, 8, 10 },
    .{ 2, 7, 3, -9 },       .{ -1, -6, -1, -1 },    .{ 9, 5, 11, -2 },      .{ 11, -3, 12, -8 },
    .{ 3, 0, 3, 5 },        .{ -1, 4, 0, 10 },      .{ 3, -6, 4, 5 },       .{ -13, 0, -10, 5 },
    .{ 5, 8, 12, 11 },      .{ 8, 9, 9, -6 },       .{ 7, -4, 8, -12 },     .{ -10, 4, -10, 9 },
    .{ 7, 3, 12, 4 },       .{ 9, -7, 10, -2 },     .{ 7, 0, 12, -2 },      .{ -1, -6, 0, -11 },
};

/// Maximum number of features to detect
n_features: usize = 500,

/// Scale factor between pyramid levels
scale_factor: f32 = 1.2,

/// Number of pyramid levels
n_levels: u8 = 8,

/// Border width where features are not detected
edge_threshold: u8 = DEFAULT_PATCH_SIZE / 2,

/// First pyramid level to use (0 = original resolution)
first_level: u8 = 0,

/// Number of points to compare in BRIEF (2 or 3, we use 2)
wta_k: u8 = 2,

/// Patch size for BRIEF descriptor
patch_size: u8 = DEFAULT_PATCH_SIZE,

/// FAST threshold for corner detection
fast_threshold: u8 = 20,

/// Score type for keypoint response (HARRIS or FAST)
score_type: ScoreType = .fast_score,

const Orb = @This();

pub const ScoreType = enum {
    harris_score,
    fast_score,
};

/// Detect keypoints in the image at multiple scales
pub fn detect(self: Orb, image: Image(u8), allocator: Allocator) ![]KeyPoint {
    // Build image pyramid
    var pyramid = try ImagePyramid(u8).build(
        allocator,
        image,
        self.n_levels,
        self.scale_factor,
        1.6, // blur_sigma for anti-aliasing
    );
    defer pyramid.deinit();

    // Calculate how many features to detect per level
    const features_per_level = try self.computeFeaturesPerLevel(allocator);
    defer allocator.free(features_per_level);

    var all_keypoints: ArrayList(KeyPoint) = .{};
    defer all_keypoints.deinit(allocator);

    // Detect features at each pyramid level
    for (0..self.n_levels) |level| {
        if (level < self.first_level) continue;

        const level_image = pyramid.levels[level];
        const n_desired = features_per_level[level];

        if (n_desired == 0) continue;

        // Detect FAST corners with adaptive threshold
        // Lower threshold for higher pyramid levels to maintain detection
        const adaptive_threshold = self.computeAdaptiveThreshold(level);

        var fast_detector = Fast{
            .threshold = adaptive_threshold,
            .nonmax_suppression = true,
            .min_contiguous = 9,
        };

        const corners = try fast_detector.detect(level_image, allocator);
        defer allocator.free(corners);

        // Compute Harris response if requested
        if (self.score_type == .harris_score) {
            for (corners) |*corner| {
                corner.response = computeHarrisResponse(level_image, corner.*);
            }
        }

        // Keep only the best corners for this level
        var level_keypoints = corners;
        if (corners.len > n_desired) {
            // Sort by response
            std.mem.sort(KeyPoint, corners, {}, KeyPoint.compareResponse);
            level_keypoints = corners[0..n_desired];
        }

        // Compute orientation and scale coordinates
        // Scale-aware edge margin: smaller at higher pyramid levels
        const scale = std.math.pow(f32, self.scale_factor, @as(f32, @floatFromInt(level)));
        const edge_margin = @as(f32, @floatFromInt(self.edge_threshold)) / scale;
        const min_margin = 3.0; // Minimum margin for FAST detector
        const actual_margin = @max(min_margin, edge_margin);

        for (level_keypoints) |*kp| {
            // Filter out keypoints too close to image borders
            if (kp.x < actual_margin or kp.x >= @as(f32, @floatFromInt(level_image.cols)) - actual_margin or
                kp.y < actual_margin or kp.y >= @as(f32, @floatFromInt(level_image.rows)) - actual_margin)
            {
                continue;
            }

            // Compute orientation using intensity centroid
            kp.angle = self.computeOrientation(level_image, kp.*);
            kp.octave = @intCast(level);

            // Scale coordinates to original image
            kp.x *= scale;
            kp.y *= scale;
            kp.size *= scale;

            try all_keypoints.append(allocator, kp.*);
        }
    }

    return try all_keypoints.toOwnedSlice(allocator);
}

/// Compute descriptors for detected keypoints
pub fn compute(self: Orb, image: Image(u8), keypoints: []const KeyPoint, allocator: Allocator) ![]BinaryDescriptor {
    // Build pyramid for multi-scale description
    var pyramid = try ImagePyramid(u8).build(
        allocator,
        image,
        self.n_levels,
        self.scale_factor,
        1.6, // blur_sigma for anti-aliasing
    );
    defer pyramid.deinit();

    var descriptors = try allocator.alloc(BinaryDescriptor, keypoints.len);

    for (keypoints, 0..) |kp, i| {
        const level = @min(@as(usize, @intCast(@max(0, kp.octave))), self.n_levels - 1);
        const level_image = pyramid.levels[level];

        // Scale keypoint to pyramid level
        const scale = std.math.pow(f32, self.scale_factor, @as(f32, @floatFromInt(level)));
        const level_kp = KeyPoint{
            .x = kp.x / scale,
            .y = kp.y / scale,
            .size = kp.size / scale,
            .angle = kp.angle,
            .response = kp.response,
            .octave = kp.octave,
            .class_id = kp.class_id,
        };

        descriptors[i] = self.computeBriefDescriptor(level_image, level_kp);
    }

    return descriptors;
}

/// Detect keypoints using a pre-built pyramid
fn detectWithPyramid(self: Orb, pyramid: ImagePyramid(u8), allocator: Allocator) ![]KeyPoint {
    // Calculate how many features to detect per level
    const features_per_level = try self.computeFeaturesPerLevel(allocator);
    defer allocator.free(features_per_level);

    var all_keypoints: ArrayList(KeyPoint) = .{};
    defer all_keypoints.deinit(allocator);

    // Detect features at each pyramid level
    for (0..self.n_levels) |level| {
        if (level < self.first_level) continue;

        const level_image = pyramid.levels[level];
        const n_desired = features_per_level[level];

        if (n_desired == 0) continue;

        // Detect FAST corners with adaptive threshold
        // Lower threshold for higher pyramid levels to maintain detection
        const adaptive_threshold = self.computeAdaptiveThreshold(level);

        var fast_detector = Fast{
            .threshold = adaptive_threshold,
            .nonmax_suppression = true,
            .min_contiguous = 9,
        };

        const corners = try fast_detector.detect(level_image, allocator);
        defer allocator.free(corners);

        // Compute Harris response if requested
        if (self.score_type == .harris_score) {
            for (corners) |*corner| {
                corner.response = computeHarrisResponse(level_image, corner.*);
            }
        }

        // Keep only the best corners for this level
        var level_keypoints = corners;
        if (corners.len > n_desired) {
            // Sort by response
            std.mem.sort(KeyPoint, corners, {}, KeyPoint.compareResponse);
            level_keypoints = corners[0..n_desired];
        }

        // Compute orientation and scale coordinates
        // Scale-aware edge margin: smaller at higher pyramid levels
        const scale = std.math.pow(f32, self.scale_factor, @as(f32, @floatFromInt(level)));
        const edge_margin = @as(f32, @floatFromInt(self.edge_threshold)) / scale;
        const min_margin = 3.0; // Minimum margin for FAST detector
        const actual_margin = @max(min_margin, edge_margin);

        for (level_keypoints) |*kp| {
            // Filter out keypoints too close to image borders
            if (kp.x < actual_margin or kp.x >= @as(f32, @floatFromInt(level_image.cols)) - actual_margin or
                kp.y < actual_margin or kp.y >= @as(f32, @floatFromInt(level_image.rows)) - actual_margin)
            {
                continue;
            }

            // Compute orientation using intensity centroid
            kp.angle = self.computeOrientation(level_image, kp.*);
            kp.octave = @intCast(level);

            // Scale coordinates to original image
            kp.x *= scale;
            kp.y *= scale;
            kp.size *= scale;

            try all_keypoints.append(allocator, kp.*);
        }
    }

    return try all_keypoints.toOwnedSlice(allocator);
}

/// Compute descriptors using a pre-built pyramid
fn computeWithPyramid(self: Orb, pyramid: ImagePyramid(u8), keypoints: []const KeyPoint, allocator: Allocator) ![]BinaryDescriptor {
    var descriptors = try allocator.alloc(BinaryDescriptor, keypoints.len);

    for (keypoints, 0..) |kp, i| {
        const level = @min(@as(usize, @intCast(@max(0, kp.octave))), self.n_levels - 1);
        const level_image = pyramid.levels[level];

        // Scale keypoint to pyramid level
        const scale = std.math.pow(f32, self.scale_factor, @as(f32, @floatFromInt(level)));
        const level_kp = KeyPoint{
            .x = kp.x / scale,
            .y = kp.y / scale,
            .size = kp.size / scale,
            .angle = kp.angle,
            .response = kp.response,
            .octave = kp.octave,
            .class_id = kp.class_id,
        };

        descriptors[i] = self.computeBriefDescriptor(level_image, level_kp);
    }

    return descriptors;
}

/// Detect keypoints and compute their descriptors
pub fn detectAndCompute(
    self: Orb,
    image: Image(u8),
    allocator: Allocator,
) !struct { keypoints: []KeyPoint, descriptors: []BinaryDescriptor } {
    // Build pyramid once for both detection and description
    var pyramid = try ImagePyramid(u8).build(
        allocator,
        image,
        self.n_levels,
        self.scale_factor,
        1.6, // blur_sigma for anti-aliasing
    );
    defer pyramid.deinit();

    // Detect keypoints using the pyramid
    const keypoints = try self.detectWithPyramid(pyramid, allocator);
    errdefer allocator.free(keypoints);

    // Compute descriptors using the same pyramid
    const descriptors = try self.computeWithPyramid(pyramid, keypoints, allocator);

    return .{
        .keypoints = keypoints,
        .descriptors = descriptors,
    };
}

/// Compute the distribution of features per pyramid level
fn computeFeaturesPerLevel(self: Orb, allocator: Allocator) ![]usize {
    var n_features_per_level = try allocator.alloc(usize, self.n_levels);

    // Exponential scale distribution for better coverage
    // Uses formula: n_features * (1 - factor) / (1 - factor^n_levels) * factor^level
    const levels_usize = @as(usize, @intCast(self.n_levels));

    // Handle degenerate scale factors by distributing features evenly
    if (self.n_levels == 1 or self.scale_factor <= 1.0) {
        const base = if (levels_usize == 0) 0 else self.n_features / levels_usize;
        var remainder = if (levels_usize == 0) 0 else self.n_features % levels_usize;

        for (0..levels_usize) |level| {
            var count = base;
            if (remainder > 0) {
                count += 1;
                remainder -= 1;
            }
            n_features_per_level[level] = count;
        }

        return n_features_per_level;
    }

    const factor = 1.0 / self.scale_factor;
    const factor_to_n = std.math.pow(f32, factor, @as(f32, @floatFromInt(self.n_levels)));

    // Distribute features with exponential decay
    var assigned: usize = 0;
    const n_features_f = @as(f32, @floatFromInt(self.n_features));

    for (0..self.n_levels) |level| {
        const remaining = if (assigned < self.n_features) self.n_features - assigned else 0;
        if (level == self.n_levels - 1 or remaining == 0) {
            n_features_per_level[level] = remaining;
            assigned += remaining;
            continue;
        }

        const scale_factor_level = std.math.pow(f32, factor, @as(f32, @floatFromInt(level)));

        // Calculate desired features for this level
        const desired_float = n_features_f * (1.0 - factor) / (1.0 - factor_to_n) * scale_factor_level;
        const desired_clamped = @min(@as(usize, @intFromFloat(@round(desired_float))), remaining);

        // Ensure at least some features per level (except possibly last level)
        // Reduced minimum to allow more flexible distribution, but never exceed remaining budget
        const base_min = @max(10, self.n_features / (self.n_levels * 3));
        const min_features = @min(remaining, base_min);

        const allocated = if (desired_clamped < min_features) min_features else desired_clamped;
        n_features_per_level[level] = allocated;
        assigned += n_features_per_level[level];
    }

    return n_features_per_level;
}

/// Compute keypoint orientation using intensity centroid with circular mask
fn computeOrientation(self: Orb, image: Image(u8), kp: KeyPoint) f32 {
    const half_patch = self.patch_size / 2;
    const radius = @as(f32, @floatFromInt(half_patch));
    const radius_sq = radius * radius;
    const x = @as(isize, @intFromFloat(kp.x));
    const y = @as(isize, @intFromFloat(kp.y));

    var m00: f32 = 0; // Zeroth moment
    var m10: f32 = 0; // First moment in x
    var m01: f32 = 0; // First moment in y

    // Compute moments with circular mask
    for (0..self.patch_size) |v| {
        const dy = @as(isize, @intCast(v)) - half_patch;
        const py = y + dy;

        if (py < 0 or py >= image.rows) continue;

        for (0..self.patch_size) |u| {
            const dx = @as(isize, @intCast(u)) - half_patch;
            const px = x + dx;

            if (px < 0 or px >= image.cols) continue;

            // Apply circular mask
            const dist_sq = @as(f32, @floatFromInt(dx * dx + dy * dy));
            if (dist_sq > radius_sq) continue;

            // Gaussian weight for better stability (optional, can use 1.0 for uniform)
            const weight = @exp(-dist_sq / (2.0 * radius_sq / 4.0));

            const intensity = @as(f32, @floatFromInt(image.at(@intCast(py), @intCast(px)).*)) * weight;
            m00 += intensity;
            m10 += intensity * @as(f32, @floatFromInt(dx));
            m01 += intensity * @as(f32, @floatFromInt(dy));
        }
    }

    // Avoid division by zero
    if (m00 < 0.001) return 0;

    // Compute angle from centroid
    const centroid_x = m10 / m00;
    const centroid_y = m01 / m00;
    const angle_rad = std.math.atan2(centroid_y, centroid_x);
    return std.math.radiansToDegrees(angle_rad);
}

/// Compute BRIEF descriptor for a keypoint using the learned ORB pattern
fn computeBriefDescriptor(self: Orb, image: Image(u8), kp: KeyPoint) BinaryDescriptor {
    _ = self;
    var descriptor = BinaryDescriptor.init();

    const cos_angle = @cos(std.math.degreesToRadians(kp.angle));
    const sin_angle = @sin(std.math.degreesToRadians(kp.angle));

    // Use the learned ORB pattern for robust descriptor computation
    for (orb_pattern, 0..) |pattern, bit_idx| {
        // Get the two points to compare from the pattern
        const x1 = @as(f32, @floatFromInt(pattern[0]));
        const y1 = @as(f32, @floatFromInt(pattern[1]));
        const x2 = @as(f32, @floatFromInt(pattern[2]));
        const y2 = @as(f32, @floatFromInt(pattern[3]));

        // Rotate points by keypoint angle for rotation invariance
        const rx1 = cos_angle * x1 - sin_angle * y1;
        const ry1 = sin_angle * x1 + cos_angle * y1;
        const rx2 = cos_angle * x2 - sin_angle * y2;
        const ry2 = sin_angle * x2 + cos_angle * y2;

        // Sample pixels at rotated positions
        const val1 = samplePixel(image, kp.x + rx1, kp.y + ry1);
        const val2 = samplePixel(image, kp.x + rx2, kp.y + ry2);

        // Set bit if val1 < val2 (binary test)
        if (val1 < val2) {
            descriptor.setBit(bit_idx);
        }
    }

    return descriptor;
}

/// Compute Harris corner response for a keypoint
fn computeHarrisResponse(image: Image(u8), kp: KeyPoint) f32 {
    const window_size = 7;
    const half_window = window_size / 2;
    const k = 0.04; // Harris detector constant

    const x = @as(isize, @intFromFloat(kp.x));
    const y = @as(isize, @intFromFloat(kp.y));

    var Ixx: f32 = 0;
    var Iyy: f32 = 0;
    var Ixy: f32 = 0;

    // Compute image derivatives and structure tensor
    for (0..window_size) |dy| {
        const yy = y + @as(isize, @intCast(dy)) - half_window;
        if (yy <= 0 or yy >= image.rows - 1) continue;

        for (0..window_size) |dx| {
            const xx = x + @as(isize, @intCast(dx)) - half_window;
            if (xx <= 0 or xx >= image.cols - 1) continue;

            // Compute gradients using Sobel operators
            const uy = @as(usize, @intCast(yy));
            const ux = @as(usize, @intCast(xx));

            // Horizontal gradient (Sobel X)
            const Ix = @as(f32, @floatFromInt(@as(i32, image.at(uy - 1, ux + 1).*) - @as(i32, image.at(uy - 1, ux - 1).*) +
                2 * (@as(i32, image.at(uy, ux + 1).*) - @as(i32, image.at(uy, ux - 1).*)) +
                @as(i32, image.at(uy + 1, ux + 1).*) - @as(i32, image.at(uy + 1, ux - 1).*))) / 8.0;

            // Vertical gradient (Sobel Y)
            const Iy = @as(f32, @floatFromInt(@as(i32, image.at(uy + 1, ux - 1).*) - @as(i32, image.at(uy - 1, ux - 1).*) +
                2 * (@as(i32, image.at(uy + 1, ux).*) - @as(i32, image.at(uy - 1, ux).*)) +
                @as(i32, image.at(uy + 1, ux + 1).*) - @as(i32, image.at(uy - 1, ux + 1).*))) / 8.0;

            // Accumulate structure tensor elements
            Ixx += Ix * Ix;
            Iyy += Iy * Iy;
            Ixy += Ix * Iy;
        }
    }

    // Harris corner response: R = det(M) - k * trace(M)^2
    // where M is the structure tensor [Ixx, Ixy; Ixy, Iyy]
    const det = Ixx * Iyy - Ixy * Ixy;
    const trace = Ixx + Iyy;

    return det - k * trace * trace;
}

/// Sample a pixel with bounds checking
fn samplePixel(image: Image(u8), x: f32, y: f32) u8 {
    const ix = @as(isize, @intFromFloat(@round(x)));
    const iy = @as(isize, @intFromFloat(@round(y)));

    if (ix < 0 or ix >= image.cols or iy < 0 or iy >= image.rows) {
        return 0;
    }

    return image.at(@intCast(iy), @intCast(ix)).*;
}

/// Compute an adaptive FAST threshold for the given pyramid level (bounded to >= 5)
fn computeAdaptiveThreshold(self: Orb, level: usize) u8 {
    const level_scale = std.math.pow(f32, self.scale_factor, @as(f32, @floatFromInt(level)));
    const attenuation = 1.0 / level_scale;
    const base_threshold = @as(f32, @floatFromInt(self.fast_threshold));
    const scaled_threshold = std.math.clamp(base_threshold * attenuation, @as(f32, 5.0), @as(f32, 255.0));
    return @as(u8, @intFromFloat(@round(scaled_threshold)));
}

// Tests
test "ORB initialization" {
    const orb = Orb{
        .n_features = 1000,
        .scale_factor = 1.5,
        .n_levels = 6,
    };

    try expectEqual(@as(usize, 1000), orb.n_features);
    try expectEqual(@as(f32, 1.5), orb.scale_factor);
    try expectEqual(@as(u8, 6), orb.n_levels);
}

test "ORB feature distribution" {
    const allocator = std.testing.allocator;

    const orb = Orb{
        .n_features = 500,
        .n_levels = 4,
        .scale_factor = 1.2,
    };

    const features_per_level = try orb.computeFeaturesPerLevel(allocator);
    defer allocator.free(features_per_level);

    // Should have 4 levels
    try expectEqual(@as(usize, 4), features_per_level.len);

    // Total should be approximately n_features
    var total: usize = 0;
    for (features_per_level) |n| {
        total += n;
    }

    // Allow some rounding error
    try expectEqual(true, total <= orb.n_features + 10);
    try expectEqual(true, total >= orb.n_features - 10);

    // First level should have most features
    try expectEqual(true, features_per_level[0] > features_per_level[1]);
}

test "ORB detect and compute on synthetic image" {
    const allocator = std.testing.allocator;

    // Create test image with strong corner patterns
    var image = try Image(u8).init(allocator, 100, 100);
    defer image.deinit(allocator);

    // Fill with mid-gray
    for (0..image.rows) |r| {
        for (0..image.cols) |c| {
            image.at(r, c).* = 100;
        }
    }

    // Create strong corner patterns with high contrast
    // White square
    for (15..35) |r| {
        for (15..35) |c| {
            image.at(r, c).* = 250;
        }
    }

    // Black square
    for (55..75) |r| {
        for (55..75) |c| {
            image.at(r, c).* = 10;
        }
    }

    // Additional pattern for more corners
    for (40..50) |r| {
        for (20..30) |c| {
            image.at(r, c).* = if ((r + c) % 2 == 0) 200 else 50;
        }
    }

    const orb = Orb{
        .n_features = 50,
        .n_levels = 3,
        .fast_threshold = 10, // Lower threshold for test image
    };

    const result = try orb.detectAndCompute(image, allocator);
    defer allocator.free(result.keypoints);
    defer allocator.free(result.descriptors);

    // Should detect some keypoints
    try expectEqual(true, result.keypoints.len > 0);

    // Should have same number of descriptors as keypoints
    try expectEqual(result.keypoints.len, result.descriptors.len);

    // Check that keypoints have valid properties
    for (result.keypoints) |kp| {
        try expectEqual(true, kp.x >= 0 and kp.x < 100);
        try expectEqual(true, kp.y >= 0 and kp.y < 100);
        try expectEqual(true, kp.angle >= -180 and kp.angle <= 180);
        try expectEqual(true, kp.octave >= 0 and kp.octave < 3);
    }

    // Check that descriptors are not all zero
    var non_zero_found = false;
    for (result.descriptors) |desc| {
        if (desc.popCount() > 0) {
            non_zero_found = true;
            break;
        }
    }
    try expectEqual(true, non_zero_found);
}

test "ORB feature distribution respects budget" {
    const allocator = std.testing.allocator;

    const orb = Orb{
        .n_features = 5,
        .n_levels = 4,
        .scale_factor = 1.2,
    };

    const features_per_level = try orb.computeFeaturesPerLevel(allocator);
    defer allocator.free(features_per_level);

    var total: usize = 0;
    for (features_per_level) |n| {
        total += n;
        try expectEqual(true, n <= orb.n_features);
    }

    try expectEqual(@as(usize, 5), total);
}

test "ORB adaptive FAST threshold stays within bounds" {
    const orb = Orb{
        .fast_threshold = 20,
        .scale_factor = 1.2,
        .n_levels = 12,
    };

    try expectEqual(@as(u8, 20), orb.computeAdaptiveThreshold(0));
    try expectEqual(true, orb.computeAdaptiveThreshold(10) >= 5);
    try expectEqual(true, orb.computeAdaptiveThreshold(11) >= 5);
}
