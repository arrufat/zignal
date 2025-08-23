//! ORB (Oriented FAST and Rotated BRIEF) feature detector and descriptor

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const KeyPoint = @import("KeyPoint.zig");
const BinaryDescriptor = @import("BinaryDescriptor.zig");
const Fast = @import("Fast.zig");
const Image = @import("../image.zig").Image;
const ImagePyramid = @import("../image/pyramid.zig").ImagePyramid;

/// Default patch size for BRIEF descriptor (industry standard)
pub const DEFAULT_PATCH_SIZE: u8 = 31;

/// Maximum number of features to detect
n_features: usize = 500,

/// Scale factor between pyramid levels
scale_factor: f32 = 1.2,

/// Number of pyramid levels
n_levels: u8 = 8,

/// Border width where features are not detected
edge_threshold: u8 = DEFAULT_PATCH_SIZE,

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

        // Detect FAST corners
        var fast_detector = Fast{
            .threshold = self.fast_threshold,
            .nonmax_suppression = true,
            .min_contiguous = 9,
        };

        const corners = try fast_detector.detect(level_image, allocator);
        defer allocator.free(corners);

        // Keep only the best corners for this level
        var level_keypoints = corners;
        if (corners.len > n_desired) {
            // Sort by response
            std.mem.sort(KeyPoint, corners, {}, KeyPoint.compareResponse);
            level_keypoints = corners[0..n_desired];
        }

        // Compute orientation and scale coordinates
        for (level_keypoints) |*kp| {
            // Compute orientation using intensity centroid
            kp.angle = self.computeOrientation(level_image, kp.*);
            kp.octave = @intCast(level);

            // Scale coordinates to original image
            const scale = std.math.pow(f32, self.scale_factor, @as(f32, @floatFromInt(level)));
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

/// Detect keypoints and compute their descriptors
pub fn detectAndCompute(
    self: Orb,
    image: Image(u8),
    allocator: Allocator,
) !struct { keypoints: []KeyPoint, descriptors: []BinaryDescriptor } {
    const keypoints = try self.detect(image, allocator);
    errdefer allocator.free(keypoints);

    const descriptors = try self.compute(image, keypoints, allocator);

    return .{
        .keypoints = keypoints,
        .descriptors = descriptors,
    };
}

/// Compute the distribution of features per pyramid level
fn computeFeaturesPerLevel(self: Orb, allocator: Allocator) ![]usize {
    var n_features_per_level = try allocator.alloc(usize, self.n_levels);

    // Simple distribution: more features at finer scales
    // This follows ORB paper's approach
    const inv_scale = 1.0 / self.scale_factor;
    var sum_inv_scale: f32 = 0;

    // Calculate sum of inverse scales
    for (0..self.n_levels) |level| {
        sum_inv_scale += std.math.pow(f32, inv_scale, @as(f32, @floatFromInt(level)));
    }

    // Distribute features proportionally
    var assigned: usize = 0;
    for (0..self.n_levels) |level| {
        const scale_factor_level = std.math.pow(f32, inv_scale, @as(f32, @floatFromInt(level)));
        const n_desired = @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(self.n_features)) * scale_factor_level / sum_inv_scale)));

        if (level == self.n_levels - 1) {
            // Last level gets remaining features
            n_features_per_level[level] = self.n_features - assigned;
        } else {
            n_features_per_level[level] = n_desired;
            assigned += n_desired;
        }
    }

    return n_features_per_level;
}

/// Compute keypoint orientation using intensity centroid
fn computeOrientation(self: Orb, image: Image(u8), kp: KeyPoint) f32 {
    const half_patch = self.patch_size / 2;
    const x = @as(isize, @intFromFloat(kp.x));
    const y = @as(isize, @intFromFloat(kp.y));

    var m00: f32 = 0; // Zeroth moment
    var m10: f32 = 0; // First moment in x
    var m01: f32 = 0; // First moment in y

    // Compute moments
    for (0..self.patch_size) |v| {
        const dy = @as(isize, @intCast(v)) - half_patch;
        const py = y + dy;

        if (py < 0 or py >= image.rows) continue;

        for (0..self.patch_size) |u| {
            const dx = @as(isize, @intCast(u)) - half_patch;
            const px = x + dx;

            if (px < 0 or px >= image.cols) continue;

            const intensity = @as(f32, @floatFromInt(image.at(@intCast(py), @intCast(px)).*));
            m00 += intensity;
            m10 += intensity * @as(f32, @floatFromInt(dx));
            m01 += intensity * @as(f32, @floatFromInt(dy));
        }
    }

    // Avoid division by zero
    if (m00 == 0) return 0;

    // Compute angle from centroid
    const angle_rad = std.math.atan2(m01 / m00, m10 / m00);
    return std.math.radiansToDegrees(angle_rad);
}

/// Compute BRIEF descriptor for a keypoint
fn computeBriefDescriptor(self: Orb, image: Image(u8), kp: KeyPoint) BinaryDescriptor {
    _ = self;
    var descriptor = BinaryDescriptor.init();

    const cos_angle = @cos(std.math.degreesToRadians(kp.angle));
    const sin_angle = @sin(std.math.degreesToRadians(kp.angle));

    // Use a simple pattern for testing - in production would use learned ORB pattern
    // Pattern: compare pixels in a grid pattern around the keypoint
    var bit_idx: usize = 0;

    for (0..16) |i| {
        for (0..16) |j| {
            if (bit_idx >= 256) break;

            // First point of pair
            const x1 = @as(f32, @floatFromInt(i)) - 8;
            const y1 = @as(f32, @floatFromInt(j)) - 8;

            // Second point of pair (offset)
            const x2 = x1 + 3;
            const y2 = y1 + 3;

            // Rotate by keypoint angle
            const rx1 = cos_angle * x1 - sin_angle * y1;
            const ry1 = sin_angle * x1 + cos_angle * y1;
            const rx2 = cos_angle * x2 - sin_angle * y2;
            const ry2 = sin_angle * x2 + cos_angle * y2;

            // Sample pixels
            const val1 = samplePixel(image, kp.x + rx1, kp.y + ry1);
            const val2 = samplePixel(image, kp.x + rx2, kp.y + ry2);

            // Set bit if val1 < val2
            if (val1 < val2) {
                descriptor.setBit(bit_idx);
            }

            bit_idx += 1;
        }
        if (bit_idx >= 256) break;
    }

    return descriptor;
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

// Tests
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;

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
